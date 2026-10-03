--[[
    ui_player.lua - Giao diện Native & Đồng bộ Mắt - Tai cho KOReader TTS Plugin
    Triển khai:
      - Thanh điều khiển nổi neo đáy màn hình (Floating Control Bar) chuẩn E-ink
      - Chế độ thu nhỏ (Mini Floating Bubble)
      - Đồng bộ bôi sáng câu thời gian thực (Sentence Highlighting) với partial E-ink refresh
      - Tương tác hai chiều mượt mà với PlaybackQueue
--]]

local WidgetContainer = require("ui/widget/widgetcontainer")
local UIManager = require("ui/uimanager")

local ok_frame, FrameContainer = pcall(require, "ui/widget/framecontainer")
if not ok_frame then FrameContainer = WidgetContainer end

local ok_vg, VerticalGroup = pcall(require, "ui/widget/verticalgroup")
if not ok_vg then VerticalGroup = WidgetContainer end

local ok_hg, HorizontalGroup = pcall(require, "ui/widget/horizontalgroup")
if not ok_hg then HorizontalGroup = WidgetContainer end

local ok_btn, Button = pcall(require, "ui/widget/button")
if not ok_btn then Button = WidgetContainer end

local ok_icon, IconButton = pcall(require, "ui/widget/iconbutton")
if not ok_icon then IconButton = WidgetContainer end

local ok_text, TextWidget = pcall(require, "ui/widget/textwidget")
if not ok_text then TextWidget = WidgetContainer end

local ok_blit, Blitbuffer = pcall(require, "ffi/blitbuffer")
if not ok_blit or not Blitbuffer then
    Blitbuffer = {
        COLOR_WHITE  = 0xFFFFFF,
        COLOR_BLACK  = 0x000000,
        COLOR_GRAY_E = 0xEEEEEE,
    }
end

local ok_screen, Screen = pcall(require, "device/screen")
if not ok_screen or not Screen then
    Screen = {
        getWidth = function() return 600 end,
        getHeight = function() return 800 end,
        scaleBySize = function(self, px) return px end,
    }
end

local ok_size, Size = pcall(require, "ui/size")
if not ok_size or not Size then
    Size = {
        border = { thin = 1, medium = 2 },
        padding = { default = 5 },
    }
end

local ok_gettext, _ = pcall(require, "gettext")
if not ok_gettext or type(_) ~= "function" then
    _ = function(msg) return msg end
end

local UIPlayer = WidgetContainer:extend{
    name = "koreader_tts_ui_player",
}

-- Danh sách các nấc tốc độ đọc hỗ trợ xoay vòng
local SPEED_LEVELS = { 0.8, 1.0, 1.2, 1.5, 2.0 }

--- Khởi tạo đối tượng UIPlayer
function UIPlayer:new(opts)
    local instance = setmetatable({}, self)
    opts = opts or {}

    instance.ui = opts.ui
    instance.view = opts.view or (opts.ui and opts.ui.view)
    instance.playback_queue = opts.playback_queue
    instance.settings = opts.settings
    instance.audio_backend = opts.audio_backend
    instance.chunker = opts.chunker

    instance.visible = false
    instance.is_mini = false
    instance.current_highlight = nil

    instance.current_page = 1
    instance.current_index = 1
    instance.total_on_page = 1

    -- Tham chiếu widget
    instance.control_bar = nil
    instance.mini_bubble = nil
    instance.title_widget = nil
    instance.play_pause_btn = nil
    instance.mini_play_btn = nil
    instance.mini_label_btn = nil
    instance.speed_btn = nil
    instance.buffer_status_widget = nil

    return instance
end

--- Hiển thị giao diện điều khiển (thanh lớn hoặc mini bubble tùy trạng thái)
function UIPlayer:show()
    self.visible = true
    if self.is_mini then
        self:showMiniBubble()
    else
        self:showControlBar()
    end
end

--- Ẩn toàn bộ giao diện điều khiển và làm sạch highlight
function UIPlayer:hide()
    self.visible = false
    self:hideControlBar()
    self:hideMiniBubble()
    self:clearHighlight()
end

--- Chuyển đổi qua lại giữa thanh điều khiển đầy đủ và bong bóng thu nhỏ
function UIPlayer:toggleMode()
    if self.is_mini then
        self.is_mini = false
        self:hideMiniBubble()
        self:showControlBar()
    else
        self.is_mini = true
        self:hideControlBar()
        self:showMiniBubble()
    end
end

