"""Polls the dish and router, keeps the live picture in memory, and saves history to the store.

Three loops run in background threads:
  dish    every second: status (speed, latency, outages, alerts)
  router  every 2 seconds: the device list with per-device byte counters
  slow    history and dropouts every minute; obstruction map and router info every 10 minutes
"""

import json
import math
import os
import random
import re
import statistics
import threading
import time
import traceback
from collections import deque
from datetime import date, timedelta

import grpc

from . import __version__, starlink
from .starlink import Endpoint, gps_ns_to_unix

# Devices are keyed by the router's client_id. The router hides the second half of every
# MAC address ("3A:51:DE:XX:XX:XX"), so MACs can't tell two devices from the same maker apart.
ID_RE = re.compile(r"^[0-9]{1,20}$")
IFACE_BAND = {"RF_2GHZ": "2.4", "RF_5GHZ": "5", "RF_5GHZ_HIGH": "5", "RF_6GHZ": "6", "ETH": "eth"}
TYPES = {"phone", "laptop", "desktop", "tablet", "watch", "tv", "console", "speaker", "camera", "thermostat",
         "lights", "vacuum", "plug", "ereader", "printer", "unknown"}

OUTAGE_TEXT = {
    "BOOTING": "Starlink was starting up",
    "STOWED": "The dish was stowed",
    "THERMAL_SHUTDOWN": "The dish got too hot and paused",
    "NO_SCHEDULE": "No satellite time was available",
    "NO_SATS": "No satellites were in view",
    "OBSTRUCTED": "Something blocked the dish's view",
    "NO_DOWNLINK": "The signal from the satellite was lost",
    "NO_PINGS": "The connection briefly stopped responding",
    "ACTUATOR_ACTIVITY": "The dish was moving",
    "CABLE_TEST": "The cable was being tested",
    "SLEEPING": "The sleep schedule turned it off",
    "UNKNOWN": "Unknown cause",
}
# Dish alert -> (plain text, tone). "info" alerts are shown but don't go in the activity feed.
ALERT_TEXT = {
    "motors_stuck": ("The dish's motors are stuck", "warn"),
    "thermal_throttle": ("The dish is hot, so it's slowing down to cool off", "warn"),
    "thermal_shutdown": ("The dish got too hot and shut down", "crit"),
    "mast_not_near_vertical": ("The dish's mast isn't upright", "warn"),
    "unexpected_location": ("The dish is somewhere your plan doesn't cover", "warn"),
    "slow_ethernet_speeds": ("The cable to the dish is running slowly", "warn"),
    "slow_ethernet_speeds_100": ("The cable to the dish is limited to 100 Mbps", "warn"),
    "install_pending": ("A software update installs soon, which restarts Starlink", "info"),
    "is_heating": ("The dish is heating itself to melt snow", "info"),
    "power_supply_thermal_throttle": ("The power supply is hot and slowing down", "warn"),
    "is_power_save_idle": ("Starlink is asleep (sleep schedule)", "info"),
    "dbf_telem_stale": ("The dish's internal readings are out of date", "warn"),
    "low_motor_current": ("The dish's motors are drawing too little power", "warn"),
    "lower_signal_than_predicted": ("The signal is weaker than expected", "warn"),
    "obstruction_map_reset": ("The dish is relearning what blocks its view", "info"),
    "dish_water_detected": ("Water was detected in the dish", "crit"),
    "router_water_detected": ("Water was detected in the router", "crit"),
    "upsu_router_port_slow": ("The router port on the power supply is slow", "warn"),
    "no_ethernet_link": ("There's no cable connection between the dish and router", "crit"),
}
SPEEDTEST_TEXT = {
    "SPEEDTEST_ERROR_TOKEN": "Starlink couldn't authorize the test. Try again in a minute.",
    "SPEEDTEST_ERROR_OFFLINE": "Starlink was offline, so the test couldn't run.",
    "SPEEDTEST_ERROR_NO_RESULT": "The test finished without a result. Try again.",
    "refused": "The router didn't allow the test.",
    "timeout": "The test didn't finish within 90 seconds.",
}
TYPE_RULES = [  # first match wins, so the specific ones come first
    ("watch", r"watch"),
    ("tablet", r"ipad|\btab\b|tablet|galaxy-?tab|kindle-?fire|fire-?hd"),
    ("ereader", r"kindle|kobo|e-?reader"),
    ("tv", r"\btv\b|roku|chromecast|fire-?tv|firestick|bravia|webos|tizen|androidtv|shield"),
    ("console", r"playstation|\bps[345]\b|xbox|nintendo|\bswitch\b|\bconsole\b"),
    ("speaker", r"echo|alexa|homepod|nest-?(mini|audio|hub)|google-?home|sonos|speaker"),
    ("camera", r"\bcam\b|camera|\bring\b|doorbell|wyze|arlo|eufy|blink"),
    ("printer", r"printer|epson|canon|brother|officejet|laserjet|deskjet"),
    ("laptop", r"macbook|laptop|notebook|thinkpad|chromebook|surface|ideapad|zenbook|vivobook|inspiron|elitebook"),
    ("desktop", r"imac|mac-?mini|mac-?studio|desktop|\bpc\b|optiplex|workstation"),
    ("phone", r"iphone|android|galaxy|samsung|pixel|redmi|xiaomi|oneplus|huawei|tecno|infinix|itel|nokia|oppo|"
              r"vivo|realme|\bmoto|\bsm-|\b[ams]\d{2}[a-z]?\b"),
]


def num(v):
    try:
        f = float(v)
    except (TypeError, ValueError):
        return None
    return f if math.isfinite(f) else None


def g(d, path):
    for p in path.split("."):
        if not isinstance(d, dict):
            return None
        d = d.get(p)
    return d


def ms(t):
    return int(t * 1000) if t else None


def local_day(ts):
    return time.strftime("%Y-%m-%d", time.localtime(ts))


def day_start(ts):
    lt = time.localtime(ts)
    return int(time.mktime((lt.tm_year, lt.tm_mon, lt.tm_mday, 0, 0, 0, 0, 0, -1)))


def start_of_day(day):
    return int(time.mktime(time.strptime(day, "%Y-%m-%d")))


def fmt_secs(s):
    s = round(s)
    if s < 60:
        return f"{s} second{'' if s == 1 else 's'}"
    if s < 3600:
        m = round(s / 60)
        return f"{m} minute{'' if m == 1 else 's'}"
    h, m = divmod(round(s / 60), 60)
    return f"{h} h {m} min" if m else f"{h} h"


