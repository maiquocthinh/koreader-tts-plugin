# Installation & Setup Guide

A concise guide to installing and configuring the KOReader TTS Plugin (OpenAI-compatible) on your device.

---

## 1. Plugin Directory by Device

Connect your device via USB and locate the KOReader plugins directory:

| Device | Plugin Path |
| :--- | :--- |
| **Kobo** | `/.kobo/koreader/plugins/koreader_tts.koplugin/` |
| **Kindle (Jailbroken)** | `/mnt/us/koreader/plugins/koreader_tts.koplugin/` |
| **Android (Boox, Meebook, etc.)** | `/sdcard/koreader/plugins/koreader_tts.koplugin/` |
| **PocketBook** | `/system/koreader/plugins/koreader_tts.koplugin/` |
| **Desktop / Linux PC** | `~/.config/koreader/plugins/koreader_tts.koplugin/` |

---

## 2. Installation Steps

1. Copy all project files into `koreader_tts.koplugin/` at the path listed above:
   ```text
   koreader_tts.koplugin/
   ├── _meta.lua
   ├── main.lua
   ├── settings.lua
   ├── text_chunker.lua
   ├── tts_client.lua
   ├── audio_backend.lua
   ├── playback_queue.lua
   ├── ui_player.lua
   └── sleep_timer.lua
   ```
2. Eject USB safely and restart KOReader.
3. In KOReader, go to **Settings (Gear icon)** → **Plugin management** → enable `[X] koreader_tts`.

---

## 3. Server Configuration

1. Open any book (EPUB, MOBI, PDF).
2. Swipe down from top edge to open Top Menu → **Text-to-Speech (TTS)** → **Settings**:
   - **Server URL**: e.g. `http://192.168.1.100:7860` (or your cloud endpoint).
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
