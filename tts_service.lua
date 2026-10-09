--[[
    tts_service.lua - Backward-compatibility shim forwarding to src/engine/engine_factory
    Project: KOReader TTS Plugin
--]]

local ok, mod = pcall(require, "src.engine.engine_factory")
if ok and mod then return mod end
return require("src/engine/engine_factory")
