# SysAI OS Architecture

## Overview

SysAI OS is a desktop-first **Agentic Operating Environment** powered by the existing SysAI engine. It transforms SysAI from a terminal-bound assistant into an autonomous operating system interface where users specify high-level goals and observe/control multi-step autonomous work through persistent runs, structured event streams, real-time activity timelines, and verified outcomes.

---

## 1. System Responsibilities

```
┌────────────────────────────────────────────────────────┐
│                        SysAI OS                        │
│                   Desktop Application                  │
│                                                        │
│  [Home View]       [Runs View]       [Run Detail View] │
│  [Workspace View]  [Experience View] [System View]     │
└───────────────────────────┬────────────────────────────┘
                            │
              SysAI OS Application Services
                            │
       ┌────────────────────┴────────────────────┐
       │                                         │
   OS Runtime                             SysAI Adapter
       │                                         │
  Run Lifecycle                             READ / CALL
  Task Progression                               │
  Structured Events                              ▼
  SQLite Persistence                     Existing SysAI
  Approvals & Artifacts                     [READ-ONLY]
       │                                         │
       └─────────────────────────────────────────┘
```

| Area | SysAI OS (New) | SysAI Engine (Existing, Read-Only) |
|---|---|---|
| **User Interface** | Desktop shell (Flutter, dark-first, GTK/Adwaita) | Terminal CLI |
| **Run Abstraction** | Persistent `Run` model, lifecycle state machine | Single commands / interactive PTY session |
| **Event System** | Structured NDJSON event stream (`RunEvent`) | Terminal text / ANSI streams |
| **Persistence** | Runtime-owned `runtime_*` SQLite tables; Dart `sysai_os.db` is a projection/cache | SQLite `memory.db` (experience store) |
| **Orchestration** | Agent runner (Plan → Execute → Verify) | Deterministic collectors + LLM reasoning |
| **Intelligence** | Uses SysAI adapter | Model providers (Ollama, cloud), prompt assembly |
| **Self-Diagnostics**| OS status UI | Deterministic `doctor` checks |

---

## 2. Integration & Adapter Boundary

### Principle: Zero SysAI Modifications
The SysAI repository is strictly immutable upstream software. In the desktop
configuration, SysAI OS connects to it through the persistent runtime
(`bridge/sysai_os_runtime.py`), which imports the adapter and SysAI modules in
the runtime process. The older `bridge/sysai_bridge.py` stdin/stdout entrypoint
is retained only for compatibility and direct bridge tests; it is not a second
desktop execution service.

```
Flutter Desktop UI
       ↕ (Unix-domain socket)
Persistent Python Runtime (bridge/sysai_os_runtime.py)
       ↕ (in-process adapter handlers)
Compatibility Adapter (bridge/sysai_bridge.py)
       ↕ (Python in-process import via sys.path)
SysAI Engine Modules (sysai.config, sysai.doctor, sysai.memory, sysai.domains, etc.)
```

### Communication Protocol
- Production transport: versioned newline-delimited JSON over a local
  Unix-domain socket. The runtime survives Flutter disconnects.
- Compatibility transport: subprocess stdin/stdout NDJSON for direct bridge
  tests and older integrations; it is not used by the desktop app.
- Format: Newline-Delimited JSON (NDJSON)
- One-shot Request:
  ```json
  {"id": "req-1", "method": "get_doctor", "params": {"probe_model": false}}
  {"id": "req-1", "ok": true, "result": {...}}
  ```
- Streaming Execution Request:
  ```json
  {"id": "req-2", "method": "execute_run", "params": {"run_id": "run-1", "goal": "..."}}
  {"id": "req-2", "ok": true, "done": false, "event": {"type": "planning.started", ...}}
  {"id": "req-2", "ok": true, "done": false, "event": {"type": "task.started", ...}}
  {"id": "req-2", "ok": true, "done": true, "result": {"status": "completed", "outcome": "..."}}
  ```

