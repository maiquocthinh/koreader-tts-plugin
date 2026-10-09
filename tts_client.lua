--[[
    tts_client.lua - Backward-compatibility shim forwarding to src/bridge/fallback/tts_client
    Project: KOReader TTS Plugin
--]]

local ok, mod = pcall(require, "src.bridge.fallback.tts_client")
if ok and mod then return mod end
return require("src/bridge/fallback/tts_client")
