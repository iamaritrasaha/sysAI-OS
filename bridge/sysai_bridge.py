#!/usr/bin/env python3
"""
SysAI_OS Bridge Server — Phase 2
================================
The legacy adapter communicates over stdin/stdout using newline-delimited JSON
(NDJSON). The production runtime imports this adapter in-process and exposes
the same request/response handlers over its local Unix-domain-socket protocol.

The bridge imports SysAI modules directly using the path configured
via SYSAI_PATH (environment variable or .sysai_path file in project root).
It does NOT modify SysAI in any way — it is strictly a read-and-call adapter.

Features in Phase 2:
- Capability Registry inspection (`list_capabilities`)
- Approval resolution (`resolve_approval`, `get_pending_approvals`)
- Run control (`pause_run`, `resume_run`, `cancel_run`)
- Direct workspace exploration (`list_workspace_files`, `read_workspace_file`)
- Streaming run execution with policy gating, checkpoints, and artifacts
"""
from __future__ import annotations

import json
import os
import sys
import threading
import traceback
from pathlib import Path
from typing import Any

# Ensure bridge directory is on sys.path
BRIDGE_DIR = Path(__file__).resolve().parent
if str(BRIDGE_DIR) not in sys.path:
    sys.path.insert(0, str(BRIDGE_DIR))

from approval_manager import APPROVAL_MANAGER, EXECUTION_CONTROLLER
from computer_action_manager import COMPUTER_ACTION_MANAGER
from capabilities.registry import get_default_registry


# ── SysAI discovery ──────────────────────────────────────────────────────────

def _find_sysai_path() -> Path | None:
    """Locate SysAI src directory using discovery order:
    1. SYSAI_PATH env var
    2. .sysai_path file in bridge/ parent (project root)
    3. Sibling directory: ../SysAI/src or ../../Projects/sysai/src
    """
    env_path = os.environ.get("SYSAI_PATH")
    if env_path:
        p = Path(env_path)
        if (p / "sysai").is_dir():
            return p
        if (p / "src" / "sysai").is_dir():
            return p / "src"
        _warn(f"SYSAI_PATH set to {env_path!r} but no sysai module found there")

    # .sysai_path file
    project_root = Path(__file__).resolve().parent.parent
    dot_file = project_root / ".sysai_path"
    if dot_file.exists():
        candidate = Path(dot_file.read_text(encoding="utf-8").strip())
        if (candidate / "sysai").is_dir():
            return candidate
        if (candidate / "src" / "sysai").is_dir():
            return candidate / "src"

    # Sibling heuristics
    candidates = [
        project_root.parent / "sysai" / "src",
        project_root.parent / "SysAI" / "src",
        project_root.parent.parent / "Projects" / "sysai" / "src",
        project_root.parent.parent / "sysai" / "src",
    ]
    for c in candidates:
        if c.is_dir() and (c / "sysai").is_dir():
            return c

    # Installed venv / engine directory (production install)
    try:
        from sysai_paths import PATHS
        venv_path = PATHS.find_sysai_in_venv()
        if venv_path:
            return venv_path
        engine_path = PATHS.find_sysai_in_engine_install()
        if engine_path:
            return engine_path
    except ImportError:
        pass  # sysai_paths not available (very early bootstrap)

    return None


def _warn(msg: str) -> None:
    print(json.dumps({"type": "warn", "message": msg}), flush=True)


# ── Import SysAI ─────────────────────────────────────────────────────────────

SYSAI_SRC = _find_sysai_path()
SYSAI_AVAILABLE = False
SYSAI_PATH_USED = str(SYSAI_SRC) if SYSAI_SRC else None

