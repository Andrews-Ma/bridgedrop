#!/usr/bin/env python3
"""Private BridgeDrop v1 relay. Opaque packets only; never receives pair keys.

This standard-library HTTP implementation is a development/reference service,
not an independently hardened public production server. See README.md.
"""

import argparse
import base64
import binascii
from contextlib import contextmanager
from dataclasses import dataclass
import hashlib
import hmac
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
import signal
import sqlite3
import threading
import time
from urllib.parse import parse_qs, urlsplit


VERSION = 1
UUID_RE = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
PAIR_RE = re.compile(r"^[0-9a-f]{32}$")
TOKEN_RE = re.compile(r"^[A-Za-z0-9_-]{32,256}$")
PACKET_FIELDS = {"pairID", "senderID", "receiverID", "requestID", "ciphertext"}
MAX_DEVICES = 4096
MAX_MESSAGES = 100000


class APIError(Exception):
    def __init__(self, status, code):
        super().__init__(code)
        self.status = status
        self.code = code


@dataclass(frozen=True)
class Config:
    token: str
    database: str = "bridgedrop-relay.sqlite3"
    host: str = "127.0.0.1"
    port: int = 47186
    max_body: int = 2 * 1024 * 1024
    ttl_seconds: float = 24 * 3600
    quota_bytes: int = 256 * 1024 * 1024
    presence_seconds: float = 90
    max_clients: int = 32
    requests_per_second: float = 60
    burst: int = 120
    max_wait: float = 25

    def validate(self):
        if not TOKEN_RE.fullmatch(self.token):
            raise ValueError("BRIDGEDROP_RELAY_TOKEN must contain 32-256 URL-safe characters; generate a new independent random token")
        if not 0 <= self.port <= 65535:
            raise ValueError("invalid port")
        if not 1 <= self.max_body <= 2 * 1024 * 1024:
            raise ValueError("body limit must be between 1 byte and 2 MiB")
        if not 0 < self.ttl_seconds <= 24 * 3600:
            raise ValueError("TTL must be positive and at most 24 hours")
        if not 1 <= self.quota_bytes <= 256 * 1024 * 1024:
            raise ValueError("quota must be between 1 byte and 256 MiB")
        if not 0 < self.presence_seconds <= 90:
            raise ValueError("presence expiry must be positive and at most 90 seconds")
        if not 1 <= self.max_clients <= 64:
            raise ValueError("concurrency must be between 1 and 64")
        if not 0 < self.requests_per_second <= 120 or not 1 <= self.burst <= 240:
            raise ValueError("invalid rate limit")
        if not 0 <= self.max_wait <= 25:
            raise ValueError("long poll wait must be at most 25 seconds")


def canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False).encode("utf-8")


def valid_uuid(value):
    return isinstance(value, str) and UUID_RE.fullmatch(value) is not None


def packet_json(packet, pair_id, sender_id, receiver_id, request_id):
    if not isinstance(packet, dict) or set(packet) != PACKET_FIELDS:
        raise APIError(400, "invalid_packet")
    if packet.get("pairID") != pair_id:
        raise APIError(400, "packet_room_mismatch")
    if (packet.get("senderID"), packet.get("receiverID"), packet.get("requestID")) != (sender_id, receiver_id, request_id):
        raise APIError(400, "packet_route_mismatch")
    ciphertext = packet.get("ciphertext")
    if not isinstance(ciphertext, str):
        raise APIError(400, "invalid_ciphertext")
    try:
        raw = base64.b64decode(ciphertext, validate=True)
    except (ValueError, binascii.Error):
        raise APIError(400, "invalid_ciphertext")
    # AES.GCM/ChaChaPoly combined representations include a 12-byte nonce
    # and a 16-byte authentication tag, even for an empty plaintext.
    if len(raw) < 28 or base64.b64encode(raw).decode("ascii") != ciphertext:
        raise APIError(400, "invalid_ciphertext")
    return canonical(packet)


