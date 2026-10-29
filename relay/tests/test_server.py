"""Protocol/storage tests using real HTTP sockets and temporary SQLite files."""

import base64
from dataclasses import replace
import http.client
import json
from pathlib import Path
import secrets
import socket
import sys
import tempfile
import threading
import time
import unittest
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from server import APIError, Config, RelayHTTPServer, RelayStore  # noqa: E402


PAIR = "a" * 32
OTHER_PAIR = "b" * 32
SENDER = str(uuid.uuid4()).upper()
RECIPIENT = str(uuid.uuid4()).upper()


def new_id():
    return str(uuid.uuid4()).upper()


def packet(request_id, data=b"x" * 48, sender=SENDER, recipient=RECIPIENT, pair_id=PAIR):
    # Opaque synthetic bytes. CryptoKit authentication is tested by the Swift
    # core; the relay has no encryption keys and cannot decrypt these bytes.
    return {"pairID": pair_id, "senderID": sender, "receiverID": recipient,
            "requestID": request_id, "ciphertext": base64.b64encode(data).decode("ascii")}


def message(request_id, data=b"x" * 48):
    return {"requestID": request_id, "senderID": SENDER, "packet": packet(request_id, data)}


def response(request_id, data=b"r" * 48):
    return {"packet": packet(request_id, data, sender=RECIPIENT, recipient=SENDER)}


class RunningRelay:
    def __init__(self, config, clock=time.time):
        self.store = RelayStore(config, clock=clock)
        self.server = RelayHTTPServer(config, self.store)
        self.thread = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.02}, daemon=True)
        self.thread.start()
        self.port = self.server.server_address[1]
        self.token = config.token

    def close(self):
        self.server.shutdown()
        self.thread.join(timeout=2)
        self.server.server_close()
        self.store.close()

    def request(self, method, path, body=None, authorized=True, headers=None):
        raw = json.dumps(body).encode("utf-8") if body is not None else None
        values = {"Content-Type": "application/json"}
        if authorized:
            values["Authorization"] = "Bearer " + self.token
        values.update(headers or {})
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=3)
        try:
            connection.request(method, path, body=raw, headers=values)
            reply = connection.getresponse()
            status = reply.status
            result_headers = dict(reply.getheaders())
            result = reply.read()
            return status, json.loads(result) if result else None, result_headers
        finally:
            connection.close()


class HTTPTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.config = Config(token=secrets.token_urlsafe(32), database=str(Path(self.directory.name) / "relay.sqlite3"), port=0)
        self.relay = RunningRelay(self.config)
        self.base = "/v1/rooms/" + PAIR

    def tearDown(self):
        self.relay.close()
        self.directory.cleanup()

    def restart(self, **changes):
        self.relay.close()
        self.config = replace(self.config, **changes)
        self.relay = RunningRelay(self.config)

    def test_health_is_public_and_other_paths_require_auth(self):
        status, body, headers = self.relay.request("GET", "/health", authorized=False)
        self.assertEqual((status, body), (200, {"ok": True, "version": 1}))
        self.assertEqual(headers["Cache-Control"], "no-store")
        for path in (self.base + "/presence", "/register", "/v1/rooms"):
            status, body, _ = self.relay.request("POST", path, {}, authorized=False)
            self.assertEqual((status, body), (401, {"error": "unauthorized"}))
        status, _, _ = self.relay.request("GET", self.base + "/presence", headers={"Authorization": "Bearer " + secrets.token_urlsafe(32)})
        self.assertEqual(status, 401)
        self.assertEqual(self.relay.request("POST", "/register", {})[0], 404)

    def test_presence_persists_and_expires(self):
        now = [1000.0]
        self.relay.store.clock = lambda: now[0]
        value = {"deviceID": SENDER, "name": "Mac 书房"}
        self.assertEqual(self.relay.request("POST", self.base + "/presence", value)[:2], (200, {"saved": True}))
        self.assertEqual(self.relay.request("GET", self.base + "/presence")[1], {"devices": [{"deviceID": SENDER, "name": "Mac 书房", "lastSeen": 1000.0}]})
        self.assertEqual(self.relay.request("GET", "/v1/rooms/" + OTHER_PAIR + "/presence")[1], {"devices": []})
        # Use the same deterministic clock during database re-opening.
        self.relay.close()
        self.relay = RunningRelay(self.config, clock=lambda: now[0])
        self.assertEqual(len(self.relay.request("GET", self.base + "/presence")[1]["devices"]), 1)
        now[0] = 1090.0
        self.assertEqual(self.relay.request("GET", self.base + "/presence")[1], {"devices": []})

    def test_message_reads_do_not_ack_and_response_ack_is_durable(self):
        request_id = new_id()
        value = message(request_id)
        path = self.base + "/messages/" + RECIPIENT
        self.assertEqual(self.relay.request("POST", path, value)[:2], (202, {"accepted": True}))
        expected = {"messages": [value]}
        self.assertEqual(self.relay.request("GET", path)[1], expected)
        self.assertEqual(self.relay.request("GET", path)[1], expected)
        self.assertEqual(self.relay.request("GET", self.base + "/messages/" + SENDER)[1], {"messages": []})
        reply_path = self.base + "/responses/" + request_id
        self.assertEqual(self.relay.request("GET", reply_path)[:2], (204, None))
        self.restart()
        self.assertEqual(self.relay.request("GET", path)[1], expected)
        reply = response(request_id)
        self.assertEqual(self.relay.request("POST", reply_path, reply)[:2], (200, {"saved": True}))
        self.assertEqual(self.relay.request("GET", path)[1], {"messages": []})
        self.assertEqual(self.relay.request("GET", reply_path)[:2], (200, reply))
        self.restart()
        self.assertEqual(self.relay.request("GET", path)[1], {"messages": []})
        self.assertEqual(self.relay.request("GET", reply_path)[:2], (200, reply))
        # The request fingerprint still permits an exact retry after ack.
        self.assertEqual(self.relay.request("POST", path, value)[0], 202)
        with self.relay.store.lock:
            row = self.relay.store.db.execute("SELECT request_packet,request_hash FROM messages").fetchone()
        self.assertIsNone(row[0])
        self.assertEqual(len(row[1]), 64)

    def test_exact_duplicates_idempotent_but_changed_ciphertext_conflicts(self):
        request_id = new_id()
        path = self.base + "/messages/" + RECIPIENT
        original = message(request_id)
        self.assertEqual(self.relay.request("POST", path, original)[0], 202)
        self.assertEqual(self.relay.request("POST", path, original)[0], 202)
        self.assertEqual(len(self.relay.request("GET", path)[1]["messages"]), 1)
        modified = message(request_id, b"y" * 48)
        self.assertEqual(self.relay.request("POST", path, modified)[:2], (409, {"error": "request_replay_mismatch"}))
        reply_path = self.base + "/responses/" + request_id
        original_reply = response(request_id)
        self.assertEqual(self.relay.request("POST", reply_path, original_reply)[0], 200)
        self.assertEqual(self.relay.request("POST", reply_path, original_reply)[0], 200)
        self.assertEqual(self.relay.request("POST", reply_path, response(request_id, b"t" * 48))[:2], (409, {"error": "response_replay_mismatch"}))
        self.assertEqual(self.relay.request("POST", path, modified)[0], 409)
        self.assertEqual(self.relay.request("GET", reply_path)[1], original_reply)

    def test_packet_route_mismatches_rejected(self):
        path = self.base + "/messages/" + RECIPIENT
        for field, changed in (("pairID", OTHER_PAIR), ("senderID", RECIPIENT), ("receiverID", SENDER), ("requestID", new_id())):
            value = message(new_id())
            value["packet"][field] = changed
            self.assertEqual(self.relay.request("POST", path, value)[0], 400, field)
        request_id = new_id()
        self.assertEqual(self.relay.request("POST", path, message(request_id))[0], 202)
        reply_path = self.base + "/responses/" + request_id
        wrong_reply = {"packet": packet(request_id)}
        self.assertEqual(self.relay.request("POST", reply_path, wrong_reply)[0], 400)
        self.assertEqual(len(self.relay.request("GET", path)[1]["messages"]), 1)

    def test_concurrent_identical_retry_creates_one_durable_item(self):
        path = self.base + "/messages/" + RECIPIENT
        value = message(new_id())
        replies = []
        threads = [threading.Thread(target=lambda: replies.append(self.relay.request("POST", path, value))) for _ in range(12)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join(timeout=3)
            self.assertFalse(thread.is_alive())
        self.assertEqual([item[0] for item in replies], [202] * 12)
        self.assertEqual(self.relay.request("GET", path)[1], {"messages": [value]})
        self.restart()
        self.assertEqual(self.relay.request("GET", path)[1], {"messages": [value]})

    def test_response_quota_failure_keeps_original_pending(self):
        self.restart(quota_bytes=3000)
        request_id = new_id()
        path = self.base + "/messages/" + RECIPIENT
        value = message(request_id)
        self.assertEqual(self.relay.request("POST", path, value)[0], 202)
        reply_path = self.base + "/responses/" + request_id
        self.assertEqual(self.relay.request("POST", reply_path, response(request_id, b"q" * 3000))[0], 507)
        self.assertEqual(self.relay.request("GET", path)[1], {"messages": [value]})
        self.assertEqual(self.relay.request("GET", reply_path)[:2], (204, None))
        self.assertEqual(self.relay.request("POST", reply_path, response(request_id))[0], 200)

    def test_ids_json_ciphertext_and_query_validation(self):
        path = self.base + "/messages/" + RECIPIENT
        invalid = message(new_id())
        invalid["requestID"] = "../outside"
        self.assertEqual(self.relay.request("POST", path, invalid)[0], 400)
        for text in ("not base64", base64.b64encode(b"short").decode("ascii")):
            invalid = message(new_id())
            invalid["packet"]["ciphertext"] = text
            self.assertEqual(self.relay.request("POST", path, invalid)[0], 400)
        self.assertEqual(self.relay.request("GET", path + "?wait=nan")[0], 400)
        self.assertEqual(self.relay.request("GET", path + "?wait=1&wait=2")[0], 400)
        self.assertEqual(self.relay.request("GET", path + "?wait=-1")[0], 400)
        self.assertEqual(self.relay.request("GET", path + "?unknown=1")[0], 400)
        self.assertEqual(self.relay.request("POST", path + "?wait=1", message(new_id()))[0], 400)
        self.assertEqual(self.relay.request("GET", "/v1/rooms/" + PAIR.upper() + "/presence")[0], 404)
        self.assertEqual(self.relay.request("POST", self.base + "/presence", {"deviceID": SENDER, "name": "bad\nname"})[0], 400)
        self.assertEqual(self.relay.request("GET", self.base + "/responses/" + new_id())[:2], (204, None))
        self.assertEqual(self.relay.request("POST", self.base + "/responses/" + new_id(), response(new_id()))[0], 404)

    def test_message_batch_is_at_most_eight(self):
        path = self.base + "/messages/" + RECIPIENT
        for _ in range(11):
            self.assertEqual(self.relay.request("POST", path, message(new_id()))[0], 202)
        first = self.relay.request("GET", path)[1]["messages"]
        self.assertEqual(len(first), 8)
        for item in first:
            self.assertEqual(self.relay.request("POST", self.base + "/responses/" + item["requestID"], response(item["requestID"]))[0], 200)
        self.assertEqual(len(self.relay.request("GET", path)[1]["messages"]), 3)

    def test_long_poll_wakes_for_message_and_response(self):
        path = self.base + "/messages/" + RECIPIENT
        collected = []
        listener = threading.Thread(target=lambda: collected.append(self.relay.request("GET", path + "?wait=2")))
        listener.start()
        time.sleep(0.05)
        request_id = new_id()
        self.assertEqual(self.relay.request("POST", path, message(request_id))[0], 202)
        listener.join(timeout=1)
        self.assertFalse(listener.is_alive())
        self.assertEqual(collected[0][1]["messages"][0]["requestID"], request_id)
        reply_path = self.base + "/responses/" + request_id
        collected.clear()
        listener = threading.Thread(target=lambda: collected.append(self.relay.request("GET", reply_path + "?wait=2")))
        listener.start()
        time.sleep(0.05)
        self.assertEqual(self.relay.request("POST", reply_path, response(request_id))[0], 200)
        listener.join(timeout=1)
        self.assertFalse(listener.is_alive())
        self.assertEqual(collected[0][:2], (200, response(request_id)))

    def test_body_limit_and_non_json(self):
        self.restart(max_body=512)
        self.assertEqual(self.relay.request("POST", self.base + "/presence", {"padding": "x" * 600})[:2], (413, {"error": "body_too_large"}))
        self.assertEqual(self.relay.request("POST", self.base + "/presence", {}, headers={"Content-Type": "text/plain"})[0], 415)
        connection = http.client.HTTPConnection("127.0.0.1", self.relay.port, timeout=2)
        try:
            raw = b'{"deviceID":"duplicate","deviceID":"second","name":"test"}'
            connection.request("POST", self.base + "/presence", raw, {"Authorization": "Bearer " + self.relay.token, "Content-Type": "application/json"})
            reply = connection.getresponse()
            self.assertEqual(reply.status, 400)
            self.assertEqual(json.loads(reply.read()), {"error": "duplicate_json_key"})
        finally:
            connection.close()

    def test_default_two_mib_limit_rejects_before_reading_body(self):
        connection = http.client.HTTPConnection("127.0.0.1", self.relay.port, timeout=2)
        try:
            connection.putrequest("POST", self.base + "/presence")
            connection.putheader("Authorization", "Bearer " + self.relay.token)
            connection.putheader("Content-Type", "application/json")
            connection.putheader("Content-Length", str(2 * 1024 * 1024 + 1))
            connection.endheaders()
            reply = connection.getresponse()
            self.assertEqual(reply.status, 413)
            self.assertEqual(json.loads(reply.read()), {"error": "body_too_large"})
        finally:
            connection.close()

    def test_duplicate_authorization_header_is_rejected(self):
        connection = http.client.HTTPConnection("127.0.0.1", self.relay.port, timeout=2)
        try:
            connection.putrequest("GET", self.base + "/presence")
            connection.putheader("Authorization", "Bearer " + self.relay.token)
            connection.putheader("Authorization", "Bearer " + self.relay.token)
            connection.endheaders()
            reply = connection.getresponse()
            self.assertEqual(reply.status, 401)
            reply.read()
        finally:
            connection.close()

    def test_quota_freed_by_ack_and_ttl(self):
        self.restart(quota_bytes=5000)
        now = [time.time()]
        self.relay.store.clock = lambda: now[0]
        path = self.base + "/messages/" + RECIPIENT
        request_id = new_id()
        large_message = message(request_id, b"a" * 2200)
        self.assertEqual(self.relay.request("POST", path, large_message)[0], 202)
        self.assertEqual(self.relay.request("POST", path, message(new_id(), b"b" * 2200))[0], 507)
        self.assertEqual(self.relay.request("POST", self.base + "/responses/" + request_id, response(request_id))[0], 200)
        self.assertEqual(self.relay.request("POST", path, message(new_id(), b"c" * 2200))[0], 202)
        now[0] += self.config.ttl_seconds
        self.assertEqual(self.relay.request("GET", path)[1], {"messages": []})
        self.assertEqual(self.relay.request("GET", self.base + "/responses/" + request_id)[:2], (204, None))
        with self.relay.store.lock:
            self.assertEqual(tuple(self.relay.store.db.execute("SELECT bytes_used,messages,devices FROM usage").fetchone()), (0, 0, 0))

    def test_rate_limit_has_retry_header(self):
        self.restart(requests_per_second=0.001, burst=2)
        self.assertEqual(self.relay.request("GET", "/health", authorized=False)[0], 200)
        self.assertEqual(self.relay.request("GET", "/health", authorized=False)[0], 200)
        status, body, headers = self.relay.request("GET", "/health", authorized=False)
        self.assertEqual((status, body), (429, {"error": "rate_limited"}))
        self.assertEqual(headers["Retry-After"], "1")

    def test_concurrency_is_bounded(self):
        self.restart(max_clients=1)
        held = socket.create_connection(("127.0.0.1", self.relay.port), timeout=2)
        try:
            held.sendall(b"GET /health HTTP/1.1\r\n")
            deadline = time.monotonic() + 1
            while self.relay.server.slots._value != 0 and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertEqual(self.relay.server.slots._value, 0)
            status, body, headers = self.relay.request("GET", "/health", authorized=False)
            self.assertEqual((status, body), (503, {"error": "relay_is_busy"}))
            self.assertEqual(headers["Retry-After"], "1")
        finally:
            held.close()
        deadline = time.monotonic() + 1
        while self.relay.server.slots._value != 1 and time.monotonic() < deadline:
            time.sleep(0.01)
        self.assertEqual(self.relay.request("GET", "/health", authorized=False)[0], 200)


class ConfigurationTests(unittest.TestCase):
    def test_short_and_invalid_tokens_rejected(self):
        for token in ("", "short", "a" * 31, "a" * 32 + "\n", "secret token " * 3):
            with self.assertRaises(ValueError):
                Config(token=token).validate()
        Config(token=secrets.token_urlsafe(32)).validate()

    def test_unsafe_resource_limits_rejected(self):
        valid = Config(token=secrets.token_urlsafe(32))
        for changes in ({"max_clients": 0}, {"max_clients": 1000}, {"max_body": 3 * 1024 * 1024}, {"quota_bytes": 1024 * 1024 * 1024}, {"ttl_seconds": 48 * 3600}, {"max_wait": 26}):
            with self.assertRaises(ValueError):
                replace(valid, **changes).validate()


if __name__ == "__main__":
    unittest.main()