if SYSAI_SRC:
    if str(SYSAI_SRC) not in sys.path:
        sys.path.insert(0, str(SYSAI_SRC))
    try:
        import dataclasses
        from sysai.config import (
            Config,
            config_dir,
            load_config,
            load_model_profiles,
            load_private_env,
            persistent_state_dir,
        )
        from sysai.doctor import run_doctor
        from sysai.memory import list_memories, search as memory_search, stats as memory_stats
        from sysai.ollama import OllamaManager
        from sysai.providers import (
            PROVIDER_CAPABILITIES,
            OllamaCloudProvider,
            OpenAICompatibleProvider,
        )
        from sysai import __version__ as SYSAI_VERSION
        SYSAI_AVAILABLE = True
    except Exception as exc:
        _warn(f"SysAI import failed: {exc}")
        SYSAI_VERSION = "unknown"
else:
    SYSAI_VERSION = "unknown"


# ── Response helpers ──────────────────────────────────────────────────────────

def _ok(request_id: str, result: Any) -> dict:
    return {"id": request_id, "ok": True, "result": result}


def _err(request_id: str, message: str, code: str = "error") -> dict:
    return {"id": request_id, "ok": False, "error": message, "code": code}


def _unavailable(request_id: str) -> dict:
    return _err(
        request_id,
        f"SysAI engine is unavailable. Expected installation at: {SYSAI_PATH_USED or 'undiscovered'}. "
        "Set SYSAI_PATH environment variable or create a .sysai_path file in the SysAI_OS root.",
        "sysai_unavailable",
    )


# ── Method handlers ───────────────────────────────────────────────────────────

def handle_ping(req_id: str, _params: dict) -> dict:
    return _ok(req_id, {
        "alive": True,
        "bridge_version": "2.0.0",
        "sysai_available": SYSAI_AVAILABLE,
        "sysai_version": SYSAI_VERSION,
        "sysai_path": SYSAI_PATH_USED,
    })


def handle_get_config(req_id: str, _params: dict) -> dict:
    if not SYSAI_AVAILABLE:
        return _unavailable(req_id)
    try:
        cfg = load_config()
        return _ok(req_id, {
            "provider": cfg.provider,
            "model": cfg.model,
            "ollama_url": cfg.ollama_url,
            "history_enabled": cfg.history_enabled,
            "thinking": cfg.thinking,
            "verbosity": cfg.verbosity,
            "config_dir": str(config_dir()),
        })
    except Exception as exc:
        return _err(req_id, str(exc))


def handle_get_doctor(req_id: str, params: dict) -> dict:
    if not SYSAI_AVAILABLE:
        return _unavailable(req_id)
    try:
        probe = params.get("probe_model", False)
        configured = load_config()
        effective = configured
        # Keep SysAI's config file untouched, but make the OS health surface
        # report the live provider state rather than a stale unavailable
        # default. The selected model is used for this diagnostic snapshot
        # only; execution applies the same dynamic selection policy.
        configured_available, _ = _check_model_available(
            configured.provider, configured.model, configured
        )
        if not configured_available:
            for candidate in _discover_models(configured):
                if candidate.get("available"):
                    effective = dataclasses.replace(
                        configured,
                        provider=str(candidate["provider"]),
                        model=str(candidate["name"]),
                    )
                    break
        result = run_doctor(effective, probe_model=probe)
        result["configured_model"] = configured.model
        result["effective_model"] = effective.model
        return _ok(req_id, result)
    except Exception as exc:
        return _err(req_id, f"Doctor failed: {exc}")


def handle_get_memory_stats(req_id: str, _params: dict) -> dict:
    if not SYSAI_AVAILABLE:
        return _unavailable(req_id)
    try:
        return _ok(req_id, memory_stats())
    except Exception as exc:
        return _err(req_id, str(exc))


def handle_list_memories(req_id: str, params: dict) -> dict:
    if not SYSAI_AVAILABLE:
        return _unavailable(req_id)
    try:
        mem_type = params.get("type")
        status = params.get("status")
        limit = int(params.get("limit", 50))
        records = list_memories(type=mem_type, status=status, limit=limit)
        return _ok(req_id, {"memories": records, "count": len(records)})
    except Exception as exc:
        return _err(req_id, str(exc))


