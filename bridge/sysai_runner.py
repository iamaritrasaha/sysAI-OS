"""
SysAI_OS Agent Runner — Phase 2
===============================
Implements the Phase 2 agentic execution environment:
- Capability Registry execution
- Deterministic Policy Engine gating (ALLOW, REQUIRE_APPROVAL, DENY)
- Approval Domain: interactive blocking wait for human decision
- Artifact Generation and tracking
- Execution Checkpoints for pause/resume and crash recovery
- Subprocess lifecycle management and clean cancellation
"""
from __future__ import annotations

import os
import sys
import time
import json
import traceback
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional

from approval_manager import APPROVAL_MANAGER, EXECUTION_CONTROLLER
from computer_action_manager import COMPUTER_ACTION_MANAGER
from capabilities.registry import CapabilityRegistry, get_default_registry
from policy.policy_engine import PolicyEngine, PolicyVerdict

Emitter = Callable[[dict], None]


# ── Event Helpers ─────────────────────────────────────────────────────────────

def _event(emit: Emitter, req_id: str, run_id: str, event_type: str, **kwargs) -> None:
    kw_type = kwargs.pop("type", None)
    if kw_type is not None:
        kwargs["artifact_type"] = kw_type
    emit({
        "id": req_id,
        "ok": True,
        "done": False,
        "event": {
            "type": event_type,
            "run_id": run_id,
            "timestamp": _now(),
            **kwargs,
        },
    })


def _done(emit: Emitter, req_id: str, status: str, outcome: str = "") -> None:
    emit({
        "id": req_id,
        "ok": True,
        "done": True,
        "result": {"status": status, "outcome": outcome},
    })


def _now() -> str:
    import datetime
    return datetime.datetime.now().astimezone().isoformat(timespec="milliseconds")


# ── Plan Generation ───────────────────────────────────────────────────────────

