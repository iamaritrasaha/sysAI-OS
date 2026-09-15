"""
SysAI OS Capability Registry
============================
Registers and executes all capabilities exposed by SysAI OS:
- filesystem (read, list, stat, write, mkdir)
- shell (execute)
- git (status, diff, log)
- system (environment)
- sysai (diagnostics, model_status, experience_query)
"""
from __future__ import annotations

import os
import platform
import signal
import subprocess
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional

from approval_manager import EXECUTION_CONTROLLER
from capabilities import browser as browser_capabilities
from capabilities import computer as computer_capabilities


@dataclass
class Capability:
    id: str
    name: str
    description: str
    category: str  # filesystem | shell | git | system | sysai
    risk: str  # observe | low | medium | high | privileged
    requires_approval: bool = False
    input_schema: Dict[str, Any] = field(default_factory=dict)
    handler: Optional[Callable[[Dict[str, Any], Dict[str, Any]], Dict[str, Any]]] = None

    def to_dict(self) -> Dict[str, Any]:
        return {
            "id": self.id,
            "name": self.name,
            "description": self.description,
            "category": self.category,
            "risk": self.risk,
            "requires_approval": self.requires_approval,
            "input_schema": self.input_schema,
        }

    def execute(self, params: Dict[str, Any], context: Dict[str, Any]) -> Dict[str, Any]:
        if not self.handler:
            raise RuntimeError(f"Capability '{self.id}' has no registered handler.")
        return self.handler(params, context)


class CapabilityRegistry:
    def __init__(self) -> None:
        self._capabilities: Dict[str, Capability] = {}

    def register(self, capability: Capability) -> None:
        self._capabilities[capability.id] = capability

    def get(self, capability_id: str) -> Optional[Capability]:
        return self._capabilities.get(capability_id)

    def list_all(self) -> List[Capability]:
        return list(self._capabilities.values())

    def to_dict_list(self) -> List[Dict[str, Any]]:
        return [c.to_dict() for c in self._capabilities.values()]


# ── Canonical Workspace Resolver ──────────────────────────────────────────────

def _resolve_in_workspace(path_str: str, workspace_root: Path) -> Path:
    """
    Resolves path_str relative to workspace_root and validates that the canonical
    target path is within the canonical workspace_root.
    Raises PermissionError if traversal outside workspace occurs.
    """
    ws_root = workspace_root.resolve()
    target = (ws_root / path_str).resolve() if not os.path.isabs(path_str) else Path(path_str).resolve()

    # Boundary check
    if target != ws_root and ws_root not in target.parents:
        raise PermissionError(
            f"Path traversal denied: '{path_str}' resolves to '{target}' which is outside workspace '{ws_root}'"
        )
    return target


# ── Handlers: Filesystem ──────────────────────────────────────────────────────

def _handle_fs_read(params: Dict[str, Any], context: Dict[str, Any]) -> Dict[str, Any]:
    ws_root = Path(context.get("workspace_root", os.getcwd()))
    raw_path = params.get("path", "")
    target = _resolve_in_workspace(raw_path, ws_root)

    if not target.exists():
        return {"error": f"File not found: {raw_path}", "exists": False}
    if not target.is_file():
        return {"error": f"Path is a directory: {raw_path}", "is_file": False}

    max_bytes = int(params.get("max_bytes", 100_000))
    offset = int(params.get("offset", 0))

    file_size = target.stat().st_size
    with target.open("rb") as f:
        if offset > 0:
            f.seek(offset)
        content_bytes = f.read(max_bytes)

    try:
        text = content_bytes.decode("utf-8")
        is_binary = False
    except UnicodeDecodeError:
        text = f"[Binary file: {len(content_bytes)} bytes]"
        is_binary = True

    rel_path = str(target.relative_to(ws_root.resolve()))
    return {
        "path": rel_path,
        "content": text,
        "size": file_size,
        "bytes_read": len(content_bytes),
        "is_binary": is_binary,
        "is_truncated": (offset + len(content_bytes)) < file_size,
    }


