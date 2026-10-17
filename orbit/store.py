"""SQLite storage: dish readings, device usage, outages, people and the activity feed.

Times are Unix seconds in the database. "Days" are local calendar days on this machine.
"""

import os
import sqlite3
import threading
import time
from pathlib import Path

SCHEMA = """
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);

-- One row per second from the dish. online: 1 online, 0 the dish reported an outage, NULL dish unreachable.
CREATE TABLE IF NOT EXISTS dish_samples (
  ts INTEGER PRIMARY KEY, down_bps REAL, up_bps REAL, latency_ms REAL, drop_rate REAL, online INTEGER);

CREATE TABLE IF NOT EXISTS dish_minutes (
  ts INTEGER PRIMARY KEY, down_bytes REAL, up_bytes REAL, down_bps_avg REAL, down_bps_max REAL,
  up_bps_avg REAL, up_bps_max REAL, latency_avg REAL, latency_max REAL, drop_avg REAL,
  seconds INTEGER, offline_seconds INTEGER);

CREATE TABLE IF NOT EXISTS outages (start_ms INTEGER PRIMARY KEY, duration_s REAL, cause TEXT, did_switch INTEGER);

-- id is the router's client_id. The router only shows half of each MAC ("3A:51:DE:XX:XX:XX").
-- allowance_alerted is the period and level already reported, like "2026-10-02|80".
CREATE TABLE IF NOT EXISTS devices (
  id TEXT PRIMARY KEY, mac TEXT, first_seen INTEGER, last_seen INTEGER, router_name TEXT, hostname TEXT,
  custom_name TEXT, owner TEXT, type TEXT, acknowledged INTEGER DEFAULT 0, last_ip TEXT, last_iface TEXT,
  last_domain TEXT, last_rx REAL, last_tx REAL, last_assoc_s REAL, last_poll REAL,
  notes TEXT, hidden INTEGER DEFAULT 0, allowance_bytes REAL, allowance_period TEXT, allowance_alerted TEXT);

-- More client_ids for a device you merged: a phone that made up a new private address, or joined the guest
-- Wi-Fi, gets a new client_id from the router. Their traffic counts for `device`. The last_* columns are
-- that connection's own byte counters, like the ones in devices.
CREATE TABLE IF NOT EXISTS device_aliases (
  cid TEXT PRIMARY KEY, device TEXT, mac TEXT, router_name TEXT, hostname TEXT, first_seen INTEGER, last_seen INTEGER,
  last_rx REAL, last_tx REAL, last_assoc_s REAL, last_poll REAL);
CREATE INDEX IF NOT EXISTS device_aliases_device ON device_aliases(device);

CREATE TABLE IF NOT EXISTS device_minutes (
  id TEXT, ts INTEGER, down_bytes REAL, up_bytes REAL, down_mbps_max REAL, up_mbps_max REAL, signal_avg REAL,
  PRIMARY KEY (id, ts));
CREATE INDEX IF NOT EXISTS device_minutes_ts ON device_minutes(ts);

CREATE TABLE IF NOT EXISTS device_days (id TEXT, day TEXT, down_bytes REAL, up_bytes REAL, PRIMARY KEY (id, day));

CREATE TABLE IF NOT EXISTS people (
  id TEXT PRIMARY KEY, name TEXT, color TEXT, sort INTEGER,
  allowance_bytes REAL, allowance_period TEXT, allowance_alerted TEXT);

CREATE TABLE IF NOT EXISTS events (
  id INTEGER PRIMARY KEY AUTOINCREMENT, ts INTEGER, cat TEXT, icon TEXT, title TEXT, detail TEXT, device TEXT, tone TEXT);
CREATE INDEX IF NOT EXISTS events_ts ON events(ts);

-- Connections to the tripwire's decoy doors on this computer. ip is the visitor's address, device the
-- Orbit device it belonged to at the time (if any).
CREATE TABLE IF NOT EXISTS probes (
  id INTEGER PRIMARY KEY AUTOINCREMENT, ts INTEGER, ip TEXT, device TEXT, name TEXT, port INTEGER);
CREATE INDEX IF NOT EXISTS probes_ts ON probes(ts);

-- Speed tests run by the router. Speeds are the typical (median) and peak readings during the test.
CREATE TABLE IF NOT EXISTS speedtests (
  ts INTEGER PRIMARY KEY, down_mbps REAL, up_mbps REAL, down_peak REAL, up_peak REAL, latency_ms REAL, error TEXT);

-- Devices signed in to Orbit over the home network. Only a hash of each session token is kept.
CREATE TABLE IF NOT EXISTS sessions (token_hash TEXT PRIMARY KEY, created INTEGER, last_seen INTEGER, label TEXT);
"""

