# ==============================================================================
# Makefile - KOReader TTS Plugin (Native Rust Core Engine)
# ==============================================================================

SHELL := /bin/bash
.PHONY: all build rust rust-android rust-musl package test test-rust test-lua clean install-adb help

all: build

help:
	@echo "Available targets:"
	@echo "  make build         - Build Android native libraries and package plugin into dist/"
	@echo "  make rust-android  - Cross-compile .so for Android (arm64-v8a, armeabi-v7a)"
	@echo "  make rust-musl     - Cross-compile .so for Kindle & Kobo (Musl static)"
	@echo "  make package       - Package plugin Lua code and libs/ into dist/"
	@echo "  make test          - Run all Rust tests and Lua test suites (100% verification)"
	@echo "  make test-rust     - Run 30 unit tests in rust_core/"
	@echo "  make test-lua      - Run all Lua unit & acceptance test suites"
	@echo "  make install-adb   - Push dist/koreader_tts.koplugin to connected Android device"
	@echo "  make clean         - Clean build targets and dist/ artifacts"

build: rust-android package

rust-android:
	@bash scripts/build_android.sh

rust-musl:
	@bash scripts/build_musl.sh

package:
	@bash scripts/package_plugin.sh

test: test-rust test-lua

test-rust:
	@echo "=== [1/2] Running Rust Unit Tests (30 tests) ==="
	cd rust_core && cargo test

test-lua:
	@echo "=== [2/2] Running Lua Unit & Acceptance Tests ==="
	luajit tests/test_native_ffi.lua
	@for f in tests/test_phase*.lua; do \
		echo "-> Running $$f..."; \
		luajit "$$f" || exit 1; \
	done
	@for f in tests/verify_acceptance_phase*.lua; do \
		echo "-> Running $$f..."; \
		luajit "$$f" || exit 1; \
	done
	@echo "=== ALL TESTS PASSED 100% ==="

install-adb: package
	@echo "=== Installing Plugin to Android Device via ADB ==="
	adb push dist/koreader_tts.koplugin /sdcard/koreader/plugins/
	@echo "[+] Installation complete. Restart KOReader to load updated plugin."

clean:
	@echo "=== Cleaning build artifacts ==="
	rm -rf dist/
	cd rust_core && cargo clean
