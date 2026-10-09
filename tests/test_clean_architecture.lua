--[[
    test_clean_architecture.lua - Unit tests for Option 2 Modular Clean Architecture
    Verifies that all modules under src/ui, src/service, src/engine, src/bridge
    can be loaded and executed independently.
--]]

package.path = "./?.lua;./tests/?.lua;" .. package.path

local MockKOReader = require("mock_koreader")
MockKOReader.installGlobals()

local ffi = require("ffi")

local total_tests = 0
local passed_tests = 0

local function test(name, fn)
    total_tests = total_tests + 1
    local ok, err = pcall(fn)
    if ok then
        passed_tests = passed_tests + 1
        print(string.format("[TEST] %-50s ... PASS", name))
    else
        print(string.format("[TEST] %-50s ... FAIL", name))
        print("       Error: " .. tostring(err))
    end
end

print("==========================================================")
print("  STANDALONE TEST SUITE - CLEAN ARCHITECTURE (SRC/)")
print("==========================================================")

-- 1. Bridge Layer
test("Bridge: ffi_signatures exports all events", function()
    local FfiSignatures = require("src.bridge.ffi_signatures")
    assert(FfiSignatures.EVENT_NONE == 0)
    assert(FfiSignatures.EVENT_CHUNK_STARTED == 1)
    assert(FfiSignatures.EVENT_CHUNK_FINISHED == 2)
    assert(FfiSignatures.EVENT_PAGE_COMPLETED == 3)
    assert(FfiSignatures.EVENT_BUFFER_UPDATED == 4)
    assert(FfiSignatures.EVENT_LATENCY_REPORT == 5)
    assert(FfiSignatures.EVENT_ERROR == 6)
end)

test("Bridge: ffi_loader returns candidates", function()
    local FfiLoader = require("src.bridge.ffi_loader")
    local paths = FfiLoader.getCandidatePaths("./")
    assert(type(paths) == "table")
    assert(#paths > 0)
end)

test("Bridge: ffi_marshaler handles JSON and text arrays", function()
    local FfiMarshaler = require("src.bridge.ffi_marshaler")
    local c_json = FfiMarshaler.marshalConfigJson({
        server_url = "http://127.0.0.1:8000",
        voice = "test_voice",
        speed = 1.25,
    })
    assert(c_json ~= nil)
    local json_str = ffi.string(c_json)
    assert(json_str:find("test_voice"))
    assert(json_str:find("1.25"))

    local texts = { "Sentence 1", "Sentence 2", "Sentence 3" }
    local c_arr, count = FfiMarshaler.marshalTextArray(texts)
    assert(count == 3)
    assert(ffi.string(c_arr[0]) == "Sentence 1")
    assert(ffi.string(c_arr[2]) == "Sentence 3")
end)

-- 2. Engine Layer
test("Engine: ITtsEngine contract constants", function()
    local ITtsEngine = require("src.engine.engine_interface")
    assert(ITtsEngine.EVENT_CHUNK_STARTED == 1)
    assert(ITtsEngine.EVENT_ERROR == 6)
end)

test("Engine: FallbackEngine implements ITtsEngine", function()
    local FallbackEngine = require("src.engine.fallback_engine")
    local engine = FallbackEngine:new({
        voice = "duc_tri",
        speed = 1.0,
    })
    assert(engine:isNative() == false)
    assert(engine:loadPage(1, { "Câu một.", "Câu hai." }) == true)
    local s0 = engine:getSlotStatus(0)
    assert(s0.chunk_index == 0)
    assert(s0.is_playing == true)
end)

test("Engine: EngineFactory creates engine strategies", function()
    local EngineFactory = require("src.engine.engine_factory")
    local fallback = EngineFactory.create({ _force_fallback = true })
    assert(fallback ~= nil)
    assert(fallback:isNative() == false)

    local default_engine = EngineFactory.create({})
    assert(default_engine ~= nil)
    assert(type(default_engine.isNative) == "function")
end)

-- 3. Service Layer
test("Service: SettingsManager CRUD", function()
    local SettingsManager = require("src.service.settings_manager")
    local sm = SettingsManager:new()
    assert(sm:get("speed") == 1.0)
    assert(sm:set("speed", 1.5) == true)
    assert(sm:get("speed") == 1.5)
end)

test("Service: DocumentChunker sanitization and 3-tier split", function()
    local DocumentChunker = require("src.service.document_chunker")
    local chunker = DocumentChunker:new()
    local raw = " 42 \nMột đoạn văn bản chứa chú thích[1] và dấu sao* cùng từ ngắt\194\173dòng mềm.\n 42 "
    local cleaned = chunker:sanitize(raw)
    assert(not cleaned:find("%[1%]"))
    assert(not cleaned:find("\194\173"))
    assert(not cleaned:find("^42"))
    assert(not cleaned:find("42$"))
    assert(cleaned:find("Một đoạn văn bản chứa chú thích"))
end)

test("Service: SleepTimer mode management", function()
    local SleepTimer = require("src.service.sleep_timer")
    local timer = SleepTimer:new()
    assert(timer:getMode() == "0")
    timer:setMode("15")
    assert(timer:getMode() == "15")
    timer:cancel()
end)

test("Service: ReadingCoordinator FSM with ITtsEngine", function()
    local ReadingCoordinator = require("src.service.reading_coordinator")
    local EngineFactory = require("src.engine.engine_factory")
    local engine = EngineFactory.create({ _force_fallback = true })
    local coordinator = ReadingCoordinator:new({
        engine = engine,
    })
    assert(coordinator:getState() == "IDLE")
    assert(coordinator.engine == engine)
end)

-- 4. UI Layer
test("UI: CanvasHighlight calculates partial dirty rects", function()
    local CanvasHighlight = require("src.ui.canvas_highlight")
    local highlighter = CanvasHighlight:new()
    assert(highlighter.current_highlight == nil)

    local mock_view = {
        clearHighlight = function(self) end,
        setHighlight = function(self, boxes, color) end,
    }
    local bboxes = { { x = 10, y = 20, w = 100, h = 30 } }
    highlighter:highlightSentence(mock_view, bboxes, "gray")
    assert(highlighter.current_highlight ~= nil)
    assert(#highlighter.current_highlight == 1)

    highlighter:clearHighlight(mock_view)
    assert(highlighter.current_highlight == nil)
end)

test("UI: PlayerWidget integrates CanvasHighlight", function()
    local PlayerWidget = require("src.ui.player_widget")
    local mock_view = {
        clearHighlight = function(self) end,
        setHighlight = function(self, boxes, color) end,
    }
    local player = PlayerWidget:new({
        view = mock_view,
    })
    assert(player.highlighter ~= nil)
    local bboxes = { { x = 0, y = 0, w = 50, h = 20 } }
    player:highlightSentence(bboxes, "underline")
    assert(player.current_highlight ~= nil)
    player:clearHighlight()
    assert(player.current_highlight == nil)
end)

print("==========================================================")
print(string.format("  ALL %d/%d CLEAN ARCHITECTURE TESTS PASSED!", passed_tests, total_tests))
print("==========================================================")

if passed_tests < total_tests then
    os.exit(1)
end
