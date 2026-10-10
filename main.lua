--[[
    main.lua - KOReader TTS Plugin Entry Point
    Plugin: koreader_tts
    Inherits from WidgetContainer, manages plugin lifecycle and menu integration.
--]]

-- Ensure plugin directory is in package.path so internal modules can be required
local plugin_path = debug.getinfo(1, "S").source:match("@?(.*[/\\\\])")
if plugin_path and not package.path:find(plugin_path, 1, true) then
    package.path = plugin_path .. "?.lua;" .. plugin_path .. "?/init.lua;" .. package.path
end

local ok_wc, WidgetContainer = pcall(require, "ui/widget/container/widgetcontainer")
if not ok_wc or not WidgetContainer then
    WidgetContainer = require("ui/widget/widgetcontainer")
end

local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local ButtonDialog = require("ui/widget/buttondialog")

local Settings = require("src.service.settings_manager")
local TextChunker = require("src.service.document_chunker")
local EngineFactory = require("src.engine.engine_factory")
local AudioBackend = require("src.bridge.fallback.audio_backend")
local PlaybackQueue = require("src.service.reading_coordinator")
local UIPlayer = require("src.ui.player_widget")

local ok_gettext, _ = pcall(require, "gettext")
if not ok_gettext or type(_) ~= "function" then
    _ = function(msg) return msg end
end

local KoreaderTTS = WidgetContainer:extend{
    name = "koreader_tts",
    is_doc_only = true,
}

--- Initialize plugin when loaded into KOReader
function KoreaderTTS:init()
    local ok_log, logger = pcall(require, "logger")
    if ok_log and logger and logger.warn then
        logger.warn("KoreaderTTS:init() called! ui=", tostring(self.ui))
    end
    self.settings = Settings:new()
    local cache_dir = "cache/tts"
    local ok_ds, DataStorage = pcall(require, "datastorage")
    if ok_ds and DataStorage and type(DataStorage.getDataDir) == "function" then
        local data_dir = DataStorage:getDataDir()
        if data_dir and data_dir ~= "" then
            cache_dir = data_dir .. "/cache/tts"
        end
    end

    self.engine = EngineFactory.create{
        server_url = self.settings:get("server_url"),
        voice = self.settings:get("voice"),
        audio_format = self.settings:get("audio_format"),
        speed = self.settings:get("speed"),
        api_key = self.settings:get("api_key"),
        cache_dir = cache_dir,
        preload_count = self.settings:get("preload_count") or 1,
        plugin_dir = plugin_path,
    }
    self.tts_service = self.engine

    self.audio_backend = AudioBackend:new{
        backend_type = self.settings:get("audio_backend"),
        speed = self.settings:get("speed"),
    }

    local this = self
    local chunker = TextChunker:new{
        min_chars = self.settings:get("min_chunk_chars") or 120,
        max_chars = self.settings:get("max_chunk_chars") or 300,
        filter_footnotes = self.settings:get("filter_footnotes"),
        custom_mappings = self.settings:getCustomMappings(),
    }
    self.chunker = chunker

    self.playback_queue = PlaybackQueue:new{
        ui = self.ui,
        document = self.ui and self.ui.document,
        chunker = chunker,
        engine = self.engine,
        tts_service = self.tts_service,
        audio_backend = self.audio_backend,
        settings = self.settings,
        on_chunk_change = function(chunk, page, index, total)
            if _G.logger and _G.logger.info then
                _G.logger.info(string.format("[TTS Queue] Page %d | Chunk %d/%d: %s", page, index, total, chunk.text))
            end
            if this.ui_player then
                this.ui_player:onChunkChange(chunk, page, index, total)
            end
        end,
        on_state_change = function(old_state, new_state)
            if this.ui_player then
                this.ui_player:onStateChange(old_state, new_state)
            end
        end,
        on_buffer_change = function()
            if this.ui_player and this.ui_player.onBufferChange then
                this.ui_player:onBufferChange()
            end
        end,
        on_page_turn = function(new_page)
            if this.ui_player then
                this.ui_player:onPageTurn(new_page)
            end
            UIManager:show(InfoMessage:new{
                text = string.format(_("Tự động lật sang trang %d"), new_page),
                timeout = 1,
            })
        end,
        on_finished = function()
            if this.ui_player then
                this.ui_player:onFinished()
            end
            UIManager:show(InfoMessage:new{
                text = _("Đã đọc xong toàn bộ văn bản."),
                timeout = 3,
            })
        end,
        on_error = function(err)
            if this.ui_player then
                this.ui_player:onError(err)
            end
            UIManager:show(InfoMessage:new{
                text = string.format(_("Lỗi phát âm thanh:\n%s"), tostring(err)),
                timeout = 4,
            })
        end,
    }

    self.ui_player = UIPlayer:new{
        ui = self.ui,
        view = self.view or (self.ui and self.ui.view),
        playback_queue = self.playback_queue,
        settings = self.settings,
        audio_backend = self.audio_backend,
        chunker = chunker,
    }

    if self.ui and self.ui.menu and type(self.ui.menu.registerToMainMenu) == "function" then
        self.ui.menu:registerToMainMenu(self)
        self.ui.menu.tab_item_table = nil
    end

    if self.ui and self.ui.dictionary and type(self.ui.dictionary.addToDictButtons) == "function" then
        self.ui.dictionary:addToDictButtons({
            id = "koreader_tts_read",
            text = _("▶ Đọc từ đây"),
            font_bold = true,
            callback = function(dict_popup)
                if dict_popup then UIManager:close(dict_popup) end
                UIManager:scheduleIn(0.2, function()
                    this:onStartTTS()
                end)
            end,
        })
    end
