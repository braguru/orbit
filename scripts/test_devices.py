"""Tests device management (merging, allowances, bulk changes, hiding, forgetting) by feeding Orbit's
collector made-up router replies. It sends nothing to the dish or router, and uses a throwaway database.

Usage:  .venv/bin/python scripts/test_devices.py
"""
import json
import os
import sys
import tempfile
import time as real_time
import types
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from orbit import collector as C  # noqa: E402
from orbit.store import Store  # noqa: E402

# A clock the test controls: 15 October 2026, noon local time.
NOW = [real_time.mktime((2026, 10, 15, 12, 0, 0, 0, 0, -1))]
fake = types.SimpleNamespace(**{k: getattr(real_time, k) for k in dir(real_time) if not k.startswith("__")})
fake.time = lambda: NOW[0]
C.time = fake

failures = []


def check(cond, what):
    print(("  ok   " if cond else "  FAIL ") + what)
    if not cond:
        failures.append(what)


def client(cid, rx, tx, assoc, given="", name="", iface="RF_5GHZ", domain="lan", mac="AA:10:00:00:00:01", signal=-50):
    return {"client_id": cid, "mac_address": mac, "given_name": given, "name": name, "iface": iface, "domain": domain,
            "rx_stats": {"bytes": str(int(rx)), "rate_mbps": 100}, "tx_stats": {"bytes": str(int(tx)), "rate_mbps": 50},
            "associated_time_s": assoc, "signal_strength": signal, "ip_address": "192.168.1.50", "snr": 30,
            "channel_width": 80, "blocked": False}


def poll(c, clients, step=2):
    NOW[0] += step
    c._on_clients(clients, NOW[0])


def events(c, n=50):
    return [e["title"] + (" | " + e["detail"] if e.get("detail") else "") for e in c.store.events(n)]


tmp = tempfile.mkdtemp()
db = os.path.join(tmp, "test.db")
store = Store(db)
c = C.Collector(store)

print("first look and steady polling")
poll(c, [client(1001, 0, 0, 100, "My iPhone", "iPhone"), client(1002, 0, 0, 100, "Mom", "Galaxy-A05", domain="lan1", mac="DA:20:00:00:00:02")])
check(set(c.devices) == {"1001", "1002"}, "both devices known")
check(all(d["acknowledged"] for d in c.devices.values()), "first look: all acknowledged")
rx = {1001: 0, 1002: 0}
assoc = {1001: 100, 1002: 100}
for i in range(10):
    rx[1001] += 1e6
    rx[1002] += 2e6
    assoc[1001] += 2
    assoc[1002] += 2
    poll(c, [client(1001, rx[1001], rx[1001] / 10, assoc[1001], "My iPhone", "iPhone"),
             client(1002, rx[1002], rx[1002] / 10, assoc[1002], "Mom", "Galaxy-A05", domain="lan1", mac="DA:20:00:00:00:02")])
check(abs(sum(c.dev_today["1002"]) - 2.2e7) < 1, f"Mom counted 22 MB today ({sum(c.dev_today['1002']) / 1e6:.1f})")
c.store.update_device("1002", owner="family")
c.devices["1002"]["owner"] = "family"

print("Mom's phone joins the main Wi-Fi with a new address (new client_id 1003)")
rx3 = 0
for i in range(20):  # 40 s: the old entry goes offline after 30 s
    rx3 += 1e6
    rx[1001] += 1e6
    assoc[1001] += 2
    poll(c, [client(1001, rx[1001], 0, assoc[1001], "My iPhone", "iPhone"),
             client(1003, rx3, 0, 2 * (i + 1), "", "Galaxy-A05", mac="EE:30:00:00:00:03")])
check("1003" in c.devices and not c.devices["1003"]["acknowledged"], "1003 is a new, unacknowledged device")
joined = [e for e in events(c) if e.startswith("A new device joined")]
check(joined and "It may be Mom with a new address" in joined[0], f"join event hints at Mom: {joined[:1]}")
check(not c.devices["1002"]["online"], "the old entry went offline")
st = json.loads(c.state_json())
d3 = next(d for d in st["devices"] if d["id"] == "1003")
check(d3["maybe_same"] == "1002", f"state suggests 1003 is the same as 1002 ({d3['maybe_same']})")

