"""Tests the tripwire and the network-protection alerts: a real listener on spare ports, made-up router
replies for the isolation checks. It sends nothing to the dish or router and uses a throwaway database.

Usage:  .venv/bin/python scripts/test_tripwire.py
"""
import os
import socket
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
os.environ["ORBIT_TRIPWIRE_PORTS"] = "19445,19022,19389,16900"
from orbit import collector as C  # noqa: E402
from orbit.store import Store  # noqa: E402

failures = []


def check(cond, what):
    print(("  ok   " if cond else "  FAIL ") + what)
    if not cond:
        failures.append(what)


def knock(port):
    s = socket.create_connection(("127.0.0.1", port), timeout=2)
    s.close()


def titles(c, n=20):
    return [e["title"] for e in c.store.events(n)]


tmp = tempfile.mkdtemp()
c = C.Collector(Store(os.path.join(tmp, "t.db")))
c.networks = {"lan": {"guest": False, "isolated": False, "subnet": "192.168.1.1/24", "ssids": {"RF_2GHZ": "Home"}, "open": False, "enabled": True},
              "lan2": {"guest": True, "isolated": True, "subnet": "192.168.3.1/24", "ssids": {"RF_2GHZ": "Open"}, "open": True, "enabled": True}}
c.devices["77"] = {"id": "77", "router_name": "Galaxy-A15", "ip": "192.168.1.88", "online": True, "last_seen": time.time()}

print("the listener")
check(c.tripwire_on, "on by default")
c.tripwire.ignore_local = False  # the test knocks from this computer
c.tripwire.start()
check(len(c.tripwire.listening) == 4 and not c.tripwire.busy, "all four spare doors are open")

print("known devices on the main Wi-Fi are allowed")
c.devices["88"] = {"id": "88", "router_name": "Mom-iPhone", "ip": "192.168.1.60", "online": True, "acknowledged": 1, "last_seen": time.time()}
n = len(titles(c))
c._on_probe(time.time(), "192.168.1.60", 19445)
src = [p for p in c.state()["security"]["probes"] if p["ip"] == "192.168.1.60"]
check(len(titles(c)) == n and len(src) == 1 and src[0]["known"] and not src[0]["scan"], "a known device's knock raises nothing but is listed, marked known")
for port in (19022, 19389, 16900):
    c._on_probe(time.time(), "192.168.1.60", port)
check(len(titles(c)) == n and [p for p in c.state()["security"]["probes"] if p["ip"] == "192.168.1.60"][0]["scan"] is False, "even many doors from a known device is not called a scan")
c.devices["88"]["acknowledged"] = 0
c._on_probe(time.time(), "192.168.1.60", 19445)
check(any("Mom-iPhone tried to connect" in t for t in titles(c)), "the same device, once not known, is flagged")
c.devices["88"]["acknowledged"] = 1
src = [p for p in c.state()["security"]["probes"] if p["ip"] == "192.168.1.60"][0]
check(src["known"] and not src["scan"], "marking a device as known settles its earlier knocks too")
c.probe_alerts.clear()
c.probes.clear()

print("a first knock")
c._on_probe(time.time(), "192.168.1.88", 19445)
check(any("tried to connect to this Mac" in t and "Galaxy-A15" in t for t in titles(c)), "names the device")
n = len(titles(c))
c._on_probe(time.time(), "192.168.1.88", 19445)
check(len(titles(c)) == n, "a repeat knock inside ten minutes makes no second alert")

print("a scan")
c._on_probe(time.time(), "192.168.1.88", 19022)
check(not any("scanning" in t for t in titles(c)), "two doors is not yet a scan")
c._on_probe(time.time(), "192.168.1.88", 19389)
check(any("is scanning this Mac" in t for t in titles(c)), "three doors is a scan")
sec = c.state()["security"]
src = sec["probes"][0]
check(src["scan"] and src["tries"] == 4 and src["device"] == "77" and src["network"] == "main", "the list tells which device, how many tries, on which network")
check([p["port"] for p in src["ports"]][0] == 19445, "most-tried door first")

print("a stranger from outside the router's networks")
c._on_probe(time.time(), "10.9.9.9", 19445)
check(any("10.9.9.9 tried" in e["title"] and "isn’t on any of your Wi-Fi" in (e["detail"] or "") for e in c.store.events(5)), "flagged as impossible")

print("real connections reach the handler")
got = []
c.tripwire.on_probe = lambda ts, ip, port: got.append((ip, port))
knock(16900)
time.sleep(0.4)
check(got == [("127.0.0.1", 16900)], "a connection to a decoy is noted")
c.tripwire.ignore_local = True
knock(16900)
time.sleep(0.4)
check(len(got) == 1, "this computer's own connections are ignored")

print("turning it off and on")
c.set_tripwire({"on": False})
check(not c.tripwire.running and not c.state()["security"]["tripwire"]["listening"], "off: nothing listening")
try:
    knock(19445)
    check(False, "off: the door is closed")
except OSError:
    check(True, "off: the door is closed")
check(c.store.meta("tripwire") == "0", "the choice is saved")
c.set_tripwire({"on": True})
check(c.tripwire.running and len(c.tripwire.listening) == 4, "on again")
c.tripwire.stop()

print("network protection changes")
before = {k: dict(v) for k, v in c.networks.items()}
after = {k: dict(v) for k, v in before.items()}
n0 = len(titles(c, 50))
c._network_changes({}, after)
check(len(titles(c, 50)) == n0, "first reading: no alerts")
n = len(titles(c, 50))
c._network_changes(before, before)
check(len(titles(c, 50)) == n, "no change: no alerts")
after["lan2"]["isolated"] = False
c._network_changes(before, after)
check("Client isolation was turned off on Open" in titles(c, 50), "isolation off on a guest network")
check("no password" in (c.store.events(1)[0]["detail"] or ""), "and says strangers can join")
c._network_changes(after, before)
check("Client isolation is back on for Open" in titles(c, 50), "isolation back on")
after2 = {k: dict(v) for k, v in before.items()}
after2["lan"]["isolated"] = False
n = len(titles(c, 50))
c._network_changes(before, after2)
check(len(titles(c, 50)) == n, "the main network is meant to be open to its own devices: no alert")
after3 = {k: dict(v) for k, v in before.items()}
after3["lan3"] = {"guest": True, "isolated": True, "subnet": "192.168.4.1/24", "ssids": {"RF_2GHZ": "Cafe"}, "open": True, "enabled": True}
c._network_changes(before, after3)
check("A Wi-Fi network without a password appeared: Cafe" in titles(c, 50), "a new open network")

print()
print("FAILED: " + ", ".join(failures) if failures else "all passed")
sys.exit(1 if failures else 0)