end

--- Hook for older and newer KOReader dictionary popup button registration
function KoreaderTTS:onDictButtonsReady(dict_popup, buttons)
    if not dict_popup or dict_popup.is_wiki_fullpage then return end
    local this = self
    table.insert(buttons, {{
        id = "koreader_tts_read",
        text = _("▶ Đọc từ đây"),
        callback = function()
            UIManager:close(dict_popup)
            UIManager:scheduleIn(0.2, function()
                this:onStartTTS()
            end)
        end,
    }})
end

--- Determine unique identifier for current book (Task 6.2)
function KoreaderTTS:getCurrentBookId()
    local doc = self.ui and self.ui.document
    if not doc then return nil end
    if type(doc.getMD5) == "function" then
        local ok, md5 = pcall(doc.getMD5, doc)
        if ok and md5 and md5 ~= "" then return tostring(md5) end
    end
    return doc.file or (self.ui and self.ui.doc_path) or doc.path or "current_book"
end

--- Hook registered to KOReader Reader Top Menu
-- @param menu_items Menu items table
function KoreaderTTS:addToMainMenu(menu_items)
    local ok_log, logger = pcall(require, "logger")
    if ok_log and logger and logger.warn then
        logger.warn("KoreaderTTS:addToMainMenu() called!")
    end
    local this = self
    local sub_items = {
        {
            text = _("▶ Đọc từ đầu trang này"),
            callback = function(touchmenu_instance)
                if touchmenu_instance then touchmenu_instance:closeMenu() end
                this:onStartTTS()
            end,
        },
    }

    -- Check for previous session of current book (Task 6.2)
    local cur_book_id = self:getCurrentBookId()
    local last_book_id = self.settings:get("last_book_id")
    local last_page = self.settings:get("last_page") or 1
    local last_chunk = self.settings:get("last_chunk_index") or 1

    if cur_book_id and last_book_id and cur_book_id == last_book_id and (last_page > 1 or last_chunk > 1) then
        table.insert(sub_items, {
            text = string.format(_("⏯ Đọc tiếp tục phiên trước (Trang %d · Câu %d)"), last_page, last_chunk),
            callback = function(touchmenu_instance)
                if touchmenu_instance then touchmenu_instance:closeMenu() end
                this:onResumePreviousSession()
            end,
        })
    end

    table.insert(sub_items, {
        text = _("⏲ Hẹn giờ tắt đọc"),
        callback = function(touchmenu_instance)
            if touchmenu_instance then
                touchmenu_instance:closeMenu()
                UIManager:scheduleIn(0.1, function()
                    this:showSleepTimerDialog()
                end)
            else
                this:showSleepTimerDialog()
            end
        end,
    })
    table.insert(sub_items, {
        text = _("⚙ Cài đặt tiện ích"),
        callback = function(touchmenu_instance)
            local ok_l, log = pcall(require, "logger")
            if ok_l and log then log.warn("TTS: Cài đặt tiện ích callback invoked!") end
            if touchmenu_instance then
                touchmenu_instance:closeMenu()
                UIManager:scheduleIn(0.1, function()
                    this:showSettingsDialog()
                end)
            else
                this:showSettingsDialog()
            end
        end,
    })

    menu_items.koreader_tts = {
        text = _("Đọc bằng giọng nói"),
        sorting_hint = "tools",
        sub_item_table = sub_items,
    }
end

--- Synchronize when the user turns page manually in KOReader reader view
function KoreaderTTS:onPageUpdate(page_number)
    self:_handleUserPageTurn(page_number)
end

function KoreaderTTS:onGotoPage(page_number)
    self:_handleUserPageTurn(page_number)
end

