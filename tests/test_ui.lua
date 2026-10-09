--[[
    tests/test_ui.lua - Unit tests for Presentation layer
    Tests:
      - src.ui.canvas_highlight
      - src.ui.player_widget
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
print("  UNIT TEST SUITE: PRESENTATION LAYER (src/ui/)")
print("==========================================================")

local CanvasHighlight = require("src.ui.canvas_highlight")
local PlayerWidget = require("src.ui.player_widget")
local SettingsManager = require("src.service.settings_manager")

-- 1. CanvasHighlight Tests
run_test("CanvasHighlight: Gray mode sets partial refresh dirty rects", function()
    local highlighter = CanvasHighlight:new()
    local dirty_calls = {}
    local UIManager = require("ui/uimanager")
    local old_setDirty = UIManager.setDirty
    UIManager.setDirty = function(self, view, refresh_type, rects)
        table.insert(dirty_calls, { refresh_type = refresh_type, count = #rects })
    end

    local mock_view = {
        clearHighlight = function(self) end,
        setHighlight = function(self, boxes, color) end,
    }
    local bboxes = {
        { x = 10, y = 100, w = 300, h = 25 },
        { x = 10, y = 130, w = 250, h = 25 },
    }

    highlighter:highlightSentence(mock_view, bboxes, "gray")
    assert(highlighter.current_highlight ~= nil)
    assert(#highlighter.current_highlight == 2)
    assert(#dirty_calls > 0)
    assert(dirty_calls[#dirty_calls].refresh_type == "partial", "Must use partial E-ink refresh")

    UIManager.setDirty = old_setDirty
end)

run_test("CanvasHighlight: Underline mode creates 2px bottom strip", function()
    local highlighter = CanvasHighlight:new()
    local applied_boxes = nil
    local mock_view = {
        clearHighlight = function(self) end,
        setHighlight = function(self, boxes, color)
            applied_boxes = boxes
        end,
    }
    local bboxes = { { x = 20, y = 50, w = 150, h = 30 } }
    highlighter:highlightSentence(mock_view, bboxes, "underline")

    assert(applied_boxes ~= nil)
    assert(applied_boxes[1].h == 2, "Underline height must be 2px")
    assert(applied_boxes[1].y == (50 + 30 - 2), "Underline must anchor to bottom of line")
end)

run_test("CanvasHighlight: clearHighlight clears boxes safely", function()
    local highlighter = CanvasHighlight:new()
    local cleared = false
    local mock_view = {
        clearHighlight = function(self) cleared = true end,
        setHighlight = function(self, b, c) end,
    }
    highlighter:highlightSentence(mock_view, { { x = 0, y = 0, w = 10, h = 10 } }, "gray")
    assert(highlighter.current_highlight ~= nil)

    highlighter:clearHighlight(mock_view)
    assert(cleared == true, "Must call view:clearHighlight")
    assert(highlighter.current_highlight == nil, "current_highlight must be nil after clear")
end)

-- 2. PlayerWidget Tests
run_test("PlayerWidget: Control bar and mini bubble toggle", function()
    local sm = SettingsManager:new()
    local mock_view = {
        clearHighlight = function(self) end,
        setHighlight = function(self, b, c) end,
    }
    local player = PlayerWidget:new({
        view = mock_view,
        settings = sm,
    })

    assert(player.is_mini == false)
    player:showControlBar()
    assert(player.control_bar ~= nil)

    player:toggleMode()
    assert(player.is_mini == true)
    assert(player.mini_bubble ~= nil)

    player:toggleMode()
    assert(player.is_mini == false)
    assert(player.control_bar ~= nil)

    player:hide()
    assert(player.visible == false)
end)

run_test("PlayerWidget: Playback speed cycling", function()
    local sm = SettingsManager:new()
    local backend = {
        speed = 1.0,
        setSpeed = function(self, s) self.speed = s end,
    }
    local player = PlayerWidget:new({
        settings = sm,
        audio_backend = backend,
    })

    player:onCycleSpeed()
    assert(backend.speed == 1.2, "1.0x must cycle to 1.2x")

    player:onCycleSpeed()
    assert(backend.speed == 1.5, "1.2x must cycle to 1.5x")

    player:onCycleSpeed()
    assert(backend.speed == 2.0, "1.5x must cycle to 2.0x")

    player:onCycleSpeed()
    assert(backend.speed == 0.8, "2.0x must cycle back to 0.8x")

    player:onCycleSpeed()
    assert(backend.speed == 1.0, "0.8x must cycle to 1.0x")
end)

run_test("PlayerWidget: Highlighting delegation to CanvasHighlight", function()
    local mock_view = {
        clearHighlight = function(self) end,
        setHighlight = function(self, b, c) end,
    }
    local player = PlayerWidget:new({
        view = mock_view,
        settings = SettingsManager:new(),
    })
    assert(player.highlighter ~= nil, "PlayerWidget must instantiate CanvasHighlight")

    local bboxes = { { x = 5, y = 5, w = 100, h = 20 } }
    player:highlightSentence(bboxes, "gray")
    assert(player.current_highlight ~= nil)

    player:clearHighlight()
    assert(player.current_highlight == nil)
end)

print("==========================================================")
print(string.format("  ALL %d/%d PRESENTATION TESTS PASSED!", passed_tests, total_tests))
print("==========================================================")

if passed_tests < total_tests then os.exit(1) end
