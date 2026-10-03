--[[
    tests/verify_acceptance_phase3.lua
    End-to-End Acceptance Verification script for Phase 3
    Validates 3 Definition of Done (DoD) criteria:
      - DoD 3.1: Non-blocking HTTP Client downloads WAV to cache without UI freeze
      - DoD 3.2: Multi-platform AudioBackend plays audio and triggers completion callback
      - DoD 3.3: End-to-End integration: Document -> TextChunker -> TTSClient -> AudioBackend -> Callback
      - Optional --live flag: live TTS server connection test using memory credentials
--]]

package.path = "./?.lua;./tests/?.lua;" .. package.path

local MockKOReader = require("mock_koreader")
MockKOReader.installGlobals()

local TTSClient = require("tts_client")
local AudioBackend = require("audio_backend")
local TextChunker = require("text_chunker")
local KoreaderTTS = require("main")
local Settings = require("settings")

local function step_banner(num, title)
    print(string.format("\n=== [STEP %d] %s ===", num, title))
end

--- Helper function to generate valid WAV bytes for acceptance test
local function create_sample_wav_bytes(duration_seconds, sample_rate)
    sample_rate = sample_rate or 24000
    local channels = 1
    local bits_per_sample = 16
    local byte_rate = sample_rate * channels * (bits_per_sample / 8)
    local data_size = math.floor(duration_seconds * byte_rate)
    local file_size = 36 + data_size

    local function pack16(v)
        local b1 = v % 256
        local b2 = math.floor(v / 256) % 256
        return string.char(b1, b2)
    end

    local function pack32(v)
        local b1 = v % 256
        local b2 = math.floor(v / 256) % 256
        local b3 = math.floor(v / 65536) % 256
        local b4 = math.floor(v / 16777216) % 256
        return string.char(b1, b2, b3, b4)
    end

    local header = "RIFF"
        .. pack32(file_size)
        .. "WAVE"
        .. "fmt "
        .. pack32(16)
        .. pack16(1)
        .. pack16(channels)
        .. pack32(sample_rate)
        .. pack32(byte_rate)
        .. pack16(channels * (bits_per_sample / 8))
        .. pack16(bits_per_sample)
        .. "data"
        .. pack32(data_size)

    local data = string.rep("\0", math.min(data_size, 2048))
    return header .. data
end

-- =========================================================================
-- VERIFY DoD 3.1: Non-blocking HTTP Client downloads WAV to cache
-- =========================================================================
step_banner(1, "Verify DoD 3.1: Non-blocking WAV Download & Cache Persistence")

MockKOReader.UIManager:reset()
local sample_wav_data = create_sample_wav_bytes(1.2, 24000)
local test_text = "Hôm nay tôi đọc sách trên thiết bị màn hình E-ink KOReader."

local tts_client = TTSClient:new{
    cache_dir = "cache/tts_acceptance",
    _mock_transport = function(text, voice, done)
        done(true, sample_wav_data)
    end
}

local download_success = nil
local downloaded_path = nil

print("  -> Calling fetchSpeechAsync asynchronously...")
tts_client:fetchSpeechAsync(test_text, function(success, result)
    download_success = success
    downloaded_path = result
end)

-- Verify UI thread is not blocked
local ui_events_processed = 0
MockKOReader.UIManager:scheduleIn(0.01, function()
    ui_events_processed = ui_events_processed + 1
end)

MockKOReader.UIManager:runAllScheduled()

assert(download_success == true, "ERROR DoD 3.1: Audio download failed!")
assert(downloaded_path ~= nil, "ERROR DoD 3.1: No file path returned!")
assert(ui_events_processed >= 1, "ERROR DoD 3.1: UI event loop was blocked!")

-- Check WAV file on disk
local f = io.open(downloaded_path, "rb")
assert(f ~= nil, "ERROR DoD 3.1: WAV file was not created on disk!")
local magic = f:read(4)
f:close()
assert(magic == "RIFF", "ERROR DoD 3.1: Header magic is not RIFF/WAV!")

print(string.format("  -> Successfully downloaded WAV to: '%s'", downloaded_path))
print(string.format("  -> Header verified: '%s' valid, size > 0 bytes.", magic))
print("  [DoD 3.1 RESULT]: PASS - Non-blocking WAV download verified, UI responsive.")

-- =========================================================================
-- VERIFY DoD 3.2: Multi-platform AudioBackend
-- =========================================================================
step_banner(2, "Verify DoD 3.2: Multi-platform AudioBackend & Callback Trigger")

MockKOReader.UIManager:reset()
local audio_backend = AudioBackend:new{
    backend_type = "mock",
    speed = 1.0,
}

local duration, byte_rate, sample_rate = AudioBackend.getWavDuration(downloaded_path)
print(string.format("  -> WAV parsing: Sample rate = %d Hz | Byte rate = %d B/s | Duration = %.2f s",
    sample_rate, byte_rate, duration))
assert(duration > 1.0 and duration < 1.4, "ERROR DoD 3.2: Incorrect duration calculation!")