function KoreaderTTS:_handleUserPageTurn(page_number)
    if not page_number or page_number <= 0 then return end
    if not self.playback_queue then return end

    if self._page_turn_timer and UIManager.unschedule then
        UIManager:unschedule(self._page_turn_timer)
        self._page_turn_timer = nil
    end

    local this = self
    self._page_turn_timer = UIManager:scheduleIn(0.2, function()
        this._page_turn_timer = nil
        if not this.playback_queue then return end

        local cur_p = this.playback_queue:getCurrentPage()
        if cur_p ~= page_number then
            if this.playback_queue:getState() == "PLAYING" then
                -- Actively reading: jump to new page sentence 1 seamlessly!
                this.playback_queue:seekChunk(page_number, 1)
            else
                -- Paused or idle: update coordinates and widget to match screen view
                this.playback_queue.current_page = page_number
                this.playback_queue.current_index = 1
                this.playback_queue._page_cache[page_number] = nil
                local chunks = this.playback_queue:_getPageChunks(page_number)
                local chunk = chunks and chunks[1]
                if this.ui_player and this.ui_player.visible then
                    this.ui_player:onChunkChange(chunk, page_number, 1, #chunks)
                end
            end
        end
    end)
end

--- Get current active page number across all KOReader view modes
function KoreaderTTS:getCurrentPageNumber()
    if self.ui and type(self.ui.getCurrentPage) == "function" then
        local ok, p = pcall(self.ui.getCurrentPage, self.ui)
        if ok and p and p > 0 then return p end
    end
    if self.ui and self.ui.paging and self.ui.paging.current_page then
        return self.ui.paging.current_page
    end
    if self.view and self.view.state and self.view.state.page then
        return self.view.state.page
    end
    local doc = self.ui and self.ui.document
    if doc then
        if type(doc.getCurrentPage) == "function" then
            local ok, p = pcall(doc.getCurrentPage, doc)
            if ok and p then
                return (p >= 0 and p + 1) or p
            end
        end
        if doc.info and doc.info.current_page then
            return doc.info.current_page
        end
    end
    return 1
end

--- Get total page count of active document
function KoreaderTTS:getTotalPageCount()
    if self.ui and type(self.ui.getPageCount) == "function" then
        local ok, count = pcall(self.ui.getPageCount, self.ui)
        if ok and count and count > 0 then return count end
    end
    if self.ui and self.ui.paging and self.ui.paging.total_pages then
        return self.ui.paging.total_pages
    end
    local doc = self.ui and self.ui.document
    if doc then
        if type(doc.getPageCount) == "function" then
            local ok, count = pcall(doc.getPageCount, doc)
            if ok and count and count > 0 then return count end
        end
        if doc.info and doc.info.number_of_pages then
            return doc.info.number_of_pages
        end
    end
    return 9999
end

--- Resume previous reading session (Task 6.2)
function KoreaderTTS:onResumePreviousSession()
    local last_page = self.settings:get("last_page") or 1
    local last_chunk = self.settings:get("last_chunk_index") or 1

    local document = self.ui and self.ui.document
    if not self.chunker then
        self.chunker = TextChunker:new{
            min_chars = 30,
            max_chars = self.settings:get("max_chunk_chars") or 300,
            filter_footnotes = self.settings:get("filter_footnotes"),
            custom_mappings = self.settings:getCustomMappings(),
        }
    end

    if self.playback_queue then
        self.playback_queue.document = document
        self.playback_queue.chunker = self.chunker
        if self.ui_player then
            self.ui_player.view = self.view or (self.ui and self.ui.view)
            self.ui_player:show()
        end
        self.playback_queue:start(last_page, last_chunk)
    end
end

--- Sleep timer settings dialog (Task 6.1)
function KoreaderTTS:showSleepTimerDialog()
    local this = self
    local timer = self.ui_player and self.ui_player.sleep_timer
    local cur_mode = timer and tostring(timer:getMode()) or "0"

    local dialog
    local function selectTimer(mode, label)
        if timer then
            timer:setMode(mode)
        end
        if this.ui_player and this.ui_player.sleep_timer_btn and this.ui_player.sleep_timer_btn.setText and timer then
            this.ui_player.sleep_timer_btn:setText(timer:getDisplayText())
        end
        UIManager:close(dialog)
        if UIManager and UIManager.setDirty then
            pcall(UIManager.setDirty, UIManager, nil, "ui")
        end
        UIManager:show(InfoMessage:new{
            text = string.format(_("Đã cài đặt hẹn giờ: %s"), label),
            timeout = 2,
        })
    end

    local buttons = {
        {
            {
                text = _("Tắt hẹn giờ") .. (cur_mode == "0" and "  ✔" or ""),
                align = "left",
                callback = function() selectTimer("0", _("Tắt")) end,
            },
        },
        {
            {
                text = _("15 phút") .. (cur_mode == "15" and "  ✔" or ""),
                align = "left",
                callback = function() selectTimer("15", _("15 phút")) end,
            },
        },
        {
            {
                text = _("30 phút") .. (cur_mode == "30" and "  ✔" or ""),
                align = "left",
                callback = function() selectTimer("30", _("30 phút")) end,
            },
        },
        {
            {
                text = _("45 phút") .. (cur_mode == "45" and "  ✔" or ""),
                align = "left",
                callback = function() selectTimer("45", _("45 phút")) end,
            },
        },
        {
            {
                text = _("Khi đọc hết trang hiện tại") .. (cur_mode == "page" and "  ✔" or ""),
                align = "left",
                callback = function() selectTimer("page", _("Hết trang")) end,
            },
        },
        {
            {
                text = _("Đóng"),
                callback = function() UIManager:close(dialog) end,
            },
        },
    }

    dialog = ButtonDialog:new{
        title = _("Hẹn giờ tắt đọc"),
        buttons = buttons,
    }
    UIManager:show(dialog)
end

--- Stop TTS playback
function KoreaderTTS:onStopTTS()
    if self.playback_queue then
        self.playback_queue:stop()
    end
    if self.ui_player then
        self.ui_player:hide()
    end
    if self.engine and self.engine.client and self.engine.client.clearCache then
        pcall(self.engine.client.clearCache, self.engine.client, 86400)
    end
    UIManager:show(InfoMessage:new{
        text = _("Đã dừng đọc."),
        timeout = 2,
    })
end

--- Test playback of first sentence on page (Task 3.3)
function KoreaderTTS:onTestSingleSentence()
    local ok_log, logger = pcall(require, "logger")
    if ok_log and logger and logger.warn then
        logger.warn("TTS: onTestSingleSentence() TRIGGERED!")
    end

    local document = self.ui and self.ui.document
    local current_page = self:getCurrentPageNumber()

    local chunker = TextChunker:new{
        min_chars = 30,
        max_chars = self.settings:get("max_chunk_chars") or 300,
        filter_footnotes = self.settings:get("filter_footnotes"),
        custom_mappings = self.settings:getCustomMappings(),
    }

    local test_text = nil
    local chunks = {}
    if document then
        chunks = chunker:extractPageChunks(document, current_page, self.ui)
        -- If current page has 0 chunks (cover/title/image page), scan forward up to 5 pages
        if #chunks == 0 then
            local total_pages = self:getTotalPageCount()
            for p = current_page + 1, math.min(current_page + 5, total_pages) do
                local next_chunks = chunker:extractPageChunks(document, p, self.ui)
                if #next_chunks > 0 then
                    chunks = next_chunks
                    current_page = p
                    break
                end
            end
        end
    end

    if #chunks > 0 then
        test_text = chunks[1].text
    else
        -- Fallback default test sentence when no book is open or book starts with blank/cover pages
        test_text = _("Chào mừng bạn đến với KOReader. Đây là câu thử nghiệm kết nối máy chủ và kiểm tra âm thanh.")
    end

    -- Pause active reading queue if playing
    if self.playback_queue and self.playback_queue:getState() == "PLAYING" then
        self.playback_queue:pause()
    end

    UIManager:show(InfoMessage:new{
        text = string.format(_("Đang tải âm thanh thử nghiệm...\n'%s'"), test_text),
        timeout = 2,
    })

    local this = self
    self.audio_backend:setSpeed(self.settings:get("speed"))

    self.engine:synthesizeSingle(test_text, function(success, result_or_err)
        if not success then
            UIManager:show(InfoMessage:new{
                text = string.format(_("Lỗi tải âm thanh từ máy chủ:\n%s"), tostring(result_or_err)),
                timeout = 5,
            })
            return
        end

        local wav_path = result_or_err
        this.audio_backend:play(wav_path, function(finished)
            if finished then
                UIManager:show(InfoMessage:new{
                    text = _("Đã phát xong câu thử nghiệm!"),
                    timeout = 2,
                })
            end
        end, { speed = this.settings:get("speed") })

        local driver = this.audio_backend._active_process or this.audio_backend.driver_name or "timer"
        UIManager:show(InfoMessage:new{
            text = string.format(_("Đang phát câu thử nghiệm... [%s]\n'%s'"), tostring(driver), test_text),
            timeout = 3,
        })
    end)
end

--- Start TTS reading session (Task 2.1 & Phase 4 Preload Queue)
function KoreaderTTS:onStartTTS()
    local document = self.ui and self.ui.document
    local current_page = self:getCurrentPageNumber()

    local ok_log, logger = pcall(require, "logger")
    if ok_log and logger and logger.warn then
        logger.warn(string.format("[TTS DEBUG] onStartTTS: current_page=%s, ui:getCurrentPage=%s, paging.current_page=%s, doc:getCurrentPage=%s",
            tostring(current_page),
            tostring(self.ui and type(self.ui.getCurrentPage) == "function" and self.ui:getCurrentPage()),
            tostring(self.ui and self.ui.paging and self.ui.paging.current_page),
            tostring(document and type(document.getCurrentPage) == "function" and document:getCurrentPage())
        ))
    end

    if self.audio_backend then
        self.audio_backend:setSpeed(self.settings:get("speed"))
    end

    local chunker = self.chunker or TextChunker:new{
        min_chars = self.settings:get("min_chunk_chars") or 120,
        max_chars = self.settings:get("max_chunk_chars") or 300,
        filter_footnotes = self.settings:get("filter_footnotes"),
        custom_mappings = self.settings:getCustomMappings(),
    }
    self.chunker = chunker

    local chunks = chunker:extractPageChunks(document, current_page, self.ui)
    if ok_log and logger and logger.warn then
        logger.warn(string.format("[TTS DEBUG] onStartTTS: page=%s, chunks_count=%d, first_chunk='%s'",
            tostring(current_page), #chunks, tostring(chunks[1] and chunks[1].text)))
    end

    -- If current page is empty (e.g. cover/title/illustration page), scan ahead up to 10 pages
    if #chunks == 0 and document then
        local total_pages = self:getTotalPageCount()
        for p = current_page + 1, math.min(current_page + 10, total_pages) do
            local next_chunks = chunker:extractPageChunks(document, p, self.ui)
            if #next_chunks > 0 then
                chunks = next_chunks
                current_page = p
                -- Turn reader page to match
                if self.ui then
                    pcall(function()
                        local ok_ev, Event = pcall(require, "ui/event")
                        if self.ui.paging and type(self.ui.paging.onGotoPage) == "function" then
                            self.ui.paging:onGotoPage(current_page)
                        elseif type(self.ui.gotoPage) == "function" then
                            self.ui:gotoPage(current_page)
                        elseif ok_ev and Event then
                            self.ui:handleEvent(Event:new("GotoPage", current_page))
                        end
                    end)
                end
                break
            end
        end
    end

    local chunk_count = #chunks

    -- Log extracted chunks for debugging (DoD 2.1)
    if _G.logger and type(_G.logger.info) == "function" then
        _G.logger.info(string.format("[TTS] Extracted page %d: found %d chunks.", current_page, chunk_count))
        for i, c in ipairs(chunks) do
            _G.logger.info(string.format("[TTS]   Chunk %d: %s (bboxes: %d)", i, c.text, #(c.bboxes or {})))
        end
    end

    local preview = (chunk_count > 0) and chunks[1].text or _("(Trang trống hoặc không có chữ)")
    local msg = string.format(
        _("Đọc giọng nói:\nTrang: %d | Tổng số câu: %d\nCâu 1: %s"),
        current_page, chunk_count, preview
    )
    UIManager:show(InfoMessage:new{
        text = msg,
        timeout = 3,
    })

    -- Start preload queue from chunk 1 of current page
    if self.playback_queue and chunk_count > 0 then
        self.playback_queue.document = document
        self.playback_queue.chunker = chunker
        if self.ui_player then
            self.ui_player.view = self.view or (self.ui and self.ui.view)
            pcall(function() self.ui_player:show() end)
        end
        self.playback_queue:start(current_page, 1)
    end

    return chunks
end

--- Hook into KOReader text selection menu (Task 5.4)
function KoreaderTTS:addToHighlightMenu(menu_items, selected_text)
    if type(menu_items) == "table" and selected_text and selected_text ~= "" then
        table.insert(menu_items, {
            text = _("🔊 Đọc bằng giọng nói"),
            callback = function()
                self:onReadSelectedText(selected_text)
            end,
        })
    end
end

--- Read selected text snippet independently (Task 5.4)
function KoreaderTTS:onReadSelectedText(selected_text)
    if not selected_text or selected_text == "" then return end

    local chunker = self.chunker or TextChunker:new()
    local cleaned = chunker:sanitize(selected_text)
    cleaned = chunker:normalizePronunciation(cleaned, self.settings:getCustomMappings())

    if cleaned == "" then return end

    -- Pause active book reading queue if playing
    if self.playback_queue and self.playback_queue:getState() == "PLAYING" then
        self.playback_queue:pause()
    end

    UIManager:show(InfoMessage:new{
        text = string.format(_("Đang tải đoạn chọn:\n'%s'"), cleaned:sub(1, 60) .. "..."),
        timeout = 2,
    })

    local this = self
    self.engine:synthesizeSingle(cleaned, function(success, result_or_err)
        if not success then
            UIManager:show(InfoMessage:new{
                text = string.format(_("Lỗi tải âm thanh đoạn chọn:\n%s"), tostring(result_or_err)),
                timeout = 4,
            })
            return
        end

        UIManager:show(InfoMessage:new{
            text = _("Đang phát đoạn chọn..."),
            timeout = 1,
        })

        this.audio_backend:play(result_or_err, function(finished)
            if finished then
                UIManager:show(InfoMessage:new{
                    text = _("Đã đọc xong đoạn văn bản được chọn!"),
                    timeout = 2,
                })
            end
        end, { speed = this.settings:get("speed") })
    end)
end

--- Pronunciation Dictionary Management Dialog (CRUD UI)
function KoreaderTTS:showWordMappingDialog()
    local this = self
    local custom_mappings = this.settings:getCustomMappings()

    -- 1. Open add new mapping dialog
    local function openAddWordDialog()
        local word_dialog
        word_dialog = InputDialog:new{
            title = _("Nhập từ gốc (viết tắt / từ khó)"),
            hint = "AI, TP.HCM, CNTT...",
            buttons = {
                {
                    {
                        text = _("Hủy"),
                        callback = function()
                            UIManager:close(word_dialog)
                            this:showWordMappingDialog()
                        end,
                    },
                    {
                        text = _("Tiếp tục"),
                        is_enter_default = true,
                        callback = function()
                            local orig_word = word_dialog:getInputText()
                            UIManager:close(word_dialog)
                            if orig_word and orig_word ~= "" then
                                -- Open replacement input dialog
                                local repl_dialog
                                repl_dialog = InputDialog:new{
                                    title = string.format(_("Từ đọc thay thế cho '%s'"), orig_word),
                                    hint = _("Ví dụ: Trí tuệ nhân tạo"),
                                    buttons = {
                                        {
                                            {
                                                text = _("Hủy"),
                                                callback = function()
                                                    UIManager:close(repl_dialog)
                                                    this:showWordMappingDialog()
                                                end,
                                            },
                                            {
                                                text = _("Lưu"),
                                                is_enter_default = true,
                                                callback = function()
                                                    local repl_word = repl_dialog:getInputText()
                                                    UIManager:close(repl_dialog)
                                                    if repl_word and repl_word ~= "" then
                                                        this.settings:setWordMapping(orig_word, repl_word)
                                                        this.settings:save()
                                                        UIManager:show(InfoMessage:new{
                                                            text = string.format(_("Đã thêm: %s ➔ %s"), orig_word, repl_word),
                                                            timeout = 2,
                                                        })
                                                    end
                                                    this:showWordMappingDialog()
                                                end,
                                            },
                                        },
                                    },
                                }
                                UIManager:show(repl_dialog)
                            else
                                this:showWordMappingDialog()
                            end
                        end,
                    },
                },
            },
        }
        UIManager:show(word_dialog)
    end

    -- 2. Open edit/delete existing mapping dialog
    local function openEditOrDeleteDialog(orig_word, current_repl)
        local action_dialog
        action_dialog = ButtonDialog:new{
            title = string.format(_("Từ điển: %s ➔ %s"), orig_word, current_repl),
            buttons = {
                {
                    {
                        text = _("Sửa từ đọc"),
                        align = "left",
                        callback = function()
                            UIManager:close(action_dialog)
                            local edit_dialog
                            edit_dialog = InputDialog:new{
                                title = string.format(_("Sửa cách đọc cho '%s'"), orig_word),
                                input = current_repl,
                                buttons = {
                                    {
                                        {
                                            text = _("Hủy"),
                                            callback = function()
                                                UIManager:close(edit_dialog)
                                                this:showWordMappingDialog()
                                            end,
                                        },
                                        {
                                            text = _("Lưu"),
                                            is_enter_default = true,
                                            callback = function()
                                                local new_repl = edit_dialog:getInputText()
                                                UIManager:close(edit_dialog)
                                                if new_repl and new_repl ~= "" then
                                                    this.settings:setWordMapping(orig_word, new_repl)
                                                    this.settings:save()
                                                    UIManager:show(InfoMessage:new{
                                                        text = _("Đã cập nhật cách đọc thành công!"),
                                                        timeout = 2,
                                                    })
                                                end
                                                this:showWordMappingDialog()
                                            end,
                                        },
                                    },
                                },
                            }
                            UIManager:show(edit_dialog)
                        end,
                    },
                    {
                        text = _("Xóa từ này"),
                        align = "left",
                        callback = function()
                            UIManager:close(action_dialog)
                            this.settings:removeWordMapping(orig_word)
                            this.settings:save()
                            UIManager:show(InfoMessage:new{
                                text = string.format(_("Đã xóa mapping của '%s'."), orig_word),
                                timeout = 2,
                            })
                            this:showWordMappingDialog()
                        end,
                    },
                },
                {
                    {
                        text = _("Quay lại"),
                        callback = function()
                            UIManager:close(action_dialog)
                            this:showWordMappingDialog()
                        end,
                    },
                },
            },
        }
        UIManager:show(action_dialog)
    end

    -- Build button list for existing mappings
    local buttons = {
        {
            {
                text = _("+ Thêm từ mới"),
                align = "left",
                callback = function()
                    if this.word_mapping_dialog then
                        UIManager:close(this.word_mapping_dialog)
                    end
                    openAddWordDialog()
                end,
            },
        },
    }

    -- List custom user mappings
    for orig, repl in pairs(custom_mappings) do
        local w, r = orig, repl
        table.insert(buttons, {
            {
                text = string.format("• %s ➔ %s", w, r),
                align = "left",
                callback = function()
                    if this.word_mapping_dialog then
                        UIManager:close(this.word_mapping_dialog)
                    end
                    openEditOrDeleteDialog(w, r)
                end,
            },
        })
    end

    -- Reset to defaults and close buttons
    table.insert(buttons, {
        {
            text = _("Khôi phục từ điển mặc định"),
            callback = function()
                this.settings:resetWordMappings()
                this.settings:save()
                UIManager:close(this.word_mapping_dialog)
                UIManager:show(InfoMessage:new{
                    text = _("Đã xóa sạch từ tùy biến, khôi phục từ điển mặc định."),
                    timeout = 3,
                })
                this:showWordMappingDialog()
            end,
        },
        {
            text = _("Quay lại Cài đặt"),
            callback = function()
                UIManager:close(this.word_mapping_dialog)
                this.word_mapping_dialog = nil
                this:showSettingsDialog()
            end,
        },
    })

    this.word_mapping_dialog = ButtonDialog:new{
        title = _("Quản lý từ điển phát âm"),
        buttons = buttons,
    }
    UIManager:show(this.word_mapping_dialog)
end

--- Show main plugin settings dialog
function KoreaderTTS:showSettingsDialog()
    local ok_l, log = pcall(require, "logger")
    if ok_l and log then log.warn("TTS: showSettingsDialog() CALLED!") end
    local this = self

    if self.settings_dialog then
        pcall(UIManager.close, UIManager, self.settings_dialog)
        self.settings_dialog = nil
    end

    local openServerAndVoiceDialog

    local function openServerUrlInput()
        local input_dialog
        input_dialog = InputDialog:new{
            title = _("Địa chỉ máy chủ âm thanh"),
            input = this.settings:get("server_url") or "",
            input_hint = "https://api.openai.com/v1/audio/speech",
            buttons = {
                {
                    {
                        text = _("Hủy"),
                        id = "cancel",
                        callback = function()
                            UIManager:close(input_dialog)
                            UIManager:nextTick(function()
                                if openServerAndVoiceDialog then openServerAndVoiceDialog() end
                            end)
                        end,
                    },
                    {
                        text = _("Lưu"),
                        is_enter_default = true,
                        callback = function()
                            local val = input_dialog:getInputText()
                            if val and val ~= "" then
                                this.settings:set("server_url", val)
                                this.settings:save()
                                local updated_url = this.settings:get("server_url")
                                if this.engine and this.engine.updateConfig then
                                    this.engine:updateConfig({ server_url = updated_url })
                                end
                            end
                            UIManager:close(input_dialog)
                            UIManager:nextTick(function()
                                if openServerAndVoiceDialog then openServerAndVoiceDialog() end
                            end)
                        end,
                    },
                },
            },
        }
        UIManager:show(input_dialog)
        input_dialog:onShowKeyboard()
    end

    local function openVoiceInput()
        local input_dialog
        input_dialog = InputDialog:new{
            title = _("Chọn giọng đọc"),
            input = this.settings:get("voice") or "alloy",
            input_hint = "alloy",
            buttons = {
                {
                    {
                        text = _("Hủy"),
                        id = "cancel",
                        callback = function()
                            UIManager:close(input_dialog)
                            UIManager:nextTick(function()
                                if openServerAndVoiceDialog then openServerAndVoiceDialog() end
                            end)
                        end,
                    },
                    {
                        text = _("Lưu"),
                        is_enter_default = true,
                        callback = function()
                            local val = input_dialog:getInputText()
                            if val and val ~= "" then
                                this.settings:set("voice", val)
                                this.settings:save()
                                if this.engine and this.engine.updateConfig then
                                    this.engine:updateConfig({ voice = val })
                                end
                            end
                            UIManager:close(input_dialog)
                            UIManager:nextTick(function()
                                if openServerAndVoiceDialog then openServerAndVoiceDialog() end
                            end)
                        end,
                    },
                },
            },
        }
        UIManager:show(input_dialog)
        input_dialog:onShowKeyboard()
    end

    local openSpeedInput
    local openPreloadCountDialog
    local openAudioFormatDialog

    openAudioFormatDialog = function()
        local format_dialog
        local current_fmt = this.settings:get("audio_format") or "wav"

        local format_options = {
            { id = "wav",  title = _("WAV (Mặc định - Âm thanh gốc, phát tức thì)") },
            { id = "flac", title = _("FLAC (Chất lượng cao, tiết kiệm 70% dung lượng)") },
            { id = "mp3",  title = _("MP3 (Phổ biến, siêu nhẹ, nén 90%)") },
            { id = "opus", title = _("OPUS (Tối ưu nhất, siêu nhẹ, tải nhanh nhất)") },
        }

        local buttons = {}
        for _, opt in ipairs(format_options) do
            local is_selected = (opt.id == current_fmt)
            local prefix = is_selected and "● " or "○ "
            table.insert(buttons, {
                {
                    text = prefix .. opt.title,
                    align = "left",
                    callback = function()
                        this.settings:set("audio_format", opt.id)
                        this.settings:save()
                        if this.engine and this.engine.updateConfig then
                            this.engine:updateConfig({ audio_format = opt.id })
                        end
                        UIManager:close(format_dialog)
                        UIManager:nextTick(function()
                            if openServerAndVoiceDialog then openServerAndVoiceDialog() end
                        end)
                    end,
                }
            })
        end

        table.insert(buttons, {
            {
                text = _("Hủy"),
                id = "cancel",
                callback = function()
                    UIManager:close(format_dialog)
                    UIManager:nextTick(function()
                        if openServerAndVoiceDialog then openServerAndVoiceDialog() end
                    end)
                end,
            }
        })

        format_dialog = ButtonDialog:new{
            title = _("Chọn định dạng âm thanh"),
            buttons = buttons,
        }
        UIManager:show(format_dialog)
    end

    openServerAndVoiceDialog = function()
        local sv_dialog
        local current_server = this.settings:get("server_url") or ""
        local current_voice = this.settings:get("voice") or ""
        local current_speed = this.settings:get("speed") or 1.0
        local current_preload = this.settings:get("preload_count") or 1
        local current_format = this.settings:get("audio_format") or "wav"

        local sv_buttons = {
            {
                {
                    text = string.format(_("1. Địa chỉ Máy chủ: %s"), current_server),
                    align = "left",
                    callback = function()
                        UIManager:close(sv_dialog)
                        UIManager:nextTick(openServerUrlInput)
                    end,
                },
            },
            {
                {
                    text = string.format(_("2. Giọng đọc mặc định: %s"), current_voice),
                    align = "left",
                    callback = function()
                        UIManager:close(sv_dialog)
                        UIManager:nextTick(openVoiceInput)
                    end,
                },
            },
            {
                {
                    text = string.format(_("3. Tốc độ đọc: %.1fx"), current_speed),
                    align = "left",
                    callback = function()
                        UIManager:close(sv_dialog)
                        UIManager:nextTick(openSpeedInput)
                    end,
                },
            },
            {
                {
                    text = string.format(_("4. Số câu tải trước: %d câu"), current_preload),
                    align = "left",
                    callback = function()
                        UIManager:close(sv_dialog)
                        UIManager:nextTick(openPreloadCountDialog)
                    end,
                },
            },
            {
                {
                    text = string.format(_("5. Định dạng âm thanh: %s"), (current_format or "wav"):upper()),
                    align = "left",
                    callback = function()
                        UIManager:close(sv_dialog)
                        UIManager:nextTick(openAudioFormatDialog)
                    end,
                },
            },
            {
                {
                    text = _("6. Phát thử âm thanh"),
                    align = "left",
                    callback = function()
                        this:onTestSingleSentence()
                    end,
                },
            },
            {
                {
                    text = _("Quay lại Cài đặt"),
                    callback = function()
                        UIManager:close(sv_dialog)
                        UIManager:nextTick(function()
                            this:showSettingsDialog()
                        end)
                    end,
                },
            },
        }

        sv_dialog = ButtonDialog:new{
            title = _("Cài đặt Máy chủ, Giọng đọc & Tốc độ"),
            buttons = sv_buttons,
        }
        UIManager:show(sv_dialog)
    end

    openPreloadCountDialog = function()
        local input_dialog
        local cur_count = this.settings:get("preload_count") or 1
        input_dialog = InputDialog:new{
            title = _("Số câu tải trước (1 - 7)"),
            input = tostring(cur_count),
            input_type = "number",
            input_hint = "1",
            buttons = {
                {
                    {
                        text = _("Hủy"),
                        id = "cancel",
                        callback = function()
                            UIManager:close(input_dialog)
                            UIManager:nextTick(function()
                                if openServerAndVoiceDialog then openServerAndVoiceDialog() end
                            end)
                        end,
                    },
                    {
                        text = _("Lưu"),
                        is_enter_default = true,
                        callback = function()
                            local val = tonumber(input_dialog:getInputText())
                            if val then
                                val = math.max(1, math.min(7, math.floor(val)))
                                this.settings:set("preload_count", val)
                                this.settings:save()
                                if this.engine and this.engine.updateConfig then
                                    this.engine:updateConfig({ preload_count = val })
                                end
                                UIManager:show(InfoMessage:new{
                                    text = string.format(_("Đã lưu số câu đệm: %d câu"), val),
                                    timeout = 2,
                                })
                            end
                            UIManager:close(input_dialog)
                            UIManager:nextTick(function()
                                if openServerAndVoiceDialog then openServerAndVoiceDialog() end
                            end)
                        end,
                    },
                },
            },
        }
        UIManager:show(input_dialog)
        input_dialog:onShowKeyboard()
    end

    openSpeedInput = function()
        local input_dialog
        input_dialog = InputDialog:new{
            title = _("Tốc độ đọc (0.5x - 2.0x)"),
            input = tostring(this.settings:get("speed") or 1.0),
            input_hint = "1.0",
            buttons = {
                {
                    {
                        text = _("Hủy"),
                        id = "cancel",
                        callback = function()
                            UIManager:close(input_dialog)
                            UIManager:nextTick(function()
                                if openServerAndVoiceDialog then openServerAndVoiceDialog() end
                            end)
                        end,
                    },
                    {
                        text = _("Lưu"),
                        is_enter_default = true,
                        callback = function()
                            local val = tonumber(input_dialog:getInputText())
                            if val then
                                val = math.max(0.5, math.min(2.0, val))
                                this.settings:set("speed", val)
                                this.settings:save()
                                if this.audio_backend then
                                    this.audio_backend:setSpeed(val)
                                end
                                if this.engine and this.engine.updateConfig then
                                    this.engine:updateConfig({ speed = val })
                                end
                                if this.ui_player and this.ui_player.speed_btn and this.ui_player.speed_btn.setText then
                                    this.ui_player.speed_btn:setText(string.format(_("Tốc độ: %.1fx"), val))
                                end
                                if this.ui_player and this.ui_player.mini_label_btn and this.ui_player.mini_label_btn.setText then
                                    this.ui_player.mini_label_btn:setText(string.format("%d/%d · %.1fx", this.ui_player.current_index or 1, this.ui_player.total_on_page or 1, val))
                                end
                            end
                            UIManager:close(input_dialog)
                            if UIManager and UIManager.setDirty then
                                pcall(UIManager.setDirty, UIManager, nil, "ui")
                            end
                            UIManager:nextTick(function()
                                if openServerAndVoiceDialog then openServerAndVoiceDialog() end
                            end)
                        end,
                    },
                },
            },
        }
        UIManager:show(input_dialog)
        input_dialog:onShowKeyboard()
    end

    -- Main settings dialog buttons
    local buttons = {
        {
            {
                text = _("1. Cài đặt Máy chủ, Giọng đọc & Tốc độ"),
                align = "left",
                callback = function()
                    UIManager:close(this.settings_dialog)
                    UIManager:nextTick(function()
                        openServerAndVoiceDialog()
                    end)
                end,
            },
        },
        {
            {
                text = _("2. Quản lý từ điển phát âm"),
                align = "left",
                callback = function()
                    UIManager:close(this.settings_dialog)
                    UIManager:nextTick(function()
                        this:showWordMappingDialog()
                    end)
                end,
            },
        },
        {
            {
                text = _("Khôi phục mặc định"),
                callback = function()
                    this.settings:resetDefaults()
                    this.settings:save()
                    UIManager:close(this.settings_dialog)
                    UIManager:show(InfoMessage:new{
                        text = _("Đã khôi phục cấu hình về mặc định ban đầu."),
                        timeout = 3,
                    })
                end,
            },
            {
                text = _("Đóng"),
                callback = function()
                    UIManager:close(this.settings_dialog)
                    this.settings_dialog = nil
                end,
            },
        },
    }

    self.settings_dialog = ButtonDialog:new{
        title = _("Cài đặt đọc giọng nói"),
        buttons = buttons,
    }
    local ok_s, err_s = pcall(UIManager.show, UIManager, self.settings_dialog)
    if ok_l and log then log.warn("TTS: UIManager:show(settings_dialog) result:", ok_s, tostring(err_s)) end
end

--- Handle reader close / document close: ensure TTS stops cleanly
function KoreaderTTS:onCloseDocument()
    self:onStopTTS()
    if self.engine and self.engine.destroy then
        pcall(function() self.engine:destroy() end)
    elseif self.tts_service and self.tts_service.destroy then
        pcall(function() self.tts_service:destroy() end)
    end
end

function KoreaderTTS:onCloseWidget()
    self:onStopTTS()
    if self.engine and self.engine.destroy then
        pcall(function() self.engine:destroy() end)
    elseif self.tts_service and self.tts_service.destroy then
        pcall(function() self.tts_service:destroy() end)
    end
end

--- Handle device suspend / screen turn-off: pause playback cleanly
function KoreaderTTS:onSuspend()
    if self.playback_queue and (self.playback_queue:getState() == "PLAYING" or self.playback_queue:getState() == "PREFETCHING") then
        self.playback_queue:pause()
    end
end

--- Handle KOReader exit: stop all playback
function KoreaderTTS:onExit()
    self:onStopTTS()
    if self.engine and self.engine.destroy then
        pcall(function() self.engine:destroy() end)
    elseif self.tts_service and self.tts_service.destroy then
        pcall(function() self.tts_service:destroy() end)
    end
end

return KoreaderTTS
