"""Access to the Starlink dish and router over their local gRPC API.

Both devices describe their own API through gRPC reflection, so no protocol
files are needed. Only the requests in READ_ONLY and ACTIONS can be sent.

What the Gen 3 router allowed when tested on 2026-10-02: every read, and starting its own
speed test. Settings changes (device names, block schedules) are refused with
PERMISSION_DENIED: only the Starlink app, with Starlink's signing keys, can make them.
"""

import threading

import grpc
from google.protobuf.json_format import MessageToDict
from yagrc import reflector

DISH = "192.168.100.1:9200"
ROUTER = "192.168.1.1:9000"
TIMEOUT = 4

# Requests that only read data. wifi_get_config also returns the Wi-Fi passwords; the collector
# keeps only each device's name and block schedule from it.
READ_ONLY = frozenset({"get_status", "get_history", "get_device_info", "dish_get_obstruction_map", "wifi_get_clients",
                       "wifi_get_config", "get_speedtest_status", "get_diagnostics"})
# Requests that make a device do something. Starting a speed test uses a few hundred MB of data.
ACTIONS = frozenset({"start_speedtest"})

# GPS time started on 1980-01-06 and is 18 leap seconds ahead of Unix time.
GPS_EPOCH = 315964800
GPS_LEAP_SECONDS = 18


def gps_ns_to_unix(ns):
    return int(ns) / 1e9 + GPS_EPOCH - GPS_LEAP_SECONDS


class Endpoint:
    """One gRPC endpoint (the dish or the router). Reconnects by itself after errors."""

    def __init__(self, target, borrow=None):
        self.target = target
        self.borrow = borrow  # another Endpoint whose API classes we can use if reflection fails
        self.channel = None
        self.stub = None
        self.stub_cls = None
        self.request_cls = None
        self.lock = threading.Lock()

    def _connect(self):
        self.channel = grpc.insecure_channel(self.target)
        grpc.channel_ready_future(self.channel).result(timeout=TIMEOUT)
        try:
            client = reflector.GrpcReflectionClient()
            client.load_protocols(self.channel, symbols=["SpaceX.API.Device.Device"])
            self.stub_cls = client.service_stub_class("SpaceX.API.Device.Device")
            self.request_cls = client.message_class("SpaceX.API.Device.Request")
        except Exception:
            if not (self.borrow and self.borrow.request_cls):
                raise
            self.stub_cls, self.request_cls = self.borrow.stub_cls, self.borrow.request_cls
        self.stub = self.stub_cls(self.channel)

    def read(self, name, timeout=TIMEOUT):
        """Send one read-only request, such as "get_status", and return the reply as a dict."""
        if name not in READ_ONLY:
            raise ValueError(f"{name} is not a read-only request")
        with self.lock:
            try:
                if self.stub is None:
                    self._connect()
                resp = self.stub.Handle(self.request_cls(**{name: {}}), timeout=timeout)
            except Exception:
                self._close()
                raise
        for oneof in resp.DESCRIPTOR.oneofs:
            which = resp.WhichOneof(oneof.name)
            if which:
                return MessageToDict(getattr(resp, which), preserving_proto_field_name=True,
                                     always_print_fields_with_no_presence=True)
        return {}

    def act(self, name, **fields):
        """Send one request from ACTIONS, such as start_speedtest."""
        if name not in ACTIONS:
            raise ValueError(f"{name} is not an allowed action")
        with self.lock:
            try:
                if self.stub is None:
                    self._connect()
                self.stub.Handle(self.request_cls(**{name: fields}), timeout=TIMEOUT)
            except Exception:
                self._close()
                raise

    def _close(self):
        if self.channel is not None:
            self.channel.close()
        self.channel = self.stub = None

    def close(self):
        with self.lock:
            self._close()