--- Hiển thị thanh điều khiển nổi (Floating Control Bar) neo ở đáy màn hình
function UIPlayer:showControlBar()
    if self.control_bar then
        UIManager:close(self.control_bar)
    end

    local this = self
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()
    local bar_h = 135

    -- 1. Dòng 1: Header (Tiêu đề tiến độ, nút thu nhỏ [—], nút đóng [✕])
    self.title_widget = TextWidget:new{
        text = string.format(_("Trang %d · Câu %d/%d"), self.current_page, self.current_index, self.total_on_page),
    }

    local btn_minimize = Button:new{
        text = " [—] ",
        callback = function()
            this:toggleMode()
        end,
    }

    local btn_close = Button:new{
        text = " [✕] ",
        callback = function()
            this:onClose()
        end,
    }

    local header_row = HorizontalGroup:new{
        self.title_widget,
        btn_minimize,
        btn_close,
    }

    -- 2. Dòng 2: Cụm 5 nút điều khiển phát âm thanh
    local btn_prev_page = IconButton:new{
        icon = "backward_step",
        text = "|<",
        callback = function()
            this:onPrevPage()
        end,
    }

    local btn_prev_chunk = IconButton:new{
        icon = "rewind",
        text = "<<",
        callback = function()
            this:onPrevChunk()
        end,
    }

    local is_playing = self.playback_queue and (self.playback_queue:getState() == "PLAYING")
    self.play_pause_btn = IconButton:new{
        icon = is_playing and "pause" or "play",
        text = is_playing and " || " or " ▶ ",
        callback = function()
            this:onTogglePlayPause()
        end,
    }

    local btn_next_chunk = IconButton:new{
        icon = "fastforward",
        text = ">>",
        callback = function()
            this:onNextChunk()
        end,
    }

    local btn_next_page = IconButton:new{
        icon = "forward_step",
        text = ">|",
        callback = function()
            this:onNextPage()
        end,
    }

    local controls_row = HorizontalGroup:new{
        btn_prev_page,
        btn_prev_chunk,
        self.play_pause_btn,
        btn_next_chunk,
        btn_next_page,
    }

    -- 3. Dòng 3: Footer (Tốc độ đọc, Giọng đọc, Đèn trạng thái đệm)
    local cur_speed = self.audio_backend and self.audio_backend.speed or 1.0
    self.speed_btn = Button:new{
        text = string.format(_("Tốc độ: %.1fx"), cur_speed),
        callback = function()
            this:onCycleSpeed()
        end,
    }

    local cur_voice = self.settings and self.settings:get("voice") or "vi-VN-NamMinh"
    local voice_text = TextWidget:new{
        text = string.format(_("Giọng: %s"), cur_voice),
    }

    self.buffer_status_widget = TextWidget:new{
        text = _("Đệm: ●● (2 câu)"),
    }

    local footer_row = HorizontalGroup:new{
        self.speed_btn,
        voice_text,
        self.buffer_status_widget,
    }

    -- Cây widget tổng thể: FrameContainer viền 1px
    local group = VerticalGroup:new{
        header_row,
        controls_row,
        footer_row,
    }

    self.control_bar = FrameContainer:new{
        bordersize = Size.border.thin or 1,
        background = Blitbuffer.COLOR_WHITE,
        dimen = { x = 0, y = screen_h - bar_h, w = screen_w, h = bar_h },
        group,
    }

    UIManager:show(self.control_bar)
    self:_updateBufferStatus()
end

--- Đóng thanh điều khiển nổi
function UIPlayer:hideControlBar()
    if self.control_bar then
        UIManager:close(self.control_bar)
        self.control_bar = nil
        self.play_pause_btn = nil
        self.speed_btn = nil
        self.title_widget = nil
        self.buffer_status_widget = nil
    end
end

--- Hiển thị Mini Floating Bubble ở góc dưới bên phải màn hình
function UIPlayer:showMiniBubble()
    if self.mini_bubble then
        UIManager:close(self.mini_bubble)
    end

    local this = self
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()
    local bubble_w = 140
    local bubble_h = 42

    local is_playing = self.playback_queue and (self.playback_queue:getState() == "PLAYING")
    self.mini_play_btn = IconButton:new{
        icon = is_playing and "pause" or "play",
        text = is_playing and "||" or "▶",
        callback = function()
            this:onTogglePlayPause()
        end,
    }

    local cur_speed = self.audio_backend and self.audio_backend.speed or 1.0
    self.mini_label_btn = Button:new{
        text = string.format("%d/%d · %.1fx", self.current_index, self.total_on_page, cur_speed),
        callback = function()
            -- Chạm vào phần chữ để phóng to trở lại thanh điều khiển đầy đủ
            this:toggleMode()
        end,
    }

    local bubble_group = HorizontalGroup:new{
        self.mini_play_btn,
        self.mini_label_btn,
    }

    self.mini_bubble = FrameContainer:new{
        bordersize = Size.border.thin or 1,
        background = Blitbuffer.COLOR_WHITE,
        dimen = {
            x = screen_w - bubble_w - 15,
            y = screen_h - bubble_h - 25,
            w = bubble_w,
            h = bubble_h,
        },
        bubble_group,
    }

    UIManager:show(self.mini_bubble)