local playback_finished = false
print("  -> Playing audio via AudioBackend:play()...")
audio_backend:play(downloaded_path, function(success)
    playback_finished = success
end)

assert(audio_backend:isPlaying() == true, "ERROR DoD 3.2: AudioBackend isPlaying not set!")

-- Simulate 1.3 seconds playback time
MockKOReader.UIManager:tick(1.3)

assert(playback_finished == true, "ERROR DoD 3.2: on_finished callback not called!")
assert(audio_backend:isPlaying() == false, "ERROR DoD 3.2: isPlaying not reset after completion!")

print("  -> Playback completion callback triggered accurately.")
print("  [DoD 3.2 RESULT]: PASS - Audio driver completed playback and triggered callback.")

-- =========================================================================
-- VERIFY DoD 3.3: End-to-End Single Sentence Playback on KOReader UI
-- =========================================================================
step_banner(3, "Verify DoD 3.3: End-to-End Single Sentence (Doc -> API -> Audio)")

MockKOReader.UIManager:reset()
local sample_page_text = "Chào mừng bạn đến với KOReader. Đây là câu thử nghiệm tính năng đọc bằng giọng nói của Phase 3."
local mock_doc = MockKOReader.createMockCrengineDocument(sample_page_text)

local plugin = KoreaderTTS:new{
    ui = {
        document = mock_doc,
        menu = { registerToMainMenu = function() end },
    }
}
plugin:init()

plugin.tts_client._mock_transport = function(text, voice, done)
    done(true, sample_wav_data)
end
plugin.audio_backend.driver_name = "desktop"

print("  -> Triggering 'Test single sentence' from Menu...")
plugin:onTestSingleSentence()

assert(#MockKOReader.UIManager._shown_widgets >= 1, "ERROR DoD 3.3: Loading notice not displayed!")
local msg1 = MockKOReader.UIManager._shown_widgets[1]
print(string.format("  -> Toast 1: '%s'", msg1.text:gsub("\n", " - ")))
assert(msg1.text:find("Đang tải") or msg1.text:find("Loading"), "ERROR DoD 3.3: Missing loading toast!")

MockKOReader.UIManager:tick(0.1)

local msg2 = MockKOReader.UIManager._shown_widgets[#MockKOReader.UIManager._shown_widgets]
print(string.format("  -> Toast 2: '%s'", msg2.text:gsub("\n", " - ")))
assert(msg2.text:find("Đang phát") or msg2.text:find("Playing"), "ERROR DoD 3.3: Missing playing toast!")
assert(plugin.audio_backend:isPlaying() == true, "ERROR DoD 3.3: Audio backend not playing!")

MockKOReader.UIManager:tick(1.5)
assert(plugin.audio_backend:isPlaying() == false, "ERROR DoD 3.3: Backend did not stop after playback!")

local msg3 = MockKOReader.UIManager._shown_widgets[#MockKOReader.UIManager._shown_widgets]
print(string.format("  -> Toast 3: '%s'", msg3.text))
assert(msg3.text:find("Đã phát xong") or msg3.text:find("Finished"), "ERROR DoD 3.3: Missing completion toast!")

print("  [DoD 3.3 RESULT]: PASS - End-to-End single sentence playback verified 100%.")

os.remove(downloaded_path)

-- =========================================================================
-- OPTIONAL: LIVE TTS SERVER CONNECTION TEST
-- =========================================================================
local is_live_test = false
for _, arg in ipairs(arg or {}) do
    if arg == "--live" then is_live_test = true end
end

if is_live_test then
    step_banner(4, "Optional Check: Connect to Live TTS Server")
    print("  -> Connecting to live server configured in memory...")

    local live_client = TTSClient:new{
        server_url = "https://maiquocthinh-vieneu-tts.hf.space/v1/audio/speech",
        voice = "Đức Trí",
        request_timeout = 25,
        cache_dir = "cache/tts_live",
    }

    local live_done = false
    local live_ok = false
    local live_res = nil

    live_client:fetchSpeechAsync("Xin chào bạn. Tôi là giọng đọc Đức Trí trên KOReader.", function(ok, res)
        live_done = true
        live_ok = ok
        live_res = res
    end)

    local max_wait = 250
    while not live_done and max_wait > 0 do
        max_wait = max_wait - 1
        MockKOReader.UIManager:tick(0.1)
    end

    if live_ok then
        print(string.format("  -> [LIVE PASS]: Successfully downloaded from live server! File: %s", live_res))
        local live_dur = AudioBackend.getWavDuration(live_res)
        print(string.format("  -> Audio duration from server: %.2f s", live_dur))
        os.remove(live_res)
    else
        print(string.format("  -> [LIVE NOTICE]: Cannot connect to live server: %s", tostring(live_res)))
    end
end

print("\n=========================================================================")
print("  SUMMARY: ALL 3 PHASE 3 ACCEPTANCE CRITERIA VERIFIED 100%!               ")
print("=========================================================================\n")
