#!/usr/bin/env bash
# ==============================================================================
# build_android.sh - Cross-compile libtts_core.so for Android (arm64-v8a, armeabi-v7a)
# Project: KOReader TTS Plugin
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Ensure NDK environment variable is configured
if [[ -z "${ANDROID_NDK_HOME:-}" && -z "${NDK_HOME:-}" ]]; then
    DEFAULT_NDK="C:/Users/maiquocthinh/scoop/persist/android-clt/ndk/28.2.13676358"
    if [[ -d "${DEFAULT_NDK}" ]]; then
        export ANDROID_NDK_HOME="${DEFAULT_NDK}"
        export NDK_HOME="${DEFAULT_NDK}"
    else
        echo "[-] ERROR: Neither ANDROID_NDK_HOME nor NDK_HOME is set."
        echo "    Please set ANDROID_NDK_HOME to your Android NDK directory."
        exit 1
    fi
fi

export PATH="/c/Users/maiquocthinh/scoop/persist/rustup/.cargo/bin:${PATH}"
export RUSTUP_HOME="${RUSTUP_HOME:-C:/Users/maiquocthinh/scoop/persist/rustup/.rustup}"
export CARGO_HOME="${CARGO_HOME:-C:/Users/maiquocthinh/scoop/persist/rustup/.cargo}"

echo "=== [1/2] Compiling Android Native Core (arm64-v8a, armeabi-v7a) ==="
mkdir -p "${ROOT_DIR}/libs"

cd "${ROOT_DIR}/rust_core"
cargo ndk -t arm64-v8a -t armeabi-v7a -o "${ROOT_DIR}/libs" build --release

echo "=== [2/2] Android .so Binaries Generated Successfully ==="
ls -lh "${ROOT_DIR}/libs/arm64-v8a/libtts_core.so" "${ROOT_DIR}/libs/armeabi-v7a/libtts_core.so" 2>/dev/null || true