end

--- Đóng Mini Floating Bubble
function UIPlayer:hideMiniBubble()
    if self.mini_bubble then
        UIManager:close(self.mini_bubble)
        self.mini_bubble = nil
        self.mini_play_btn = nil
        self.mini_label_btn = nil
    end
end

-- =========================================================================
-- ĐỒNG BỘ BÔI SÁNG CÂU TRÊN MÀN HÌNH E-INK (SENTENCE HIGHLIGHTING)
-- =========================================================================

--- Bôi sáng câu đang đọc và làm mới cục bộ (Partial Refresh) chống chớp màn hình
-- @param bboxes Mảng tọa độ các hình chữ nhật bao quanh chữ
-- @param mode Chế độ bôi sáng: "gray" | "underline" | "none"
function UIPlayer:highlightSentence(bboxes, mode)
    mode = mode or (self.settings and self.settings:get("highlight_mode")) or "gray"
    if mode == "none" then
        self:clearHighlight()
        return
    end

    if not self.view then
        return
    end

    -- Thu thập vùng chữ nhật cũ để gom vào lệnh làm mới cục bộ (partial dirty rect)
    local dirty_rects = {}
    if self.current_highlight then
        for _, rect in ipairs(self.current_highlight) do
            table.insert(dirty_rects, rect)
        end
    end

    -- Xóa highlight cũ
    if type(self.view.clearHighlight) == "function" then
        pcall(self.view.clearHighlight, self.view)
    end

    if not bboxes or #bboxes == 0 then
        self.current_highlight = nil
        if #dirty_rects > 0 and UIManager.setDirty then
            UIManager:setDirty(self.view, "partial", dirty_rects)
        end
        return
    end

    -- Áp dụng highlight theo chế độ
    local highlight_boxes = bboxes
    local highlight_color = Blitbuffer.COLOR_GRAY_E

    if mode == "underline" then
        -- Chế độ gạch chân: biến đổi mỗi bbox thành một đường viền h=2px ở đáy dòng
        highlight_boxes = {}
        for _, b in ipairs(bboxes) do
            table.insert(highlight_boxes, {
                x = b.x,
                y = b.y + math.max(0, b.h - 2),
                w = b.w,
                h = 2,
            })
        end
        highlight_color = Blitbuffer.COLOR_BLACK
    end

    if type(self.view.setHighlight) == "function" then
        pcall(self.view.setHighlight, self.view, highlight_boxes, highlight_color)
    end

    self.current_highlight = highlight_boxes

    -- Gom tọa độ mới vào danh sách dirty
    for _, rect in ipairs(highlight_boxes) do
        table.insert(dirty_rects, rect)
    end

    -- Yêu cầu UIManager chỉ làm mới đúng vùng hình chữ nhật cục bộ (Không chớp toàn màn hình)
    if #dirty_rects > 0 and UIManager.setDirty then
        pcall(UIManager.setDirty, UIManager, self.view, "partial", dirty_rects)
    end
end

--- Làm sạch highlight đang hiển thị
function UIPlayer:clearHighlight()
    if self.current_highlight and self.view then
        local old_rects = self.current_highlight
        self.current_highlight = nil

        if type(self.view.clearHighlight) == "function" then
            pcall(self.view.clearHighlight, self.view)
        end
        if UIManager.setDirty then
            pcall(UIManager.setDirty, UIManager, self.view, "partial", old_rects)
        end
    end
end

-- =========================================================================
-- ĐỒNG BỘ TRẠNG THÁI & PHẢN HỒI SỰ KIỆN TỪ PLAYBACK QUEUE
-- =========================================================================

--- Cập nhật biểu tượng Play/Pause trên các widget đang mở
function UIPlayer:_updatePlayPauseIcon()
    local is_playing = self.playback_queue and (self.playback_queue:getState() == "PLAYING")
    local icon = is_playing and "pause" or "play"
    local label = is_playing and " || " or " ▶ "

    if self.play_pause_btn then
        if self.play_pause_btn.setIcon then self.play_pause_btn:setIcon(icon) end
        if self.play_pause_btn.setText then self.play_pause_btn:setText(label) end
    end
    if self.mini_play_btn then
        if self.mini_play_btn.setIcon then self.mini_play_btn:setIcon(icon) end
        if self.mini_play_btn.setText then self.mini_play_btn:setText(is_playing and "||" or "▶") end
    end
end