### Engine Discovery
The location of SysAI is resolved dynamically without hardcoded assumptions:
1. `SYSAI_PATH` environment variable (highest priority)
2. `.sysai_path` file located in the SysAI_OS project root
3. Sibling directory heuristics (`../SysAI/src`, `../../Projects/sysai/src`)

---

## 3. Run Domain Model

A `Run` represents one user goal executed by the OS.

### State Transitions
```
               ┌──────────┐
               │ CREATED  │
               └────┬─────┘
                    │
                    ▼
               ┌──────────┐
               │ PLANNING │
               └────┬─────┘
                    │
                    ▼
               ┌──────────┐
               │  READY   │
               └────┬─────┘
                    │
                    ▼
    ┌────────► ┌──────────┐ ─────────┐
    │          │ RUNNING  │          │
    │          └────┬─────┘          │
    │ (resume)      │                │
┌───┴──────────┐    │                ▼
│ WAITING_APPR │    │          ┌───────────┐
│   BLOCKED    │    │          │  FAILED   │
└──────────────┘    │          └───────────┘
                    ▼
               ┌───────────┐
               │ VERIFYING │
               └────┬──────┘
                    │
                    ▼
               ┌───────────┐
               │ COMPLETED │
               └───────────┘
```

### Terminal States
`COMPLETED`, `FAILED`, `CANCELLED`, `INTERRUPTED`. A required task failure
causes `FAILED`; later independent tasks may still run so the Run retains
useful evidence, but verification cannot convert that Run into a false
success. Re-execution of a terminal Run is an explicit API action and still
passes through the same runtime single-flight guard.

---

## 4. Structured Event System

SysAI OS never parses raw terminal output for state. All actions emit typed `RunEvent` records:

| Event Type | Purpose | UI Display |
|---|---|---|
| `planning.started` | Goal analysis begins | Spinner on plan section |
| `planning.completed` | Structured plan ready | Renders step list |
| `run.started` | Execution loop active | Status badge → RUNNING |
| `task.started` | Task step initiated | Step bullet → active spinner |
| `capability.started` | Tool invocation begins | Sub-action text in timeline |
| `capability.completed` | Tool execution finished | Tool output preview + code |
| `task.completed` | Task step finished | Step bullet → checkmark |
| `task.failed` | Task encountered error | Step bullet → error icon |
| `verification.started` | Reviewing evidence | Status badge → VERIFYING |
| `verification.completed`| Evidence verified | Verification badge |
| `run.completed` | Outcome finalized | Verified Outcome block |
| `run.failed` | Unrecoverable error | Failure report block |

---

## 5. Persistence & Database Migrations

- Engine: SQLite (via `sqlite3` direct binding, WAL mode, foreign keys enabled)
- Database Files: the canonical runtime uses a per-user state SQLite file for
  `runtime_*` tables; the existing `<app_support_dir>/sysai_os.db` remains the
  Flutter projection/compatibility store.
- Migration Versioning: Managed via `PRAGMA user_version` (V1 -> V2 -> V3), applied incrementally and idempotently (`ALTER TABLE` guarded by try/catch) so upgrading never loses existing data.
- Tables:
  - `runs`: Run metadata, plan JSON, events JSON, outcome, timestamps, plus `provider_id` / `model_id` / `model_display_name` (V3) — the model a Run actually used, fixed at creation
  - `approvals`: Approval request IDs, capability, explanations, risk tiers, payload, resolution status
  - `artifacts`: Output files, diffs, reports, command logs, content previews, metadata
  - `checkpoints`: Step index state snapshots for pause/resume and crash recovery
  - `settings` (V3): SysAI OS's own key/value preferences — currently the default model (`default_provider_id` / `default_model_id` / `default_model_display_name`), independent of SysAI's own `config.toml`
- Crash Recovery: the runtime marks active persisted Runs `INTERRUPTED` on
  startup and closes orphaned approval waits; Flutter refreshes its projection
  from the runtime. The Dart repository's `recoverInterruptedRuns()` remains
  for non-canonical/isolated compatibility use.

---