def _handle_fs_list(params: Dict[str, Any], context: Dict[str, Any]) -> Dict[str, Any]:
    ws_root = Path(context.get("workspace_root", os.getcwd()))
    raw_path = params.get("path", ".")
    target = _resolve_in_workspace(raw_path, ws_root)

    if not target.exists():
        return {"error": f"Directory not found: {raw_path}", "exists": False}
    if not target.is_dir():
        return {"error": f"Path is not a directory: {raw_path}", "is_dir": False}

    entries = []
    max_items = int(params.get("max_items", 100))

    for entry in sorted(target.iterdir(), key=lambda p: (not p.is_dir(), p.name.lower())):
        if len(entries) >= max_items:
            break
        # Skip excessive hidden dirs (.git internals)
        if entry.name in [".git", ".dart_tool", "__pycache__"]:
            entries.append({
                "name": entry.name,
                "path": str(entry.relative_to(ws_root.resolve())),
                "is_dir": True,
                "size": 0,
                "modified": time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(entry.stat().st_mtime)),
                "ignored_children": True,
            })
            continue

        try:
            st = entry.stat()
            entries.append({
                "name": entry.name,
                "path": str(entry.relative_to(ws_root.resolve())),
                "is_dir": entry.is_dir(),
                "size": st.st_size if not entry.is_dir() else 0,
                "modified": time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(st.st_mtime)),
            })
        except Exception:
            continue

    rel_path = str(target.relative_to(ws_root.resolve())) if target != ws_root.resolve() else "."
    return {
        "path": rel_path,
        "entries": entries,
        "count": len(entries),
    }


def _handle_fs_stat(params: Dict[str, Any], context: Dict[str, Any]) -> Dict[str, Any]:
    ws_root = Path(context.get("workspace_root", os.getcwd()))
    raw_path = params.get("path", "")
    target = _resolve_in_workspace(raw_path, ws_root)

    if not target.exists():
        return {"exists": False, "path": raw_path}

    st = target.stat()
    rel_path = str(target.relative_to(ws_root.resolve())) if target != ws_root.resolve() else "."
    return {
        "exists": True,
        "path": rel_path,
        "is_file": target.is_file(),
        "is_dir": target.is_dir(),
        "size": st.st_size,
        "modified": time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(st.st_mtime)),
        "permissions": oct(st.st_mode)[-3:],
    }


def _handle_fs_write(params: Dict[str, Any], context: Dict[str, Any]) -> Dict[str, Any]:
    ws_root = Path(context.get("workspace_root", os.getcwd()))
    raw_path = params.get("path", "")
    content = params.get("content", "")
    append = bool(params.get("append", False))

    target = _resolve_in_workspace(raw_path, ws_root)
    existed = target.exists()

    # Ensure parent directories exist
    target.parent.mkdir(parents=True, exist_ok=True)

    mode = "a" if append else "w"
    with target.open(mode, encoding="utf-8") as f:
        f.write(content)

    rel_path = str(target.relative_to(ws_root.resolve()))
    bytes_written = len(content.encode("utf-8"))

    # Return artifact metadata for tracking
    return {
        "path": rel_path,
        "bytes_written": bytes_written,
        "created": not existed,
        "modified": existed,
        "artifact": {
            "type": "file",
            "title": target.name,
            "path": rel_path,
            "content_preview": content[:500] if len(content) > 500 else content,
            "metadata": {
                "size": target.stat().st_size,
                "bytes_written": bytes_written,
                "appended": append,
            },
        },
    }


def _handle_fs_mkdir(params: Dict[str, Any], context: Dict[str, Any]) -> Dict[str, Any]:
    ws_root = Path(context.get("workspace_root", os.getcwd()))
    raw_path = params.get("path", "")
    parents = bool(params.get("parents", True))
    target = _resolve_in_workspace(raw_path, ws_root)

    existed = target.exists()
    target.mkdir(parents=parents, exist_ok=True)
    rel_path = str(target.relative_to(ws_root.resolve()))
    return {
        "path": rel_path,
        "created": not existed,
    }


# ── Handlers: Shell / Terminal ─────────────────────────────────────────────────

# Bound how much output a single command session buffers/streams. Past this,
# we keep counting but stop retaining lines — full output belongs in the
# session's artifact/log, not in memory or in a flood of UI events.
_TERMINAL_MAX_BUFFERED_LINES = 2000