# Columns added after the first version. CREATE TABLE IF NOT EXISTS leaves an older table as it was.
ADDED_COLUMNS = {
    "devices": [("notes", "TEXT"), ("hidden", "INTEGER DEFAULT 0"), ("allowance_bytes", "REAL"),
                ("allowance_period", "TEXT"), ("allowance_alerted", "TEXT")],
    "probes": [("known", "INTEGER DEFAULT 0")],
    "people": [("allowance_bytes", "REAL"), ("allowance_period", "TEXT"), ("allowance_alerted", "TEXT")],
}

COLORS = ["blue", "orange", "green", "amber", "pink", "violet"]


def account_name():
    """The name this computer's account goes by, so a new Orbit greets its own person.

    Nothing personal is written into Orbit itself: each install takes the name from
    the account it runs under, and falls back to "Me" when there isn't one.
    """
    try:
        import pwd
        full = pwd.getpwuid(os.getuid()).pw_gecos.split(",")[0].strip()
        if full:
            return full
    except Exception:
        pass
    return "Me"


DEFAULT_PEOPLE = [("me", account_name(), "blue"), ("family", "Family", "orange"),
                  ("home", "Smart home", "amber"), ("guests", "Guests", "pink")]
ALLOWANCE_FIELDS = {"allowance_bytes", "allowance_period", "allowance_alerted"}
DEVICE_FIELDS = {"custom_name", "owner", "type", "acknowledged", "notes", "hidden"} | ALLOWANCE_FIELDS
PERSON_FIELDS = {"name"} | ALLOWANCE_FIELDS

KEEP_SAMPLES_S = 2 * 86400
KEEP_MINUTES_S = 400 * 86400
KEEP_DEVICE_MINUTES_S = 35 * 86400
KEEP_EVENTS = 5000
KEEP_PROBES_S = 30 * 86400