## 6. Phase 2: Agentic Execution Environment

Phase 2 transforms SysAI OS into a genuinely autonomous execution environment with strict safety boundaries and interactive human governance.

### Capability Registry
All agent operations are governed through a structured `CapabilityRegistry`:
- **Filesystem**: `filesystem.read`, `filesystem.list`, `filesystem.stat`, `filesystem.write`, `filesystem.mkdir`
- **Shell**: `shell.execute` (with execution timeouts, process-group isolation, separated stdout/stderr)
- **Version Control**: `git.status`, `git.diff`, `git.log`
- **System**: `system.environment`
- **SysAI Intelligence**: `sysai.diagnostics`, `sysai.model_status`, `sysai.experience_query`

### Risk Model & Policy Engine
Every capability and argument set is evaluated against a 5-tier risk taxonomy:
- `observe`: Passive inspection (safe)
- `low`: Non-destructive queries (safe)
- `medium`: State modifications or safe writes within project (approval gated)
- `high`: Shell execution or destructive file operations (approval gated)
- `privileged`: System-level modifications (strictly gated or denied)

The `PolicyEngine` determines one of three verdicts before execution:
1. `ALLOW`: Operation proceeds immediately.
2. `REQUIRE_APPROVAL`: Operation pauses cooperatively, emitting `approval.requested`. The runner blocks in an out-of-process monitor until the user grants approval.
3. `DENY`: Unconditional denial (e.g. `rm -rf /`, `mkfs`, fork bombs, canonical path escapes).

### Canonical Workspace Sandboxing
Filesystem operations are strictly sandboxed within the active workspace root:
- Canonical symlink and `..` traversal resolution (`resolve()`)
- Any path resolving outside `workspace_root` is immediately denied with a `PathTraversalError`.

### Interactive Approval Domain
When an operation requires human authorization:
1. Runner creates an `ApprovalRequest` and enters a thread-safe blocking condition.
2. An `approval.requested` event notifies the Flutter UI.
3. The UI presents an prominent **Interactive Approval Banner** displaying:
   - Tool name, risk badge, and structured parameter payload
   - Clear justification/explanation
   - `[Approve once]` and `[Reject]` action buttons
4. Upon user decision, `BridgeService.resolveApproval()` signals the Python bridge, immediately releasing the runner's thread.

### Cooperative Pause, Resume & Process-Group Cancellation
- Runners check `EXECUTION_CONTROLLER.wait_if_paused()` between tasks.
- If paused by the user, the run suspends execution without losing state.
- Subprocesses executed by `shell.execute` are registered in a distinct process group (`os.setpgid`), allowing clean `SIGTERM`/`SIGKILL` termination without orphaned processes.

### Durable Artifacts
Operations producing persistent results (generated files, analysis summaries, reports) emit `artifact.created` events:
- Persisted to SQLite `artifacts` table
- Linked directly to originating `Run` and `RunTask`
- Inspected in Run Detail and Workspace views via native preview dialogs.

---

## 7. Phase 3: Terminal, Browser, Computer Capabilities

### Capability Event Envelope — a gotcha worth documenting
Every capability handler receives `context["emit"]`, a single-dict-argument
callable (`emit({"type": ..., ...})`). Inside `sysai_runner.execute_run`,
this is `_emit_capability_event`, an adapter that wraps the dict in the
standard streaming envelope (`{"id", "ok", "done", "event": {...}}`) that
`BridgeService` on the Dart side requires to route an event into the
*current* Run's stream. A capability that instead received and called the
bridge's raw low-level `emit` directly would silently misroute its events
as unsolicited bridge events — they would never reach the Run at all, with
no error anywhere. This exact bug existed during Phase 3 development for
the Terminal and Browser capabilities and was caught only by a real
end-to-end test (`test/integration/phase3_vertical_slice_test.dart`) that
asserted on event *types actually observed*, not just "the Run completed
without throwing." Any new capability must go through `context["emit"]`
exactly as the existing ones do — never bypass it, never assume it's safe
to call the raw bridge emitter.

