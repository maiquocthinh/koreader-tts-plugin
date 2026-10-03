--[[
    tests/test_phase6_hardening.lua - Standalone unit test suite for Phase 6
    Validates:
      - SleepTimer: countdown, cancel timer, stop at end of page
      - PreventStandby: enable lock when PLAYING, release when PAUSED/STOP
      - Resume Session: persist and restore book_id, page, index accurately
      - Network Resilience: Skip-on-error on server 4xx/5xx responses
      - Cache Cleanup: scan and purge expired cache files
    Run via: luajit tests/test_phase6_hardening.lua
--]]

package.path = "./?.lua;./tests/?.lua;" .. package.path

local MockKOReader = require("mock_koreader")
MockKOReader.installGlobals()

local TextChunker = require("text_chunker")
local TTSClient = require("tts_client")
local AudioBackend = require("audio_backend")
local PlaybackQueue = require("playback_queue")
local SleepTimer = require("sleep_timer")
local KoreaderTTS = require("main")
local Settings = require("settings")

local function run_test(name, func)
    io.write(string.format("[TEST] %-52s ... ", name))
    local ok, err = pcall(func)
    if ok then
        print("PASS")
    else
        print("FAIL")
        error(string.format("Test '%s' failed: %s", name, tostring(err)))
    end
end

print("==========================================================")
print("  STANDALONE TEST SUITE - PHASE 6 (HARDENING & RESILIENCE)")
print("==========================================================")

-- Helper sample wav bytes
local function create_sample_wav_bytes(duration_seconds)
    duration_seconds = duration_seconds or 0.3
    local sample_rate = 24000
    local channels = 1
    local bits = 16
    local byte_rate = sample_rate * channels * (bits / 8)
    local data_size = math.floor(duration_seconds * byte_rate)
    local file_size = 36 + data_size

    local function pack16(v) return string.char(v % 256, math.floor(v / 256) % 256) end
    local function pack32(v)
        return string.char(v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256)
    end

    local header = "RIFF" .. pack32(file_size) .. "WAVEfmt "
        .. pack32(16) .. pack16(1) .. pack16(channels)
        .. pack32(sample_rate) .. pack32(byte_rate)
        .. pack16(2) .. pack16(bits)
        .. "data" .. pack32(data_size)

    return header .. string.rep("\0", math.min(data_size, 256))
end

local sample_wav_data = create_sample_wav_bytes(0.3)

-- Test 1: SleepTimer countdown and timeout trigger
run_test("SleepTimer: Minute countdown and on_timeout trigger", function()
    MockKOReader.UIManager:reset()

    local timeout_reason = nil
    local timer = SleepTimer:new{
        on_timeout = function(reason)
            timeout_reason = reason
        end
    }

    -- Set 1 minute (60 seconds)
    timer:setMode("1")
    assert(timer:getMode() == "1")
    assert(timer:getRemainingSeconds() == 60)

    -- Advance 30 seconds
    for _ = 1, 30 do MockKOReader.UIManager:tick(1) end
    assert(timer:getRemainingSeconds() == 30)
    assert(timeout_reason == nil, "Must not timeout before elapsed")

    -- Advance remaining 30 seconds
    for _ = 1, 30 do MockKOReader.UIManager:tick(1) end
    assert(timer:getRemainingSeconds() == 0)
    assert(timeout_reason == "timer", "After 60 seconds, must trigger on_timeout")
end)

-- Test 2: SleepTimer "page" mode stops on page turn
run_test("SleepTimer: 'page' mode stops on page turn", function()
    local timeout_reason = nil
    local timer = SleepTimer:new{
        on_timeout = function(reason)
            timeout_reason = reason
        end
    }

    timer:setMode("page")
    assert(timer:getMode() == "page")
    assert(timer:getDisplayText():find("Hết trang"))

    timer:onPageTurn(2)
    assert(timeout_reason == "page", "On page turn, must trigger 'page' timeout")
end)

-- Test 3: Standby Lock (Prevent Standby)
run_test("PreventStandby: Enabled when PLAYING, released on PAUSE/STOP", function()
    MockKOReader.UIManager:reset()
    _G.Device:preventStandby(false)
    assert(_G.Device._standby_prevented == false)

    local pages = { [1] = "Câu thử nghiệm chống ngủ máy của e-reader." }
    local doc = MockKOReader.createMockMultiPageDocument(pages)
    local queue = PlaybackQueue:new{
        document = doc,
        chunker = TextChunker:new(),
        tts_client = TTSClient:new{
            cache_dir = "cache/tts_h1",
            _mock_transport = function(t, v, done) done(true, sample_wav_data) end
        },
        audio_backend = AudioBackend:new{ backend_type = "mock" },
    }

    -- Start playback
    queue:start(1, 1)
    MockKOReader.UIManager:tick(0.05)

    assert(queue:getState() == PlaybackQueue.STATE_PLAYING)
    assert(_G.Device._standby_prevented == true, "When PLAYING, preventStandby must be true")

    -- Pause playback
    queue:pause()
    assert(queue:getState() == PlaybackQueue.STATE_PAUSED)
    assert(_G.Device._standby_prevented == false, "When PAUSED, preventStandby must be false")

    -- Stop playback
    queue:stop()
    assert(_G.Device._standby_prevented == false, "When STOP, preventStandby must be false")
end)