class RelayStore:
    """Single SQLite writer with transactions and condition-based long polls."""

    def __init__(self, config, clock=time.time):
        config.validate()
        self.config = config
        self.clock = clock
        self.lock = threading.RLock()
        self.changed = threading.Condition(self.lock)
        self.closing = False
        if config.database != ":memory:":
            path = Path(config.database).expanduser().resolve()
            path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            descriptor = os.open(str(path), os.O_CREAT | os.O_RDWR, 0o600)
            os.close(descriptor)
            os.chmod(str(path), 0o600)
            config_path = str(path)
        else:
            config_path = ":memory:"
        self.db = sqlite3.connect(config_path, check_same_thread=False, isolation_level=None, timeout=5)
        self.db.row_factory = sqlite3.Row
        self.db.execute("PRAGMA auto_vacuum=INCREMENTAL")
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.execute("PRAGMA synchronous=FULL")
        self.db.execute("PRAGMA busy_timeout=5000")
        self.db.executescript("""
            CREATE TABLE IF NOT EXISTS messages (
                pair_id TEXT NOT NULL, request_id TEXT NOT NULL,
                sender_id TEXT NOT NULL, recipient_id TEXT NOT NULL,
                request_hash TEXT NOT NULL, request_packet BLOB,
                response_hash TEXT, response_packet BLOB,
                created_at REAL NOT NULL, bytes_used INTEGER NOT NULL,
                PRIMARY KEY (pair_id, request_id)
            );
            CREATE INDEX IF NOT EXISTS message_inbox
                ON messages(pair_id, recipient_id, response_hash, created_at);
            CREATE INDEX IF NOT EXISTS message_expiry ON messages(created_at);
            CREATE TABLE IF NOT EXISTS presence (
                pair_id TEXT NOT NULL, device_id TEXT NOT NULL,
                name TEXT NOT NULL, last_seen REAL NOT NULL,
                bytes_used INTEGER NOT NULL,
                PRIMARY KEY (pair_id, device_id)
            );
            CREATE INDEX IF NOT EXISTS presence_expiry ON presence(last_seen);
            CREATE TABLE IF NOT EXISTS usage (
                singleton INTEGER PRIMARY KEY CHECK(singleton=1),
                bytes_used INTEGER NOT NULL, messages INTEGER NOT NULL,
                devices INTEGER NOT NULL
            );
            INSERT OR IGNORE INTO usage SELECT 1,
                (SELECT COALESCE(SUM(bytes_used),0) FROM messages) +
                (SELECT COALESCE(SUM(bytes_used),0) FROM presence),
                (SELECT COUNT(*) FROM messages),
                (SELECT COUNT(*) FROM presence);
            PRAGMA user_version=1;
        """)
        if config_path != ":memory:":
            os.chmod(config_path, 0o600)
        with self.lock, self.transaction():
            self.prune()

    @contextmanager
    def transaction(self):
        if self.closing:
            raise APIError(503, "relay_is_stopping")
        self.db.execute("BEGIN IMMEDIATE")
        try:
            yield
            self.db.execute("COMMIT")
        except BaseException:
            self.db.execute("ROLLBACK")
            raise

    def close(self):
        with self.changed:
            if self.closing:
                return
            self.closing = True
            self.changed.notify_all()
            self.db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
            self.db.close()

    def maintain(self):
        with self.lock, self.transaction():
            self.prune()
        with self.lock:
            self.db.execute("PRAGMA wal_checkpoint(PASSIVE)")
            self.db.execute("PRAGMA incremental_vacuum(256)")

    def prune(self):
        now = self.clock()
        message_cutoff = now - self.config.ttl_seconds
        presence_cutoff = now - self.config.presence_seconds
        message_usage = self.db.execute("SELECT COALESCE(SUM(bytes_used),0),COUNT(*) FROM messages WHERE created_at <= ?", (message_cutoff,)).fetchone()
        presence_usage = self.db.execute("SELECT COALESCE(SUM(bytes_used),0),COUNT(*) FROM presence WHERE last_seen <= ?", (presence_cutoff,)).fetchone()
        if message_usage[1]:
            self.db.execute("DELETE FROM messages WHERE created_at <= ?", (message_cutoff,))
        if presence_usage[1]:
            self.db.execute("DELETE FROM presence WHERE last_seen <= ?", (presence_cutoff,))
        if message_usage[1] or presence_usage[1]:
            self.db.execute("UPDATE usage SET bytes_used=bytes_used-?,messages=messages-?,devices=devices-? WHERE singleton=1", (message_usage[0] + presence_usage[0], message_usage[1], presence_usage[1]))

    def adjust_usage(self, byte_delta, messages=0, devices=0):
        self.db.execute("UPDATE usage SET bytes_used=bytes_used+?,messages=messages+?,devices=devices+? WHERE singleton=1", (byte_delta, messages, devices))

    def check_quota(self, additional):
        used = self.db.execute("SELECT bytes_used FROM usage WHERE singleton=1").fetchone()[0]
        if used + additional > self.config.quota_bytes:
            raise APIError(507, "relay_storage_full")

    def set_presence(self, pair_id, body):
        if not isinstance(body, dict) or set(body) != {"deviceID", "name"}:
            raise APIError(400, "invalid_presence")
        device_id, name = body["deviceID"], body["name"]
        if not valid_uuid(device_id) or not isinstance(name, str) or not 1 <= len(name.encode("utf-8")) <= 256 or any(ord(c) < 32 for c in name):
            raise APIError(400, "invalid_presence")
        cost = 256 + len(name.encode("utf-8"))
        with self.changed, self.transaction():
            self.prune()
            existing = self.db.execute("SELECT bytes_used FROM presence WHERE pair_id=? AND device_id=?", (pair_id, device_id)).fetchone()
            if existing is None and self.db.execute("SELECT devices FROM usage WHERE singleton=1").fetchone()[0] >= MAX_DEVICES:
                raise APIError(507, "presence_capacity_reached")
            delta = cost - (existing[0] if existing else 0)
            self.check_quota(delta)
            self.db.execute("INSERT INTO presence VALUES(?,?,?,?,?) ON CONFLICT(pair_id,device_id) DO UPDATE SET name=excluded.name,last_seen=excluded.last_seen,bytes_used=excluded.bytes_used", (pair_id, device_id, name, self.clock(), cost))
            self.adjust_usage(delta, devices=0 if existing else 1)
            self.changed.notify_all()

    def get_presence(self, pair_id):
        with self.lock, self.transaction():
            self.prune()
            rows = self.db.execute("SELECT device_id,name,last_seen FROM presence WHERE pair_id=? ORDER BY device_id", (pair_id,)).fetchall()
        return {"devices": [{"deviceID": r[0], "name": r[1], "lastSeen": r[2]} for r in rows]}

    def post_message(self, pair_id, recipient_id, body):
        if not isinstance(body, dict) or set(body) != {"requestID", "senderID", "packet"}:
            raise APIError(400, "invalid_message")
        request_id, sender_id = body["requestID"], body["senderID"]
        if not valid_uuid(request_id) or not valid_uuid(sender_id) or sender_id == recipient_id:
            raise APIError(400, "invalid_message_ids")
        packet = packet_json(body["packet"], pair_id, sender_id, recipient_id, request_id)
        digest = hashlib.sha256(packet).hexdigest()
        cost = 512 + len(packet)
        with self.changed, self.transaction():
            self.prune()
            old = self.db.execute("SELECT request_hash FROM messages WHERE pair_id=? AND request_id=?", (pair_id, request_id)).fetchone()
            if old:
                if old[0] != digest:
                    raise APIError(409, "request_replay_mismatch")
                return
            if self.db.execute("SELECT messages FROM usage WHERE singleton=1").fetchone()[0] >= MAX_MESSAGES:
                raise APIError(507, "message_capacity_reached")
            self.check_quota(cost)
            self.db.execute("INSERT INTO messages VALUES(?,?,?,?,?,?,NULL,NULL,?,?)", (pair_id, request_id, sender_id, recipient_id, digest, packet, self.clock(), cost))
            self.adjust_usage(cost, messages=1)
            self.changed.notify_all()

    def get_messages(self, pair_id, recipient_id, wait):
        deadline = time.monotonic() + wait
        with self.changed:
            while True:
                with self.transaction():
                    self.prune()
                    rows = self.db.execute("SELECT request_id,sender_id,request_packet FROM messages WHERE pair_id=? AND recipient_id=? AND response_hash IS NULL ORDER BY created_at,rowid LIMIT 8", (pair_id, recipient_id)).fetchall()
                if rows:
                    return {"messages": [{"requestID": r[0], "senderID": r[1], "packet": json.loads(r[2])} for r in rows]}
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    return {"messages": []}
                self.changed.wait(timeout=remaining)

    def post_response(self, pair_id, request_id, body):
        if not isinstance(body, dict) or set(body) != {"packet"}:
            raise APIError(400, "invalid_response")
        with self.changed, self.transaction():
            self.prune()
            old = self.db.execute("SELECT sender_id,recipient_id,response_hash,bytes_used FROM messages WHERE pair_id=? AND request_id=?", (pair_id, request_id)).fetchone()
            if not old:
                raise APIError(404, "request_not_found")
            packet = packet_json(body["packet"], pair_id, old[1], old[0], request_id)
            digest = hashlib.sha256(packet).hexdigest()
            if old[2]:
                if old[2] != digest:
                    raise APIError(409, "response_replay_mismatch")
                return
            cost = 512 + len(packet)
            self.check_quota(cost - old[3])
            # A durable reply acknowledges the inbox item. Drop its bulky
            # ciphertext while retaining the original digest for safe retries.
            self.db.execute("UPDATE messages SET request_packet=NULL,response_hash=?,response_packet=?,bytes_used=? WHERE pair_id=? AND request_id=?", (digest, packet, cost, pair_id, request_id))
            self.adjust_usage(cost - old[3])
            self.changed.notify_all()

    def get_response(self, pair_id, request_id, wait):
        deadline = time.monotonic() + wait
        with self.changed:
            while True:
                with self.transaction():
                    self.prune()
                    row = self.db.execute("SELECT response_packet FROM messages WHERE pair_id=? AND request_id=?", (pair_id, request_id)).fetchone()
                if row is not None and row[0] is not None:
                    return {"packet": json.loads(row[0])}
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    return None
                self.changed.wait(timeout=remaining)