def _handle_shell_execute(params: Dict[str, Any], context: Dict[str, Any]) -> Dict[str, Any]:
    ws_root = Path(context.get("workspace_root", os.getcwd()))
    raw_cwd = params.get("cwd", ".")
    target_cwd = _resolve_in_workspace(raw_cwd, ws_root)

    cmd = params.get("cmd", "").strip()
    if not cmd:
        return {"error": "No command provided", "success": False}

    purpose = params.get("purpose", "Shell command")
    timeout = int(params.get("timeout", 60))

    run_id = str(context.get("run_id", ""))
    task_id = context.get("task_id")
    emit = context.get("emit")
    rel_cwd = str(target_cwd.relative_to(ws_root.resolve())) if target_cwd != ws_root.resolve() else "."
    session_id = f"term-{run_id or 'standalone'}-{int(time.time() * 1000)}"

    def _emit_event(event_type: str, **kwargs: Any) -> None:
        if emit:
            emit({"type": event_type, "run_id": run_id, "task_id": task_id, "session_id": session_id, **kwargs})

    _emit_event("terminal.session.created", command=cmd, cwd=rel_cwd, purpose=purpose)

    try:
        proc = subprocess.Popen(
            cmd,
            shell=True,
            cwd=str(target_cwd),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
            start_new_session=True,  # Process group for clean kill
        )
    except Exception as exc:
        _emit_event("terminal.session.completed", exit_code=-1, success=False, error=str(exc))
        return {"command": cmd, "purpose": purpose, "session_id": session_id, "error": str(exc), "success": False}

    # Registered immediately (not after the blocking wait below) so
    # cancel_run() can actually find and kill this process group while the
    # command is still running, not only after it has already finished.
    if run_id:
        EXECUTION_CONTROLLER.register_process(run_id, proc)
    if "active_process_holder" in context:
        context["active_process_holder"]["proc"] = proc

    stdout_lines: List[str] = []
    stderr_lines: List[str] = []
    truncated = {"stdout": False, "stderr": False}

    def _reader(stream, sink: List[str], stream_name: str) -> None:
        try:
            for line in iter(stream.readline, ""):
                if len(sink) < _TERMINAL_MAX_BUFFERED_LINES:
                    sink.append(line)
                    _emit_event("terminal.output", stream=stream_name, line=line.rstrip("\n"))
                else:
                    truncated[stream_name] = True
        finally:
            try:
                stream.close()
            except Exception:
                pass

    t_out = threading.Thread(target=_reader, args=(proc.stdout, stdout_lines, "stdout"), daemon=True)
    t_err = threading.Thread(target=_reader, args=(proc.stderr, stderr_lines, "stderr"), daemon=True)
    t_out.start()
    t_err.start()

    try:
        try:
            proc.wait(timeout=timeout)
            timed_out = False
        except subprocess.TimeoutExpired:
            os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
            try:
                proc.wait(timeout=3)
            except Exception:
                os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
            timed_out = True

        t_out.join(timeout=2)
        t_err.join(timeout=2)
    finally:
        if run_id:
            EXECUTION_CONTROLLER.unregister_process(run_id)

    stdout = "".join(stdout_lines)
    stderr = "".join(stderr_lines)
    combined_output = stdout + stderr
    exit_code = proc.returncode if not timed_out else -1
    success = proc.returncode == 0 and not timed_out
    any_truncated = truncated["stdout"] or truncated["stderr"]

    _emit_event(
        "terminal.session.completed",
        exit_code=exit_code,
        success=success,
        timed_out=timed_out,
        truncated=any_truncated,
    )

    result: Dict[str, Any] = {
        "command": cmd,
        "purpose": purpose,
        "cwd": rel_cwd,
        "session_id": session_id,
        "stdout": stdout,
        "stderr": stderr,
        "output": combined_output[:4000],
        "exit_code": exit_code,
        "success": success,
        "timed_out": timed_out,
        "truncated": any_truncated,
    }

    # Meaningful-artifact criteria: a failed or substantial command becomes a
    # durable terminal log. A short, successful command (e.g. `git status`)
    # does not need to permanently clutter the artifact list.
    if not success or len(combined_output) > 500:
        result["artifact"] = {
            "type": "terminal_log",
            "title": f"Terminal: {cmd[:40]}",
            "content_preview": combined_output[:600],
            "metadata": {
                "command": cmd,
                "exit_code": exit_code,
                "timed_out": timed_out,
                "session_id": session_id,
                "truncated": any_truncated,
            },
        }
    return result


# ── Handlers: Git ─────────────────────────────────────────────────────────────

