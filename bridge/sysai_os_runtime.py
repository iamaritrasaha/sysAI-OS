#!/usr/bin/env python3
"""Persistent SysAI OS runtime service.

The runtime deliberately reuses ``sysai_runner`` and the capability registry
from the Phase 4 bridge.  It changes the process boundary, not the execution
pipeline: Flutter is a local IPC client and the runtime is the owner of the
long-lived scheduler, worker threads, approvals and child processes.

Transport is newline-delimited JSON over a 0600 Unix domain socket.  Runtime
records are stored in auxiliary ``runtime_*`` tables in the existing SQLite
database.  This lets V1-V5 databases open unchanged while the runtime becomes
the authoritative writer for background execution state and event cursors.
"""
from __future__ import annotations

import argparse
import datetime as dt
import fcntl
import json
import os
import secrets
import signal
import socket
import sqlite3
import subprocess
import sys
import threading
import time
from pathlib import Path
from typing import Any, Optional
from zoneinfo import ZoneInfo

PROTOCOL_VERSION = "1"
RUNTIME_VERSION = "1.0.0"
MAX_MESSAGE_BYTES = 1024 * 1024
TICK_SECONDS = 1.0
ONCE_GRACE_SECONDS = 15 * 60


def _now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec="milliseconds")


def default_runtime_dir() -> Path:
    configured = os.environ.get("SYSAI_RUNTIME_DIR", "").strip()
    if configured:
        return Path(configured).expanduser()
    xdg = os.environ.get("XDG_RUNTIME_DIR", "").strip()
    if xdg:
        return Path(xdg) / "sysai-os"
    return Path.home() / ".local" / "state" / "sysai-os" / "runtime"


def default_db_path() -> Path:
    configured = os.environ.get("SYSAI_RUNTIME_DB", "").strip()
    if configured:
        return Path(configured).expanduser()
    state = os.environ.get("XDG_STATE_HOME", "").strip()
    root = Path(state).expanduser() if state else Path.home() / ".local" / "state"
    return root / "sysai-os" / "sysai_os.db"