print("merge them")
c.flush_lock.acquire()  # the merge must wait for a flush in progress
import threading  # noqa: E402
res = {}
th = threading.Thread(target=lambda: res.update(out=c.merge_devices("1003", {"other": "1002"})))
th.start()
real_time.sleep(0.2)
check(th.is_alive(), "merge waits while a minute of usage is being written")
c.flush_lock.release()
th.join(5)
out = res["out"]
check(out["id"] == "1003", "the connected entry keeps its id")
check(out["name"] == "Mom" and out["custom_name"] == "Mom", f"keeps the name you know it by ({out['name']})")
check(out["owner"] == "family", "keeps the owner")
check("1002" not in c.devices and c.aliases.get("1002") == "1003", "1002 is now an alias of 1003")
check(abs(sum(c.dev_today["1003"]) - (2.2e7 + 2e7)) < 1, f"today's usage combined ({sum(c.dev_today['1003']) / 1e6:.1f} MB)")
check(out["aliases"] and out["aliases"][0]["cid"] == "1002" and out["aliases"][0]["name"] == "Mom", f"aliases listed: {out['aliases']}")
check(not out["is_new"], "merged device is known")
c._flush_devices()
rows = c.store._all("SELECT id, SUM(down_bytes) d FROM device_days GROUP BY id")
check({r["id"] for r in rows} == {"1001", "1003"}, f"history moved to 1003: {rows}")
check(any(e.startswith("You merged") for e in events(c)), f"merge event: {[e for e in events(c) if 'merged' in e]}")
check(not c.store._all("SELECT * FROM devices WHERE id='1002'"), "1002 row deleted")
check(c.store._all("SELECT * FROM device_aliases WHERE cid='1002'")[0]["device"] == "1003", "alias row saved")
ev_dev = {e["device"] for e in c.store.events(100) if e["device"]}
check("1002" not in ev_dev, "activity entries point at the kept device")

print("she goes back to the guest Wi-Fi: 1002 again")
before = sum(c.dev_today["1003"])
joined_before = len([e for e in events(c, 200) if e.startswith("A new device")])
for i in range(20):
    rx[1002] += 3e6
    assoc[1002] = 2 * (i + 1)  # a new association
    poll(c, [client(1001, rx[1001], 0, assoc[1001], "My iPhone", "iPhone"),
             client(1002, rx[1002], 0, assoc[1002], "Mom", "Galaxy-A05", domain="lan1", mac="DA:20:00:00:00:02")])
check("1002" not in c.devices, "no new device for 1002")
check(len([e for e in events(c, 200) if e.startswith("A new device")]) == joined_before, "no 'new device joined' alert")
gained = sum(c.dev_today["1003"]) - before
check(abs(gained - rx[1002]) < 1, f"her guest traffic counts for 1003: {gained / 1e6:.1f} MB (counter {rx[1002] / 1e6:.1f} MB since association)")
d = c.devices["1003"]
check(d["online"] and d["domain"] == "lan1", "1003 online on the guest network")

print("both connections at once (like a laptop on Wi-Fi and a cable)")
for i in range(3):
    rx[1002] += 4e6
    rx3 += 4e6
    assoc[1002] += 2
    poll(c, [client(1001, rx[1001], 0, assoc[1001], "My iPhone", "iPhone"),
             client(1002, rx[1002], 0, assoc[1002], "Mom", "Galaxy-A05", domain="lan1", mac="DA:20:00:00:00:02"),
             client(1003, rx3, 0, 300 + 2 * i, "", "Galaxy-A05", mac="EE:30:00:00:00:03")])
d = c.devices["1003"]
check(d["domain"] == "lan", f"its own connection's details win ({d['domain']})")
st = json.loads(c.state_json())
d3 = next(x for x in st["devices"] if x["id"] == "1003")
check(d3["down_mbps"] > 25, f"live speed adds both connections ({d3['down_mbps']:.1f} Mbps)")

print("save, then restart Orbit")
c._flush_devices()
arow = c.store._all("SELECT * FROM device_aliases WHERE cid='1002'")[0]
check(arow["last_rx"] == rx[1002], f"alias counters saved ({arow['last_rx']})")
total_before = sum(c.dev_today["1003"])
c2 = C.Collector(Store(db))
check(c2.aliases.get("1002") == "1003", "aliases load after a restart")
NOW[0] += 60
rx[1002] += 5e6
assoc[1002] += 62
c2._on_clients([client(1002, rx[1002], 0, assoc[1002], "Mom", "Galaxy-A05", domain="lan1", mac="DA:20:00:00:00:02")], NOW[0])
check(abs(sum(c2.dev_today["1003"]) - total_before - 5e6) < 1,
      f"stayed connected while Orbit was off: counts just the 5 MB since ({(sum(c2.dev_today['1003']) - total_before) / 1e6:.1f})")
