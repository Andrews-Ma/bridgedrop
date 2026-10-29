#!/usr/bin/env python3
"""Run the native Swift client against a temporary local relay, without exposing keys."""
import os
from pathlib import Path
import secrets
import subprocess
import sys
import tempfile
import threading

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from relay.server import Config, RelayHTTPServer

with tempfile.TemporaryDirectory(prefix="bridgedrop-relay-check-") as directory:
    token = secrets.token_urlsafe(32)
    config = Config(token=token, database=str(Path(directory) / "check.sqlite3"), port=0)
    server = RelayHTTPServer(config)
    thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.02}, daemon=True)
    thread.start()
    environment = os.environ.copy()
    environment["BRIDGEDROP_RELAY_TOKEN"] = token
    try:
        subprocess.run(["swift", "run", "bridgedrop-check", "http://127.0.0.1:" + str(server.server_address[1])],
                       cwd=ROOT, env=environment, check=True, timeout=180)
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)
