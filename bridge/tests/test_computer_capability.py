"""
Tests for Controlled Computer Use.

Observation/capture against the host desktop are real when a tool exists
(and honestly report when one doesn't). Observation/capture/click/scroll
against the registered SysAI-owned test surface, and type/key against it,
go through a request/block/resolve round-trip with
`ComputerActionManager` — mirroring the existing approval flow — and are
genuinely denied outright for any other target.
"""
from __future__ import annotations

import shutil
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest import mock

from capabilities.registry import get_default_registry
from computer_action_manager import COMPUTER_ACTION_MANAGER


class TestComputerCapabilityRegistration(unittest.TestCase):
    def test_all_computer_capabilities_are_registered(self) -> None:
        registry = get_default_registry()
        for cap_id in ("computer.observe", "computer.capture", "computer.click",
                       "computer.type", "computer.key", "computer.scroll"):
            self.assertIsNotNone(registry.get(cap_id), f"{cap_id} not registered")


class TestComputerObserveDesktop(unittest.TestCase):
    def test_reports_real_display_state_when_no_target_given(self) -> None:
        registry = get_default_registry()
        result = registry.get("computer.observe").execute({}, {"run_id": "r1"})
        self.assertTrue(result["success"])
        self.assertIn("display", result)
        self.assertIn("session_type", result)


class TestComputerCaptureDesktop(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.mkdtemp(prefix="sysai_computer_test_")

    def tearDown(self) -> None:
        shutil.rmtree(self.temp_dir, ignore_errors=True)

    def test_honestly_reports_unavailable_when_no_screenshot_tool_exists(self) -> None:
        registry = get_default_registry()
        with mock.patch("capabilities.computer.shutil.which", return_value=None):
            result = registry.get("computer.capture").execute(
                {}, {"workspace_root": self.temp_dir, "run_id": "r1", "emit": lambda e: None}
            )
        self.assertFalse(result["success"])
        self.assertFalse(result["available"])
        self.assertIn("reason", result)
        self.assertNotIn("artifact", result)

    def test_captures_and_creates_an_artifact_when_a_tool_is_available(self) -> None:
        registry = get_default_registry()

        def fake_which(name):
            return f"/usr/bin/{name}" if name == "scrot" else None

        def fake_run(cmd, **kwargs):
            Path(cmd[-1]).write_bytes(b"fake-png-bytes")
            return mock.Mock(returncode=0)

        events = []
        with mock.patch("capabilities.computer.shutil.which", side_effect=fake_which), \
             mock.patch("capabilities.computer.subprocess.run", side_effect=fake_run):
            result = registry.get("computer.capture").execute(
                {}, {"workspace_root": self.temp_dir, "run_id": "r1", "emit": events.append}
            )

        self.assertTrue(result["success"])
        self.assertTrue(result["available"])
        self.assertEqual(result["artifact"]["type"], "screenshot")
        self.assertEqual([e["type"] for e in events], ["computer.capture.created"])


def _resolve_soon(request_id_holder: dict, result: dict, *, key: str = "request_id", delay: float = 0.05) -> None:
    """Runs on a background thread: waits for the handler under test to
    publish its request id via `emit`, then resolves it — simulating
    Flutter executing the action and calling back
    `report_computer_action_result` shortly after the request arrives."""
    deadline = time.time() + 5
    while key not in request_id_holder and time.time() < deadline:
        time.sleep(0.01)
    time.sleep(delay)
    req_id = request_id_holder.get(key)
    if req_id:
        COMPUTER_ACTION_MANAGER.resolve(req_id, result)


class TestControlledActionsAgainstTheRegisteredTestSurface(unittest.TestCase):
    def setUp(self) -> None:
        self.registry = get_default_registry()

    def _run_with_resolution(self, cap_id: str, params: dict, resolved_result: dict):
        events = []
        holder: dict = {}

        def emit(event):
            events.append(event)
            if event.get("type") == "computer.action.requested":
                holder["request_id"] = event["request_id"]

        thread = threading.Thread(target=_resolve_soon, args=(holder, resolved_result))
        thread.start()
        try:
            result = self.registry.get(cap_id).execute(
                params, {"run_id": "r1", "task_id": "t1", "emit": emit}
            )
        finally:
            thread.join(timeout=5)
        return result, events

    def test_observe_against_the_test_surface_routes_through_the_action_manager(self) -> None:
        manifest = {"success": True, "controls": ["main_field", "submit_button"]}
        result, events = self._run_with_resolution(
            "computer.observe", {"target_id": "sysai-test-surface"}, manifest
        )
        self.assertEqual(result, manifest)
        self.assertEqual([e["type"] for e in events], ["computer.action.requested", "computer.action.completed"])

    def test_click_against_the_test_surface_executes_and_reports_success(self) -> None:
        result, events = self._run_with_resolution(
            "computer.click",
            {"target_id": "sysai-test-surface", "selector": "submit_button"},
            {"success": True, "action": "click"},
        )
        self.assertTrue(result["success"])
        self.assertEqual(events[0]["selector"], "submit_button")
        self.assertTrue(events[-1]["success"])

    def test_type_against_the_test_surface_carries_the_text_through_as_metadata(self) -> None:
        result, events = self._run_with_resolution(
            "computer.type",
            {"target_id": "sysai-test-surface", "selector": "main_field", "text": "hello"},
            {"success": True},
        )
        self.assertTrue(result["success"])
        self.assertEqual(events[0]["text_metadata"], "hello")

    def test_scroll_against_the_test_surface_executes(self) -> None:
        result, _ = self._run_with_resolution(
            "computer.scroll",
            {"target_id": "sysai-test-surface", "selector": "scroll_region", "direction": "down"},
            {"success": True},
        )
        self.assertTrue(result["success"])

    def test_capture_against_the_test_surface_uses_the_render_tree_not_a_screenshot_tool(self) -> None:
        with mock.patch("capabilities.computer.shutil.which", return_value=None):
            result, events = self._run_with_resolution(
                "computer.capture",
                {"target_id": "sysai-test-surface"},
                {"success": True, "artifact": {"type": "screenshot"}},
            )
        # Must succeed even though no OS screenshot tool is available —
        # proving this path never touches _find_screenshot_tool at all.
        self.assertTrue(result["success"])

    # Timeout behavior is covered directly against ComputerActionManager in
    # test_computer_action_manager.py — the capability handler hardcodes a
    # real 60s wait, too slow to exercise meaningfully at this layer.


class TestControlledActionsRejectUnregisteredTargets(unittest.TestCase):
    def test_missing_target_id_is_denied_without_ever_waiting(self) -> None:
        registry = get_default_registry()
        events = []
        result = registry.get("computer.click").execute({}, {"run_id": "r1", "emit": events.append})
        self.assertFalse(result["success"])
        self.assertIn("error", result)
        self.assertEqual([e["type"] for e in events], ["computer.action.denied"])

    def test_arbitrary_desktop_target_is_denied_for_every_action_type(self) -> None:
        registry = get_default_registry()
        for cap_id in ("computer.click", "computer.type", "computer.key", "computer.scroll"):
            result = registry.get(cap_id).execute(
                {"target_id": "some-random-window"}, {"run_id": "r1", "emit": lambda e: None}
            )
            self.assertFalse(result["success"], f"{cap_id} against an arbitrary target must be denied")


if __name__ == "__main__":
    unittest.main()
