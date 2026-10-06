--[[
    ui_player.lua - Native UI & Visual Sync for KOReader TTS Plugin
    Features:
      - Floating Control Bar anchored to bottom of screen (E-ink optimized)
      - Mini Floating Bubble mode
      - Real-time sentence highlighting with partial E-ink refresh
      - Two-way synchronization with PlaybackQueue
--]]

local ok_wc, WidgetContainer = pcall(require, "ui/widget/container/widgetcontainer")
if not ok_wc or not WidgetContainer then
    WidgetContainer = require("ui/widget/widgetcontainer")
end
local UIManager = require("ui/uimanager")

local ok_log, logger = pcall(require, "logger")
if not ok_log or not logger then
    logger = {
        warn = function(...) end,
        info = function(...) end,
        dbg = function(...) end,
        err = function(...) end,
    }
end

local ok_frame, FrameContainer = pcall(require, "ui/widget/container/framecontainer")
if not ok_frame or not FrameContainer then
    ok_frame, FrameContainer = pcall(require, "ui/widget/framecontainer")
end
if not ok_frame or not FrameContainer then
    FrameContainer = WidgetContainer
end

local ok_vg, VerticalGroup = pcall(require, "ui/widget/verticalgroup")
if not ok_vg then VerticalGroup = WidgetContainer end

local ok_hg, HorizontalGroup = pcall(require, "ui/widget/horizontalgroup")
if not ok_hg then HorizontalGroup = WidgetContainer end

local ok_btn, Button = pcall(require, "ui/widget/button")
if not ok_btn then Button = WidgetContainer end

local ok_bd, ButtonDialog = pcall(require, "ui/widget/buttondialog")
if not ok_bd or not ButtonDialog then ButtonDialog = WidgetContainer end

local ok_id, InputDialog = pcall(require, "ui/widget/inputdialog")
if not ok_id or not InputDialog then InputDialog = WidgetContainer end

local ok_text, TextWidget = pcall(require, "ui/widget/textwidget")
if not ok_text then TextWidget = WidgetContainer end

local ok_bc, BottomContainer = pcall(require, "ui/widget/container/bottomcontainer")
if not ok_bc or not BottomContainer then BottomContainer = WidgetContainer end

local ok_hspan, HorizontalSpan = pcall(require, "ui/widget/horizontalspan")
if not ok_hspan or not HorizontalSpan then
    HorizontalSpan = WidgetContainer:extend{
        width = 0,
        getSize = function(self) return { w = self.width or 0, h = 0 } end,
    }
end

local ok_vspan, VerticalSpan = pcall(require, "ui/widget/verticalspan")
if not ok_vspan or not VerticalSpan then
    VerticalSpan = WidgetContainer:extend{
        width = 0,
        getSize = function(self) return { w = 0, h = self.width or 0 } end,
    }
end

local ok_geom, Geom = pcall(require, "ui/geometry")
if not ok_geom or not Geom then
    Geom = {
        new = function(self, o) return o or {} end,
    }
end

local ok_blit, Blitbuffer = pcall(require, "ffi/blitbuffer")
if not ok_blit or not Blitbuffer then
    Blitbuffer = {
        COLOR_WHITE  = 0xFFFFFF,
        COLOR_BLACK  = 0x000000,
        COLOR_GRAY_E = 0xEEEEEE,
    }
end

