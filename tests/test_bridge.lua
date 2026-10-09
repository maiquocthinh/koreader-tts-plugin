--[[
    tests/test_bridge.lua - Unit tests for Bridge layer
    Tests:
      - src.bridge.ffi_signatures
      - src.bridge.ffi_loader
      - src.bridge.ffi_marshaler
      - src.bridge.fallback.tts_client
      - src.bridge.fallback.audio_backend
--]]

package.path = "./?.lua;./tests/?.lua;" .. package.path

local MockKOReader = require("mock_koreader")
MockKOReader.installGlobals()

local ffi = require("ffi")

local total_tests = 0
local passed_tests = 0

local function run_test(name, fn)
    total_tests = total_tests + 1
    local ok, err = pcall(fn)
    if ok then
        passed_tests = passed_tests + 1
        print(string.format("[TEST] %-52s ... PASS", name))
    else
        print(string.format("[TEST] %-52s ... FAIL", name))
        print("       Error: " .. tostring(err))
    end
end

print("==========================================================")
print("  UNIT TEST SUITE: BRIDGE LAYER (src/bridge/)")
print("==========================================================")

local FfiSignatures = require("src.bridge.ffi_signatures")
local FfiLoader = require("src.bridge.ffi_loader")
local FfiMarshaler = require("src.bridge.ffi_marshaler")
local TTSClient = require("src.bridge.fallback.tts_client")
local AudioBackend = require("src.bridge.fallback.audio_backend")

-- 1. FfiSignatures
run_test("FfiSignatures: event types and C-ABI struct cdef", function()
    assert(FfiSignatures.EVENT_NONE == 0)
    assert(FfiSignatures.EVENT_CHUNK_STARTED == 1)
    assert(FfiSignatures.EVENT_CHUNK_FINISHED == 2)
    assert(FfiSignatures.EVENT_PAGE_COMPLETED == 3)
    assert(FfiSignatures.EVENT_BUFFER_UPDATED == 4)
    assert(FfiSignatures.EVENT_LATENCY_REPORT == 5)
    assert(FfiSignatures.EVENT_ERROR == 6)

    local ev = ffi.new("TtsCoreEvent")
    assert(ffi.sizeof(ev) == 288, "TtsCoreEvent size must be 288 bytes")
    local slot = ffi.new("TtsCoreSlotStatus")
    assert(ffi.sizeof(slot) == 24, "TtsCoreSlotStatus size must be 24 bytes")
end)

-- 2. FfiLoader
run_test("FfiLoader: candidate library paths resolution", function()
    local paths = FfiLoader.getCandidatePaths("./")
    assert(type(paths) == "table")
    assert(#paths > 0)
end)

-- 3. FfiMarshaler
run_test("FfiMarshaler: JSON configuration marshaling", function()
    local c_json = FfiMarshaler.marshalConfigJson({
        server_url = "https://api.openai.com/v1/audio/speech",
        voice = "alloy",
        audio_format = "wav",
        speed = 1.2,
        preload_count = 3,
    })
    assert(c_json ~= nil)
    local str = ffi.string(c_json)
    assert(str:find("alloy"))
    assert(str:find("1.2"))
end)

run_test("FfiMarshaler: Text array marshaling to const char*[count]", function()
    local texts = { "Câu một.", "Câu hai.", "Câu ba." }
    local c_arr, count = FfiMarshaler.marshalTextArray(texts)
    assert(count == 3)
    assert(ffi.string(c_arr[0]) == "Câu một.")
    assert(ffi.string(c_arr[1]) == "Câu hai.")
    assert(ffi.string(c_arr[2]) == "Câu ba.")
end)

run_test("FfiMarshaler: Event unpacking", function()
    local ev = ffi.new("TtsCoreEvent")
    ev.event_type = FfiSignatures.EVENT_CHUNK_STARTED
    ev.generation = 42
    ev.chunk_index = 2
    ev.total_chunks = 10
    ev.duration_seconds = 2.5
    ev.latency_ms = 180

    local t = FfiMarshaler.unpackEvent(ev)
    assert(t.event_type == FfiSignatures.EVENT_CHUNK_STARTED)
    assert(t.generation == 42)
    assert(t.chunk_index == 2)
    assert(t.total_chunks == 10)
    assert(math.abs(t.duration_seconds - 2.5) < 0.001)
    assert(t.latency_ms == 180)
    assert(t.error_message == nil)
end)

run_test("FfiMarshaler: Slot status unpacking", function()
    local slot = ffi.new("TtsCoreSlotStatus")
    slot.chunk_index = 1
    slot.is_cached = 1
    slot.is_fetching = 0
    slot.is_playing = 1
    slot.duration_seconds = 1.75

    local s = FfiMarshaler.unpackSlotStatus(slot)
    assert(s.chunk_index == 1)
    assert(s.is_cached == true)
    assert(s.is_fetching == false)
    assert(s.is_playing == true)
    assert(math.abs(s.duration_seconds - 1.75) < 0.001)
end)

-- 4. Fallback TTSClient
run_test("Fallback TTSClient: FNV-1a hash and cache path", function()
    local client = TTSClient:new({
        server_url = "https://api.openai.com/v1/audio/speech",
        voice = "alloy",
        cache_dir = "cache/tts_test",
    })
    local p1 = client:getCacheFilePath("Chào bạn", "duc_tri", "wav")
    local p2 = client:getCacheFilePath("Chào bạn", "duc_tri", "wav")
    local p3 = client:getCacheFilePath("Chào bạn khác", "duc_tri", "wav")
    assert(p1 == p2, "Deterministic cache paths must match")
    assert(p1 ~= p3, "Different texts must have different cache paths")
    assert(p1:match("%.wav$"), "Cache path must have .wav extension")
end)

-- 5. Fallback AudioBackend
run_test("Fallback AudioBackend: speed clamping and playback callback", function()
    local backend = AudioBackend:new({ speed = 1.0 })
    backend:setSpeed(0.2)
    assert(backend.speed == 0.5, "Speed must be clamped to min 0.5")
    backend:setSpeed(3.0)
    assert(backend.speed == 2.0, "Speed must be clamped to max 2.0")

    local called = false
    backend:play("test.wav", function(finished)
        called = true
    end)
    local UIManager = require("ui/uimanager")
    if UIManager.tick then
        UIManager:tick(2.0)
    end
    assert(called == true, "Desktop mock player must execute finished callback")
end)

print("==========================================================")
print(string.format("  ALL %d/%d BRIDGE TESTS PASSED!", passed_tests, total_tests))
print("==========================================================")

if passed_tests < total_tests then os.exit(1) end
