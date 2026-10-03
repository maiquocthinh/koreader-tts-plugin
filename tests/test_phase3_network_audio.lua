--[[
    tests/test_phase3_network_audio.lua - Standalone unit test suite for Phase 3
    Validates:
      - UTF-8 JSON serialization
      - WAV header structure parsing & duration calculation
      - Non-blocking HTTP Client & atomic disk caching
      - Multi-platform Audio Backend lifecycle & token cancellation
    Run via: luajit tests/test_phase3_network_audio.lua
--]]

package.path = "./?.lua;./tests/?.lua;" .. package.path

local MockKOReader = require("mock_koreader")
MockKOReader.installGlobals()

local TTSClient = require("tts_client")
local AudioBackend = require("audio_backend")

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

--- Helper function to generate valid binary WAV header bytes
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
        .. pack32(16) -- fmt chunk size
        .. pack16(1)  -- PCM format
        .. pack16(channels)
        .. pack32(sample_rate)
        .. pack32(byte_rate)
        .. pack16(channels * (bits_per_sample / 8))
        .. pack16(bits_per_sample)
        .. "data"
        .. pack32(data_size)

    local data = string.rep("\0", math.min(data_size, 1024))
    return header .. data
end

print("==========================================================")
print("  STANDALONE TEST SUITE - PHASE 3 (NETWORK & AUDIO)")
print("==========================================================")

-- Test 1: JSON Serializer
run_test("JSON encoding: UTF-8 characters and escapes", function()
    local encode = TTSClient._json_encode
    assert(encode("Xin chào") == '"Xin chào"')
    assert(encode("Câu có dấu \"ngoặc kép\" và \n xuống dòng") == '"Câu có dấu \\"ngoặc kép\\" và \\n xuống dòng"')

    local tbl = { input = "Thử nghiệm", voice = "vi-VN-NamMinh", speed = 1.0 }
    local json = encode(tbl)
    assert(json:find('"input":"Thử nghiệm"', 1, true))
    assert(json:find('"voice":"vi-VN-NamMinh"', 1, true))
    assert(json:find('"speed":1', 1, true))
end)

-- Test 2: URL Parser
run_test("URL parser: http/https, custom port/path", function()
    local parse = TTSClient._parse_url

    local u1 = parse("http://192.168.1.100:7860")
    assert(u1.scheme == "http")
    assert(u1.host == "192.168.1.100")
    assert(u1.port == 7860)
    assert(u1.path == "/v1/audio/speech")

    local u2 = parse("https://api.example.com/v1/custom")
    assert(u2.scheme == "https")
    assert(u2.host == "api.example.com")
    assert(u2.port == 443)
    assert(u2.path == "/v1/custom")
end)

-- Test 3: FNV-1a Hash & Cache path
run_test("FNV-1a hash & deterministic cache paths", function()
    local client = TTSClient:new{ cache_dir = "cache/tts_test" }
    local p1 = client:getCacheFilePath("Hôm nay trời đẹp.", "vi-VN-NamMinh")
    local p2 = client:getCacheFilePath("Hôm nay trời đẹp.", "vi-VN-NamMinh")
    local p3 = client:getCacheFilePath("Hôm nay trời mưa.", "vi-VN-NamMinh")
    local p4 = client:getCacheFilePath("Hôm nay trời đẹp.", "vi-VN-NuMaiPhuong")

    assert(p1 == p2, "Same text and voice must yield same cache path")
    assert(p1 ~= p3, "Different text must yield different cache path")
    assert(p1 ~= p4, "Different voice must yield different cache path")
    assert(p1:match("%.wav$"), "Cache path must have .wav extension")
end)

-- Test 4: WAV Header Parsing & Duration calculation
run_test("WAV header parser & accurate duration calculation", function()
    local wav_data = create_sample_wav_bytes(1.5, 24000)
    local test_path = "cache/tts_test_sample.wav"

    local f = io.open(test_path, "wb")
    assert(f, "Cannot open test_sample.wav for writing")
    f:write(wav_data)
    f:close()

    local duration, byte_rate, sample_rate = AudioBackend.getWavDuration(test_path)
    os.remove(test_path)

    assert(sample_rate == 24000, "Sample rate must be 24000")
    assert(byte_rate == 48000, "Byte rate must be 48000")
    assert(math.abs(duration - 1.5) < 0.05, "Calculated duration must approximate 1.5 seconds")
end)

-- Test 5: Asynchronous download via TTSClient (Mock Transport)
run_test("fetchSpeechAsync succeeds & saves cache atomically", function()
    MockKOReader.UIManager:reset()

    local sample_wav = create_sample_wav_bytes(1.0, 24000)
    local client = TTSClient:new{
        cache_dir = "cache/tts_unit",
        _mock_transport = function(text, voice, done)
            done(true, sample_wav)
        end
    }

    local test_text = "Thử nghiệm tải audio non-blocking."
    local received_success = nil
    local received_result = nil

    client:fetchSpeechAsync(test_text, function(success, result)
        received_success = success
        received_result = result
    end)

    MockKOReader.UIManager:runAllScheduled()

    assert(received_success == true, "fetchSpeechAsync must succeed")
    assert(type(received_result) == "string", "Result must be a file path string")
    assert(client:hasValidCache(test_text, client.voice) == true, "Cache file must be valid")

    os.remove(received_result)
end)

