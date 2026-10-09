# KOReader TTS Plugin (OpenAI-Compatible)

A high-performance Text-to-Speech (TTS) plugin for [KOReader](https://github.com/koreader/koreader), powered by a native Rust engine (`libtts_core.so`) and designed primarily for **Android E-ink devices** (Onyx Boox, Meebook, Bigme) and Android phones/tablets. Compatible with any OpenAI-compatible TTS server (`POST /v1/audio/speech`).

> **Platform Status**:
> - **Android (arm64-v8a, armeabi-v7a)**: Fully supported and tested with native Rust core.
> - **Linux / Kindle / Kobo / PocketBook**: Experimental / WIP (requires compiling native target or using Pure Lua fallback mode).

---

## Features

- **High-Performance Native Core**: Offloads network I/O, audio decoding, and PCM streaming to background Rust threads via LuaJIT FFI, completely eliminating UI freezes and Android OS ANRs ("KOReader isn't responding").
- **Document Engines**: Works with Crengine (EPUB, MOBI, FB2, TXT) and MuPDF (PDF).
- **Text Processing**: 3-tier sentence chunking (dialogue preservation, anti-fragmentation, safety splitting) and custom pronunciation dictionary with in-app CRUD UI.
- **True Zero-gap Playback**: Seamless audio sample chaining with cross-page preloading and automatic page turns.
- **E-ink Native UI**: Bottom-anchored floating control bar, mini floating bubble mode, and real-time sentence highlighting using partial E-ink refresh (no full screen flashes).
- **Session Hardening**: Sleep timer (15m/30m/45m/end of page), screen standby prevention, session resume by book MD5, and network failure resilience.

---

## Directory Structure

```text
koreader_tts/
├── _meta.lua            # Plugin metadata entry point
├── main.lua             # WidgetContainer entry point & menu integration
│
├── src/
│   ├── ui/              # Presentation layer (player_widget, canvas_highlight)
│   ├── service/         # Application service layer (reading_coordinator, document_chunker, etc.)
│   ├── engine/          # Engine strategy abstraction (ITtsEngine, NativeEngine, FallbackEngine, EngineFactory)
│   └── bridge/          # C-ABI FFI glue (ffi_signatures, ffi_loader, ffi_marshaler) & fallback drivers
│
├── libs/                # Precompiled Android native libraries (arm64-v8a, armeabi-v7a)
├── rust_core/           # Native Rust engine source (tokio, symphonia, ringbuf)
├── scripts/             # Build & packaging scripts
├── Makefile             # Automated build, test, and packaging targets
├── INSTALL.md           # Installation guide
└── tests/               # Modular test suites (runnable via LuaJIT & cargo)
```

---

## Quick Start (Android)

1. Copy the packaged folder into your Android device:
   ```bash
   adb push dist/koreader_tts.koplugin /sdcard/koreader/plugins/
   ```
2. Restart KOReader, go to **Settings (Gear)** → **Plugin management**, and enable **koreader_tts**.
3. Open a book, tap top menu → **Text-to-Speech (TTS)** → **Server settings**:
   - **Server URL**: e.g. `https://api.openai.com/v1/audio/speech` (or self-hosted `http://<server-ip>:8000/v1/audio/speech`)
   - **Voice**: e.g. `alloy`
4. Tap **Start reading from here** or **Test single sentence**.

See [INSTALL.md](INSTALL.md) for detailed platform notes and troubleshooting.

---

## Testing

Run all 30 Rust tests and 5 modular Lua test suites locally:

```bash
make test
```

---

## License

Released under the [GNU General Public License v3.0](https://www.gnu.org/licenses/gpl-3.0.html).