def _handle_git_status(_params: Dict[str, Any], context: Dict[str, Any]) -> Dict[str, Any]:
    ws_root = Path(context.get("workspace_root", os.getcwd()))
    try:
        res = subprocess.run(
            ["git", "status", "--porcelain"],
            cwd=str(ws_root),
            capture_output=True,
            text=True,
            timeout=10,
        )
        if res.returncode != 0:
            return {"is_git_repo": False, "status": "", "clean": True}
        output = res.stdout.strip()
        return {
            "is_git_repo": True,
            "status": output,
            "clean": len(output) == 0,
            "changes_count": len([l for l in output.splitlines() if l.strip()]),
        }
    except Exception as exc:
        return {"error": str(exc), "is_git_repo": False}


def _handle_git_diff(params: Dict[str, Any], context: Dict[str, Any]) -> Dict[str, Any]:
    ws_root = Path(context.get("workspace_root", os.getcwd()))
    cmd = ["git", "diff"]
    if params.get("staged"):
        cmd.append("--staged")
    path = params.get("path")
    if path:
        cmd.extend(["--", path])

    try:
        res = subprocess.run(
            cmd,
            cwd=str(ws_root),
            capture_output=True,
            text=True,
            timeout=10,
        )
        diff_text = res.stdout
        return {
            "diff": diff_text[:5000],
            "has_diff": len(diff_text.strip()) > 0,
            "is_truncated": len(diff_text) > 5000,
        }
    except Exception as exc:
        return {"error": str(exc), "has_diff": False}


def _handle_git_log(params: Dict[str, Any], context: Dict[str, Any]) -> Dict[str, Any]:
    ws_root = Path(context.get("workspace_root", os.getcwd()))
    max_count = int(params.get("max_count", 10))
    try:
        res = subprocess.run(
            ["git", "log", f"-n{max_count}", "--oneline"],
            cwd=str(ws_root),
            capture_output=True,
            text=True,
            timeout=10,
        )
        if res.returncode != 0:
            return {"is_git_repo": False, "commits": []}
        lines = [l.strip() for l in res.stdout.splitlines() if l.strip()]
        return {"is_git_repo": True, "commits": lines}
    except Exception as exc:
        return {"error": str(exc), "commits": []}


# ── Handlers: System ──────────────────────────────────────────────────────────

def _handle_system_env(_params: Dict[str, Any], context: Dict[str, Any]) -> Dict[str, Any]:
    ws_root = Path(context.get("workspace_root", os.getcwd()))
    return {
        "os": platform.system(),
        "release": platform.release(),
        "arch": platform.machine(),
        "python_version": platform.python_version(),
        "workspace_root": str(ws_root.resolve()),
        "user": os.environ.get("USER", "unknown"),
        "hostname": platform.node(),
    }


# ── Handlers: SysAI Engine ───────────────────────────────────────────────────

def _handle_sysai_diagnostics(params: Dict[str, Any], context: Dict[str, Any]) -> Dict[str, Any]:
    try:
        from sysai.doctor import run_doctor
        probe = bool(params.get("probe_model", False))
        # run_doctor() accepts an explicit Config and honors it completely
        # (see sysai/doctor.py: `config = config or load_config()`); the bug
        # was here, not in the engine — passing nothing silently fell back
        # to load_config()'s config.toml/hardcoded default, so a Run's
        # model probe would test "qwen3:8b" even when the Run explicitly
        # selected a different model. Thread the Run's isolated config
        # through so the probe checks the model the Run actually selected.
        return run_doctor(context.get("run_config"), probe_model=probe)
    except Exception as exc:
        return {"error": f"SysAI doctor failed: {exc}", "available": False}


def _handle_sysai_model_status(_params: Dict[str, Any], context: Dict[str, Any]) -> Dict[str, Any]:
    try:
        from sysai.config import load_config
        cfg = context.get("run_config") or load_config()
        return {
            "provider": cfg.provider,
            "model": cfg.model,
            "ollama_url": cfg.ollama_url,
            "history_enabled": cfg.history_enabled,
            "thinking": cfg.thinking,
        }
    except Exception as exc:
        return {"error": str(exc), "available": False}


