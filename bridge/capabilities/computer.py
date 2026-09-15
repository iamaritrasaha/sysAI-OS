"""
SysAI OS Computer Capability — Controlled Computer Use
========================================================
Observation and capture are real when the host environment supports them.
Input/mutation (click/type/key/scroll) is real *only* against explicitly
registered SysAI-owned targets — currently just `sysai-test-surface`, a
deterministic Flutter surface. Since the Python bridge is a separate
subprocess with no access to the live Flutter widget tree, executing one
of these actions is a request/block/resolve round-trip through
`ComputerActionManager` (mirroring how interactive approvals already
work): this handler emits `computer.action.requested`, blocks, and Flutter
performs the real widget callback and reports the result back via the
`report_computer_action_result` RPC.

Any `target_id` that isn't a registered target is refused outright — this
is the enforcement point for "arbitrary desktop targets remain denied,"
backed by target identity, not just UI convention. There is no path here
that ever touches OS-level input or any window SysAI does not own.
"""
from __future__ import annotations

import os
import shutil
import subprocess
import time
from pathlib import Path
from typing import Any, Dict

from computer_action_manager import COMPUTER_ACTION_MANAGER

# The only Controlled Computer Use target implemented in this phase. A
# `registered-window` target type is modeled on the Dart side
# (ComputerTargetType.registeredWindow) but intentionally has no handler
# here yet — same posture Phase 3 took with click/type/key before this
# phase gave them a real implementation.
KNOWN_TARGETS = {"sysai-test-surface"}

# Screenshot tools checked in preference order. None of these is bundled or
# installed by SysAI OS — if the host has one, capture works; if not, we say
# so rather than fabricating an image.
_SCREENSHOT_TOOLS = [
    ("scrot", ["scrot", "-o"]),
    ("gnome-screenshot", ["gnome-screenshot", "-f"]),
    ("grim", ["grim"]),
    ("import", ["import", "-window", "root"]),
    ("maim", ["maim"]),
    ("spectacle", ["spectacle", "-b", "-n", "-o"]),
]


def _find_screenshot_tool():
    for name, _ in _SCREENSHOT_TOOLS:
        if shutil.which(name):
            return name
    return None


def handle_computer_observe(params: Dict[str, Any], context: Dict[str, Any]) -> Dict[str, Any]:
    target_id = str(params.get("target_id", ""))
    if target_id in KNOWN_TARGETS:
        # Observing a registered target returns its actual control
        # manifest (ids + bounds) from Flutter, not host display info —
        # this is what lets click/type/scroll address a `selector`
        # reliably instead of guessing pixel coordinates.
        return _execute_controlled_action("observe", params, context)

    display = os.environ.get("DISPLAY")
    session_type = os.environ.get("XDG_SESSION_TYPE", "unknown")
    resolution = None

    if display:
        try:
            proc = subprocess.run(
                ["xdpyinfo"], capture_output=True, text=True, timeout=5,
                env={**os.environ, "DISPLAY": display},
            )
            for line in proc.stdout.splitlines():
                line = line.strip()
                if line.startswith("dimensions:"):
                    resolution = line.split(":", 1)[1].strip().split()[0]
                    break
        except (OSError, subprocess.SubprocessError):
            pass

    return {
        "success": True,
        "available": display is not None,
        "display": display,
        "session_type": session_type,
        "resolution": resolution,
        "screenshot_tool": _find_screenshot_tool(),
    }