def _generate_plan(goal: str) -> List[Dict[str, Any]]:
    """
    Generates a structured plan for the given goal using registered capabilities.
    Includes task dependencies, descriptions, and retry configuration.
    """
    goal_lower = goal.lower()

    # Controlled Computer Use — the Phase 4 vertical slice: observe the
    # registered test surface, type into it, click submit, then capture
    # the resulting state to verify the action actually landed. Checked
    # first and with specific multi-word phrases deliberately: goals that
    # mention this feature also tend to contain the bare word "test"
    # (e.g. "the computer test surface"), which would otherwise be
    # swallowed by the unrelated "run the test suite" branch below.
    if any(kw in goal_lower for kw in ["test surface", "computer test", "click submit", "type into"]):
        return [
            {
                "id": "t1",
                "title": "Observe the SysAI OS test surface",
                "capability": "computer.observe",
                "params": {"target_id": "sysai-test-surface"},
                "description": "Inspects the controlled target before acting on it.",
                "dependencies": [],
            },
            {
                "id": "t2",
                "title": "Type into the text field",
                "capability": "computer.type",
                "params": {"target_id": "sysai-test-surface", "selector": "main_field", "text": "hello from sysai"},
                "description": "Types a value into the controlled target's text field (requires approval).",
                "dependencies": ["t1"],
            },
            {
                "id": "t3",
                "title": "Click Submit",
                "capability": "computer.click",
                "params": {"target_id": "sysai-test-surface", "selector": "submit_button"},
                "description": "Clicks the controlled target's submit control.",
                "dependencies": ["t2"],
            },
            {
                "id": "t4",
                "title": "Capture the resulting state",
                "capability": "computer.capture",
                "params": {"target_id": "sysai-test-surface"},
                "description": "Captures the controlled target to verify the action actually changed its state.",
                "dependencies": ["t3"],
            },
            {
                "id": "t5",
                "title": "Synthesize outcome",
                "capability": "_synthesize",
                "params": {},
                "description": "Summarizes what was observed, typed, clicked, and captured.",
                "dependencies": ["t4"],
            },
        ]

    # Workspace write / file creation / report generation
    if any(kw in goal_lower for kw in ["write", "create file", "create", "report.md", "generate report", "save", "release notes"]):
        return [
            {
                "id": "t1",
                "title": "Inspect workspace environment",
                "capability": "system.environment",
                "params": {},
                "description": "Inspect OS and platform environment.",
                "dependencies": [],
            },
            {
                "id": "t2",
                "title": "Check repository git status",
                "capability": "git.status",
                "params": {},
                "description": "Check if working tree is clean.",
                "dependencies": ["t1"],
            },
            {
                "id": "t3",
                "title": "Write summary report to workspace",
                "capability": "filesystem.write",
                "params": {
                    "path": "workspace_report.md",
                    "content": (
                        "# Workspace Execution Report\n\n"
                        "Generated autonomously by **SysAI OS Phase 2**.\n\n"
                        "- State: Verified\n"
                        "- Environment: Healthy\n"
                        "- Policy: Governed with Approval Gating\n"
                    ),
                },
                "description": "Writes the summary report to the workspace (requires approval).",
                "dependencies": ["t2"],
            },
            {
                "id": "t4",
                "title": "Verify written artifact",
                "capability": "filesystem.stat",
                "params": {"path": "workspace_report.md"},
                "description": "Verifies artifact file existence and metadata.",
                "dependencies": ["t3"],
            },
            {
                "id": "t5",
                "title": "Synthesize execution outcome",
                "capability": "_synthesize",
                "params": {},
                "description": "Summarizes run results and artifacts.",
                "dependencies": ["t4"],
            },
        ]

    # Health / diagnostics / doctor
    if any(kw in goal_lower for kw in ["health", "diagnos", "doctor", "inspect", "healthy", "build environment"]):
        return [
            {
                "id": "t1",
                "title": "Gather SysAI configuration",
                "capability": "sysai.model_status",
                "params": {},
                "description": "Reads active model and provider settings.",
                "dependencies": [],
            },
            {
                "id": "t2",
                "title": "Run SysAI doctor diagnostics",
                "capability": "sysai.diagnostics",
                "params": {"probe_model": True},
                "description": "Executes engine health checks.",
                "dependencies": ["t1"],
            },
            {
                "id": "t3",
                "title": "Query experience store",
                "capability": "sysai.experience_query",
                "params": {"limit": 10},
                "description": "Inspects recurring patterns and learned experience.",
                "dependencies": ["t1"],
            },
            {
                "id": "t4",
                "title": "Verify Flutter toolchain",
                "capability": "shell.execute",
                "params": {
                    "cmd": "flutter doctor --no-version-check 2>&1 | head -25",
                    "purpose": "Check toolchain status",
                },
                "description": "Verifies Flutter and Dart SDK availability.",
                "dependencies": [],
            },
            {
                "id": "t5",
                "title": "Run Flutter static analysis",
                "capability": "shell.execute",
                "params": {
                    "cmd": "flutter analyze --no-pub 2>&1 | head -30",
                    "purpose": "Check codebase issues",
                },
                "description": "Executes static analysis on workspace.",
                "dependencies": ["t4"],
            },
            {
                "id": "t6",
                "title": "Synthesize diagnostic findings",
                "capability": "_synthesize",
                "params": {},
                "description": "Formulates complete system health synthesis.",
                "dependencies": ["t2", "t5"],
            },
        ]

    # Test related
    if any(kw in goal_lower for kw in ["test", "tests", "failing", "unit test", "widget test"]):
        return [
            {
                "id": "t1",
                "title": "Run Flutter test suite",
                "capability": "shell.execute",
                "params": {
                    "cmd": "flutter test --reporter=compact 2>&1 | tail -30",
                    "purpose": "Execute test suite",
                },
                "description": "Runs all unit and widget tests.",
                "dependencies": [],
                "max_attempts": 2,
            },
            {
                "id": "t2",
                "title": "Analyze test results",
                "capability": "_synthesize",
                "params": {},
                "description": "Summarizes test results and coverage.",
                "dependencies": ["t1"],
            },
        ]

    # Dependency research / upgrade investigation — the Phase 3 vertical
    # slice: filesystem inspection, a real web search + read, then a
    # verification command, spanning three operational surfaces in one Run.
    if any(kw in goal_lower for kw in ["dependency", "dependencies", "upgrade", "newer version", "latest version", "latest stable"]):
        return [
            {
                "id": "t1",
                "title": "Inspect project dependency manifest",
                "capability": "filesystem.read",
                "params": {"path": "pubspec.yaml"},
                "description": "Reads the project's declared dependencies and current versions.",
                "dependencies": [],
            },
            {
                "id": "t2",
                "title": "Search for the latest stable Flutter release",
                "capability": "browser.search",
                "params": {"query": "Flutter SDK latest stable release version"},
                "description": "Searches the web for current release information.",
                "dependencies": ["t1"],
            },
            {
                "id": "t3",
                "title": "Read the top result for release details",
                "capability": "browser.navigate",
                "params": {"url": "https://docs.flutter.dev/release/release-notes"},
                "description": "Reads a release-notes page for version and compatibility details.",
                "dependencies": ["t2"],
            },
            {
                "id": "t4",
                "title": "Run the test suite to verify current compatibility",
                "capability": "shell.execute",
                "params": {
                    "cmd": "flutter test --reporter=compact 2>&1 | tail -30",
                    "purpose": "Verify tests pass before recommending any upgrade",
                },
                "description": "Confirms the project's current, known-good baseline before suggesting a change.",
                "dependencies": ["t1"],
                "max_attempts": 2,
            },
            {
                "id": "t5",
                "title": "Synthesize upgrade recommendation",
                "capability": "_synthesize",
                "params": {},
                "description": "Reports current vs. latest version and whether upgrading looks safe.",
                "dependencies": ["t3", "t4"],
            },
        ]

    # Default / Generic
    return [
        {
            "id": "t1",
            "title": "Gather platform environment",
            "capability": "system.environment",
            "params": {},
            "description": "Inspects host system parameters.",
            "dependencies": [],
        },
        {
            "id": "t2",
            "title": "Inspect SysAI engine diagnostics",
            "capability": "sysai.diagnostics",
            "params": {"probe_model": False},
            "description": "Gathers baseline diagnostics.",
            "dependencies": ["t1"],
        },
        {
            "id": "t3",
            "title": "Synthesize outcome",
            "capability": "_synthesize",
            "params": {},
            "description": "Formulates final report.",
            "dependencies": ["t2"],
        },
    ]


