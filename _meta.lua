--[[
    _meta.lua - KOReader Plugin Metadata
    Plugin: koreader_tts
    Category: read
--]]

local ok, _ = pcall(require, "gettext")
if not ok or type(_) ~= "function" then
    _ = function(msg) return msg end
end

return {
    name = "koreader_tts",
    fullname = _("TTS Reader"),
    description = _("Đọc sách bằng giọng nói qua REST API (OpenAI-compatible)"),
    category = "read",
    version = "0.1.0",
}
