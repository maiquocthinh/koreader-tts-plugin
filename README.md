# KOReader TTS Plugin (OpenAI-Compatible)

A high-performance Text-to-Speech (TTS) plugin for [KOReader](https://github.com/koreader/koreader), designed for E-ink devices, Android, and Linux. Compatible with any OpenAI-compatible TTS server (`POST /v1/audio/speech`).

---

## Features

- **Document Engines**: Works with Crengine (EPUB, MOBI, FB2, TXT) and MuPDF (PDF).
- **Text Processing**: 3-tier sentence chunking (dialogue preservation, anti-fragmentation, safety splitting) and custom pronunciation dictionary with in-app CRUD UI.
- **Non-blocking Network**: Coroutine + socket polling streaming with atomic disk caching (`.wav`), keeping UI 100% responsive.
- **Hardware Audio Backends**: Native drivers for Android (`MediaPlayer`), Linux/Kobo/Kindle (`mpv`/`aplay`), and Desktop.
- **Zero-gap Playback (< 100ms)**: 3-slot sliding window buffer (`Slot N`: playing, `Slot N+1`: ready, `Slot N+2`: prefetching) with seamless cross-page preload and auto page-turn.
- **E-ink Native UI**: Bottom-anchored floating control bar, mini floating bubble mode, and real-time sentence highlighting using partial refresh (no screen flash).
- **Hardening**: Sleep timer (15m/30m/45m/end of page), prevent standby lock, resume last session by book MD5, and skip-on-error network resilience.

---

## Directory Structure

```text
koreader_tts/
├── _meta.lua            # Plugin metadata entry point
├── main.lua             # WidgetContainer entry point & menu integration
│
├── [Root Shims - 100% Backward Compatibility]
├── settings.lua         # Forwarding shim -> src/service/settings_manager
├── text_chunker.lua     # Forwarding shim -> src/service/document_chunker
├── playback_queue.lua   # Forwarding shim -> src/service/reading_coordinator
├── ui_player.lua        # Forwarding shim -> src/ui/player_widget
├── sleep_timer.lua      # Forwarding shim -> src/service/sleep_timer
├── tts_service.lua      # Forwarding shim -> src/engine/engine_factory
├── tts_client.lua       # Forwarding shim -> src/bridge/fallback/tts_client
├── audio_backend.lua    # Forwarding shim -> src/bridge/fallback/audio_backend
├── android_player.lua   # Forwarding shim -> src/bridge/fallback/android_player
│
├── src/
│   ├── ui/              # Presentation layer (player_widget, canvas_highlight)
│   ├── service/         # Application service layer (reading_coordinator, document_chunker, etc.)
│   ├── engine/          # Engine strategy abstraction (ITtsEngine, NativeEngine, FallbackEngine, EngineFactory)
│   └── bridge/          # C-ABI FFI glue (ffi_signatures, ffi_loader, ffi_marshaler) & fallback drivers
│
├── libs/                # Precompiled native libraries (Android arm64-v8a, armeabi-v7a)
├── rust_core/           # Native Rust engine source (tokio, symphonia, ringbuf)
├── scripts/             # Build & packaging scripts
├── Makefile             # Automated build, test, and packaging targets
├── INSTALL.md           # Installation guide
└── tests/               # 14 standalone test suites (runnable via LuaJIT & cargo)
```

---

## Quick Start

1. Copy the plugin folder to your KOReader plugins directory:
   - **Android**: `/sdcard/koreader/plugins/koreader_tts.koplugin/`
   - **Kobo**: `/.kobo/koreader/plugins/koreader_tts.koplugin/`
   - **Kindle**: `/mnt/us/koreader/plugins/koreader_tts.koplugin/`
   - **PocketBook**: `/system/koreader/plugins/koreader_tts.koplugin/`
2. Restart KOReader, go to **Settings (Gear)** → **Plugin management**, and enable **koreader_tts**.
3. Open a book, tap top menu → **Text-to-Speech (TTS)** → **Server settings**:
   - **Server URL**: e.g. `http://192.168.1.100:7860`
   - **Voice**: e.g. `vi-VN-NamMinh`
4. Tap **Start reading from here** or **Test single sentence**.

See [INSTALL.md](INSTALL.md) for detailed platform-specific setup and troubleshooting.

---

## Testing

Run all 30 Rust tests and 14 Lua test suites locally:

```bash
make test
```

---

## License

Released under the [GNU General Public License v3.0](https://www.gnu.org/licenses/gpl-3.0.html).
