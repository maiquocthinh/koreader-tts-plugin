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

    instance.server_url = options.server_url or "https://api.openai.com/v1/audio/speech"
    instance.voice = options.voice or "alloy"
    instance.audio_format = options.audio_format or "wav"
    instance.speed = options.speed or 1.0
    instance.api_key = options.api_key or ""
    instance.cache_dir = options.cache_dir or "cache/tts"
    instance.preload_count = options.preload_count or 1

    if TTSClient then
        instance.client = TTSClient:new(options)
    end

    instance.slots = {}
    instance.playing_idx = 0
    instance.generation = 0
    instance.next_page_generation = 0
    instance.next_page_slots = nil
    instance.active_fetching_idx = nil
    instance.event_queue = {}

    return instance
end

function FallbackEngine:isNative()
    return false
end

function FallbackEngine:loadPage(generation, chunk_texts)
    self.generation = generation or 0
    self.playing_idx = 0

    -- Cross-page promotion
    if self.next_page_generation == generation and self.next_page_slots then
        local next_s = self.next_page_slots
        self.next_page_slots = nil
        local count = 0
        for _ in pairs(next_s) do count = count + 1 end
        if count == #(chunk_texts or {}) then
            self.slots = next_s
            self:_pumpQueue()
            return true
        end
    end

    self.slots = {}
    if chunk_texts then
        for idx, txt in ipairs(chunk_texts) do
            self.slots[idx - 1] = {
                text = txt,
                is_cached = false,
                is_fetching = false,
                file_path = nil,
                duration = 0.0,
            }
        end
    end

    self:_pumpQueue()
    return true
end

-- Backward compatibility alias
FallbackEngine.loadPageChunks = FallbackEngine.loadPage

function FallbackEngine:enqueueNextPage(generation, chunk_texts)
    self.next_page_generation = generation or 0
    self.next_page_slots = {}
    if chunk_texts then
        for idx, txt in ipairs(chunk_texts) do
            self.next_page_slots[idx - 1] = {
                text = txt,
                is_cached = false,
                is_fetching = false,
                file_path = nil,
                duration = 0.0,
            }
        end
    end
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
    self.active_fetching_idx = nil
    self.slots = {}
    self.event_queue = {}
    return true
end

function FallbackEngine:seekChunk(generation, chunk_index)
    self.generation = generation or self.generation
    self.playing_idx = chunk_index or 0
    self:_pumpQueue()
    return true
end

function FallbackEngine:_pushEvent(ev)
    table.insert(self.event_queue, ev)
end

function FallbackEngine:pollEvents(callback)
    if not callback then return end
    while #self.event_queue > 0 do
        local ev = table.remove(self.event_queue, 1)
        callback(ev)
    end
end

function FallbackEngine:getSlotStatus(chunk_index)
    local slot = self.slots and self.slots[chunk_index]
    if slot then
        return {
            chunk_index = chunk_index,
            is_cached = (slot.is_cached == true) or (slot.file_path ~= nil),
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

function FallbackEngine:getSlotPath(chunk_index)
    local slot = self.slots and self.slots[chunk_index]
    if slot and slot.file_path then
        return slot.file_path
    end
    if slot and slot.text and self.client then
        local ok, path = self.client:hasValidCache(slot.text, self.voice, self.audio_format)
        if ok and path then
            slot.file_path = path
            slot.is_cached = true
            return path
        end
    end
    return nil
end

function FallbackEngine:_pumpQueue()
    if not self.client then return end

    -- 1. Check if current playing chunk needs fetching (Priority 1)
    local cur_slot = self.slots[self.playing_idx]
    if cur_slot and not cur_slot.file_path and not cur_slot.is_cached and not cur_slot.is_fetching then
        self:_fetchSlot(self.playing_idx, true)
        return
    end

    -- 2. If a fetch is already in flight, wait
    if self.active_fetching_idx ~= nil then
        return
    end

    -- 3. Prefetch upcoming chunks up to preload_count
    local k = self.preload_count or 1
    for offset = 1, k do
        local idx = self.playing_idx + offset
        local s = self.slots[idx]
        if s and not s.file_path and not s.is_cached and not s.is_fetching then
            self:_fetchSlot(idx, false)
            return
        end
    end

    -- 4. Cross-page chunk 0 prefetch if current window is full
    if self.next_page_slots and self.next_page_slots[0] then
        local s0 = self.next_page_slots[0]
        if not s0.file_path and not s0.is_cached and not s0.is_fetching then
            self:_fetchNextPageSlot(0)
            return
        end
    end
end

function FallbackEngine:_fetchSlot(chunk_index, is_urgent)
    local slot = self.slots[chunk_index]
    if not slot or slot.is_fetching then return end

    slot.is_fetching = true
    self.active_fetching_idx = chunk_index
    local expected_gen = self.generation
    local this = self

    self.client:fetchSpeechAsync(slot.text, function(success, result_or_err)
        if this.generation ~= expected_gen then return end
        slot.is_fetching = false
        if this.active_fetching_idx == chunk_index then
            this.active_fetching_idx = nil
        end

        if success then
            slot.file_path = result_or_err
            slot.is_cached = true
            this:_pushEvent({
                event_type = 4, -- EVENT_BUFFER_UPDATED
                generation = expected_gen,
                chunk_index = chunk_index,
            })
            if this.client.last_latency_ms then
                this:_pushEvent({
                    event_type = 5, -- EVENT_LATENCY_REPORT
                    generation = expected_gen,
                    chunk_index = chunk_index,
                    latency_ms = this.client.last_latency_ms,
                })
            end
        else
            this:_pushEvent({
                event_type = 6, -- EVENT_ERROR
                generation = expected_gen,
                chunk_index = chunk_index,
                error_message = tostring(result_or_err),
            })
        end

        this:_pumpQueue()
    end, {
        voice = self.voice,
        speed = self.speed,
        format = self.audio_format,
    })
end

function FallbackEngine:_fetchNextPageSlot(chunk_index)
    local slot = self.next_page_slots and self.next_page_slots[chunk_index]
    if not slot or slot.is_fetching then return end

    slot.is_fetching = true
    self.active_fetching_idx = -100
    local expected_gen = self.next_page_generation
    local this = self

    self.client:fetchSpeechAsync(slot.text, function(success, result_or_err)
        if this.next_page_generation ~= expected_gen then return end
        slot.is_fetching = false
        this.active_fetching_idx = nil

        if success then
            slot.file_path = result_or_err
            slot.is_cached = true
        end
    end, {
        voice = self.voice,
        speed = self.speed,
        format = self.audio_format,
    })
end

function FallbackEngine:synthesizeSingle(text, callback)
    if not self.client then
        if callback then callback(false, "No TTS client") end
        return
    end
    self.client:fetchSpeechAsync(text, callback, {
        voice = self.voice,
        speed = self.speed,
        format = self.audio_format,
    })
end

function FallbackEngine:updateConfig(new_options)
    new_options = new_options or {}
    if new_options.server_url then self.server_url = new_options.server_url end
    if new_options.voice then self.voice = new_options.voice end
    if new_options.audio_format then self.audio_format = new_options.audio_format end
    if new_options.speed then self.speed = new_options.speed end
    if new_options.api_key ~= nil then self.api_key = new_options.api_key end
    if new_options.preload_count then self.preload_count = new_options.preload_count end

    if self.client then
        self.client.server_url = self.server_url
        self.client.voice = self.voice
        self.client.audio_format = self.audio_format
        self.client.speed = self.speed
        self.client.api_key = self.api_key
    end
    return true
end

function FallbackEngine:destroy()
    self:stop()
end

return FallbackEngine