# ── Synthesis Helper ──────────────────────────────────────────────────────────

def _synthesize(goal: str, collected_results: List[Dict[str, Any]]) -> str:
    lines = [f"### Execution Summary for: {goal}", ""]

    for task in collected_results:
        title = task.get("title", "Task")
        result = task.get("result", {})
        status = task.get("status", "completed")
        icon = "✓" if status == "completed" else "✗"
        lines.append(f"{icon} **{title}**")

        if "error" in result:
            lines.append(f"  - Error: {result['error']}")
            continue

        if "artifact" in result:
            art = result["artifact"]
            lines.append(f"  - Created Artifact: `{art.get('title')}` ({art.get('type')})")

        if "overall" in result:
            lines.append(f"  - Doctor Overall: **{result.get('overall')}** ({result.get('attention_count', 0)} attention items)")

        elif "output" in result and result.get("output"):
            output_snippet = result["output"].strip().split("\n")[:4]
            lines.append("  - Output snippet:")
            for l in output_snippet:
                if l.strip():
                    lines.append(f"    > {l}")

        elif "entries" in result:
            lines.append(f"  - Found {len(result['entries'])} directory entries.")

        elif "content" in result:
            lines.append(f"  - Content preview: `{result['content'][:100]}...`")

        lines.append("")

    return "\n".join(lines)


# ── Main Run Execution Loop ───────────────────────────────────────────────────

def _model_profile_provider(profile: Any) -> str:
    """Normalize the provider identity stored in a SysAI model profile."""
    provider_name = str(getattr(profile, "provider", "")).lower().replace("_", "-")
    profile_id = str(getattr(profile, "id", "")).lower()
    if provider_name == "ollama" and profile_id.startswith("remote-ollama"):
        return "remote-ollama"
    if provider_name in ("openai", "openai-compatible", "remote"):
        return "openai-compatible"
    return provider_name


