#!/usr/bin/env bash
# ==============================================================================
# build_android.sh - Cross-compile libtts_core.so for Android (arm64-v8a, armeabi-v7a)
# Project: KOReader TTS Plugin
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Locate Android NDK across Linux, macOS, and Windows
if [[ -z "${ANDROID_NDK_HOME:-}" && -z "${NDK_HOME:-}" ]]; then
    if [[ -n "${ANDROID_NDK_ROOT:-}" && -d "${ANDROID_NDK_ROOT}" ]]; then
        export ANDROID_NDK_HOME="${ANDROID_NDK_ROOT}"
        export NDK_HOME="${ANDROID_NDK_ROOT}"
    elif [[ -n "${ANDROID_SDK_ROOT:-}" && -d "${ANDROID_SDK_ROOT}/ndk" ]]; then
        LATEST_NDK=$(ls -d "${ANDROID_SDK_ROOT}/ndk"/* 2>/dev/null | sort -V | tail -n 1 || true)
        if [[ -n "${LATEST_NDK}" && -d "${LATEST_NDK}" ]]; then
            export ANDROID_NDK_HOME="${LATEST_NDK}"
            export NDK_HOME="${LATEST_NDK}"
        fi
    fi
    # Windows Scoop fallback
    DEFAULT_NDK="C:/Users/maiquocthinh/scoop/persist/android-clt/ndk/28.2.13676358"
    if [[ -z "${ANDROID_NDK_HOME:-}" && -d "${DEFAULT_NDK}" ]]; then
        export ANDROID_NDK_HOME="${DEFAULT_NDK}"
        export NDK_HOME="${DEFAULT_NDK}"
    fi
fi

if [[ -z "${ANDROID_NDK_HOME:-}" && -z "${NDK_HOME:-}" ]]; then
    echo "[-] ERROR: Neither ANDROID_NDK_HOME, NDK_HOME, nor ANDROID_NDK_ROOT is set."
    echo "    Please set ANDROID_NDK_HOME to your Android NDK directory."
    exit 1
fi

# Add local scoop rustup paths only if present (Windows host dev)
SCOOP_CARGO="/c/Users/maiquocthinh/scoop/persist/rustup/.cargo/bin"
if [[ -d "${SCOOP_CARGO}" ]]; then
    export PATH="${SCOOP_CARGO}:${PATH}"
    export RUSTUP_HOME="${RUSTUP_HOME:-C:/Users/maiquocthinh/scoop/persist/rustup/.rustup}"
    export CARGO_HOME="${CARGO_HOME:-C:/Users/maiquocthinh/scoop/persist/rustup/.cargo}"
fi

echo "=== [1/2] Compiling Android Native Core (arm64-v8a, armeabi-v7a) ==="
mkdir -p "${ROOT_DIR}/libs"

cd "${ROOT_DIR}/rust_core"
cargo ndk -t arm64-v8a -t armeabi-v7a -o "${ROOT_DIR}/libs" build --release

echo "=== [2/2] Android .so Binaries Generated Successfully ==="
ls -lh "${ROOT_DIR}/libs/arm64-v8a/libtts_core.so" "${ROOT_DIR}/libs/armeabi-v7a/libtts_core.so" 2>/dev/null || true