### Terminal
`shell.execute` (`bridge/capabilities/registry.py`) spawns the command with
threaded stdout/stderr readers, streaming `terminal.output` per line while
also honoring the existing timeout/cancellation/process-group-kill logic.
The process is registered with `EXECUTION_CONTROLLER` *before* the blocking
wait, not after — otherwise `cancel_run()` has nothing to find and kill
while the command is actually running. Output lines are never persisted
individually; the Dart side (`app_providers.dart`) routes `terminal.output`
straight to a bounded in-memory buffer and never calls `saveRun()` for it.
Only the session summary — written once, on `terminal.session.completed` —
is durable, in `terminal_sessions`.

### Browser
`bridge/capabilities/browser.py` fetches over HTTP and extracts
title/text/links with the stdlib `html.parser` — there is no headless
rendering browser dependency in the bridge process. `browser.capture`
persists a text/HTML snapshot as an artifact, not a screenshot; that
distinction is intentional and documented in the module itself so it
doesn't get "fixed" into a false claim later. Search targets
`lite.duckduckgo.com` (not the more commonly referenced `html.duckduckgo.com`
endpoint, which serves an anti-bot interstitial to non-interactive
clients) with a realistic browser `User-Agent` purely to fetch publicly
served HTML reliably. One `BrowserSession` per Run aggregates navigation
history, persisted in `browser_sessions`. `browser.download`'s destination
parameter is deliberately named `path` (not `destination`) so the Policy
Engine's existing workspace-boundary check — which inspects `params["path"]`
for *every* capability — covers it automatically; the handler also checks
independently as defense-in-depth.

### Computer
As of Phase 3: architectural foundation only. `computer.observe` and
`computer.capture` against the host desktop were real (capture required a
screenshot utility present on the host); `computer.click` / `.type` /
`.key` / `.scroll` were registered, approval-gated placeholders that
always returned `{"success": false, "implemented": false, ...}`.
Superseded by Phase 4's Controlled Computer Use — see §8 below.

### Notifications
A `Notification` domain (`lib/models/notification.dart`), distinct from
the Activity timeline: Activity is "what happened" (every structured
event); notifications are "what needs, or needed, the user's attention" —
fired only for `run.completed`, `run.failed`, `run.interrupted` (via
startup recovery), and `approval.requested`. Persisted in `notifications`;
mirrored to Linux desktop notifications through `notify-send`
(`lib/services/notification_service.dart`) — a zero-dependency shell-out,
silently skipped if the binary isn't present, never able to crash a Run.

### Scheduling — deferred (through Phase 3)
Not implemented in Phase 3. `ScheduledAutomation` persistence, a due-task
scanner, and the "obeys the same Policy Engine as any other Run" guarantee
are a real piece of design work in their own right, and rushing them to
hit a Phase 3 checklist would have meant either a shallow, untested
implementation or displacing the Terminal/Browser/Computer/Notifications
work that this phase's product goal actually depends on. Deferred cleanly
rather than half-built. Implemented in Phase 4 — see §8.

### Database Migration V3 → V4
Adds `terminal_sessions`, `browser_sessions`, and `notifications`, applied
idempotently via the same `fromVersion < N` pattern as V2 → V3. Existing
Runs, approvals, artifacts, checkpoints, and settings are untouched.

---

## 8. Phase 4: Scheduled Automations & Controlled Computer Use

### Scheduler
`ScheduledAutomation` (`lib/models/scheduled_automation.dart`) persists
goal, workspace, persisted provider/model, and a typed schedule — a small
JSON blob keyed by `scheduleType` (`once`/`interval`/`daily`/`weekly`), not
raw cron text; four fixed UI presets didn't justify a general cron parser.
`lib/services/schedule_calculator.dart::computeNextTrigger` is pure
(`nowUtc` passed explicitly, no `DateTime.now()` inside it) and DST-safe
for `daily`/`weekly` via `package:timezone`'s `TZDateTime` — it always
reconstructs the candidate wall-clock instant from the civil date rather
than adding a 24h `Duration`, which is what actually makes it correct
across a DST transition (adding a fixed duration across one would land on
the wrong wall-clock hour).