c = c2

print("separate")
alerts_before = len([e for e in events(c, 500) if e.startswith("A new device")])
c.separate_alias("1003", "1002")
check("1002" in c.devices and c.devices["1002"]["acknowledged"] and "1002" not in c.aliases, "1002 is its own known device again")
check(c.store._all("SELECT acknowledged FROM devices WHERE id='1002'")[0]["acknowledged"] == 1, "saved as known")
rx[1002] += 1e6
assoc[1002] += 2
poll(c, [client(1002, rx[1002], 0, assoc[1002], "Mom", "Galaxy-A05", domain="lan1", mac="DA:20:00:00:00:02")])
check(abs(sum(c.dev_today.get("1002", (0, 0))) - 1e6) < 1, "new traffic counts for 1002 now")
check(len([e for e in events(c, 500) if e.startswith("A new device")]) == alerts_before, "separating doesn't raise a new-device alert")

print("allowances")
try:
    c.update_device("1001", {"allowance": {"bytes": 5e5, "period": "day"}})
    check(False, "tiny allowance refused")
except ValueError as e:
    check(True, f"tiny allowance refused: {e}")
try:
    c.update_device("1001", {"allowance": {"bytes": True, "period": "day"}})
    check(False, "bool allowance refused")
except ValueError:
    check(True, "bool allowance refused")
used = sum(c.dev_today["1001"])
out = c.update_device("1001", {"allowance": {"bytes": used + 10e6, "period": "day"}})
check(out["allowance"]["used"] == used and out["allowance"]["level"] == 80, f"allowance shows usage, already past 80%: {out['allowance']}")
c._check_allowances(NOW[0])
check(not [e for e in events(c, 5) if "allowance" in e and "has used" in e], "no alert for what was already used when you set it")
for i in range(6):  # 12 MB more: over 100%
    rx[1001] += 2e6
    assoc[1001] += 2
    poll(c, [client(1001, rx[1001], 0, assoc[1001], "My iPhone", "iPhone")])
c._check_allowances(NOW[0])
alerts = [e for e in c.store.events(10) if e["cat"] == "usage"]
check(len(alerts) == 1 and "has used its daily allowance" in alerts[0]["title"] and alerts[0]["tone"] == "warn",
      f"100% alert: {[a['title'] + ' | ' + a['detail'] for a in alerts]}")
c._check_allowances(NOW[0])
check(len([e for e in c.store.events(10) if e["cat"] == "usage"]) == 1, "alerts once per period")
c3 = C.Collector(Store(db))
c3._check_allowances(NOW[0])
check(len([e for e in c3.store.events(10) if e["cat"] == "usage"]) == 1, "no repeat after a restart")

print("person allowance, per month")
c.store.add_device_days([("1001", "2026-10-03", 30e9, 1e9), ("1003", "2026-10-07", 9e9, 0), ("1001", "2026-09-30", 50e9, 0)])
c.update_device("1001", {"owner": "me"})
c.update_device("1003", {"owner": "me"})
c._month_cache = (None, {})
c.update_person("me", {"allowance": {"bytes": 50e9, "period": "month"}})
st = json.loads(c.state_json())
me = next(p for p in st["people"] if p["id"] == "me")
exp = 40e9 + sum(c.dev_today["1001"]) + sum(c.dev_today["1003"])
check(abs(me["allowance"]["used"] - exp) < 1, f"month usage: earlier days this month plus today ({me['allowance']['used'] / 1e9:.2f} GB)")
check(me["allowance"]["level"] == 80, "past 80% already when set")
c.store.add_device_days([("1003", "2026-10-08", 12e9, 0)])
NOW[0] += 301  # the month total refreshes every 5 minutes
poll(c, [client(1001, rx[1001], 0, assoc[1001] + 301, "My iPhone", "iPhone")], step=0)
c._check_allowances(NOW[0])
# The first person is named after whoever's account Orbit runs under; use that name.
me_name = next(p["name"] for p in json.loads(c.state_json())["people"] if p["id"] == "me")
pa = [e for e in c.store.events(10) if e["cat"] == "usage" and me_name in e["title"]]
check(pa and pa[0]["title"] == f"{me_name} has used their monthly allowance" and pa[0]["device"] is None,
      f"person alert: {[(e['title'], e['detail']) for e in pa]}")
