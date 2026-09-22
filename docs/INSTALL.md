# SysAI OS — Installation Guide

## Prerequisites

- Linux x86_64 or arm64
- Python 3.11 or newer
- A Flutter-built SysAI OS binary (included in release packages)
- Optional: [bubblewrap](https://github.com/containers/bubblewrap) for shell sandbox isolation
- Optional: systemd (for background runtime service)

## Installing from a Release Package

```bash
tar -xzf sysai-os-<version>-linux-x86_64.tar.gz
cd sysai-os-<version>-linux-x86_64
./install.sh --sysai-src /path/to/sysai
```

The installer:
1. Copies the Flutter app to `~/.local/share/sysai-os/app/`
2. Copies runtime Python files to `~/.local/share/sysai-os/runtime/`
3. Creates a dedicated Python venv at `~/.local/share/sysai-os/venv/`
4. Installs the SysAI engine into the venv
5. Creates a launcher script at `~/.local/bin/sysai-os`
6. Installs a `.desktop` entry
7. Optionally installs the systemd user service

## Installing the Runtime Service

The persistent runtime can operate as a systemd user service, enabling scheduled automations even when the UI is closed:

```bash
./install/manage-service.sh install
./install/manage-service.sh enable
./install/manage-service.sh start
```

Check status:
```bash
./install/manage-service.sh status
```

## Filesystem Layout (Production)

| Path | Purpose |
|------|--------|
| `~/.local/share/sysai-os/app/` | Flutter application |
| `~/.local/share/sysai-os/runtime/` | Python runtime files |
| `~/.local/share/sysai-os/venv/` | Python virtual environment |
| `~/.local/state/sysai-os/sysai_os.db` | Persistent Runs database |
| `~/.local/state/sysai-os/logs/` | Runtime logs (rotating, max ~20 MB) |
| `~/.config/sysai-os/` | User configuration |
| `~/.cache/sysai-os/captures/` | Computer Use screenshots |
| `~/.cache/sysai-os/downloads/` | Browser downloads |
| `$XDG_RUNTIME_DIR/sysai-os/runtime.sock` | IPC Unix socket |

All paths respect XDG environment variables and can be overridden via:
- `SYSAI_RUNTIME_DIR`, `SYSAI_RUNTIME_DB`, `SYSAI_RUNTIME_SOCKET`
- `SYSAI_STATE_DIR`, `SYSAI_CONFIG_DIR`, `SYSAI_CACHE_DIR`, `SYSAI_DATA_DIR`

## Uninstalling

```bash
./uninstall.sh
```

This removes application files only. Your Runs, database, and configuration are preserved.

To also remove user data:
```bash
rm -rf ~/.local/state/sysai-os ~/.config/sysai-os ~/.cache/sysai-os
```

## Development Mode

To run from a development checkout without installing:

```bash
cd /path/to/SysAI_OS
echo '/path/to/sysai/src' > .sysai_path
flutter run -d linux
```

Or with an environment variable:
```bash
SYSAI_PATH=/path/to/sysai/src flutter run -d linux
```

## Environment Variables Reference

| Variable | Purpose |
|----------|--------|
| `SYSAI_PATH` | Override SysAI engine discovery (dev mode) |
| `SYSAI_RUNTIME_DIR` | Override runtime socket/PID directory |
| `SYSAI_RUNTIME_DB` | Override database path |
| `SYSAI_RUNTIME_SOCKET` | Override socket path |
| `SYSAI_STATE_DIR` | Override state directory |
| `SYSAI_CONFIG_DIR` | Override config directory |
| `SYSAI_CACHE_DIR` | Override cache directory |
| `SYSAI_DATA_DIR` | Override data directory |
| `SYSAI_LOG_FILE` | Override log file path |
| `SYSAI_LOG_DEBUG` | Set to `1` for DEBUG-level logging |
| `SYSAI_SANDBOX_DISABLED` | Set to `1` to disable bubblewrap sandbox |
| `SYSAI_SANDBOX_PROFILE` | Override sandbox profile (observe/workspace_write/network_enabled/build_test) |