def handle_search_memory(req_id: str, params: dict) -> dict:
    if not SYSAI_AVAILABLE:
        return _unavailable(req_id)
    try:
        query = str(params.get("query", ""))
        limit = int(params.get("limit", 20))
        records = memory_search(query, limit=limit)
        return _ok(req_id, {"memories": records, "count": len(records)})
    except Exception as exc:
        return _err(req_id, str(exc))


def handle_list_capabilities(req_id: str, _params: dict) -> dict:
    registry = get_default_registry()
    return _ok(req_id, {"capabilities": registry.to_dict_list()})


def handle_resolve_approval(req_id: str, params: dict) -> dict:
    appr_id = str(params.get("request_id") or params.get("approval_id") or "")
    approved = bool(params.get("approved", False))
    run_id = params.get("run_id")
    success = APPROVAL_MANAGER.resolve(appr_id, approved, str(run_id) if run_id is not None else None)
    return _ok(req_id, {"resolved": success, "request_id": appr_id, "approved": approved})


def handle_get_pending_approvals(req_id: str, params: dict) -> dict:
    run_id = params.get("run_id")
    pending = APPROVAL_MANAGER.get_pending(run_id)
    return _ok(req_id, {"approvals": pending})


def handle_report_computer_action_result(req_id: str, params: dict) -> dict:
    """Dispatched on the main stdin-read loop while a capability handler's
    worker thread sits blocked in ComputerActionManager.wait_for_result —
    the same shape resolve_approval unblocks ApprovalManager.wait_for_decision."""
    action_id = str(params.get("request_id") or "")
    result = params.get("result") or {}
    run_id = params.get("run_id")
    target_id = params.get("target_id")
    resolved = COMPUTER_ACTION_MANAGER.resolve(
        action_id,
        result,
        str(run_id) if run_id is not None else None,
        str(target_id) if target_id is not None else None,
    )
    return _ok(req_id, {"resolved": resolved, "request_id": action_id})


def handle_pause_run(req_id: str, params: dict) -> dict:
    run_id = str(params.get("run_id", ""))
    success = EXECUTION_CONTROLLER.pause_run(run_id)
    return _ok(req_id, {"paused": success, "run_id": run_id})


def handle_resume_run(req_id: str, params: dict) -> dict:
    run_id = str(params.get("run_id", ""))
    success = EXECUTION_CONTROLLER.resume_run(run_id)
    return _ok(req_id, {"resumed": success, "run_id": run_id})


def handle_cancel_run(req_id: str, params: dict) -> dict:
    run_id = str(params.get("run_id", ""))
    EXECUTION_CONTROLLER.cancel_run(run_id)
    APPROVAL_MANAGER.cancel_run(run_id)
    return _ok(req_id, {"cancelled": True, "run_id": run_id})


def handle_list_workspace_files(req_id: str, params: dict) -> dict:
    registry = get_default_registry()
    cap = registry.get("filesystem.list")
    if not cap:
        return _err(req_id, "filesystem.list capability unavailable")
    try:
        ws_root = params.get("workspace_root") or str(Path(__file__).resolve().parent.parent)
        result = cap.execute(params, {"workspace_root": ws_root})
        return _ok(req_id, result)
    except Exception as exc:
        return _err(req_id, str(exc))


def handle_read_workspace_file(req_id: str, params: dict) -> dict:
    registry = get_default_registry()
    cap = registry.get("filesystem.read")
    if not cap:
        return _err(req_id, "filesystem.read capability unavailable")
    try:
        ws_root = params.get("workspace_root") or str(Path(__file__).resolve().parent.parent)
        result = cap.execute(params, {"workspace_root": ws_root})
        return _ok(req_id, result)
    except Exception as exc:
        return _err(req_id, str(exc))


