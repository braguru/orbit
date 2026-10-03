#!/usr/bin/env python3
"""Read-only probe of the local Starlink APIs.

Asks the dish (192.168.100.1:9200) and the Starlink router (192.168.1.1:9000)
what they report, so we know which dashboard features real data can support.
It only sends the requests listed in READ_ONLY and never changes a setting.

Usage:  .venv/bin/python scripts/probe_starlink.py
Writes a redacted copy of every response to scripts/probe_report.json.
"""

import ipaddress
import json
import re
import statistics
import time
from datetime import datetime, timezone
from pathlib import Path

import grpc
from google.protobuf.json_format import MessageToDict
from yagrc import reflector

DISH = "192.168.100.1:9200"
ROUTER = "192.168.1.1:9000"
TIMEOUT = 10

# The only requests this script ever sends. Each one just reads data.
READ_ONLY = {
    "dish": ["get_device_info", "get_status", "get_history", "dish_get_obstruction_map", "dish_get_config"],
    "router": ["get_device_info", "get_status", "wifi_get_clients", "wifi_get_status",
               "get_network_interfaces", "wifi_get_config"],
}
ALLOWED = {n for names in READ_ONLY.values() for n in names}
# Keep only the field names of these responses, never the values: they can hold Wi-Fi passwords.
SHAPE_ONLY = {"wifi_get_config"}

REPORT = Path(__file__).with_name("probe_report.json")

# ---------- redaction ----------
SECRET_WORDS = ("password", "psk", "passphrase", "secret", "token", "key")
COORD_KEYS = {"latitude", "longitude", "altitude", "lla", "ecef"}
ID_KEYS = {"id", "uuid", "serial", "serial_number"}


def mask_mac(v):
    parts = v.replace("-", ":").split(":")
    return ":".join(parts[:3] + ["xx"] * 3) if len(parts) == 6 else "[hidden]"


def mask_ip(v):
    try:
        ip = ipaddress.ip_address(v.split("/")[0])
    except ValueError:
        return v
    return v if (ip.is_private or ip.is_link_local or ip.is_loopback) else "[public address hidden]"


MAC_RE = re.compile(r"^[0-9A-Fa-f]{2}([:-][0-9A-Fa-f]{2}){5}$")
# Hardware IDs such as "Router-0100…" or "ut01000000-…" identify the kit and the account.
HW_ID_RE = re.compile(r"^(Router-[0-9A-Fa-f]{8,}|ut[0-9a-f]{8}-[0-9a-f-]{8,})$")


def redact(value, key=""):
    k = key.lower()
    if isinstance(value, dict):
        return {("[hardware id]" if HW_ID_RE.match(kk) else kk): redact(vv, kk) for kk, vv in value.items()}
    if isinstance(value, list):
        return [redact(v, key) for v in value]
    if any(w in k for w in SECRET_WORDS) or k in COORD_KEYS:
        return "[hidden]"
    if k in ID_KEYS or k.endswith("_id") or k.endswith("serial_number"):
        return "[hidden]"
    if isinstance(value, str):
        if "mac" in k or "bssid" in k or MAC_RE.match(value):  # radio MACs (BSSIDs) can geolocate a home
            return mask_mac(value) if value else value
        if HW_ID_RE.match(value):
            return "[hardware id]"
        return mask_ip(value)
    return value


def shape(value):
    if isinstance(value, dict):
        return {k: shape(v) for k, v in value.items()}
    if isinstance(value, list):
        return [shape(value[0])] if value else []
    return type(value).__name__


# ---------- gRPC ----------
def reflect(channel):
    client = reflector.GrpcReflectionClient()
    client.load_protocols(channel, symbols=["SpaceX.API.Device.Device"])
    return client.service_stub_class("SpaceX.API.Device.Device"), client.message_class("SpaceX.API.Device.Request")


def request_types(request_cls):
    return sorted(f.name for o in request_cls.DESCRIPTOR.oneofs for f in o.fields)


def to_dict(msg):
    return MessageToDict(msg, preserving_proto_field_name=True, always_print_fields_with_no_presence=True)


def ask(stub, request_cls, name):
    resp = stub.Handle(request_cls(**{name: {}}), timeout=TIMEOUT)
    for oneof in resp.DESCRIPTOR.oneofs:
        which = resp.WhichOneof(oneof.name)
        if which:
            return which, to_dict(getattr(resp, which))
    return None, to_dict(resp)


