# SysAI OS Development Guide

## Prerequisites

1. **Flutter SDK**: 3.29+ / Dart 3.7+
2. **Python 3**: 3.11+
3. **Linux Desktop Tools**: `clang`, `cmake`, `ninja-build`, `pkg-config`, `libgtk-3-dev`, `libsqlite3-0`
4. **SysAI Engine**: The separate `sysai` repository.

---

## Pointing SysAI_OS to SysAI

SysAI_OS needs to locate the SysAI Python source tree at runtime. It searches in the following order:

### 1. Environment Variable (Recommended for Development)
```bash
export SYSAI_PATH="/path/to/sysai/src"
```

### 2. `.sysai_path` File (Convenient for Local Clones)
Place a single-line file named `.sysai_path` at the root of `SysAI_OS`, pointing at your local checkout:
```
/path/to/sysai/src
```

### 3. Automatic Discovery
If neither is specified, SysAI_OS attempts to locate sibling checkouts relative to wherever this repository is cloned:
- `<parent-of-repo-parent>/Projects/sysai/src`
- `../SysAI/src`
- `../../Projects/sysai/src`

---

## Running the Application

```bash
cd /path/to/SysAI_OS

# Get dependencies
flutter pub get

# Run on Linux desktop
flutter run -d linux
```

The desktop app connects to a per-user `sysai-os/runtime.sock`. If it is not
already running, Flutter starts `bridge/sysai_os_runtime.py` detached. To
inspect the runtime directly:

```bash
PYTHONPATH=bridge SYSAI_PATH=/path/to/sysai/src \
  python3 bridge/sysai_os_runtime.py
```

Set `SYSAI_RUNTIME_DIR`, `SYSAI_RUNTIME_SOCKET`, or `SYSAI_RUNTIME_DB` for
isolated development/test locations. The socket is local-only and the
runtime directory is user-scoped. Closing Flutter is intentionally not a
runtime shutdown; use the `runtime.shutdown` IPC operation for an explicit
stop. Models are discovered from the connected SysAI providers at runtime;
SysAI OS does not select or embed a fixed model name.

---

## Running Tests

```bash
# Static analysis (zero issues expected)
flutter analyze

# Run all test suites
flutter test

# Run individual suites
flutter test test/models/run_test.dart
flutter test test/services/run_repository_test.dart
flutter test test/config/sysai_config_test.dart
flutter test test/widget_test.dart
```

---

## Testing the Python Bridge Directly

The Python bridge can be tested interactively using standard NDJSON:

```bash
export SYSAI_PATH="/path/to/sysai/src"
python3 bridge/sysai_bridge.py
```

Then paste JSON-RPC-like commands to `stdin` (this legacy bridge entrypoint is
still supported for compatibility; desktop uses the runtime socket):

```json
{"id": "1", "method": "get_doctor", "params": {"probe_model": false}}
{"id": "2", "method": "get_config"}
{"id": "3", "method": "get_memory_stats"}
{"id": "4", "method": "execute_run", "params": {"run_id": "test-1", "goal": "Inspect the SysAI OS project and report whether its test/build environment is healthy."}}
```

---

## Phase 6 Tooling & Packaging

### Testing
```bash
# Run all Python bridge and sandbox tests
PYTHONPATH=bridge python3 -m unittest discover -s bridge/tests -v

# Run clean-environment smoke test (verifies installation without repo deps)
./install/smoke_test.sh --sysai-src /path/to/sysai
```

### Packaging a Release
```bash
# Build Flutter release bundle
flutter build linux --release

# Package tarball distribution
./install/package.sh
```

### Managing Runtime Service
```bash
# Install and control user service
./install/manage-service.sh install
./install/manage-service.sh enable
./install/manage-service.sh start
./install/manage-service.sh status
```

---

## Architecture Rules to Maintain

1. **Zero Modifications to SysAI**: The SysAI repository is strictly immutable. Do not write or commit any code to `sysai`.
2. **Deterministic UI State**: The UI renders persisted `Run`, `RunTask`, and `RunEvent` data from SQLite. Ephemeral widget state must not be used for execution status.
3. **Structured Events Only**: Never parse terminal ANSI strings or raw text to determine run status.
4. **Desktop-First UI**: Keep interface calm, technical, and responsive. Avoid chatbot chatter aesthetics.
5. **Relocatable & XDG Compliant**: Always resolve paths via `SysAIPaths` (Python) and `SysAIConfig` (Dart). Never hardcode machine-specific paths.
6. **Execution Isolation**: Use Bubblewrap (`bwrap`) profiles for agent-driven shell execution.