def _check_model_available(provider: str, model: str, cfg: Any) -> tuple[bool, str]:
    if not model:
        return False, "Model name cannot be empty"

    clean_model = model
    if ":" in model and (model.startswith(f"{provider}:") or model.startswith("ollama:")):
        clean_model = model.split(":", 1)[1]

    p = provider.lower()
    if p in ("ollama", "remote-ollama", "remote_ollama"):
        try:
            manager = OllamaManager(cfg)
            if not manager.available():
                return False, "Ollama service unreachable"
            names, status = manager.models_result()
            if status != "ok":
                return False, f"Ollama unreachable ({status})"
            matched = any(
                m == clean_model
                or m == model
                or m.split(":")[0] == clean_model
                or clean_model.split(":")[0] == m
                or clean_model.split(":")[0] == m.split(":")[0]
                for m in names
            )
            if not matched:
                return False, f"Model '{clean_model}' is not installed in local Ollama"
            return True, ""
        except Exception as exc:
            return False, f"Ollama check failed: {exc}"

    if p in ("ollama-cloud", "ollama_cloud"):
        key = os.environ.get("OLLAMA_API_KEY", "") or load_private_env().get("OLLAMA_API_KEY", "")
        if not key:
            return False, "OLLAMA_API_KEY environment variable is not set"
        try:
            cloud_prov = OllamaCloudProvider(cfg)
            if not cloud_prov.available():
                return False, "Ollama Cloud is unreachable"
            return True, ""
        except Exception as e:
            return False, f"Ollama Cloud error: {e}"

    if p in ("openai", "openai-compatible", "openai_compatible", "remote"):
        endpoint = (cfg.model_endpoint or "").rstrip("/")
        if not endpoint:
            return False, "Remote model endpoint is not configured"
        if cfg.api_key_env and not os.environ.get(cfg.api_key_env, ""):
            return False, f"Remote API key environment variable {cfg.api_key_env} is not set"
        return True, ""

    return False, f"Unknown provider: {provider}"


def _model_profile_provider(profile: Any) -> str:
    """Return the stable provider id exposed to SysAI OS for a profile.

    The CLI historically stores a remote Ollama profile with provider
    ``ollama`` because the engine uses the same client implementation. That
    provider id is ambiguous at the OS boundary: a Run carrying only
    ``provider=ollama, model=name`` would silently fall back to local Ollama.
    Profile ids are the remaining durable discriminator, so normalize that
    legacy representation before sending models to Flutter.
    """
    provider = str(getattr(profile, "provider", "")).lower().replace("_", "-")
    profile_id = str(getattr(profile, "id", "")).lower()
    if provider == "ollama" and profile_id.startswith("remote-ollama"):
        return "remote-ollama"
    if provider in ("openai", "openai-compatible", "remote"):
        return "openai-compatible"
    return provider


