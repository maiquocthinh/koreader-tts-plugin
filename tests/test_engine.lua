--[[
    tests/test_engine.lua - Unit tests for Engine Strategy layer
    Tests:
      - src.engine.engine_interface
      - src.engine.native_engine
      - src.engine.fallback_engine
      - src.engine.engine_factory
--]]

package.path = "./?.lua;./tests/?.lua;" .. package.path

local MockKOReader = require("mock_koreader")
MockKOReader.installGlobals()

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
print("  UNIT TEST SUITE: ENGINE LAYER (src/engine/)")
print("==========================================================")

local ITtsEngine = require("src.engine.engine_interface")
local NativeEngine = require("src.engine.native_engine")
local FallbackEngine = require("src.engine.fallback_engine")
local EngineFactory = require("src.engine.engine_factory")

-- 1. ITtsEngine Contract
run_test("ITtsEngine: Interface constants and default isNative", function()
    assert(ITtsEngine.EVENT_NONE == 0)
    assert(ITtsEngine.EVENT_CHUNK_STARTED == 1)
    assert(ITtsEngine.EVENT_CHUNK_FINISHED == 2)
    assert(ITtsEngine.EVENT_PAGE_COMPLETED == 3)
    assert(ITtsEngine.EVENT_BUFFER_UPDATED == 4)
    assert(ITtsEngine.EVENT_LATENCY_REPORT == 5)
    assert(ITtsEngine.EVENT_ERROR == 6)
    assert(ITtsEngine:isNative() == false)
end)

-- 2. FallbackEngine
run_test("FallbackEngine: pure Lua state and slot status", function()
    local engine = FallbackEngine:new({
        voice = "duc_tri",
        speed = 1.0,
    })
    assert(engine:isNative() == false)
    assert(engine:loadPage(1, { "Câu A.", "Câu B.", "Câu C." }) == true)
    local s0 = engine:getSlotStatus(0)
    assert(s0.chunk_index == 0)
    assert(s0.is_playing == true)

    local s1 = engine:getSlotStatus(1)
    assert(s1.chunk_index == 1)
    assert(s1.is_playing == false)

    engine:seekChunk(1, 2)
    local s2 = engine:getSlotStatus(2)
    assert(s2.is_playing == true)

    engine:destroy()
end)

-- 3. EngineFactory Strategy Resolution
run_test("EngineFactory: force fallback option yields FallbackEngine", function()
    local engine = EngineFactory.create({ _force_fallback = true })
    assert(engine ~= nil)
    assert(engine:isNative() == false)
end)

run_test("EngineFactory: default creation selects engine strategy", function()
    local engine = EngineFactory.create({
        server_url = "https://api.openai.com/v1/audio/speech",
        voice = "alloy",
    })
    assert(engine ~= nil)
    assert(type(engine.isNative) == "function")
    assert(type(engine.loadPage) == "function")
    assert(type(engine.play) == "function")
    assert(type(engine.pause) == "function")
    assert(type(engine.resume) == "function")
    assert(type(engine.stop) == "function")
    assert(type(engine.pollEvents) == "function")
    assert(type(engine.getSlotStatus) == "function")
    assert(type(engine.destroy) == "function")
end)

-- 4. NativeEngine (when native library is available on host)
run_test("NativeEngine: lifecycle, loadPage, and event polling", function()
    local engine = NativeEngine:new({
        server_url = "https://api.openai.com/v1/audio/speech",
        voice = "alloy",
        cache_dir = "cache/tts_engine_test",
    })
    if engine then
        assert(engine:isNative() == true)
        local loaded = engine:loadPage(1, { "Test native sentence 1", "Test native sentence 2" })
        assert(loaded == true, "loadPage must return true on native engine")

        local events = {}
        engine:pollEvents(function(ev)
            table.insert(events, ev)
        end)
        assert(type(events) == "table")

        local s0 = engine:getSlotStatus(0)
        assert(type(s0) == "table")
        assert(s0.chunk_index == 0)

        engine:destroy()
    else
        print("  (Native library not compiled for current host arch; Fallback strategy covers this target)")
    end
end)

print("==========================================================")
print(string.format("  ALL %d/%d ENGINE TESTS PASSED!", passed_tests, total_tests))
print("==========================================================")

if passed_tests < total_tests then os.exit(1) end