The production scheduler is owned by `bridge/sysai_os_runtime.py` and ticks
independently of Flutter. The Flutter `SchedulerService` is now only a
compatibility facade for isolated/non-canonical repositories; it performs an
immediate local pass but does not start a UI-owned background timer. Runtime
automation firing creates a normal Run and enters the same
`sysai_runner.execute_run()` capability/policy/approval pipeline as a manual
Run — there is no second execution engine.

**Duplicate-trigger protection**: `automation_occurrences` has a
`UNIQUE(automation_id, occurrence_key)` constraint, and `claimOccurrence()`
is nothing but that insert — the constraint violation *is* the atomic
"already handled" check, safe across a restart or a concurrent
`processDueAutomations()` call, no extra locking needed.

**Missed-trigger policy** (deterministic, not a guess): a `once`
automation fires if caught within `kOnceGraceWindow` (15 minutes) of its
instant, otherwise it's marked `missed` and disabled; a recurring
automation fires once for whatever is currently due and its next trigger
is recomputed straight past `now` — a long-closed app never queues up a
backlog of catch-up Runs, one per missed period.

**Model persistence**: an automation's `providerId`/`modelId` travel with
it into `createRun()` explicitly; changing the global default elsewhere
never touches an existing automation, because `createRun()` only falls
back to the default when nothing explicit is passed.

**Approvals**: unchanged from every other Run — a scheduled Run hitting
`REQUIRE_APPROVAL` sits in `waitingApproval` exactly like a manual one.
Nothing about being scheduled grants privilege.

### Workspace selection — a gap this phase closed incidentally
Before Phase 4, no Run — manual or otherwise — ever passed `workspace_root`
to the bridge; every Run silently executed against the bridge's own
implicit default (the SysAI_OS project root). Since `ScheduledAutomation`
needed a real, honored `workspacePath`, `Run.workspacePath` and the
`workspace_root` bridge parameter were wired through for *all* Runs, not
just scheduled ones — leaving it automation-only would have been an
inconsistency between two code paths that are supposed to be identical.

### Controlled Computer Use
Explicitly not unrestricted desktop automation — call it exactly what it
is. `ComputerTarget.sysaiTestSurface` (`lib/models/computer_target.dart`)
is the only implemented target: a deterministic Flutter surface
(`ComputerView`/`TestSurfaceController`) that SysAI OS owns end-to-end. A
second type, `registeredWindow`, is modeled but has no handler — same
posture Phase 3 took with click/type/key before this phase gave them a
real implementation.

**Execution model**: the Python bridge is a separate subprocess with no
access to the live Flutter widget tree, so a real action is a
request/block/resolve round-trip — `computer.action.requested` →
`ComputerActionManager.wait_for_result()` blocks the capability handler's
worker thread → Flutter's `RunExecutor._handleComputerActionRequested`
calls the *same* `TestSurfaceController` method a human clicking/typing in
`ComputerView` would call → `reportComputerActionResult` unblocks Python.
This mirrors the pre-existing approval round-trip
(`ApprovalManager`/`resolve_approval`) almost exactly. No OS-level input
(no `xdotool`), no dependency on X11 vs. Wayland, no new external tool.

**Target enforcement**: `policy_engine.py::_evaluate_computer` denies any
`target_id` outside `KNOWN_COMPUTER_TARGETS` outright — this is what
actually stops "arbitrary desktop" from being reachable, on target
identity, not left to UI convention. `click`/`scroll` against the known
target are `ALLOW`; `type`/`key` still require approval even against it.

