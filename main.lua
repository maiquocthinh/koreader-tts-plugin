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
    self.ui.menu:registerToMainMenu(self)
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
                text = _("⚙ Cài đặt máy chủ & Giọng đọc..."),
                callback = function()
                    self:showSettingsDialog()
                end,
            },
        },
    }
end

--- Xử lý sự kiện bắt đầu đọc TTS
function KoreaderTTS:onStartTTS()
    -- ponytail: Phase 1 hiển thị thông báo tiến độ, sẽ nối vào tts_client và audio_backend ở Phase 3
    local server_url = self.settings:get("server_url") or ""
    local voice = self.settings:get("voice") or ""
    local msg = string.format(
        _("VieNeu TTS Plugin (Phase 1):\nMáy chủ: %s\nGiọng đọc: %s\n\nĐộng cơ âm thanh và tải đệm sẽ kích hoạt ở Giai đoạn 3."),
        server_url, voice
    )
    UIManager:show(InfoMessage:new{
        text = msg,
        timeout = 5,
    })
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
