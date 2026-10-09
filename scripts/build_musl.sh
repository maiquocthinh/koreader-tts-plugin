#!/usr/bin/env bash
# ==============================================================================
# build_musl.sh - Cross-compile libtts_core.so for Kindle & Kobo (Musl Libc static)
# Target: armv7-unknown-linux-musleabihf
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

export PATH="/c/Users/maiquocthinh/scoop/persist/rustup/.cargo/bin:${PATH}"
export RUSTUP_HOME="${RUSTUP_HOME:-C:/Users/maiquocthinh/scoop/persist/rustup/.rustup}"
export CARGO_HOME="${CARGO_HOME:-C:/Users/maiquocthinh/scoop/persist/rustup/.cargo}"

TARGET="armv7-unknown-linux-musleabihf"

echo "=== [1/2] Compiling Kindle / Kobo Musl Static Binary (${TARGET}) ==="

cd "${ROOT_DIR}/rust_core"

if command -v cross &>/dev/null && docker info &>/dev/null; then
    echo "  -> Using Docker-powered 'cross' compiler..."
    cross build --target "${TARGET}" --release
else
    echo "  -> Docker daemon is not active. Falling back to host cargo..."
    cargo build --target "${TARGET}" --release || {
        echo "[!] WARNING: Native Musl compilation on Windows requires Docker daemon running for 'cross'."
        echo "    Start Docker Desktop to compile armv7-unknown-linux-musleabihf."
        exit 0
    }
fi

SRC_SO="${ROOT_DIR}/rust_core/target/${TARGET}/release/libtts_core.so"
if [[ -f "${SRC_SO}" ]]; then
    mkdir -p "${ROOT_DIR}/libs/kindle-armhf" "${ROOT_DIR}/libs/kobo-armv7l"
    cp "${SRC_SO}" "${ROOT_DIR}/libs/kindle-armhf/libtts_core.so"
    cp "${SRC_SO}" "${ROOT_DIR}/libs/kobo-armv7l/libtts_core.so"
    echo "=== [2/2] Kindle & Kobo Musl .so Binaries Copied Successfully ==="
    ls -lh "${ROOT_DIR}/libs/kindle-armhf/libtts_core.so" "${ROOT_DIR}/libs/kobo-armv7l/libtts_core.so"
fi
