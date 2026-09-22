#!/usr/bin/env python3
"""Centralized logging configuration for the SysAI OS runtime.

All runtime components should call `configure_logging()` once at startup
rather than creating their own handlers.

Log destination: SysAIPaths.log_file()  (overridable via SYSAI_LOG_FILE)
Log level:       WARNING by default, DEBUG if SYSAI_LOG_DEBUG=1
Rotation:        5 MB per file, 3 backup files (max ~20 MB total)
Sensitive data:  Never log model prompts, API keys, or credentials.
"""
from __future__ import annotations

import logging
import logging.handlers
import os
import stat
from pathlib import Path
from typing import Optional

from sysai_paths import PATHS

_CONFIGURED = False
_RUNTIME_LOGGER_NAME = "sysai_os"


def _make_formatter() -> logging.Formatter:
    return logging.Formatter(
        fmt="%(asctime)s %(levelname)-8s %(name)s: %(message)s",
        datefmt="%Y-%m-%dT%H:%M:%S",
    )


def configure_logging(
    log_file: Optional[Path] = None,
    debug: Optional[bool] = None,
) -> None:
    """Configure the root logger for the SysAI OS runtime.

    Safe to call multiple times; subsequent calls are no-ops.
    """
    global _CONFIGURED
    if _CONFIGURED:
        return
    _CONFIGURED = True

    level = logging.DEBUG if (debug or os.environ.get("SYSAI_LOG_DEBUG", "") == "1") else logging.WARNING

    root = logging.getLogger()
    root.setLevel(level)

    # ── File handler (rotating) ───────────────────────────────────────────────
    dest = log_file or PATHS.log_file()
    try:
        dest.parent.mkdir(parents=True, exist_ok=True)
        # Private log: only owner can read/write
        handler: logging.Handler = logging.handlers.RotatingFileHandler(
            str(dest),
            maxBytes=5 * 1024 * 1024,  # 5 MB
            backupCount=3,
            encoding="utf-8",
        )
        # Ensure log file is not world-readable (may be created with umask 022)
        try:
            dest.chmod(stat.S_IRUSR | stat.S_IWUSR)  # 0o600
        except Exception:
            pass
        handler.setFormatter(_make_formatter())
        root.addHandler(handler)
    except Exception as exc:
        # Cannot create log file (unwritable dir, etc.) — fall back to stderr
        # but do not crash the runtime over logging failure.
        _fallback_stderr(level, f"Could not open log file {dest}: {exc}")
        return

    # ── Optional stderr handler (development mode) ────────────────────────────
    if os.environ.get("SYSAI_LOG_STDERR", "") == "1" or level == logging.DEBUG:
        stderr_handler = logging.StreamHandler()
        stderr_handler.setFormatter(_make_formatter())
        root.addHandler(stderr_handler)


def _fallback_stderr(level: int, warning: str) -> None:
    stderr_handler = logging.StreamHandler()
    stderr_handler.setFormatter(_make_formatter())
    root = logging.getLogger()
    root.setLevel(level)
    root.addHandler(stderr_handler)
    logging.getLogger(_RUNTIME_LOGGER_NAME).warning(warning)


def get_logger(name: str = _RUNTIME_LOGGER_NAME) -> logging.Logger:
    """Return a logger for a runtime component."""
    return logging.getLogger(name)
