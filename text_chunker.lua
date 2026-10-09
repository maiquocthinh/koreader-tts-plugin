--[[
    text_chunker.lua - Backward-compatibility shim forwarding to src/service/document_chunker
    Project: KOReader TTS Plugin
--]]

local ok, mod = pcall(require, "src.service.document_chunker")
if ok and mod then return mod end
return require("src/service/document_chunker")
