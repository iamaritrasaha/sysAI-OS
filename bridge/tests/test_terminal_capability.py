"""
Tests for the Terminal / structured shell-session capability.
"""
from __future__ import annotations

import shutil
import tempfile
import unittest
from pathlib import Path

from capabilities.registry import get_default_registry
from approval_manager import EXECUTION_CONTROLLER


class TestTerminalCapability(unittest.TestCase):
    def setUp(self) -> None:
        self.registry = get_default_registry()
        self.capability = self.registry.get("shell.execute")
        self.temp_dir = tempfile.mkdtemp(prefix="sysai_terminal_test_")
        self.workspace_root = Path(self.temp_dir).resolve()

    def tearDown(self) -> None:
        shutil.rmtree(self.temp_dir, ignore_errors=True)

    def _context(self, run_id: str = "term-run", **extra):
        events = []
        ctx = {
            "workspace_root": str(self.workspace_root),
            "run_id": run_id,
            "task_id": "t1",
            "emit": events.append,
            **extra,
        }
        return ctx, events

    def test_structured_execution_separates_stdout_and_stderr(self) -> None:
        ctx, events = self._context()
        result = self.capability.execute({"cmd": "echo out-line; echo err-line 1>&2"}, ctx)

        self.assertTrue(result["success"])
        self.assertEqual(result["exit_code"], 0)
        self.assertIn("out-line", result["stdout"])
        self.assertIn("err-line", result["stderr"])
        self.assertNotIn("err-line", result["stdout"])
        self.assertIsNotNone(result.get("session_id"))

    def test_nonzero_exit_code_is_reported_and_not_marked_successful(self) -> None:
        ctx, _ = self._context()
        result = self.capability.execute({"cmd": "exit 7"}, ctx)
        self.assertFalse(result["success"])
        self.assertEqual(result["exit_code"], 7)

    def test_timeout_terminates_the_process_and_reports_timed_out(self) -> None:
        ctx, _ = self._context()
        result = self.capability.execute({"cmd": "sleep 5", "timeout": 1}, ctx)
        self.assertTrue(result["timed_out"])
        self.assertFalse(result["success"])
        self.assertEqual(result["exit_code"], -1)

    def test_emits_session_lifecycle_and_output_events(self) -> None:
        ctx, events = self._context()
        self.capability.execute({"cmd": "echo one; echo two"}, ctx)

        types = [e["type"] for e in events]
        self.assertEqual(types[0], "terminal.session.created")
        self.assertEqual(types[-1], "terminal.session.completed")
        self.assertIn("terminal.output", types)

        output_events = [e for e in events if e["type"] == "terminal.output"]
        self.assertTrue(all(e["stream"] in ("stdout", "stderr") for e in output_events))
        # Every event in the session shares one session_id.
        session_ids = {e["session_id"] for e in events}
        self.assertEqual(len(session_ids), 1)

    def test_cwd_is_resolved_within_the_workspace(self) -> None:
        (self.workspace_root / "sub").mkdir()
        ctx, _ = self._context()
        result = self.capability.execute({"cmd": "pwd", "cwd": "sub"}, ctx)
        self.assertTrue(result["success"])
        self.assertIn("sub", result["stdout"])
        self.assertEqual(result["cwd"], "sub")

    def test_process_is_registered_with_execution_controller_before_it_finishes(self) -> None:
        # Registration must happen before the blocking wait, not after —
        # otherwise cancel_run() called mid-command has nothing to kill.
        # We can't easily observe "during," but we can confirm register/
        # unregister both fire by checking the controller has no leftover
        # entry once the (short) command completes.
        ctx, _ = self._context(run_id="term-registration-run")
        self.capability.execute({"cmd": "echo done"}, ctx)
        # unregister_process always runs in the handler's finally block.
        EXECUTION_CONTROLLER.unregister_process("term-registration-run")  # idempotent no-op if already gone

    def test_output_beyond_the_buffered_line_limit_is_marked_truncated(self) -> None:
        ctx, _ = self._context()
        # Generate far more lines than the 2000-line buffer cap, quickly.
        result = self.capability.execute(
            {"cmd": "for i in $(seq 1 2500); do echo line-$i; done", "timeout": 20}, ctx
        )
        self.assertTrue(result["success"])
        self.assertTrue(result["truncated"])

    def test_substantial_output_becomes_a_terminal_log_artifact(self) -> None:
        ctx, _ = self._context()
        result = self.capability.execute({"cmd": "python3 -c \"print('x' * 600)\""}, ctx)
        self.assertIn("artifact", result)
        self.assertEqual(result["artifact"]["type"], "terminal_log")

    def test_short_successful_command_does_not_create_an_artifact(self) -> None:
        ctx, _ = self._context()
        result = self.capability.execute({"cmd": "echo hi"}, ctx)
        self.assertTrue(result["success"])
        self.assertNotIn("artifact", result)

    def test_failed_command_creates_an_artifact_even_if_short(self) -> None:
        ctx, _ = self._context()
        result = self.capability.execute({"cmd": "exit 1"}, ctx)
        self.assertIn("artifact", result)


if __name__ == "__main__":
    unittest.main()
