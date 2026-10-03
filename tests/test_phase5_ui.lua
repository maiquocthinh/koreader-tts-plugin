--[[
    tests/test_phase5_ui.lua - Standalone unit test suite for Phase 5
    Validates:
      - Sentence Highlighting with partial E-ink refresh
      - Bottom-anchored Floating Control Bar
      - Mini Floating Bubble mode
      - Text Selection Hook & standalone selection playback
    Run via: luajit tests/test_phase5_ui.lua
--]]

package.path = "./?.lua;./tests/?.lua;" .. package.path

local MockKOReader = require("mock_koreader")
MockKOReader.installGlobals()

local TextChunker = require("text_chunker")
local TTSClient = require("tts_client")
local AudioBackend = require("audio_backend")
local PlaybackQueue = require("playback_queue")
local UIPlayer = require("ui_player")
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
print("  STANDALONE TEST SUITE - PHASE 5 (NATIVE UI & HIGHLIGHT)")
print("==========================================================")

-- Helper mock bboxes
local sample_bboxes = {
    { x = 50, y = 100, w = 400, h = 24 },
    { x = 50, y = 128, w = 250, h = 24 },
}

-- Test 1: Sentence highlighting in gray mode
run_test("Highlight: Gray mode sets COLOR_GRAY_E & partial dirty", function()
    MockKOReader.UIManager:reset()
    local doc = MockKOReader.createMockCrengineDocument()
    local ui = MockKOReader.createMockUI(doc, 1)

    local player = UIPlayer:new{
        ui = ui,
        view = ui.view,
    }

    player:highlightSentence(sample_bboxes, "gray")

    assert(ui.view._highlight ~= nil, "view._highlight must be set")
    assert(ui.view._highlight_color == _G.Blitbuffer.COLOR_GRAY_E, "Highlight color must be COLOR_GRAY_E")
    assert(#ui.view._highlight == 2, "Must have 2 bounding boxes")

    -- Check partial refresh
    assert(#MockKOReader.UIManager._dirty_calls >= 1, "Must call UIManager:setDirty")
    local last_dirty = MockKOReader.UIManager._dirty_calls[#MockKOReader.UIManager._dirty_calls]
    assert(last_dirty.refresh_type == "partial", "Refresh type must be partial (prevents E-ink flashing)")
end)

-- Test 2: Sentence highlighting in underline mode
run_test("Highlight: Underline mode creates 2px bottom strip", function()
    MockKOReader.UIManager:reset()
    local doc = MockKOReader.createMockCrengineDocument()
    local ui = MockKOReader.createMockUI(doc, 1)

    local player = UIPlayer:new{
        ui = ui,
        view = ui.view,
    }

    player:highlightSentence(sample_bboxes, "underline")

    assert(ui.view._highlight ~= nil)
    assert(ui.view._highlight_color == _G.Blitbuffer.COLOR_BLACK, "Underline must use COLOR_BLACK")
    assert(ui.view._highlight[1].h == 2, "Underline height must be 2px")
    assert(ui.view._highlight[1].y == 100 + 24 - 2, "Underline y must be at bottom of line")
end)

-- Test 3: Highlight mode "none"
run_test("Highlight: None mode renders no highlight", function()
    MockKOReader.UIManager:reset()
    local doc = MockKOReader.createMockCrengineDocument()
    local ui = MockKOReader.createMockUI(doc, 1)

    local player = UIPlayer:new{
        ui = ui,
        view = ui.view,
    }

    player:highlightSentence(sample_bboxes, "none")
    assert(ui.view._highlight == nil, "None mode must not set highlight")
end)

-- Test 4: Clear highlight on sentence change
run_test("Highlight: clearHighlight cleans highlight & dirties rect", function()
    MockKOReader.UIManager:reset()
    local doc = MockKOReader.createMockCrengineDocument()
    local ui = MockKOReader.createMockUI(doc, 1)

    local player = UIPlayer:new{
        ui = ui,
        view = ui.view,
    }

    player:highlightSentence(sample_bboxes, "gray")
    assert(player.current_highlight ~= nil)

    MockKOReader.UIManager:reset()
    player:clearHighlight()

    assert(ui.view._highlight == nil, "View highlight must be cleared")
    assert(player.current_highlight == nil, "current_highlight must be nil")
    assert(#MockKOReader.UIManager._dirty_calls == 1, "Must trigger partial dirty rect to clean area")
end)

-- Test 5: Floating Control Bar widget tree
run_test("Control Bar: Constructs Header, Controls, Footer rows", function()
    MockKOReader.UIManager:reset()
    local doc = MockKOReader.createMockCrengineDocument()
    local ui = MockKOReader.createMockUI(doc, 1)

    local player = UIPlayer:new{
        ui = ui,
        view = ui.view,
    }

    player:showControlBar()

    assert(player.control_bar ~= nil, "control_bar must be created")
    assert(#MockKOReader.UIManager._shown_widgets == 1, "UIManager must show control_bar")
    assert(player.title_widget ~= nil, "Must have title_widget for progress")
    assert(player.play_pause_btn ~= nil, "Must have play_pause_btn")
    assert(player.speed_btn ~= nil, "Must have speed_btn")
    assert(player.buffer_status_widget ~= nil, "Must have buffer_status_widget")

    player:hideControlBar()
    assert(player.control_bar == nil, "hideControlBar must release widget")
end)

-- Test 6: Control Bar navigation buttons
run_test("Control Bar: Play/Pause, Next, Prev, Pages call queue", function()
    MockKOReader.UIManager:reset()
    local pages = {
        [1] = "Câu số một của bài test giao diện. Câu số hai của bài test giao diện.",
        [2] = "Câu số một của trang kế tiếp này."
    }
    local doc = MockKOReader.createMockMultiPageDocument(pages, 2)
    local ui = MockKOReader.createMockUI(doc, 1)

    local queue_calls = {}
    local mock_queue = {
        getState = function() return "PLAYING" end,
        togglePlayPause = function() table.insert(queue_calls, "toggle") end,
        nextChunk = function() table.insert(queue_calls, "next") end,
        prevChunk = function() table.insert(queue_calls, "prev") end,
        seekChunk = function(self, p, i) table.insert(queue_calls, string.format("seek_%d_%d", p, i)) end,
        stop = function() table.insert(queue_calls, "stop") end,
        getSlot = function() return nil end,
    }

    local player = UIPlayer:new{
        ui = ui,
        view = ui.view,
        playback_queue = mock_queue,
    }

    player:showControlBar()

    player:onTogglePlayPause()
    assert(queue_calls[#queue_calls] == "toggle")

    player:onNextChunk()
    assert(queue_calls[#queue_calls] == "next")

    player:onPrevChunk()
    assert(queue_calls[#queue_calls] == "prev")

    player:onNextPage()
    assert(queue_calls[#queue_calls] == "seek_2_1")

    player:onClose()
    assert(queue_calls[#queue_calls] == "stop")
    assert(player.visible == false)
end)

-- Test 7: Speed button cycling
run_test("Speed: Cycles 0.8x -> 1.0x -> 1.2x -> 1.5x -> 2.0x", function()
    local storage = MockKOReader.createMockSettings()
    local settings = Settings:new(storage)
    local audio_backend = AudioBackend:new{ speed = 1.0 }

    local player = UIPlayer:new{
        settings = settings,
        audio_backend = audio_backend,
    }
    player:showControlBar()

    -- 1.0x -> cycle to 1.2x
    player:onCycleSpeed()
    assert(math.abs(audio_backend.speed - 1.2) < 0.01, "audio_backend speed must be 1.2x")
    assert(math.abs(settings:get("speed") - 1.2) < 0.01, "Settings must save 1.2x")

    -- 1.2x -> 1.5x
    player:onCycleSpeed()
    assert(math.abs(audio_backend.speed - 1.5) < 0.01)

    -- 1.5x -> 2.0x
    player:onCycleSpeed()
    assert(math.abs(audio_backend.speed - 2.0) < 0.01)

    -- 2.0x -> wrap back to 0.8x
    player:onCycleSpeed()
    assert(math.abs(audio_backend.speed - 0.8) < 0.01)

    player:hide()
end)

-- Test 8: Buffer status indicator (●●, ●○, ○○)
run_test("Buffer Status: Indicator displays correctly by slots", function()
    local mock_queue = {
        getState = function() return "PLAYING" end,
        getSlot = function(self, offset)
            if offset == 1 then return { status = "READY" } end
            if offset == 2 then return { status = "READY" } end
            return nil
        end
    }

    local player = UIPlayer:new{
        playback_queue = mock_queue,
    }
    player:showControlBar()

    assert(player.buffer_status_widget.text:find("●●"), "Both slots READY must show ●●")

    -- Only slot 1 READY
    mock_queue.getSlot = function(self, offset)
        if offset == 1 then return { status = "READY" } end
        return { status = "FETCHING" }
    end
    player:_updateBufferStatus()
    assert(player.buffer_status_widget.text:find("●○"), "1 slot READY must show ●○")

    -- No slots READY
    mock_queue.getSlot = function(self, offset)
        return { status = "FETCHING" }
    end
    player:_updateBufferStatus()
    assert(player.buffer_status_widget.text:find("○○"), "Loading must show ○○")

    player:hide()
end)

-- Test 9: Mini Floating Bubble toggle
run_test("Mini Bubble: Toggles between Control Bar and Bubble", function()
    MockKOReader.UIManager:reset()
    local player = UIPlayer:new()

    -- Open control bar
    player:show()
    assert(player.is_mini == false)
    assert(player.control_bar ~= nil)
    assert(player.mini_bubble == nil)

    -- Minimize
    player:toggleMode()
    assert(player.is_mini == true)
    assert(player.control_bar == nil, "Control bar must be closed when minimized")
    assert(player.mini_bubble ~= nil, "Mini bubble must be shown")

    -- Restore
    player:toggleMode()
    assert(player.is_mini == false)
    assert(player.control_bar ~= nil, "Control bar must be restored")
    assert(player.mini_bubble == nil, "Mini bubble must be closed")

    player:hide()
end)

-- Test 10: Mini Bubble Play/Pause icon tap
run_test("Mini Bubble: Play/Pause button on bubble works", function()
    local toggled = false
    local mock_queue = {
        getState = function() return "PLAYING" end,
        togglePlayPause = function() toggled = true end,
        getSlot = function() return nil end,
    }

    local player = UIPlayer:new{ playback_queue = mock_queue }
    player.is_mini = true
    player:showMiniBubble()

    assert(player.mini_play_btn ~= nil)
    player.mini_play_btn.callback()
    assert(toggled == true, "Tapping play on bubble must call togglePlayPause")

    player:hide()
end)

-- Test 11: addToHighlightMenu hook
run_test("Selection Hook: addToHighlightMenu adds TTS button", function()
    local plugin = KoreaderTTS:new{
        ui = { menu = {} }
    }
    plugin:init()

    local menu_items = {
        { text = "Highlight" },
        { text = "Bookmark" },
    }

    plugin:addToHighlightMenu(menu_items, "Selected text snippet by user.")

    assert(#menu_items == 3, "menu_items must have 1 added item")
    assert(menu_items[3].text == "🔊 Đọc bằng TTS", "Added button must be '🔊 Đọc bằng TTS'")
    assert(type(menu_items[3].callback) == "function", "Button must have callback")
end)

-- Test 12: onReadSelectedText plays selection independently
run_test("Selection Reading: onReadSelectedText plays audio selection", function()
    MockKOReader.UIManager:reset()
    local doc = MockKOReader.createMockCrengineDocument()
    local ui = MockKOReader.createMockUI(doc, 1)

    local plugin = KoreaderTTS:new{ ui = ui }
    plugin:init()

    local played_wav = nil
    plugin.tts_client._mock_transport = function(text, voice, done)
        done(true, "RIFF_DUMMY_DATA_FOR_TEST")
    end
    plugin.audio_backend.play = function(self, path, on_finish)
        played_wav = path
        if on_finish then on_finish(true) end
        return true
    end

    local selected_text = "This is a highlighted snippet to read."
    plugin:onReadSelectedText(selected_text)

    MockKOReader.UIManager:runAllScheduled()

    assert(played_wav ~= nil, "Snippet must be played via audio_backend")
    assert(ui.view.state.page == 1, "Book page position must remain unchanged")
end)

print("==========================================================")
print("  ALL 12 TESTS PASSED SUCCESSFULLY!                      ")
print("==========================================================")
