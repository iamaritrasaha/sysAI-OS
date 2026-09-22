#!/usr/bin/env python3
"""Shell execution sandbox for SysAI OS.

Provides a second layer of OS-level containment around agent-initiated shell
commands, implemented with bubblewrap (bwrap). This is defense-in-depth:
the Policy Engine is still required and evaluated first.

Sandbox profiles
----------------
OBSERVE       — read-only bind of workspace, no network, no /tmp writes
WORKSPACE_WRITE — workspace read/write, /tmp writable, no network (default)
NETWORK_ENABLED — workspace read/write, /tmp writable, network permitted
BUILD_TEST    — workspace read/write, /tmp writable, network permitted,
                  extra compiler/toolchain paths visible

Honest limitations
------------------
* Does not sandbox the runtime process itself, only subprocesses it spawns.
* Does not prevent all inter-process communication (shared memory, signals
  to processes outside the bwrap jail are still possible via /proc exposure
  unless --hide-pid is used, which requires newer kernels/setuid bwrap).
* Landlock (kernel-level path restriction) is not used: it requires C
  syscalls not available from pure Python without a compiled helper.
* Network isolation is NOT applied to NETWORK_ENABLED or BUILD_TEST profiles.
* If bwrap is not available, sandbox is UNAVAILABLE and the fallback
  behavior (require approval) is applied per configuration.

Configuration
-------------
SYSAI_SANDBOX_DISABLED=1  — disable sandbox even if bwrap is available
SYSAI_SANDBOX_PROFILE=<name> — override default profile
SYSAI_SANDBOX_NO_APPROVAL_FALLBACK=1 — do not require approval when sandbox unavailable
"""
from __future__ import annotations

import os
import shutil
import subprocess
from enum import Enum
from pathlib import Path
from typing import List, Optional


class SandboxProfile(str, Enum):
    """Sandbox restriction profile."""
    OBSERVE = "observe"
    WORKSPACE_WRITE = "workspace_write"
    NETWORK_ENABLED = "network_enabled"
    BUILD_TEST = "build_test"


class SandboxState(str, Enum):
    """Runtime sandbox availability state."""
    AVAILABLE = "available"
    UNAVAILABLE = "unavailable"
    DISABLED = "disabled"


_BWRAP_PATH: Optional[str] = None
_PROBE_DONE = False


def _probe_bwrap() -> Optional[str]:
    """Locate bwrap and verify it is usable."""
    global _BWRAP_PATH, _PROBE_DONE
    if _PROBE_DONE:
        return _BWRAP_PATH
    _PROBE_DONE = True
    path = shutil.which("bwrap")
    if not path:
        _BWRAP_PATH = None
        return None
    try:
        # Run a trivial bwrap invocation to confirm it works.
        result = subprocess.run(
            [path, "--ro-bind", "/", "/", "--proc", "/proc", "--dev", "/dev",
             "true"],
            capture_output=True,
            timeout=5,
        )
        _BWRAP_PATH = path if result.returncode == 0 else None
    except Exception:
        _BWRAP_PATH = None
    return _BWRAP_PATH


def get_sandbox_state() -> SandboxState:
    """Return the current sandbox availability state."""
    if os.environ.get("SYSAI_SANDBOX_DISABLED", "") == "1":
        return SandboxState.DISABLED
    if _probe_bwrap() is None:
        return SandboxState.UNAVAILABLE
    return SandboxState.AVAILABLE


def sandbox_available() -> bool:
    """True if sandboxing is available and not disabled."""
    return get_sandbox_state() == SandboxState.AVAILABLE


def requires_approval_when_unsandboxed() -> bool:
    """True if unsandboxed execution should fall back to requiring approval."""
    return os.environ.get("SYSAI_SANDBOX_NO_APPROVAL_FALLBACK", "") != "1"


def _default_profile() -> SandboxProfile:
    override = os.environ.get("SYSAI_SANDBOX_PROFILE", "").strip().lower()
    for p in SandboxProfile:
        if p.value == override:
            return p
    return SandboxProfile.WORKSPACE_WRITE


# Paths that must be visible to almost every process (compilers, shells, etc.)
_COMMON_RO = [
    "/usr", "/bin", "/lib", "/lib64", "/sbin",
    "/etc/passwd", "/etc/group", "/etc/nsswitch.conf",
    "/etc/resolv.conf",  # needed for DNS in NETWORK_ENABLED / BUILD_TEST
    "/etc/ssl",          # TLS certificates for HTTPS
    "/etc/localtime",
]

