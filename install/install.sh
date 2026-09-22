#!/usr/bin/env bash
# SysAI OS installer
# Usage: ./install.sh [--prefix DIR] [--sysai-src DIR] [--no-service] [--help]
#
# Installs SysAI OS into a user-local prefix (default: ~/.local).
# This script is idempotent — running it again updates an existing install.
set -euo pipefail

# ── Defaults ─────────────────────────────────────────────────────────────────
PREFIX="${HOME}/.local"
SYSAI_SRC=""
INSTALL_SERVICE=true
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -d "${SCRIPT_DIR}/app" || -d "${SCRIPT_DIR}/runtime" || -d "${SCRIPT_DIR}/bridge" ]]; then
    BUNDLE_DIR="${SCRIPT_DIR}"
else
    BUNDLE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
fi

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "[install] $*"; }

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --prefix)      PREFIX="$2";       shift 2 ;;
        --sysai-src)   SYSAI_SRC="$2";    shift 2 ;;
        --no-service)  INSTALL_SERVICE=false; shift ;;
        --help|-h)
            echo "Usage: $0 [--prefix DIR] [--sysai-src DIR] [--no-service]"
            echo "  --prefix DIR      Install prefix (default: ~/.local)"
            echo "  --sysai-src DIR   Path to SysAI engine source (optional)"
            echo "  --no-service      Skip systemd user service installation"
            exit 0
            ;;
        *) die "Unknown argument: $1" ;;
    esac
done

# ── Path setup ────────────────────────────────────────────────────────────────
DATA_DIR="${PREFIX}/share/sysai-os"
BIN_DIR="${PREFIX}/bin"
APPS_DIR="${PREFIX}/share/applications"
APP_DIR="${DATA_DIR}/app"
RUNTIME_DEST="${DATA_DIR}/runtime"
VENV_DIR="${DATA_DIR}/venv"

info "Installation prefix: ${PREFIX}"
info "Data directory:       ${DATA_DIR}"

# ── Prerequisites ─────────────────────────────────────────────────────────────
PYTHON=$(command -v python3 || true)
[[ -n "${PYTHON}" ]] || die "python3 not found. Please install Python 3.11+."