def _discover_providers(cfg: Any) -> list[dict]:
    providers = []

    # 1. Ollama local
    local_avail = False
    local_models_count = 0
    try:
        local_mgr = OllamaManager(cfg)
        local_avail = local_mgr.available()
        if local_avail:
            local_models_count = len(local_mgr.models())
    except Exception:
        pass

    providers.append({
        "id": "ollama",
        "name": "Ollama Local",
        "available": local_avail,
        "configured": True,
        "status_message": "Online" if local_avail else "Ollama unreachable",
        "local": True,
        "models_count": local_models_count,
    })

    # 2. Ollama Cloud
    cloud_key = os.environ.get("OLLAMA_API_KEY", "") or load_private_env().get("OLLAMA_API_KEY", "")
    cloud_cfg = bool(cloud_key)
    cloud_avail = False
    cloud_status = "OLLAMA_API_KEY not set"
    if cloud_cfg:
        try:
            cloud_prov = OllamaCloudProvider(cfg)
            cloud_avail = cloud_prov.available()
            cloud_status = "Online" if cloud_avail else "Ollama Cloud unreachable"
        except Exception as e:
            cloud_status = str(e)
    providers.append({
        "id": "ollama-cloud",
        "name": "Ollama Cloud",
        "available": cloud_avail,
        "configured": cloud_cfg,
        "status_message": cloud_status,
        "local": False,
        "models_count": 0,
    })

    # 3. Remote Ollama
    profiles = load_model_profiles()
    remote_ollama_profiles = [p for p in profiles if _model_profile_provider(p) == "remote-ollama"]
    remote_configured = bool(remote_ollama_profiles or (cfg.provider in ("remote-ollama", "remote_ollama") and cfg.model_endpoint))
    providers.append({
        "id": "remote-ollama",
        "name": "Remote Ollama",
        "available": remote_configured,
        "configured": remote_configured,
        "status_message": "Configured in profiles" if remote_configured else "No remote endpoints configured",
        "local": False,
        "models_count": len(remote_ollama_profiles),
    })

    # 4. OpenAI Compatible
    api_profiles = [p for p in profiles if p.provider in ("openai", "openai-compatible", "openai_compatible", "remote")]
    api_configured = bool(api_profiles or (cfg.provider in ("openai", "openai-compatible", "openai_compatible") and cfg.model_endpoint))
    providers.append({
        "id": "openai-compatible",
        "name": "Compatible API",
        "available": api_configured,
        "configured": api_configured,
        "status_message": "Configured in profiles" if api_configured else "Endpoint and model required",
        "local": False,
        "models_count": len(api_profiles),
    })

    return providers


def _discover_models(cfg: Any) -> list[dict]:
    models: list[dict] = []
    seen_ids = set()

    # 1. Local Ollama discovered models
    try:
        local_mgr = OllamaManager(cfg)
        if local_mgr.available():
            names, status = local_mgr.models_result()
            if status == "ok":
                for name in names:
                    m_id = f"ollama:{name}"
                    seen_ids.add(m_id)
                    models.append({
                        "id": m_id,
                        "name": name,
                        "provider": "ollama",
                        "display_name": name,
                        "available": True,
                        "unavailable_reason": None,
                        "context_window": None,
                        "capabilities": ["streaming"],
                        "local": True,
                        "metadata": {},
                    })
    except Exception:
        pass

    # 2. Configured active model from SysAI
    # Do not turn a stale/unavailable engine default into a selectable model.
    # The engine remains the source of truth for configuration; the UI should
    # show models that are actually discoverable and available right now.
    profiles = load_model_profiles()
    active_profile = next(
        (profile for profile in profiles
         if profile.id == str(getattr(cfg, "active_model_id", "") or "")),
        None,
    )
    active_provider = (_model_profile_provider(active_profile)
                       if active_profile is not None
                       else str(getattr(cfg, "provider", "") or "").strip())
    active_model = str(getattr(cfg, "model", "") or "").strip()
    active_id = f"{active_provider}:{active_model}"
    if active_provider and active_model and active_id not in seen_ids:
        active_cfg = cfg
        if active_profile is not None:
            active_cfg = dataclasses.replace(
                cfg,
                provider=active_provider,
                ollama_url=(active_profile.base_url
                            if active_provider in ("ollama", "remote-ollama")
                            else cfg.ollama_url),
                ollama_auth_env=(active_profile.api_key_env
                                 if active_provider in ("ollama", "remote-ollama")
                                 else cfg.ollama_auth_env),
                model_endpoint=active_profile.base_url,
                api_key_env=active_profile.api_key_env,
            )
        avail, _reason = _check_model_available(active_provider, active_model, active_cfg)
        if avail:
            seen_ids.add(active_id)
            models.append({
                "id": active_id,
                "name": active_model,
                "provider": active_provider,
                "display_name": f"{active_model} (configured)",
                "available": True,
                "unavailable_reason": None,
                "context_window": None,
                "capabilities": ["streaming"],
                "local": active_provider == "ollama",
                "metadata": {"configured": True},
            })

    # 3. Ollama Cloud models if configured
    cloud_key = os.environ.get("OLLAMA_API_KEY", "") or load_private_env().get("OLLAMA_API_KEY", "")
    if cloud_key:
        try:
            cloud_prov = OllamaCloudProvider(cfg)
            c_names, _ = cloud_prov.manager.models_result()
            for name in c_names:
                m_id = f"ollama-cloud:{name}"
                if m_id not in seen_ids:
                    seen_ids.add(m_id)
                    models.append({
                        "id": m_id,
                        "name": name,
                        "provider": "ollama-cloud",
                        "display_name": f"{name} (cloud)",
                        "available": True,
                        "unavailable_reason": None,
                        "context_window": None,
                        "capabilities": ["streaming"],
                        "local": False,
                        "metadata": {},
                    })
        except Exception:
            pass

    # 4. Model Profiles from SysAI config.toml
    try:
        for profile in profiles:
            provider = _model_profile_provider(profile)
            m_id = f"{provider}:{profile.name}"
            if m_id in seen_ids:
                continue
            seen_ids.add(m_id)
            candidate = dataclasses.replace(
                cfg, provider=provider, model=profile.name,
                ollama_url=profile.base_url if provider in ("ollama", "remote-ollama") else cfg.ollama_url,
                ollama_auth_env=profile.api_key_env if provider in ("ollama", "remote-ollama") else cfg.ollama_auth_env,
                model_endpoint=profile.base_url, api_key_env=profile.api_key_env,
                active_model_id=profile.id
            )
            avail, reason = _check_model_available(profile.provider, profile.name, candidate)
            models.append({
                "id": m_id,
                "name": profile.name,
                "provider": provider,
                "display_name": f"{profile.name} ({profile.id})",
                "available": avail,
                "unavailable_reason": reason if not avail else None,
                "context_window": None,
                "capabilities": ["streaming"],
                "local": provider == "ollama",
                "metadata": {"profile_id": profile.id, "base_url": profile.base_url},
            })
    except Exception:
        pass

    return models


