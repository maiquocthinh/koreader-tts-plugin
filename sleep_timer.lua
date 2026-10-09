--[[
    sleep_timer.lua - Backward-compatibility shim forwarding to src/service/sleep_timer
    Project: KOReader TTS Plugin
--]]

local ok, mod = pcall(require, "src.service.sleep_timer")
if ok and mod then return mod end
return require("src/service/sleep_timer")
