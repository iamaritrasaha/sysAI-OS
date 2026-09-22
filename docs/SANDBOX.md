# SysAI OS — Shell Sandbox

SysAI OS adds a second layer of OS-level containment around agent-initiated shell commands using [bubblewrap](https://github.com/containers/bubblewrap) (`bwrap`). This is defense-in-depth: the Policy Engine is still required and evaluated first.

## Architecture

```
Agent requests shell action
    ↓
Policy Engine (decision: permit/deny/require-approval)
    ↓
Approval if required
    ↓
Sandbox construction (build_bwrap_args)
    ↓
Shell process executes inside constrained bwrap environment
```

## Sandbox Profiles

| Profile | Network | Workspace | /tmp | Use Case |
|---------|---------|-----------|------|----------|
| `observe` | ✗ isolated | read-only | ✗ | Safe inspection |
| `workspace_write` | ✗ isolated | read-write | ✓ | Default agent work |
| `network_enabled` | ✓ permitted | read-write | ✓ | Downloads, API calls |
| `build_test` | ✓ permitted | read-write | ✓ | Compilers, test runners |

Default profile: `workspace_write`.

Override: `SYSAI_SANDBOX_PROFILE=<profile>`

## Sandbox State

The UI diagnostics panel reports one of:

- **available** — bubblewrap found and functional, sandboxing active
- **unavailable** — bubblewrap not installed, sandboxing not possible
- **disabled** — user explicitly disabled via `SYSAI_SANDBOX_DISABLED=1`

## Behavior When Sandbox Unavailable

By default, when bubblewrap is not available, unsandboxed shell execution requires approval (shown as a policy prompt in the UI).

To opt out of this fallback approval: `SYSAI_SANDBOX_NO_APPROVAL_FALLBACK=1`

## Honest Limitations

The sandbox does **not**:
- Sandbox the runtime process itself (only subprocesses it spawns)
- Prevent all forms of inter-process communication
- Apply Landlock kernel-level path restrictions (requires C syscalls not available from pure Python)
- Isolate network traffic for `network_enabled` and `build_test` profiles
- Provide cryptographic integrity of the workspace

## Installation Requirement

Install bubblewrap (Ubuntu/Debian):
```bash
sudo apt install bubblewrap
```

Verify:
```bash
bwrap --version
```