def guess_type(*names):
    text = " ".join(n for n in names if n).lower()
    for kind, pattern in TYPE_RULES:
        if text and re.search(pattern, text):
            return kind
    return "unknown"


def display_name(d):
    return (d.get("custom_name") or d.get("router_name") or d.get("hostname")
            or f"Unnamed device · {str(d['id'])[-4:]}")


def clean_text(v, limit):
    s = re.sub(r"[\x00-\x1f\x7f]", "", str(v or ""))
    return re.sub(r"\s+", " ", s).strip()[:limit]


def private_mac(mac):
    """Phones make up a random MAC address per network for privacy; those have this bit set."""
    try:
        return bool(int(str(mac)[:2], 16) & 2)
    except ValueError:
        return False


def typical(samples):
    """The usual speed during a test: the median, skipping the first readings while it ramps up."""
    v = [x for x in samples if x]
    if len(v) > 6:
        v = v[2:]
    return statistics.median(v) if v else None


class Collector:
    def __init__(self, store, dish=starlink.DISH, router=starlink.ROUTER):
        self.store = store
        # The fast loops and the slow loop each get their own connections, so a big history
        # download never delays the once-a-second reading.
        self.dish = Endpoint(dish)
        self.router = Endpoint(router, borrow=self.dish)
        self.dish_slow = Endpoint(dish)
        self.router_slow = Endpoint(router, borrow=self.dish_slow)
        self.router_test = Endpoint(router, borrow=self.dish_slow)  # speed tests poll once a second on their own line
        self.lock = threading.RLock()
        self.stopping = threading.Event()
        self.threads = []
        self.started = time.time()

        self.dish_live = {"reachable": None, "fails": 0, "online": None}
        self.dish_info = {}
        self.power_w = None
        self.obstruction = None
        self.live = deque(maxlen=900)  # (ts, down_bps, up_bps, latency_ms, drop_rate, online), last 15 minutes
        self.pending = []
        self.sample_minute = None
        self.last_sample = None
        self.fastest_bps = 0.0
        self.alerts = None
        self.software = store.meta("dish_software")
        self.backfilled = False
        self.gap_before = None  # first reading after a gap (the Mac slept): fill in before it from the dish
        # Orbit's dropout records start at the dish's boot before Orbit first ran: its history covers since boot.
        known = store.meta("known_since")
        self.known_since = int(known) if known else None

        self.router_live = {"reachable": None, "fails": 0}
        self.router_info = {}
        self.networks = {}
        self.schedules = {}  # client_id -> number of block-schedule ranges set in the Starlink app
        self.speedtest = {"running": False}
        self.tests = [self._test_out(r) for r in store.speedtests(10)]
        self.fake_speedtest = os.environ.get("ORBIT_FAKE_SPEEDTEST") == "1"  # development: simulate, use no data
        self.devices = {}   # client_id -> device dict (saved fields plus live ones)
        self.counters = {}  # client_id -> (rx_bytes, tx_bytes, associated_s, poll_ts)
        self.recent = {}    # client_id -> deque of (poll_ts, down_bytes, up_bytes) for the live speed
        self.acc = {}       # client_id -> [down, up, max_down_mbps, max_up_mbps, signal_sum, signal_n] this minute
        self.acc_minute = None
        init = store.meta("initialized")
        self.initialized = init is not None
        self.watching_since = int(init) if init else None

        now = time.time()
        self.day = local_day(now)
        self.home_today = [0.0, 0.0]
        self.dev_today = {}
        self.events = deque(maxlen=40)
        self._outage_cache = (0.0, [])
        self._people_cache = None
        self._state_cache = (0.0, b"")
        self._load(now)

    # ---------- lifecycle ----------
    def _load(self, now):
        for key, row in self.store.devices().items():
            d = dict(row)
            d.update(online=False, ip=row.get("last_ip"), iface=row.get("last_iface"), domain=row.get("last_domain"),
                     type_guess=guess_type(row.get("router_name"), row.get("hostname")))
            self.devices[key] = d
        self.home_today = list(self.store.home_bytes(day_start(now), now))
        self.dev_today = {m: list(v) for m, v in self.store.device_day_totals(self.day).items()}
        for e in reversed(self.store.events(40)):
            self.events.appendleft(self._event_out(e))
        self.fastest_bps = self.store.fastest_down(now - 7 * 86400)
        for r in self.store.samples_since(int(now) - 900):
            self.live.append((r["ts"], r["down_bps"], r["up_bps"], r["latency_ms"], r["drop_rate"], r["online"]))
        if self.live:
            self.last_sample = self.live[-1][0]
            self.sample_minute = self.last_sample // 60 * 60

    def start(self):
        for fn in (self._dish_loop, self._router_loop, self._slow_loop):
            t = threading.Thread(target=self._guard(fn), name=fn.__name__, daemon=True)
            t.start()
            self.threads.append(t)

    def _guard(self, fn):
        def run():
            while not self.stopping.is_set():
                try:
                    fn()
                    return
                except Exception:
                    traceback.print_exc()
                    self.stopping.wait(5)
        return run

    def stop(self):
        self.stopping.set()
        for t in self.threads:
            t.join(timeout=8)
        self._flush_samples()
        if self.sample_minute is not None:
            self.store.rollup_minutes(self.sample_minute, self.sample_minute + 60)
        self._flush_devices()
        for e in (self.dish, self.router, self.dish_slow, self.router_slow):
            e.close()

    # ---------- activity ----------
    @staticmethod
    def _event_out(e):
        return {"id": e["id"], "ts": e["ts"] * 1000, "cat": e["cat"], "icon": e["icon"], "title": e["title"],
                "detail": e.get("detail"), "device": e.get("device"), "tone": e.get("tone")}

    def event(self, cat, icon, title, detail=None, device=None, tone=None, ts=None):
        ts = int(ts or time.time())
        eid = self.store.add_event(ts, cat, icon, title, detail, device, tone)
        with self.lock:
            self.events.append(self._event_out({"id": eid, "ts": ts, "cat": cat, "icon": icon, "title": title,
                                                "detail": detail, "device": device, "tone": tone}))
            self.events = deque(sorted(self.events, key=lambda x: (-x["ts"], -x["id"]))[:40], maxlen=40)

    # ---------- dish ----------
    def _dish_loop(self):
        while not self.stopping.is_set():
            t = time.time()
            try:
                sample = self._on_dish_status(self.dish.read("get_status"), t)
            except Exception:
                sample = self._on_dish_error(t)
            self._add_sample(sample)
            self.stopping.wait(1.02 - time.time() % 1)

    def _on_dish_status(self, st, t):
        outage = st.get("outage") or None
        online = outage is None
        lat = num(st.get("pop_ping_latency_ms")) if online else None
        drop = num(st.get("pop_ping_drop_rate"))
        down = num(st.get("downlink_throughput_bps")) or 0.0
        up = num(st.get("uplink_throughput_bps")) or 0.0
        info, obs, cfg = st.get("device_info") or {}, st.get("obstruction_stats") or {}, st.get("config") or {}
        alerts = sorted(k for k, v in (st.get("alerts") or {}).items() if v is True)
        out = None
        if outage:
            since = num(outage.get("start_timestamp_ns"))
            out = {"cause": outage.get("cause") or "UNKNOWN", "since": ms(gps_ns_to_unix(since)) if since else None}
        with self.lock:
            back = self.dish_live.get("reachable") is False
            self.dish_live = {
                "reachable": True, "fails": 0, "online": online, "outage": out, "latency": lat, "drop": drop,
                "down": down, "up": up, "uptime": num(g(st, "device_state.uptime_s")),
                "obstructed": num(obs.get("fraction_obstructed")) or 0.0,
                "obstructed_now": bool(obs.get("currently_obstructed")), "obstruction_valid_s": num(obs.get("valid_s")),
                "alerts": alerts,
            }
            self.dish_info = {
                "hardware": info.get("hardware_version"), "software": info.get("software_version"),
                "actuated": st.get("has_actuators") == "HAS_ACTUATORS_YES", "eth_mbps": num(st.get("eth_speed_mbps")),
                "update_state": st.get("software_update_state"), "service": st.get("class_of_service"),
                "dl_limit": st.get("dl_bandwidth_restricted_reason"), "ul_limit": st.get("ul_bandwidth_restricted_reason"),
                "snow_melt": cfg.get("snow_melt_mode"), "update_hour": num(cfg.get("swupdate_reboot_hour")),
                "sleep": {"on": bool(cfg.get("power_save_mode")), "start_min": num(cfg.get("power_save_start_minutes")),
                          "duration_min": num(cfg.get("power_save_duration_minutes"))},
            }
        if back:
            self.event("network", "satellite-dish", "Orbit can reach your dish again", tone="good")
        self._check_software(info.get("software_version"))
        self._check_alerts(alerts)
        return (int(t), down, up, lat, drop, 1 if online else 0)

    def _on_dish_error(self, t):
        with self.lock:
            fails = self.dish_live["fails"] = self.dish_live.get("fails", 0) + 1
            lost = fails == 3 and self.dish_live.get("reachable") is not False
            if fails >= 3:
                self.dish_live.update(reachable=False, online=None, latency=None, down=0.0, up=0.0, outage=None)
        if lost:
            self.event("network", "satellite-dish", "Orbit can't reach your dish",
                       "It may be restarting, or a cable may be unplugged.", tone="warn")
        return (int(t), 0.0, 0.0, None, None, None)

    def _check_software(self, version):
        if version and version != self.software:
            old, self.software = self.software, version
            self.store.set_meta("dish_software", version)
            if old:
                self.event("network", "rotate-cw", "Starlink software updated", f"Now on version {version}.")

    def _check_alerts(self, alerts):
        now_on = set(alerts)
        if self.alerts is not None:
            for key in sorted(now_on - self.alerts):
                text, tone = ALERT_TEXT.get(key, (key.replace("_", " ").capitalize(), "warn"))
                if tone != "info":
                    self.event("network", "triangle-alert", text, "Reported by the dish.", tone=tone)
        self.alerts = now_on

    def _add_sample(self, sample):
        ts = sample[0]
        self._check_day(ts)
        with self.lock:
            last = self.last_sample
            if last is not None and ts <= last:
                return
            # If the loop fell behind by a few seconds, repeat this reading so usage isn't undercounted.
            rows = [(s,) + sample[1:] for s in range(last + 1, ts)] if last is not None and ts - last <= 10 else []
            if last is not None and ts - last > 10:  # a gap, usually the Mac sleeping: backfill on the next history pull
                self.gap_before, self.backfilled = ts, False
            rows.append(sample)
            for r in rows:
                self.live.append(r)
                self.pending.append(r)
                self.home_today[0] += r[1] / 8
                self.home_today[1] += r[2] / 8
                self.fastest_bps = max(self.fastest_bps, r[1])
            self.last_sample = ts
            minute = ts // 60 * 60
            new_minute = self.sample_minute is not None and minute != self.sample_minute
            prev_minute, self.sample_minute = self.sample_minute, minute
        if new_minute or len(self.pending) >= 10:
            self._flush_samples()
        if new_minute:
            self.store.rollup_minutes(prev_minute, minute)

    def _flush_samples(self):
        with self.lock:
            rows, self.pending = self.pending, []
        self.store.add_samples(rows)

    def _check_day(self, ts):
        day = local_day(ts)
        with self.lock:
            if day != self.day:
                self.day = day
                self.home_today = [0.0, 0.0]
                self.dev_today = {}

    # ---------- router ----------
    def _router_loop(self):
        while not self.stopping.is_set():
            t = time.time()
            try:
                self._on_clients(self.router.read("wifi_get_clients").get("clients") or [], t)
            except Exception:
                self._on_router_error()
            self.stopping.wait(max(0.2, 2 - (time.time() - t)))

    def _on_clients(self, clients, t):
        self._check_day(int(t))
        minute = int(t) // 60 * 60
        if self.acc_minute is not None and minute != self.acc_minute:
            self._flush_devices()
        self.acc_minute = minute
        first_look = not self.initialized
        seen, joined, came, went, flipped = set(), [], [], [], []
        with self.lock:
            back = self.router_live.get("reachable") is False
            self.router_live.update(reachable=True, fails=0, updated=t)
            for c in clients:
                if c.get("role") == "CONTROLLER":  # the router itself
                    continue
                key = str(c.get("client_id") or "")
                if not ID_RE.match(key) or key == "0":
                    continue
                seen.add(key)
                mac = str(c.get("mac_address") or "").upper()
                given, host = clean_text(c.get("given_name"), 60), clean_text(c.get("name"), 60)
                d = self.devices.get(key)
                if d is None:
                    d = self._new_device(key, mac, t, given, host, acknowledged=first_look)
                    if not first_look:
                        joined.append(d)
                iface = c.get("iface") or None
                wired = iface == "ETH"
                rx, tx = num(g(c, "rx_stats.bytes")) or 0.0, num(g(c, "tx_stats.bytes")) or 0.0
                assoc = num(c.get("associated_time_s")) or 0.0
                prev = self.counters.get(key)
                down, up = self._deltas(key, d, rx, tx, assoc, t)
                # A normal poll, not the first one after Orbit restarted or the device reconnected
                steady = prev is not None and rx >= prev[0] and tx >= prev[1] and assoc + 5 >= prev[2]
                down_mbps, up_mbps = self._speed(key, down if steady else 0.0, up if steady else 0.0, t, fresh=not steady)
                signal = None if wired else num(c.get("signal_strength"))
                a = self.acc.setdefault(key, [0.0, 0.0, 0.0, 0.0, 0.0, 0])
                a[0] += down
                a[1] += up
                a[2], a[3] = max(a[2], down_mbps), max(a[3], up_mbps)
                if signal is not None:
                    a[4] += signal
                    a[5] += 1
                today = self.dev_today.setdefault(key, [0.0, 0.0])
                today[0] += down
                today[1] += up
                was_online, offline_since = d.get("online"), d.get("offline_since")
                blocked = bool(c.get("blocked"))  # set from the Starlink app: paused, or inside a block schedule
                if was_online and blocked != bool(d.get("blocked")):
                    flipped.append((d, blocked))
                if given != (d.get("router_name") or "") or host != (d.get("hostname") or ""):
                    d["type_guess"] = guess_type(given, host)
                d.update(online=True, last_seen=t, mac=mac or d.get("mac"), router_name=given or None, blocked=blocked,
                         hostname=host or None, ip=c.get("ip_address") or d.get("ip"), iface=iface,
                         domain=c.get("domain") or None, signal=signal, snr=None if wired else num(c.get("snr")),
                         down_mbps=down_mbps, up_mbps=up_mbps, rate_down=num(g(c, "rx_stats.rate_mbps")),
                         rate_up=num(g(c, "tx_stats.rate_mbps")), width=num(c.get("channel_width")), offline_since=None,
                         since=(t - assoc) if assoc else (d.get("since") if was_online else t))
                if not was_online and offline_since and t - offline_since > 300 and d not in joined:
                    came.append(d)
            for key, d in self.devices.items():
                if d.get("online") and key not in seen and t - (d.get("last_seen") or 0) > 30:
                    d.update(online=False, offline_since=t, down_mbps=0.0, up_mbps=0.0)
                    if t - (d.get("since") or t) > 300:
                        went.append(d)
        if back:
            self.event("network", "router", "Orbit can reach your router again", tone="good")
        if first_look:
            self.initialized = True
            self.watching_since = int(t)
            self.store.set_meta("initialized", int(t))
            self.event("network", "radar", "Orbit started watching your network",
                       f"Found {len(seen)} device{'' if len(seen) == 1 else 's'} on your Wi-Fi.")
        for d in joined:
            self.event("security", "shield-alert", "A new device joined your Wi-Fi",
                       f"{display_name(d)} · {self._net_label(d)}", device=d["id"], tone="warn")
        for d in came:
            self.event("devices", "wifi", f"{display_name(d)} connected", self._net_label(d), device=d["id"])
        for d in went:
            self.event("devices", "wifi-off", f"{display_name(d)} disconnected", device=d["id"])
        for d, blocked in flipped:
            if blocked:
                self.event("devices", "ban", f"{display_name(d)} lost internet access", "Blocked from the Starlink app.", device=d["id"])
            else:
                self.event("devices", "play", f"{display_name(d)} has internet access again", device=d["id"])

    def _on_router_error(self):
        with self.lock:
            fails = self.router_live["fails"] = self.router_live.get("fails", 0) + 1
            lost = fails == 3 and self.router_live.get("reachable") is not False
            if fails >= 3:
                self.router_live["reachable"] = False
        if lost:
            self.event("network", "router", "Orbit can't reach your router",
                       "Device details may be out of date until it's back.", tone="warn")

    def _new_device(self, key, mac, t, given, host, acknowledged):
        d = {"id": key, "mac": mac, "first_seen": int(t), "last_seen": t, "router_name": given or None,
             "hostname": host or None, "custom_name": None, "owner": None, "type": None,
             "acknowledged": 1 if acknowledged else 0, "online": False, "type_guess": guess_type(given, host)}
        self.store.add_device(key, mac, t, given or None, host or None, d["acknowledged"])
        self.devices[key] = d
        return d

    SPEED_WINDOW_S = 6

    def _speed(self, key, down, up, t, fresh=False):
        """Live Mbps from the byte counters over the last few seconds. The router's own figure is a
        15-second average, which lags; one poll alone is too jumpy, because video arrives in bursts."""
        q = self.recent.setdefault(key, deque())
        if fresh:
            q.clear()
        q.append((t, down, up))
        while q and t - q[0][0] > self.SPEED_WINDOW_S:
            q.popleft()
        span = max(t - q[0][0], 2.0) if len(q) > 1 else 2.0
        moved_down = sum(x[1] for x in list(q)[1:]) if len(q) > 1 else down
        moved_up = sum(x[2] for x in list(q)[1:]) if len(q) > 1 else up
        return moved_down * 8 / 1e6 / span, moved_up * 8 / 1e6 / span

    def _deltas(self, key, d, rx, tx, assoc, t):
        """Bytes downloaded and uploaded since the last poll. The router's counters restart when a device reconnects."""
        prev = self.counters.get(key)
        self.counters[key] = (rx, tx, assoc, t)
        if prev is None:
            last_poll, last_rx, last_tx = d.get("last_poll"), d.get("last_rx"), d.get("last_tx")
            if last_poll and last_rx is not None and last_tx is not None:
                gap = t - last_poll
                if assoc >= (d.get("last_assoc_s") or 0) + gap - 60 and rx >= last_rx and tx >= last_tx:
                    return self._sane(rx - last_rx, tx - last_tx, gap)  # stayed connected while Orbit was off
                if assoc < gap:
                    return self._sane(rx, tx, assoc)  # reconnected while Orbit was off
                return 0.0, 0.0
            return self._sane(rx, tx, assoc) if assoc < 300 else (0.0, 0.0)  # it just joined
        prx, ptx, passoc, pt = prev
        if rx < prx or tx < ptx or assoc + 5 < passoc:  # counters restarted
            return self._sane(rx, tx, max(assoc, 1))
        return self._sane(rx - prx, tx - ptx, t - pt)

    @staticmethod
    def _sane(down, up, seconds):
        cap = 1.25e9 * max(seconds, 1)  # 10 Gbps; anything faster is a bad reading
        return (down if 0 <= down <= cap else 0.0), (up if 0 <= up <= cap else 0.0)

    def _flush_devices(self):
        with self.lock:
            minute, acc, self.acc = self.acc_minute, self.acc, {}
            if minute is None:
                return
            day = local_day(minute)
            minutes = [(key, minute, a[0], a[1], a[2], a[3], (a[4] / a[5]) if a[5] else None)
                       for key, a in acc.items() if a[0] or a[1] or a[5]]
            days = [(key, day, a[0], a[1]) for key, a in acc.items() if a[0] or a[1]]
            counters = []
            for key, (rx, tx, assoc, pt) in self.counters.items():
                d = self.devices.get(key)
                if d:
                    counters.append((rx, tx, assoc, pt, int(d.get("last_seen") or pt), d.get("mac"), d.get("router_name"),
                                     d.get("hostname"), d.get("ip"), d.get("iface"), d.get("domain"), key))
        self.store.add_device_minutes(minutes)
        self.store.add_device_days(days)
        self.store.save_counters(counters)

    def _net_label(self, d):
        net = self.networks.get(d.get("domain") or "")
        if d.get("iface") == "ETH":
            return "Wired"
        if net:
            return "Guest Wi-Fi" if net.get("guest") else "Main Wi-Fi"
        return "Wi-Fi"

    # ---------- slow loop ----------
    def _slow_loop(self):
        due = {"history": 0.0, "info": 0.0, "prune": time.time() + 120}
        while not self.stopping.is_set():
            t = time.time()
            if t >= due["history"]:
                due["history"] = t + (60 if self._history() else 15)
            if t >= due["info"]:
                due["info"] = t + (600 if self._info() else 60)
            if t >= due["prune"]:
                self.store.prune(t)
                with self.lock:
                    self.fastest_bps = max(self.store.fastest_down(t - 7 * 86400),
                                           max((r[1] for r in self.live), default=0.0))
                due["prune"] = t + 3600
            self.stopping.wait(2)

    def _history(self):
        try:
            h = self.dish_slow.read("get_history")
        except Exception:
            return False
        t = time.time()
        cur = int(num(h.get("current")) or 0)

        def recent(key, count):
            a = h.get(key) or []
            k = min(count, len(a), cur)
            return [num(a[(cur - k + i) % len(a)]) for i in range(k)]

        power = [v for v in recent("power_in", 60) if v]
        with self.lock:
            self.power_w = sum(power) / len(power) if power else None
            uptime = self.dish_live.get("uptime")
        if self.known_since is None and uptime:
            self.known_since = int(t - uptime)
            self.store.set_meta("known_since", self.known_since)
        if not self.backfilled:
            self._backfill(h, cur, t)
            self.backfilled = True
        rows = []
        for o in h.get("outages") or []:
            start = num(o.get("start_timestamp_ns"))
            if not start:
                continue
            rows.append((int(gps_ns_to_unix(start) * 1000), (num(o.get("duration_ns")) or 0) / 1e9,
                         o.get("cause") or "UNKNOWN", 1 if o.get("did_switch") else 0))
        for start_ms, dur, cause, _ in self.store.add_outages(rows):
            if dur < 2:  # sub-second blips still count in the stats, but don't fill the activity feed
                continue
            if cause == "BOOTING":
                self.event("network", "rotate-cw", "Starlink restarted", f"Back online after {fmt_secs(dur)}.",
                           ts=start_ms / 1000)
            else:
                self.event("network", "satellite-dish", f"Starlink dropped for {fmt_secs(dur)}",
                           OUTAGE_TEXT.get(cause, cause.replace("_", " ").capitalize()) + ".",
                           tone="warn" if dur >= 10 else None, ts=start_ms / 1000)
        with self.lock:
            self._outage_cache = (0.0, [])
        return True

    def _backfill(self, h, cur, t):
        """Fill in the last 15 minutes from the dish's own history, so charts aren't empty after a restart."""
        down, up = h.get("downlink_throughput_bps") or [], h.get("uplink_throughput_bps") or []
        lat, drop = h.get("pop_ping_latency_ms") or [], h.get("pop_ping_drop_rate") or []
        n = min(len(down), len(up), len(lat), len(drop))
        k = min(n, cur, 900)
        now_s = int(t)
        rows = []
        for i in range(k):  # i = 0 is the newest sample
            idx = (cur - 1 - i) % n
            dr = num(drop[idx])
            online = 0 if dr is not None and dr >= 1 else 1
            rows.append((now_s - 1 - i, num(down[idx]) or 0.0, num(up[idx]) or 0.0,
                         num(lat[idx]) if online else None, dr, online))
        rows.reverse()
        with self.lock:
            before, self.gap_before = self.gap_before or int(self.started), None
            have = {r[0] for r in self.live}
            missing = [r for r in rows if r[0] not in have and r[0] < before]
            if not missing:
                return
            merged = sorted({r[0]: r for r in missing + list(self.live)}.values())
            self.live = deque(merged[-900:], maxlen=900)
            pending, self.pending = self.pending, []
        self.store.add_samples(missing + pending)
        self.store.rollup_minutes(missing[0][0] // 60 * 60, now_s // 60 * 60)
        with self.lock:
            self.home_today = list(self.store.home_bytes(day_start(t), t))

    def _info(self):
        ok = True
        try:
            om = self.dish_slow.read("dish_get_obstruction_map")
            snr = []
            for v in om.get("snr") or []:
                f = num(v)
                snr.append(-1 if f is None or f < 0 else round(f, 2))
            with self.lock:
                self.obstruction = {"rows": int(num(om.get("num_rows")) or 0), "cols": int(num(om.get("num_cols")) or 0),
                                    "snr": snr, "min_elevation_deg": num(om.get("min_elevation_deg")),
                                    "max_theta_deg": num(om.get("max_theta_deg")),
                                    "frame": om.get("map_reference_frame"), "updated": ms(time.time())}
        except Exception:
            ok = False
        try:
            # The router answers get_status with its Wi-Fi status. Its config section also holds the Wi-Fi
            # passwords, so only the fields below are kept and the rest is dropped right away.
            rs = self.router_slow.read("get_status")
            nets = {}
            for n in g(rs, "config.networks") or []:
                ssids = {b.get("band"): b.get("ssid") for b in n.get("basic_service_sets") or [] if b.get("ssid")}
                nets[n.get("domain") or ""] = {"guest": bool(n.get("guest")), "isolated": bool(n.get("client_isolation")),
                                               "subnet": n.get("ipv4"), "ssids": ssids}
            info = rs.get("device_info") or {}
            router_info = {"hardware": info.get("hardware_version"), "software": info.get("software_version"),
                           "uptime_s": num(g(rs, "device_state.uptime_s")), "bypass": bool(g(rs, "config.bypass_mode"))}
            # Block schedules set in the Starlink app, per device. Orbit can show them but not change them.
            confs = g(rs, "config.client_configs")
            if confs is None:
                confs = g(self.router_slow.read("wifi_get_config"), "wifi_config.client_configs") or []
            schedules = {}
            for c in confs:
                ranges = sum(len(s.get("block_ranges") or []) for s in c.get("weekly_block_schedules") or [])
                if c.get("client_id") and ranges:
                    schedules[str(c["client_id"])] = ranges
            del rs, confs
            with self.lock:
                self.networks, self.router_info, self.schedules = nets, router_info, schedules
        except Exception:
            ok = False
        return ok

    # ---------- speed tests ----------
    @staticmethod
    def _test_out(r):
        err = r.get("error")
        return {"ts": r["ts"] * 1000, "down": r.get("down_mbps"), "up": r.get("up_mbps"), "down_peak": r.get("down_peak"),
                "up_peak": r.get("up_peak"), "latency": r.get("latency_ms"), "error": err,
                "error_text": SPEEDTEST_TEXT.get(err, "The test failed. Try again in a minute.") if err else None}

    def start_speedtest(self):
        """The router tests download, then upload, for about 30 seconds in all. It uses a few hundred MB."""
        with self.lock:
            if self.speedtest.get("running"):
                raise ValueError("A speed test is already running")
            if self.tests and time.time() - self.tests[0]["ts"] / 1000 < 60:
                raise ValueError("Wait a minute between speed tests")
            if self.dish_live.get("online") is not True and not self.fake_speedtest:
                raise ValueError("Starlink is offline, so there’s nothing to test")
            self.speedtest = {"running": True, "phase": "starting", "started": time.time(), "down": [], "up": [],
                              "latency": self.dish_live.get("latency")}
            self._state_cache = (0.0, b"")
        threading.Thread(target=self._run_speedtest, name="speedtest", daemon=True).start()

    def _run_speedtest(self):
        error = None
        try:
            if self.fake_speedtest:
                self._fake_speedtest()
            else:
                before = g(self.router_test.read("get_speedtest_status"), "status.id")
                self.router_test.act("start_speedtest", duration_s=10, send_telemetry=False)
                t0, ours = time.time(), False
                while True:
                    if self.stopping.is_set() or time.time() - t0 > 90:
                        error = "timeout"
                        break
                    st = self.router_test.read("get_speedtest_status").get("status") or {}
                    ours = ours or st.get("id") != before or bool(st.get("running"))  # not the previous test's leftovers
                    if ours:
                        down = [num(v) for v in g(st, "down.throughputs_mbps") or []]
                        up = [num(v) for v in g(st, "up.throughputs_mbps") or []]
                        with self.lock:
                            self.speedtest.update(down=down, up=up, phase="up" if up else "down" if down else "starting")
                        errs = [e for e in (g(st, "down.err"), g(st, "up.err")) if e and e != "SPEEDTEST_ERROR_NONE"]
                        if errs:
                            error = errs[0]
                            break
                        if not st.get("running") and time.time() - t0 > 3:
                            break
                    self.stopping.wait(1)
        except grpc.RpcError as e:
            error = "refused" if e.code() == grpc.StatusCode.PERMISSION_DENIED else "SPEEDTEST_ERROR_UNKNOWN"
        except Exception:
            traceback.print_exc()
            error = "SPEEDTEST_ERROR_UNKNOWN"
        self._finish_speedtest(error)

    def _fake_speedtest(self):
        """Development only (ORBIT_FAKE_SPEEDTEST=1): pretend to test, without using any data."""
        for phase, base in (("down", 230.0), ("up", 12.0)):
            for _ in range(14):
                if self.stopping.is_set():
                    return
                with self.lock:
                    self.speedtest[phase] = self.speedtest.get(phase, []) + [base * random.uniform(0.4, 1.8) for _ in range(4)]
                    self.speedtest["phase"] = phase
                time.sleep(1)

    def _finish_speedtest(self, error=None):
        with self.lock:
            st = dict(self.speedtest)
        down_s, up_s = st.get("down") or [], st.get("up") or []
        down, up = typical(down_s), typical(up_s)
        if not error and not down:
            error = "SPEEDTEST_ERROR_NO_RESULT"
        ts = int(time.time())
        row = {"ts": ts, "down_mbps": down, "up_mbps": up, "down_peak": max([x for x in down_s if x] or [0]) or None,
               "up_peak": max([x for x in up_s if x] or [0]) or None, "latency_ms": st.get("latency"), "error": error}
        self.store.add_speedtest(ts, row["down_mbps"], row["up_mbps"], row["down_peak"], row["up_peak"], row["latency_ms"], error)
        result = self._test_out(row)
        with self.lock:
            self.speedtest = {"running": False, "result": result}
            self.tests = [result] + self.tests[:9]
            self._state_cache = (0.0, b"")
        if error:
            self.event("network", "gauge", "The speed test didn’t finish", result["error_text"], tone="warn")
        else:
            self.event("network", "gauge", f"Speed test: {round(down)} Mbps down, {round(up or 0)} Mbps up",
                       f"Latency {round(st['latency'])} ms" if st.get("latency") else None)

    def _speedtest_out(self):
        """What the page shows while a test runs: the phase and a smoothed live reading."""
        with self.lock:
            st = dict(self.speedtest)

        def now(v):
            v = [x for x in (v or [])[-8:] if x is not None]  # about the last 2 seconds; the router reports 4 a second
            return sum(v) / len(v) if v else None

        return {"running": bool(st.get("running")), "phase": st.get("phase"), "started": ms(st.get("started")),
                "down_now": now(st.get("down")), "up_now": now(st.get("up")), "down_n": len(st.get("down") or []),
                "up_n": len(st.get("up") or []), "result": st.get("result")}

    # ---------- what the web app sees ----------
    def _outages(self, now):
        with self.lock:
            at, rows = self._outage_cache
            uptime = self.dish_live.get("uptime")
        if now - at < 10:
            return rows
        since = min(now - 86400, now - uptime) if uptime else now - 86400
        rows = self.store.outages_since(int(since * 1000))
        with self.lock:
            self._outage_cache = (now, rows)
        return rows

    def _people(self):
        if self._people_cache is None:
            self._people_cache = [{"id": p["id"], "name": p["name"], "color": p["color"]} for p in self.store.people()]
        return self._people_cache

    def _invalidate(self):
        self._people_cache = None
        self._state_cache = (0.0, b"")

    def _device_out(self, d):
        online = bool(d.get("online"))
        today = self.dev_today.get(d["id"]) or (0.0, 0.0)
        net = self.networks.get(d.get("domain") or "")
        iface = d.get("iface")
        return {
            "id": d["id"], "mac": d.get("mac"), "name": display_name(d), "custom_name": d.get("custom_name"),
            "router_name": d.get("router_name"), "hostname": d.get("hostname"), "owner": d.get("owner"),
            "type": d.get("type") or d.get("type_guess") or "unknown", "type_set": bool(d.get("type")),
            "online": online, "since": ms(d.get("since")) if online else None, "first_seen": ms(d.get("first_seen")),
            "last_seen": ms(d.get("last_seen")), "ip": d.get("ip"), "iface": iface, "band": IFACE_BAND.get(iface),
            "domain": d.get("domain"),
            "upper_band": iface == "RF_5GHZ_HIGH",
            "network": ("guest" if net.get("guest") else "main") if net else ("wired" if iface == "ETH" else None),
            "ssid": (net or {}).get("ssids", {}).get(iface), "signal": d.get("signal"), "snr": d.get("snr"),
            "down_mbps": d.get("down_mbps") or 0.0 if online else 0.0, "up_mbps": d.get("up_mbps") or 0.0 if online else 0.0,
            "rate_down": d.get("rate_down"), "rate_up": d.get("rate_up"), "width": d.get("width"),
            "today_down": today[0], "today_up": today[1], "is_new": not d.get("acknowledged"),
            "private_mac": private_mac(d.get("mac")), "blocked": bool(d.get("blocked")) and online,
            "schedules": self.schedules.get(d["id"], 0),
        }

    @staticmethod
    def _point(r):
        return {"t": r[0] * 1000, "down": r[1] / 1e6, "up": r[2] / 1e6, "lat": r[3], "on": r[5]}

    def state(self, now=None):
        now = now or time.time()
        outages = self._outages(now)
        with self.lock:
            dl, di, rl, ri = dict(self.dish_live), dict(self.dish_info), dict(self.router_live), dict(self.router_info)
            devices = [self._device_out(d) for d in self.devices.values()]
            points = [self._point(r) for r in list(self.live)[-5:]]
            events = list(self.events)
            home = {"day": self.day, "down": self.home_today[0], "up": self.home_today[1]}
            nets = [{"domain": k, **v} for k, v in self.networks.items()]
            fastest, power = self.fastest_bps, self.power_w
        devices.sort(key=lambda x: (not x["online"], -(x["down_mbps"] + x["up_mbps"]), x["name"].lower()))
        uptime = dl.get("uptime")
        boot = now - uptime if uptime else None
        ends = [o["start_ms"] / 1000 + o["duration_s"] for o in outages
                if o["duration_s"] >= 5 and boot and o["start_ms"] / 1000 >= boot - 5]
        online_since = max([boot] + ends) if boot and dl.get("online") else None
        outage = dl.get("outage")
        if outage:
            outage = {**outage, "text": OUTAGE_TEXT.get(outage["cause"], outage["cause"].replace("_", " ").capitalize())}
        return {
            "now": ms(now), "version": __version__, "started": ms(self.started), "known_since": ms(self.known_since),
            "watching_since": ms(self.watching_since),
            "dish": {
                "reachable": dl.get("reachable"), "online": dl.get("online"), "outage": outage,
                "latency_ms": dl.get("latency"), "drop_rate": dl.get("drop"),
                "down_mbps": (dl.get("down") or 0.0) / 1e6, "up_mbps": (dl.get("up") or 0.0) / 1e6,
                "uptime_s": uptime, "online_since": ms(online_since), "obstructed": dl.get("obstructed"),
                "obstructed_now": dl.get("obstructed_now"), "obstruction_valid_s": dl.get("obstruction_valid_s"),
                "alerts": [{"key": k, "text": ALERT_TEXT.get(k, (k.replace("_", " ").capitalize(), "warn"))[0],
                            "tone": ALERT_TEXT.get(k, ("", "warn"))[1]} for k in dl.get("alerts") or []],
                "power_w": power, "fastest_mbps": fastest / 1e6, **di,
            },
            "router": {"reachable": rl.get("reachable"), "updated": ms(rl.get("updated")), **ri, "networks": nets},
            "home": home, "points": points, "devices": devices, "people": self._people(), "events": events,
            "speedtest": self._speedtest_out(), "tests": self.tests[:5],
            "outages": [{"start": o["start_ms"], "duration_s": o["duration_s"], "cause": o["cause"],
                         "text": OUTAGE_TEXT.get(o["cause"], o["cause"].replace("_", " ").capitalize())}
                        for o in outages if o["start_ms"] >= (now - 86400) * 1000],
        }

    def state_json(self):
        now = time.time()
        with self.lock:
            at, body = self._state_cache
        if now - at < 0.9 and body:
            return body
        body = json.dumps(self.state(now), separators=(",", ":")).encode()
        with self.lock:
            self._state_cache = (now, body)
        return body

    def live_points(self):
        with self.lock:
            return [self._point(r) for r in self.live]

    def _current_minute_bytes(self):
        with self.lock:
            m = self.sample_minute
            rows = [r for r in self.live if m is not None and r[0] >= m]
        return sum(r[1] for r in rows) / 8, sum(r[2] for r in rows) / 8

    def usage(self, rng):
        now = time.time()
        now_s = int(now)
        if rng == "24h":
            start = now_s // 3600 * 3600 - 23 * 3600
            keys = [start + i * 3600 for i in range(24)]
            by = {r["k"]: r for r in self.store.home_buckets(start, now_s + 1, "hour")}
            bars = [{"t": k * 1000, "down": (by.get(k) or {}).get("down") or 0.0, "up": (by.get(k) or {}).get("up") or 0.0}
                    for k in keys]
            bucket = 900
            devs = self.store.device_usage_minutes(start, now_s + 1)
            with self.lock:
                for key, a in self.acc.items():
                    v = devs.setdefault(key, [0.0, 0.0])
                    v[0] += a[0]
                    v[1] += a[1]
        elif rng in ("7d", "30d"):
            n = 7 if rng == "7d" else 30
            today = date.fromtimestamp(now)
            days = [(today - timedelta(days=n - 1 - i)).isoformat() for i in range(n)]
            start = start_of_day(days[0])
            by = {r["k"]: r for r in self.store.home_buckets(start, now_s + 1, "day")}
            bars = [{"t": start_of_day(d) * 1000, "day": d, "down": (by.get(d) or {}).get("down") or 0.0,
                     "up": (by.get(d) or {}).get("up") or 0.0} for d in days]
            with self.lock:
                bars[-1]["down"], bars[-1]["up"] = self.home_today
            bucket = 3600 if n == 7 else 6 * 3600
            devs = self.store.device_usage_days(days[0], days[-2]) if n > 1 else {}
            with self.lock:
                for key, (d0, u0) in self.dev_today.items():
                    v = devs.setdefault(key, [0.0, 0.0])
                    v[0] += d0
                    v[1] += u0
        else:
            raise ValueError("Unknown range")
        if rng == "24h":
            extra = self._current_minute_bytes()
            bars[-1]["down"] += extra[0]
            bars[-1]["up"] += extra[1]
        rows = {r["k"]: r for r in self.store.speed_series(start, now_s + 1, bucket)}
        speed = []
        for k in range(start // bucket * bucket, now_s + 1, bucket):
            r = rows.get(k)
            speed.append({"t": k * 1000, "down": r["down"] / 1e6 if r and r["down"] is not None else None,
                          "down_max": r["down_max"] / 1e6 if r and r["down_max"] is not None else None,
                          "up": r["up"] / 1e6 if r and r["up"] is not None else None,
                          "lat": r["lat"] if r else None})
        with self.lock:
            names = {key: (display_name(d), d.get("owner"), d.get("type") or d.get("type_guess"))
                     for key, d in self.devices.items()}
        devices = []
        for key, (d0, u0) in devs.items():
            if d0 + u0 <= 0:
                continue
            name, owner, kind = names.get(key, ("Forgotten device", None, "unknown"))
            devices.append({"id": key, "name": name, "owner": owner, "type": kind, "down": d0, "up": u0})
        devices.sort(key=lambda x: -(x["down"] + x["up"]))
        out = self.store.outage_stats(start * 1000, (now_s + 1) * 1000)
        return {
            "range": rng, "start": start * 1000, "end": ms(now), "bars": bars, "speed": speed, "bucket_s": bucket,
            "total": {"down": sum(b["down"] for b in bars), "up": sum(b["up"] for b in bars)},
            "devices": devices, "outages": {"count": out["n"], "seconds": out["s"]},
            "recorded_s": self.store.recorded_seconds(start, now_s + 1), "range_s": now_s - start,
        }

    def device_usage(self, did):
        key, _ = self._find(did)
        today = date.today()
        days = [(today - timedelta(days=6 - i)).isoformat() for i in range(7)]
        saved = self.store.device_days_for(key, days[0], days[-1])
        with self.lock:
            live = list(self.dev_today.get(key) or (0.0, 0.0))
        out = [{"day": d, "t": start_of_day(d) * 1000, "down": (saved.get(d) or (0.0, 0.0))[0],
                "up": (saved.get(d) or (0.0, 0.0))[1]} for d in days]
        out[-1]["down"], out[-1]["up"] = live
        return {"days": out}

    def events_list(self, cat=None, limit=200):
        return [self._event_out(e) for e in self.store.events(max(1, min(int(limit), 500)), cat or None)]

    def obstruction_map(self):
        with self.lock:
            if not self.obstruction:
                raise KeyError("obstruction map")
            return self.obstruction

    # ---------- changes from the web app ----------
    def _find(self, did):
        did = str(did or "")
        if not ID_RE.match(did):
            raise KeyError(did)
        with self.lock:
            d = self.devices.get(did)
        if d is None:
            raise KeyError(did)
        return did, d

    def update_device(self, did, body):
        key, d = self._find(did)
        fields = {}
        if "name" in body:
            fields["custom_name"] = clean_text(body["name"], 40) or None
        if "owner" in body:
            owner = body["owner"]
            if owner is not None and owner not in {p["id"] for p in self._people()}:
                raise ValueError("That person doesn't exist")
            fields["owner"] = owner
        if "type" in body:
            if body["type"] is not None and body["type"] not in TYPES:
                raise ValueError("Unknown device type")
            fields["type"] = body["type"]
        if fields or body.get("acknowledged") is True:
            fields["acknowledged"] = 1
        if not fields:
            raise ValueError("Nothing to change")
        with self.lock:
            before = display_name(d)
            d.update(fields)
            after = display_name(d)
        self.store.update_device(key, **fields)
        if "custom_name" in fields and after != before:
            self.event("you", "pencil", f"You renamed {before} to {after}", device=key)
        if "owner" in fields:
            person = next((p["name"] for p in self._people() if p["id"] == fields["owner"]), None)
            self.event("you", "tag", f"{after} now belongs to {person}" if person else f"{after} has no owner now", device=key)
        self._invalidate()
        with self.lock:
            return self._device_out(d)

    def forget_device(self, did):
        key, d = self._find(did)
        if d.get("online"):
            raise ValueError("Only offline devices can be forgotten")
        with self.lock:
            name = display_name(d)
            for table in (self.devices, self.counters, self.recent, self.dev_today, self.acc):
                table.pop(key, None)
        self.store.delete_device(key)
        self.event("you", "trash-2", f"You forgot {name}", "If it connects again, it shows up as new.")
        self._invalidate()

    def add_person(self, body):
        name = clean_text(body.get("name"), 24)
        if not name:
            raise ValueError("A name is needed")
        person = self.store.add_person(name)
        self._invalidate()
        moved = 0
        for did in body.get("devices") or []:
            try:
                key, d = self._find(did)
            except KeyError:
                continue
            with self.lock:
                d.update(owner=person["id"], acknowledged=1)
            self.store.update_device(key, owner=person["id"], acknowledged=1)
            moved += 1
        self.event("you", "user-plus", f"You added {name}", f"{moved} device{'' if moved == 1 else 's'}" if moved else None)
        self._invalidate()
        return person

    def rename_person(self, pid, body):
        people = {p["id"]: p for p in self._people()}
        if pid not in people:
            raise KeyError(pid)
        name = clean_text(body.get("name"), 24)
        if not name:
            raise ValueError("A name is needed")
        self.store.rename_person(pid, name)
        self.event("you", "pencil", f"You renamed {people[pid]['name']} to {name}")
        self._invalidate()

    def delete_person(self, pid):
        people = {p["id"]: p for p in self._people()}
        if pid not in people:
            raise KeyError(pid)
        self.store.delete_person(pid)
        with self.lock:
            for d in self.devices.values():
                if d.get("owner") == pid:
                    d["owner"] = None
        self.event("you", "user", f"You removed {people[pid]['name']}", "Their devices have no owner now.")
        self._invalidate()
