--[[
    tests/test_phase5_ui.lua - Bộ kiểm thử độc lập cho Giai đoạn 5 (Phase 5)
    Kiểm tra:
      - Bôi sáng câu (Sentence Highlighting) với partial E-ink refresh
      - Thanh điều khiển nổi neo đáy màn hình (Floating Control Bar)
      - Chế độ thu nhỏ (Mini Floating Bubble)
      - Menu bôi đen chữ (Text Selection Hook) & phát đoạn chọn độc lập
    Chạy trực tiếp qua: luajit tests/test_phase5_ui.lua
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
print("  CHẠY BỘ KIỂM THỬ ĐỘC LẬP - GIAI ĐOẠN 5 (PHASE 5)")
print("==========================================================")

-- Helper mock bboxes
local sample_bboxes = {
    { x = 50, y = 100, w = 400, h = 24 },
    { x = 50, y = 128, w = 250, h = 24 },
}

-- Test 1: Bôi sáng câu ở chế độ gray
run_test("Highlight: Chế độ gray gọi setHighlight COLOR_GRAY_E & partial", function()
    MockKOReader.UIManager:reset()
    local doc = MockKOReader.createMockCrengineDocument()
    local ui = MockKOReader.createMockUI(doc, 1)

    local player = UIPlayer:new{
        ui = ui,
        view = ui.view,
    }

    player:highlightSentence(sample_bboxes, "gray")

    assert(ui.view._highlight ~= nil, "view._highlight phải được gán")
    assert(ui.view._highlight_color == _G.Blitbuffer.COLOR_GRAY_E, "Màu highlight phải là COLOR_GRAY_E")
    assert(#ui.view._highlight == 2, "Phải có 2 bounding boxes")

    -- Kiểm tra partial refresh
    assert(#MockKOReader.UIManager._dirty_calls >= 1, "Phải gọi UIManager:setDirty")
    local last_dirty = MockKOReader.UIManager._dirty_calls[#MockKOReader.UIManager._dirty_calls]
    assert(last_dirty.refresh_type == "partial", "Chế độ refresh phải là partial (chống chớp E-ink)")
end)

-- Test 2: Bôi sáng câu ở chế độ underline
run_test("Highlight: Chế độ underline tạo dải viền đáy chữ h=2px", function()
    MockKOReader.UIManager:reset()
    local doc = MockKOReader.createMockCrengineDocument()
    local ui = MockKOReader.createMockUI(doc, 1)

    local player = UIPlayer:new{
        ui = ui,
        view = ui.view,
    }

    player:highlightSentence(sample_bboxes, "underline")

    assert(ui.view._highlight ~= nil)
    assert(ui.view._highlight_color == _G.Blitbuffer.COLOR_BLACK, "Gạch chân phải dùng COLOR_BLACK")
    assert(ui.view._highlight[1].h == 2, "Chiều cao đường gạch chân phải là 2px")
    assert(ui.view._highlight[1].y == 100 + 24 - 2, "Vị trí y của đường gạch chân phải ở đáy dòng chữ")
end)

-- Test 3: Chế độ highlight "none"
run_test("Highlight: Chế độ none không hiển thị bôi sáng", function()
    MockKOReader.UIManager:reset()
    local doc = MockKOReader.createMockCrengineDocument()
    local ui = MockKOReader.createMockUI(doc, 1)

    local player = UIPlayer:new{
        ui = ui,
        view = ui.view,
    }

    player:highlightSentence(sample_bboxes, "none")
    assert(ui.view._highlight == nil, "Chế độ none không được gán highlight")
end)

-- Test 4: Làm sạch highlight khi chuyển câu
run_test("Highlight: clearHighlight xóa highlight và dirty vùng cũ", function()
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

    assert(ui.view._highlight == nil, "Highlight trên view phải bị xóa")
    assert(player.current_highlight == nil, "current_highlight phải về nil")
    assert(#MockKOReader.UIManager._dirty_calls == 1, "Phải gọi partial dirty rect làm sạch vùng cũ")
end)

-- Test 5: Tạo cây widget Floating Control Bar
run_test("Control Bar: Dựng đủ 3 dòng Header, Controls, Footer", function()
    MockKOReader.UIManager:reset()
    local doc = MockKOReader.createMockCrengineDocument()
    local ui = MockKOReader.createMockUI(doc, 1)

    local player = UIPlayer:new{
        ui = ui,
        view = ui.view,
    }

    player:showControlBar()

    assert(player.control_bar ~= nil, "control_bar phải được khởi tạo")
    assert(#MockKOReader.UIManager._shown_widgets == 1, "UIManager phải hiển thị control_bar")
    assert(player.title_widget ~= nil, "Phải có title_widget hiển thị tiến độ")
    assert(player.play_pause_btn ~= nil, "Phải có play_pause_btn")
    assert(player.speed_btn ~= nil, "Phải có speed_btn")
    assert(player.buffer_status_widget ~= nil, "Phải có buffer_status_widget")

    player:hideControlBar()
    assert(player.control_bar == nil, "hideControlBar phải giải phóng widget")
end)

-- Test 6: Bấm các nút điều hướng trên Control Bar
run_test("Control Bar: Nút Play/Pause, Next, Prev, Pages gọi queue", function()
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

-- Test 7: Xoay vòng tốc độ đọc qua nút [Tốc độ]
run_test("Speed: Nút tốc độ xoay vòng 0.8x -> 1.0x -> 1.2x -> 1.5x -> 2.0x", function()
    local storage = MockKOReader.createMockSettings()
    local settings = Settings:new(storage)
    local audio_backend = AudioBackend:new{ speed = 1.0 }

    local player = UIPlayer:new{
        settings = settings,
        audio_backend = audio_backend,
    }
    player:showControlBar()

    -- Đang 1.0x -> xoay vòng sang 1.2x
    player:onCycleSpeed()
    assert(math.abs(audio_backend.speed - 1.2) < 0.01, "Tốc độ audio_backend phải là 1.2x")
    assert(math.abs(settings:get("speed") - 1.2) < 0.01, "Settings phải lưu 1.2x")

    -- 1.2x -> 1.5x
    player:onCycleSpeed()
    assert(math.abs(audio_backend.speed - 1.5) < 0.01)

    -- 1.5x -> 2.0x
    player:onCycleSpeed()
    assert(math.abs(audio_backend.speed - 2.0) < 0.01)

    -- 2.0x -> quay lại 0.8x
    player:onCycleSpeed()
    assert(math.abs(audio_backend.speed - 0.8) < 0.01)

    player:hide()
end)

-- Test 8: Đèn trạng thái bộ đệm (●●, ●○, ○○)
run_test("Buffer Status: Đèn đệm hiển thị chính xác theo slots", function()
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

    assert(player.buffer_status_widget.text:find("●●"), "Cả 2 slot READY phải hiện ●●")

    -- Chỉ slot 1 READY
    mock_queue.getSlot = function(self, offset)
        if offset == 1 then return { status = "READY" } end
        return { status = "FETCHING" }
    end
    player:_updateBufferStatus()
    assert(player.buffer_status_widget.text:find("●○"), "1 slot READY phải hiện ●○")

    -- Chưa có slot nào READY
    mock_queue.getSlot = function(self, offset)
        return { status = "FETCHING" }
    end
    player:_updateBufferStatus()
    assert(player.buffer_status_widget.text:find("○○"), "Đang tải phải hiện ○○")

    player:hide()
end)

-- Test 9: Thu nhỏ thành Mini Bubble và mở rộng lại
run_test("Mini Bubble: Chuyển đổi qua lại giữa Control Bar và Bubble", function()
    MockKOReader.UIManager:reset()
    local player = UIPlayer:new()

    -- Mở control bar
    player:show()
    assert(player.is_mini == false)
    assert(player.control_bar ~= nil)
    assert(player.mini_bubble == nil)

    -- Thu nhỏ
    player:toggleMode()
    assert(player.is_mini == true)
    assert(player.control_bar == nil, "Control bar phải bị đóng khi thu nhỏ")
    assert(player.mini_bubble ~= nil, "Mini bubble phải được hiển thị")

    -- Mở rộng lại
    player:toggleMode()
    assert(player.is_mini == false)
    assert(player.control_bar ~= nil, "Control bar phải được phục hồi")
    assert(player.mini_bubble == nil, "Mini bubble phải đóng khi phóng to")

    player:hide()
end)

-- Test 10: Chạm icon trên Mini Bubble toggle Play/Pause
run_test("Mini Bubble: Nút Play/Pause trên Bubble hoạt động chuẩn", function()
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
    assert(toggled == true, "Chạm nút play trên mini bubble phải gọi togglePlayPause")

    player:hide()
end)

-- Test 11: Hook addToHighlightMenu thêm nút Đọc bằng TTS
run_test("Selection Hook: addToHighlightMenu thêm nút Đọc bằng TTS", function()
    local plugin = KoreaderTTS:new{
        ui = { menu = {} }
    }
    plugin:init()

    local menu_items = {
        { text = "Đánh dấu" },
        { text = "Ghi chú" },
    }

    plugin:addToHighlightMenu(menu_items, "Đoạn văn bản được người dùng bôi đen.")

    assert(#menu_items == 3, "menu_items phải được thêm 1 nút")
    assert(menu_items[3].text == "🔊 Đọc bằng TTS", "Nút thêm vào phải là '🔊 Đọc bằng TTS'")
    assert(type(menu_items[3].callback) == "function", "Nút phải có callback")
end)

-- Test 12: onReadSelectedText phát âm thanh đoạn chọn độc lập
run_test("Selection Reading: onReadSelectedText phát audio đoạn chọn", function()
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

    local selected_text = "Đây là đoạn văn bản được bôi đen cần đọc."
    plugin:onReadSelectedText(selected_text)

    -- Bơm scheduler
    MockKOReader.UIManager:runAllScheduled()

    assert(played_wav ~= nil, "Đoạn văn chọn phải được gửi phát qua audio_backend")
    assert(ui.view.state.page == 1, "Trang sách hiện tại không được phép thay đổi khi đọc đoạn bôi đen")
end)

print("==========================================================")
print("  TẤT CẢ 12 BÀI KIỂM THỬ ĐỀU ĐÃ VƯỢT QUA THÀNH CÔNG!     ")
print("==========================================================")