def _json(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"), default=str)


def _secure_dir(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True)
    try:
        if path.stat().st_uid == os.getuid():
            os.chmod(path, 0o700)
    except OSError:
        pass


class RuntimeStore:
    """Thread-safe persistence owned by the runtime process."""

    def __init__(self, path: Path):
        self.path = path
        _secure_dir(self.path.parent)
        self.db = sqlite3.connect(str(path), check_same_thread=False, timeout=30)
        self.db.row_factory = sqlite3.Row
        self.lock = threading.RLock()
        with self.lock:
            self.db.execute("PRAGMA journal_mode=WAL")
            self.db.execute("PRAGMA foreign_keys=ON")
            self.db.executescript(
                """
                CREATE TABLE IF NOT EXISTS runtime_runs (
                    id TEXT PRIMARY KEY,
                    run_json TEXT NOT NULL,
                    status TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS runtime_events (
                    event_id INTEGER PRIMARY KEY AUTOINCREMENT,
                    run_id TEXT NOT NULL,
                    event_json TEXT NOT NULL,
                    created_at TEXT NOT NULL
                );
                CREATE INDEX IF NOT EXISTS idx_runtime_events_run
                    ON runtime_events(run_id, event_id);
                CREATE TABLE IF NOT EXISTS runtime_approvals (
                    id TEXT PRIMARY KEY,
                    run_id TEXT NOT NULL,
                    approval_json TEXT NOT NULL,
                    status TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    resolved_at TEXT
                );
                CREATE TABLE IF NOT EXISTS runtime_notifications (
                    id TEXT PRIMARY KEY,
                    notification_json TEXT NOT NULL,
                    read INTEGER NOT NULL DEFAULT 0,
                    created_at TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS runtime_automations (
                    id TEXT PRIMARY KEY,
                    automation_json TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS runtime_occurrences (
                    automation_id TEXT NOT NULL,
                    occurrence_key TEXT NOT NULL,
                    run_id TEXT,
                    created_at TEXT NOT NULL,
                    PRIMARY KEY(automation_id, occurrence_key)
                );
                """
            )
            self.db.commit()

    def close(self) -> None:
        with self.lock:
            self.db.commit()
            self.db.close()

    def save_run(self, run: dict) -> None:
        now = run.get("updated_at") or _now()
        run["updated_at"] = now
        with self.lock:
            self.db.execute(
                """INSERT INTO runtime_runs(id,run_json,status,created_at,updated_at)
                   VALUES(?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET
                   run_json=excluded.run_json,status=excluded.status,
                   updated_at=excluded.updated_at""",
                (run["id"], _json(run), run.get("status", "created"),
                 run.get("created_at", now), now),
            )
            self.db.commit()

    def get_run(self, run_id: str) -> Optional[dict]:
        with self.lock:
            row = self.db.execute("SELECT run_json FROM runtime_runs WHERE id=?", (run_id,)).fetchone()
        return json.loads(row[0]) if row else None

    def list_runs(self) -> list[dict]:
        with self.lock:
            rows = self.db.execute("SELECT run_json FROM runtime_runs ORDER BY created_at DESC").fetchall()
        return [json.loads(row[0]) for row in rows]

    def append_event(self, run_id: str, event: dict) -> int:
        with self.lock:
            cur = self.db.execute(
                "INSERT INTO runtime_events(run_id,event_json,created_at) VALUES(?,?,?)",
                (run_id, _json(event), _now()),
            )
            event_id = int(cur.lastrowid)
            self.db.commit()
        return event_id

    def events(self, run_id: str, after: int = 0) -> list[dict]:
        with self.lock:
            rows = self.db.execute(
                "SELECT event_id,event_json FROM runtime_events WHERE run_id=? AND event_id>? ORDER BY event_id",
                (run_id, after),
            ).fetchall()
        result = []
        for row in rows:
            item = json.loads(row[1])
            item["event_id"] = int(row[0])
            result.append(item)
        return result

    def save_approval(self, approval: dict) -> None:
        with self.lock:
            self.db.execute(
                """INSERT INTO runtime_approvals(id,run_id,approval_json,status,created_at,resolved_at)
                   VALUES(?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET
                   approval_json=excluded.approval_json,status=excluded.status,
                   resolved_at=excluded.resolved_at""",
                (approval["id"], approval["run_id"], _json(approval), approval.get("status", "pending"),
                 approval.get("created_at", _now()), approval.get("resolved_at")),
            )
            self.db.commit()

    def pending_approvals(self) -> list[dict]:
        with self.lock:
            rows = self.db.execute(
                "SELECT approval_json FROM runtime_approvals WHERE status='pending' ORDER BY created_at"
            ).fetchall()
        return [json.loads(row[0]) for row in rows]

    def save_notification(self, notification: dict) -> None:
        with self.lock:
            self.db.execute(
                """INSERT OR REPLACE INTO runtime_notifications(id,notification_json,read,created_at)
                   VALUES(?,?,?,?)""",
                (notification["id"], _json(notification), 1 if notification.get("read") else 0,
                 notification.get("created_at", _now())),
            )
            self.db.commit()

    def notifications(self, limit: int = 100) -> list[dict]:
        with self.lock:
            rows = self.db.execute(
                "SELECT notification_json FROM runtime_notifications ORDER BY created_at DESC LIMIT ?", (limit,)
            ).fetchall()
        return [json.loads(row[0]) for row in rows]

    def mark_notification_read(self, notification_id: str) -> bool:
        with self.lock:
            cur = self.db.execute("UPDATE runtime_notifications SET read=1 WHERE id=?", (notification_id,))
            row = self.db.execute("SELECT notification_json FROM runtime_notifications WHERE id=?", (notification_id,)).fetchone()
            if row:
                item = json.loads(row[0]); item["read"] = True
                self.db.execute("UPDATE runtime_notifications SET notification_json=? WHERE id=?", (_json(item), notification_id))
            self.db.commit()
        return cur.rowcount > 0

    def save_automation(self, automation: dict) -> None:
        with self.lock:
            self.db.execute(
                "INSERT OR REPLACE INTO runtime_automations(id,automation_json,updated_at) VALUES(?,?,?)",
                (automation["id"], _json(automation), automation.get("updated_at", _now())),
            )
            self.db.commit()

    def get_automation(self, automation_id: str) -> Optional[dict]:
        with self.lock:
            row = self.db.execute("SELECT automation_json FROM runtime_automations WHERE id=?", (automation_id,)).fetchone()
        return json.loads(row[0]) if row else None

    def automations(self) -> list[dict]:
        with self.lock:
            rows = self.db.execute("SELECT automation_json FROM runtime_automations ORDER BY updated_at DESC").fetchall()
        return [json.loads(row[0]) for row in rows]

    def delete_automation(self, automation_id: str) -> None:
        with self.lock:
            self.db.execute("DELETE FROM runtime_automations WHERE id=?", (automation_id,))
            self.db.commit()

    def claim_occurrence(self, automation_id: str, key: str, run_id: Optional[str] = None) -> bool:
        try:
            with self.lock:
                self.db.execute(
                    "INSERT INTO runtime_occurrences(automation_id,occurrence_key,run_id,created_at) VALUES(?,?,?,?)",
                    (automation_id, key, run_id, _now()),
                )
                self.db.commit()
            return True
        except sqlite3.IntegrityError:
            return False

    def link_occurrence(self, automation_id: str, key: str, run_id: str) -> None:
        with self.lock:
            self.db.execute("UPDATE runtime_occurrences SET run_id=? WHERE automation_id=? AND occurrence_key=?", (run_id, automation_id, key))
            self.db.commit()


class Client:
    def __init__(self, conn: socket.socket):
        self.conn = conn
        self.lock = threading.Lock()
        self.subscriptions: dict[str, int] = {}
        self.closed = False

    def send(self, message: dict) -> None:
        if self.closed:
            return
        data = (_json(message) + "\n").encode()
        if len(data) > MAX_MESSAGE_BYTES:
            return
        try:
            with self.lock:
                self.conn.sendall(data)
        except OSError:
            self.closed = True

    def close(self) -> None:
        self.closed = True
        try:
            self.conn.close()
        except OSError:
            pass


class Runtime:
    def __init__(self, socket_path: Path, db_path: Path):
        self.socket_path = socket_path
        self.db_path = db_path
        self.store = RuntimeStore(db_path)
        self.clients: set[Client] = set()
        self.clients_lock = threading.Lock()
        self.active_runs: set[str] = set()
        self.active_lock = threading.Lock()
        self.targets: dict[str, dict] = {}
        self.targets_lock = threading.Lock()
        self.stop_event = threading.Event()
        self.accepting = True
        self.server: Optional[socket.socket] = None
        self.started_at = time.time()
        self._run_counter = 0
        self._recover_crashed_runs()

    def _recover_crashed_runs(self) -> None:
        """Apply the existing interruption boundary after a runtime crash."""
        active = {"created", "planning", "ready", "running", "waiting_approval", "blocked", "verifying"}
        for run in self.store.list_runs():
            if run.get("status") not in active:
                continue
            event = {
                "type": "run.interrupted", "run_id": run["id"], "timestamp": _now(),
                "message": "Runtime stopped unexpectedly; Run requires attention before it can be resumed.",
            }
            self.emit_runtime_event(event)

    def ready(self) -> dict:
        try:
            import sysai_bridge
            available = bool(sysai_bridge.SYSAI_AVAILABLE)
            version = sysai_bridge.SYSAI_VERSION
            path = sysai_bridge.SYSAI_PATH_USED
        except Exception:
            available, version, path = False, "unknown", None
        return {
            "type": "ready", "protocol_version": PROTOCOL_VERSION,
            "runtime_version": RUNTIME_VERSION, "pid": os.getpid(),
            "uptime_seconds": 0, "started_at": dt.datetime.fromtimestamp(self.started_at, dt.timezone.utc).isoformat(),
            "scheduler_running": True, "sysai_available": available,
            "sysai_version": version, "sysai_path": path,
        }

    def broadcast(self, message: dict, run_id: Optional[str] = None) -> None:
        with self.clients_lock:
            clients = list(self.clients)
        for client in clients:
            if run_id is None or run_id in client.subscriptions:
                client.send(message)

    def emit_runtime_event(self, event: dict, request_id: Optional[str] = None) -> dict:
        run_id = str(event.get("run_id", ""))
        event_id = self.store.append_event(run_id, event) if run_id else 0
        event = dict(event)
        if event_id:
            event["event_id"] = event_id
        self._apply_event(run_id, event)
        envelope = {"id": request_id, "ok": True, "done": False, "event": event} if request_id else {
            "type": "runtime.event", "event": event
        }
        self.broadcast(envelope, run_id)
        return envelope

    def _apply_event(self, run_id: str, event: dict) -> None:
        if not run_id:
            return
        run = self.store.get_run(run_id)
        if not run:
            return
        typ = event.get("type", "")
        ts = event.get("timestamp", _now())
        data = {k: v for k, v in event.items() if k not in ("type", "message")}
        run.setdefault("events", []).append({"type": typ, "timestamp": ts, "message": event.get("message", ""), "data": data, "task_id": event.get("task_id")})
        status_map = {
            "planning.started": "planning", "planning.completed": "ready", "run.started": "running",
            "task.started": "running", "verification.started": "verifying", "run.completed": "completed",
            "run.failed": "failed", "run.cancelled": "cancelled", "run.interrupted": "interrupted",
            "approval.requested": "waiting_approval", "run.paused": "blocked",
        }
        if typ in status_map:
            run["status"] = status_map[typ]
        if typ == "planning.completed" and isinstance(event.get("plan"), list):
            run["plan"] = [{"id": t.get("id", ""), "title": t.get("title", ""), "description": t.get("description", ""), "dependencies": t.get("dependencies", []), "capability_hints": t.get("capability_hints", []), "status": "pending", "attempts": 1, "max_attempts": t.get("max_attempts", 1)} for t in event["plan"]]
        if typ in ("task.started", "task.completed", "task.failed"):
            for task in run.get("plan", []):
                if task.get("id") == event.get("task_id"):
                    task["status"] = {"task.started": "running", "task.completed": "completed", "task.failed": "failed"}[typ]
                    if typ == "task.failed": task["error"] = event.get("error", "")
        if typ == "model.selected":
            run.setdefault("provider_id", event.get("provider")); run.setdefault("model_id", event.get("model")); run.setdefault("model_display_name", event.get("model"))
        if typ in ("run.completed", "run.failed", "run.cancelled"):
            run["completed_at"] = ts
            if typ == "run.completed": run["outcome"] = event.get("outcome", event.get("message", ""))
            if typ == "run.failed": run["error_message"] = event.get("message", event.get("error", ""))
        if typ == "approval.requested":
            approval = {"id": event.get("approval_id", event.get("request_id", "")), "run_id": run_id, "task_id": event.get("task_id"), "capability_id": event.get("capability_id", ""), "title": event.get("title", "Approval Required"), "explanation": event.get("explanation", ""), "risk": event.get("risk", "high"), "payload": event.get("payload", {}), "status": "pending", "created_at": ts}
            run["pending_approval"] = approval; self.store.save_approval(approval)
        if typ == "approval.resolved":
            pending = run.pop("pending_approval", None)
            if pending:
                pending["status"] = "approved" if event.get("approved") else "rejected"; pending["resolved_at"] = ts; self.store.save_approval(pending)
            run["status"] = "running" if event.get("approved") else "blocked"
        run["updated_at"] = ts
        self.store.save_run(run)
        if typ in ("run.completed", "run.failed", "run.interrupted", "approval.requested"):
            ntype, title, urgency = {
                "run.completed": ("run_completed", "Run completed", "normal"),
                "run.failed": ("run_failed", "Run failed", "critical"),
                "run.interrupted": ("run_interrupted", "Run interrupted", "critical"),
                "approval.requested": ("approval_required", "Approval needed", "critical"),
            }[typ]
            self.notify(ntype, title, event.get("message", run.get("title", "")), run_id, urgency)

    def notify(self, ntype: str, title: str, message: str, run_id: Optional[str], urgency: str = "normal") -> None:
        stamp = int(time.time() * 1000000)
        notification = {"id": f"runtime-notif-{stamp}-{secrets.token_hex(3)}", "type": ntype, "title": title, "message": message, "run_id": run_id, "created_at": _now(), "read": False}
        self.store.save_notification(notification)
        try:
            if subprocess.call(["notify-send", "-u", urgency, title, message], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=3) != 0:
                pass
        except (OSError, subprocess.SubprocessError):
            pass

    def _start_run(self, run: dict, client: Optional[Client] = None, request_id: Optional[str] = None, legacy_direct: bool = False) -> None:
        if not self.accepting:
            return
        run_id = run["id"]
        with self.active_lock:
            if run_id in self.active_runs:
                return
            self.active_runs.add(run_id)

        def worker() -> None:
            try:
                import sysai_bridge
                import sysai_runner
                if not sysai_bridge.SYSAI_AVAILABLE:
                    self.emit_runtime_event({"type": "run.failed", "run_id": run_id, "timestamp": _now(), "message": "SysAI engine is unavailable."}, request_id)
                    return
                sysai_runner.execute_run(
                    req_id=request_id or f"runtime-{run_id}", run_id=run_id, goal=run.get("goal", ""),
                    emit=lambda envelope: self._runner_emit(envelope, run_id, client, request_id),
                    workspace_root=run.get("workspace_path"), provider=run.get("provider_id"), model=run.get("model_id"),
                    computer_target_available=(lambda _target: True) if legacy_direct else (lambda target: self.target_available(target)),
                )
            except Exception as exc:
                self.emit_runtime_event({"type": "run.failed", "run_id": run_id, "timestamp": _now(), "message": str(exc)}, request_id)
            finally:
                with self.active_lock: self.active_runs.discard(run_id)

        threading.Thread(target=worker, name=f"sysai-run-{run_id}", daemon=True).start()

    def request_shutdown(self) -> None:
        """Stop new work and cooperatively terminate active execution."""
        if not self.accepting:
            return
        self.accepting = False
        try:
            import sysai_runner
            with self.active_lock:
                active = list(self.active_runs)
            for run_id in active:
                sysai_runner.EXECUTION_CONTROLLER.cancel_run(run_id)
        except Exception:
            # Shutdown must still close the socket if the engine is already
            # unavailable or partially torn down.
            pass
        self.stop_event.set()

    def _runner_emit(self, envelope: dict, run_id: str, client: Optional[Client], request_id: Optional[str]) -> None:
        event = envelope.get("event")
        if event:
            routed = self.emit_runtime_event(event, request_id)
            # The execute_run caller receives its stream directly. A client
            # that also subscribed to the run already receives the broadcast
            # above, so avoid delivering a duplicate frame.
            if client and not client.closed and run_id not in client.subscriptions:
                client.send(routed)
        if envelope.get("done"):
            final = dict(envelope)
            if client and not client.closed:
                final["id"] = request_id
                client.send(final)

    def target_available(self, target_id: str) -> bool:
        with self.targets_lock:
            # The Phase 4 direct-provider test surface predates target
            # registration. Preserve that compatibility until a target has
            # explicitly registered once; after that, unregistering it is a
            # real unavailable state and actions wait for remount.
            target = self.targets.get(target_id)
            return True if target is None and target_id == "sysai-test-surface" else bool(target and target.get("available"))

    def due_automation_loop(self) -> None:
        while not self.stop_event.wait(TICK_SECONDS):
            try: self.process_automations()
            except Exception as exc: self.broadcast({"type": "runtime.warning", "message": f"Scheduler error: {exc}"})

    def process_automations(self) -> None:
        now = dt.datetime.now(dt.timezone.utc)
        for automation in self.store.automations():
            if not automation.get("enabled", True) or not automation.get("next_trigger_at"): continue
            try: trigger = dt.datetime.fromisoformat(automation["next_trigger_at"].replace("Z", "+00:00"))
            except ValueError: continue
            if trigger > now: continue
            key = automation["next_trigger_at"]
            if not self.store.claim_occurrence(automation["id"], key):
                continue
            if automation.get("schedule_type") == "once" and (now - trigger).total_seconds() > ONCE_GRACE_SECONDS:
                automation.update({"enabled": False, "next_trigger_at": None, "last_result": "missed", "updated_at": _now()}); self.store.save_automation(automation)
                self.notify("automation_missed", "Automation missed", automation.get("title", ""), None, "critical"); continue
            run_id = f"run-auto-{int(time.time()*1000000)}-{secrets.token_hex(3)}"
            run = self._new_run(run_id, automation)
            self.store.save_run(run); self.store.link_occurrence(automation["id"], key, run_id)
            automation.update({"last_run_id": run_id, "last_triggered_at": key, "updated_at": _now()})
            automation["next_trigger_at"] = self._next_trigger(automation, now)
            if automation.get("schedule_type") == "once": automation["enabled"] = False; automation["next_trigger_at"] = None
            self.store.save_automation(automation); self._start_run(run)

    def _new_run(self, run_id: str, automation: dict) -> dict:
        stamp = _now(); goal = automation.get("goal", "")
        return {"id": run_id, "title": goal[:57] + ("..." if len(goal) > 60 else ""), "goal": goal, "status": "created", "created_at": stamp, "updated_at": stamp, "plan": [], "events": [], "outcome": "", "error_message": "", "provider_id": automation.get("provider_id"), "model_id": automation.get("model_id"), "model_display_name": automation.get("model_display_name"), "workspace_path": automation.get("workspace_path")}

    def _next_trigger(self, automation: dict, now: dt.datetime) -> Optional[str]:
        typ = automation.get("schedule_type"); expr = automation.get("schedule_expression", {})
        if typ == "interval":
            minutes = max(1, int(expr.get("minutes", 60))); return (now + dt.timedelta(minutes=minutes)).isoformat()
        try: zone = ZoneInfo(automation.get("timezone", "UTC"))
        except Exception: zone = dt.timezone.utc
        local = now.astimezone(zone); hour, minute = int(expr.get("hour", local.hour)), int(expr.get("minute", local.minute))
        candidate = local.replace(hour=hour, minute=minute, second=0, microsecond=0)
        if typ == "weekly":
            weekday = int(expr.get("weekday", 1)); candidate += dt.timedelta(days=(weekday - candidate.isoweekday()) % 7)
        if candidate <= local: candidate += dt.timedelta(days=7 if typ == "weekly" else 1)
        return candidate.astimezone(dt.timezone.utc).isoformat()

    def rpc(self, request: dict, client: Client) -> Optional[dict]:
        req_id = str(request.get("id", "")); method = str(request.get("method", "")); params = request.get("params") or {}
        if not isinstance(params, dict): return {"id": req_id, "ok": False, "error": "params must be an object", "code": "invalid_params"}
        if method == "runtime.status":
            result = self.ready(); result.update({"uptime_seconds": int(time.time() - self.started_at), "active_runs": len(self.active_runs), "client_count": len(self.clients), "socket": str(self.socket_path)})
            return {"id": req_id, "ok": True, "result": result}
        if method == "runtime.shutdown":
            self.request_shutdown()
            return {"id": req_id, "ok": True, "result": {"shutting_down": True}}
        if method in ("ping", "get_config", "get_doctor", "get_memory_stats", "list_memories", "search_memory", "list_capabilities", "get_pending_approvals", "list_workspace_files", "read_workspace_file", "list_providers", "list_models", "check_model_availability"):
            import sysai_bridge
            return sysai_bridge.HANDLERS[method](req_id, params)
        if method == "run.create":
            run = params.get("run") or params
            if not isinstance(run, dict) or not run.get("id") or not run.get("goal"): return {"id": req_id, "ok": False, "error": "run requires id and goal", "code": "invalid_params"}
            self.store.save_run(dict(run)); return {"id": req_id, "ok": True, "result": {"run": self.store.get_run(run["id"])}}
        if method == "run.get": return {"id": req_id, "ok": True, "result": {"run": self.store.get_run(str(params.get("run_id", "")))}}
        if method == "run.list": return {"id": req_id, "ok": True, "result": {"runs": self.store.list_runs()}}
        if method == "execute_run":
            if not self.accepting:
                return {"id": req_id, "ok": False, "error": "Runtime is shutting down", "code": "shutting_down"}
            run_id = str(params.get("run_id", "")); run = self.store.get_run(run_id)
            if run and run.get("status") in {"completed", "failed", "cancelled", "interrupted"}:
                # A terminal Run can be explicitly re-executed by a legacy
                # bridge caller. Start a clean attempt under the same stable
                # Run id; active Runs remain single-flight below.
                stamp = _now(); goal = str(params.get("goal") or run.get("goal", "")).strip()
                run = {**run, "title": goal[:57] + ("..." if len(goal) > 60 else ""), "goal": goal,
                       "status": "created", "created_at": stamp, "updated_at": stamp,
                       "plan": [], "events": [], "outcome": "", "error_message": "",
                       "completed_at": None, "workspace_path": params.get("workspace_root", run.get("workspace_path")),
                       "provider_id": params.get("provider", run.get("provider_id")),
                       "model_id": params.get("model", run.get("model_id"))}
                self.store.save_run(run)
            if not run:
                stamp = _now(); goal = str(params.get("goal", "")).strip(); run = {"id": run_id, "title": goal[:57] + ("..." if len(goal) > 60 else ""), "goal": goal, "status": "created", "created_at": stamp, "updated_at": stamp, "plan": [], "events": [], "outcome": "", "error_message": "", "provider_id": params.get("provider"), "model_id": params.get("model"), "workspace_path": params.get("workspace_root")}; self.store.save_run(run)
            self._start_run(run, client, req_id, legacy_direct=bool(params.get("legacy_direct"))); return {"id": req_id, "ok": True, "done": False, "event": {"type": "runtime.accepted", "run_id": run_id, "timestamp": _now()}}
        if method == "events.replay":
            run_id = str(params.get("run_id", "")); after = int(params.get("after_event_id", 0)); return {"id": req_id, "ok": True, "result": {"events": self.store.events(run_id, after)}}
        if method == "events.subscribe":
            run_id = str(params.get("run_id", "")); client.subscriptions[run_id] = int(params.get("after_event_id", 0))
            for event in self.store.events(run_id, client.subscriptions[run_id]):
                client.send({"id": req_id, "ok": True, "done": False, "event": event})
            return None
        if method == "events.unsubscribe":
            client.subscriptions.pop(str(params.get("run_id", "")), None); return {"id": req_id, "ok": True, "result": {"unsubscribed": True}}
        if method in ("resolve_approval", "report_computer_action_result", "pause_run", "resume_run", "cancel_run"):
            import sysai_bridge
            return sysai_bridge.HANDLERS[method](req_id, params)
        if method == "approval.list": return {"id": req_id, "ok": True, "result": {"approvals": self.store.pending_approvals()}}
        if method == "approval.resolve":
            import sysai_bridge
            result = sysai_bridge.handle_resolve_approval(req_id, params); return result
        if method == "notification.list": return {"id": req_id, "ok": True, "result": {"notifications": self.store.notifications(int(params.get("limit", 100)))} }
        if method == "notification.mark_read": return {"id": req_id, "ok": True, "result": {"marked": self.store.mark_notification_read(str(params.get("id", "")))}}
        if method == "automation.list": return {"id": req_id, "ok": True, "result": {"automations": self.store.automations()}}
        if method in ("automation.create", "automation.update"):
            automation = params.get("automation") or params
            if not automation.get("id"): return {"id": req_id, "ok": False, "error": "automation id required", "code": "invalid_params"}
            self.store.save_automation(dict(automation)); return {"id": req_id, "ok": True, "result": {"automation": self.store.get_automation(automation["id"])}}
        if method == "automation.delete": self.store.delete_automation(str(params.get("id", ""))); return {"id": req_id, "ok": True, "result": {"deleted": True}}
        if method == "automation.run_now":
            if not self.accepting:
                return {"id": req_id, "ok": False, "error": "Runtime is shutting down", "code": "shutting_down"}
            automation = self.store.get_automation(str(params.get("id", "")))
            if not automation: return {"id": req_id, "ok": True, "result": {"run": None}}
            run = self._new_run(f"run-auto-{int(time.time()*1000000)}-{secrets.token_hex(3)}", automation); self.store.save_run(run); self._start_run(run, client, req_id); return {"id": req_id, "ok": True, "result": {"run": run}}
        if method == "computer.target.register":
            target_id = str(params.get("target_id", "")); self.targets[target_id] = {**params, "available": True}; return {"id": req_id, "ok": True, "result": {"registered": True, "target_id": target_id}}
        if method == "computer.target.unregister":
            target_id = str(params.get("target_id", "")); self.targets[target_id] = {"target_id": target_id, "available": False}; return {"id": req_id, "ok": True, "result": {"registered": False, "target_id": target_id}}
        return {"id": req_id, "ok": False, "error": f"Unknown method: {method!r}", "code": "unknown_method"}

    def client_loop(self, conn: socket.socket) -> None:
        client = Client(conn)
        with self.clients_lock: self.clients.add(client)
        client.send(self.ready())
        buffer = b""
        try:
            while not self.stop_event.is_set():
                chunk = conn.recv(65536)
                if not chunk: break
                buffer += chunk
                if len(buffer) > MAX_MESSAGE_BYTES: client.send({"ok": False, "error": "message exceeds 1 MiB limit", "code": "message_too_large"}); break
                while b"\n" in buffer:
                    raw, buffer = buffer.split(b"\n", 1); raw = raw.strip()
                    if not raw: continue
                    try: request = json.loads(raw.decode("utf-8"))
                    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
                        client.send({"ok": False, "error": f"Invalid JSON: {exc}", "code": "parse_error"}); continue
                    if not isinstance(request, dict): client.send({"ok": False, "error": "request must be an object", "code": "invalid_request"}); continue
                    def dispatch(req=request):
                        try:
                            result = self.rpc(req, client)
                            if result is not None: client.send(result)
                        except Exception as exc:
                            client.send({"id": str(req.get("id", "")), "ok": False, "error": str(exc), "code": "internal_error"})
                    threading.Thread(target=dispatch, daemon=True).start()
        finally:
            client.closed = True
            with self.clients_lock: self.clients.discard(client)
            client.close()

    def run(self) -> None:
        _secure_dir(self.socket_path.parent)
        try: self.socket_path.unlink()
        except FileNotFoundError: pass
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server.bind(str(self.socket_path)); os.chmod(self.socket_path, 0o600); self.server.listen(16); self.server.settimeout(1)
        threading.Thread(target=self.due_automation_loop, name="sysai-scheduler", daemon=True).start()
        while not self.stop_event.is_set():
            try: conn, _ = self.server.accept()
            except socket.timeout: continue
            except OSError: break
            threading.Thread(target=self.client_loop, args=(conn,), daemon=True).start()
        # Give canceled workers a short, bounded window to emit their final
        # state and let registered child processes reap before closing SQLite.
        deadline = time.time() + 5
        while self.active_runs and time.time() < deadline:
            time.sleep(0.05)
        for run_id in list(self.active_runs):
            self.emit_runtime_event({
                "type": "run.interrupted", "run_id": run_id, "timestamp": _now(),
                "message": "Runtime shut down before this Run could finish.",
            })
        try: self.server.close()
        except OSError: pass
        try: self.socket_path.unlink()
        except FileNotFoundError: pass
        self.store.close()


def main() -> int:
    parser = argparse.ArgumentParser(description="SysAI OS persistent runtime")
    parser.add_argument("--socket", type=Path, default=default_runtime_dir() / "runtime.sock")
    parser.add_argument("--db", type=Path, default=default_db_path())
    args = parser.parse_args()
    args.socket = args.socket.expanduser(); args.db = args.db.expanduser()
    _secure_dir(args.socket.parent)
    lock_path = args.socket.with_suffix(".lock")
    lock_file = open(lock_path, "a+")
    try: fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        return 2
    runtime = Runtime(args.socket, args.db)
    def stop(_sig, _frame): runtime.request_shutdown()
    signal.signal(signal.SIGTERM, stop); signal.signal(signal.SIGINT, stop)
    runtime.run()
    try: fcntl.flock(lock_file.fileno(), fcntl.LOCK_UN); lock_file.close(); lock_path.unlink()
    except OSError: pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
