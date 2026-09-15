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
3. **Automatic fallback**: Discovers standard sibling paths such as `/media/hrik/Hrik/Projects/sysai/src`.

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

## Phase 1 Capabilities

- **Command Center (Home)**: State goals, view active runs, and monitor engine health and model configuration.
- **Persistent Runs**: Every goal creates a tracked SQLite `Run` with full state machine lifecycle (`CREATED` → `PLANNING` → `READY` → `RUNNING` → `VERIFYING` → `COMPLETED` / `FAILED`).
- **Run Detail View**: Displays original goal, execution plan progress, current action, live structured event timeline, and verified outcome.
- **Experience View**: Read-only explorer into SysAI's Experience Engine memory store (`memory.db`), with search and pattern statistics.
- **System View**: Real-time engine health, versions, and deterministic `doctor` diagnostic checks.
- **Workspace View**: Project structure inspection and foundation for future agentic workspace tools.
