#!/usr/bin/env bash
# SysAI OS systemd user-service manager
# Usage: manage-service.sh <command>
# Commands: install enable start stop restart status disable uninstall
set -euo pipefail

SERVICE_NAME="sysai-os-runtime"
SERVICE_FILE="${SERVICE_NAME}.service"

# ── Path resolution (mirrors sysai_paths.py) ─────────────────────────────────
XDG_DATA_HOME="${XDG_DATA_HOME:-${HOME}/.local/share}"
XDG_STATE_HOME="${XDG_STATE_HOME:-${HOME}/.local/state}"
XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-${XDG_STATE_HOME}/sysai-os/runtime}"
SYSAI_DATA_DIR="${SYSAI_DATA_DIR:-${XDG_DATA_HOME}/sysai-os}"
SYSAI_STATE_DIR="${SYSAI_STATE_DIR:-${XDG_STATE_HOME}/sysai-os}"

VENV_PYTHON="${SYSAI_DATA_DIR}/venv/bin/python3"
RUNTIME_DIR="${SYSAI_DATA_DIR}/runtime"
SOCKET_PATH="${SYSAI_RUNTIME_SOCKET:-${XDG_RUNTIME_DIR}/sysai-os/runtime.sock}"
SYSTEMD_USER_DIR="${HOME}/.config/systemd/user"
SERVICE_DEST="${SYSTEMD_USER_DIR}/${SERVICE_FILE}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="${SCRIPT_DIR}/sysai-os-runtime.service.template"

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "[sysai-os] $*"; }

cmd_install() {
    [[ -f "${VENV_PYTHON}" ]] || die "Runtime venv not found at ${VENV_PYTHON}. Run install.sh first."
    [[ -f "${RUNTIME_DIR}/sysai_os_runtime.py" ]] || die "Runtime script not found at ${RUNTIME_DIR}. Run install.sh first."
    [[ -f "${TEMPLATE}" ]] || die "Service template not found at ${TEMPLATE}."

    mkdir -p "${SYSTEMD_USER_DIR}"

    sed \
        -e "s|@@VENV_PYTHON@@|${VENV_PYTHON}|g" \
        -e "s|@@RUNTIME_DIR@@|${RUNTIME_DIR}|g" \
        -e "s|@@SOCKET_PATH@@|${SOCKET_PATH}|g" \
        "${TEMPLATE}" > "${SERVICE_DEST}"

    info "Service file installed to ${SERVICE_DEST}"
    systemctl --user daemon-reload
    info "systemd user daemon reloaded."
}

cmd_enable()  { systemctl --user enable "${SERVICE_NAME}" && info "Service enabled."; }
cmd_start()   { systemctl --user start  "${SERVICE_NAME}" && info "Service started."; }
cmd_stop()    { systemctl --user stop   "${SERVICE_NAME}" && info "Service stopped."; }
cmd_restart() { systemctl --user restart "${SERVICE_NAME}" && info "Service restarted."; }
cmd_status()  { systemctl --user status  "${SERVICE_NAME}"; }
cmd_disable() { systemctl --user disable "${SERVICE_NAME}" && info "Service disabled."; }

cmd_uninstall() {
    systemctl --user stop    "${SERVICE_NAME}" 2>/dev/null || true
    systemctl --user disable "${SERVICE_NAME}" 2>/dev/null || true
    rm -f "${SERVICE_DEST}"
    systemctl --user daemon-reload
    info "Service uninstalled."
}

main() {
    local subcmd="${1:-}"
    case "${subcmd}" in
        install)   cmd_install   ;;
        enable)    cmd_enable    ;;
        start)     cmd_start     ;;
        stop)      cmd_stop      ;;
        restart)   cmd_restart   ;;
        status)    cmd_status    ;;
        disable)   cmd_disable   ;;
        uninstall) cmd_uninstall ;;
        *)
            echo "Usage: $0 {install|enable|start|stop|restart|status|disable|uninstall}"
            exit 1
            ;;
    esac
}

main "$@"
