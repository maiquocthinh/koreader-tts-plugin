--[[
    main.lua - KOReader TTS Plugin Entry Point
    Plugin: koreader_tts
    Kế thừa WidgetContainer, quản lý vòng đời plugin và menu tích hợp.
--]]

local WidgetContainer = require("ui/widget/widgetcontainer")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local ButtonDialog = require("ui/widget/buttondialog")
local Settings = require("settings")
local TextChunker = require("text_chunker")
local TTSClient = require("tts_client")
local AudioBackend = require("audio_backend")
local PlaybackQueue = require("playback_queue")
local UIPlayer = require("ui_player")

local ok_gettext, _ = pcall(require, "gettext")
if not ok_gettext or type(_) ~= "function" then
    _ = function(msg) return msg end
end

local KoreaderTTS = WidgetContainer:extend{
    name = "koreader_tts",
    is_doc_only = true,
}

--- Khởi tạo plugin khi nạp vào KOReader
function KoreaderTTS:init()
    self.settings = Settings:new()
    self.tts_client = TTSClient:new{
        server_url = self.settings:get("server_url"),
        voice = self.settings:get("voice"),
        api_key = self.settings:get("api_key"),
        request_timeout = self.settings:get("request_timeout"),
    }
    self.audio_backend = AudioBackend:new{
        backend_type = self.settings:get("audio_backend"),
        speed = self.settings:get("speed"),
    }

    local this = self
    local chunker = TextChunker:new{
        min_chars = 30,
        max_chars = self.settings:get("max_chunk_chars") or 300,
        filter_footnotes = self.settings:get("filter_footnotes"),
        custom_mappings = self.settings:getCustomMappings(),
    }
    self.chunker = chunker

    self.playback_queue = PlaybackQueue:new{
        ui = self.ui,
        document = self.ui and self.ui.document,
        chunker = chunker,
        tts_client = self.tts_client,
        audio_backend = self.audio_backend,
        settings = self.settings,
        on_chunk_change = function(chunk, page, index, total)
            if _G.logger and _G.logger.info then
                _G.logger.info(string.format("[TTS Queue] Trang %d | Câu %d/%d: %s", page, index, total, chunk.text))
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
    end
end

--- Hook đăng ký vào Reader Top Menu của KOReader
-- @param menu_items Bảng danh mục menu của KOReader
function KoreaderTTS:addToMainMenu(menu_items)
    menu_items.koreader_tts = {
        text = _("Đọc bằng giọng nói (TTS)"),
        sub_item_table = {
            {
                text = _("▶ Bắt đầu đọc từ vị trí này"),
                callback = function()
                    self:onStartTTS()
                end,
            },
            {
                text = _("🎛 Hiện/Ẩn thanh điều khiển"),
                callback = function()
                    self:onToggleUIPlayer()
                end,
            },
            {
                text = _("⏯ Tạm dừng / Tiếp tục"),
                callback = function()
                    self:onTogglePlayPause()
                end,
            },
            {
                text = _("⏭ Câu tiếp theo"),
                callback = function()
                    self:onNextChunk()
                end,
            },
            {
                text = _("⏮ Câu trước đó"),
                callback = function()
                    self:onPrevChunk()
                end,
            },
            {
                text = _("⏹ Dừng đọc TTS"),
                callback = function()
                    self:onStopTTS()
                end,
            },
            {
                text = _("🔊 Phát thử 1 câu (Test Audio & API)"),
                callback = function()
                    self:onTestSingleSentence()
                end,
            },
            {
                text = _("⚙ Cài đặt máy chủ & Giọng đọc..."),
                callback = function()
                    self:showSettingsDialog()
                end,
            },
        },
    }
end

--- Hiện hoặc ẩn thanh điều khiển nổi
function KoreaderTTS:onToggleUIPlayer()
    if self.ui_player then
        if self.ui_player.visible then
            self.ui_player:hide()
        else
            self.ui_player.view = self.view or (self.ui and self.ui.view)
            self.ui_player:show()
        end
    end
end

--- Tạm dừng hoặc tiếp tục đọc
function KoreaderTTS:onTogglePlayPause()
    if self.playback_queue then
        self.playback_queue:togglePlayPause()
    end
end

--- Chuyển tới câu tiếp theo
function KoreaderTTS:onNextChunk()
    if self.playback_queue then
        self.playback_queue:nextChunk()
    end
end

--- Quay lại câu trước đó
function KoreaderTTS:onPrevChunk()
    if self.playback_queue then
        self.playback_queue:prevChunk()
    end
end

--- Dừng đọc TTS
function KoreaderTTS:onStopTTS()
    if self.playback_queue then
        self.playback_queue:stop()
        UIManager:show(InfoMessage:new{
            text = _("Đã dừng đọc TTS."),
            timeout = 2,
        })
    end
end

--- Thử nghiệm phát câu đầu tiên trên trang (Task 3.3)
function KoreaderTTS:onTestSingleSentence()
    local document = self.ui and self.ui.document
    local current_page = 1
    if self.view and self.view.state and self.view.state.page then
        current_page = self.view.state.page
    elseif document and type(document.getCurrentPage) == "function" then
        current_page = document:getCurrentPage() or 1
    end

    local chunker = TextChunker:new{
        min_chars = 30,
        max_chars = self.settings:get("max_chunk_chars") or 300,
        filter_footnotes = self.settings:get("filter_footnotes"),
        custom_mappings = self.settings:getCustomMappings(),
    }

    local chunks = chunker:extractPageChunks(document, current_page)
    if #chunks == 0 then
        UIManager:show(InfoMessage:new{
            text = _("Trang hiện tại không có nội dung chữ để đọc."),
            timeout = 3,
        })
        return
    end

    local first_chunk = chunks[1]
    UIManager:show(InfoMessage:new{
        text = string.format(_("Đang tải âm thanh cho câu 1...\n'%s'"), first_chunk.text),
        timeout = 2,
    })

    -- Đồng bộ cấu hình mới nhất từ settings
    self.tts_client.server_url = self.settings:get("server_url")
    self.tts_client.voice = self.settings:get("voice")
    self.tts_client.api_key = self.settings:get("api_key")
    self.tts_client.timeout = self.settings:get("request_timeout")
    self.audio_backend:setSpeed(self.settings:get("speed"))

    local this = self
    self.tts_client:fetchSpeechAsync(first_chunk.text, function(success, result_or_err)
        if not success then
            UIManager:show(InfoMessage:new{
                text = string.format(_("Lỗi tải âm thanh từ TTS Server:\n%s"), tostring(result_or_err)),
                timeout = 5,
            })
            return
        end

        local wav_path = result_or_err
        UIManager:show(InfoMessage:new{
            text = string.format(_("Đang phát câu 1...\n'%s'"), first_chunk.text),
            timeout = 2,
        })

        this.audio_backend:play(wav_path, function(finished)
            if finished then
                UIManager:show(InfoMessage:new{
                    text = _("Đã phát xong câu thử nghiệm!"),
                    timeout = 2,
                })
            end
        end)
    end)
end

--- Xử lý sự kiện bắt đầu đọc TTS (Task 2.1 & Phase 4 Preload Queue)
function KoreaderTTS:onStartTTS()
    local document = self.ui and self.ui.document
    local current_page = 1
    if self.view and self.view.state and self.view.state.page then
        current_page = self.view.state.page
    elseif document and type(document.getCurrentPage) == "function" then
        current_page = document:getCurrentPage() or 1
    end

    -- Cập nhật cấu hình mới nhất vào các subsystem
    if self.tts_client then
        self.tts_client.server_url = self.settings:get("server_url")
        self.tts_client.voice = self.settings:get("voice")
        self.tts_client.api_key = self.settings:get("api_key")
        self.tts_client.timeout = self.settings:get("request_timeout")
    end
    if self.audio_backend then
        self.audio_backend:setSpeed(self.settings:get("speed"))
    end

    local chunker = TextChunker:new{
        min_chars = 30,
        max_chars = self.settings:get("max_chunk_chars") or 300,
        filter_footnotes = self.settings:get("filter_footnotes"),
        custom_mappings = self.settings:getCustomMappings(),
    }
    self.chunker = chunker

    local chunks = chunker:extractPageChunks(document, current_page)
    local chunk_count = #chunks

    -- In ra console/logger toàn bộ nội dung đã bóc tách (DoD 2.1)
    if _G.logger and type(_G.logger.info) == "function" then
        _G.logger.info(string.format("[TTS] Trích xuất trang %d: tìm thấy %d câu.", current_page, chunk_count))
        for i, c in ipairs(chunks) do
            _G.logger.info(string.format("[TTS]   Câu %d: %s (bboxes: %d)", i, c.text, #(c.bboxes or {})))
        end
    end

    local preview = (chunk_count > 0) and chunks[1].text or _("(Trang trống hoặc không có chữ)")
    local msg = string.format(
        _("VieNeu TTS Plugin (Phase 4 Preload Pipeline):\nTrang: %d | Tổng số câu: %d\nCâu 1: %s"),
        current_page, chunk_count, preview
    )
    UIManager:show(InfoMessage:new{
        text = msg,
        timeout = 3,
    })

    -- Kích hoạt hàng đợi đệm phát liên tục từ câu 1 của trang hiện tại
    if self.playback_queue and chunk_count > 0 then
        self.playback_queue.document = document
        self.playback_queue.chunker = chunker
        if self.ui_player then
            self.ui_player.view = self.view or (self.ui and self.ui.view)
            self.ui_player:show()
        end
        self.playback_queue:start(current_page, 1)
    end

    return chunks
end

--- Hook vào menu bôi đen văn bản của KOReader (Task 5.4)
function KoreaderTTS:addToHighlightMenu(menu_items, selected_text)
    if type(menu_items) == "table" and selected_text and selected_text ~= "" then
        table.insert(menu_items, {
            text = _("🔊 Đọc bằng TTS"),
            callback = function()
                self:onReadSelectedText(selected_text)
            end,
        })
    end
end

--- Đọc một đoạn văn bản được bôi đen độc lập (Task 5.4)
function KoreaderTTS:onReadSelectedText(selected_text)
    if not selected_text or selected_text == "" then return end

    local chunker = self.chunker or TextChunker:new()
    local cleaned = chunker:sanitize(selected_text)
    cleaned = chunker:normalizePronunciation(cleaned, self.settings:getCustomMappings())

    if cleaned == "" then return end

    -- Tạm dừng hàng đợi phát hiện tại nếu đang đọc sách
    if self.playback_queue and self.playback_queue:getState() == "PLAYING" then
        self.playback_queue:pause()
    end

    UIManager:show(InfoMessage:new{
        text = string.format(_("Đang tải đoạn chọn:\n'%s'"), cleaned:sub(1, 60) .. "..."),
        timeout = 2,
    })

    local this = self
    self.tts_client:fetchSpeechAsync(cleaned, function(success, result_or_err)
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
        end)
    end)
end

--- Hộp thoại quản lý Từ điển phát âm / Mapping từ ngữ cho TTS (CRUD UI)
function KoreaderTTS:showWordMappingDialog()
    local this = self
    local custom_mappings = this.settings:getCustomMappings()

    -- 1. Hàm mở popup thêm từ mới
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
                                -- Mở tiếp dialog nhập từ đọc thay thế
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

    -- 2. Hàm mở popup sửa hoặc xóa từ đã có
    local function openEditOrDeleteDialog(orig_word, current_repl)
        local action_dialog
        action_dialog = ButtonDialog:new{
            title = string.format(_("Từ điển: %s ➔ %s"), orig_word, current_repl),
            buttons = {
                {
                    {
                        text = _("Sửa từ đọc"),
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

    -- Tạo danh sách các nút hiển thị các từ đang có
    local buttons = {
        {
            {
                text = _("+ Thêm từ mapping mới..."),
                callback = function()
                    if this.word_mapping_dialog then
                        UIManager:close(this.word_mapping_dialog)
                    end
                    openAddWordDialog()
                end,
            },
        },
    }

    -- Liệt kê các từ custom hiện có
    for orig, repl in pairs(custom_mappings) do
        local w, r = orig, repl
        table.insert(buttons, {
            {
                text = string.format("• %s ➔ %s", w, r),
                callback = function()
                    if this.word_mapping_dialog then
                        UIManager:close(this.word_mapping_dialog)
                    end
                    openEditOrDeleteDialog(w, r)
                end,
            },
        })
    end

    -- Nút khôi phục và đóng
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
        title = _("Quản lý Từ điển Phát âm TTS"),
        buttons = buttons,
    }
    UIManager:show(this.word_mapping_dialog)
end

--- Hiển thị hộp thoại cài đặt chính của Plugin
function KoreaderTTS:showSettingsDialog()
    local this = self

    local function openServerUrlInput()
        local input_dialog
        input_dialog = InputDialog:new{
            title = _("Địa chỉ máy chủ TTS (API URL)"),
            input = this.settings:get("server_url") or "",
            hint = "http://192.168.1.100:7860",
            buttons = {
                {
                    {
                        text = _("Hủy"),
                        id = "cancel",
                        callback = function()
                            UIManager:close(input_dialog)
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
                                UIManager:show(InfoMessage:new{
                                    text = _("Đã lưu địa chỉ máy chủ thành công!"),
                                    timeout = 3,
                                })
                            end
                            UIManager:close(input_dialog)
                        end,
                    },
                },
            },
        }
        UIManager:show(input_dialog)
    end

    local function openVoiceInput()
        local input_dialog
        input_dialog = InputDialog:new{
            title = _("Chọn ID Giọng đọc (Voice ID)"),
            input = this.settings:get("voice") or "vi-VN-NamMinh",
            hint = "vi-VN-NamMinh",
            buttons = {
                {
                    {
                        text = _("Hủy"),
                        id = "cancel",
                        callback = function()
                            UIManager:close(input_dialog)
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
                                UIManager:show(InfoMessage:new{
                                    text = _("Đã lưu giọng đọc thành công!"),
                                    timeout = 3,
                                })
                            end
                            UIManager:close(input_dialog)
                        end,
                    },
                },
            },
        }
        UIManager:show(input_dialog)
    end

    local function openSpeedInput()
        local input_dialog
        input_dialog = InputDialog:new{
            title = _("Tốc độ đọc (0.5x - 2.0x)"),
            input = tostring(this.settings:get("speed") or 1.0),
            hint = "1.0",
            buttons = {
                {
                    {
                        text = _("Hủy"),
                        id = "cancel",
                        callback = function()
                            UIManager:close(input_dialog)
                        end,
                    },
                    {
                        text = _("Lưu"),
                        is_enter_default = true,
                        callback = function()
                            local val = tonumber(input_dialog:getInputText())
                            if val then
                                this.settings:set("speed", val)
                                this.settings:save()
                                UIManager:show(InfoMessage:new{
                                    text = string.format(_("Đã lưu tốc độ: %.1fx"), this.settings:get("speed")),
                                    timeout = 3,
                                })
                            end
                            UIManager:close(input_dialog)
                        end,
                    },
                },
            },
        }
        UIManager:show(input_dialog)
    end

    -- Menu ButtonDialog tổng hợp để lựa chọn thông số cần sửa
    local current_server = this.settings:get("server_url") or ""
    local current_voice = this.settings:get("voice") or ""
    local current_speed = this.settings:get("speed") or 1.0

    local buttons = {
        {
            {
                text = string.format(_("1. Địa chỉ Máy chủ: %s"), current_server),
                callback = function()
                    UIManager:close(this.settings_dialog)
                    openServerUrlInput()
                end,
            },
        },
        {
            {
                text = string.format(_("2. Giọng đọc mặc định: %s"), current_voice),
                callback = function()
                    UIManager:close(this.settings_dialog)
                    openVoiceInput()
                end,
            },
        },
        {
            {
                text = string.format(_("3. Tốc độ đọc: %.1fx"), current_speed),
                callback = function()
                    UIManager:close(this.settings_dialog)
                    openSpeedInput()
                end,
            },
        },
        {
            {
                text = _("4. Quản lý Từ điển phát âm (Mapping từ đọc)..."),
                callback = function()
                    UIManager:close(this.settings_dialog)
                    this:showWordMappingDialog()
                end,
            },
        },
        {
            {
                text = _("5. Phát thử âm thanh (Test Audio & API)"),
                callback = function()
                    UIManager:close(this.settings_dialog)
                    this:onTestSingleSentence()
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
        title = _("Cài đặt TTS Plugin"),
        buttons = buttons,
    }
    UIManager:show(self.settings_dialog)
end

return KoreaderTTS