def _native_model_name(provider: str, model: str) -> str:
    """Strip only a known ModelInfo provider namespace from a model ID."""
    value = model.strip()
    provider_name = provider.lower().replace("_", "-")
    prefixes = {provider_name}
    if provider_name in ("ollama", "remote-ollama"):
        prefixes.update(("ollama", "remote-ollama"))
    elif provider_name in ("openai", "openai-compatible", "remote"):
        prefixes.update(("openai", "openai-compatible", "remote"))
    elif provider_name == "ollama-cloud":
        prefixes.add("ollama-cloud")
    for prefix in prefixes:
        marker = prefix + ":"
        if value.lower().startswith(marker):
            return value[len(marker):]
    return value


def execute_run(
    *,
    req_id: str,
    run_id: str,
    goal: str,
    emit: Emitter,
    workspace_root: Optional[str] = None,
    provider: Optional[str] = None,
    model: Optional[str] = None,
    computer_target_available: Optional[Callable[[str], bool]] = None,
) -> None:
    """
    Executes a Run using the Phase 2 agentic architecture:
    Plan -> Policy Check -> Approval Gating -> Capability Execution -> Checkpoints -> Verify -> Complete
    """
    if not workspace_root:
        workspace_root = str(Path(__file__).resolve().parent.parent)

    ws_root = Path(workspace_root).resolve()
    registry = get_default_registry()
    policy_engine = PolicyEngine(default_require_write_approval=True)

    EXECUTION_CONTROLLER.register_run(run_id)

    emit_ev = lambda etype, **kw: _event(emit, req_id, run_id, etype, **kw)
    active_proc_holder: Dict[str, Any] = {}

    # 0. Model & Provider resolution and availability pre-flight check
    target_provider = str(provider).strip() if provider else ""
    target_model = str(model).strip() if model else ""
    run_config = None

    try:
        from sysai.config import load_config, load_model_profiles
        import dataclasses
        base_cfg = load_config()
        if not target_provider:
            active_profile = next(
                (profile for profile in load_model_profiles()
                 if profile.id == getattr(base_cfg, "active_model_id", "")),
                None,
            )
            target_provider = (
                _model_profile_provider(active_profile)
                if active_profile is not None
                else base_cfg.provider
            )
        if not target_model:
            from sysai_bridge import _check_model_available, _discover_models
            avail, _ = _check_model_available(target_provider, base_cfg.model, base_cfg)
            if avail:
                target_model = base_cfg.model
            else:
                discovered = _discover_models(base_cfg)
                avail_models = [m for m in discovered if m.get("available") and m.get("provider") == target_provider]
                if not avail_models:
                    avail_models = [m for m in discovered if m.get("available")]
                if avail_models:
                    selected = avail_models[0]
                    target_model = str(selected.get("name") or selected.get("id", ""))
                    # Discovery IDs are namespaced for the UI (for example
                    # ``ollama:llama3``), while the provider API expects the
                    # provider-native model name.
                    if target_model.startswith(f"{target_provider}:"):
                        target_model = target_model.split(":", 1)[1]
                else:
                    target_model = base_cfg.model

        # Flutter stores the namespaced ModelInfo.id (for example
        # ``remote-ollama:audit-model``) so the selection remains unique in
        # the UI. SysAI clients expect only the provider-native model name;
        # normalize once before availability checks, profile lookup, and
        # every downstream provider call.
        target_model = _native_model_name(target_provider, target_model)

        # Flutter persists the provider/model selection, not a mutable global
        # client. Rehydrate endpoint/auth settings from the selected profile
        # for this Run so concurrent Runs cannot inherit each other's backend.
        from sysai_bridge import _check_model_available
        selected_profile = None
        for profile in load_model_profiles():
            if _model_profile_provider(profile) != target_provider:
                continue
            if profile.name == target_model or profile.id == getattr(base_cfg, "active_model_id", ""):
                selected_profile = profile
                break
        if selected_profile is not None:
            base_cfg = dataclasses.replace(
                base_cfg,
                provider=target_provider,
                model=target_model,
                ollama_url=(selected_profile.base_url
                            if target_provider in ("ollama", "remote-ollama")
                            else base_cfg.ollama_url),
                ollama_auth_env=(selected_profile.api_key_env
                                 if target_provider in ("ollama", "remote-ollama")
                                 else base_cfg.ollama_auth_env),
                model_endpoint=selected_profile.base_url,
                api_key_env=selected_profile.api_key_env,
                active_model_id=selected_profile.id,
            )
        is_available, unavail_reason = _check_model_available(target_provider, target_model, base_cfg)
        if not is_available:
            emit_ev(
                "model.unavailable",
                provider=target_provider,
                model=target_model,
                reason=unavail_reason,
            )
            err_msg = f"Selected model '{target_model}' ({target_provider}) is unavailable: {unavail_reason}"
            emit_ev("run.failed", message=err_msg, detail=unavail_reason)
            _done(emit, req_id, "failed", err_msg)
            return

        run_config = dataclasses.replace(base_cfg, provider=target_provider, model=target_model)
    except ImportError:
        # The runtime cannot safely invent a provider/model when SysAI is not
        # installed. Keep the selection empty and let the normal unavailable
        # model path report an actionable configuration error.
        target_provider = target_provider.strip()
        target_model = target_model.strip()

    # Emit model.selected structured event (safe, no secrets leaked)
    emit_ev(
        "model.selected",
        provider=target_provider,
        model=target_model,
        local=(target_provider == "ollama"),
    )

    def _emit_capability_event(event_dict: Dict[str, Any]) -> None:
        """Adapter for capability handlers (terminal/browser/computer), which
        author their own event dicts (`{"type": ..., ...}`) directly rather
        than going through `emit_ev`. Wraps them in the same
        `{"id", "ok", "done", "event"}` streaming envelope every other event
        uses — skipping this silently misroutes the event on the Dart side
        instead of raising, so it's easy to get wrong without noticing."""
        event_dict = dict(event_dict)
        event_dict.setdefault("timestamp", _now())
        emit({"id": req_id, "ok": True, "done": False, "event": event_dict})

    context: Dict[str, Any] = {
        "workspace_root": str(ws_root),
        "run_id": run_id,
        "emit": _emit_capability_event,
        "active_process_holder": active_proc_holder,
        "run_config": run_config,
        "provider": target_provider,
        "model": target_model,
        # The persistent runtime supplies this callback so a controlled
        # Computer action can wait honestly for its Flutter-owned target to
        # remount after a UI disconnect. Direct bridge callers keep the
        # Phase 4 behavior when no callback is supplied.
        "computer_target_available": computer_target_available,
        "is_cancelled": lambda: EXECUTION_CONTROLLER.is_cancelled(run_id),
    }

    step_index = 0

    try:
        # 1. Planning stage
        emit_ev("planning.started", message="Analyzing goal and assembling execution plan")
        time.sleep(0.2)

        plan = _generate_plan(goal)

        emit_ev(
            "planning.completed",
            message=f"Plan generated with {len(plan)} tasks",
            plan=[
                {
                    "id": t["id"],
                    "title": t["title"],
                    "description": t.get("description", ""),
                    "dependencies": t.get("dependencies", []),
                    "capability": t.get("capability", ""),
                }
                for t in plan
            ],
        )

        # Checkpoint: After plan
        step_index += 1
        emit_ev(
            "checkpoint.created",
            step_index=step_index,
            state={"phase": "planned", "tasks_count": len(plan)},
        )

        emit_ev("run.started", message="Beginning autonomous execution")

        collected_results: List[Dict[str, Any]] = []
        any_task_failed = False

        # 2. Task execution loop
        for task in plan:
            task_id = task["id"]
            title = task["title"]
            capability_id = task.get("capability", "")
            params = task.get("params", {})
            max_attempts = int(task.get("max_attempts", 1))

            # Every capability handler can see which task invoked it — new
            # capabilities (terminal, browser, computer) use this to
            # associate sessions/events with the right task.
            context["task_id"] = task_id

            # Check cooperative pause / cancellation
            if not EXECUTION_CONTROLLER.wait_if_paused(
                run_id,
                on_pause=lambda: emit_ev("run.paused", message="Execution paused by user"),
            ):
                emit_ev("run.cancelled", message="Run cancelled by user")
                _done(emit, req_id, "cancelled", "Run cancelled by user.")
                return

            emit_ev(
                "task.started",
                task_id=task_id,
                title=title,
                capability=capability_id,
                description=task.get("description", ""),
            )

            # Special case: internal synthesizer
            if capability_id == "_synthesize":
                emit_ev("capability.started", task_id=task_id, action="Synthesizing findings")
                summary = _synthesize(goal, collected_results)
                emit_ev("capability.completed", task_id=task_id, action="Synthesis complete")
                emit_ev("task.completed", task_id=task_id, title=title)
                collected_results.append({
                    "task_id": task_id,
                    "title": title,
                    "status": "completed",
                    "result": {"summary": summary},
                })
                continue

            capability = registry.get(capability_id)
            if not capability:
                any_task_failed = True
                err_msg = f"Unknown capability: {capability_id}"
                emit_ev("task.failed", task_id=task_id, title=title, error=err_msg)
                collected_results.append({
                    "task_id": task_id,
                    "title": title,
                    "status": "failed",
                    "result": {"error": err_msg},
                })
                continue

            # 3. Policy Evaluation
            decision = policy_engine.evaluate(capability_id, params, context)

            if decision.verdict == PolicyVerdict.DENY:
                any_task_failed = True
                err_msg = f"Policy DENIED capability '{capability_id}': {decision.reason}"
                emit_ev(
                    "capability.denied",
                    task_id=task_id,
                    capability_id=capability_id,
                    reason=decision.reason,
                    risk=decision.risk,
                    explanation=decision.explanation,
                )
                emit_ev("task.failed", task_id=task_id, title=title, error=err_msg)
                collected_results.append({
                    "task_id": task_id,
                    "title": title,
                    "status": "failed",
                    "result": {"error": err_msg},
                })
                continue

            # 4. Interactive Approval Gating
            if decision.verdict == PolicyVerdict.REQUIRE_APPROVAL:
                approval_req = APPROVAL_MANAGER.create_request(
                    run_id=run_id,
                    task_id=task_id,
                    capability_id=capability_id,
                    title=f"Approve {capability.name}",
                    explanation=decision.explanation or decision.reason,
                    risk=decision.risk,
                    payload=params,
                )

                emit_ev(
                    "approval.requested",
                    request_id=approval_req.id,
                    approval_id=approval_req.id,
                    task_id=task_id,
                    capability_id=capability_id,
                    title=approval_req.title,
                    explanation=approval_req.explanation,
                    risk=approval_req.risk,
                    payload=params,
                )

                # Block waiting for user decision
                approved = APPROVAL_MANAGER.wait_for_decision(approval_req.id, timeout=300)

                emit_ev(
                    "approval.resolved",
                    request_id=approval_req.id,
                    approval_id=approval_req.id,
                    task_id=task_id,
                    approved=approved,
                )

                if not approved:
                    any_task_failed = True
                    err_msg = f"Operation '{capability.name}' was rejected by user."
                    emit_ev("task.failed", task_id=task_id, title=title, error=err_msg)
                    collected_results.append({
                        "task_id": task_id,
                        "title": title,
                        "status": "failed",
                        "result": {"error": err_msg},
                    })
                    continue

            # 5. Capability Execution with retry support
            task_success = False
            task_result: Dict[str, Any] = {}

            for attempt in range(1, max_attempts + 1):
                # Cancellation must win over retry: a killed attempt must
                # never respawn. Without this check a cancelled Run whose
                # task allows retries would immediately start the next
                # attempt (and its subprocess) after cancel_run().
                if EXECUTION_CONTROLLER.is_cancelled(run_id):
                    break
                if attempt > 1:
                    emit_ev(
                        "task.retrying",
                        task_id=task_id,
                        attempt=attempt,
                        max_attempts=max_attempts,
                    )

                emit_ev(
                    "capability.started",
                    task_id=task_id,
                    capability_id=capability_id,
                    action=capability.description,
                )

                try:
                    task_result = capability.execute(params, context)

                    # Check for subprocess registration
                    if "proc" in active_proc_holder:
                        EXECUTION_CONTROLLER.register_process(run_id, active_proc_holder["proc"])

                    # If capability returned an artifact, emit artifact.created
                    if "artifact" in task_result:
                        art = task_result["artifact"]
                        emit_ev(
                            "artifact.created",
                            task_id=task_id,
                            artifact_id=f"art-{run_id}-{task_id}",
                            artifact_type=art.get("type", "file"),
                            title=art.get("title", ""),
                            path=art.get("path"),
                            content_preview=art.get("content_preview"),
                            metadata=art.get("metadata", {}),
                        )

                    success = task_result.get("success", True) and "error" not in task_result
                    if success:
                        emit_ev(
                            "capability.completed",
                            task_id=task_id,
                            capability_id=capability_id,
                            result_summary=str(task_result)[:200],
                        )
                        emit_ev("task.completed", task_id=task_id, title=title)
                        task_success = True
                        break
                    else:
                        err = task_result.get("error", "Execution returned non-zero exit code")
                        emit_ev(
                            "capability.failed",
                            task_id=task_id,
                            capability_id=capability_id,
                            error=err,
                        )
                except Exception as exc:
                    tb = traceback.format_exc()
                    task_result = {"error": str(exc), "traceback": tb}
                    emit_ev(
                        "capability.failed",
                        task_id=task_id,
                        capability_id=capability_id,
                        error=str(exc),
                    )
                finally:
                    EXECUTION_CONTROLLER.unregister_process(run_id)

            if EXECUTION_CONTROLLER.is_cancelled(run_id):
                emit_ev("run.cancelled", message="Run cancelled by user")
                _done(emit, req_id, "cancelled", "Run cancelled by user.")
                return

            if not task_success:
                any_task_failed = True
                emit_ev(
                    "task.failed",
                    task_id=task_id,
                    title=title,
                    error=task_result.get("error", "Failed after retries"),
                )

            collected_results.append({
                "task_id": task_id,
                "title": title,
                "status": "completed" if task_success else "failed",
                "result": task_result,
            })

            # Checkpoint: After task completes
            step_index += 1
            emit_ev(
                "checkpoint.created",
                step_index=step_index,
                state={
                    "completed_task": task_id,
                    "tasks_remaining": len(plan) - len(collected_results),
                },
            )

        # 6. Verification Stage
        emit_ev("verification.started", message="Reviewing execution evidence and outputs")
        time.sleep(0.2)

        # Build outcome summary
        final_summary = ""
        for r in reversed(collected_results):
            if r.get("result", {}).get("summary"):
                final_summary = r["result"]["summary"]
                break

        if not final_summary:
            final_summary = _synthesize(goal, collected_results)

        emit_ev(
            "verification.completed",
            message="Verification confirmed",
            outcome=final_summary[:500],
        )

        # 7. A plan can continue after an individual task failure so later
        # independent tasks still produce evidence, but the Run must not be
        # reported as successful when any task failed.
        if any_task_failed:
            failure_message = "One or more Run tasks failed."
            emit_ev("run.failed", message=failure_message, outcome=final_summary)
            _done(emit, req_id, "failed", failure_message)
        else:
            emit_ev(
                "run.completed",
                message="Run completed successfully",
                outcome=final_summary,
            )
            _done(emit, req_id, "completed", final_summary)

    except Exception as exc:
        tb = traceback.format_exc()
        emit_ev("run.failed", message=f"Execution failed: {exc}", detail=tb[:1000])
        _done(emit, req_id, "failed", str(exc))
    finally:
        APPROVAL_MANAGER.cancel_run(run_id)
        COMPUTER_ACTION_MANAGER.cancel_run(run_id)
