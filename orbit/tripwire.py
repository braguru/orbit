"""A tripwire on this computer: decoy doors that nothing at home should ever knock on.

Orbit listens on a handful of ports that attackers and scanners try first (file sharing, remote
login, remote desktop). Nothing legitimate at home connects to them, so any connection is a probe.
It never reads what a visitor sends and never answers: it notes who knocked and hangs up.

What this can and can't see:
  - It sees completed connections to those doors on THIS computer, from devices on the same Wi-Fi.
  - It does not see half-open scans (a SYN scan never finishes the handshake), pings, or doors that
    belong to a real service (such as Remote Login, when it is switched on).
  - It sees nothing about other devices, and nothing from guest networks: the router isolates those.

macOS lets any program listen on a port below 1024, so no administrator rights are needed. If the macOS
firewall is on, it may ask once whether to allow incoming connections for Python. Say Allow.
"""

import ipaddress
import selectors
import socket
import threading
import time

# (port, what it is). Listed in the order people are most likely to try them.
DECOYS = [(445, "File sharing (SMB)"), (22, "Remote login (SSH)"), (3389, "Remote Desktop (RDP)"),
          (5900, "Screen sharing (VNC)"), (23, "Telnet"), (21, "File transfer (FTP)"), (139, "Windows file sharing"),
          (135, "Windows remote calls"), (1034, "Extra door"), (7765, "Extra door"), (4967, "Extra door")]
MAX_PER_SECOND = 200  # a flood is counted, not followed


def label_for(port, decoys=DECOYS):
    return dict(decoys).get(port) or f"Port {port}"


def local_addresses():
    """Every address this computer answers to, so it never reports itself."""
    out = {"127.0.0.1", "::1"}
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None):
            out.add(info[4][0])
    except OSError:
        pass
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.connect(("192.168.1.1", 9))  # picks the home interface; sends nothing
            out.add(s.getsockname()[0])
    except OSError:
        pass
    return out


class Tripwire:
    def __init__(self, on_probe, decoys=DECOYS, ignore_local=True):
        """on_probe(ts, ip, port) is called for each knock, from the tripwire's own thread."""
        self.on_probe = on_probe
        self.decoys = list(decoys)
        self.ignore_local = ignore_local
        self.listening, self.busy = [], []  # [port] opened, and [port] that something else already uses
        self.since = None
        self._sel = None
        self._thread = None
        self._stop = threading.Event()
        self._lock = threading.Lock()
        self._local = set()
        self._second, self._count, self.dropped = 0, 0, 0

    @property
    def running(self):
        return self._thread is not None and self._thread.is_alive()

    def start(self):
        with self._lock:
            if self.running:
                return
            self._stop.clear()
            self._sel = selectors.DefaultSelector()
            self.listening, self.busy = [], []
            self._local = local_addresses()
            for port, _ in self.decoys:
                s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                try:
                    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                    s.bind(("0.0.0.0", port))
                    s.listen(16)
                    s.setblocking(False)
                except OSError:
                    s.close()
                    self.busy.append(port)
                    continue
                self._sel.register(s, selectors.EVENT_READ, port)
                self.listening.append(port)
            self.since = time.time()
            self._thread = threading.Thread(target=self._loop, name="tripwire", daemon=True)
            self._thread.start()

    def stop(self):
        with self._lock:
            self._stop.set()
            t, self._thread = self._thread, None
        if t:
            t.join(timeout=3)
        sel, self._sel = self._sel, None
        if sel:
            for key in list(sel.get_map().values()):
                try:
                    sel.unregister(key.fileobj)
                    key.fileobj.close()
                except (OSError, KeyError, ValueError):
                    pass
            sel.close()
        self.listening, self.since = [], None

    def _loop(self):
        sel = self._sel
        while not self._stop.is_set():
            try:
                events = sel.select(timeout=0.5)
            except (OSError, ValueError):
                return
            for key, _ in events:
                try:
                    conn, addr = key.fileobj.accept()
                except OSError:
                    continue
                conn.close()  # hang up without reading or answering
                self._note(addr[0], key.data)

    def _note(self, ip, port):
        now = time.time()
        if int(now) != self._second:
            self._second, self._count = int(now), 0
        self._count += 1
        if self._count > MAX_PER_SECOND:
            self.dropped += 1
            return
        if ip.startswith("::ffff:"):
            ip = ip[7:]
        if self.ignore_local and (ip in self._local or ipaddress.ip_address(ip).is_loopback):
            return
        try:
            self.on_probe(now, ip, port)
        except Exception:  # the tripwire must never stop watching because of a bug in a handler
            pass
