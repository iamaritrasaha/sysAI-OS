# SysAI OS

**SysAI OS** is an agentic operating environment desktop application built with Flutter, designed to govern and interact with the **SysAI** runtime engine.

It replaces chat-style assistants with an operating system paradigm: users state high-level goals, and SysAI OS manages multi-step execution plans, streaming activity timelines, persistent SQLite runs, and verified outcomes.

---

## Architecture & Integration

- **SysAI Engine is Read-Only**: The core AI runtime, provider routing, Experience Engine, collectors, and diagnostics live in the separate `SysAI` repository. SysAI OS treats it as an external dependency and does not mutate it.
- **Python NDJSON Bridge**: SysAI OS spawns `bridge/sysai_bridge.py` as a subprocess communicating over standard I/O with newline-delimited JSON.
- **State Persistence**: Runs, plan steps, and structured events are stored locally in SQLite (`sysai_os.db`) using WAL mode, surviving application restarts.

For full architectural details, see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

---

## Pointing SysAI_OS to SysAI

SysAI_OS locates the SysAI Python source tree using:

1. **Environment variable** (highest priority):
   ```bash
   export SYSAI_PATH="/path/to/sysai/src"
   ```
2. **`.sysai_path` file** at the root of `SysAI_OS`:
   ```bash
   echo "/path/to/sysai/src" > .sysai_path
   ```
3. **Automatic fallback**: Discovers standard sibling checkouts relative to wherever this repository is cloned, e.g. `<repo-parent>/Projects/sysai/src` or `../SysAI/src`.

---

## Launching the Desktop Application

```bash
# Ensure dependencies are downloaded
flutter pub get

# Launch on Linux desktop
flutter run -d linux
```

---

## Running Verification & Tests

```bash
# Static analysis (zero issues)
flutter analyze

# Run full test suite (domain models, SQLite persistence, widget tests)
flutter test
```

---

## Model Switching

SysAI OS discovers providers and models live from the connected SysAI installation — nothing is hard-coded, and availability is never fabricated:

- `list_providers` / `list_models` / `check_model_availability` (`bridge/sysai_bridge.py`) query Ollama (local), Ollama Cloud, remote Ollama, and OpenAI-compatible endpoints through SysAI's own config/provider modules. A model that isn't actually installed or configured is reported unavailable with a reason, never silently substituted.
- **SysAI OS default model** is its own preference, persisted in the local `settings` table (`default_provider_id` / `default_model_id` / `default_model_display_name`) — it does not write to SysAI's `config.toml`. Change it from the sidebar quick switcher or **System → Models**; the change only affects Runs created afterward.
- **Per-Run override**: the Home goal composer lets you pick a different model for one Run. A Run's `provider_id` / `model_id` / `model_display_name` are stored on the Run itself at creation and never change afterward, even if the global default later changes.
- **Isolation**: `sysai_runner.execute_run` builds an isolated `dataclasses.replace(base_config, ...)` per Run rather than mutating SysAI's shared config object, so concurrent Runs with different models cannot leak into each other. `model.selected` / `model.unavailable` are emitted as structured events; an unavailable model fails the Run instead of executing anyway.
- Schema `V2 → V3` (`lib/services/run_repository.dart`) adds the `settings` table and the three model columns on `runs` via `ALTER TABLE` guarded by try/catch, so it's idempotent and preserves every existing Run, approval, artifact, and checkpoint.

---

## Typography

- **Inter** (SIL OFL 1.1) for all interface text — display, headings, body, labels, buttons. Bundled at `assets/fonts/Inter-*.ttf`; license at `assets/fonts/Inter-LICENSE.txt`.
- **JetBrains Mono** (SIL OFL 1.1) for anything that's literally code: model ids, file paths, shell commands, terminal/event-log output. Bundled at `assets/fonts/JetBrainsMono-*.ttf`; license at `assets/fonts/JetBrainsMono-OFL.txt`.
- Both are declared directly in `pubspec.yaml` and loaded from local assets — no network font fetch at runtime.
- Semantic text styles live in `lib/theme/typography.dart` (`AppText.pageTitle`, `AppText.body`, `AppText.code`, ...) instead of ad hoc `TextStyle`s; shared spacing/radii/icon-size tokens live in `lib/theme/tokens.dart`. Status color/label/icon mapping (Run lifecycle) is centralized in `lib/theme/status.dart` — previously duplicated with three different colors per state across Home, Runs, and Run Detail.

---

## Phase 3: Native Agentic Workspace

SysAI OS gained three new operational surfaces, all going through the same Capability Registry → Policy Engine path as everything else — nothing bypasses policy.

