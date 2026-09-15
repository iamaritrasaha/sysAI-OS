"""
SysAI OS Computer Action Manager
=================================
Blocks a capability-handler thread until Flutter has actually executed a
Controlled Computer Use action against a registered target and reported
the result back — the exact same request/block/resolve shape
`ApprovalManager` (approval_manager.py) already uses for interactive
approvals. `sysai_bridge.py`'s main stdin-read loop dispatches the
`report_computer_action_result` RPC while the capability handler's worker
thread sits blocked in `wait_for_result()`, unblocking it.
"""
from __future__ import annotations

import threading
import time
from dataclasses import dataclass, field
from typing import Any, Dict, Optional


@dataclass
class PendingComputerAction:
    id: str
    run_id: str
    task_id: Optional[str]
    target_id: str
    action_type: str
    selector: Optional[str]
    coordinates: Optional[Dict[str, Any]]
    text_metadata: Optional[str]
    created_at: float = field(default_factory=time.time)
    resolved: bool = False
    result: Dict[str, Any] = field(default_factory=dict)
    event: threading.Event = field(default_factory=threading.Event)

    def to_dict(self) -> Dict[str, Any]:
        return {
            "id": self.id,
            "run_id": self.run_id,
            "task_id": self.task_id,
            "target_id": self.target_id,
            "type": self.action_type,
            "selector": self.selector,
            "coordinates": self.coordinates,
            "text_metadata": self.text_metadata,
            "resolved": self.resolved,
        }


class ComputerActionManager:
    """Thread-safe request/block/resolve gating for Controlled Computer Use
    actions, one instance shared for the life of the bridge process."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._actions: Dict[str, PendingComputerAction] = {}

    def create_request(
        self,
        *,
        run_id: str,
        task_id: Optional[str],
        target_id: str,
        action_type: str,
        selector: Optional[str] = None,
        coordinates: Optional[Dict[str, Any]] = None,
        text_metadata: Optional[str] = None,
    ) -> PendingComputerAction:
        req_id = f"cact-{run_id}-{task_id or 'run'}-{int(time.time() * 1000)}"
        item = PendingComputerAction(
            id=req_id,
            run_id=run_id,
            task_id=task_id,
            target_id=target_id,
            action_type=action_type,
            selector=selector,
            coordinates=coordinates,
            text_metadata=text_metadata,
        )
        with self._lock:
            self._actions[req_id] = item
        return item

    def wait_for_result(self, request_id: str, timeout: Optional[float] = 60) -> Dict[str, Any]:
        with self._lock:
            item = self._actions.get(request_id)
        if not item:
            return {"success": False, "error": "Unknown computer action request."}

        signaled = item.event.wait(timeout=timeout)
        if not signaled:
            with self._lock:
                item.resolved = True
                item.result = {"success": False, "error": "Computer action timed out waiting for Flutter to execute it."}
                result = dict(item.result)
                self._actions.pop(request_id, None)
            return result
        with self._lock:
            result = dict(item.result)
            self._actions.pop(request_id, None)
        return result

    def resolve(
        self,
        request_id: str,
        result: Dict[str, Any],
        run_id: Optional[str] = None,
        target_id: Optional[str] = None,
    ) -> bool:
        with self._lock:
            item = self._actions.get(request_id)
            if (
                not item
                or item.resolved
                or (run_id is not None and item.run_id != run_id)
                or (target_id is not None and item.target_id != target_id)
            ):
                return False
            item.resolved = True
            item.result = result
            item.event.set()
            return True

    def cancel(self, request_id: str) -> bool:
        return self.resolve(request_id, {"success": False, "cancelled": True, "error": "Computer action cancelled."})

    def cancel_run(self, run_id: str) -> None:
        with self._lock:
            for item in self._actions.values():
                if item.run_id == run_id and not item.resolved:
                    item.resolved = True
                    item.result = {"success": False, "cancelled": True, "error": "Run cancelled."}
                    item.event.set()


# Global instance shared within the bridge process, alongside APPROVAL_MANAGER.
COMPUTER_ACTION_MANAGER = ComputerActionManager()