local ok_dev, Device = pcall(require, "device")
local Screen = (ok_dev and Device and Device.screen) or _G.Screen
if not Screen then
    local ok_s, S = pcall(require, "device/screen")
    Screen = ok_s and S or {
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

local ok_font, Font = pcall(require, "ui/font")
if not ok_font or not Font then
    Font = {
        getFace = function(self, name, size)
            return {
                size = size or 14,
                is_real_bold = false,
                ftsize = {
                    getHeightAndAscender = function() return size or 14 end
                }
            }
        end
    }
end

local SleepTimer = require("sleep_timer")

local UIPlayer = WidgetContainer:extend{
    name = "koreader_tts_ui_player",
}
UIPlayer.__index = UIPlayer

-- Playback speed presets for cycling
local SPEED_LEVELS = { 0.8, 1.0, 1.2, 1.5, 2.0 }

--- Initialize UIPlayer instance
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

    -- Sleep Timer integration
    instance.sleep_timer = opts.sleep_timer or SleepTimer:new{
        uimanager = UIManager,
        on_timeout = function(reason)
            if instance.playback_queue then
                instance.playback_queue:stop()
            end
            instance:hide()
            local ok_info, InfoMessage = pcall(require, "ui/widget/infomessage")
            if ok_info and InfoMessage then
                UIManager:show(InfoMessage:new{
                    text = _("Đã dừng đọc theo hẹn giờ."),
                    timeout = 3,
                })
            end
        end,
        on_tick = function(rem)
            if instance.sleep_timer_btn and instance.sleep_timer_btn.setText and rem % 60 == 0 then
                instance.sleep_timer_btn:setText(instance.sleep_timer:getDisplayText())
            end
        end,
    }

    -- Widget references
    instance.control_bar = nil
    instance.mini_bubble = nil
    instance.title_widget = nil
    instance.play_pause_btn = nil
    instance.mini_play_btn = nil
    instance.mini_label_btn = nil
    instance.speed_btn = nil
    instance.sleep_timer_btn = nil
    instance.buffer_status_widget = nil

    return instance
end

--- Show UI player (full bar or mini bubble based on current mode)
function UIPlayer:show()
    self.visible = true
    if self.is_mini then
        self:showMiniBubble()
    else
        self:showControlBar()
    end
end

--- Hide UI player completely and clear highlights
function UIPlayer:hide()
    self.visible = false
    self:hideControlBar()
    self:hideMiniBubble()
    self:clearHighlight()
end

--- Toggle between full control bar and mini floating bubble
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

--- Show Floating Control Bar anchored to bottom of screen
function UIPlayer:showControlBar()
    if self.control_bar then
        UIManager:close(self.control_bar)
    end

    local this = self
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()

    -- 1. Row 1: Header (Progress title, Buffer status, [—], [✕])
    self.title_widget = TextWidget:new{
        text = string.format(_("Trang %d · Câu %d/%d"), self.current_page, self.current_index, self.total_on_page),
        face = Font:getFace("cfont", 16),
        bold = true,
    }

    self.buffer_status_widget = TextWidget:new{
        text = _("Đệm: ●● (2 câu)"),
        face = Font:getFace("cfont", 13),
    }

    local btn_minimize = Button:new{
        text = "  —  ",
        bordersize = 0,
        padding = 4,
        callback = function()
            this:toggleMode()
        end,
    }
    self.btn_minimize = btn_minimize

    local btn_close = Button:new{
        text = "  ✕  ",
        bordersize = 0,
        padding = 4,
        callback = function()
            this:onClose()
        end,
    }
    self.btn_close = btn_close

    local actions_group = HorizontalGroup:new{
        align = "center",
        btn_minimize,
        HorizontalSpan:new{ width = 6 },
        btn_close,
    }
    self.header_actions = actions_group

    self.header_span1 = HorizontalSpan:new{ width = 28 }
    self.header_span2 = HorizontalSpan:new{ width = 28 }

    local header_row = HorizontalGroup:new{
        align = "center",
        self.title_widget,
        self.header_span1,
        self.buffer_status_widget,
        self.header_span2,
        actions_group,
    }
    self.header_row = header_row

    -- 2. Row 2: Navigation controls & Quick settings
    local btn_prev_page = Button:new{
        text = " |< ",
        bordersize = Size.border.thin or 1,
        padding = 6,
        callback = function()
            this:onPrevPage()
        end,
    }
    self.btn_prev_page = btn_prev_page

    local btn_prev_chunk = Button:new{
        text = " << ",
        bordersize = Size.border.thin or 1,
        padding = 6,
        callback = function()
            this:onPrevChunk()
        end,
    }
    self.btn_prev_chunk = btn_prev_chunk

    local is_playing = self.playback_queue and (self.playback_queue:getState() == "PLAYING")
    self.play_pause_btn = Button:new{
        text = is_playing and "  ||  " or "  ▶  ",
        bordersize = Size.border.thin or 1,
        padding = 6,
        callback = function()
            this:onTogglePlayPause()
        end,
    }

    local btn_next_chunk = Button:new{
        text = " >> ",
        bordersize = Size.border.thin or 1,
        padding = 6,
        callback = function()
            this:onNextChunk()
        end,
    }
    self.btn_next_chunk = btn_next_chunk

    local btn_next_page = Button:new{
        text = " >| ",
        bordersize = Size.border.thin or 1,
        padding = 6,
        callback = function()
            this:onNextPage()
        end,
    }
    self.btn_next_page = btn_next_page

    local cur_speed = self.audio_backend and self.audio_backend.speed or 1.0
    self.speed_btn = Button:new{
        text = string.format(_("Tốc độ: %.1fx"), cur_speed),
        bordersize = Size.border.thin or 1,
        padding = 6,
        callback = function()
            this:showSpeedDialog()
        end,
    }

    self.sleep_timer_btn = Button:new{
        text = self.sleep_timer and self.sleep_timer:getDisplayText() or _("Hẹn giờ: Tắt"),
        bordersize = Size.border.thin or 1,
        padding = 6,
        callback = function()
            this:showSleepTimerDialog()
        end,
    }

    local controls_row = HorizontalGroup:new{
        align = "center",
        btn_prev_page,
        HorizontalSpan:new{ width = 6 },
        btn_prev_chunk,
        HorizontalSpan:new{ width = 6 },
        self.play_pause_btn,
        HorizontalSpan:new{ width = 6 },
        btn_next_chunk,
        HorizontalSpan:new{ width = 6 },
        btn_next_page,
        HorizontalSpan:new{ width = 18 },
        self.speed_btn,
        HorizontalSpan:new{ width = 8 },
        self.sleep_timer_btn,
    }
    self.controls_row = controls_row

    local content_group = VerticalGroup:new{
        align = "center",
        VerticalSpan:new{ width = 4 },
        header_row,
        VerticalSpan:new{ width = 8 },
        controls_row,
        VerticalSpan:new{ width = 4 },
    }
    self.content_group = content_group

    -- Compute space-between gap for header row before rendering
    self:_layoutHeaderSpaceBetween()

    local card = FrameContainer:new{
        margin = 0,
        bordersize = Size.border.thin or 1,
        background = Blitbuffer.COLOR_WHITE,
        padding = 8,
        radius = 6,
        content_group,
    }
    self.card_container = card

    local screen_geom = (Screen and type(Screen.getSize) == "function" and Screen:getSize()) or Geom:new{ w = screen_w, h = screen_h }
    self.control_bar = BottomContainer:new{
        dimen = screen_geom,
        card,
    }

    -- Direct hit-testing gesture handler: guarantees taps are intercepted reliably
    self.control_bar.handleEvent = function(cbar, event)
        local arg1 = event.args and event.args[1]
        local is_gesture = event.handler == "onGesture" or (type(arg1) == "table" and arg1.ges)
        if is_gesture then
            local ges = type(arg1) == "table" and arg1 or nil
            if ges and ges.pos and ges.ges == "tap" then
                local pos = ges.pos
                if this:_isTapOnWidget(pos, this.btn_close) then
                    this:onClose()
                    return true
                end
                if this:_isTapOnWidget(pos, this.play_pause_btn) then
                    this:onTogglePlayPause()
                    return true
                end
                if this:_isTapOnWidget(pos, this.btn_prev_chunk) then
                    this:onPrevChunk()
                    return true
                end
                if this:_isTapOnWidget(pos, this.btn_next_chunk) then
                    this:onNextChunk()
                    return true
                end
                if this:_isTapOnWidget(pos, this.btn_prev_page) then
                    this:onPrevPage()
                    return true
                end
                if this:_isTapOnWidget(pos, this.btn_next_page) then
                    this:onNextPage()
                    return true
                end
                if this:_isTapOnWidget(pos, this.speed_btn) then
                    this:showSpeedDialog()
                    return true
                end
                if this:_isTapOnWidget(pos, this.sleep_timer_btn) then
                    this:showSleepTimerDialog()
                    return true
                end
                if this:_isTapOnWidget(pos, this.btn_minimize) then
                    this:toggleMode()
                    return true
                end
                -- Absorb any tap inside the player card frame so it never leaks to reader gestures
                if this:_isTapOnWidget(pos, this.card_container) then
                    return true
                end
            end
        end
        return BottomContainer.handleEvent(cbar, event)
    end

    UIManager:show(self.control_bar)
    self:_updateBufferStatus()
end

--- Hit test a screen position against a widget's rendered dimensions
function UIPlayer:_isTapOnWidget(pos, widget)
    if not widget or not pos then return false end
    local d = widget.dimen or (widget[1] and widget[1].dimen)
    if not d or not d.x or not d.y or not d.w or not d.h then return false end
    local pad = 12
    return pos.x >= (d.x - pad) and pos.x <= (d.x + d.w + pad)
        and pos.y >= (d.y - pad) and pos.y <= (d.y + d.h + pad)
end

--- Recalculate header row layout like CSS 'justify-content: space-between'
function UIPlayer:_layoutHeaderSpaceBetween()
    if not self.controls_row or not self.header_row or not self.header_span1 or not self.header_span2 then
        return
    end

    local total_w = (self.controls_row.getSize and self.controls_row:getSize().w) or 460
    local w_title = (self.title_widget and self.title_widget.getSize and self.title_widget:getSize().w) or 160
    local w_buffer = (self.buffer_status_widget and self.buffer_status_widget.getSize and self.buffer_status_widget:getSize().w) or 120
    local w_actions = (self.header_actions and self.header_actions.getSize and self.header_actions:getSize().w) or 60

    local free_space = total_w - (w_title + w_buffer + w_actions)
    local gap = math.max(16, math.floor(free_space / 2))

    self.header_span1.width = gap
    self.header_span2.width = gap

    if self.header_row.resetLayout then
        self.header_row:resetLayout()
    end
    if self.content_group and self.content_group.resetLayout then
        self.content_group:resetLayout()
    end
end

--- Hide Floating Control Bar
function UIPlayer:hideControlBar()
    if self.control_bar then
        UIManager:close(self.control_bar)
        self.control_bar = nil
        self.play_pause_btn = nil
        self.speed_btn = nil
        self.sleep_timer_btn = nil
        self.title_widget = nil
        self.buffer_status_widget = nil
        self.btn_minimize = nil
        self.btn_close = nil
        self.btn_prev_page = nil
        self.btn_prev_chunk = nil
        self.btn_next_chunk = nil
        self.btn_next_page = nil
        self.card_container = nil
        self.header_row = nil
        self.header_span1 = nil
        self.header_span2 = nil
        self.header_actions = nil
        self.controls_row = nil
        self.content_group = nil
    end
end

--- Show Mini Floating Bubble in bottom-right corner
function UIPlayer:showMiniBubble()
    if self.mini_bubble then
        UIManager:close(self.mini_bubble)
    end

    local this = self
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()

    local is_playing = self.playback_queue and (self.playback_queue:getState() == "PLAYING")
    self.mini_play_btn = Button:new{
        text = is_playing and " || " or " ▶ ",
        bordersize = 0,
        padding = 4,
        callback = function()
            this:onTogglePlayPause()
        end,
    }

    local cur_speed = self.audio_backend and self.audio_backend.speed or 1.0
    self.mini_label_btn = Button:new{
        text = string.format("%d/%d · %.1fx", self.current_index, self.total_on_page, cur_speed),
        bordersize = 0,
        padding = 4,
        callback = function()
            -- Tap text label to restore full control bar
            this:toggleMode()
        end,
    }

    local bubble_group = HorizontalGroup:new{
        align = "center",
        self.mini_play_btn,
        HorizontalSpan:new{ width = 6 },
        self.mini_label_btn,
    }

    local card = FrameContainer:new{
        bordersize = Size.border.thin or 1,
        background = Blitbuffer.COLOR_WHITE,
        padding = 6,
        radius = 4,
        bubble_group,
    }
    self.mini_card_container = card

    local screen_geom = (Screen and type(Screen.getSize) == "function" and Screen:getSize()) or Geom:new{ w = screen_w, h = screen_h }
    self.mini_bubble = BottomContainer:new{
        dimen = screen_geom,
        card,
    }

    self.mini_bubble.handleEvent = function(mb, event)
        local arg1 = event.args and event.args[1]
        local is_gesture = event.handler == "onGesture" or (type(arg1) == "table" and arg1.ges)
        if is_gesture then
            local ges = type(arg1) == "table" and arg1 or nil
            if ges and ges.pos and ges.ges == "tap" then
                local pos = ges.pos
                if this:_isTapOnWidget(pos, this.mini_play_btn) then
                    this:onTogglePlayPause()
                    return true
                end
                -- Tapping anywhere else on the mini bubble expands back to full control bar
                if this:_isTapOnWidget(pos, this.mini_card_container) then
                    this:toggleMode()
                    return true
                end
            end
        end
        return BottomContainer.handleEvent(mb, event)
    end

    UIManager:show(self.mini_bubble)
end

--- Hide Mini Floating Bubble
function UIPlayer:hideMiniBubble()
    if self.mini_bubble then
        UIManager:close(self.mini_bubble)
        self.mini_bubble = nil
        self.mini_play_btn = nil
        self.mini_label_btn = nil
        self.mini_card_container = nil
    end
end

-- =========================================================================
-- SENTENCE HIGHLIGHTING (E-INK FRIENDLY)
-- =========================================================================

--- Highlight current sentence using partial refresh (no full screen flash)
-- @param bboxes Array of bounding box tables { x, y, w, h }
-- @param mode Highlight mode: "gray" | "underline" | "none"
function UIPlayer:highlightSentence(bboxes, mode)
    mode = mode or (self.settings and self.settings:get("highlight_mode")) or "gray"
    if mode == "none" then
        self:clearHighlight()
        return
    end

    if not self.view then
        return
    end

    -- Collect previous rects to dirty for clean removal
    local dirty_rects = {}
    if self.current_highlight then
        for _, rect in ipairs(self.current_highlight) do
            table.insert(dirty_rects, rect)
        end
    end

    -- Clear old highlight on view
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

    -- Apply highlight style
    local highlight_boxes = bboxes
    local highlight_color = Blitbuffer.COLOR_GRAY_E

    if mode == "underline" then
        -- Underline style: 2px stripe at the bottom of each text line
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

    -- Add new rects to dirty list
    for _, rect in ipairs(highlight_boxes) do
        table.insert(dirty_rects, rect)
    end

    -- Instruct UIManager to execute partial refresh only (prevents E-ink flash)
    if #dirty_rects > 0 and UIManager.setDirty then
        pcall(UIManager.setDirty, UIManager, self.view, "partial", dirty_rects)
    end
end

--- Clear active sentence highlight
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
-- STATE SYNCHRONIZATION WITH PLAYBACK QUEUE
-- =========================================================================

--- Update Play/Pause icon across active widgets
function UIPlayer:_updatePlayPauseIcon()
    local is_playing = self.playback_queue and (self.playback_queue:getState() == "PLAYING")
    local label = is_playing and "  ||  " or "  ▶  "

    if self.play_pause_btn then
        if self.play_pause_btn.setText then self.play_pause_btn:setText(label) end
    end
    if self.mini_play_btn then
        if self.mini_play_btn.setText then self.mini_play_btn:setText(is_playing and " || " or " ▶ ") end
    end
    if self.control_bar and UIManager and UIManager.setDirty then
        pcall(UIManager.setDirty, UIManager, self.control_bar, "ui")
    end
    if self.mini_bubble and UIManager and UIManager.setDirty then
        pcall(UIManager.setDirty, UIManager, self.mini_bubble, "ui")
    end
end

--- Update buffer status indicator (●●, ●○, ○○)
function UIPlayer:_updateBufferStatus()
    if not self.buffer_status_widget or not self.playback_queue then
        return
    end

    local k = (self.settings and self.settings:get("preload_count")) or 2
    k = math.max(1, math.min(7, k))

    local ready_count = 0
    for i = 1, k do
        local s = self.playback_queue:getSlot(i)
        if s and s.status == "READY" then
            ready_count = ready_count + 1
        end
    end

    local dots = string.rep("●", ready_count) .. string.rep("○", k - ready_count)
    local status_suffix = ""
    if self.playback_queue and self.playback_queue._active_fetch_offset ~= nil then
        status_suffix = " ⏳"
    elseif self.tts_client and self.tts_client.last_latency_ms and self.tts_client.last_latency_ms > 0 then
        local sec = self.tts_client.last_latency_ms / 1000
        status_suffix = string.format(" (%.1fs)", sec)
    end
    local status_text = string.format(_("Đệm: %s%s"), dots, status_suffix)

    if self.buffer_status_widget.setText then
        self.buffer_status_widget:setText(status_text)
    end
    self:_layoutHeaderSpaceBetween()
end

--- Event callback when current chunk changes
function UIPlayer:onChunkChange(chunk, page, index, total)
    self.current_page = page
    self.current_index = index
    self.total_on_page = total or self.total_on_page

    -- 1. Update progress labels
    local progress_str = string.format(_("Trang %d · Câu %d/%d"), page, index, total)
    if self.title_widget and self.title_widget.setText then
        self.title_widget:setText(progress_str)
    end
    self:_layoutHeaderSpaceBetween()

    local cur_speed = self.audio_backend and self.audio_backend.speed or 1.0
    if self.mini_label_btn and self.mini_label_btn.setText then
        self.mini_label_btn:setText(string.format("%d/%d · %.1fx", index, total, cur_speed))
    end

    -- 2. Synchronize sentence highlight
    if chunk and chunk.bboxes then
        self:highlightSentence(chunk.bboxes)
    end

    -- 3. Update buffer & play/pause icon
    self:_updateBufferStatus()
    self:_updatePlayPauseIcon()

    -- 4. Refresh control bar UI
    if self.control_bar and UIManager.setDirty then
        pcall(UIManager.setDirty, UIManager, self.control_bar, "ui")
    elseif self.mini_bubble and UIManager.setDirty then
        pcall(UIManager.setDirty, UIManager, self.mini_bubble, "ui")
    end
end

--- Event callback when FSM state changes
function UIPlayer:onStateChange(old_state, new_state)
    self:_updatePlayPauseIcon()
    self:_updateBufferStatus()
end

--- Event callback when background prefetch buffer updates
function UIPlayer:onBufferChange()
    self:_updateBufferStatus()
    if self.control_bar and UIManager and UIManager.setDirty then
        pcall(UIManager.setDirty, UIManager, self.control_bar, "ui")
    end
end

--- Event callback when page turns
function UIPlayer:onPageTurn(new_page)
    self.current_page = new_page
    self:clearHighlight()
    if self.sleep_timer then
        self.sleep_timer:onPageTurn(new_page)
    end
end

--- Event callback when entire book completes
function UIPlayer:onFinished()
    self:clearHighlight()
    self:_updatePlayPauseIcon()
end

--- Event callback on error
function UIPlayer:onError(err)
    self:_updatePlayPauseIcon()
end

-- =========================================================================
-- USER ACTION HANDLERS
-- =========================================================================

--- Toggle Play / Pause
function UIPlayer:onTogglePlayPause()
    if self.playback_queue then
        self.playback_queue:togglePlayPause()
        self:_updatePlayPauseIcon()
    end
end

--- Advance to next chunk
function UIPlayer:onNextChunk()
    if self.playback_queue then
        self.playback_queue:nextChunk()
    end
end

--- Return to previous chunk
function UIPlayer:onPrevChunk()
    if self.playback_queue then
        self.playback_queue:prevChunk()
    end
end

--- Advance to next page
function UIPlayer:onNextPage()
    if self.playback_queue then
        self.playback_queue:seekChunk(self.current_page + 1, 1)
    end
end

--- Return to previous page
function UIPlayer:onPrevPage()
    if self.playback_queue and self.current_page > 1 then
        self.playback_queue:seekChunk(self.current_page - 1, 1)
    end
end

--- Show popup dialog to choose playback speed directly (matches InputDialog in Settings)
function UIPlayer:showSpeedDialog()
    local this = self
    local cur_speed = self.audio_backend and self.audio_backend.speed or 1.0
    local input_dialog

    input_dialog = InputDialog:new{
        title = _("Tốc độ đọc (0.5x - 2.0x)"),
        input = tostring(cur_speed),
        input_hint = "1.0",
        buttons = {
            {
                {
                    text = _("Hủy"),
                    id = "cancel",
                    callback = function()
                        UIManager:close(input_dialog)
                        if UIManager and UIManager.setDirty then
                            pcall(UIManager.setDirty, UIManager, nil, "ui")
                        end
                    end,
                },
                {
                    text = _("Lưu"),
                    is_enter_default = true,
                    callback = function()
                        local val = tonumber(input_dialog:getInputText())
                        if val then
                            val = math.max(0.5, math.min(2.0, val))
                            if this.audio_backend then
                                this.audio_backend:setSpeed(val)
                            end
                            if this.settings then
                                this.settings:set("speed", val)
                                this.settings:save()
                            end
                            if this.speed_btn and this.speed_btn.setText then
                                this.speed_btn:setText(string.format(_("Tốc độ: %.1fx"), val))
                            end
                            if this.mini_label_btn and this.mini_label_btn.setText then
                                this.mini_label_btn:setText(string.format("%d/%d · %.1fx", this.current_index, this.total_on_page, val))
                            end
                        end
                        UIManager:close(input_dialog)
                        if this.control_bar and UIManager and UIManager.setDirty then
                            pcall(UIManager.setDirty, UIManager, this.control_bar, "ui")
                        end
                        -- Cleanly repaint uncovered screen area to avoid ghosting artifacts
                        if UIManager and UIManager.setDirty then
                            pcall(UIManager.setDirty, UIManager, nil, "ui")
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(input_dialog)
    if input_dialog.onShowKeyboard then
        input_dialog:onShowKeyboard()
    end
end

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

--- Show popup dialog to choose sleep timer directly (matches vertical single-column list)
function UIPlayer:showSleepTimerDialog()
    local this = self
    if not self.sleep_timer then return end
    local cur_mode = tostring(self.sleep_timer:getMode())
    local dialog

    local function selectTimer(mode)
        this.sleep_timer:setMode(mode)
        if this.sleep_timer_btn and this.sleep_timer_btn.setText then
            this.sleep_timer_btn:setText(this.sleep_timer:getDisplayText())
        end
        if dialog then
            UIManager:close(dialog)
        end
        if this.control_bar and UIManager and UIManager.setDirty then
            pcall(UIManager.setDirty, UIManager, this.control_bar, "ui")
        end
        -- Cleanly repaint uncovered screen area to avoid ghosting artifacts
        if UIManager and UIManager.setDirty then
            pcall(UIManager.setDirty, UIManager, nil, "ui")
        end
    end

    local buttons = {
        {
            {
                text = _("Tắt hẹn giờ") .. (cur_mode == "0" and "  ✔" or ""),
                align = "left",
                callback = function() selectTimer("0") end,
            },
        },
        {
            {
                text = _("15 phút") .. (cur_mode == "15" and "  ✔" or ""),
                align = "left",
                callback = function() selectTimer("15") end,
            },
        },
        {
            {
                text = _("30 phút") .. (cur_mode == "30" and "  ✔" or ""),
                align = "left",
                callback = function() selectTimer("30") end,
            },
        },
        {
            {
                text = _("45 phút") .. (cur_mode == "45" and "  ✔" or ""),
                align = "left",
                callback = function() selectTimer("45") end,
            },
        },
        {
            {
                text = _("Khi đọc hết trang hiện tại") .. (cur_mode == "page" and "  ✔" or ""),
                align = "left",
                callback = function() selectTimer("page") end,
            },
        },
        {
            {
                text = _("Đóng"),
                callback = function()
                    if dialog then
                        UIManager:close(dialog)
                        if UIManager.setDirty then
                            pcall(UIManager.setDirty, UIManager, nil, "ui")
                        end
                    end
                end,
            },
        },
    }

    dialog = ButtonDialog:new{
        title = _("Hẹn giờ tắt đọc"),
        buttons = buttons,
    }
    UIManager:show(dialog)
end

function UIPlayer:onCycleSleepTimer()
    if not self.sleep_timer then return end
    local modes = { "0", "15", "30", "45", "page" }
    local cur = tostring(self.sleep_timer:getMode())
    local next_m = modes[1]
    for i, m in ipairs(modes) do
        if m == cur then
            next_m = modes[(i % #modes) + 1]
            break
        end
    end
    self.sleep_timer:setMode(next_m)
    if self.sleep_timer_btn and self.sleep_timer_btn.setText then
        self.sleep_timer_btn:setText(self.sleep_timer:getDisplayText())
    end
end

--- Close player and stop playback
function UIPlayer:onClose()
    if self.playback_queue then
        self.playback_queue:stop()
    end
    self:hide()
end

return UIPlayer
