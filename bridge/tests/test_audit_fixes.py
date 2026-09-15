"""Regression tests for issues proven during the architecture audit.

Covers five reproduced defects:
1. Cancellation during a multi-attempt task respawned the killed subprocess
   because the runner's retry loop never checked the ExecutionController.
2. The runtime's run snapshot embedded every event (including per-line
   terminal.output chatter) without bound, so a chatty command — or even one
   multi-megabyte line — grew run_json past the IPC frame limit and made
   run.get/run.list responses undeliverable.
3. Oversized frames were dropped silently by Client.send, which looks like a
   client-side hang.
4. Automation last_result was never updated when a runtime-fired Run settled,
   so the Automations UI showed "Never run" forever.
5. The runtime scheduler's next-trigger math added timedelta(days=...) to a
   zoned datetime, shifting wall-clock schedules by an hour across DST.
"""
from __future__ import annotations

import datetime as dt
import json
import socket
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest import mock
from zoneinfo import ZoneInfo

BRIDGE_DIR = Path(__file__).resolve().parent.parent
if str(BRIDGE_DIR) not in sys.path:
    sys.path.insert(0, str(BRIDGE_DIR))

import sysai_os_runtime
from sysai_os_runtime import MAX_EMBEDDED_EVENTS, Client, Runtime, RuntimeStore


def _minimal_runtime(root: Path) -> Runtime:
    # Bypass the socket server; these tests exercise store/event logic only.
    runtime = object.__new__(Runtime)
    runtime.socket_path = root / "unused.sock"
    runtime.db_path = root / "runtime.db"
    runtime.store = RuntimeStore(runtime.db_path)
    runtime.clients = set()
    runtime.clients_lock = threading.Lock()
    runtime.active_runs = set()
    runtime.active_lock = threading.Lock()
    runtime.targets = {}
    runtime.targets_lock = threading.Lock()
    runtime.stop_event = threading.Event()
    runtime.accepting = True
    runtime.started_at = time.time()
    return runtime


class BoundedRunSnapshotTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="sysai-audit-fix-")
        self.runtime = _minimal_runtime(Path(self.temp.name))

    def tearDown(self) -> None:
        self.runtime.store.close()
        self.temp.cleanup()

    def test_terminal_output_not_embedded_but_replayable(self) -> None:
        self.runtime.store.save_run({"id": "r1", "status": "running", "created_at": "t", "updated_at": "t"})
        for i in range(500):
            self.runtime.emit_runtime_event({"type": "terminal.output", "run_id": "r1", "line": f"line {i}"})
        self.runtime.emit_runtime_event({"type": "task.completed", "run_id": "r1", "task_id": "t1"})
        run = self.runtime.store.get_run("r1")
        embedded_types = [e["type"] for e in run["events"]]
        self.assertNotIn("terminal.output", embedded_types)
        self.assertIn("task.completed", embedded_types)
        con = sqlite3.connect(self.runtime.store.path)
        try:
            rows = con.execute(
                "SELECT count(*) FROM runtime_events WHERE run_id='r1' AND event_json LIKE '%terminal.output%'"
            ).fetchone()[0]
        finally:
            con.close()
        self.assertEqual(rows, 500, "replayable history must keep every line")

    def test_embedded_events_capped(self) -> None:
        self.runtime.store.save_run({"id": "r2", "status": "running", "created_at": "t", "updated_at": "t"})
        for i in range(MAX_EMBEDDED_EVENTS + 50):
            self.runtime.emit_runtime_event({"type": "task.started", "run_id": "r2", "task_id": f"t{i}"})
        run = self.runtime.store.get_run("r2")
        self.assertEqual(len(run["events"]), MAX_EMBEDDED_EVENTS)
        self.assertLess(len(json.dumps(run)), 1024 * 1024)


class OversizeFrameIsLoudTests(unittest.TestCase):
    def test_send_over_limit_reports_instead_of_silently_dropping(self) -> None:
        server, client = socket.socketpair()
        try:
            receiver = Client(server)
            receiver.closed = False  # socketpair peer is open
            with mock.patch("sys.stderr"):
                receiver.send({"type": "run.list", "result": {"x": "y" * (2 * 1024 * 1024)}})
            self.assertFalse(receiver.closed, "a recoverable oversize frame must not close the client")
            client.settimeout(2)
            data = client.recv(65536)
            self.assertIn(b"runtime.warning", data, "the client must be told why it got no response")
        finally:
            client.close()
            server.close()


class AutomationResultTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="sysai-audit-auto-")
        self.runtime = _minimal_runtime(Path(self.temp.name))

    def tearDown(self) -> None:
        self.runtime.store.close()
        self.temp.cleanup()

    def test_settled_run_updates_automation_last_result(self) -> None:
        automation = {"id": "auto-1", "title": "nightly", "enabled": True,
                      "last_run_id": "run-x", "updated_at": "t"}
        self.runtime.store.save_automation(automation)
        self.runtime.store.save_run({"id": "run-x", "status": "running", "created_at": "t", "updated_at": "t"})
        self.runtime.emit_runtime_event({"type": "run.completed", "run_id": "run-x", "outcome": "ok"})
        self.assertEqual(self.runtime.store.get_automation("auto-1")["last_result"], "success")

        self.runtime.store.save_automation({**automation, "last_run_id": "run-y"})
        self.runtime.store.save_run({"id": "run-y", "status": "running", "created_at": "t", "updated_at": "t"})
        self.runtime.emit_runtime_event({"type": "run.failed", "run_id": "run-y", "message": "boom"})
        self.assertEqual(self.runtime.store.get_automation("auto-1")["last_result"], "failure")

    def test_manual_run_does_not_touch_automations(self) -> None:
        automation = {"id": "auto-2", "title": "other", "enabled": True,
                      "last_run_id": "run-other", "updated_at": "t"}
        self.runtime.store.save_automation(automation)
        self.runtime.store.save_run({"id": "run-manual", "status": "running", "created_at": "t", "updated_at": "t"})
        self.runtime.emit_runtime_event({"type": "run.failed", "run_id": "run-manual", "message": "boom"})
        self.assertNotIn("last_result", self.runtime.store.get_automation("auto-2"))


class DstNextTriggerTests(unittest.TestCase):
    def test_daily_wall_clock_survives_dst_end(self) -> None:
        runtime = object.__new__(Runtime)
        automation = {"schedule_type": "daily",
                      "schedule_expression": {"hour": 9, "minute": 0},
                      "timezone": "America/New_York"}
        # DST ends 2026-11-01 02:00 local (EDT -> EST). "now" is Oct 31
        # 10:00 EDT, so the next 09:00 trigger lands after the transition.
        # It must be Nov 1 at 09:00 *local* (EST, UTC-5) — the old code
        # added a day to a zoned datetime and drifted to 08:00 local.
        now = dt.datetime(2026, 10, 31, 14, 0, tzinfo=dt.timezone.utc)
        result = Runtime._next_trigger(runtime, automation, now)
        local = dt.datetime.fromisoformat(result).astimezone(ZoneInfo("America/New_York"))
        self.assertEqual((local.hour, local.minute, local.day), (9, 0, 1))
        self.assertEqual(local.utcoffset(), dt.timedelta(hours=-5))

    def test_weekly_wall_clock_survives_dst_start(self) -> None:
        runtime = object.__new__(Runtime)
        automation = {"schedule_type": "weekly",
                      "schedule_expression": {"weekday": 2, "hour": 7, "minute": 30},
                      "timezone": "America/New_York"}
        # DST starts 2026-03-08 02:00 local. A weekly Tuesday 07:30 trigger
        # computed from Tuesday Mar 3 must land on Tuesday Mar 10 at 07:30
        # local (EDT, UTC-4), keeping the same wall clock across the shift.
        now = dt.datetime(2026, 3, 3, 12, 0, tzinfo=ZoneInfo("America/New_York"))
        result = Runtime._next_trigger(runtime, automation, now)
        local = dt.datetime.fromisoformat(result).astimezone(ZoneInfo("America/New_York"))
        self.assertEqual((local.hour, local.minute), (7, 30))
        self.assertEqual((local.month, local.day), (3, 10))
        self.assertEqual(local.utcoffset(), dt.timedelta(hours=-4))


class CancelDuringRetryTests(unittest.TestCase):
    """A cancelled Run must not respawn its killed subprocess."""

    def test_cancel_mid_attempt_stops_execution(self) -> None:
        import sysai_runner

        temp = tempfile.TemporaryDirectory(prefix="sysai-audit-cancel-")
        try:
            plan = [{
                "id": "t1", "title": "Long command", "capability": "shell.execute",
                "params": {"cmd": "sleep 30", "timeout": 60},
                "description": "Spawns a long-running process group.",
                "dependencies": [], "max_attempts": 2,
            }]
            events: list[dict] = []
            emit = lambda envelope: events.append(envelope.get("event") or envelope)

            with mock.patch.object(sysai_runner, "_generate_plan", return_value=plan):
                runner = threading.Thread(
                    target=sysai_runner.execute_run,
                    kwargs=dict(req_id="t1", run_id="run-cancel-test",
                                goal="audit cancellation", emit=emit,
                                workspace_root=str(temp.name)),
                    daemon=True,
                )
                runner.start()

                deadline = time.time() + 10
                while time.time() < deadline and not any(
                    e.get("type") == "terminal.session.created" for e in events
                ):
                    time.sleep(0.05)
                self.assertTrue(
                    any(e.get("type") == "terminal.session.created" for e in events),
                    f"run never started a command: {events}",
                )

                sysai_runner.EXECUTION_CONTROLLER.cancel_run("run-cancel-test")
                runner.join(timeout=15)
                self.assertFalse(runner.is_alive(), "runner did not stop after cancel")

            time.sleep(1.0)
            probe = subprocess.run(["pgrep", "-f", "sleep 30"], capture_output=True, text=True)
            self.assertNotEqual(probe.returncode, 0,
                                f"subprocess respawned after cancel: {probe.stdout!r}")

            types = [e.get("type") for e in events]
            self.assertIn("run.cancelled", types)
            self.assertNotIn("task.retrying", types,
                             "a cancelled run must not advance to a retry attempt")
        finally:
            temp.cleanup()
            # The cancelled marker is global state on the shared controller.
            with sysai_runner.EXECUTION_CONTROLLER._lock:
                sysai_runner.EXECUTION_CONTROLLER._cancelled_runs.discard("run-cancel-test")
                sysai_runner.EXECUTION_CONTROLLER._paused_runs.pop("run-cancel-test", None)
                sysai_runner.EXECUTION_CONTROLLER._active_procs.pop("run-cancel-test", None)