- **Terminal**: `shell.execute` now streams structured `terminal.session.created` / `terminal.output` / `terminal.session.completed` events instead of returning one blob at the end. Output lines are **never persisted individually** — they live in a bounded (500-line) in-memory buffer (`terminalLiveOutputProvider`) that a chatty command can't turn into thousands of SQLite writes. Only the session summary (command, cwd, status, exit code, a bounded output preview) is durable, in the new `terminal_sessions` table. Cancellation registers the process with `ExecutionController` *before* the blocking wait, not after, so `cancel_run()` can actually kill a still-running command.
- **Browser**: a read-mostly capability layer (`bridge/capabilities/browser.py`) — `browser.search` / `.navigate` / `.read` / `.follow_link` / `.download` / `.capture`. Fetches over HTTP and extracts title/text/links with the stdlib `html.parser`; this is **not** a headless rendering browser, and `browser.capture` persists a text/HTML snapshot, not a screenshot. Search uses DuckDuckGo's lite endpoint with a browser User-Agent (the default endpoint serves an anti-bot page to non-browser clients). One `BrowserSession` per Run aggregates navigation history in `browser_sessions`. Downloads are approval-gated and sandboxed to the workspace (defense-in-depth: checked both by the Policy Engine and by the handler itself).
- **Computer** (Phase 3 scope): observation/capture against the host desktop and honestly-reported placeholders for input. Superseded by Phase 4's Controlled Computer Use, below.
- **Background Runs**: `runExecutorProvider` is a plain (non-`autoDispose`) Riverpod `Provider`, so a Run's event-stream subscription lives with the app session, not with the Run Detail screen — navigating away never stops it. The Shell footer shows global active-Run and pending-approval counts regardless of the current page.
- **Notifications**: a `Notification` domain, distinct from the Activity timeline (Activity = what happened; notifications = what needs/needed attention) — fired only for approval-required, run-completed, run-failed, and run-interrupted, persisted in `notifications`, and mirrored to Linux desktop notifications via `notify-send` (zero new dependencies; silently skipped if unavailable). An in-app bell in the Shell shows unread count and opens a short list.
- Schema `V3 → V4` adds `terminal_sessions`, `browser_sessions`, and `notifications`, idempotently, preserving every existing Run/approval/artifact/checkpoint/setting.

---

## Phase 4: Persistent Automations & Controlled Computer Use

- **Automations**: `ScheduledAutomation` (once/interval/daily/weekly) persists a goal, workspace, and provider/model — firing one creates a normal `Run` through the exact same pipeline a manual Run uses. DST-safe scheduling via `package:timezone`; duplicate-trigger protection via a `UNIQUE(automation_id, occurrence_key)` claim table; a deterministic, documented missed-trigger policy (a `once` fires within a 15-minute grace window or is marked missed, a recurring automation catches up once and recomputes past `now`). One central 30-second timer, never one per automation. Manage from the **Automations** tab: create, edit, enable/disable, run now, delete, and see next run / last result / linked past Runs.
- **Controlled Computer Use** — explicitly not unrestricted desktop automation. Real `observe`/`capture`/`click`/`type`/`key`/`scroll` actions execute against exactly one registered, SysAI-owned target: a deterministic Flutter test surface (**Computer** tab). Since the Python bridge can't reach the live widget tree, an action is a request/block/resolve round-trip (mirroring the existing approval flow) — Flutter executes the real widget callback and reports the result back. Any other target is denied outright by the Policy Engine, on target identity. `type`/`key` still require approval even against the registered target. Captures use Flutter's own `RenderRepaintBoundary.toImage()`, not an OS screenshot tool.
- **Workspace selection**: `Run.workspacePath` / the bridge's `workspace_root` parameter are now wired through for every Run (manual or scheduled) — previously silently defaulted for all Runs.
- The Scheduler and any in-flight Run run only while the SysAI OS process is alive — see `docs/lifecycle.md`. This is not a background daemon.
- Schema `V4 → V5` adds `scheduled_automations`, `automation_occurrences`, `computer_sessions`, `computer_actions`, and a `workspace_path` column on `runs`, idempotently, preserving every existing row. See `docs/ARCHITECTURE.md` §8 for the full design.

---

## Phase 1 Capabilities

- **Command Center (Home)**: State goals, view active runs, and monitor engine health and model configuration.
- **Persistent Runs**: Every goal creates a tracked SQLite `Run` with full state machine lifecycle (`CREATED` → `PLANNING` → `READY` → `RUNNING` → `VERIFYING` → `COMPLETED` / `FAILED`).
- **Run Detail View**: Displays original goal, execution plan progress, current action, live structured event timeline, and verified outcome.
- **Experience View**: Read-only explorer into SysAI's Experience Engine memory store (`memory.db`), with search and pattern statistics.
- **System View**: Real-time engine health, versions, and deterministic `doctor` diagnostic checks.
- **Workspace View**: Project structure inspection and foundation for future agentic workspace tools.