class RateLimiter:
    def __init__(self, rate, burst):
        self.rate, self.burst = rate, burst
        self.lock = threading.Lock()
        self.buckets = {}

    def allow(self, address):
        now = time.monotonic()
        with self.lock:
            if address not in self.buckets and len(self.buckets) >= 1024:
                self.buckets = {key: value for key, value in self.buckets.items() if now - value[1] < 120}
                if len(self.buckets) >= 1024:
                    return False
            tokens, last = self.buckets.get(address, (float(self.burst), now))
            tokens = min(float(self.burst), tokens + (now - last) * self.rate)
            allowed = tokens >= 1
            self.buckets[address] = (tokens - 1 if allowed else tokens, now)
            return allowed


class RelayHTTPServer(ThreadingHTTPServer):
    daemon_threads = True
    block_on_close = False
    allow_reuse_address = True

    def __init__(self, config, store=None):
        config.validate()
        self.config = config
        self.store = store if store is not None else RelayStore(config)
        self.slots = threading.BoundedSemaphore(config.max_clients)
        self.limiter = RateLimiter(config.requests_per_second, config.burst)
        self.next_maintenance = time.monotonic() + 30
        super().__init__((config.host, config.port), RelayHandler)

    def service_actions(self):
        if time.monotonic() >= self.next_maintenance:
            self.store.maintain()
            self.next_maintenance = time.monotonic() + 30

    def process_request(self, request, client_address):
        if not self.slots.acquire(blocking=False):
            try:
                request.settimeout(1)
                request.sendall(b'HTTP/1.1 503 Service Unavailable\r\nContent-Type: application/json\r\nContent-Length: 25\r\nConnection: close\r\nRetry-After: 1\r\n\r\n{"error":"relay_is_busy"}')
            except OSError:
                pass
            finally:
                self.close_request(request)
            return
        try:
            super().process_request(request, client_address)
        except BaseException:
            self.slots.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.slots.release()

    def handle_error(self, request, client_address):
        # Do not log request bodies, headers, packet data, or credentials.
        pass


class RelayHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "BridgeDropRelay/1"
    sys_version = ""

    def setup(self):
        super().setup()
        self.connection.settimeout(10)
        self.rate_accounted = False

    def log_message(self, format, *args):
        pass

    def send_json(self, status, body=None, extra=None):
        raw = canonical(body) if body is not None else b""
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Connection", "close")
        for name, value in (extra or {}).items():
            self.send_header(name, value)
        self.end_headers()
        self.close_connection = True
        if raw:
            self.wfile.write(raw)

    def authorize(self):
        values = self.headers.get_all("Authorization", [])
        if len(values) != 1 or not values[0].startswith("Bearer "):
            raise APIError(401, "unauthorized")
        offered = values[0][7:]
        try:
            valid = hmac.compare_digest(offered.encode("ascii"), self.server.config.token.encode("ascii"))
        except UnicodeEncodeError:
            valid = False
        if not valid:
            raise APIError(401, "unauthorized")

    def read_json(self):
        if self.headers.get("Transfer-Encoding") is not None:
            raise APIError(400, "unsupported_transfer_encoding")
        lengths = self.headers.get_all("Content-Length", [])
        if not lengths:
            raise APIError(411, "content_length_required")
        if len(lengths) != 1 or not re.fullmatch(r"[0-9]{1,10}", lengths[0]):
            raise APIError(400, "invalid_content_length")
        size = int(lengths[0])
        if size > self.server.config.max_body:
            raise APIError(413, "body_too_large")
        if self.headers.get_content_type() != "application/json":
            raise APIError(415, "json_required")
        raw = self.rfile.read(size)
        if len(raw) != size:
            raise APIError(400, "incomplete_body")
        def unique_object(pairs):
            result = {}
            for key, value in pairs:
                if key in result:
                    raise APIError(400, "duplicate_json_key")
                result[key] = value
            return result
        def invalid_constant(value):
            raise APIError(400, "invalid_json")
        try:
            return json.loads(raw.decode("utf-8"), object_pairs_hook=unique_object, parse_constant=invalid_constant)
        except (UnicodeDecodeError, json.JSONDecodeError, RecursionError):
            raise APIError(400, "invalid_json")

    def route(self):
        parts = urlsplit(self.path)
        if parts.scheme or parts.netloc or parts.fragment:
            raise APIError(400, "invalid_path")
        if parts.path == "/health" and self.command == "GET" and not parts.query:
            self.send_json(200, {"ok": True, "version": VERSION})
            return
        self.authorize()
        segments = parts.path.split("/")
        if len(segments) not in (5, 6) or segments[:3] != ["", "v1", "rooms"] or not PAIR_RE.fullmatch(segments[3]):
            raise APIError(404, "not_found")
        pair_id, operation = segments[3], segments[4]
        query = parse_qs(parts.query, keep_blank_values=True)
        wait = 0.0
        if parts.query:
            if self.command != "GET" or operation not in ("messages", "responses") or set(query) != {"wait"} or len(query["wait"]) != 1:
                raise APIError(400, "invalid_query")
            value = query["wait"][0]
            if not re.fullmatch(r"[0-9]{1,3}(\.[0-9]{1,3})?", value):
                raise APIError(400, "invalid_wait")
            wait = min(float(value), self.server.config.max_wait)
        if operation == "presence" and len(segments) == 5:
            if self.command == "POST":
                self.server.store.set_presence(pair_id, self.read_json())
                self.send_json(200, {"saved": True})
                return
            if self.command == "GET":
                self.send_json(200, self.server.store.get_presence(pair_id))
                return
        if len(segments) == 6 and valid_uuid(segments[5]):
            object_id = segments[5]
            if operation == "messages":
                if self.command == "POST":
                    self.server.store.post_message(pair_id, object_id, self.read_json())
                    self.send_json(202, {"accepted": True})
                    return
                if self.command == "GET":
                    self.send_json(200, self.server.store.get_messages(pair_id, object_id, wait))
                    return
            if operation == "responses":
                if self.command == "POST":
                    self.server.store.post_response(pair_id, object_id, self.read_json())
                    self.send_json(200, {"saved": True})
                    return
                if self.command == "GET":
                    response = self.server.store.get_response(pair_id, object_id, wait)
                    self.send_json(200 if response is not None else 204, response)
                    return
        raise APIError(404, "not_found")

    def dispatch(self):
        try:
            if not self.rate_accounted and not self.server.limiter.allow(self.client_address[0]):
                raise APIError(429, "rate_limited")
            self.rate_accounted = True
            self.route()
        except APIError as error:
            headers = {"WWW-Authenticate": "Bearer"} if error.status == 401 else {"Retry-After": "1"} if error.status == 429 else None
            self.send_json(error.status, {"error": error.code}, headers)
        except (OSError, TimeoutError):
            self.close_connection = True
        except Exception:
            self.send_json(500, {"error": "internal_error"})

    do_GET = dispatch
    do_POST = dispatch

    def handle_expect_100(self):
        # Gate the body before agreeing to receive it.
        try:
            if not self.server.limiter.allow(self.client_address[0]):
                raise APIError(429, "rate_limited")
            self.rate_accounted = True
            self.authorize()
            lengths = self.headers.get_all("Content-Length", [])
            if len(lengths) != 1 or not re.fullmatch(r"[0-9]{1,10}", lengths[0]):
                raise APIError(400, "invalid_content_length")
            if int(lengths[0]) > self.server.config.max_body:
                raise APIError(413, "body_too_large")
        except APIError as error:
            self.send_json(error.status, {"error": error.code})
            return False
        self.send_response_only(100)
        self.end_headers()
        return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=47186)
    parser.add_argument("--db", default="bridgedrop-relay.sqlite3")
    args = parser.parse_args()
    config = Config(token=os.environ.get("BRIDGEDROP_RELAY_TOKEN", ""), database=args.db, host=args.host, port=args.port)
    try:
        config.validate()
    except ValueError as error:
        parser.error(str(error))
    # Owner-only SQLite/WAL files and directories created by this process.
    os.umask(0o077)
    server = RelayHTTPServer(config)
    def stop(signum, frame):
        threading.Thread(target=server.shutdown, daemon=True).start()
    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)
    address = server.server_address
    print("BridgeDrop development relay listening on {}:{}; opaque packets, HTTP only.".format(*address), flush=True)
    try:
        server.serve_forever(poll_interval=0.2)
    finally:
        server.server_close()
        server.store.close()


if __name__ == "__main__":
    main()