def handle_list_providers(req_id: str, _params: dict) -> dict:
    if not SYSAI_AVAILABLE:
        return _unavailable(req_id)
    try:
        cfg = load_config()
        providers = _discover_providers(cfg)
        return _ok(req_id, {"providers": providers})
    except Exception as exc:
        return _err(req_id, f"Failed to list providers: {exc}")


def handle_list_models(req_id: str, _params: dict) -> dict:
    if not SYSAI_AVAILABLE:
        return _unavailable(req_id)
    try:
        cfg = load_config()
        models = _discover_models(cfg)
        return _ok(req_id, {"models": models})
    except Exception as exc:
        return _err(req_id, f"Failed to list models: {exc}")


def handle_check_model_availability(req_id: str, params: dict) -> dict:
    if not SYSAI_AVAILABLE:
        return _unavailable(req_id)
    try:
        provider = str(params.get("provider", "")).strip().lower()
        model = str(params.get("model", "")).strip()
        cfg = load_config()
        available, reason = _check_model_available(provider, model, cfg)
        return _ok(req_id, {
            "provider": provider,
            "model": model,
            "available": available,
            "reason": reason,
        })
    except Exception as exc:
        return _err(req_id, f"Availability check failed: {exc}")



def handle_execute_run(req_id: str, params: dict) -> None:
    """Streaming: executes a run goal, emitting events line by line."""
    goal = str(params.get("goal", "")).strip()
    run_id = str(params.get("run_id", ""))
    workspace_root = params.get("workspace_root") or str(Path(__file__).resolve().parent.parent)

    if not goal:
        _emit(_err(req_id, "No goal provided", "invalid_params"))
        return

    if not SYSAI_AVAILABLE:
        _emit({
            "id": req_id, "ok": True, "done": False,
            "event": {
                "type": "run.failed",
                "run_id": run_id,
                "message": f"SysAI engine unavailable. Set SYSAI_PATH to {SYSAI_PATH_USED or 'SysAI installation path'}.",
            }
        })
        _emit({"id": req_id, "ok": True, "done": True, "result": {"status": "failed", "reason": "sysai_unavailable"}})
        return

    provider = params.get("provider")
    model = params.get("model")

    # Import and run the Phase 2 agentic runner
    try:
        import importlib
        runner_mod = importlib.import_module("sysai_runner")
        importlib.reload(runner_mod)
        runner_mod.execute_run(
            req_id=req_id,
            run_id=run_id,
            goal=goal,
            emit=_emit,
            workspace_root=workspace_root,
            provider=provider,
            model=model,
        )
    except Exception as exc:
        tb = traceback.format_exc()
        _emit({
            "id": req_id, "ok": True, "done": False,
            "event": {
                "type": "run.failed",
                "run_id": run_id,
                "message": f"Runtime error: {exc}",
                "detail": tb,
            }
        })
        _emit({"id": req_id, "ok": True, "done": True, "result": {"status": "failed", "reason": str(exc)}})


