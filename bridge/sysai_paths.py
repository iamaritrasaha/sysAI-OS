#!/usr/bin/env python3
"""Centralized XDG-aware path resolution for SysAI OS.

All runtime file locations are defined here. Code that needs a path must
import from this module rather than computing paths inline. This ensures
the production layout is coherent, testable, and relocatable.

Override any path via environment variables:
    SYSAI_RUNTIME_DIR   — Unix socket and PID file directory
    SYSAI_RUNTIME_DB    — SQLite database file path
    SYSAI_RUNTIME_SOCKET — Unix socket path (overrides SYSAI_RUNTIME_DIR/runtime.sock)
    SYSAI_STATE_DIR     — State directory root (overrides XDG_STATE_HOME/sysai-os)
    SYSAI_CONFIG_DIR    — Config directory root (overrides XDG_CONFIG_HOME/sysai-os)
    SYSAI_CACHE_DIR     — Cache directory root (overrides XDG_CACHE_HOME/sysai-os)
    SYSAI_DATA_DIR      — Data directory root (overrides XDG_DATA_HOME/sysai-os)
    SYSAI_LOG_FILE      — Log file path
    SYSAI_LOG_DEBUG     — Set to '1' to enable DEBUG-level logging

Install-mode detection:
    If the runtime Python is inside a venv at <data_dir>/venv, we are in
    install mode. Otherwise we are in development mode (running from checkout).
"""
from __future__ import annotations

import os
import sys
from pathlib import Path
from typing import Optional

APP_NAME = "sysai-os"


class SysAIPaths:
    """Computes all production XDG-compliant paths for SysAI OS.

    Instantiate once and reuse, or use the module-level singleton `PATHS`.
    Tests can create instances with custom env mappings via `_env` parameter.
    """

    def __init__(self, _env: Optional[dict] = None) -> None:
        # Allow tests to inject an env dict without touching os.environ
        self._env: dict = _env if _env is not None else os.environ

    def _get(self, key: str, default: str = "") -> str:
        return self._env.get(key, default).strip()

    # ── Base directories ──────────────────────────────────────────────────────

    def state_dir(self) -> Path:
        """Persistent state: DB, logs. XDG_STATE_HOME/sysai-os."""
        override = self._get("SYSAI_STATE_DIR")
        if override:
            return Path(override).expanduser()
        xdg = self._get("XDG_STATE_HOME")
        base = Path(xdg).expanduser() if xdg else Path.home() / ".local" / "state"
        return base / APP_NAME

    def config_dir(self) -> Path:
        """User configuration. XDG_CONFIG_HOME/sysai-os."""
        override = self._get("SYSAI_CONFIG_DIR")
        if override:
            return Path(override).expanduser()
        xdg = self._get("XDG_CONFIG_HOME")
        base = Path(xdg).expanduser() if xdg else Path.home() / ".config"
        return base / APP_NAME

    def cache_dir(self) -> Path:
        """Cache: captures, downloads. XDG_CACHE_HOME/sysai-os."""
        override = self._get("SYSAI_CACHE_DIR")
        if override:
            return Path(override).expanduser()
        xdg = self._get("XDG_CACHE_HOME")
        base = Path(xdg).expanduser() if xdg else Path.home() / ".cache"
        return base / APP_NAME

    def data_dir(self) -> Path:
        """Application data: venv, installed runtime files. XDG_DATA_HOME/sysai-os."""
        override = self._get("SYSAI_DATA_DIR")
        if override:
            return Path(override).expanduser()
        xdg = self._get("XDG_DATA_HOME")
        base = Path(xdg).expanduser() if xdg else Path.home() / ".local" / "share"
        return base / APP_NAME

    def runtime_dir(self) -> Path:
        """Runtime socket and PID file directory. XDG_RUNTIME_DIR/sysai-os or fallback."""
        override = self._get("SYSAI_RUNTIME_DIR")
        if override:
            return Path(override).expanduser()
        xdg = self._get("XDG_RUNTIME_DIR")
        if xdg:
            return Path(xdg).expanduser() / APP_NAME
        # Fallback: state_dir/runtime (persists across reboots, acceptable for desktops)
        return self.state_dir() / "runtime"

    # ── Specific paths ────────────────────────────────────────────────────────

    def db_path(self) -> Path:
        """Persistent SQLite database."""
        override = self._get("SYSAI_RUNTIME_DB")
        if override:
            return Path(override).expanduser()
        return self.state_dir() / "sysai_os.db"

    def socket_path(self) -> Path:
        """Unix domain socket for IPC."""
        override = self._get("SYSAI_RUNTIME_SOCKET")
        if override:
            return Path(override).expanduser()
        return self.runtime_dir() / "runtime.sock"

    def pid_file(self) -> Path:
        """PID/lock file for single-instance guarantee."""
        return self.runtime_dir() / "runtime.pid"

    def log_dir(self) -> Path:
        """Log directory."""
        return self.state_dir() / "logs"

    def log_file(self) -> Path:
        """Runtime log file."""
        override = self._get("SYSAI_LOG_FILE")
        if override:
            return Path(override).expanduser()
        return self.log_dir() / "runtime.log"

    def captures_dir(self) -> Path:
        """Computer Use screenshots and captures."""
        return self.cache_dir() / "captures"

    def downloads_dir(self) -> Path:
        """Browser download staging area."""
        return self.cache_dir() / "downloads"

    def engine_venv(self) -> Path:
        """Python venv containing the SysAI engine package."""
        return self.data_dir() / "venv"

    def engine_install(self) -> Path:
        """Alternative: SysAI engine installed as a source tree."""
        return self.data_dir() / "engine"

    def runtime_install(self) -> Path:
        """Installed bridge/runtime Python files."""
        return self.data_dir() / "runtime"

    def app_install(self) -> Path:
        """Installed Flutter application bundle."""
        return self.data_dir() / "app"

    # ── Mode detection ────────────────────────────────────────────────────────

    def is_install_mode(self) -> bool:
        """True if running from an installed venv rather than a development checkout.

        Detection: the Python executable running this process is inside the
        engine venv we would have created during install.
        """
        try:
            venv = self.engine_venv().resolve()
            exe = Path(sys.executable).resolve()
            return exe.is_relative_to(venv)
        except Exception:
            return False

    def find_sysai_in_venv(self) -> Optional[Path]:
        """Locate the SysAI engine `src` directory inside the installed venv.

        Returns the path whose child directory is `sysai/`, or None if the
        engine is not installed in the venv.
        """
        venv = self.engine_venv()
        if not venv.exists():
            return None
        # Standard venv layout: lib/python3.XX/site-packages/
        for lib_dir in sorted(venv.glob("lib/python*/site-packages"), reverse=True):
            if (lib_dir / "sysai").is_dir():
                return lib_dir
        return None

    def find_sysai_in_engine_install(self) -> Optional[Path]:
        """Locate the SysAI engine inside the engine_install directory."""
        engine = self.engine_install()
        # Try: engine/src/sysai or engine/sysai
        for candidate in (engine / "src", engine):
            if (candidate / "sysai").is_dir():
                return candidate
        return None


# Module-level singleton using the real process environment.
PATHS = SysAIPaths()
