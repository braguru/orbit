"""Tests the router-settings alerts with made-up readings. It sends nothing to the dish or router and uses a throwaway database.

Usage:  .venv/bin/python scripts/test_router.py
"""
import copy
import os
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
os.environ["ORBIT_TRIPWIRE"] = "0"
from orbit import collector as C  # noqa: E402
from orbit.store import Store  # noqa: E402

failures = []


def check(cond, what):
    print(("  ok   " if cond else "  FAIL ") + what)
    if not cond:
        failures.append(what)


c = C.Collector(Store(os.path.join(tempfile.mkdtemp(), "t.db")))
titles = lambda: [e["title"] for e in c.store.events(50)]
S = {"dns": {"servers": [], "custom": False, "secure": False}, "bypass": False}
L = {"public_ip_age_s": 5000.0, "poe": {"on": True, "power_w": 11, "faults": 0}, "no_wan_link": False}

print("first reading")
c._settings_changes(None, S, None, L)
check(titles() == [], "no alerts on the first reading")

print("DNS and secure DNS")
b = copy.deepcopy(S); b["dns"]["servers"] = ["203.0.113.9"]; b["dns"]["custom"] = True
c._settings_changes(S, b, L, L)
check(any("DNS servers changed" in t for t in titles()), "new DNS servers are flagged")
check("203.0.113.9" in c.store.events(1)[0]["detail"], "and named")
c._settings_changes(S, S, L, L)
check(len(titles()) == 1, "no change, no alert")
b2 = copy.deepcopy(S); b2["dns"]["secure"] = True
c._settings_changes(S, b2, L, L)
check("Secure DNS was turned on" in titles(), "secure DNS on")

print("bypass, address, power and link")
b3 = copy.deepcopy(S); b3["bypass"] = True
c._settings_changes(S, b3, L, L)
check("Your router went into bypass mode" in titles(), "bypass mode")
l2 = copy.deepcopy(L); l2["public_ip_age_s"] = 20.0
c._settings_changes(S, S, L, l2)
check("Your public internet address changed" in titles(), "a new public address")
l3 = copy.deepcopy(L); l3["public_ip_age_s"] = 5030.0
n = len(titles())
c._settings_changes(S, S, L, l3)
check(len(titles()) == n, "the address getting older is not a change")
l4 = copy.deepcopy(L); l4["poe"]["faults"] = 2
c._settings_changes(S, S, L, l4)
check("The router's power feed reported a fault" in titles(), "a power fault")
l5 = copy.deepcopy(L); l5["no_wan_link"] = True
c._settings_changes(S, S, L, l5)
check("The router lost its link to the dish" in titles(), "lost link")

print()
print("FAILED: " + ", ".join(failures) if failures else "all passed")
sys.exit(1 if failures else 0)
