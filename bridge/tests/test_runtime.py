"""Focused protocol tests for the Phase 5 persistent runtime."""
from __future__ import annotations

import json
import os
import socket
import tempfile
import threading
import time
import unittest
from pathlib import Path

from sysai_os_runtime import MAX_MESSAGE_BYTES, Runtime


class RuntimeProtocolTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="sysai-runtime-test-")
        root = Path(self.temp.name)
        self.socket_path = root / "runtime.sock"
        self.runtime = Runtime(self.socket_path, root / "runtime.db")
        self.thread = threading.Thread(target=self.runtime.run, daemon=True)
        self.thread.start()
        deadline = time.time() + 3
        while not self.socket_path.exists() and time.time() < deadline:
            time.sleep(0.01)
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(3)
        self.sock.connect(str(self.socket_path))
        self.receive()

    def tearDown(self) -> None:
        try:
            self.sock.close()
        finally:
            self.runtime.stop_event.set()
            self.thread.join(timeout=3)
            self.temp.cleanup()

    def send(self, value: str | dict) -> None:
        raw = value if isinstance(value, str) else json.dumps(value)
        self.sock.sendall((raw + "\n").encode())

    def receive(self) -> dict:
        data = b""
        while b"\n" not in data:
            data += self.sock.recv(65536)
        return json.loads(data.split(b"\n", 1)[0])

    def test_status_unknown_malformed_and_replay(self) -> None:
        self.send({"id": "status", "method": "runtime.status", "params": {}})
        status = self.receive()
        self.assertTrue(status["ok"])
        self.assertEqual(status["result"]["protocol_version"], "1")

        self.send({"id": "unknown", "method": "does.not.exist", "params": {}})
        self.assertEqual(self.receive()["code"], "unknown_method")
        self.send("not json")
        self.assertEqual(self.receive()["code"], "parse_error")

        self.send({"id": "create", "method": "run.create", "params": {"run": {
            "id": "run-replay", "goal": "test", "status": "created",
            "created_at": "2026-01-01T00:00:00+00:00", "updated_at": "2026-01-01T00:00:00+00:00",
            "plan": [], "events": [], "outcome": "", "error_message": "",
        }}})
        self.assertTrue(self.receive()["ok"])
        self.runtime.emit_runtime_event({"type": "run.started", "run_id": "run-replay", "timestamp": "2026-01-01T00:00:01+00:00", "message": "started"})
        self.send({"id": "replay", "method": "events.replay", "params": {"run_id": "run-replay", "after_event_id": 0}})
        replay = self.receive()["result"]["events"]
        self.assertEqual(len(replay), 1)
        self.assertEqual(replay[0]["event_id"], 1)
        self.assertEqual(replay[0]["type"], "run.started")

    def test_message_limit_and_socket_permissions(self) -> None:
        self.send("x" * (MAX_MESSAGE_BYTES + 1))
        response = self.receive()
        self.assertEqual(response["code"], "message_too_large")
        self.assertEqual(os.stat(self.socket_path).st_mode & 0o777, 0o600)

    def test_reconnect_replays_events_while_client_is_disconnected(self) -> None:
        self.send({"id": "create-survival", "method": "run.create", "params": {"run": {
            "id": "run-survival", "goal": "real runtime lifecycle", "status": "running",
            "created_at": "2026-01-01T00:00:00+00:00", "updated_at": "2026-01-01T00:00:00+00:00",
        }}})
        self.assertTrue(self.receive()["ok"])
        self.sock.close()

        # This is the runtime process and scheduler/event store continuing
        # without a UI client. A new client receives the durable cursor.
        self.runtime.emit_runtime_event({
            "type": "terminal.output", "run_id": "run-survival",
            "timestamp": "2026-01-01T00:00:01+00:00", "text": "still running",
        })
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        client.settimeout(3)
        client.connect(str(self.socket_path))

        def receive(sock: socket.socket) -> dict:
            data = b""
            while b"\n" not in data:
                data += sock.recv(65536)
            return json.loads(data.split(b"\n", 1)[0])

        self.assertEqual(receive(client)["type"], "ready")
        client.sendall((json.dumps({
            "id": "reconnect-replay", "method": "events.replay",
            "params": {"run_id": "run-survival", "after_event_id": 0},
        }) + "\n").encode())
        response = receive(client)
        self.assertEqual(response["result"]["events"][0]["type"], "terminal.output")
        self.assertEqual(response["result"]["events"][0]["event_id"], 1)
        client.close()


if __name__ == "__main__":
    unittest.main()
