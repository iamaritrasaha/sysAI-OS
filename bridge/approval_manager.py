"""
SysAI OS Approval Manager & Execution Control
============================================
Handles execution blocking for interactive approvals, cooperative pause/resume,
and clean subprocess cancellation.
"""
from __future__ import annotations

import os
import signal
import subprocess
import threading
import time
from dataclasses import dataclass, field
from typing import Any, Callable, Dict, List, Optional


@dataclass
class PendingApproval:
    id: str
    run_id: str
    task_id: Optional[str]
    capability_id: str
    title: str
    explanation: str
    risk: str
    payload: Dict[str, Any]
    created_at: float = field(default_factory=time.time)
    resolved: bool = False
    approved: bool = False
    event: threading.Event = field(default_factory=threading.Event)

    def to_dict(self) -> Dict[str, Any]:
        return {
            "id": self.id,
            "run_id": self.run_id,
            "task_id": self.task_id,
            "capability_id": self.capability_id,
            "title": self.title,
            "explanation": self.explanation,
            "risk": self.risk,
            "payload": self.payload,
            "resolved": self.resolved,
            "approved": self.approved,
        }


class ApprovalManager:
    """Manages thread-safe approval gating across runs."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._approvals: Dict[str, PendingApproval] = {}

    def create_request(
        self,
        *,
        run_id: str,
        task_id: Optional[str],
        capability_id: str,
        title: str,
        explanation: str,
        risk: str,
        payload: Dict[str, Any],
    ) -> PendingApproval:
        req_id = f"appr-{run_id}-{task_id or 'run'}-{int(time.time() * 1000)}"
        item = PendingApproval(
            id=req_id,
            run_id=run_id,
            task_id=task_id,
            capability_id=capability_id,
            title=title,
            explanation=explanation,
            risk=risk,
            payload=payload,
        )
        with self._lock:
            self._approvals[req_id] = item
        return item

    def wait_for_decision(self, request_id: str, timeout: Optional[float] = None) -> bool:
        with self._lock:
            item = self._approvals.get(request_id)
        if not item:
            return False
        # Block until resolved
        signaled = item.event.wait(timeout=timeout)
        if not signaled:
            # Timed out
            with self._lock:
                item.resolved = True
                item.approved = False
            return False
        return item.approved

    def resolve(self, request_id: str, approved: bool) -> bool:
        with self._lock:
            item = self._approvals.get(request_id)
            if not item or item.resolved:
                return False
            item.resolved = True
            item.approved = approved
            item.event.set()
            return True

    def cancel_run(self, run_id: str) -> None:
        with self._lock:
            for item in self._approvals.values():
                if item.run_id == run_id and not item.resolved:
                    item.resolved = True
                    item.approved = False
                    item.event.set()

    def get_pending(self, run_id: Optional[str] = None) -> List[Dict[str, Any]]:
        with self._lock:
            items = [
                a.to_dict()
                for a in self._approvals.values()
                if not a.resolved and (run_id is None or a.run_id == run_id)
            ]
        return items


class ExecutionController:
    """Manages cooperative pause/resume and process cancellation per run."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._paused_runs: Dict[str, threading.Event] = {}  # Set = running, Clear = paused
        self._cancelled_runs: set[str] = set()
        self._active_procs: Dict[str, subprocess.Popen] = {}

    def register_run(self, run_id: str) -> None:
        with self._lock:
            ev = threading.Event()
            ev.set()  # Initially not paused
            self._paused_runs[run_id] = ev
            self._cancelled_runs.discard(run_id)

    def pause_run(self, run_id: str) -> bool:
        with self._lock:
            ev = self._paused_runs.get(run_id)
            if ev:
                ev.clear()  # Pause
                return True
            return False

    def resume_run(self, run_id: str) -> bool:
        with self._lock:
            ev = self._paused_runs.get(run_id)
            if ev:
                ev.set()  # Unpause
                return True
            return False

    def cancel_run(self, run_id: str) -> bool:
        with self._lock:
            self._cancelled_runs.add(run_id)
            ev = self._paused_runs.get(run_id)
            if ev:
                ev.set()  # Unblock if paused
            proc = self._active_procs.pop(run_id, None)
            if proc:
                try:
                    os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
                except Exception:
                    pass
            return True

    def register_process(self, run_id: str, proc: subprocess.Popen) -> None:
        with self._lock:
            self._active_procs[run_id] = proc

    def unregister_process(self, run_id: str) -> None:
        with self._lock:
            self._active_procs.pop(run_id, None)

    def is_cancelled(self, run_id: str) -> bool:
        with self._lock:
            return run_id in self._cancelled_runs

    def wait_if_paused(self, run_id: str, on_pause: Optional[Callable[[], None]] = None) -> bool:
        """Returns False if run was cancelled while waiting."""
        with self._lock:
            ev = self._paused_runs.get(run_id)
            cancelled = run_id in self._cancelled_runs
        if cancelled:
            return False
        if ev and not ev.is_set():
            if on_pause:
                on_pause()
            ev.wait()  # Block until resume
        with self._lock:
            return run_id not in self._cancelled_runs


# Global instances shared within bridge process
APPROVAL_MANAGER = ApprovalManager()
EXECUTION_CONTROLLER = ExecutionController()