def handle_computer_capture(params: Dict[str, Any], context: Dict[str, Any]) -> Dict[str, Any]:
    target_id = str(params.get("target_id", ""))
    if target_id in KNOWN_TARGETS:
        # A registered SysAI-owned target is rendered by Flutter, not the
        # host desktop — capture it via the same render-tree mechanism
        # (RepaintBoundary) used for the rest of Controlled Computer Use,
        # not an OS screenshot tool. This is also what makes captures work
        # in headless/CI environments with no screenshot utility at all.
        return _execute_controlled_action("capture", params, context)

    tool = _find_screenshot_tool()
    run_id = context.get("run_id", "")
    session_id = f"computer-{run_id}" if run_id else "computer-standalone"

    if not tool:
        return {
            "success": False,
            "available": False,
            "session_id": session_id,
            "reason": "No screenshot utility found on this host (checked scrot, gnome-screenshot, "
                      "grim, import, maim, spectacle). Capture is architecturally supported but "
                      "inert without one of these installed.",
        }

    ws_root = Path(context.get("workspace_root", os.getcwd()))
    out_dir = ws_root / ".sysai_os" / "captures"
    out_dir.mkdir(parents=True, exist_ok=True)
    out_path = out_dir / f"capture-{int(time.time() * 1000)}.png"

    _, cmd_prefix = next(t for t in _SCREENSHOT_TOOLS if t[0] == tool)
    try:
        subprocess.run(cmd_prefix + [str(out_path)], capture_output=True, timeout=10, check=True)
    except (OSError, subprocess.SubprocessError) as exc:
        return {"success": False, "available": True, "session_id": session_id, "reason": f"Capture failed: {exc}"}

    if context.get("emit"):
        context["emit"]({
            "type": "computer.capture.created",
            "run_id": run_id,
            "session_id": session_id,
            "path": str(out_path.relative_to(ws_root)) if out_path.is_relative_to(ws_root) else str(out_path),
        })

    rel_path = str(out_path.relative_to(ws_root)) if out_path.is_relative_to(ws_root) else str(out_path)
    return {
        "success": True,
        "available": True,
        "session_id": session_id,
        "path": rel_path,
        "artifact": {
            "type": "screenshot",
            "title": "Desktop capture",
            "path": rel_path,
            "metadata": {"tool": tool},
        },
    }


def _execute_controlled_action(
    action_type: str,
    params: Dict[str, Any],
    context: Dict[str, Any],
    *,
    selector_key: str = "selector",
) -> Dict[str, Any]:
    run_id = str(context.get("run_id", ""))
    task_id = context.get("task_id")
    target_id = str(params.get("target_id", ""))
    emit = context.get("emit")

    if target_id not in KNOWN_TARGETS:
        if emit:
            emit({
                "type": "computer.action.denied",
                "run_id": run_id,
                "task_id": task_id,
                "action": action_type,
                "target_id": target_id,
                "reason": "unregistered_target",
            })
        return {
            "success": False,
            "error": f"Unknown or unregistered computer target: {target_id!r}. "
                     f"Controlled Computer Use only acts on explicitly registered SysAI-owned targets.",
        }

    coordinates = params.get("coordinates")
    if coordinates is None and ("x" in params or "y" in params):
        coordinates = {"x": params.get("x"), "y": params.get("y")}

    request = COMPUTER_ACTION_MANAGER.create_request(
        run_id=run_id,
        task_id=task_id,
        target_id=target_id,
        action_type=action_type,
        selector=params.get(selector_key),
        coordinates=coordinates,
        text_metadata=params.get("text") if action_type == "type" else params.get("key") if action_type == "key" else params.get("direction"),
    )

    if emit:
        emit({
            "type": "computer.action.requested",
            "run_id": run_id,
            "task_id": task_id,
            "request_id": request.id,
            "action": action_type,
            "target_id": target_id,
            "selector": request.selector,
            "coordinates": request.coordinates,
            "text_metadata": request.text_metadata,
        })

    result = COMPUTER_ACTION_MANAGER.wait_for_result(request.id, timeout=60)

    if emit:
        emit({
            "type": "computer.action.completed",
            "run_id": run_id,
            "task_id": task_id,
            "request_id": request.id,
            "action": action_type,
            "target_id": target_id,
            "success": bool(result.get("success")),
        })

    return result


def handle_computer_click(params: Dict[str, Any], context: Dict[str, Any]) -> Dict[str, Any]:
    return _execute_controlled_action("click", params, context)


def handle_computer_type(params: Dict[str, Any], context: Dict[str, Any]) -> Dict[str, Any]:
    return _execute_controlled_action("type", params, context)


def handle_computer_key(params: Dict[str, Any], context: Dict[str, Any]) -> Dict[str, Any]:
    return _execute_controlled_action("key", params, context)


def handle_computer_scroll(params: Dict[str, Any], context: Dict[str, Any]) -> Dict[str, Any]:
    return _execute_controlled_action("scroll", params, context)
