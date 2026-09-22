#!/usr/bin/env bash
# SysAI OS release packager — produces a tarball bundle
# Usage: ./install/package.sh [--version X.Y.Z]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
VERSION="${1:-}"
ARCH=$(uname -m)

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "[package] $*"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) VERSION="$2"; shift 2 ;;
        *) die "Unknown argument: $1" ;;
    esac
done

if [[ -z "${VERSION}" ]]; then
    VERSION=$(grep '^version:' "${PROJECT_DIR}/pubspec.yaml" | awk '{print $2}' | cut -d+ -f1)
fi
[[ -n "${VERSION}" ]] || die "Could not determine version. Pass --version X.Y.Z"

DIST_NAME="sysai-os-${VERSION}-linux-${ARCH}"
DIST_DIR="${PROJECT_DIR}/dist/${DIST_NAME}"
OUT_TARBALL="${PROJECT_DIR}/dist/${DIST_NAME}.tar.gz"

FLUTTER_BUNDLE="${PROJECT_DIR}/build/linux/${ARCH}/release/bundle"
[[ -d "${FLUTTER_BUNDLE}" ]] || FLUTTER_BUNDLE="${PROJECT_DIR}/build/linux/x64/release/bundle"
[[ -d "${FLUTTER_BUNDLE}" ]] || die "Flutter release bundle not found. Run: flutter build linux --release"

info "Packaging SysAI OS ${VERSION} for linux/${ARCH}..."
info "Bundle source: ${FLUTTER_BUNDLE}"

mkdir -p "${DIST_DIR}"
rm -rf "${DIST_DIR:?}/"*

# Flutter app
mkdir -p "${DIST_DIR}/app"
cp -a "${FLUTTER_BUNDLE}/".  "${DIST_DIR}/app/"

# Bridge/runtime Python files
mkdir -p "${DIST_DIR}/runtime" "${DIST_DIR}/runtime/capabilities" "${DIST_DIR}/runtime/policy"
for f in \
    sysai_os_runtime.py sysai_bridge.py sysai_runner.py \
    sysai_paths.py sysai_logging.py sandbox.py \
    approval_manager.py computer_action_manager.py; do
    [[ -f "${PROJECT_DIR}/bridge/${f}" ]] && cp "${PROJECT_DIR}/bridge/${f}" "${DIST_DIR}/runtime/" || true
done
for d in capabilities policy; do
    if [[ -d "${PROJECT_DIR}/bridge/${d}" ]]; then
        rsync -a "${PROJECT_DIR}/bridge/${d}/" "${DIST_DIR}/runtime/${d}/" \
            --exclude='__pycache__' --exclude='*.pyc' --exclude='tests'
    fi
done

# Install scripts
mkdir -p "${DIST_DIR}/install"
cp -a "${SCRIPT_DIR}/"*.sh "${DIST_DIR}/install/" 2>/dev/null || true
cp -a "${SCRIPT_DIR}/"*.template "${DIST_DIR}/install/" 2>/dev/null || true
cp -a "${SCRIPT_DIR}/"*.desktop "${DIST_DIR}/install/" 2>/dev/null || true
chmod +x "${DIST_DIR}/install/"*.sh 2>/dev/null || true

# Root-level install.sh and uninstall.sh for convenience
cp "${SCRIPT_DIR}/install.sh"   "${DIST_DIR}/install.sh"
cp "${SCRIPT_DIR}/uninstall.sh" "${DIST_DIR}/uninstall.sh"
chmod +x "${DIST_DIR}/install.sh" "${DIST_DIR}/uninstall.sh"

# Release notes
cat > "${DIST_DIR}/RELEASE.md" << REOF
# SysAI OS ${VERSION} — Linux (${ARCH})

## Installation

\`\`\`bash
tar -xzf sysai-os-${VERSION}-linux-${ARCH}.tar.gz
cd sysai-os-${VERSION}-linux-${ARCH}
./install.sh --sysai-src /path/to/sysai
\`\`\`

## Requirements
- Linux x86_64 or arm64
- Python 3.11+
- systemd (optional, for background runtime service)
- bubblewrap (optional, for shell sandbox isolation)

## Uninstall
\`\`\`bash
./uninstall.sh
\`\`\`
User data (Runs, DB) is preserved. See uninstall.sh for data removal.
REOF

# Create tarball
mkdir -p "${PROJECT_DIR}/dist"
tar -czf "${OUT_TARBALL}" -C "${PROJECT_DIR}/dist" "${DIST_NAME}"

info "Package created: ${OUT_TARBALL}"
info "Size: $(du -sh "${OUT_TARBALL}" | cut -f1)"
