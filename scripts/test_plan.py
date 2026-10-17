"""Tests saving the floor plan: what is kept, what is refused. It uses a throwaway database and sends nothing to the network.

Usage:  .venv/bin/python scripts/test_plan.py
"""
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


def refused(body):
    try:
        c.set_plan(body)
    except ValueError:
        return True
    return False


c = C.Collector(Store(os.path.join(tempfile.mkdtemp(), "t.db")))
GOOD = {"w": 12, "h": 8, "router": {"x": 2.5, "y": 6}, "walls": [{"id": "a", "a": [0.5, 0.5], "b": [11.5, 0.5], "mat": "brick"}],
        "rooms": [{"id": "r", "name": "  Kitchen ", "x": 3, "y": 2}], "devices": {"722785742": {"x": 3.4, "y": 6.4}}}

print("saving")
check(c.get_plan() == {"plan": None, "rev": 0}, "nothing saved at first")
res = c.set_plan(GOOD)
got = c.get_plan()
check(res["ok"] and got["rev"] == res["rev"] > 0, "saved, with a revision")
check(got["plan"]["walls"][0]["mat"] == "brick" and got["plan"]["rooms"][0]["name"] == "Kitchen", "walls kept, names trimmed")
check(got["plan"]["devices"]["722785742"] == {"x": 3.4, "y": 6.4}, "a device's spot kept")
check(c.state()["plan_rev"] == res["rev"], "the live state tells other windows the plan changed")

print("clamping and cleaning")
wild = dict(GOOD, walls=[{"id": "x" * 99, "a": [-5, 99], "b": [3, 3], "mat": "metal"}], devices={"12": {"x": 500, "y": -2}})
c.set_plan(wild)
p = c.get_plan()["plan"]
check(p["walls"][0]["a"] == [0, 8] and len(p["walls"][0]["id"]) == 20, "points are held inside the plan, ids are short")
check(p["devices"]["12"] == {"x": 12, "y": 0}, "a device can't sit outside the plan")
check(set(p) == {"v", "w", "h", "router", "walls", "rooms", "devices"}, "only known fields are stored")

print("refusing")
check(refused(dict(GOOD, w=1)), "a plan that is too small")
check(refused(dict(GOOD, router=None)), "no router")
check(refused(dict(GOOD, walls=[{"a": [0, 0], "b": [1, 1], "mat": "steel"}])), "an unknown material")
check(refused(dict(GOOD, walls=[{"a": [0, 0], "b": "x", "mat": "brick"}])), "a bad point")
check(refused(dict(GOOD, rooms=[{"name": "  ", "x": 1, "y": 1}])), "a room without a name")
check(refused(dict(GOOD, devices={"abc": {"x": 1, "y": 1}})), "a device id that isn't a number")
check(refused(dict(GOOD, walls=[{"a": [0, 0], "b": [1, 1], "mat": "brick"}] * 301)), "too many walls")
check(c.get_plan()["plan"]["walls"][0]["mat"] == "metal", "a refused save changes nothing")

print()
print("FAILED: " + ", ".join(failures) if failures else "all passed")
sys.exit(1 if failures else 0)