-- Test 6: Cache Hit verification
run_test("Cache hit detection returns cached file immediately", function()
    local sample_wav = create_sample_wav_bytes(0.8, 24000)
    local client = TTSClient:new{
        cache_dir = "cache/tts_unit",
    }
    local text = "Câu này đã được cache sẵn."
    local cache_file = client:getCacheFilePath(text, client.voice)

    local f = io.open(cache_file, "wb")
    f:write(sample_wav)
    f:close()

    local called_transport = false
    client._mock_transport = function()
        called_transport = true
    end

    local returned_path = nil
    client:fetchSpeechAsync(text, function(ok, path)
        returned_path = path
    end)

    assert(called_transport == false, "Transport must not be invoked on cache hit")
    assert(returned_path == cache_file, "Must return existing cache file path")

    os.remove(cache_file)
end)

-- Test 7: Network error handling & temporary file cleanup
run_test("Safe network error handling & .tmp cleanup", function()
    MockKOReader.UIManager:reset()

    local client = TTSClient:new{
        cache_dir = "cache/tts_unit",
        _mock_transport = function(text, voice, done)
            done(false, "Lỗi kết nối máy chủ 503 Service Unavailable")
        end
    }

    local text = "Câu bị lỗi mạng."
    local err_received = nil
    local ok_received = nil

    client:fetchSpeechAsync(text, function(ok, res)
        ok_received = ok
        err_received = res
    end)

    MockKOReader.UIManager:runAllScheduled()

    assert(ok_received == false, "Must return failure status")
    assert(err_received:find("503"), "Error message must contain server response")

    local tmp_file = client:getCacheFilePath(text, client.voice) .. ".tmp"
    local f = io.open(tmp_file, "r")
    assert(f == nil, "Temporary .tmp file must be removed on error")
end)

-- Test 8: AudioBackend Playback Lifecycle & Callback
run_test("AudioBackend:play triggers and executes callback", function()
    MockKOReader.UIManager:reset()

    local sample_wav = create_sample_wav_bytes(0.5, 24000)
    local test_path = "cache/tts_play_test.wav"
    local f = io.open(test_path, "wb")
    f:write(sample_wav)
    f:close()

    local backend = AudioBackend:new{ backend_type = "mock", speed = 1.0 }
    assert(backend:isPlaying() == false, "Initial state must not be playing")

    local finished_called = false
    backend:play(test_path, function(success)
        finished_called = success
    end)

    assert(backend:isPlaying() == true, "After play(), isPlaying must be true")

    MockKOReader.UIManager:tick(0.6)

    assert(finished_called == true, "on_finished callback must be triggered")
    assert(backend:isPlaying() == false, "After finish, isPlaying must be false")

    os.remove(test_path)
end)

-- Test 9: AudioBackend Token Cancellation
run_test("AudioBackend:stop invalidates token & cancels callback", function()
    MockKOReader.UIManager:reset()

    local sample_wav = create_sample_wav_bytes(1.0, 24000)
    local test_path = "cache/tts_stop_test.wav"
    local f = io.open(test_path, "wb")
    f:write(sample_wav)
    f:close()

    local backend = AudioBackend:new{ backend_type = "mock" }
    local old_callback_fired = false

    backend:play(test_path, function()
        old_callback_fired = true
    end)

    assert(backend:isPlaying() == true)

    backend:stop()
    assert(backend:isPlaying() == false, "stop() must immediately reset isPlaying")

    MockKOReader.UIManager:tick(1.5)

    assert(old_callback_fired == false, "Cancelled session callback must not fire")

    os.remove(test_path)
end)

-- Test 10: Playback speed clamping
run_test("AudioBackend:setSpeed clamps [0.5, 2.0]", function()
    local backend = AudioBackend:new{ speed = 1.0 }
    backend:setSpeed(0.1)
    assert(backend.speed == 0.5, "speed < 0.5 must clamp to 0.5")
    backend:setSpeed(5.0)
    assert(backend.speed == 2.0, "speed > 2.0 must clamp to 2.0")
    backend:setSpeed(1.5)
    assert(backend.speed == 1.5)
end)

-- Test 11: Platform Driver Detection
run_test("AudioBackend detects platform driver by Device", function()
    _G.Device:setPlatform("android")
    local b1 = AudioBackend:new()
    assert(b1.driver_name == "android", "Must select android driver")

    _G.Device:setPlatform("kobo")
    local b2 = AudioBackend:new()
    assert(b2.driver_name == "linux", "Must select linux driver on Kobo")

    _G.Device:setPlatform("desktop")
    local b3 = AudioBackend:new()
    assert(b3.driver_name == "desktop", "Must select desktop driver")
end)

print("==========================================================")
print("  ALL 11 TESTS PASSED SUCCESSFULLY!                      ")
print("==========================================================")
