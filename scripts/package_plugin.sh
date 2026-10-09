#!/usr/bin/env bash
# ==============================================================================
# package_plugin.sh - Package KOReader TTS Plugin into dist/koreader_tts.koplugin/
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DIST_DIR="${ROOT_DIR}/dist/koreader_tts.koplugin"

echo "=== [1/3] Preparing Distribution Directory ==="
rm -rf "${DIST_DIR}"
mkdir -p "${DIST_DIR}"

echo "=== [2/3] Copying Plugin Lua Modules ==="
LUA_FILES=(
    "_meta.lua"
    "main.lua"
    "playback_queue.lua"
    "text_chunker.lua"
    "settings.lua"
    "sleep_timer.lua"
    "ui_player.lua"
    "tts_service.lua"
    "tts_client.lua"
    "audio_backend.lua"
    "android_player.lua"
)

for file in "${LUA_FILES[@]}"; do
    if [[ -f "${ROOT_DIR}/${file}" ]]; then
        cp "${ROOT_DIR}/${file}" "${DIST_DIR}/"
        echo "  + ${file}"
    else
        echo "  ! Optional/Missing: ${file}"
    fi
done

echo "=== [2.5/3] Copying Modular Architecture Source Tree (src/) ==="
if [[ -d "${ROOT_DIR}/src" ]]; then
    mkdir -p "${DIST_DIR}/src"
    cp -r "${ROOT_DIR}/src/"* "${DIST_DIR}/src/"
    echo "  + Bundled src/ modular hierarchy (ui, service, engine, bridge)"
fi

echo "=== [3/3] Bundling Native Libraries (libs/) ==="
if [[ -d "${ROOT_DIR}/libs" ]]; then
    mkdir -p "${DIST_DIR}/libs"
    cp -r "${ROOT_DIR}/libs/"* "${DIST_DIR}/libs/" 2>/dev/null || true
    echo "  + Bundled native binaries (.so only):"
    find "${DIST_DIR}/libs" -type f -name "*.so" | while read -r lib; do
        size=$(ls -lh "${lib}" | awk '{print $5}')
        echo "    * $(basename "$(dirname "${lib}")")/$(basename "${lib}") (${size})"
    done
fi

echo ""
echo "=== PACKAGING COMPLETE ==="
echo "Target folder: ${DIST_DIR}"
echo "Ready for installation: copy '${DIST_DIR}' to device plugins directory."
