"""Regression coverage for per-Run model endpoint resolution."""
from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

BRIDGE_DIR = Path(__file__).resolve().parent.parent
if str(BRIDGE_DIR) not in sys.path:
    sys.path.insert(0, str(BRIDGE_DIR))

import sysai_bridge
import sysai_runner


class ModelResolutionAuditTests(unittest.TestCase):
    def test_legacy_remote_ollama_profile_is_not_exposed_as_local(self) -> None:
        from sysai.config import Config, ModelProfile

        profile = ModelProfile(
            "remote-ollama", "ollama", "audit-model", "http://remote.example:11434",
        )
        with mock.patch.object(sysai_bridge, "load_model_profiles", return_value=[profile]), \
             mock.patch.object(sysai_bridge.OllamaManager, "available", return_value=False), \
             mock.patch.object(sysai_bridge, "_check_model_available", return_value=(True, "")):
            models = sysai_bridge._discover_models(Config())
        selected = next(model for model in models if model["name"] == "audit-model")
        self.assertEqual(selected["provider"], "remote-ollama")
        self.assertEqual(selected["id"], "remote-ollama:audit-model")
        self.assertFalse(selected["local"])

    def test_runner_rehydrates_selected_profile_endpoint_per_run(self) -> None:
        from sysai.config import ModelProfile

        profile = ModelProfile(
            "remote-ollama", "ollama", "audit-model", "http://remote.example:11434",
        )
        events: list[dict] = []
        with tempfile.TemporaryDirectory(prefix="sysai-model-audit-") as workspace, \
             mock.patch.object(sysai_runner, "_generate_plan", return_value=[]), \
             mock.patch.object(sysai_bridge, "load_model_profiles", return_value=[profile]), \
             mock.patch("sysai.config.load_model_profiles", return_value=[profile]), \
             mock.patch.object(sysai_bridge, "_check_model_available", return_value=(True, "")) as check:
            sysai_runner.execute_run(
                req_id="model-audit", run_id="run-model-audit", goal="audit",
                emit=lambda envelope: events.append(envelope.get("event") or envelope),
                workspace_root=workspace, provider="remote-ollama", model="remote-ollama:audit-model",
            )
        resolved_config = check.call_args.args[2]
        self.assertEqual(resolved_config.ollama_url, "http://remote.example:11434")
        self.assertEqual(resolved_config.active_model_id, "remote-ollama")
        self.assertEqual(next(e for e in events if e["type"] == "model.selected")["provider"], "remote-ollama")


if __name__ == "__main__":
    unittest.main()
