"""HTTP server: the web app, a small JSON API and a live stream of updates (Server-Sent Events).

Security for a dashboard on a home network:
  - Only answers requests addressed to this machine (localhost, a LAN IP or a .local name),
    which blocks DNS-rebinding attacks from websites.
  - Changes (POST/DELETE) must be JSON from the same origin, which blocks cross-site requests.
  - With --lan, other devices must sign in with the access code (see auth.py).
  - It never stores or serves Wi-Fi passwords.
"""

import ipaddress
import json
import re
import socket
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

from .auth import COOKIE, SESSION_DAYS

WEB = Path(__file__).resolve().parent.parent / "web"
MIME = {".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8", ".css": "text/css; charset=utf-8",
        ".svg": "image/svg+xml", ".png": "image/png", ".ico": "image/x-icon", ".json": "application/json",
        ".webmanifest": "application/manifest+json"}
CSP = ("default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; "
       "font-src 'self' https://fonts.gstatic.com; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'")
MAX_BODY = 16 * 1024
DEVICE = re.compile(r"/api/devices/([0-9]{1,20})")
DEVICE_USAGE = re.compile(r"/api/devices/([0-9]{1,20})/usage")
DEVICE_MERGE = re.compile(r"/api/devices/([0-9]{1,20})/merge")
DEVICE_ALIAS = re.compile(r"/api/devices/([0-9]{1,20})/aliases/([0-9]{1,20})")
PERSON = re.compile(r"/api/people/([A-Za-z0-9_-]{1,40})")


