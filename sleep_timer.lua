--[[
    sleep_timer.lua - Sleep Timer module for KOReader TTS Plugin
    Supported modes:
      - 0: Off
      - 15, 30, 45: Minutes countdown
      - "page": Auto stop at the end of current page
      - "chapter": Auto stop at the end of current chapter
--]]

local ok_uimanager, UIManager = pcall(require, "ui/uimanager")
if not ok_uimanager or not UIManager then
    UIManager = {
        scheduleIn = function(self, delay, func)
            if type(func) == "function" then func() end
        end
    }
end

local ok_gettext, _ = pcall(require, "gettext")
if not ok_gettext or type(_) ~= "function" then
    _ = function(msg) return msg end
end

local SleepTimer = {}
SleepTimer.__index = SleepTimer

-- Preset timer modes for cycling
SleepTimer.MODES = { "0", "15", "30", "45", "page" }

--- Initialize SleepTimer
function SleepTimer:new(opts)
    local instance = setmetatable({}, self)
    opts = opts or {}

    instance.uimanager = opts.uimanager or UIManager
    instance.on_timeout = opts.on_timeout
    instance.on_tick = opts.on_tick

    instance.mode = "0"
    instance.remaining_seconds = 0
    instance._timer_task = nil

    return instance
end

--- Set timer mode
-- @param mode: "0" | "15" | "30" | "45" | "page" | "chapter" (or number)
function SleepTimer:setMode(mode)
    mode = tostring(mode or "0")
    self:cancel()
    self.mode = mode

    local minutes = tonumber(mode)
    if minutes and minutes > 0 then
        self.remaining_seconds = minutes * 60
        self:_startCountdown()
    elseif mode == "page" or mode == "chapter" then
        self.remaining_seconds = 0
    else
        self.mode = "0"
        self.remaining_seconds = 0
    end
end

--- Get current timer mode
function SleepTimer:getMode()
    return self.mode
end

--- Get remaining countdown seconds
function SleepTimer:getRemainingSeconds()
    return self.remaining_seconds
end

--- Get concise display string for UI button
function SleepTimer:getDisplayText()
    if self.mode == "0" or self.mode == 0 then
        return _("Hẹn giờ: Tắt")
    elseif self.mode == "page" then
        return _("Hẹn giờ: Hết trang")
    elseif self.mode == "chapter" then
        return _("Hẹn giờ: Hết chương")
    else
        local mins = math.ceil(self.remaining_seconds / 60)
        if mins > 0 then
            return string.format(_("Hẹn giờ: %dp"), mins)
        else
            return string.format(_("Hẹn giờ: %ds"), self.remaining_seconds)
        end
    end
end

--- 1-second interval countdown loop
function SleepTimer:_startCountdown()
    local this = self
    local function tick()
        if this.mode == "0" or this.remaining_seconds <= 0 then
            return
        end

        this.remaining_seconds = this.remaining_seconds - 1

        if this.on_tick then
            pcall(this.on_tick, this.remaining_seconds)
        end

        if this.remaining_seconds <= 0 then
            this:_triggerTimeout("timer")
        else
            this._timer_task = this.uimanager:scheduleIn(1, tick)
        end
    end

    self._timer_task = self.uimanager:scheduleIn(1, tick)
end

--- Trigger timeout callback
function SleepTimer:_triggerTimeout(reason)
    self:cancel()
    if self.on_timeout then
        pcall(self.on_timeout, reason)
    end
end

--- Listen to page turn event from PlaybackQueue
function SleepTimer:onPageTurn(new_page)
    if self.mode == "page" then
        self:_triggerTimeout("page")
    end
end

--- Listen to chapter change event
function SleepTimer:onChapterChange(new_chapter)
    if self.mode == "chapter" then
        self:_triggerTimeout("chapter")
    end
end

--- Cancel active timer
function SleepTimer:cancel()
    if self._timer_task and self.uimanager and self.uimanager.unschedule then
        pcall(self.uimanager.unschedule, self.uimanager, self._timer_task)
    end
    self._timer_task = nil
    self.remaining_seconds = 0
    if self.mode ~= "page" and self.mode ~= "chapter" then
        self.mode = "0"
    end
end

return SleepTimer