-- Test 4: Resume Session tracking and restoration
run_test("Resume Session: Persists and restores book_id, page, index", function()
    MockKOReader.UIManager:reset()
    local test_pages = {
        [1] = "Câu một trang một. Câu hai trang một.",
        [2] = "Câu một trang hai. Câu hai trang hai.",
    }
    local doc = MockKOReader.createMockMultiPageDocument(test_pages, 2, "md5_sample_novel_999")
    local ui = MockKOReader.createMockUI(doc, 1)

    local plugin = KoreaderTTS:new{ ui = ui }
    plugin:init()
    local settings = plugin.settings

    plugin.tts_client._mock_transport = function(t, v, done) done(true, sample_wav_data) end
    plugin.audio_backend.driver_name = "desktop"

    -- Start reading from Page 2 Chunk 1
    plugin.playback_queue.document = doc
    plugin.playback_queue:start(2, 1)
    MockKOReader.UIManager:tick(0.05)

    -- Verify settings recorded session
    assert(settings:get("last_book_id") == "md5_sample_novel_999", "Must save correct book_id by MD5")
    assert(settings:get("last_page") == 2, "Must save page 2")
    assert(settings:get("last_chunk_index") == 1, "Must save chunk 1")

    plugin.playback_queue:stop()

    -- Simulate reopening book and resuming previous session
    local resumed = false
    plugin.playback_queue.start = function(self, p, i)
        resumed = true
        assert(p == 2 and i == 1, "Must resume at Page 2 Chunk 1")
    end

    plugin:onResumePreviousSession()
    assert(resumed == true, "onResumePreviousSession must invoke queue:start")
end)

-- Test 5: Skip-on-error on server 4xx/5xx responses
run_test("Network Resilience: Skip-on-error skips permanent error", function()
    MockKOReader.UIManager:reset()

    local pages = {
        [1] = "Câu một bị lỗi máy chủ 400. Câu hai bình thường tiếp tục phát."
    }
    local doc = MockKOReader.createMockMultiPageDocument(pages)
    local chunker = TextChunker:new()

    local error_logged = false
    local tts_client = TTSClient:new{
        cache_dir = "cache/tts_h2",
        _mock_transport = function(text, voice, done)
            if text:find("lỗi") then
                done(false, "Máy chủ TTS phản hồi lỗi HTTP 400: Bad Request")
            else
                done(true, sample_wav_data)
            end
        end
    }
    local audio_backend = AudioBackend:new{ backend_type = "mock" }

    local chunks_played = {}
    local queue = PlaybackQueue:new{
        document = doc,
        chunker = chunker,
        tts_client = tts_client,
        audio_backend = audio_backend,
        on_error = function(err)
            error_logged = true
        end,
        on_chunk_change = function(chunk, page, index)
            table.insert(chunks_played, index)
        end
    }

    queue:start(1, 1)
    MockKOReader.UIManager:runAllScheduled(10)

    -- Chunk 1 failed with 400: must trigger skip-on-error and advance to chunk 2
    assert(error_logged == true, "Must notify skip-on-error")
    assert(#chunks_played >= 1 and chunks_played[#chunks_played] == 2, "Must automatically advance to Chunk 2")
    assert(queue:getCurrentIndex() == 2, "Queue position must be chunk 2")

    queue:stop()
end)

-- Test 6: Cache Cleanup via clearCache()
run_test("Cache Cleanup: clearCache purges expired files", function()
    local client = TTSClient:new{ cache_dir = "cache/tts_cleanup_test" }
    local old_file = client.cache_dir .. "/chunk_old_test.wav"
    local f = io.open(old_file, "wb")
    f:write(sample_wav_data)
    f:close()

    local check_f = io.open(old_file, "rb")
    assert(check_f ~= nil, "Test file must exist before cleanup")
    check_f:close()

    -- Trigger cleanup with max_age = -1 (forces all files to be treated as expired)
    client:clearCache(-1)

    local f_after = io.open(old_file, "rb")
    assert(f_after == nil, "Expired file must be removed after clearCache")
end)

print("==========================================================")
print("  ALL 6 TESTS PASSED SUCCESSFULLY!                       ")
print("==========================================================")
