--[[
    tests/mock_koreader.lua - Mock KOReader runtime environment
    Enables running standalone unit tests without the full KOReader source code.
--]]

local MockKOReader = {}

-- 1. Mock G_reader_settings
function MockKOReader.createMockSettings(initial_data)
    local storage = {
        _data = initial_data or {},
        _saved = false,
        _flushed = false,
    }

    function storage:readSetting(key)
        local val = self._data[key]
        if val == nil then return nil end
        local copy = {}
        if type(val) == "table" then
            for k, v in pairs(val) do copy[k] = v end
            return copy
        end
        return val
    end

    function storage:saveSetting(key, val)
        local copy = {}
        if type(val) == "table" then
            for k, v in pairs(val) do copy[k] = v end
            self._data[key] = copy
        else
            self._data[key] = val
        end
        self._saved = true
    end

    function storage:flush()
        self._flushed = true
    end

    return storage
end

-- 2. Mock Gettext
function MockKOReader.gettext(msg)
    return msg
end

-- 3. Mock WidgetContainer and UI system
local WidgetContainer = {}
WidgetContainer.__index = WidgetContainer

function WidgetContainer:extend(tbl)
    local sub = tbl or {}
    setmetatable(sub, { __index = self })
    sub.__index = sub
    function sub:new(o)
        local inst = setmetatable(o or {}, sub)
        return inst
    end
    return sub
end

local UIManager = {
    _shown_widgets = {},
    _closed_widgets = {},
    _scheduled_tasks = {},
    _current_time = 0,
    _dirty_calls = {},
}

function UIManager:show(widget)
    table.insert(self._shown_widgets, widget)
end

function UIManager:close(widget)
    table.insert(self._closed_widgets, widget)
end

function UIManager:setDirty(widget, refresh_type, rects)
    table.insert(self._dirty_calls, {
        widget = widget,
        refresh_type = refresh_type or "full",
        rects = rects or {},
    })
end

function UIManager:scheduleIn(delay, func)
    local task = {
        delay = delay or 0,
        func = func,
        trigger_time = self._current_time + (delay or 0),
        cancelled = false,
    }
    table.insert(self._scheduled_tasks, task)
    return task
end

function UIManager:nextTick(func, ...)
    return self:scheduleIn(0, func, ...)
end

function UIManager:unschedule(task)
    if task then
        task.cancelled = true
    end
end

function UIManager:tick(seconds)
    local dt = seconds or 0.05
    self._current_time = self._current_time + dt
    local remaining = {}
    -- Sort or execute ready tasks
    for _, task in ipairs(self._scheduled_tasks) do
        if not task.cancelled then
            if self._current_time >= task.trigger_time then
                local ok, err = pcall(task.func)
                if not ok and _G.logger and _G.logger.err then
                    _G.logger.err("Mock UIManager task error: " .. tostring(err))
                end
            else
                table.insert(remaining, task)
            end
        end
    end
    self._scheduled_tasks = remaining
end

function UIManager:runAllScheduled(max_iterations)
    local iter = 0
    max_iterations = max_iterations or 100
    while #self._scheduled_tasks > 0 and iter < max_iterations do
        iter = iter + 1
        self:tick(0.05)
    end
end

function UIManager:reset()
    self._shown_widgets = {}
    self._closed_widgets = {}
    self._scheduled_tasks = {}
    self._current_time = 0
    self._dirty_calls = {}
end

local Blitbuffer = {
    COLOR_WHITE  = 0xFFFFFF,
    COLOR_BLACK  = 0x000000,
    COLOR_GRAY_E = 0xEEEEEE,
}

local Screen = {
    getWidth = function() return 600 end,
    getHeight = function() return 800 end,
    scaleBySize = function(self, px) return px end,
}

local Size = {
    border = {
        thin = 1,
        medium = 2,
    },
    padding = {
        default = 5,
    },
}

local MockWidget = {}
MockWidget.__index = MockWidget

function MockWidget:new(o)
    local inst = setmetatable(o or {}, self)
    inst._children = inst._children or {}
    return inst
end

function MockWidget:getInputText()
    return self.input or ""
end

function MockWidget:onShowKeyboard()
    self._keyboard_shown = true
end

function MockWidget:setText(text)
    self.text = text
end

function MockWidget:setIcon(icon)
    self.icon = icon
end

local MockDevice = {
    _platform = "desktop",
    _standby_prevented = false,
}

function MockDevice:setPlatform(platform)
    self._platform = platform or "desktop"
end

function MockDevice:preventStandby(enable)
    self._standby_prevented = enable
end

function MockDevice:isAndroid()
    return self._platform == "android"
end

function MockDevice:isLinux()
    return self._platform == "linux" or self._platform == "kobo" or self._platform == "kindle"
end

function MockDevice:isKobo()
    return self._platform == "kobo"
end

function MockDevice:isKindle()
    return self._platform == "kindle"
end

function MockDevice:isDesktop()
    return self._platform == "desktop"
end

function MockDevice:isPocketBook()
    return self._platform == "pocketbook"
end

