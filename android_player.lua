--[[
    android_player.lua - Backward-compatibility shim forwarding to src/bridge/fallback/android_player
    Project: KOReader TTS Plugin
--]]

local ok, mod = pcall(require, "src.bridge.fallback.android_player")
if ok and mod then return mod end
return require("src/bridge/fallback/android_player")
