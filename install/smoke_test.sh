#!/usr/bin/env bash
# Clean-environment smoke test for SysAI OS
# Creates a completely fresh HOME in /tmp and tests the installed app without
# depending on the development checkout layout.
# Usage: ./install/smoke_test.sh [--sysai-src DIR] [--skip-app]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SYSAI_SRC=""
SKIP_APP=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --sysai-src) SYSAI_SRC="$2"; shift 2 ;;
        --skip-app)  SKIP_APP=true; shift ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

pass() { echo "  ✓ $*"; }
fail() { echo "  ✗ $*" >&2; FAILURES=$((FAILURES+1)); }
FAILURES=0

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  SysAI OS clean-environment smoke test"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── Create isolated HOME ──────────────────────────────────────────────────────
TEST_HOME=$(mktemp -d /tmp/sysai-smoke-XXXXXX)
trap 'echo "Cleaning up ${TEST_HOME}..."; rm -rf "${TEST_HOME}"' EXIT
echo "Test HOME: ${TEST_HOME}"

export HOME="${TEST_HOME}"
export XDG_DATA_HOME="${TEST_HOME}/.local/share"
export XDG_STATE_HOME="${TEST_HOME}/.local/state"
export XDG_CACHE_HOME="${TEST_HOME}/.cache"
export XDG_CONFIG_HOME="${TEST_HOME}/.config"
export XDG_RUNTIME_DIR="${TEST_HOME}/run"
mkdir -p "${XDG_RUNTIME_DIR}"

# Prevent any reference to dev checkout paths
export SYSAI_PATH=""
export SYSAI_RUNTIME_DIR=""
export SYSAI_RUNTIME_DB=""

# ── Run install.sh into synthetic HOME ───────────────────────────────────────
echo ""
echo "[1] Running install.sh..."
INSTALL_ARGS=("--no-service")
[[ -n "${SYSAI_SRC}" ]] && INSTALL_ARGS+=("--sysai-src" "${SYSAI_SRC}")
"${SCRIPT_DIR}/install.sh" "${INSTALL_ARGS[@]}" "--prefix" "${TEST_HOME}/.local" 2>&1 | sed 's/^/  /'

# ── Verify installation layout ────────────────────────────────────────────────
echo ""
echo "[2] Verifying installation layout..."

RUNTIME_SCRIPT="${TEST_HOME}/.local/share/sysai-os/runtime/sysai_os_runtime.py"
VENV_PYTHON="${TEST_HOME}/.local/share/sysai-os/venv/bin/python3"

[[ -f "${RUNTIME_SCRIPT}" ]] && pass "Runtime script exists" || fail "Runtime script missing: ${RUNTIME_SCRIPT}"
[[ -f "${VENV_PYTHON}" ]] && pass "Venv Python exists" || fail "Venv Python missing: ${VENV_PYTHON}"
[[ -x "${TEST_HOME}/.local/bin/sysai-os" ]] && pass "Launcher script exists" || fail "Launcher missing"

# ── Test venv can import sysai_paths ─────────────────────────────────────────
echo ""
echo "[3] Testing venv Python can import runtime modules..."
RUNTIME_DIR="${TEST_HOME}/.local/share/sysai-os/runtime"
if "${VENV_PYTHON}" -c "import sys; sys.path.insert(0,'${RUNTIME_DIR}'); from sysai_paths import PATHS; print('paths ok')" 2>&1 | grep -q 'paths ok'; then
    pass "sysai_paths importable"
else
    fail "sysai_paths import failed"
fi

# ── Test SysAI engine discoverable if installed ───────────────────────────────
if [[ -n "${SYSAI_SRC}" ]]; then
    echo ""
    echo "[4] Testing SysAI engine discovery..."
    if "${VENV_PYTHON}" -c "import sysai" &>/dev/null; then
        pass "SysAI engine importable from venv"
    else
        fail "SysAI engine not importable from venv"
    fi
fi

# ── Start runtime and verify socket/DB creation ───────────────────────────────
echo ""
echo "[5] Starting runtime in background..."
SOCKET_PATH="${XDG_RUNTIME_DIR}/sysai-os/runtime.sock"
DB_PATH="${XDG_STATE_HOME}/sysai-os/sysai_os.db"

RUNTIME_LOG="${TEST_HOME}/runtime_smoke.log"
PYTHONPATH="${RUNTIME_DIR}" "${VENV_PYTHON}" "${RUNTIME_SCRIPT}" \
    --socket "${SOCKET_PATH}" --db "${DB_PATH}" \
    > "${RUNTIME_LOG}" 2>&1 &
RUNTIME_PID=$!
echo "  Runtime PID: ${RUNTIME_PID}"

# Wait for socket
for i in $(seq 1 10); do
    if [[ -S "${SOCKET_PATH}" ]]; then
        pass "Socket created at ${SOCKET_PATH}"
        break
    fi
    sleep 0.5
done
[[ -S "${SOCKET_PATH}" ]] || fail "Socket not created after 5s"

# Check DB
sleep 0.5
[[ -f "${DB_PATH}" ]] && pass "Database created at ${DB_PATH}" || fail "Database not created"

# ── Verify runtime responds via socket (send a ping) ─────────────────────────
echo ""
echo "[6] Testing runtime IPC..."
PING_RESULT=$(python3 -c "
import socket, json, time
try:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect('${SOCKET_PATH}')
    s.settimeout(5)
    line = s.recv(8192).decode()
    msg = json.loads(line)
    print('ready' if msg.get('type') == 'ready' else 'unexpected:' + line[:80])
except Exception as e:
    print('error:' + str(e))
" 2>&1)
if echo "${PING_RESULT}" | grep -q "ready"; then
    pass "Runtime responded with ready message"
else
    fail "Runtime IPC check failed: ${PING_RESULT}"
fi

# ── Verify runtime survives after simulated UI disconnect ─────────────────────
echo ""
echo "[7] Verifying runtime persists after disconnect..."
sleep 1
if kill -0 "${RUNTIME_PID}" 2>/dev/null; then
    pass "Runtime still alive after connection closed"
else
    fail "Runtime exited unexpectedly"
fi

# ── Check log file was created ────────────────────────────────────────────────
LOG_FILE="${XDG_STATE_HOME}/sysai-os/logs/runtime.log"
echo ""
echo "[8] Checking log file..."
[[ -f "${LOG_FILE}" ]] && pass "Log file created at ${LOG_FILE}" || \
    { echo "  ℹ  Log file at ${LOG_FILE} (may not exist if no warnings logged — normal)"; }

# ── Cleanup runtime ───────────────────────────────────────────────────────────
kill "${RUNTIME_PID}" 2>/dev/null || true
wait "${RUNTIME_PID}" 2>/dev/null || true

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [[ "${FAILURES}" -eq 0 ]]; then
    echo "  ✓ All smoke tests passed!"
else
    echo "  ✗ ${FAILURES} smoke test(s) FAILED"
    exit 1
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