PY_VERSION=$("${PYTHON}" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
PY_MAJOR=$(echo "${PY_VERSION}" | cut -d. -f1)
PY_MINOR=$(echo "${PY_VERSION}" | cut -d. -f2)
[[ "${PY_MAJOR}" -gt 3 || ("${PY_MAJOR}" -eq 3 && "${PY_MINOR}" -ge 11) ]] || \
    die "Python 3.11+ required (found ${PY_VERSION})"
info "Python: ${PYTHON} (${PY_VERSION})"

# ── Create directory layout ───────────────────────────────────────────────────
mkdir -p "${DATA_DIR}" "${BIN_DIR}" "${APPS_DIR}" "${APP_DIR}" "${RUNTIME_DEST}"

# ── Copy Flutter app bundle ───────────────────────────────────────────────────
# Look for built app in standard Flutter build output locations
FLUTTER_BUNDLE=""
for candidate in \
    "${BUNDLE_DIR}/app" \
    "${BUNDLE_DIR}/build/linux/x64/release/bundle" \
    "${BUNDLE_DIR}/build/linux/arm64/release/bundle"; do
    if [[ -d "${candidate}" && -x "${candidate}/sysai" ]]; then
        FLUTTER_BUNDLE="${candidate}"
        break
    fi
done

if [[ -n "${FLUTTER_BUNDLE}" ]]; then
    info "Copying Flutter bundle from ${FLUTTER_BUNDLE}..."
    rsync -a --delete "${FLUTTER_BUNDLE}/" "${APP_DIR}/"
    info "Flutter app installed to ${APP_DIR}"
else
    info "WARNING: Flutter release bundle not found. Skipping app copy."
    info "         Build with: flutter build linux --release"
    info "         Then re-run install.sh"
fi

# ── Copy runtime Python files ─────────────────────────────────────────────────
BRIDGE_SRC=""
for candidate in \
    "${BUNDLE_DIR}/runtime" \
    "${BUNDLE_DIR}/bridge"; do
    if [[ -d "${candidate}" ]]; then
        BRIDGE_SRC="${candidate}"
        break
    fi
done
[[ -n "${BRIDGE_SRC}" ]] || die "Bridge/runtime directory not found in ${BUNDLE_DIR}"

info "Copying runtime files from ${BRIDGE_SRC}..."
for f in \
    sysai_os_runtime.py sysai_bridge.py sysai_runner.py \
    sysai_paths.py sysai_logging.py sandbox.py \
    approval_manager.py computer_action_manager.py; do
    [[ -f "${BRIDGE_SRC}/${f}" ]] && cp "${BRIDGE_SRC}/${f}" "${RUNTIME_DEST}/" || true
done

# Copy subdirectories
for d in capabilities policy; do
    if [[ -d "${BRIDGE_SRC}/${d}" ]]; then
        mkdir -p "${RUNTIME_DEST}/${d}"
        rsync -a "${BRIDGE_SRC}/${d}/" "${RUNTIME_DEST}/${d}/" --exclude='__pycache__' --exclude='*.pyc'
    fi
done
info "Runtime files installed to ${RUNTIME_DEST}"

# ── Create / update Python venv ───────────────────────────────────────────────
if [[ ! -d "${VENV_DIR}" ]]; then
    info "Creating Python virtual environment at ${VENV_DIR}..."
    "${PYTHON}" -m venv "${VENV_DIR}"
else
    info "Updating existing venv at ${VENV_DIR}..."
fi

VENV_PIP="${VENV_DIR}/bin/pip"
VENV_PYTHON="${VENV_DIR}/bin/python3"

"${VENV_PIP}" install --quiet --upgrade pip

# ── Install SysAI engine into venv ───────────────────────────────────────────
if [[ -n "${SYSAI_SRC}" ]]; then
    [[ -d "${SYSAI_SRC}" ]] || die "--sysai-src directory not found: ${SYSAI_SRC}"
    info "Installing SysAI engine from ${SYSAI_SRC}..."
    "${VENV_PIP}" install --quiet -e "${SYSAI_SRC}"
elif [[ -f "${BUNDLE_DIR}/sysai_engine.tar.gz" ]]; then
    info "Installing SysAI engine from bundled tarball..."
    "${VENV_PIP}" install --quiet "${BUNDLE_DIR}/sysai_engine.tar.gz"
else
    info "WARNING: SysAI engine source not found. Runtime will start without AI capability."
    info "         Pass --sysai-src /path/to/sysai to install the engine."
fi

# ── Install wrapper launcher ──────────────────────────────────────────────────
WRAPPER="${BIN_DIR}/sysai-os"
cat > "${WRAPPER}" << 'WRAPPER_EOF'
#!/usr/bin/env bash
# SysAI OS launcher
XDG_DATA_HOME="${XDG_DATA_HOME:-${HOME}/.local/share}"
SYSAI_DATA_DIR="${SYSAI_DATA_DIR:-${XDG_DATA_HOME}/sysai-os}"
exec "${SYSAI_DATA_DIR}/app/sysai" "$@"
WRAPPER_EOF
chmod +x "${WRAPPER}"
info "Launcher installed to ${WRAPPER}"

# ── Install .desktop file ─────────────────────────────────────────────────────
DESKTOP_SRC=""
MANAGE_SVC=""
for candidate in "${SCRIPT_DIR}" "${SCRIPT_DIR}/install" "${BUNDLE_DIR}/install"; do
    [[ -z "${DESKTOP_SRC}" && -f "${candidate}/sysai-os.desktop" ]] && DESKTOP_SRC="${candidate}/sysai-os.desktop"
    [[ -z "${MANAGE_SVC}" && -f "${candidate}/manage-service.sh" ]] && MANAGE_SVC="${candidate}/manage-service.sh"
done

if [[ -n "${DESKTOP_SRC}" ]]; then
    cp "${DESKTOP_SRC}" "${APPS_DIR}/sysai-os.desktop"
    if command -v update-desktop-database &>/dev/null; then
        update-desktop-database "${APPS_DIR}" 2>/dev/null || true
    fi
    info "Desktop entry installed to ${APPS_DIR}/sysai-os.desktop"
fi

# ── Optionally install systemd service ────────────────────────────────────────
if [[ "${INSTALL_SERVICE}" == true ]]; then
    if [[ -n "${MANAGE_SVC}" ]] && command -v systemctl &>/dev/null; then
        info "Installing systemd user service..."
        "${MANAGE_SVC}" install || \
            info "WARNING: systemd service install failed (non-fatal, run manage-service.sh install later)"
    elif ! command -v systemctl &>/dev/null; then
        info "systemctl not available — skipping service installation."
    fi
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  SysAI OS installed successfully!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
[[ -x "${APP_DIR}/sysai" ]] && echo "  App:     ${APP_DIR}/sysai"
echo "  Runtime: ${RUNTIME_DEST}"
echo "  Venv:    ${VENV_DIR}"
echo "  Launcher:${WRAPPER}"
echo ""
echo "  Start the runtime service:"
echo "    ${SCRIPT_DIR}/manage-service.sh enable"
echo "    ${SCRIPT_DIR}/manage-service.sh start"
echo ""
echo "  Or launch the app directly:"
echo "    sysai-os"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