class Device:
    def __init__(self, label, target):
        self.label, self.target = label, target
        self.channel = grpc.insecure_channel(target)
        self.stub = self.request_cls = None
        self.out = {"target": target, "reachable": False, "reflection": None,
                    "requests_offered": [], "responses": {}, "errors": {}}

    def connect(self, fallback=None):
        try:
            grpc.channel_ready_future(self.channel).result(timeout=5)
        except grpc.FutureTimeoutError:
            self.out["errors"]["connect"] = "no answer within 5 s"
            return False
        self.out["reachable"] = True
        try:
            stub_cls, self.request_cls = reflect(self.channel)
            self.out["reflection"] = True
        except Exception as e:  # reflection off: borrow the dish's definitions (same API family)
            self.out["reflection"] = False
            self.out["errors"]["reflection"] = str(e) or type(e).__name__
            if not fallback:
                return False
            stub_cls, self.request_cls = fallback
        self.stub = stub_cls(self.channel)
        self.out["requests_offered"] = request_types(self.request_cls)
        return True

    def read(self, name):
        if name not in ALLOWED:
            raise ValueError(f"{name} is not a read-only request this probe may send")
        if name not in self.out["requests_offered"]:
            self.out["errors"][name] = "not in this device's API"
            return None
        try:
            which, data = ask(self.stub, self.request_cls, name)
        except grpc.RpcError as e:
            self.out["errors"][name] = f"{e.code().name}: {e.details()}"
            return None
        self.out["responses"][name] = {"field": which, "data": shape(data) if name in SHAPE_ONLY else redact(data)}
        return self.out["responses"][name]["data"]

    def close(self):
        self.channel.close()


# ---------- summary helpers ----------
def g(d, path, default=None):
    for p in path.split("."):
        if not isinstance(d, dict) or p not in d:
            return default
        d = d[p]
    return d


