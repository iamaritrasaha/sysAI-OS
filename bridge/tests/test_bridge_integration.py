"""
Test bridge subprocess integration in Python
"""
from __future__ import annotations

import json
import os
import subprocess
import unittest
from pathlib import Path


class TestBridgeIntegration(unittest.TestCase):
    def setUp(self) -> None:
        self.bridge_script = Path(__file__).resolve().parent.parent / "sysai_bridge.py"
        self.project_root = Path(__file__).resolve().parent.parent.parent
        # SYSAI_PATH env var wins if set; otherwise fall back to the same
        # sibling-directory convention sysai_bridge.py's own discovery
        # tries (`<repo-parent>/Projects/sysai/src`) — a portable
        # structural guess, not one developer's absolute home directory.
        self.sysai_path = os.environ.get(
            "SYSAI_PATH", str(self.project_root.parent.parent / "Projects" / "sysai" / "src")
        )

    def test_bridge_ping_and_capabilities(self) -> None:
        env = dict(os.environ)
        env["SYSAI_PATH"] = self.sysai_path

        proc = subprocess.Popen(
            ["python3", str(self.bridge_script)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=env,
        )

        try:
            # 1. Read ready message
            ready_line = proc.stdout.readline()
            ready_data = json.loads(ready_line)
            self.assertEqual(ready_data.get("type"), "ready")
            self.assertEqual(ready_data.get("bridge_version"), "2.0.0")

            # 2. Ping request
            proc.stdin.write(json.dumps({"id": "req-1", "method": "ping", "params": {}}) + "\n")
            proc.stdin.flush()
            ping_resp = json.loads(proc.stdout.readline())
            self.assertTrue(ping_resp.get("ok"))
            self.assertEqual(ping_resp.get("result", {}).get("bridge_version"), "2.0.0")

            # 3. List capabilities request
            proc.stdin.write(json.dumps({"id": "req-2", "method": "list_capabilities", "params": {}}) + "\n")
            proc.stdin.flush()
            cap_resp = json.loads(proc.stdout.readline())
            self.assertTrue(cap_resp.get("ok"))
            caps = cap_resp.get("result", {}).get("capabilities", [])
            cap_ids = [c["id"] for c in caps]
            self.assertIn("filesystem.read", cap_ids)
            self.assertIn("filesystem.write", cap_ids)
            self.assertIn("shell.execute", cap_ids)
            self.assertIn("sysai.diagnostics", cap_ids)

            # 4. List workspace files request
            proc.stdin.write(json.dumps({"id": "req-3", "method": "list_workspace_files", "params": {"path": "."}}) + "\n")
            proc.stdin.flush()
            ws_resp = json.loads(proc.stdout.readline())
            self.assertTrue(ws_resp.get("ok"))
            self.assertIn("entries", ws_resp.get("result", {}))

        finally:
            proc.terminate()
            proc.wait(timeout=2)


if __name__ == "__main__":
    unittest.main()
