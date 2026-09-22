#!/usr/bin/env python3
"""Tests for sandbox.py — bubblewrap shell sandbox."""
import os
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import sandbox
from sandbox import (
    SandboxProfile,
    SandboxState,
    get_sandbox_state,
    sandbox_available,
    build_bwrap_args,
    wrap_command,
    sandbox_info,
    requires_approval_when_unsandboxed,
)


class TestSandboxStateDetection(unittest.TestCase):
    """Sandbox state detection."""

    def test_disabled_when_env_set(self):
        with patch.dict(os.environ, {"SYSAI_SANDBOX_DISABLED": "1"}):
            sandbox._PROBE_DONE = False
            state = get_sandbox_state()
        self.assertEqual(state, SandboxState.DISABLED)

    def test_unavailable_when_bwrap_not_found(self):
        with patch("sandbox.shutil.which", return_value=None):
            sandbox._PROBE_DONE = False
            sandbox._BWRAP_PATH = None
            with patch.dict(os.environ, {}, clear=False):
                if "SYSAI_SANDBOX_DISABLED" in os.environ:
                    del os.environ["SYSAI_SANDBOX_DISABLED"]
                state = get_sandbox_state()
        self.assertEqual(state, SandboxState.UNAVAILABLE)

    def test_available_when_bwrap_works(self):
        with patch("sandbox._probe_bwrap", return_value="/usr/bin/bwrap"):
            with patch.dict(os.environ, {}, clear=False):
                os.environ.pop("SYSAI_SANDBOX_DISABLED", None)
                state = get_sandbox_state()
        self.assertEqual(state, SandboxState.AVAILABLE)


class TestBuildBwrapArgs(unittest.TestCase):
    """bwrap argument construction."""

    def setUp(self):
        # Patch probe to always return a fake bwrap path
        self._probe_patcher = patch("sandbox._probe_bwrap", return_value="/usr/bin/bwrap")
        self._probe_patcher.start()
        self.workspace = Path("/tmp/test_workspace")

    def tearDown(self):
        self._probe_patcher.stop()

    def test_returns_list_starting_with_bwrap(self):
        args = build_bwrap_args(self.workspace, SandboxProfile.WORKSPACE_WRITE)
        self.assertEqual(args[0], "/usr/bin/bwrap")
        self.assertIn("--", args)

    def test_observe_profile_uses_ro_bind_for_workspace(self):
        args = build_bwrap_args(self.workspace, SandboxProfile.OBSERVE)
        # Find the workspace bind in args
        ws = str(self.workspace.resolve())
        idx = args.index(ws)
        self.assertEqual(args[idx - 1], "--ro-bind")
        self.assertEqual(args[idx + 1], ws)

    def test_workspace_write_profile_uses_rw_bind(self):
        args = build_bwrap_args(self.workspace, SandboxProfile.WORKSPACE_WRITE)
        ws = str(self.workspace.resolve())
        idx = args.index(ws)
        self.assertEqual(args[idx - 1], "--bind")
        self.assertEqual(args[idx + 1], ws)

    def test_observe_unshares_network(self):
        args = build_bwrap_args(self.workspace, SandboxProfile.OBSERVE)
        self.assertIn("--unshare-net", args)

    def test_workspace_write_unshares_network(self):
        args = build_bwrap_args(self.workspace, SandboxProfile.WORKSPACE_WRITE)
        self.assertIn("--unshare-net", args)

    def test_network_enabled_does_not_unshare_network(self):
        args = build_bwrap_args(self.workspace, SandboxProfile.NETWORK_ENABLED)
        self.assertNotIn("--unshare-net", args)

    def test_tmpfs_in_workspace_write(self):
        args = build_bwrap_args(self.workspace, SandboxProfile.WORKSPACE_WRITE)
        self.assertIn("--tmpfs", args)

    def test_unshare_pid_always_present(self):
        for profile in SandboxProfile:
            args = build_bwrap_args(self.workspace, profile)
            self.assertIn("--unshare-pid", args, f"--unshare-pid missing for {profile}")


class TestWrapCommand(unittest.TestCase):
    """wrap_command returns correct wrapped/unwrapped commands."""

    def test_returns_original_when_unavailable(self):
        with patch("sandbox.get_sandbox_state", return_value=SandboxState.UNAVAILABLE):
            cmd, sandboxed = wrap_command("ls /tmp", Path("/tmp"))
        self.assertEqual(cmd, "ls /tmp")
        self.assertFalse(sandboxed)

    def test_returns_original_when_disabled(self):
        with patch("sandbox.get_sandbox_state", return_value=SandboxState.DISABLED):
            cmd, sandboxed = wrap_command("ls /tmp", Path("/tmp"))
        self.assertFalse(sandboxed)

    def test_wraps_when_available(self):
        with patch("sandbox.get_sandbox_state", return_value=SandboxState.AVAILABLE):
            with patch("sandbox._probe_bwrap", return_value="/usr/bin/bwrap"):
                with patch("sandbox.build_bwrap_args", return_value=["/usr/bin/bwrap", "--"]):
                    cmd, sandboxed = wrap_command("ls /tmp", Path("/tmp"))
        self.assertTrue(sandboxed)
        self.assertIn("bwrap", cmd)
        self.assertIn("ls /tmp", cmd)


class TestSandboxInfo(unittest.TestCase):
    """sandbox_info() returns expected structure."""

    def test_info_has_required_fields(self):
        info = sandbox_info()
        self.assertIn("state", info)
        self.assertIn("bwrap_path", info)
        self.assertIn("default_profile", info)
        self.assertIn("requires_approval_when_unsandboxed", info)
        self.assertIn("limitations", info)
        self.assertIsInstance(info["limitations"], list)
        self.assertTrue(len(info["limitations"]) > 0)

    def test_state_values_are_valid(self):
        info = sandbox_info()
        valid = {s.value for s in SandboxState}
        self.assertIn(info["state"], valid)


class TestRequiresApproval(unittest.TestCase):
    def test_requires_approval_by_default(self):
        with patch.dict(os.environ, {}, clear=False):
            os.environ.pop("SYSAI_SANDBOX_NO_APPROVAL_FALLBACK", None)
            self.assertTrue(requires_approval_when_unsandboxed())

    def test_no_approval_when_opt_out(self):
        with patch.dict(os.environ, {"SYSAI_SANDBOX_NO_APPROVAL_FALLBACK": "1"}):
            self.assertFalse(requires_approval_when_unsandboxed())


if __name__ == "__main__":
    unittest.main()
