--[[
    audio_backend.lua - Backward-compatibility shim forwarding to src/bridge/fallback/audio_backend
    Project: KOReader TTS Plugin
--]]

local ok, mod = pcall(require, "src.bridge.fallback.audio_backend")
if ok and mod then return mod end
return require("src/bridge/fallback/audio_backend")
