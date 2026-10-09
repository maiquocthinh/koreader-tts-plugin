--[[
    playback_queue.lua - Backward-compatibility shim forwarding to src/service/reading_coordinator
    Project: KOReader TTS Plugin
--]]

local ok, mod = pcall(require, "src.service.reading_coordinator")
if ok and mod then return mod end
return require("src/service/reading_coordinator")
