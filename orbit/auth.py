"""Sign-in for phones and laptops on the home network (when Orbit runs with --lan).

This computer itself never needs to sign in. Other devices enter the access code once,
which Orbit prints in the terminal when it starts; a cookie then keeps them signed in.
Only a hash of each session token is stored, and wrong codes are rate-limited.
"""

import hashlib
import hmac
import os
import re
import secrets
import threading
import time
from http.cookies import CookieError, SimpleCookie

COOKIE = "orbit_session"
SESSION_DAYS = 365
MAX_FAILS = 5       # wrong codes allowed per address ...
FAIL_WINDOW_S = 600  # ... in this many seconds


def new_code():
    n = secrets.randbelow(10 ** 8)
    return f"{n // 10 ** 4:04d}-{n % 10 ** 4:04d}"


def _hash(token):
    return hashlib.sha256(token.encode()).hexdigest()


def is_local(ip):
    return ip in ("127.0.0.1", "::1") or ip.startswith("::ffff:127.")


def _token(cookie_header):
    if not cookie_header:
        return None
    try:
        c = SimpleCookie(cookie_header)
    except CookieError:
        return None
    return c[COOKIE].value if COOKIE in c else None


class Auth:
    def __init__(self, store, required):
        self.store = store
        self.required = required
        self.lock = threading.Lock()
        self.fails = {}
        self.code = store.meta("access_code")
        if required and not self.code:
            self.reset_code()
        # Development only: ORBIT_TEST_SIGNIN=1 makes this computer sign in too, to test the sign-in screen.
        self.local_exempt = os.environ.get("ORBIT_TEST_SIGNIN") != "1"

    def _local(self, ip):
        return self.local_exempt and is_local(ip)

    def reset_code(self):
        """A new access code. Every device that was signed in has to sign in again."""
        self.code = new_code()
        self.store.set_meta("access_code", self.code)
        self.store.clear_sessions()
        return self.code

    def _session(self, cookie_header):
        token = _token(cookie_header)
        if not token:
            return None
        h = _hash(token)
        row = self.store.session(h)
        if not row:
            return None
        now = time.time()
        if now - row["last_seen"] > SESSION_DAYS * 86400:
            self.store.delete_session(h)
            return None
        if now - row["last_seen"] > 3600:  # note activity at most hourly, not on every request
            self.store.touch_session(h, now)
        return row

    def allowed(self, ip, cookie_header):
        return not self.required or self._local(ip) or self._session(cookie_header) is not None

    def status(self, ip, cookie_header):
        return {"required": self.required, "local": self._local(ip), "signed_in": self.allowed(ip, cookie_header)}

    def login(self, ip, code, label):
        """Returns a session token, or raises ValueError (wrong code) or PermissionError (too many tries)."""
        now = time.time()
        with self.lock:
            recent = [t for t in self.fails.get(ip, []) if now - t < FAIL_WINDOW_S]
            if len(recent) >= MAX_FAILS:
                raise PermissionError("Too many wrong codes. Wait 10 minutes, then try again.")
            given = re.sub(r"\D", "", str(code or ""))
            if not (self.code and hmac.compare_digest(given, self.code.replace("-", ""))):
                self.fails[ip] = recent + [now]
                raise ValueError("That code isn’t right. It’s shown in the terminal where Orbit is running.")
            self.fails.pop(ip, None)
        token = secrets.token_urlsafe(32)
        self.store.add_session(_hash(token), now, str(label or "")[:80])
        return token

    def logout(self, cookie_header):
        token = _token(cookie_header)
        if token:
            self.store.delete_session(_hash(token))
