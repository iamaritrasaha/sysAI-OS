"""
Regression test for the sysai.diagnostics capability's use of a Run's
isolated model config.

This is NOT a SysAI engine bug: `sysai.doctor.run_doctor()` already accepts
an explicit `Config` and fully honors it (`config = config or load_config()`),
and `sysai.ollama.OllamaManager` never loads config on its own — callers must
supply one. The bug was entirely on the SysAI_OS side: the `sysai.diagnostics`
capability handler called `run_doctor(probe_model=probe)` without passing the
Run's isolated `run_config`, so a Run's model probe silently fell back to
`load_config()` (config.toml, or the engine's built-in fallback) instead of
checking the model the Run actually selected.
"""
from __future__ import annotations

import os
import sys
import unittest
from pathlib import Path
from unittest import mock

BRIDGE_DIR = Path(__file__).resolve().parent.parent
if str(BRIDGE_DIR) not in sys.path:
    sys.path.insert(0, str(BRIDGE_DIR))

import sysai_bridge
_detected = sysai_bridge._find_sysai_path()
_REPO_ROOT = BRIDGE_DIR.parent
SYSAI_PATH = os.environ.get(
    "SYSAI_PATH",
    str(_detected) if _detected else str(_REPO_ROOT.parent.parent / "Projects" / "sysai" / "src"),
)
if SYSAI_PATH not in sys.path:
    sys.path.insert(0, SYSAI_PATH)

from capabilities.registry import get_default_registry  # noqa: E402
from sysai.config import Config  # noqa: E402


class TestDiagnosticsConfigIsolation(unittest.TestCase):
    def setUp(self) -> None:
        self.registry = get_default_registry()
        self.capability = self.registry.get("sysai.diagnostics")
        self.assertIsNotNone(self.capability)

    def test_diagnostics_uses_the_runs_isolated_config_when_present(self) -> None:
        """A Run that selected a specific model must have its diagnostics
        probe check *that* model, not whatever load_config() would return."""
        run_config = Config(provider="ollama", model="llama3.2:latest")

        with mock.patch("sysai.doctor.run_doctor", return_value={"overall": "ok"}) as mocked:
            self.capability.execute(
                {"probe_model": True},
                {"run_config": run_config},
            )

        mocked.assert_called_once()
        passed_config = mocked.call_args.args[0] if mocked.call_args.args else mocked.call_args.kwargs.get("config")
        self.assertIs(passed_config, run_config)
        self.assertEqual(passed_config.model, "llama3.2:latest")

    def test_diagnostics_falls_back_cleanly_with_no_run_config(self) -> None:
        """Outside of a Run (or a Run with no explicit model), there's no
        isolated config to honor — run_doctor must still be called, with
        None, so it resolves its own fallback exactly as standalone SysAI
        does."""
        with mock.patch("sysai.doctor.run_doctor", return_value={"overall": "ok"}) as mocked:
            self.capability.execute({"probe_model": True}, {})

        mocked.assert_called_once()
        passed_config = mocked.call_args.args[0] if mocked.call_args.args else mocked.call_args.kwargs.get("config")
        self.assertIsNone(passed_config)

    def test_two_runs_probe_their_own_model_without_leaking(self) -> None:
        """Two concurrent-style diagnostics calls with different isolated
        configs must never see each other's model."""
        config_a = Config(provider="ollama", model="llama3.2:latest")
        config_b = Config(provider="ollama", model="mistral:7b")
        seen_models: list[str] = []

        def fake_run_doctor(config=None, *, probe_model=True):
            seen_models.append(config.model if config else "<fallback>")
            return {"overall": "ok"}

        with mock.patch("sysai.doctor.run_doctor", side_effect=fake_run_doctor):
            self.capability.execute({"probe_model": True}, {"run_config": config_a})
            self.capability.execute({"probe_model": True}, {"run_config": config_b})

        self.assertEqual(seen_models, ["llama3.2:latest", "mistral:7b"])


if __name__ == "__main__":
    unittest.main()