**Capture without an OS screenshot tool**: `computer.capture` against the
registered target routes through the same action-manager round-trip, and
Flutter answers it with `RenderRepaintBoundary.toImage()` — Flutter's own
render tree, not `scrot`/`grim`/etc. This is the concrete fix for "no
general screenshot tool is available," and captures a real screenshot
tool would have missed entirely: a capture of exactly this surface,
independent of what's actually on screen or which window has focus.
`computer.capture`/`.observe` against any *other* target_id still use the
Phase 3 OS-screenshot-tool path unchanged.

**Persistence**: `computer_sessions` (one row per Run/target, mirroring
`browser_sessions`'s shape) and `computer_actions` (one row per action,
full request/result). Both new in the V4→V5 migration.

### Database Migration V4 → V5
Adds `scheduled_automations`, `automation_occurrences`, `computer_sessions`,
`computer_actions`, plus an `ALTER TABLE runs ADD COLUMN workspace_path`
(the one column addition to an existing table, following the same
try/catch-wrapped `ALTER` pattern the V2→V3 migration used for
`provider_id`/`model_id`/`model_display_name`). Applied idempotently via
the same `fromVersion < N` pattern every prior migration used. Existing
runs, approvals, artifacts, checkpoints, settings, terminal/browser
sessions, and notifications are untouched — see
`test/services/v4_to_v5_migration_test.dart`, which builds a real V4 file
and migrates it, not a synthetic shortcut.

### Phase 5 — Persistent Runtime

`bridge/sysai_os_runtime.py` is the long-lived service. It imports the
existing bridge handlers, Capability Registry, Policy Engine,
`sysai_runner`, approval manager, terminal process controller, browser
capabilities, and SysAI adapter. There is one runtime per user, protected by
a non-blocking `fcntl.flock` lock file. A stale socket is safe to replace
after the lock is acquired.

Flutter's `BridgeService` is now a local Unix-domain-socket client. The
runtime directory is selected from `SYSAI_RUNTIME_DIR`, `XDG_RUNTIME_DIR`,
or a per-user state directory; the socket is mode 0600 and its containing
directory is mode 0700 when owned by the process user. The protocol is
versioned, request IDs are preserved, messages are capped at 1 MiB, malformed
JSON is rejected without terminating the server, and no TCP listener exists.

`runtime.status`, `run.*`, `automation.*`, `approval.*`,
`notification.*`, `events.replay`, and `events.subscribe` are the stable
runtime surface. Run events receive a monotonically increasing SQLite
`event_id`; reconnecting clients provide their last cursor and receive an
atomic replay-to-live subscription. Live frames retain the subscription
request ID, so the Flutter stream cannot miss or misroute them. A
runtime-created scheduled Run follows the same
`Run → Capability → Policy → Approval` pipeline as a manually-created Run.

#### Canonical ownership

There is one owner for each execution concern. The Dart tables are projections
for presentation and backwards-compatible local tests; they are not a second
execution state machine.

| Concern | Canonical owner | Flutter/Dart role |
|---|---|---|
| Runs, tasks, plan, terminal state | Python persistent runtime (`runtime_runs`) | Read/projection cache |
| Events and replay cursor | Python runtime (`runtime_events`) | Stream/render projection |
| Scheduler and occurrence claims | Python runtime (`runtime_automations`, `runtime_occurrences`) | CRUD facade only |
| Approval gates | Python runtime/`ApprovalManager`, persisted in `runtime_approvals` | Present and submit a bound response |
| Notifications | Python runtime (`runtime_notifications`) | Read/mark-read projection; native display is best effort |
| Model resolution for a Run | Run-scoped runtime `Config`, then SysAI provider | Select and persist provider/model identifiers |
| Workspace boundary | Run's persisted `workspace_path`, enforced by Python policy/capabilities | Choose/display workspace |
| Terminal and browser execution | Python capability handlers and runtime events | Render live output and derived session rows |
| Computer target authorization | Python runtime target registry and policy | Own the registered test-surface widget and perform the requested action |

No schema version bump was needed: runtime metadata and event cursors live in
new tables outside the application's existing V5 migration contract. Flutter
does not run a scheduler timer in the canonical runtime configuration and
cannot launch a child process independently of the runtime.

