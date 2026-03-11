#!/usr/bin/env bash
set -euo pipefail

# ═══════════════════════════════════════════════════════════════
# Build Orthanc Store-and-Forward Windows .exe from macOS
# Uses Inno Setup via Docker (amake/innosetup)
#
# This script:
#   1. Downloads the official Orthanc Windows installer (if needed)
#   2. Compiles everything into a single .exe installer
# ═══════════════════════════════════════════════════════════════

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

ORTHANC_VERSION="26.1.0"
ORTHANC_URL="https://orthanc.uclouvain.be/downloads/windows-64/installers/OrthancInstaller-Win64-${ORTHANC_VERSION}.exe"
ORTHANC_FILE="resources/OrthancInstaller-Win64.exe"

echo ""
echo "╔═══════════════════════════════════════════════════════════╗"
echo "║  Building Orthanc Store-and-Forward Windows Installer    ║"
echo "║  Inno Setup via Docker → .exe                            ║"
echo "╚═══════════════════════════════════════════════════════════╝"
echo ""

# ── Check Docker ─────────────────────────────────────────────
if ! command -v docker &>/dev/null; then
    echo "❌  Docker is not installed."
    exit 1
fi

if ! docker info &>/dev/null 2>&1; then
    echo "❌  Docker daemon is not running."
    exit 1
fi

# ── Download Orthanc binaries if needed ──────────────────────
if [[ -f "${ORTHANC_FILE}" ]]; then
    SIZE=$(ls -lh "${ORTHANC_FILE}" | awk '{print $5}')
    echo "[1/3] Orthanc installer already downloaded (${SIZE})"
else
    echo "[1/3] Downloading Orthanc Windows installer v${ORTHANC_VERSION} …"
    echo "      URL: ${ORTHANC_URL}"
    curl -L -o "${ORTHANC_FILE}" "${ORTHANC_URL}"
    SIZE=$(ls -lh "${ORTHANC_FILE}" | awk '{print $5}')
    echo "      Downloaded: ${SIZE}"
fi
echo ""

# ── Compile with Inno Setup ─────────────────────────────────
rm -rf output/

echo "[2/3] Compiling installer with Inno Setup …"
echo ""

docker run --rm \
    --platform linux/amd64 \
    -v "${SCRIPT_DIR}:/work" \
    amake/innosetup \
    setup.iss

echo ""
echo "[3/3] Checking output …"

if [[ -f "${SCRIPT_DIR}/output/CrowdDICOM-Setup.exe" ]]; then
    SIZE=$(ls -lh "${SCRIPT_DIR}/output/CrowdDICOM-Setup.exe" | awk '{print $5}')
    echo ""
    echo "╔═══════════════════════════════════════════════════════════╗"
    echo "║  ✅  Build successful!                                   ║"
    echo "╠═══════════════════════════════════════════════════════════╣"
    echo "║                                                         ║"
    printf "║  Output: output/CrowdDICOM-Setup.exe            ║\n"
    printf "║  Size:   %-44s  ║\n" "${SIZE}"
    echo "║                                                         ║"
    echo "║  Includes:                                              ║"
    echo "║    • Orthanc DICOM server v${ORTHANC_VERSION}                      ║"
    echo "║    • Store-and-forward Lua script                       ║"
    echo "║    • Configuration wizard                               ║"
    echo "║    • Auto service setup + startup                       ║"
    echo "║                                                         ║"
    echo "║  Copy this .exe to a Windows machine to install.        ║"
    echo "║                                                         ║"
    echo "╚═══════════════════════════════════════════════════════════╝"
    echo ""
else
    echo "❌  Build output not found."
    ls -la "${SCRIPT_DIR}/output/" 2>/dev/null || echo "    output/ directory does not exist"
    exit 1
fi