# ── Dispatch ──────────────────────────────────────────────────────────────────

HANDLERS = {
    "ping": handle_ping,
    "get_config": handle_get_config,
    "get_doctor": handle_get_doctor,
    "get_memory_stats": handle_get_memory_stats,
    "list_memories": handle_list_memories,
    "search_memory": handle_search_memory,
    "list_capabilities": handle_list_capabilities,
    "resolve_approval": handle_resolve_approval,
    "get_pending_approvals": handle_get_pending_approvals,
    "report_computer_action_result": handle_report_computer_action_result,
    "pause_run": handle_pause_run,
    "resume_run": handle_resume_run,
    "cancel_run": handle_cancel_run,
    "list_workspace_files": handle_list_workspace_files,
    "read_workspace_file": handle_read_workspace_file,
    "list_providers": handle_list_providers,
    "list_models": handle_list_models,
    "check_model_availability": handle_check_model_availability,
}

STREAMING_HANDLERS = {
    "execute_run": handle_execute_run,
}


_EMIT_LOCK = threading.Lock()


def _emit(obj: dict) -> None:
    with _EMIT_LOCK:
        print(json.dumps(obj, default=str), flush=True)


def _dispatch(request: dict) -> None:
    req_id = str(request.get("id", ""))
    method = str(request.get("method", ""))
    params = request.get("params") or {}

    if method in HANDLERS:
        try:
            result = HANDLERS[method](req_id, params)
            _emit(result)
        except Exception as exc:
            _emit(_err(req_id, f"Internal error: {exc}"))
    elif method in STREAMING_HANDLERS:
        handler = STREAMING_HANDLERS[method]

        def _worker():
            try:
                handler(req_id, params)
            except Exception as exc:
                _emit(_err(req_id, f"Streaming error: {exc}"))

        thread = threading.Thread(target=_worker, daemon=True)
        thread.start()
    else:
        _emit(_err(req_id, f"Unknown method: {method!r}", "unknown_method"))


# ── Main loop ─────────────────────────────────────────────────────────────────

def main() -> None:
    # Announce readiness
    _emit({
        "type": "ready",
        "bridge_version": "2.0.0",
        "sysai_available": SYSAI_AVAILABLE,
        "sysai_version": SYSAI_VERSION,
        "sysai_path": SYSAI_PATH_USED,
    })

    for raw_line in sys.stdin:
        line = raw_line.strip()
        if not line:
            continue
        try:
            request = json.loads(line)
        except json.JSONDecodeError as exc:
            _emit({"ok": False, "error": f"Invalid JSON: {exc}", "code": "parse_error"})
            continue
        _dispatch(request)


if __name__ == "__main__":
    main()
