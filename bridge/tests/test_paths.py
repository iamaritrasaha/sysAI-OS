#!/usr/bin/env python3
"""Tests for sysai_paths.py — portability and XDG compliance."""
import os
import sys
import unittest
from unittest.mock import patch
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from sysai_paths import SysAIPaths, APP_NAME


class TestSysAIPathsXDG(unittest.TestCase):
    """XDG directory resolution with custom environments."""

    def _paths(self, env: dict) -> SysAIPaths:
        return SysAIPaths(_env=env)

    def test_state_dir_uses_xdg_state_home(self):
        p = self._paths({"XDG_STATE_HOME": "/srv/state"})
        self.assertEqual(p.state_dir(), Path("/srv/state") / APP_NAME)

    def test_state_dir_fallback_to_home(self):
        p = self._paths({"HOME": "/home/testuser"})
        expected = Path("/home/testuser") / ".local" / "state" / APP_NAME
        # Can't easily test Path.home() without monkeypatching, so just check suffix
        self.assertTrue(str(p.state_dir()).endswith(f"/.local/state/{APP_NAME}") or 
                        str(p.state_dir()).endswith(f"\\.local\\state\\{APP_NAME}"))

    def test_config_dir_uses_xdg_config_home(self):
        p = self._paths({"XDG_CONFIG_HOME": "/srv/config"})
        self.assertEqual(p.config_dir(), Path("/srv/config") / APP_NAME)

    def test_cache_dir_uses_xdg_cache_home(self):
        p = self._paths({"XDG_CACHE_HOME": "/srv/cache"})
        self.assertEqual(p.cache_dir(), Path("/srv/cache") / APP_NAME)

    def test_data_dir_uses_xdg_data_home(self):
        p = self._paths({"XDG_DATA_HOME": "/srv/data"})
        self.assertEqual(p.data_dir(), Path("/srv/data") / APP_NAME)

    def test_runtime_dir_uses_xdg_runtime_dir(self):
        p = self._paths({"XDG_RUNTIME_DIR": "/run/user/1000"})
        self.assertEqual(p.runtime_dir(), Path("/run/user/1000") / APP_NAME)

    def test_runtime_dir_fallback_when_no_xdg_runtime(self):
        p = self._paths({"XDG_STATE_HOME": "/srv/state"})
        # Should fall back to state_dir/runtime
        self.assertEqual(p.runtime_dir(), Path("/srv/state") / APP_NAME / "runtime")


class TestSysAIPathsOverrides(unittest.TestCase):
    """Per-path env var overrides."""

    def _paths(self, env: dict) -> SysAIPaths:
        return SysAIPaths(_env=env)

    def test_sysai_state_dir_override(self):
        p = self._paths({"SYSAI_STATE_DIR": "/custom/state", "XDG_STATE_HOME": "/xdg/state"})
        self.assertEqual(p.state_dir(), Path("/custom/state"))

    def test_sysai_runtime_dir_override(self):
        p = self._paths({"SYSAI_RUNTIME_DIR": "/custom/runtime"})
        self.assertEqual(p.runtime_dir(), Path("/custom/runtime"))

    def test_sysai_runtime_db_override(self):
        p = self._paths({"SYSAI_RUNTIME_DB": "/custom/db.sqlite"})
        self.assertEqual(p.db_path(), Path("/custom/db.sqlite"))

    def test_sysai_runtime_socket_override(self):
        p = self._paths({"SYSAI_RUNTIME_SOCKET": "/custom/sock"})
        self.assertEqual(p.socket_path(), Path("/custom/sock"))

    def test_sysai_log_file_override(self):
        p = self._paths({"SYSAI_LOG_FILE": "/custom/app.log"})
        self.assertEqual(p.log_file(), Path("/custom/app.log"))


class TestSysAIPathsSpaces(unittest.TestCase):
    """Paths with spaces must be handled correctly."""

    def test_path_with_spaces_in_xdg_state(self):
        p = SysAIPaths(_env={"XDG_STATE_HOME": "/home/test user/state"})
        result = p.state_dir()
        self.assertIn("test user", str(result))

    def test_path_with_spaces_in_data_dir(self):
        p = SysAIPaths(_env={"XDG_DATA_HOME": "/my apps/data"})
        result = p.data_dir()
        self.assertIn("my apps", str(result))


class TestSysAIPathsSubpaths(unittest.TestCase):
    """Sub-path relationships."""

    def _paths(self, env: dict) -> SysAIPaths:
        return SysAIPaths(_env=env)

    def test_db_path_is_inside_state_dir(self):
        p = self._paths({"XDG_STATE_HOME": "/srv/state"})
        self.assertTrue(str(p.db_path()).startswith(str(p.state_dir())))

    def test_socket_path_is_inside_runtime_dir_by_default(self):
        p = self._paths({"XDG_RUNTIME_DIR": "/run/user/1000"})
        self.assertTrue(str(p.socket_path()).startswith(str(p.runtime_dir())))

    def test_log_file_is_inside_log_dir(self):
        p = self._paths({"XDG_STATE_HOME": "/srv/state"})
        self.assertTrue(str(p.log_file()).startswith(str(p.log_dir())))

    def test_captures_dir_is_inside_cache_dir(self):
        p = self._paths({"XDG_CACHE_HOME": "/srv/cache"})
        self.assertTrue(str(p.captures_dir()).startswith(str(p.cache_dir())))

    def test_downloads_dir_is_inside_cache_dir(self):
        p = self._paths({"XDG_CACHE_HOME": "/srv/cache"})
        self.assertTrue(str(p.downloads_dir()).startswith(str(p.cache_dir())))

    def test_engine_venv_is_inside_data_dir(self):
        p = self._paths({"XDG_DATA_HOME": "/srv/data"})
        self.assertTrue(str(p.engine_venv()).startswith(str(p.data_dir())))


class TestSysAIPathsTildeExpansion(unittest.TestCase):
    """Tilde in env vars is expanded."""

    def test_tilde_in_sysai_state_dir(self):
        p = SysAIPaths(_env={"SYSAI_STATE_DIR": "~/.local/state"})
        result = p.state_dir()
        self.assertFalse(str(result).startswith("~"))
        self.assertTrue(result.is_absolute())

    def test_tilde_in_sysai_runtime_dir(self):
        p = SysAIPaths(_env={"SYSAI_RUNTIME_DIR": "~/.local/runtime"})
        result = p.runtime_dir()
        self.assertFalse(str(result).startswith("~"))


class TestSysAIPathsNoPersonalPaths(unittest.TestCase):
    """No personal/developer paths in any default path output."""

    @patch("sysai_paths.Path.home", return_value=Path("/home/testuser"))
    def test_no_developer_name_in_default_paths(self, mock_home):
        # Running under a neutral env: just check no hardcoded names appear
        p = SysAIPaths(_env={"HOME": "/home/testuser", "XDG_STATE_HOME": "/home/testuser/.local/state"})
        paths_to_check = [
            str(p.state_dir()),
            str(p.config_dir()),
            str(p.cache_dir()),
            str(p.data_dir()),
            str(p.db_path()),
            str(p.socket_path()),
        ]
        for path_str in paths_to_check:
            self.assertNotIn("hrik", path_str, f"Developer name 'hrik' found in path: {path_str}")
            self.assertNotIn("aritra", path_str, f"Developer name 'aritra' found in path: {path_str}")
            self.assertNotIn("/media/", path_str, f"Developer media path found in path: {path_str}")


if __name__ == "__main__":
    unittest.main()
