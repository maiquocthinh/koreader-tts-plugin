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
├── _meta.lua            # Plugin metadata
├── main.lua             # Entry point & menu integration
├── settings.lua         # Persistent configuration & pronunciation dictionary
├── text_chunker.lua     # Text extraction & 3-tier chunking
├── tts_client.lua       # Non-blocking HTTP client & cache manager
├── audio_backend.lua    # Multi-platform audio playback adapter
├── playback_queue.lua   # Sliding window buffer & auto page-turn
├── ui_player.lua        # Floating control bar, mini bubble & highlighting
├── sleep_timer.lua      # Sleep timer module
├── INSTALL.md           # Installation guide
└── tests/               # 12 standalone test suites (runnable via LuaJIT)
```

---

## Quick Start

1. Copy the plugin folder to your KOReader plugins directory:
   - **Kobo**: `/.kobo/koreader/plugins/koreader_tts.koplugin/`
   - **Kindle**: `/mnt/us/koreader/plugins/koreader_tts.koplugin/`
   - **Android**: `/sdcard/koreader/plugins/koreader_tts.koplugin/`
   - **PocketBook**: `/system/koreader/plugins/koreader_tts.koplugin/`
2. Restart KOReader, go to **Settings (Gear)** → **Plugin management**, and enable **koreader_tts**.
3. Open a book, tap top menu → **Text-to-Speech (TTS)** → **Server settings**:
   - **Server URL**: e.g. `http://192.168.1.100:7860`
   - **Voice**: e.g. `vi-VN-NamMinh`
4. Tap **Start reading from here** or **Test single sentence**.

See [INSTALL.md](INSTALL.md) for detailed platform-specific setup and troubleshooting.

---

## Testing

Run all 12 test suites locally using LuaJIT:

```bash
luajit tests/test_phase1_settings.lua && \
luajit tests/verify_acceptance_phase1.lua && \
luajit tests/test_phase2_chunker.lua && \
luajit tests/verify_acceptance_phase2.lua && \
luajit tests/test_phase3_network_audio.lua && \
luajit tests/verify_acceptance_phase3.lua && \
luajit tests/test_phase4_queue.lua && \
luajit tests/verify_acceptance_phase4.lua && \
luajit tests/test_phase5_ui.lua && \
luajit tests/verify_acceptance_phase5.lua && \
luajit tests/test_phase6_hardening.lua && \
luajit tests/verify_acceptance_phase6.lua
```

---

## License

Released under the [GNU General Public License v3.0](https://www.gnu.org/licenses/gpl-3.0.html).
