# Installation & Setup Guide

A concise guide to installing and configuring the KOReader TTS Plugin (OpenAI-compatible) on your device.

---

## 1. Supported Platforms & Status

| Platform | Architecture / Core | Status | Plugin Path |
| :--- | :--- | :--- | :--- |
| **Android (Onyx Boox, Meebook, Phones, Tablets)** | `arm64-v8a`, `armeabi-v7a` (`libtts_core.so`) | **Primary & Tested** | `/sdcard/koreader/plugins/koreader_tts.koplugin/` |
| **Linux Desktop / Emulator** | In-process Lua / FFI | Development & Test | `~/.config/koreader/plugins/koreader_tts.koplugin/` |
| **Kindle / Kobo / PocketBook** | Musl static / Pure Lua fallback | Experimental / WIP | `/.kobo/` or `/mnt/us/` plugins folder |

---

## 2. Installation Steps (Android)

1. Package or download the plugin archive (`koreader_tts.koplugin/`). The package contains:
   ```text
   koreader_tts.koplugin/
   ├── _meta.lua            # Plugin metadata
   ├── main.lua             # Entry point
   ├── src/                 # Modular architecture (ui, service, engine, bridge)
   └── libs/                # Native binaries (arm64-v8a, armeabi-v7a)
       ├── arm64-v8a/libtts_core.so
       └── armeabi-v7a/libtts_core.so
   ```
2. Copy the folder to your Android device via ADB or USB:
   ```bash
   adb push dist/koreader_tts.koplugin /sdcard/koreader/plugins/
   ```
3. Restart KOReader.
4. In KOReader, go to **Settings (Gear icon)** → **Plugin management** → enable `[X] koreader_tts`.

---

## 3. Server Configuration

1. Open any book (EPUB, MOBI, PDF).
2. Swipe down from top edge to open Top Menu → **Text-to-Speech (TTS)** → **Settings**:
   - **Server URL**: e.g. `https://api.openai.com/v1/audio/speech` (or self-hosted `http://<server-ip>:8000/v1/audio/speech`).
   - **Voice**: ID of the voice provided by your TTS server.
   - **Speed**: `0.5x` - `2.0x` (default: `1.0x`).
3. Tap **Test single sentence** to verify connectivity and audio output.

---

## 4. Usage & Controls

- **Start Playback**: Top Menu → **Start reading from here**.
- **Floating Control Bar**:
  - `|<` / `>|`: Previous / Next page.
  - `<<` / `>>`: Previous / Next sentence.
  - `▶` / `||`: Play / Pause.
  - `[1.0x]`: Tap to cycle playback speed (`0.8x`, `1.0x`, `1.2x`, `1.5x`, `2.0x`).
  - `[—]`: Minimize to floating bubble.
  - `[✕]`: Stop playback and close player.
- **Mini Floating Bubble**:
  - Tap `[||]` icon to toggle play/pause.
  - Tap text (`3/14 · 1.0x`) to restore full control bar.
- **Sleep Timer**: Tap timer button on control bar footer or top menu to select `Off`, `15m`, `30m`, `45m`, or `End of page`.
- **Read Selection**: Highlight any text on the page → tap **Read with TTS** in the popup toolbar.
- **Resume Session**: Reopening a previously read book shows **Resume previous session (Page X · Sentence Y)** in the top menu.

---

## 5. Troubleshooting

| Issue | Cause | Fix |
| :--- | :--- | :--- |
| **No audio output** | System volume muted or no speaker/BT connected | Connect Bluetooth headphones / 3.5mm jack; check system volume. |
| **Connection failed** | Invalid server URL or Wi-Fi disconnected | Verify device Wi-Fi and ensure server endpoint is reachable on the network. |
| **Device sleeps during audio** | Sleep lock permission restricted | Plugin automatically calls `preventStandby(true)` while playing. Check Android/Kindle power policies. |
| **Storage filling up** | Cached audio files | Plugin auto-prunes cache older than 24h. Tap Stop to trigger instant cleanup. |
