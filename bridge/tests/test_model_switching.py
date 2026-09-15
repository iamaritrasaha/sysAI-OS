"""
Test Model Switching, Discovery, Availability, and Isolation in SysAI OS Bridge
"""
from __future__ import annotations

import json
import os
import subprocess
import unittest
from pathlib import Path


class TestModelSwitching(unittest.TestCase):
    def setUp(self) -> None:
        self.bridge_script = Path(__file__).resolve().parent.parent / "sysai_bridge.py"
        project_root = Path(__file__).resolve().parent.parent.parent
        # SYSAI_PATH env var wins if set; otherwise the same portable
        # sibling-directory guess sysai_bridge.py's own discovery tries.
        self.sysai_path = os.environ.get(
            "SYSAI_PATH", str(project_root.parent.parent / "Projects" / "sysai" / "src")
        )
        self.env = dict(os.environ)
        self.env["SYSAI_PATH"] = self.sysai_path

    def _start_bridge(self) -> subprocess.Popen:
        proc = subprocess.Popen(
            ["python3", str(self.bridge_script)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=self.env,
        )
        ready_line = proc.stdout.readline()
        ready_data = json.loads(ready_line)
        self.assertEqual(ready_data.get("type"), "ready")
        return proc

    def test_list_providers_and_models(self) -> None:
        proc = self._start_bridge()
        try:
            # 1. list_providers
            proc.stdin.write(json.dumps({"id": "req-p", "method": "list_providers", "params": {}}) + "\n")
            proc.stdin.flush()
            p_resp = json.loads(proc.stdout.readline())
            self.assertTrue(p_resp.get("ok"), f"list_providers failed: {p_resp}")
            providers = p_resp.get("result", {}).get("providers", [])
            provider_ids = [p["id"] for p in providers]
            self.assertIn("ollama", provider_ids)
            self.assertIn("ollama-cloud", provider_ids)
            self.assertIn("remote-ollama", provider_ids)
            self.assertIn("openai-compatible", provider_ids)

            # 2. list_models
            proc.stdin.write(json.dumps({"id": "req-m", "method": "list_models", "params": {}}) + "\n")
            proc.stdin.flush()
            m_resp = json.loads(proc.stdout.readline())
            self.assertTrue(m_resp.get("ok"), f"list_models failed: {m_resp}")
            models = m_resp.get("result", {}).get("models", [])
            self.assertTrue(len(models) > 0, "No models discovered")
            for m in models:
                self.assertIn("id", m)
                self.assertIn("name", m)
                self.assertIn("provider", m)
                self.assertIn("available", m)

            # 3. check_model_availability for nonexistent model
            proc.stdin.write(json.dumps({
                "id": "req-chk-bad",
                "method": "check_model_availability",
                "params": {"provider": "ollama", "model": "definitely-not-installed-xyz-123"}
            }) + "\n")
            proc.stdin.flush()
            chk_resp = json.loads(proc.stdout.readline())
            self.assertTrue(chk_resp.get("ok"))
            self.assertFalse(chk_resp.get("result", {}).get("available"))
            self.assertIn("not installed", chk_resp.get("result", {}).get("reason", ""))
        finally:
            proc.terminate()
            proc.wait(timeout=3)

    def test_run_rejection_for_unavailable_model(self) -> None:
        proc = self._start_bridge()
        try:
            # Attempt to execute a run with an unavailable model
            proc.stdin.write(json.dumps({
                "id": "run-fail-req",
                "method": "execute_run",
                "params": {
                    "run_id": "test-run-unavailable",
                    "goal": "Inspect environment",
                    "provider": "ollama",
                    "model": "nonexistent-model-xyz",
                }
            }) + "\n")
            proc.stdin.flush()

            saw_unavailable_event = False
            saw_run_failed = False

            while True:
                line = proc.stdout.readline()
                if not line:
                    break
                data = json.loads(line)
                if data.get("done") is True:
                    self.assertEqual(data.get("result", {}).get("status"), "failed")
                    break
                event = data.get("event", {})
                if event.get("type") == "model.unavailable":
                    saw_unavailable_event = True
                    self.assertEqual(event.get("model"), "nonexistent-model-xyz")
                    self.assertIn("not installed", event.get("reason", ""))
                elif event.get("type") == "run.failed":
                    saw_run_failed = True

            self.assertTrue(saw_unavailable_event, "Did not emit model.unavailable event")
            self.assertTrue(saw_run_failed, "Did not emit run.failed event")
        finally:
            proc.terminate()
            proc.wait(timeout=3)

    def test_run_execution_with_model_override_and_isolation(self) -> None:
        """
        Verify that execute_run emits model.selected, executes with isolated run_config,
        and does NOT mutate base SysAI configuration.
        """
        import sys
        if self.sysai_path not in sys.path:
            sys.path.insert(0, self.sysai_path)
        from sysai.config import load_config
        base_cfg_before = load_config()

        proc = self._start_bridge()
        try:
            # Query an available model from list_models
            proc.stdin.write(json.dumps({"id": "req-get-m", "method": "list_models", "params": {}}) + "\n")
            proc.stdin.flush()
            models = json.loads(proc.stdout.readline()).get("result", {}).get("models", [])
            available_models = [m for m in models if m.get("available")]
            if not available_models:
                self.skipTest("No available models found in Ollama to run execution test")

            chosen = available_models[0]
            chosen_name = chosen["name"]
            chosen_provider = chosen["provider"]

            proc.stdin.write(json.dumps({
                "id": "run-avail-req",
                "method": "execute_run",
                "params": {
                    "run_id": "test-run-avail",
                    "goal": "Inspect SysAI configuration",
                    "provider": chosen_provider,
                    "model": chosen_name,
                }
            }) + "\n")
            proc.stdin.flush()

            saw_model_selected = False

            while True:
                line = proc.stdout.readline()
                if not line:
                    break
                data = json.loads(line)
                if data.get("done") is True:
                    break
                event = data.get("event", {})
                if event.get("type") == "model.selected":
                    saw_model_selected = True
                    self.assertEqual(event.get("model"), chosen_name)
                    self.assertEqual(event.get("provider"), chosen_provider)
                elif event.get("type") == "planning.completed":
                    # Verified execution proceeded
                    break

            self.assertTrue(saw_model_selected, "model.selected was not emitted")

            # Check that SysAI's base config is completely unchanged
            base_cfg_after = load_config()
            self.assertEqual(base_cfg_before.model, base_cfg_after.model)
            self.assertEqual(base_cfg_before.provider, base_cfg_after.provider)
        finally:
            proc.terminate()
            proc.wait(timeout=3)


if __name__ == "__main__":
    unittest.main()