def _handle_sysai_experience(params: Dict[str, Any], _context: Dict[str, Any]) -> Dict[str, Any]:
    try:
        from sysai.memory import stats, search, list_memories
        query = params.get("query")
        limit = int(params.get("limit", 20))
        if query:
            records = search(query, limit=limit)
        else:
            records = list_memories(limit=limit)
        return {
            "stats": stats(),
            "memories": records,
            "count": len(records),
        }
    except Exception as exc:
        return {"error": str(exc), "available": False}


# ── Default Registry Factory ──────────────────────────────────────────────────

def get_default_registry() -> CapabilityRegistry:
    registry = CapabilityRegistry()

    # Filesystem
    registry.register(Capability(
        id="filesystem.read",
        name="Read File",
        description="Reads text or content from a file inside the workspace boundary.",
        category="filesystem",
        risk="low",
        requires_approval=False,
        input_schema={"path": "string", "max_bytes": "integer?", "offset": "integer?"},
        handler=_handle_fs_read,
    ))
    registry.register(Capability(
        id="filesystem.list",
        name="List Directory",
        description="Lists entries and metadata for a directory inside the workspace.",
        category="filesystem",
        risk="observe",
        requires_approval=False,
        input_schema={"path": "string?", "max_items": "integer?"},
        handler=_handle_fs_list,
    ))
    registry.register(Capability(
        id="filesystem.stat",
        name="Stat File/Directory",
        description="Inspects file metadata, permissions, and existence.",
        category="filesystem",
        risk="observe",
        requires_approval=False,
        input_schema={"path": "string"},
        handler=_handle_fs_stat,
    ))
    registry.register(Capability(
        id="filesystem.write",
        name="Write File",
        description="Creates or updates a file inside the workspace, tracking it as an artifact.",
        category="filesystem",
        risk="high",
        requires_approval=True,
        input_schema={"path": "string", "content": "string", "append": "boolean?"},
        handler=_handle_fs_write,
    ))
    registry.register(Capability(
        id="filesystem.mkdir",
        name="Create Directory",
        description="Creates a new directory inside the workspace boundary.",
        category="filesystem",
        risk="medium",
        requires_approval=False,
        input_schema={"path": "string", "parents": "boolean?"},
        handler=_handle_fs_mkdir,
    ))

    # Shell
    registry.register(Capability(
        id="shell.execute",
        name="Execute Shell Command",
        description="Executes a command inside the workspace with separated stdout/stderr and timeout protection.",
        category="shell",
        risk="medium",
        requires_approval=False,  # Evaluated dynamically by PolicyEngine
        input_schema={"cmd": "string", "purpose": "string?", "cwd": "string?", "timeout": "integer?"},
        handler=_handle_shell_execute,
    ))

    # Git
    registry.register(Capability(
        id="git.status",
        name="Git Status",
        description="Inspects Git working tree status of the workspace.",
        category="git",
        risk="observe",
        requires_approval=False,
        handler=_handle_git_status,
    ))
    registry.register(Capability(
        id="git.diff",
        name="Git Diff",
        description="Inspects uncommitted changes in the workspace.",
        category="git",
        risk="observe",
        requires_approval=False,
        input_schema={"staged": "boolean?", "path": "string?"},
        handler=_handle_git_diff,
    ))
    registry.register(Capability(
        id="git.log",
        name="Git Log",
        description="Reads recent commit history of the workspace repository.",
        category="git",
        risk="observe",
        requires_approval=False,
        input_schema={"max_count": "integer?"},
        handler=_handle_git_log,
    ))

    # System
    registry.register(Capability(
        id="system.environment",
        name="System Environment",
        description="Inspects platform, architecture, and toolchain versions.",
        category="system",
        risk="observe",
        requires_approval=False,
        handler=_handle_system_env,
    ))

    # SysAI Engine
    registry.register(Capability(
        id="sysai.diagnostics",
        name="SysAI Diagnostics",
        description="Runs deterministic SysAI engine diagnostics and doctor checks.",
        category="sysai",
        risk="observe",
        requires_approval=False,
        input_schema={"probe_model": "boolean?"},
        handler=_handle_sysai_diagnostics,
    ))
    registry.register(Capability(
        id="sysai.model_status",
        name="SysAI Model Status",
        description="Queries active model provider, configuration, and endpoint status.",
        category="sysai",
        risk="observe",
        requires_approval=False,
        handler=_handle_sysai_model_status,
    ))
    registry.register(Capability(
        id="sysai.experience_query",
        name="SysAI Experience Query",
        description="Queries the Experience Engine SQLite database for learned patterns and memories.",
        category="sysai",
        risk="observe",
        requires_approval=False,
        input_schema={"query": "string?", "limit": "integer?"},
        handler=_handle_sysai_experience,
    ))

    # Browser
    registry.register(Capability(
        id="browser.search",
        name="Web Search",
        description="Searches the web and returns result links relevant to a query.",
        category="browser",
        risk="low",
        requires_approval=False,
        input_schema={"query": "string"},
        handler=browser_capabilities.handle_browser_search,
    ))
    registry.register(Capability(
        id="browser.navigate",
        name="Navigate to Page",
        description="Loads a URL and extracts its title, text, and links.",
        category="browser",
        risk="low",
        requires_approval=False,
        input_schema={"url": "string"},
        handler=browser_capabilities.handle_browser_navigate,
    ))
    registry.register(Capability(
        id="browser.read",
        name="Read Page",
        description="Reads the substance of a page (fetch + extract).",
        category="browser",
        risk="observe",
        requires_approval=False,
        input_schema={"url": "string"},
        handler=browser_capabilities.handle_browser_read,
    ))
    registry.register(Capability(
        id="browser.follow_link",
        name="Follow Link",
        description="Navigates to a link found on a previously read page.",
        category="browser",
        risk="low",
        requires_approval=False,
        input_schema={"base_url": "string?", "href": "string"},
        handler=browser_capabilities.handle_browser_follow_link,
    ))
    registry.register(Capability(
        id="browser.download",
        name="Download File",
        description="Downloads a remote file into the workspace.",
        category="browser",
        risk="medium",
        requires_approval=True,
        input_schema={"url": "string", "path": "string"},
        handler=browser_capabilities.handle_browser_download,
    ))
    registry.register(Capability(
        id="browser.capture",
        name="Capture Page",
        description="Persists a text/HTML snapshot of a page as an artifact (not a pixel screenshot).",
        category="browser",
        risk="low",
        requires_approval=False,
        input_schema={"url": "string?", "text": "string?", "title": "string?"},
        handler=browser_capabilities.handle_browser_capture,
    ))

    # Computer / Desktop
    registry.register(Capability(
        id="computer.observe",
        name="Observe Desktop",
        description="Reports display/session information for the host desktop.",
        category="computer",
        risk="observe",
        requires_approval=False,
        handler=computer_capabilities.handle_computer_observe,
    ))
    registry.register(Capability(
        id="computer.capture",
        name="Capture Screen",
        description="Takes a screenshot if a screenshot utility is available on the host.",
        category="computer",
        risk="low",
        requires_approval=False,
        handler=computer_capabilities.handle_computer_capture,
    ))
    registry.register(Capability(
        id="computer.click",
        name="Controlled Click",
        description="Clicks a control on an explicitly registered SysAI-owned target (e.g. the test surface).",
        category="computer",
        risk="medium",
        requires_approval=False,  # Evaluated dynamically by PolicyEngine, per target
        input_schema={"target_id": "string", "selector": "string?", "x": "integer?", "y": "integer?"},
        handler=computer_capabilities.handle_computer_click,
    ))
    registry.register(Capability(
        id="computer.type",
        name="Controlled Type",
        description="Types text into a control on an explicitly registered SysAI-owned target.",
        category="computer",
        risk="privileged",
        requires_approval=True,
        input_schema={"target_id": "string", "selector": "string?", "text": "string?"},
        handler=computer_capabilities.handle_computer_type,
    ))
    registry.register(Capability(
        id="computer.key",
        name="Controlled Key Press",
        description="Sends a key press to an explicitly registered SysAI-owned target.",
        category="computer",
        risk="privileged",
        requires_approval=True,
        input_schema={"target_id": "string", "selector": "string?", "key": "string?"},
        handler=computer_capabilities.handle_computer_key,
    ))
    registry.register(Capability(
        id="computer.scroll",
        name="Controlled Scroll",
        description="Scrolls a region on an explicitly registered SysAI-owned target.",
        category="computer",
        risk="medium",
        requires_approval=False,  # Evaluated dynamically by PolicyEngine, per target
        input_schema={"target_id": "string", "selector": "string?", "direction": "string?"},
        handler=computer_capabilities.handle_computer_scroll,
    ))

    return registry