c.update_person("me", {"allowance": None})
check(next(p for p in json.loads(c.state_json())["people"] if p["id"] == "me")["allowance"] is None, "allowance removed")

print("80% alert on its own")
c.update_device("1002", {"allowance": {"bytes": 20e6, "period": "day"}})
for i in range(9):  # 18 MB of 20
    rx[1002] += 2e6
    assoc[1002] += 2
    poll(c, [client(1002, rx[1002], 0, assoc[1002], "Mom", "Galaxy-A05", domain="lan1", mac="DA:20:00:00:00:02")])
c._check_allowances(NOW[0])
a80 = [e for e in c.store.events(5) if e["cat"] == "usage"][0]
check("% of its daily allowance" in a80["title"] and a80["tone"] is None, f"80% alert: {a80['title']} | {a80['detail']}")

print("bulk changes")
r = c.bulk_update({"changes": [{"id": "1001", "owner": "family"}, {"id": "1002", "owner": "family"}]})
check(r["changed"] == 2 and c.devices["1001"]["owner"] == "family", "two devices to Family")
check(c.store.events(1)[0]["title"] == "2 devices now belong to Family", c.store.events(1)[0]["title"])
r = c.bulk_update({"changes": [{"id": "1001", "hidden": True}, {"id": "1002", "hidden": True}]})
check(c.store.events(1)[0]["title"] == "You hid 2 devices", c.store.events(1)[0]["title"])
try:
    c.bulk_update({"changes": [{"id": "1001", "name": "x"}]})
    check(False, "bulk refuses names")
except ValueError as e:
    check(True, f"bulk refuses names: {e}")
try:
    c.bulk_update({"changes": [{"id": "1001", "owner": "nobody"}, {"id": "1002", "owner": "me"}]})
    check(False, "bulk refuses an unknown person")
except ValueError:
    check(c.devices["1002"]["owner"] == "family", "nothing changed when one change is bad")
c.bulk_update({"changes": [{"id": "1001", "hidden": False}, {"id": "1002", "hidden": False}]})

print("hidden devices: no comings and goings in the feed")
c.update_device("1001", {"hidden": True})
for i in range(20):  # 1001 drops off for 40 s
    rx[1002] += 1
    assoc[1002] += 2
    poll(c, [client(1002, rx[1002], 0, assoc[1002], "Mom", "Galaxy-A05", domain="lan1", mac="DA:20:00:00:00:02")])
check(not c.devices["1001"]["online"], "hidden device went offline")
check(not [e for e in events(c, 10) if "My iPhone disconnected" in e], "no 'disconnected' entry for a hidden device")

print("forget")
try:
    c.forget_devices({"ids": ["1001", "1002"]})
    check(False, "won't forget a connected device")
except ValueError as e:
    check("1001" in c.devices, f"won't forget a connected device: {e}")
c.merge_devices("1001", {"other": "1003"})  # 1003 (offline) into 1001
check(c.aliases.get("1003") == "1001", "1003 merged into 1001")
r = c.forget_devices({"ids": ["1001"]})
check("1001" not in c.devices and not c.aliases and not c.store.aliases(), "forgetting removes its merged connections too")

print("state and errors")
st = json.loads(c.state_json())
check(isinstance(st["devices"], list) and "allowance" in st["people"][0], "state has the new fields")
for bad, what in ((lambda: c.merge_devices("1002", {"other": "1002"}), "merge with itself"),
                  (lambda: c.update_device("1002", {"hidden": "yes"}), "hidden must be a bool"),
                  (lambda: c.update_device("1002", {"allowance": {"bytes": 1e9, "period": "week"}}), "period must be day or month")):
    try:
        bad()
        check(False, what)
    except ValueError as e:
        check(True, f"{what}: {e}")
try:
    c.separate_alias("1002", "999")
    check(False, "separate an unknown alias")
except KeyError:
    check(True, "separate an unknown alias: not found")
out = c.update_device("1002", {"notes": "Line one\r\n\r\n\r\n\tLine\x00 two  "})
check(out["notes"] == "Line one\n\nLine two", f"notes keep line breaks: {out['notes']!r}")

print()
print("FAILED:" if failures else "All passed.", *failures, sep="\n  ")
sys.exit(1 if failures else 0)
