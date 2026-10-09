--[[
    settings.lua - Backward-compatibility shim forwarding to src/service/settings_manager
    Project: KOReader TTS Plugin
--]]

local ok, mod = pcall(require, "src.service.settings_manager")
if ok and mod then return mod end
return require("src/service/settings_manager")
