--[[
    tests/test_acceptance.lua - End-to-End Acceptance test suite for KOReader TTS Plugin
    Tests complete integration with KOReader lifecycle, UI menus, and Clean Architecture.
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

local function createTestPlugin(custom_doc)
    local KoreaderTTS = require("main")
    local mock_doc = custom_doc or MockKOReader.createMockMultiPageDocument({
        [1] = "Chào mừng bạn đến với KOReader. Đây là ứng dụng đọc sách tuyệt vời trên E-ink.",
        [2] = "Trang số hai chứa nhiều nội dung phong phú và hấp dẫn hơn nữa.",
        [3] = "Trang số ba tiếp tục câu chuyện đọc sách của chúng ta. Câu thứ hai của trang ba.",
    }, 5, "md5_acceptance_test")
    local mock_ui = MockKOReader.createMockUI(mock_doc)
    local plugin = KoreaderTTS:new{
        ui = mock_ui,
        view = mock_ui.view,
    }
    plugin:init()
    return plugin, mock_ui, mock_doc
end

print("==========================================================")
print("  ACCEPTANCE TEST SUITE: END-TO-END SYSTEM INTEGRATION")
print("==========================================================")

-- 1. Metadata Verification
run_test("Acceptance: _meta.lua valid KOReader plugin metadata", function()
    local meta = dofile("_meta.lua")
    assert(type(meta) == "table")
    assert(meta.name == "koreader_tts")
    assert(meta.category == "read")
    assert(type(meta.fullname) == "string" and meta.fullname ~= "")
    assert(type(meta.description) == "string" and meta.description ~= "")
end)

-- 2. Main Plugin Lifecycle & Menu Integration
run_test("Acceptance: main.lua initialization & WidgetContainer lifecycle", function()
    local plugin = createTestPlugin()

    assert(plugin.settings ~= nil)
    assert(plugin.engine ~= nil)
    assert(plugin.playback_queue ~= nil)
    assert(plugin.ui_player ~= nil)

    -- Register to main menu
    local menu_items = {}
    plugin:addToMainMenu(menu_items)
    assert(menu_items.koreader_tts ~= nil, "Menu item 'koreader_tts' must be registered")
    assert(#menu_items.koreader_tts.sub_item_table >= 3, "Must offer start, timer, and settings sub-items")

    -- Clean shutdown
    plugin:onCloseDocument()
    plugin:onExit()
end)

-- 3. Settings Dialog & Word Mapping CRUD
run_test("Acceptance: Settings dialog & pronunciation word mapping", function()
    local plugin = createTestPlugin()

    plugin:showSettingsDialog()
    assert(plugin.settings_dialog ~= nil, "Settings dialog must open successfully")

    plugin:showWordMappingDialog()
    assert(plugin.word_mapping_dialog ~= nil, "Word mapping dialog must open successfully")

    plugin:onExit()
end)

-- 4. End-to-End Reading Flow
run_test("Acceptance: onStartTTS extracts chunks and triggers playback", function()
    local plugin = createTestPlugin()

    -- Ensure engine has mock capabilities for headless desktop test
    plugin.playback_queue.tts_client = {
        fetchSpeechAsync = function(self, txt, cb)
            cb(true, "mock.wav")
            return function() end
        end,
        hasValidCache = function(self) return true, "mock.wav" end,
    }
    plugin.playback_queue.audio_backend = {
        play = function(self, path, cb)
            -- Hold callback so audio stays in active playback state
            self._cb = cb
        end,
        stop = function(self) self._cb = nil end,
        pause = function(self) end,
        resume = function(self) end,
    }

    local chunks = plugin:onStartTTS()
    assert(#chunks > 0, "Must extract and start reading chunks from active document")
    assert(plugin.playback_queue:getCurrentPage() == 1)

    -- Test suspend during playback
    plugin.playback_queue:_setState("PLAYING")
    plugin:onSuspend()
    assert(plugin.playback_queue:getState() == "PAUSED", "Suspending device must pause active playback")

    plugin:onStopTTS()
    assert(plugin.playback_queue:getState() == "IDLE")

    plugin:onExit()
end)

-- 5. Selection Reading Menu Hook
run_test("Acceptance: Text selection menu hook and independent snippet read", function()
    local plugin = createTestPlugin()

    local highlight_items = {}
    local sample_text = "Đoạn văn bản được người đọc bôi đen trên màn hình cảm ứng E-ink."
    plugin:addToHighlightMenu(highlight_items, sample_text)
    assert(#highlight_items == 1, "Must add 1 TTS button to text selection menu")

    local called_fetch = false
    plugin.engine.synthesizeSingle = function(self, txt, cb)
        called_fetch = true
        cb(true, "mock_selection.wav")
    end

    plugin:onReadSelectedText(sample_text)
    assert(called_fetch == true, "Selecting TTS button must trigger independent audio fetch")

    plugin:onExit()
end)

-- 6. Session Persistence & Resume
run_test("Acceptance: Resume session from persisted book state", function()
    local plugin = createTestPlugin()

    plugin.settings:set("last_book_id", plugin:getCurrentBookId())
    plugin.settings:set("last_page", 3)
    plugin.settings:set("last_chunk_index", 2)

    plugin.playback_queue.engine = {
        isNative = function(self) return false end,
        loadPage = function(self) return true end,
        enqueueNextPage = function(self) return true end,
        seekChunk = function(self) return true end,
        play = function(self) return true end,
        pause = function(self) return true end,
        resume = function(self) return true end,
        stop = function(self) return true end,
        getSlotPath = function(self) return "mock.wav" end,
        getSlotStatus = function(self, idx) return { chunk_index = idx, is_cached = true } end,
        pollEvents = function(self, cb) end,
    }
    plugin.playback_queue.audio_backend = {
        play = function(self, path, cb)
            self._cb = cb
        end,
        stop = function(self) self._cb = nil end,
        pause = function(self) end,
        resume = function(self) end,
    }

    plugin:onResumePreviousSession()
    assert(plugin.playback_queue:getCurrentPage() == 3, "Must resume to persisted page 3")
    assert(plugin.playback_queue:getCurrentIndex() == 2, "Must resume to persisted chunk 2")

    plugin:onExit()
end)

print("==========================================================")
print(string.format("  ALL %d/%d ACCEPTANCE TESTS PASSED!", passed_tests, total_tests))
print("==========================================================")

if passed_tests < total_tests then os.exit(1) end
