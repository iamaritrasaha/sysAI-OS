"""
Unit tests for SysAI OS Capability Registry and Policy Engine
"""
from __future__ import annotations

import os
import shutil
import tempfile
import unittest
from pathlib import Path

from capabilities.registry import get_default_registry
from policy.policy_engine import PolicyEngine, PolicyVerdict


class TestPolicyEngine(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.mkdtemp(prefix="sysai_test_ws_")
        self.workspace_root = Path(self.temp_dir).resolve()
        self.engine = PolicyEngine(default_require_write_approval=True)
        self.context = {"workspace_root": str(self.workspace_root)}

    def tearDown(self) -> None:
        shutil.rmtree(self.temp_dir, ignore_errors=True)

    def test_workspace_traversal_prevention(self) -> None:
        # Path attempting to escape workspace with ..
        decision = self.engine.evaluate(
            "filesystem.read",
            {"path": "../../../etc/passwd"},
            self.context,
        )
        self.assertEqual(decision.verdict, PolicyVerdict.DENY)
        self.assertIn("Path traversal", decision.reason)

        # Absolute path outside workspace
        decision = self.engine.evaluate(
            "filesystem.stat",
            {"path": "/etc/shadow"},
            self.context,
        )
        self.assertEqual(decision.verdict, PolicyVerdict.DENY)

        # Safe relative path inside workspace
        decision = self.engine.evaluate(
            "filesystem.read",
            {"path": "lib/main.dart"},
            self.context,
        )
        self.assertEqual(decision.verdict, PolicyVerdict.ALLOW)

    def test_shell_command_safety_classification(self) -> None:
        # 1. Unconditional deny: rm -rf /
        d = self.engine.evaluate("shell.execute", {"cmd": "rm -rf /"}, self.context)
        self.assertEqual(d.verdict, PolicyVerdict.DENY)

        # 2. Privileged: sudo
        d = self.engine.evaluate("shell.execute", {"cmd": "sudo apt update"}, self.context)
        self.assertEqual(d.verdict, PolicyVerdict.REQUIRE_APPROVAL)
        self.assertEqual(d.risk, "privileged")

        # 3. High risk: git push
        d = self.engine.evaluate("shell.execute", {"cmd": "git push origin main"}, self.context)
        self.assertEqual(d.verdict, PolicyVerdict.REQUIRE_APPROVAL)
        self.assertEqual(d.risk, "high")

        # 4. Safe read: flutter test
        d = self.engine.evaluate("shell.execute", {"cmd": "flutter test"}, self.context)
        self.assertEqual(d.verdict, PolicyVerdict.ALLOW)
        self.assertEqual(d.risk, "low")

        # 5. Safe read: git status
        d = self.engine.evaluate("shell.execute", {"cmd": "git status"}, self.context)
        self.assertEqual(d.verdict, PolicyVerdict.ALLOW)

    def test_filesystem_write_requires_approval(self) -> None:
        d = self.engine.evaluate(
            "filesystem.write",
            {"path": "lib/new_file.dart", "content": "void main() {}"},
            self.context,
        )
        self.assertEqual(d.verdict, PolicyVerdict.REQUIRE_APPROVAL)
        self.assertEqual(d.risk, "high")

    def test_browser_reading_capabilities_are_allowed(self) -> None:
        for cap_id in ("browser.search", "browser.navigate", "browser.read", "browser.follow_link"):
            d = self.engine.evaluate(cap_id, {"query": "x", "url": "https://example.com"}, self.context)
            self.assertEqual(d.verdict, PolicyVerdict.ALLOW, f"{cap_id} should be ALLOW")

    def test_browser_download_requires_approval(self) -> None:
        d = self.engine.evaluate(
            "browser.download",
            {"url": "https://example.com/f.zip", "path": "downloads/f.zip"},
            self.context,
        )
        self.assertEqual(d.verdict, PolicyVerdict.REQUIRE_APPROVAL)
        self.assertIn("f.zip", d.explanation)

    def test_browser_download_still_enforces_workspace_boundary(self) -> None:
        # The generic path-boundary check runs before capability-specific
        # rules, so a download path outside the workspace is DENIED, not
        # just downgraded to REQUIRE_APPROVAL.
        d = self.engine.evaluate(
            "browser.download",
            {"url": "https://example.com/f", "path": "../../etc/passwd"},
            self.context,
        )
        self.assertEqual(d.verdict, PolicyVerdict.DENY)

    def test_computer_observe_and_capture_are_allowed(self) -> None:
        for cap_id in ("computer.observe", "computer.capture"):
            d = self.engine.evaluate(cap_id, {}, self.context)
            self.assertEqual(d.verdict, PolicyVerdict.ALLOW, f"{cap_id} should be ALLOW")

    def test_computer_input_capabilities_deny_unregistered_or_missing_targets(self) -> None:
        # No target_id at all, and an arbitrary/unknown target_id, must both
        # be denied outright — enforced on target identity, not left to
        # whatever the capability itself would otherwise allow.
        for cap_id in ("computer.click", "computer.type", "computer.key", "computer.scroll"):
            d = self.engine.evaluate(cap_id, {}, self.context)
            self.assertEqual(d.verdict, PolicyVerdict.DENY, f"{cap_id} with no target should be DENY")

            d2 = self.engine.evaluate(cap_id, {"target_id": "some-random-desktop-window"}, self.context)
            self.assertEqual(d2.verdict, PolicyVerdict.DENY, f"{cap_id} against an unregistered target should be DENY")

    def test_computer_click_and_scroll_are_allowed_against_the_registered_test_surface(self) -> None:
        for cap_id in ("computer.click", "computer.scroll"):
            d = self.engine.evaluate(cap_id, {"target_id": "sysai-test-surface"}, self.context)
            self.assertEqual(d.verdict, PolicyVerdict.ALLOW, f"{cap_id} against the known target should be ALLOW")

    def test_computer_type_and_key_require_approval_even_against_the_registered_test_surface(self) -> None:
        for cap_id in ("computer.type", "computer.key"):
            d = self.engine.evaluate(cap_id, {"target_id": "sysai-test-surface"}, self.context)
            self.assertEqual(d.verdict, PolicyVerdict.REQUIRE_APPROVAL, f"{cap_id} should still require approval")
            self.assertEqual(d.risk, "privileged")


class TestCapabilityRegistry(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.mkdtemp(prefix="sysai_test_ws_")
        self.workspace_root = Path(self.temp_dir).resolve()
        self.registry = get_default_registry()
        self.context = {"workspace_root": str(self.workspace_root)}

    def tearDown(self) -> None:
        shutil.rmtree(self.temp_dir, ignore_errors=True)

    def test_filesystem_lifecycle(self) -> None:
        # 1. Write file
        write_cap = self.registry.get("filesystem.write")
        self.assertIsNotNone(write_cap)
        write_res = write_cap.execute(
            {"path": "test_dir/hello.txt", "content": "Hello SysAI OS!"},
            self.context,
        )
        self.assertTrue(write_res["created"])
        self.assertEqual(write_res["artifact"]["type"], "file")
        self.assertEqual(write_res["artifact"]["title"], "hello.txt")

        # 2. Stat file
        stat_cap = self.registry.get("filesystem.stat")
        stat_res = stat_cap.execute({"path": "test_dir/hello.txt"}, self.context)
        self.assertTrue(stat_res["exists"])
        self.assertTrue(stat_res["is_file"])

        # 3. Read file
        read_cap = self.registry.get("filesystem.read")
        read_res = read_cap.execute({"path": "test_dir/hello.txt"}, self.context)
        self.assertEqual(read_res["content"], "Hello SysAI OS!")
        self.assertFalse(read_res["is_truncated"])

        # 4. List directory
        list_cap = self.registry.get("filesystem.list")
        list_res = list_cap.execute({"path": "test_dir"}, self.context)
        self.assertEqual(list_res["count"], 1)
        self.assertEqual(list_res["entries"][0]["name"], "hello.txt")

    def test_traversal_raises_permission_error(self) -> None:
        read_cap = self.registry.get("filesystem.read")
        with self.assertRaises(PermissionError):
            read_cap.execute({"path": "../../../etc/passwd"}, self.context)

    def test_system_env(self) -> None:
        env_cap = self.registry.get("system.environment")
        env_res = env_cap.execute({}, self.context)
        self.assertIn("os", env_res)
        self.assertIn("python_version", env_res)
        self.assertEqual(env_res["workspace_root"], str(self.workspace_root))


if __name__ == "__main__":
    unittest.main()