# Extra paths for BUILD_TEST profile
_BUILD_EXTRA_RO = [
    "/opt",  # common third-party tool install prefix
]


def build_bwrap_args(
    workspace: Path,
    profile: Optional[SandboxProfile] = None,
    extra_rw_dirs: Optional[List[Path]] = None,
    extra_ro_dirs: Optional[List[Path]] = None,
) -> List[str]:
    """Build the bwrap argument list for the given workspace and profile.

    The returned list must be prepended to the command to be sandboxed:

        args = build_bwrap_args(workspace, SandboxProfile.WORKSPACE_WRITE)
        subprocess.run(args + ["bash", "-c", cmd], ...)
    """
    bwrap = _probe_bwrap()
    if not bwrap:
        raise RuntimeError("bwrap is not available — cannot build sandbox args")

    profile = profile or _default_profile()
    ws = str(workspace.resolve())

    args: List[str] = [bwrap]

    # ── New PID namespace ─────────────────────────────────────────────────────
    args += ["--unshare-pid", "--unshare-uts", "--unshare-ipc"]

    # ── Network isolation (only for profiles that need it) ────────────────────
    if profile in (SandboxProfile.OBSERVE, SandboxProfile.WORKSPACE_WRITE):
        args += ["--unshare-net"]

    # ── proc and dev ─────────────────────────────────────────────────────────
    args += ["--proc", "/proc", "--dev", "/dev"]

    # ── Read-only system paths ────────────────────────────────────────────────
    for p in _COMMON_RO:
        if Path(p).exists():
            args += ["--ro-bind", p, p]

    if profile == SandboxProfile.BUILD_TEST:
        for p in _BUILD_EXTRA_RO:
            if Path(p).exists():
                args += ["--ro-bind", p, p]

    # ── Workspace binding ─────────────────────────────────────────────────────
    if profile == SandboxProfile.OBSERVE:
        args += ["--ro-bind", ws, ws]
    else:
        args += ["--bind", ws, ws]

    # ── Extra user-supplied directories ──────────────────────────────────────
    for d in (extra_rw_dirs or []):
        if d.exists():
            args += ["--bind", str(d.resolve()), str(d.resolve())]
    for d in (extra_ro_dirs or []):
        if d.exists():
            args += ["--ro-bind", str(d.resolve()), str(d.resolve())]

    # ── Temporary filesystem ──────────────────────────────────────────────────
    if profile != SandboxProfile.OBSERVE:
        args += ["--tmpfs", "/tmp"]

    # ── Home dir in sandbox: mapped read-only except for workspace subdirs ─────
    # Do not bind full home: too broad. Instead make a tmpfs-backed /root
    # or /home so tools that write dotfiles don't fail completely.
    args += ["--tmpfs", "/root" if os.getuid() == 0 else "/home"]

    # ── Separator ─────────────────────────────────────────────────────────────
    args += ["--"]

    return args


def wrap_command(
    cmd: str,
    workspace: Path,
    profile: Optional[SandboxProfile] = None,
    **kwargs,
) -> tuple[str, bool]:
    """Return (wrapped_cmd_for_shell, sandboxed) for use with shell=True.

    If sandboxing is unavailable/disabled, returns the original cmd unchanged
    with sandboxed=False. The caller is responsible for enforcing approval
    requirements when sandboxed=False.

    The sandbox is invoked as:
        bwrap [options] -- bash -c <cmd>
    so the original command runs inside bash with the same shell semantics.
    """
    state = get_sandbox_state()
    if state != SandboxState.AVAILABLE:
        return cmd, False

    profile = profile or _default_profile()
    bwrap_args = build_bwrap_args(workspace, profile)

    # Build a shell-safe command using bwrap with bash -c to preserve semantics
    import shlex
    bwrap_prefix = " ".join(shlex.quote(a) for a in bwrap_args)
    wrapped = f"{bwrap_prefix} bash -c {shlex.quote(cmd)}"
    return wrapped, True


def sandbox_info() -> dict:
    """Return a JSON-serialisable summary of sandbox state for diagnostics."""
    state = get_sandbox_state()
    bwrap = _probe_bwrap()
    return {
        "state": state.value,
        "bwrap_path": bwrap,
        "default_profile": _default_profile().value,
        "requires_approval_when_unsandboxed": requires_approval_when_unsandboxed(),
        "limitations": [
            "Does not sandbox the runtime process itself, only subprocesses",
            "Does not prevent all IPC between processes",
            "Landlock kernel path restrictions not implemented (requires C syscalls)",
            "Network isolation not applied to network_enabled and build_test profiles",
        ],
    }