class Handler(BaseHTTPRequestHandler):
    server_version = "Orbit"
    sys_version = ""
    collector = None
    auth = None
    lan = False
    local_names = set()
    OPEN = {"/api/session", "/api/login", "/api/logout"}  # reachable before signing in

    def log_message(self, fmt, *args):  # keep the terminal quiet; errors are reported by the collector
        pass

    # ---------- guards ----------
    def _host_ok(self):
        name = (urlsplit("//" + (self.headers.get("Host") or "")).hostname or "").lower()
        if name in ("localhost", "127.0.0.1", "::1"):
            return True
        if not self.lan:
            return False
        if name.endswith(".local") or name in self.local_names:
            return True
        try:
            ip = ipaddress.ip_address(name)
        except ValueError:
            return False
        return ip.is_private or ip.is_link_local

    def _origin_ok(self):
        origin = self.headers.get("Origin")
        return origin is None or urlsplit(origin).netloc.lower() == (self.headers.get("Host") or "").lower()

    def _signed_in(self, path):
        return path in self.OPEN or not path.startswith("/api/") or self.auth.allowed(self.client_address[0], self.headers.get("Cookie"))

    # ---------- responses ----------
    def _send(self, code, body, ctype="application/json", cache="no-store", headers=None):
        data = body if isinstance(body, bytes) else json.dumps(body, separators=(",", ":")).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", cache)
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        if ctype.startswith("text/html"):
            self.send_header("Content-Security-Policy", CSP)
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    def _error(self, code, message):
        self._send(code, {"error": message})

    def _call(self, fn, *args):
        try:
            result = fn(*args)
        except KeyError:
            return self._error(404, "Not found")
        except ValueError as e:
            return self._error(400, str(e))
        self._send(200, result if result is not None else {"ok": True})

    def _body(self):
        if not (self.headers.get("Content-Type") or "").startswith("application/json"):
            raise ValueError("Send JSON")
        n = int(self.headers.get("Content-Length") or 0)
        if n > MAX_BODY:
            raise ValueError("Too much data")
        body = json.loads(self.rfile.read(n) or b"{}")
        if not isinstance(body, dict):
            raise ValueError("Send a JSON object")
        return body

    # ---------- routes ----------
    def do_GET(self):
        if not self._host_ok():
            return self._error(403, "Open Orbit using this computer's own address")
        url = urlsplit(self.path)
        path, q = url.path, parse_qs(url.query)
        c = self.collector
        if not self._signed_in(path):
            return self._error(401, "Sign in with the access code")
        if path == "/api/session":
            return self._send(200, self.auth.status(self.client_address[0], self.headers.get("Cookie")))
        if path == "/api/stream":
            return self._stream()
        if path == "/api/state":
            return self._send(200, c.state_json())
        if path == "/api/live":
            return self._send(200, c.live_points())
        if path == "/api/usage":
            return self._call(c.usage, (q.get("range") or ["24h"])[0])
        if path == "/api/events":
            return self._call(c.events_list, (q.get("cat") or [None])[0], (q.get("limit") or ["200"])[0])
        if path == "/api/obstruction":
            return self._call(c.obstruction_map)
        m = DEVICE_USAGE.fullmatch(path)
        if m:
            return self._call(c.device_usage, m.group(1))
        if path.startswith("/api/"):
            return self._error(404, "Not found")
        return self._static(path)

    do_HEAD = do_GET

    def do_POST(self):
        if not (self._host_ok() and self._origin_ok()):
            return self._error(403, "Not allowed")
        path, c = urlsplit(self.path).path, self.collector
        if not self._signed_in(path):
            return self._error(401, "Sign in with the access code")
        try:
            body = self._body()
        except (ValueError, json.JSONDecodeError) as e:
            return self._error(400, str(e))
        if path == "/api/login":
            return self._login(body)
        if path == "/api/logout":
            self.auth.logout(self.headers.get("Cookie"))
            return self._send(200, {"ok": True}, headers={"Set-Cookie": f"{COOKIE}=; Path=/; Max-Age=0; HttpOnly; SameSite=Strict"})
        if path == "/api/speedtest":
            return self._call(c.start_speedtest)
        if path == "/api/people":
            return self._call(c.add_person, body)
        if path == "/api/devices/bulk":
            return self._call(c.bulk_update, body)
        if path == "/api/devices/forget":
            return self._call(c.forget_devices, body)
        m = DEVICE.fullmatch(path)
        if m:
            return self._call(c.update_device, m.group(1), body)
        m = DEVICE_MERGE.fullmatch(path)
        if m:
            return self._call(c.merge_devices, m.group(1), body)
        m = PERSON.fullmatch(path)
        if m:
            return self._call(c.update_person, m.group(1), body)
        self._error(404, "Not found")

    def _login(self, body):
        try:
            token = self.auth.login(self.client_address[0], body.get("code"), self.headers.get("User-Agent"))
        except PermissionError as e:
            return self._error(429, str(e))
        except ValueError as e:
            return self._error(400, str(e))
        cookie = f"{COOKIE}={token}; Path=/; Max-Age={SESSION_DAYS * 86400}; HttpOnly; SameSite=Strict"
        self._send(200, {"ok": True}, headers={"Set-Cookie": cookie})

    def do_DELETE(self):
        if not (self._host_ok() and self._origin_ok()):
            return self._error(403, "Not allowed")
        path, c = urlsplit(self.path).path, self.collector
        if not self._signed_in(path):
            return self._error(401, "Sign in with the access code")
        m = DEVICE.fullmatch(path)
        if m:
            return self._call(c.forget_device, m.group(1))
        m = DEVICE_ALIAS.fullmatch(path)
        if m:
            return self._call(c.separate_alias, m.group(1), m.group(2))
        m = PERSON.fullmatch(path)
        if m:
            return self._call(c.delete_person, m.group(1))
        self._error(404, "Not found")

    def _stream(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Accel-Buffering", "no")
        self.end_headers()
        try:
            self.wfile.write(b"retry: 2000\n\n")
            while not self.server.stopping:
                self.wfile.write(b"data: " + self.collector.state_json() + b"\n\n")
                self.wfile.flush()
                time.sleep(1.1 - time.time() % 1)  # just after each new reading
        except OSError:  # the browser went away
            pass

    def _static(self, path):
        if path in ("", "/"):
            path = "/index.html"
        f = (WEB / path.lstrip("/")).resolve()
        if not f.is_relative_to(WEB) or not f.is_file():
            return self._error(404, "Not found")
        self._send(200, f.read_bytes(), MIME.get(f.suffix, "application/octet-stream"), cache="no-cache")


def local_names():
    host = socket.gethostname().lower()
    return {host, host.split(".")[0] + ".local", host + ".local"}


def lan_address():
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.connect(("192.168.1.1", 9))  # picks the interface on the home network; sends nothing
            return s.getsockname()[0]
    except OSError:
        return None


class OrbitServer(ThreadingHTTPServer):
    daemon_threads = True
    # A page load opens a dozen connections at once. The default queue of 5 makes the
    # operating system reset the rest, which shows up over Wi-Fi as files failing to load.
    request_queue_size = 128


def make_server(collector, auth, port, lan):
    Handler.collector = collector
    Handler.auth = auth
    Handler.lan = lan
    Handler.local_names = local_names()
    httpd = OrbitServer(("0.0.0.0" if lan else "127.0.0.1", port), Handler)
    httpd.stopping = False
    return httpd