--- Cập nhật đèn trạng thái bộ đệm (●●, ●○, ○○)
function UIPlayer:_updateBufferStatus()
    if not self.buffer_status_widget or not self.playback_queue then
        return
    end

    local s1 = self.playback_queue:getSlot(1)
    local s2 = self.playback_queue:getSlot(2)

    local s1_ready = s1 and (s1.status == "READY")
    local s2_ready = s2 and (s2.status == "READY")

    local status_text = _("Đệm: ○○ (đang tải)")
    if s1_ready and s2_ready then
        status_text = _("Đệm: ●● (2 câu)")
    elseif s1_ready then
        status_text = _("Đệm: ●○ (1 câu)")
    end

    if self.buffer_status_widget.setText then
        self.buffer_status_widget:setText(status_text)
    end
end

--- Xử lý sự kiện khi câu đọc thay đổi
function UIPlayer:onChunkChange(chunk, page, index, total)
    self.current_page = page
    self.current_index = index
    self.total_on_page = total or self.total_on_page

    -- 1. Cập nhật nhãn tiến độ
    local progress_str = string.format(_("Trang %d · Câu %d/%d"), page, index, total)
    if self.title_widget and self.title_widget.setText then
        self.title_widget:setText(progress_str)
    end

    local cur_speed = self.audio_backend and self.audio_backend.speed or 1.0
    if self.mini_label_btn and self.mini_label_btn.setText then
        self.mini_label_btn:setText(string.format("%d/%d · %.1fx", index, total, cur_speed))
    end

    -- 2. Đồng bộ bôi sáng câu trên trang sách
    if chunk and chunk.bboxes then
        self:highlightSentence(chunk.bboxes)
    end

    -- 3. Cập nhật đèn đệm & icon
    self:_updateBufferStatus()
    self:_updatePlayPauseIcon()
end

--- Xử lý sự kiện khi trạng thái FSM thay đổi
function UIPlayer:onStateChange(old_state, new_state)
    self:_updatePlayPauseIcon()
    self:_updateBufferStatus()
end

--- Xử lý sự kiện khi tự động lật sang trang mới
function UIPlayer:onPageTurn(new_page)
    self.current_page = new_page
    self:clearHighlight()
end

--- Xử lý sự kiện khi đọc xong toàn bộ sách
function UIPlayer:onFinished()
    self:clearHighlight()
    self:_updatePlayPauseIcon()
end

--- Xử lý sự kiện khi gặp lỗi âm thanh hoặc mạng
function UIPlayer:onError(err)
    self:_updatePlayPauseIcon()
end

-- =========================================================================
-- HÀNH VI TƯƠNG TÁC TỪ CÁC NÚT BẤM (USER ACTIONS)
-- =========================================================================

--- Bấm Play / Pause
function UIPlayer:onTogglePlayPause()
    if self.playback_queue then
        self.playback_queue:togglePlayPause()
        self:_updatePlayPauseIcon()
    end
end

--- Bấm Câu tiếp theo
function UIPlayer:onNextChunk()
    if self.playback_queue then
        self.playback_queue:nextChunk()
    end
end

--- Bấm Câu trước đó
function UIPlayer:onPrevChunk()
    if self.playback_queue then
        self.playback_queue:prevChunk()
    end
end

--- Bấm Trang tiếp theo (Đoạn sau)
function UIPlayer:onNextPage()
    if self.playback_queue then
        self.playback_queue:seekChunk(self.current_page + 1, 1)
    end
end

--- Bấm Trang trước đó (Đoạn trước)
function UIPlayer:onPrevPage()
    if self.playback_queue and self.current_page > 1 then
        self.playback_queue:seekChunk(self.current_page - 1, 1)
    end
end

--- Xoay vòng tốc độ đọc (0.8x -> 1.0x -> 1.2x -> 1.5x -> 2.0x)
function UIPlayer:onCycleSpeed()
    local cur_speed = self.audio_backend and self.audio_backend.speed or 1.0
    local next_speed = SPEED_LEVELS[1]

    for i, s in ipairs(SPEED_LEVELS) do
        if math.abs(s - cur_speed) < 0.05 then
            next_speed = SPEED_LEVELS[(i % #SPEED_LEVELS) + 1]
            break
        end
    end

    if self.audio_backend then
        self.audio_backend:setSpeed(next_speed)
    end
    if self.settings then
        self.settings:set("speed", next_speed)
        self.settings:save()
    end

    if self.speed_btn and self.speed_btn.setText then
        self.speed_btn:setText(string.format(_("Tốc độ: %.1fx"), next_speed))
    end
    if self.mini_label_btn and self.mini_label_btn.setText then
        self.mini_label_btn:setText(string.format("%d/%d · %.1fx", self.current_index, self.total_on_page, next_speed))
    end
end

--- Bấm nút đóng [✕]
function UIPlayer:onClose()
    if self.playback_queue then
        self.playback_queue:stop()
    end
    self:hide()
end

return UIPlayer
