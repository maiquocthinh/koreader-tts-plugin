--[[
    fallback_engine.lua - Pure Lua ITtsEngine Implementation for devices without native .so
    Project: KOReader TTS Plugin
    Layer: Engine Strategy
--]]

local ok_iface, ITtsEngine = pcall(require, "src.engine.engine_interface")
if not ok_iface then ITtsEngine = require("engine_interface") end

local ok_client, TTSClient = pcall(require, "src.bridge.fallback.tts_client")
if not ok_client then
    pcall(function() TTSClient = require("tts_client") end)
end

local FallbackEngine = setmetatable({}, { __index = ITtsEngine })
FallbackEngine.__index = FallbackEngine

--- Initializes a new FallbackEngine instance.
-- @param options Configuration options table
-- @return FallbackEngine instance
function FallbackEngine:new(options)
    local instance = setmetatable({}, self)
    options = options or {}

    instance.server_url = options.server_url or "http://127.0.0.1:8000/v1/audio/speech"
    instance.voice = options.voice or "duc_tri"
    instance.audio_format = options.audio_format or "wav"
    instance.speed = options.speed or 1.0
    instance.api_key = options.api_key or ""
    instance.cache_dir = options.cache_dir or "cache/tts"
    instance.preload_count = options.preload_count or 3

    if TTSClient then
        instance.client = TTSClient:new(options)
    end

    instance.slots = {}
    instance.playing_idx = 0
    instance.generation = 0

    return instance
end

function FallbackEngine:isNative()
    return false
end

function FallbackEngine:loadPage(generation, chunk_texts)
    self.generation = generation or 0
    self.playing_idx = 0
    self.slots = {}

    if chunk_texts then
        for idx, txt in ipairs(chunk_texts) do
            self.slots[idx - 1] = {
                text = txt,
                is_cached = false,
                is_fetching = false,
                duration = 0.0,
            }
        end
    end

    return true
end

-- Backward compatibility alias
FallbackEngine.loadPageChunks = FallbackEngine.loadPage

function FallbackEngine:enqueueNextPage(generation, chunk_texts)
    return true
end

function FallbackEngine:play()
    return true
end

function FallbackEngine:pause()
    return true
end

function FallbackEngine:resume()
    return true
end

function FallbackEngine:stop()
    return true
end

function FallbackEngine:seekChunk(generation, chunk_index)
    self.generation = generation or self.generation
    self.playing_idx = chunk_index or 0
    return true
end

function FallbackEngine:pollEvents(callback)
    -- Fallback engine is driven synchronously or via legacy coroutine loop
end

function FallbackEngine:getSlotStatus(chunk_index)
    local slot = self.slots and self.slots[chunk_index]
    if slot then
        return {
            chunk_index = chunk_index,
            is_cached = slot.is_cached == true,
            is_fetching = slot.is_fetching == true,
            is_playing = chunk_index == self.playing_idx,
            duration_seconds = slot.duration or 0.0,
        }
    end

    return {
        chunk_index = chunk_index,
        is_cached = false,
        is_fetching = false,
        is_playing = false,
        duration_seconds = 0.0,
    }
end

function FallbackEngine:destroy()
    self.slots = {}
end

return FallbackEngine