class Store:
    def __init__(self, path):
        Path(path).parent.mkdir(parents=True, exist_ok=True)
        self.db = sqlite3.connect(str(path), check_same_thread=False, isolation_level=None)
        self.db.row_factory = sqlite3.Row
        self.lock = threading.RLock()
        with self.lock:
            self.db.execute("PRAGMA journal_mode=WAL")
            self.db.execute("PRAGMA synchronous=NORMAL")
            self.db.executescript(SCHEMA)
            for table, columns in ADDED_COLUMNS.items():
                have = {r["name"] for r in self.db.execute(f"PRAGMA table_info({table})")}
                for name, decl in columns:
                    if name not in have:
                        self.db.execute(f"ALTER TABLE {table} ADD COLUMN {name} {decl}")
            if not self.db.execute("SELECT 1 FROM people LIMIT 1").fetchone():
                for i, (pid, name, color) in enumerate(DEFAULT_PEOPLE):
                    self.db.execute("INSERT INTO people (id, name, color, sort) VALUES (?,?,?,?)", (pid, name, color, i))

    # ---------- helpers ----------
    def _all(self, sql, args=()):
        with self.lock:
            return [dict(r) for r in self.db.execute(sql, args).fetchall()]

    def _one(self, sql, args=()):
        with self.lock:
            r = self.db.execute(sql, args).fetchone()
            return dict(r) if r else None

    def _run(self, sql, args=()):
        with self.lock:
            return self.db.execute(sql, args)

    def _many(self, sql, rows):
        if not rows:
            return
        with self.lock:
            self.db.execute("BEGIN")
            try:
                self.db.executemany(sql, rows)
                self.db.execute("COMMIT")
            except Exception:
                self.db.execute("ROLLBACK")
                raise

    def _tx(self, statements):
        """Run (sql, args) pairs as one transaction: all of them, or none."""
        with self.lock:
            self.db.execute("BEGIN")
            try:
                for sql, args in statements:
                    self.db.execute(sql, args)
                self.db.execute("COMMIT")
            except Exception:
                self.db.execute("ROLLBACK")
                raise

    def close(self):
        with self.lock:
            self.db.close()

    def meta(self, key, default=None):
        r = self._one("SELECT value FROM meta WHERE key=?", (key,))
        return r["value"] if r else default

    def set_meta(self, key, value):
        self._run("INSERT INTO meta VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", (key, str(value)))

    # ---------- dish ----------
    def add_samples(self, rows):
        """rows: (ts, down_bps, up_bps, latency_ms, drop_rate, online)"""
        self._many("INSERT OR IGNORE INTO dish_samples VALUES (?,?,?,?,?,?)", rows)

    def samples_since(self, ts):
        return self._all("SELECT * FROM dish_samples WHERE ts >= ? ORDER BY ts", (ts,))

    def rollup_minutes(self, start, end):
        """Summarize the per-second rows in [start, end) into one row per minute."""
        self._run("""INSERT OR REPLACE INTO dish_minutes
            SELECT (ts / 60) * 60, SUM(down_bps) / 8, SUM(up_bps) / 8, AVG(down_bps), MAX(down_bps),
                   AVG(up_bps), MAX(up_bps), AVG(latency_ms), MAX(latency_ms), AVG(drop_rate),
                   COUNT(*), SUM(online = 0)
            FROM dish_samples WHERE ts >= ? AND ts < ? GROUP BY ts / 60""", (start, end))

    def home_bytes(self, start, now):
        """Whole-home bytes (down, up) from start to now."""
        cur = int(now) // 60 * 60
        a = self._one("SELECT COALESCE(SUM(down_bytes), 0) d, COALESCE(SUM(up_bytes), 0) u "
                      "FROM dish_minutes WHERE ts >= ? AND ts < ?", (start, cur))
        b = self._one("SELECT COALESCE(SUM(down_bps), 0) / 8 d, COALESCE(SUM(up_bps), 0) / 8 u "
                      "FROM dish_samples WHERE ts >= ?", (max(start, cur),))
        return a["d"] + b["d"], a["u"] + b["u"]

    def home_buckets(self, start, end, unit):
        key = "(ts / 3600) * 3600" if unit == "hour" else "date(ts, 'unixepoch', 'localtime')"
        return self._all(f"SELECT {key} AS k, SUM(down_bytes) AS down, SUM(up_bytes) AS up "
                         f"FROM dish_minutes WHERE ts >= ? AND ts < ? GROUP BY k", (start, end))

    def speed_series(self, start, end, bucket):
        return self._all("""SELECT (ts / ?) * ? AS k, AVG(down_bps_avg) AS down, MAX(down_bps_max) AS down_max,
                   AVG(up_bps_avg) AS up, AVG(latency_avg) AS lat
            FROM dish_minutes WHERE ts >= ? AND ts < ? GROUP BY k ORDER BY k""", (bucket, bucket, start, end))

    def recorded_seconds(self, start, end):
        r = self._one("SELECT COALESCE(SUM(seconds), 0) s FROM dish_minutes WHERE ts >= ? AND ts < ?", (start, end))
        return r["s"]

    def fastest_down(self, since):
        r = self._one("SELECT MAX(down_bps_max) m FROM dish_minutes WHERE ts >= ?", (since,))
        return (r and r["m"]) or 0.0

    # ---------- outages ----------
    def add_outages(self, rows):
        """rows: (start_ms, duration_s, cause, did_switch). Returns the ones not seen before."""
        new = []
        with self.lock:
            for r in rows:
                old = self.db.execute("SELECT duration_s FROM outages WHERE start_ms=?", (r[0],)).fetchone()
                if old is None:
                    self.db.execute("INSERT INTO outages VALUES (?,?,?,?)", r)
                    new.append(r)
                elif r[1] > old[0]:
                    self.db.execute("UPDATE outages SET duration_s=? WHERE start_ms=?", (r[1], r[0]))
        return new

    def outages_since(self, start_ms):
        return self._all("SELECT * FROM outages WHERE start_ms >= ? ORDER BY start_ms", (start_ms,))

    def outage_stats(self, start_ms, end_ms):
        return self._one("SELECT COUNT(*) n, COALESCE(SUM(duration_s), 0) s FROM outages "
                         "WHERE start_ms >= ? AND start_ms < ?", (start_ms, end_ms))

    # ---------- devices ----------
    def devices(self):
        return {r["id"]: r for r in self._all("SELECT * FROM devices")}

    def add_device(self, key, mac, now, router_name, hostname, acknowledged):
        self._run("INSERT OR IGNORE INTO devices (id, mac, first_seen, last_seen, router_name, hostname, acknowledged) "
                  "VALUES (?,?,?,?,?,?,?)", (key, mac, int(now), int(now), router_name, hostname, acknowledged))

    def update_device(self, key, **fields):
        self.update_devices([(key, fields)])

    def update_devices(self, changes):
        """changes: [(id, {field: value})], saved together or not at all."""
        statements = []
        for key, fields in changes:
            bad = set(fields) - DEVICE_FIELDS
            if bad:
                raise ValueError(f"Can't change {', '.join(sorted(bad))}")
            cols = ", ".join(f"{k}=?" for k in fields)
            statements.append((f"UPDATE devices SET {cols} WHERE id=?", (*fields.values(), key)))
        self._tx(statements)

    def save_counters(self, rows):
        """rows: (rx, tx, assoc_s, poll_ts, last_seen, mac, router_name, hostname, ip, iface, domain, id)"""
        self._many("UPDATE devices SET last_rx=?, last_tx=?, last_assoc_s=?, last_poll=?, last_seen=?, mac=?, "
                   "router_name=?, hostname=?, last_ip=?, last_iface=?, last_domain=? WHERE id=?", rows)

    def delete_device(self, key):
        """Forget a device and the other client_ids merged into it. Its usage history stays."""
        self._tx([("DELETE FROM devices WHERE id=?", (key,)), ("DELETE FROM device_aliases WHERE device=?", (key,))])

    # ---------- merged devices ----------
    def aliases(self):
        return {r["cid"]: r for r in self._all("SELECT * FROM device_aliases")}

    def save_alias_counters(self, rows):
        """rows: (rx, tx, assoc_s, poll_ts, last_seen, mac, router_name, hostname, cid)"""
        self._many("UPDATE device_aliases SET last_rx=?, last_tx=?, last_assoc_s=?, last_poll=?, last_seen=?, mac=?, "
                   "router_name=?, hostname=? WHERE cid=?", rows)

    def merge_devices(self, keep, gone, fields):
        """Make `gone` part of `keep`: its usage history, activity and merged client_ids move over, and its own
        client_id becomes one of keep's. fields: keep's settings after the merge."""
        bad = set(fields) - DEVICE_FIELDS - {"first_seen"}
        if bad:
            raise ValueError(f"Can't change {', '.join(sorted(bad))}")
        cols = ", ".join(f"{k}=?" for k in fields)
        self._tx([
            ("""INSERT INTO device_minutes SELECT ?, ts, down_bytes, up_bytes, down_mbps_max, up_mbps_max, signal_avg
                FROM device_minutes WHERE id=? ON CONFLICT(id, ts) DO UPDATE SET
                down_bytes = down_bytes + excluded.down_bytes, up_bytes = up_bytes + excluded.up_bytes,
                down_mbps_max = MAX(down_mbps_max, excluded.down_mbps_max), up_mbps_max = MAX(up_mbps_max, excluded.up_mbps_max),
                signal_avg = COALESCE(signal_avg, excluded.signal_avg)""", (keep, gone)),
            ("DELETE FROM device_minutes WHERE id=?", (gone,)),
            ("""INSERT INTO device_days SELECT ?, day, down_bytes, up_bytes FROM device_days WHERE id=?
                ON CONFLICT(id, day) DO UPDATE SET
                down_bytes = down_bytes + excluded.down_bytes, up_bytes = up_bytes + excluded.up_bytes""", (keep, gone)),
            ("DELETE FROM device_days WHERE id=?", (gone,)),
            ("UPDATE events SET device=? WHERE device=?", (keep, gone)),
            ("UPDATE device_aliases SET device=? WHERE device=?", (keep, gone)),
            ("""INSERT OR REPLACE INTO device_aliases
                SELECT id, ?, mac, router_name, hostname, first_seen, last_seen, last_rx, last_tx, last_assoc_s, last_poll
                FROM devices WHERE id=?""", (keep, gone)),
            ("DELETE FROM devices WHERE id=?", (gone,)),
            (f"UPDATE devices SET {cols} WHERE id=?", (*fields.values(), keep)),
        ])

    def separate_alias(self, cid, now):
        """Undo part of a merge: the client_id becomes its own device again, with no history of its own."""
        self._tx([
            ("""INSERT OR IGNORE INTO devices (id, mac, first_seen, last_seen, router_name, hostname, acknowledged,
                    last_rx, last_tx, last_assoc_s, last_poll)
                SELECT cid, mac, COALESCE(first_seen, ?), last_seen, router_name, hostname, 1,
                       last_rx, last_tx, last_assoc_s, last_poll
                FROM device_aliases WHERE cid=?""", (int(now), cid)),
            ("DELETE FROM device_aliases WHERE cid=?", (cid,)),
        ])

    def add_device_minutes(self, rows):
        """rows: (id, ts, down_bytes, up_bytes, down_mbps_max, up_mbps_max, signal_avg)"""
        self._many("""INSERT INTO device_minutes VALUES (?,?,?,?,?,?,?) ON CONFLICT(id, ts) DO UPDATE SET
            down_bytes = down_bytes + excluded.down_bytes, up_bytes = up_bytes + excluded.up_bytes,
            down_mbps_max = MAX(down_mbps_max, excluded.down_mbps_max), up_mbps_max = MAX(up_mbps_max, excluded.up_mbps_max),
            signal_avg = COALESCE(excluded.signal_avg, signal_avg)""", rows)

    def add_device_days(self, rows):
        """rows: (id, day, down_bytes, up_bytes)"""
        self._many("""INSERT INTO device_days VALUES (?,?,?,?) ON CONFLICT(id, day) DO UPDATE SET
            down_bytes = down_bytes + excluded.down_bytes, up_bytes = up_bytes + excluded.up_bytes""", rows)

    def device_day_totals(self, day):
        return {r["id"]: (r["down_bytes"], r["up_bytes"]) for r in self._all("SELECT * FROM device_days WHERE day=?", (day,))}

    def device_days_for(self, key, first, last):
        rows = self._all("SELECT * FROM device_days WHERE id=? AND day >= ? AND day <= ?", (key, first, last))
        return {r["day"]: (r["down_bytes"], r["up_bytes"]) for r in rows}

    def device_usage_minutes(self, start, end):
        rows = self._all("SELECT id, SUM(down_bytes) d, SUM(up_bytes) u FROM device_minutes "
                         "WHERE ts >= ? AND ts < ? GROUP BY id", (start, end))
        return {r["id"]: [r["d"], r["u"]] for r in rows}

    def device_usage_days(self, first, last):
        rows = self._all("SELECT id, SUM(down_bytes) d, SUM(up_bytes) u FROM device_days "
                         "WHERE day >= ? AND day <= ? GROUP BY id", (first, last))
        return {r["id"]: [r["d"], r["u"]] for r in rows}

    # ---------- people ----------
    def people(self):
        return self._all("SELECT * FROM people ORDER BY sort, name")

    def add_person(self, name):
        with self.lock:
            people = self.people()
            used = [p["color"] for p in people]
            color = next((c for c in COLORS if c not in used), COLORS[len(people) % len(COLORS)])
            pid = "p" + format(time.time_ns() & 0xFFFFFFFFFF, "x")
            self.db.execute("INSERT INTO people (id, name, color, sort) VALUES (?,?,?,?)", (pid, name, color, len(people)))
        return {"id": pid, "name": name, "color": color, "sort": len(people)}

    def update_person(self, pid, **fields):
        bad = set(fields) - PERSON_FIELDS
        if bad:
            raise ValueError(f"Can't change {', '.join(sorted(bad))}")
        cols = ", ".join(f"{k}=?" for k in fields)
        self._run(f"UPDATE people SET {cols} WHERE id=?", (*fields.values(), pid))

    def delete_person(self, pid):
        with self.lock:
            self.db.execute("DELETE FROM people WHERE id=?", (pid,))
            self.db.execute("UPDATE devices SET owner=NULL WHERE owner=?", (pid,))  # their devices stay, unowned

    # ---------- activity ----------
    def add_event(self, ts, cat, icon, title, detail=None, device=None, tone=None):
        cur = self._run("INSERT INTO events (ts, cat, icon, title, detail, device, tone) VALUES (?,?,?,?,?,?,?)",
                        (int(ts), cat, icon, title, detail, device, tone))
        return cur.lastrowid

    def events(self, limit=50, cat=None):
        if cat:
            return self._all("SELECT * FROM events WHERE cat=? ORDER BY ts DESC, id DESC LIMIT ?", (cat, limit))
        return self._all("SELECT * FROM events ORDER BY ts DESC, id DESC LIMIT ?", (limit,))

    # ---------- tripwire ----------
    def add_probe(self, ts, ip, device, name, port, known=False):
        self._run("INSERT INTO probes (ts, ip, device, name, port, known) VALUES (?,?,?,?,?,?)",
                  (int(ts), ip, device, name, port, int(bool(known))))

    def probes_since(self, ts):
        return self._all("SELECT * FROM probes WHERE ts>=? ORDER BY ts", (int(ts),))

    # ---------- speed tests ----------
    def add_speedtest(self, ts, down, up, down_peak, up_peak, latency, error=None):
        self._run("INSERT OR REPLACE INTO speedtests VALUES (?,?,?,?,?,?,?)",
                  (int(ts), down, up, down_peak, up_peak, latency, error))

    def speedtests(self, limit=20):
        return self._all("SELECT * FROM speedtests ORDER BY ts DESC LIMIT ?", (limit,))

    # ---------- sign-in sessions ----------
    def add_session(self, token_hash, now, label):
        self._run("INSERT INTO sessions VALUES (?,?,?,?)", (token_hash, int(now), int(now), label))

    def session(self, token_hash):
        return self._one("SELECT * FROM sessions WHERE token_hash=?", (token_hash,))

    def touch_session(self, token_hash, now):
        self._run("UPDATE sessions SET last_seen=? WHERE token_hash=?", (int(now), token_hash))

    def delete_session(self, token_hash):
        self._run("DELETE FROM sessions WHERE token_hash=?", (token_hash,))

    def clear_sessions(self):
        self._run("DELETE FROM sessions")

    # ---------- housekeeping ----------
    def prune(self, now):
        with self.lock:
            self.db.execute("DELETE FROM dish_samples WHERE ts < ?", (now - KEEP_SAMPLES_S,))
            self.db.execute("DELETE FROM dish_minutes WHERE ts < ?", (now - KEEP_MINUTES_S,))
            self.db.execute("DELETE FROM device_minutes WHERE ts < ?", (now - KEEP_DEVICE_MINUTES_S,))
            self.db.execute("DELETE FROM outages WHERE start_ms < ?", (int((now - KEEP_MINUTES_S) * 1000),))
            self.db.execute("DELETE FROM events WHERE id NOT IN (SELECT id FROM events ORDER BY ts DESC LIMIT ?)",
                            (KEEP_EVENTS,))
            self.db.execute("DELETE FROM probes WHERE ts < ?", (now - KEEP_PROBES_S,))
            self.db.execute("DELETE FROM sessions WHERE last_seen < ?", (now - 365 * 86400,))
