--[[
    ui_player.lua - Backward-compatibility shim forwarding to src/ui/player_widget
    Project: KOReader TTS Plugin
--]]

local ok, mod = pcall(require, "src.ui.player_widget")
if ok and mod then return mod end
return require("src/ui/player_widget")
