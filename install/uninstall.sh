#!/usr/bin/env bash
# SysAI OS uninstaller
# Removes APPLICATION FILES only. Does NOT delete user data (runs, DB, config).
# To remove user data: rm -rf ~/.local/state/sysai-os ~/.config/sysai-os
set -euo pipefail

PREFIX="${HOME}/.local"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --prefix) PREFIX="$2"; shift 2 ;;
        *) echo "Usage: $0 [--prefix DIR]"; exit 1 ;;
    esac
done

DATA_DIR="${PREFIX}/share/sysai-os"
BIN_DIR="${PREFIX}/bin"
APPS_DIR="${PREFIX}/share/applications"

info() { echo "[uninstall] $*"; }

# Stop and remove systemd service
if command -v systemctl &>/dev/null; then
    systemctl --user stop    sysai-os-runtime 2>/dev/null || true
    systemctl --user disable sysai-os-runtime 2>/dev/null || true
    rm -f "${HOME}/.config/systemd/user/sysai-os-runtime.service"
    systemctl --user daemon-reload 2>/dev/null || true
    info "Systemd service removed."
fi

# Remove installed files
rm -rf "${DATA_DIR}"
rm -f  "${BIN_DIR}/sysai-os"
rm -f  "${APPS_DIR}/sysai-os.desktop"

if command -v update-desktop-database &>/dev/null; then
    update-desktop-database "${APPS_DIR}" 2>/dev/null || true
fi

info "Application files removed."
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  SysAI OS application files removed."
echo ""
echo "  User data was NOT deleted:"
echo "    ~/.local/state/sysai-os/  (Runs, DB, logs)"
echo "    ~/.config/sysai-os/        (Settings)"
echo "    ~/.cache/sysai-os/         (Cache)"
echo ""
echo "  To permanently delete all user data:"
echo "    rm -rf ~/.local/state/sysai-os ~/.config/sysai-os ~/.cache/sysai-os"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