-- 4. Setup global KOReader environment and mock packages
function MockKOReader.installGlobals()
    _G._ = MockKOReader.gettext
    _G.G_reader_settings = MockKOReader.createMockSettings()
    _G.Device = MockDevice
    _G.logger = {
        dbg = function(...) end,
        info = function(...) end,
        warn = function(...) end,
        err = function(...) end,
    }

    -- Mock KOReader require() modules
    package.preload["gettext"] = function()
        return MockKOReader.gettext
    end
    package.preload["device"] = function()
        return MockDevice
    end
    package.preload["device/screen"] = function()
        return Screen
    end
    package.preload["ui/size"] = function()
        return Size
    end
    package.preload["ffi/blitbuffer"] = function()
        return Blitbuffer
    end
    package.preload["ui/widget/widgetcontainer"] = function()
        return WidgetContainer
    end
    package.preload["ui/uimanager"] = function()
        return UIManager
    end
    package.preload["ui/widget/infomessage"] = function()
        return MockWidget
    end
    package.preload["ui/widget/inputdialog"] = function()
        return MockWidget
    end
    package.preload["ui/widget/buttondialog"] = function()
        return MockWidget
    end
    package.preload["ui/widget/framecontainer"] = function()
        return MockWidget
    end
    package.preload["ui/widget/verticalgroup"] = function()
        return MockWidget
    end
    package.preload["ui/widget/horizontalgroup"] = function()
        return MockWidget
    end
    package.preload["ui/widget/iconbutton"] = function()
        return MockWidget
    end
    package.preload["ui/widget/textwidget"] = function()
        return MockWidget
    end
    package.preload["ui/widget/button"] = function()
        return MockWidget
    end
    package.preload["ui/widget/container/bottomcontainer"] = function()
        return MockWidget
    end
    package.preload["ui/widget/container/centercontainer"] = function()
        return MockWidget
    end
    package.preload["ui/widget/horizontalspan"] = function()
        return MockWidget
    end
    package.preload["ui/widget/verticalspan"] = function()
        return MockWidget
    end
    package.preload["ui/geometry"] = function()
        return {
            new = function(self, o) return o or {} end,
        }
    end

    _G.Screen = Screen
    _G.Blitbuffer = Blitbuffer
    _G.Size = Size
end

-- 5. Mock Document Engines (Crengine & MuPDF)
function MockKOReader.createMockCrengineDocument(sample_text, sample_bboxes)
    return {
        _engine = "crengine",
        file = "/sdcard/books/sample_crengine.epub",
        getMD5 = function(self) return "md5_crengine_123" end,
        getTextFromPositions = function(self, page)
            return sample_text or ""
        end,
        getWordBBoxes = function(self, page)
            return sample_bboxes or {
                { x = 20, y = 50, w = 150, h = 20 },
                { x = 180, y = 50, w = 120, h = 20 },
            }
        end,
        getCurrentPage = function(self) return 1 end,
    }
end

function MockKOReader.createMockMuPDFDocument(sample_text, sample_bboxes)
    return {
        _engine = "mupdf",
        file = "/sdcard/books/sample_mupdf.pdf",
        getMD5 = function(self) return "md5_mupdf_456" end,
        getPageText = function(self, page)
            return sample_text or ""
        end,
        getTextWordBoxes = function(self, page)
            return sample_bboxes or {
                { x = 40, y = 80, w = 220, h = 22 },
                { x = 40, y = 110, w = 180, h = 22 },
            }
        end,
        getCurrentPage = function(self) return 1 end,
    }
end

--- Mock multi-page document (supports testing page turns & cross-page preloads)
function MockKOReader.createMockMultiPageDocument(pages_text_table, total_pages, book_md5)
    pages_text_table = pages_text_table or {}
    total_pages = total_pages or #pages_text_table
    local current_page = 1
    local md5 = book_md5 or "md5_multipage_789"

    return {
        _engine = "crengine",
        file = "/sdcard/books/multipage_book.epub",
        getMD5 = function(self) return md5 end,
        _pages = pages_text_table,
        _total_pages = total_pages,
        getTextFromPositions = function(self, page)
            local p = page or current_page
            return self._pages[p] or ""
        end,
        getWordBBoxes = function(self, page)
            return {
                { x = 20, y = 50, w = 200, h = 20 },
                { x = 20, y = 80, w = 180, h = 20 },
            }
        end,
        getCurrentPage = function(self)
            return current_page
        end,
        getPageCount = function(self)
            return self._total_pages
        end,
        _setCurrentPage = function(self, p)
            current_page = p
        end,
    }
end

--- Mock Reader UI object (supports onNextPage, onPrevPage, gotoPage, view.state.page, view highlight)
function MockKOReader.createMockUI(doc, initial_page)
    initial_page = initial_page or 1
    local mock_ui = {
        document = doc,
        view = {
            state = {
                page = initial_page
            },
            _highlight = nil,
            _highlight_color = nil,
            setHighlight = function(self, bboxes, color)
                self._highlight = bboxes
                self._highlight_color = color
            end,
            clearHighlight = function(self)
                self._highlight = nil
                self._highlight_color = nil
            end,
        },
        _page_turns = 0,
        menu = {
            registerToMainMenu = function() end
        },
    }

    function mock_ui:onNextPage()
        self.view.state.page = self.view.state.page + 1
        self._page_turns = self._page_turns + 1
        if self.document and self.document._setCurrentPage then
            self.document:_setCurrentPage(self.view.state.page)
        end
        return true
    end

    function mock_ui:onPrevPage()
        if self.view.state.page > 1 then
            self.view.state.page = self.view.state.page - 1
            self._page_turns = self._page_turns + 1
            if self.document and self.document._setCurrentPage then
                self.document:_setCurrentPage(self.view.state.page)
            end
        end
        return true
    end

    function mock_ui:gotoPage(p)
        self.view.state.page = p
        self._page_turns = self._page_turns + 1
        if self.document and self.document._setCurrentPage then
            self.document:_setCurrentPage(p)
        end
        return true
    end

    function mock_ui:handleEvent(ev)
        if ev and ev.name == "GotoPage" and ev.page then
            return self:gotoPage(ev.page)
        end
        return false
    end

    return mock_ui
end

MockKOReader.WidgetContainer = WidgetContainer
MockKOReader.UIManager = UIManager

return MockKOReader
