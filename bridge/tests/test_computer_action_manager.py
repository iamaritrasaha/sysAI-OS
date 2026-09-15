"""
Tests for ComputerActionManager — the request/block/resolve round-trip
Controlled Computer Use actions use to hand execution to Flutter and wait
for the real result, mirroring ApprovalManager's own tests.
"""
from __future__ import annotations

import threading
import time
import unittest

from computer_action_manager import ComputerActionManager


class TestComputerActionManager(unittest.TestCase):
    def setUp(self) -> None:
        self.manager = ComputerActionManager()

    def test_create_request_returns_a_unique_correlation_id(self) -> None:
        a = self.manager.create_request(run_id="r1", task_id="t1", target_id="sysai-test-surface", action_type="click")
        b = self.manager.create_request(run_id="r1", task_id="t2", target_id="sysai-test-surface", action_type="click")
        self.assertNotEqual(a.id, b.id)

    def test_resolve_unblocks_wait_for_result_with_the_real_result(self) -> None:
        req = self.manager.create_request(run_id="r1", task_id="t1", target_id="sysai-test-surface", action_type="type")

        def resolve_later():
            time.sleep(0.05)
            self.manager.resolve(req.id, {"success": True, "value": "typed"})

        threading.Thread(target=resolve_later).start()
        result = self.manager.wait_for_result(req.id, timeout=5)
        self.assertEqual(result, {"success": True, "value": "typed"})

    def test_wait_for_result_times_out_and_reports_a_well_formed_failure(self) -> None:
        req = self.manager.create_request(run_id="r1", task_id="t1", target_id="sysai-test-surface", action_type="click")
        result = self.manager.wait_for_result(req.id, timeout=0.1)
        self.assertFalse(result["success"])
        self.assertIn("error", result)

    def test_resolve_is_a_no_op_after_a_timeout_has_already_resolved_it(self) -> None:
        req = self.manager.create_request(run_id="r1", task_id="t1", target_id="sysai-test-surface", action_type="click")
        self.manager.wait_for_result(req.id, timeout=0.05)
        resolved_again = self.manager.resolve(req.id, {"success": True})
        self.assertFalse(resolved_again)

    def test_resolve_unknown_request_id_returns_false(self) -> None:
        self.assertFalse(self.manager.resolve("does-not-exist", {"success": True}))

    def test_wait_for_result_on_unknown_request_id_fails_immediately(self) -> None:
        result = self.manager.wait_for_result("does-not-exist", timeout=5)
        self.assertFalse(result["success"])

    def test_cancel_run_resolves_every_pending_action_for_that_run_as_cancelled(self) -> None:
        req1 = self.manager.create_request(run_id="r1", task_id="t1", target_id="sysai-test-surface", action_type="click")
        req2 = self.manager.create_request(run_id="r1", task_id="t2", target_id="sysai-test-surface", action_type="type")
        other_run = self.manager.create_request(run_id="r2", task_id="t1", target_id="sysai-test-surface", action_type="click")

        self.manager.cancel_run("r1")

        result1 = self.manager.wait_for_result(req1.id, timeout=1)
        result2 = self.manager.wait_for_result(req2.id, timeout=1)
        self.assertFalse(result1["success"])
        self.assertTrue(result1.get("cancelled"))
        self.assertFalse(result2["success"])
        self.assertTrue(result2.get("cancelled"))

        # A different run's pending action is untouched.
        self.assertFalse(other_run.resolved)

    def test_cancel_resolves_a_single_action_as_cancelled(self) -> None:
        req = self.manager.create_request(run_id="r1", task_id="t1", target_id="sysai-test-surface", action_type="click")
        self.assertTrue(self.manager.cancel(req.id))
        result = self.manager.wait_for_result(req.id, timeout=1)
        self.assertFalse(result["success"])
        self.assertTrue(result.get("cancelled"))


if __name__ == "__main__":
    unittest.main()