Run snapshots are bounded: full event history lives in `runtime_events`
(replayable by cursor), while each run record embeds only a recent window
without per-line `terminal.output` chatter. This keeps `run_json` — and
therefore `run.get`/`run.list` responses — under the 1 MiB IPC frame limit;
a frame that still exceeds it is announced to the client with a
`runtime.warning` instead of being dropped silently. When a Run reaches a
terminal state, the runtime also records `last_result` on the automation
that fired it, so the Automations UI stays truthful while Flutter's local
scheduler loop is dormant.

The runtime produces persisted attention notifications and best-effort
`notify-send` desktop notifications while Flutter is closed. A pending
approval remains pending and is never auto-approved while its runtime is
alive; if the runtime itself crashes, startup recovery marks the Run
interrupted and closes the orphaned in-memory approval rather than leaving an
approval that no worker can consume. Approval and Computer result RPCs are
bound to the originating Run (and Computer target), and duplicate/stale
responses are rejected. The controlled Computer target is explicitly
registered/unregistered by `ComputerView`; a target that was registered and
then disappears causes the runtime action to wait until the target remounts.
It is not simulated.

See `docs/lifecycle.md` for startup, reconnect, close, shutdown, and future
systemd-user integration guidance.

### Phase 6 — Productionization, Packaging, Runtime Service, and Execution Isolation

Phase 6 hardens SysAI OS for installation, persistence, relocatability, and execution isolation:

1. **Centralized XDG Path Layer**:
   - `bridge/sysai_paths.py` defines the canonical path authority for the Python runtime, supporting standard XDG specifications (`XDG_STATE_HOME`, `XDG_CONFIG_HOME`, `XDG_CACHE_HOME`, `XDG_DATA_HOME`, `XDG_RUNTIME_DIR`) with environment overrides (`SYSAI_*`).
   - `lib/config/sysai_config.dart` provides matching path and install-mode awareness on the Dart/Flutter client side.
   - Zero hardcoded personal paths or repository-relative assumptions in production mode.

2. **Dedicated Engine Virtual Environment**:
   - Runtime dependencies and the `sysai-terminal` package are isolated in a user-local virtual environment at `~/.local/share/sysai-os/venv/`.
   - The engine discovery mechanism (`_find_sysai_path()`) automatically discovers packages installed in this dedicated venv.

3. **Systemd User Service Integration**:
   - The runtime service runs as an unprivileged user service (`sysai-os-runtime.service`), managed via `install/manage-service.sh`.
   - Uses `RestartPreventExitStatus=78` (`EX_CONFIG`) to prevent restart loops upon configuration or environment failure.
   - Flutter's `BridgeService` checks for active systemd service state before attempting to spawn a child process.

4. **OS-Level Shell Sandboxing (Bubblewrap)**:
   - `bridge/sandbox.py` adds an OS-level confinement boundary around agent-initiated shell commands via `bwrap`.
   - Four distinct privilege profiles:
     - `OBSERVE`: Read-only workspace binding, unshared network, no `/tmp`.
     - `WORKSPACE_WRITE`: Read-write workspace, unshared network, isolated `/tmp`.
     - `NETWORK_ENABLED`: Read-write workspace, network enabled, isolated `/tmp`.
     - `BUILD_TEST`: Read-write workspace, network enabled, extra toolchain directories visible.
   - Seamless fallback when bubblewrap is unavailable, with policy approval requirements.

5. **Asynchronous Browser Cancellation**:
   - `bridge/capabilities/browser.py` executes network I/O in worker threads polled with `cancel_flag.is_set()` checks every 1.0s, raising `CancelledError` immediately when cancelled.
   - Fetch timeout reduced to 10s.

6. **Rotating Diagnostic Logging**:
   - `bridge/sysai_logging.py` implements structured logging with `RotatingFileHandler` (5 MB maximum per file, 3 backups), default level `WARNING` (production) or `DEBUG` (`SYSAI_LOG_DEBUG=1`).
   - Credentials and model prompts are never written to disk logs.

