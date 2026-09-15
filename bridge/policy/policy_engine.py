"""
SysAI OS Policy Engine
======================
Evaluates capability execution requests against:
1. Workspace boundary (canonical path traversal prevention)
2. Risk classification (observe, low, medium, high, privileged)
3. Command safety heuristics (destructive commands, privilege escalation)
4. Configured governance rules (ALLOW, REQUIRE_APPROVAL, DENY)
"""
from __future__ import annotations

import os
import re
from dataclasses import dataclass
from enum import Enum
from pathlib import Path
from typing import Any, Dict, Optional


class PolicyVerdict(str, Enum):
    ALLOW = "ALLOW"
    REQUIRE_APPROVAL = "REQUIRE_APPROVAL"
    DENY = "DENY"


@dataclass
class PolicyDecision:
    verdict: PolicyVerdict
    reason: str
    risk: str  # observe | low | medium | high | privileged
    explanation: str = ""

    def to_dict(self) -> Dict[str, Any]:
        return {
            "verdict": self.verdict.value,
            "reason": self.reason,
            "risk": self.risk,
            "explanation": self.explanation,
        }


class PolicyEngine:
    """Deterministic policy enforcement engine for SysAI OS."""

    # Explicitly forbidden destructive command patterns
    UNCONDITIONAL_DENY_PATTERNS = [
        re.compile(r"\brm\s+-[a-zA-Z]*r[a-zA-Z]*f\s+/(?:\s|$|\*)"),  # rm -rf / or rm -rf /*
        re.compile(r"\bmkfs\b"),                              # disk formatting
        re.compile(r"\bdd\s+if="),                            # raw disk write
        re.compile(r">\s*/dev/sd[a-z]"),                      # redirect to raw block dev
        re.compile(r":\(\)\{\s*:\|:&\s*\};:"),                # fork bomb
        re.compile(r"\bchmod\s+-[a-zA-Z]*R\s+777\s+/"),       # chmod -R 777 /
    ]

    # Patterns that require explicit human approval (Privileged risk)
    PRIVILEGED_PATTERNS = [
        re.compile(r"\bsudo\b"),
        re.compile(r"\bsu\s"),
        re.compile(r"\bdoas\b"),
        re.compile(r"\buseradd\b"),
        re.compile(r"\buserdel\b"),
        re.compile(r"\biptables\b"),
        re.compile(r"\bsystemctl\b"),
        re.compile(r"\bshutdown\b"),
        re.compile(r"\breboot\b"),
    ]

    # Patterns that require explicit human approval (High risk)
    HIGH_RISK_PATTERNS = [
        re.compile(r"\bgit\s+push\b"),
        re.compile(r"\bgit\s+reset\s+--hard\b"),
        re.compile(r"\bgit\s+clean\s+-[a-zA-Z]*f\b"),
        re.compile(r"\bcurl\b.*\|\s*(?:ba|z|sh)\b"),          # curl | bash
        re.compile(r"\bwget\b.*\|\s*(?:ba|z|sh)\b"),          # wget | bash
        re.compile(r"\bpip\s+install\s+(?!-r\b)"),            # unpinned pip install
        re.compile(r"\brm\s+-[a-zA-Z]*r"),                    # recursive delete
    ]

    # Commands considered safe observation/read
    SAFE_READ_COMMANDS = {
        "flutter test", "flutter analyze", "dart analyze", "dart test",
        "git status", "git diff", "git log", "git branch", "git show",
        "ls", "cat", "head", "tail", "grep", "find", "wc", "uname", "which",
        "python3 --version", "flutter --version", "dart --version",
    }

    # Sensitive filenames requiring approval even for writes
    SENSITIVE_FILES = {
        ".env", ".env.local", ".env.production",
        "id_rsa", "id_ed25519", "authorized_keys",
        ".git/config", ".bashrc", ".profile", ".zshrc",
    }

    def __init__(self, default_require_write_approval: bool = True) -> None:
        self.default_require_write_approval = default_require_write_approval

    def evaluate(
        self,
        capability_id: str,
        params: Dict[str, Any],
        context: Dict[str, Any],
    ) -> PolicyDecision:
        workspace_root = Path(context.get("workspace_root", os.getcwd()))

        # 1. Check workspace boundary
        traversal_decision = self._check_path_boundary(capability_id, params, workspace_root)
        if traversal_decision:
            return traversal_decision

        # 2. Shell Command Safety
        if capability_id == "shell.execute":
            return self._evaluate_shell(params)

        # 3. Filesystem Write Safety
        if capability_id in ("filesystem.write", "filesystem.create"):
            return self._evaluate_fs_write(params)

        if capability_id == "filesystem.mkdir":
            return PolicyDecision(
                verdict=PolicyVerdict.ALLOW,
                reason="Safe directory creation within workspace",
                risk="medium",
            )

        # 4. Read / Passive Observation Capabilities
        if capability_id in (
            "filesystem.read", "filesystem.list", "filesystem.stat",
            "git.status", "git.diff", "git.log",
            "system.environment",
            "sysai.diagnostics", "sysai.model_status", "sysai.experience_query",
        ):
            return PolicyDecision(
                verdict=PolicyVerdict.ALLOW,
                reason="Safe observation within workspace",
                risk="observe" if "stat" in capability_id or "env" in capability_id or "diagnos" in capability_id else "low",
            )

        # 5. Browser capabilities
        if capability_id.startswith("browser."):
            return self._evaluate_browser(capability_id, params)

        # 6. Computer/desktop capabilities
        if capability_id.startswith("computer."):
            return self._evaluate_computer(capability_id, params)

        # Default fallback
        return PolicyDecision(
            verdict=PolicyVerdict.ALLOW,
            reason="Standard capability execution",
            risk="low",
        )

    def _evaluate_browser(self, capability_id: str, params: Dict[str, Any]) -> PolicyDecision:
        # Reading/navigating public pages is a low-risk, reversible action —
        # no local or remote side effect beyond an outbound GET.
        if capability_id in ("browser.search", "browser.navigate", "browser.follow_link"):
            return PolicyDecision(
                verdict=PolicyVerdict.ALLOW,
                reason="Reading a public page is a reversible, read-only action",
                risk="low",
            )

        if capability_id == "browser.read":
            return PolicyDecision(
                verdict=PolicyVerdict.ALLOW,
                reason="Reading already-fetched page content",
                risk="observe",
            )

        if capability_id == "browser.capture":
            return PolicyDecision(
                verdict=PolicyVerdict.ALLOW,
                reason="Persisting a snapshot of an already-fetched page",
                risk="low",
            )

        if capability_id == "browser.download":
            # Writes a file into the workspace from an untrusted remote
            # source — same posture as any other workspace write.
            return PolicyDecision(
                verdict=PolicyVerdict.REQUIRE_APPROVAL,
                reason="Downloading a remote file into the workspace requires approval",
                risk="medium",
                explanation=f"SysAI wants to download {params.get('url', 'a remote file')} into the workspace.",
            )

        return PolicyDecision(
            verdict=PolicyVerdict.REQUIRE_APPROVAL,
            reason="Unrecognized browser capability defaults to approval",
            risk="high",
        )

    # Targets Controlled Computer Use is allowed to act on at all. Anything
    # else is denied here — on target identity, not just UI convention —
    # regardless of what the capability itself would otherwise allow.
    KNOWN_COMPUTER_TARGETS = {"sysai-test-surface"}

    def _evaluate_computer(self, capability_id: str, params: Dict[str, Any]) -> PolicyDecision:
        # Observation/capture never mutates anything outside SysAI OS itself.
        if capability_id in ("computer.observe", "computer.capture"):
            return PolicyDecision(
                verdict=PolicyVerdict.ALLOW,
                reason="Observing or capturing the desktop does not act on it",
                risk="low" if capability_id == "computer.capture" else "observe",
            )

        if capability_id in ("computer.click", "computer.type", "computer.key", "computer.scroll"):
            target_id = str(params.get("target_id", ""))
            if target_id not in self.KNOWN_COMPUTER_TARGETS:
                return PolicyDecision(
                    verdict=PolicyVerdict.DENY,
                    reason="Target is not an explicitly registered SysAI-owned Computer target",
                    risk="privileged",
                    explanation=f"Refusing {capability_id.split('.')[-1]} against unregistered target {target_id!r}. "
                                f"Controlled Computer Use never acts on arbitrary desktop targets.",
                )

            action = capability_id.split(".")[-1]
            if action in ("type", "key"):
                # Initial posture for text/keyboard input, even against a
                # target SysAI owns — biased toward the safer default.
                return PolicyDecision(
                    verdict=PolicyVerdict.REQUIRE_APPROVAL,
                    reason="Keyboard input requires explicit human approval",
                    risk="privileged",
                    explanation=f"SysAI wants to send {action} input to '{target_id}'.",
                )

            # click / scroll against a known, SysAI-owned target.
            return PolicyDecision(
                verdict=PolicyVerdict.ALLOW,
                reason="Controlled action against a SysAI-owned target",
                risk="medium",
            )

        return PolicyDecision(
            verdict=PolicyVerdict.REQUIRE_APPROVAL,
            reason="Unrecognized computer capability defaults to approval",
            risk="privileged",
        )

    def _check_path_boundary(
        self,
        capability_id: str,
        params: Dict[str, Any],
        workspace_root: Path,
    ) -> Optional[PolicyDecision]:
        """Checks whether any specified path or cwd violates workspace root boundaries."""
        ws_root = workspace_root.resolve()
        paths_to_check = []

        if "path" in params and isinstance(params["path"], str) and params["path"]:
            paths_to_check.append(params["path"])
        if "cwd" in params and isinstance(params["cwd"], str) and params["cwd"]:
            paths_to_check.append(params["cwd"])

        for raw_path in paths_to_check:
            target = (ws_root / raw_path).resolve() if not os.path.isabs(raw_path) else Path(raw_path).resolve()

            # Boundary check: target must be inside workspace or be workspace itself
            if target != ws_root and ws_root not in target.parents:
                return PolicyDecision(
                    verdict=PolicyVerdict.DENY,
                    reason="Path traversal outside workspace root is denied",
                    risk="privileged",
                    explanation=(
                        f"Requested path '{raw_path}' resolves to '{target}', which is outside "
                        f"the canonical workspace root '{ws_root}'."
                    ),
                )
        return None

    def _evaluate_shell(self, params: Dict[str, Any]) -> PolicyDecision:
        cmd = params.get("cmd", "").strip()
        if not cmd:
            return PolicyDecision(
                verdict=PolicyVerdict.DENY,
                reason="Empty shell command",
                risk="observe",
            )

        # 1. Unconditional Deny
        for pattern in self.UNCONDITIONAL_DENY_PATTERNS:
            if pattern.search(cmd):
                return PolicyDecision(
                    verdict=PolicyVerdict.DENY,
                    reason="Forbidden destructive command pattern detected",
                    risk="privileged",
                    explanation=f"Command '{cmd}' contains a destructive pattern prohibited by safety policy.",
                )

        # 2. Privileged commands (require approval)
        for pattern in self.PRIVILEGED_PATTERNS:
            if pattern.search(cmd):
                return PolicyDecision(
                    verdict=PolicyVerdict.REQUIRE_APPROVAL,
                    reason="Privileged system command requires explicit human approval",
                    risk="privileged",
                    explanation=f"Command '{cmd}' requires elevated system privileges.",
                )

        # 3. High risk commands (require approval)
        for pattern in self.HIGH_RISK_PATTERNS:
            if pattern.search(cmd):
                return PolicyDecision(
                    verdict=PolicyVerdict.REQUIRE_APPROVAL,
                    reason="High-risk command requires explicit human approval",
                    risk="high",
                    explanation=f"Command '{cmd}' may alter git history, download unverified scripts, or delete files.",
                )

        # 4. Check if known safe read command
        cmd_clean = cmd.split("|")[0].split(">")[0].strip()
        for safe_prefix in self.SAFE_READ_COMMANDS:
            if cmd_clean == safe_prefix or cmd_clean.startswith(f"{safe_prefix} "):
                return PolicyDecision(
                    verdict=PolicyVerdict.ALLOW,
                    reason="Safe inspection or test command",
                    risk="low",
                )

        # 5. Default shell command evaluation:
        # Standard build/test commands within workspace are allowed with medium risk
        return PolicyDecision(
            verdict=PolicyVerdict.ALLOW,
            reason="Standard shell execution within workspace",
            risk="medium",
        )

    def _evaluate_fs_write(self, params: Dict[str, Any]) -> PolicyDecision:
        raw_path = params.get("path", "")
        basename = Path(raw_path).name.lower()

        # Check sensitive files
        if basename in self.SENSITIVE_FILES or any(s in raw_path for s in self.SENSITIVE_FILES):
            return PolicyDecision(
                verdict=PolicyVerdict.REQUIRE_APPROVAL,
                reason="Writing to sensitive project configuration requires approval",
                risk="high",
                explanation=f"Attempting to modify protected file '{raw_path}'.",
            )

        if self.default_require_write_approval:
            return PolicyDecision(
                verdict=PolicyVerdict.REQUIRE_APPROVAL,
                reason="Modifying files in workspace requires human review",
                risk="high",
                explanation=f"Capability will create or modify file '{raw_path}'.",
            )

        return PolicyDecision(
            verdict=PolicyVerdict.ALLOW,
            reason="File modification allowed by policy",
            risk="medium",
        )