class RunFailureStateTests(unittest.TestCase):
    def test_failed_task_cannot_be_reported_as_successful_run(self) -> None:
        import sysai_runner
        import sysai_bridge

        plan = [{
            "id": "t1", "title": "Unknown action", "capability": "not.a.capability",
            "params": {}, "description": "must fail", "dependencies": [], "max_attempts": 1,
        }]
        events: list[dict] = []
        emit = lambda envelope: events.append(envelope.get("event") or envelope)
        with mock.patch.object(sysai_runner, "_generate_plan", return_value=plan), \
             mock.patch.object(sysai_bridge, "_check_model_available", return_value=(True, "")):
            sysai_runner.execute_run(
                req_id="failure", run_id="run-failure-state", goal="audit",
                emit=emit, workspace_root=tempfile.gettempdir(),
            )
        types = [event.get("type") for event in events]
        self.assertIn("task.failed", types)
        self.assertIn("run.failed", types)
        self.assertNotIn("run.completed", types)


class BindingAndTargetTests(unittest.TestCase):
    def test_approval_and_computer_result_require_matching_context(self) -> None:
        from approval_manager import ApprovalManager
        from computer_action_manager import ComputerActionManager

        approvals = ApprovalManager()
        approval = approvals.create_request(
            run_id="run-a", task_id="task-a", capability_id="filesystem.write",
            title="write", explanation="write", risk="high", payload={},
        )
        self.assertFalse(approvals.resolve(approval.id, True, run_id="run-b"))
        self.assertTrue(approvals.resolve(approval.id, True, run_id="run-a"))
        self.assertFalse(approvals.resolve(approval.id, False, run_id="run-a"))

        actions = ComputerActionManager()
        action = actions.create_request(
            run_id="run-a", task_id="task-a", target_id="sysai-test-surface", action_type="click",
        )
        self.assertFalse(actions.resolve(action.id, {"success": True}, "run-b", "sysai-test-surface"))
        self.assertFalse(actions.resolve(action.id, {"success": True}, "run-a", "other-target"))
        self.assertTrue(actions.resolve(action.id, {"success": True}, "run-a", "sysai-test-surface"))

    def test_persistent_runtime_requires_registered_computer_target(self) -> None:
        runtime = object.__new__(Runtime)
        runtime.targets = {}
        runtime.targets_lock = threading.Lock()
        self.assertFalse(runtime.target_available("sysai-test-surface"))

    def test_runtime_directory_rejects_symlink(self) -> None:
        with tempfile.TemporaryDirectory(prefix="sysai-runtime-dir-") as root:
            root_path = Path(root)
            outside = root_path / "outside"
            outside.mkdir()
            link = root_path / "runtime"
            link.symlink_to(outside, target_is_directory=True)
            with self.assertRaises(RuntimeError):
                sysai_os_runtime._secure_dir(link)


class TerminalLineTruncationTests(unittest.TestCase):
    def test_single_huge_line_is_truncated(self) -> None:
        from capabilities.registry import _TERMINAL_MAX_LINE_CHARS, _handle_shell_execute

        temp = tempfile.TemporaryDirectory(prefix="sysai-audit-line-")
        try:
            result = _handle_shell_execute(
                {"cmd": "python3 -c \"print('x' * 3000000)\"", "timeout": 30},
                {"workspace_root": str(temp.name), "run_id": "", "emit": None},
            )
            self.assertTrue(result.get("truncated"), "huge line must be flagged truncated")
            self.assertLess(len(result["stdout"]), _TERMINAL_MAX_LINE_CHARS * 3)
            self.assertLess(len(json.dumps(result)), 1024 * 1024)
        finally:
            temp.cleanup()


if __name__ == "__main__":
    unittest.main()