def num(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def flatten(d, prefix=""):
    out = {}
    if isinstance(d, dict):
        for k, v in d.items():
            out.update(flatten(v, f"{prefix}{k}."))
    elif isinstance(d, list):
        out[prefix[:-1]] = f"[{len(d)} items]"
    else:
        out[prefix[:-1]] = d
    return out


def dur(seconds):
    s = int(seconds or 0)
    d, h, m = s // 86400, s % 86400 // 3600, s % 3600 // 60
    return f"{d} d {h} h" if d else f"{h} h {m} min" if h else f"{m} min"


def mean(values):
    vals = [v for v in (num(x) for x in values or []) if v is not None]
    return statistics.fmean(vals) if vals else None


def head(title):
    print(f"\n=== {title} ===")


def line(label, value):
    if value not in (None, "", []):
        print(f"  {label:<24} {value}")


def offered(dev):
    names = dev.out["requests_offered"]
    reads = [n for n in names if "get" in n.split("_")]
    print(f"  API offers {len(names)} request types ({len(reads)} reads). Only the reads listed above were sent.")
    for n in ("speedtest", "wifi", "block", "pause", "limit", "qos", "schedule"):
        hits = [x for x in names if n in x]
        if hits:
            print(f"    {n:<10} {', '.join(hits)}")


def summarize_dish(dish):
    r = dish.out["responses"]
    head(f"Dish  {dish.target}")
    if not dish.out["reachable"]:
        print("  Not reachable:", dish.out["errors"])
        return
    st = g(r, "get_status.data", {})
    info = g(r, "get_device_info.data.device_info") or st.get("device_info", {})
    line("Hardware", info.get("hardware_version"))
    line("Software", info.get("software_version"))
    line("Generation", info.get("generation_number"))
    line("Uptime", dur(num(g(st, "device_state.uptime_s"))))
    lat, drop = num(st.get("pop_ping_latency_ms")), num(st.get("pop_ping_drop_rate"))
    line("Latency now", f"{lat:.0f} ms" if lat is not None else None)
    line("Ping drop now", f"{drop * 100:.1f} %" if drop is not None else None)
    down, up = num(st.get("downlink_throughput_bps")), num(st.get("uplink_throughput_bps"))
    if down is not None:
        line("Whole-home use now", f"down {down / 1e6:.1f} Mbps, up {(up or 0) / 1e6:.1f} Mbps")
    frac = num(g(st, "obstruction_stats.fraction_obstructed"))
    line("Sky obstructed", f"{frac * 100:.2f} %" if frac is not None else None)
    line("Obstructed right now", g(st, "obstruction_stats.currently_obstructed"))
    alerts = [k for k, v in (st.get("alerts") or {}).items() if v is True]
    line("Active alerts", ", ".join(alerts) or "none")
    if st.get("outage"):
        line("Current outage", st["outage"])
    line("Ethernet speed", f"{st['eth_speed_mbps']} Mbps" if st.get("eth_speed_mbps") else None)

    hist = g(r, "get_history.data", {})
    if hist:
        arrays = {k: len(v) for k, v in hist.items() if isinstance(v, list) and k != "outages"}
        n = max(arrays.values()) if arrays else 0
        line("History buffer", f"{n} samples, about {n / 60:.0f} min at 1 per second")
        line("History fields", ", ".join(sorted(arrays)))
        for key, label, scale, unit in (("pop_ping_latency_ms", "Avg latency (buffer)", 1, "ms"),
                                        ("downlink_throughput_bps", "Avg download (buffer)", 1e-6, "Mbps"),
                                        ("uplink_throughput_bps", "Avg upload (buffer)", 1e-6, "Mbps"),
                                        ("power_in", "Avg power (buffer)", 1, "W")):
            m = mean(hist.get(key))
            line(label, f"{m * scale:.1f} {unit}" if m is not None else None)
        outages = hist.get("outages") or []
        if outages:
            causes = {}
            for o in outages:
                causes[o.get("cause", "?")] = causes.get(o.get("cause", "?"), 0) + 1
            line("Outages in buffer", f"{len(outages)}: " + ", ".join(f"{c} x{k}" for c, k in causes.items()))
            for o in outages[-3:]:
                print(f"    {o.get('cause', '?'):<16} {num(o.get('duration_ns', 0)) / 1e9:.1f} s")
        else:
            line("Outages in buffer", "none")

    om = g(r, "dish_get_obstruction_map.data", {})
    if om:
        snr = [num(v) for v in om.get("snr", [])]
        seen = [v for v in snr if v is not None and v >= 0]
        line("Obstruction map", f"{om.get('num_rows')} x {om.get('num_cols')} cells, "
                                f"{len(seen) * 100 / max(1, len(snr)):.0f} % of the sky measured so far")

    cfg = flatten(g(r, "dish_get_config.data", {}))
    for k, v in cfg.items():
        if any(w in k for w in ("snow", "power_save", "sleep")):
            line(k.split(".")[-1], v)
    errs = {k: v for k, v in dish.out["errors"].items()}
    if errs:
        line("Errors", errs)
    offered(dish)


def summarize_router(router, clients_source):
    r = router.out["responses"]
    head(f"Router  {router.target}")
    if not router.out["reachable"]:
        print("  Not reachable:", router.out["errors"])
    else:
        info = g(r, "get_device_info.data.device_info", {})
        line("Hardware", info.get("hardware_version"))
        line("Software", info.get("software_version"))
        line("Reflection", "yes" if router.out["reflection"] else "no (used the dish's definitions)")

    clients = g(clients_source, "clients", None) if clients_source else None
    verdict = "unknown (no client list)"
    if clients is not None:
        print(f"\n  Wi-Fi/wired clients: {len(clients)}")
        fields = sorted({k for c in clients for k in flatten(c)})
        byte_fields = [f for f in fields if "bytes" in f]
        print("  Fields per client:", ", ".join(fields))
        print(f"\n  {'Name':<20} {'IP':<15} {'Iface':<13} {'Signal':>6} {'Down now':>9} {'Up now':>8} "
              f"{'rx bytes':>9} {'tx bytes':>9} {'dl_mb':>7} {'ul_mb':>6}")
        for c in clients:
            flat = flatten(c)
            mbps = lambda k: f"{num(flat.get(k)) or 0:.2f}"
            mb = lambda k: f"{(num(flat.get(k)) or 0) / 1e6:.0f}MB"
            print(f"  {str(c.get('given_name') or c.get('name') or '(no name)')[:20]:<20} {str(c.get('ip_address', ''))[:15]:<15} "
                  f"{str(c.get('iface', ''))[:13]:<13} {str(c.get('signal_strength', ''))[:6]:>6} "
                  f"{mbps('rx_stats.throughput_mbps_last_15s_avg'):>9} {mbps('tx_stats.throughput_mbps_last_15s_avg'):>8} "
                  f"{mb('rx_stats.bytes'):>9} {mb('tx_stats.bytes'):>9} {str(c.get('download_mb', '')):>7} {str(c.get('upload_mb', '')):>6}")
        nonzero = [b for b in byte_fields if any((num(flatten(c).get(b)) or 0) > 0 for c in clients)]
        if nonzero:
            verdict = f"YES. The router reports byte counters per device ({', '.join(nonzero)})."
        elif byte_fields:
            verdict = f"UNCLEAR. Byte fields exist ({', '.join(byte_fields)}) but every value is 0."
        else:
            verdict = "NO. The client list has no traffic counters."
    nets = g(r, "get_network_interfaces.data.network_interfaces", None)
    if nets:
        counted = [n.get("name", "?") for n in nets if any("bytes" in k for k in flatten(n))]
        line("Interface counters", f"{len(counted)} of {len(nets)} interfaces report byte counters")
    if router.out["reachable"]:
        errs = dict(router.out["errors"])
        if errs:
            line("Errors", errs)
        offered(router)
    return verdict


def main():
    started = time.time()
    dish, router = Device("dish", DISH), Device("router", ROUTER)
    if dish.connect():
        for name in READ_ONLY["dish"]:
            dish.read(name)
    fallback = (type(dish.stub), dish.request_cls) if dish.stub else None
    clients = None
    if router.connect(fallback=fallback):
        for name in READ_ONLY["router"]:
            data = router.read(name)
            if name == "wifi_get_clients" and data is not None:
                clients = data
    if clients is None and dish.stub:  # some setups answer client requests through the dish
        clients = dish.read("wifi_get_clients")

    summarize_dish(dish)
    verdict = summarize_router(router, clients)
    head("Verdict")
    print("  Per-device traffic:", verdict)

    REPORT.write_text(json.dumps({"generated_at": datetime.now(timezone.utc).isoformat(),
                                  "dish": dish.out, "router": router.out}, indent=2))
    print(f"\nRedacted report written to {REPORT.relative_to(Path.cwd()) if REPORT.is_relative_to(Path.cwd()) else REPORT}"
          f" ({REPORT.stat().st_size / 1024:.0f} KB) in {time.time() - started:.1f} s")
    dish.close()
    router.close()


if __name__ == "__main__":
    main()
