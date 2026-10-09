--[[
    native_engine.lua - ITtsEngine Implementation backed by Rust C-ABI core
    Project: KOReader TTS Plugin
    Layer: Engine Strategy
--]]

local ffi = require("ffi")

local ok_iface, ITtsEngine = pcall(require, "src.engine.engine_interface")
if not ok_iface then ITtsEngine = require("engine_interface") end

local ok_sig, FfiSignatures = pcall(require, "src.bridge.ffi_signatures")
if not ok_sig then FfiSignatures = require("ffi_signatures") end

local ok_loader, FfiLoader = pcall(require, "src.bridge.ffi_loader")
if not ok_loader then FfiLoader = require("ffi_loader") end

local ok_marshaler, FfiMarshaler = pcall(require, "src.bridge.ffi_marshaler")
if not ok_marshaler then FfiMarshaler = require("ffi_marshaler") end

local NativeEngine = setmetatable({}, { __index = ITtsEngine })
NativeEngine.__index = NativeEngine

--- Initializes a new NativeEngine.
-- @param options Table of configuration options
-- @param lib Pre-loaded FFI library handle (optional)
-- @param loaded_path Path from which library was loaded (optional)
-- @return NativeEngine instance or nil on error
function NativeEngine:new(options, lib, loaded_path)
    options = options or {}
    local plugin_dir = options.plugin_dir or ""

    if not lib then
        lib, loaded_path = FfiLoader.load(plugin_dir)
    end

    if not lib then
        return nil, "Failed to load native shared library"
    end

    local instance = setmetatable({}, self)
    instance.lib = lib
    instance.loaded_path = loaded_path
    instance.server_url = options.server_url or "http://127.0.0.1:8000/v1/audio/speech"
    instance.voice = options.voice or "duc_tri"
    instance.audio_format = options.audio_format or "wav"
    instance.speed = options.speed or 1.0
    instance.api_key = options.api_key or ""
    instance.cache_dir = options.cache_dir or "cache/tts"
    instance.preload_count = options.preload_count or 3

    local config_table = {
        server_url = instance.server_url,
        voice = instance.voice,
        audio_format = instance.audio_format,
        speed = instance.speed,
        api_key = (instance.api_key ~= "") and instance.api_key or nil,
        cache_dir = instance.cache_dir,
        preload_count = instance.preload_count,
    }

    local c_json = FfiMarshaler.marshalConfigJson(config_table)
    local err = ffi.new("int32_t[1]")
    instance.ctx = instance.lib.tts_core_context_create(c_json, err)

    if instance.ctx == nil or instance.ctx == ffi.NULL or err[0] ~= 0 then
        return nil, "Failed to create native TTS context (error code " .. tostring(err[0]) .. ")"
    end

    return instance
end

function NativeEngine:isNative()
    return true
end

function NativeEngine:loadPage(generation, chunk_texts)
    if not chunk_texts or #chunk_texts == 0 or not self.ctx then
        return false
    end
    local c_array, count = FfiMarshaler.marshalTextArray(chunk_texts)
    local res = self.lib.tts_core_queue_load_page(self.ctx, generation, c_array, count)
    return res == 0
end

-- Backward compatibility alias
NativeEngine.loadPageChunks = NativeEngine.loadPage

function NativeEngine:enqueueNextPage(generation, chunk_texts)
    if not chunk_texts or #chunk_texts == 0 or not self.ctx then
        return false
    end
    local c_array, count = FfiMarshaler.marshalTextArray(chunk_texts)
    local res = self.lib.tts_core_queue_enqueue_next_page(self.ctx, generation, c_array, count)
    return res == 0
end

function NativeEngine:play()
    if not self.ctx then return false end
    return self.lib.tts_core_playback_play(self.ctx) == 0
end

function NativeEngine:pause()
    if not self.ctx then return false end
    return self.lib.tts_core_playback_pause(self.ctx) == 0
end

function NativeEngine:resume()
    if not self.ctx then return false end
    return self.lib.tts_core_playback_resume(self.ctx) == 0
end

function NativeEngine:stop()
    if not self.ctx then return false end
    return self.lib.tts_core_playback_stop(self.ctx) == 0
end

function NativeEngine:seekChunk(generation, chunk_index)
    if not self.ctx then return false end
    return self.lib.tts_core_playback_seek(self.ctx, generation, chunk_index) == 0
end

function NativeEngine:pollEvents(callback)
    if not callback or not self.ctx then return end

    local event = ffi.new("TtsCoreEvent")
    while self.lib.tts_core_event_poll(self.ctx, event) == 1 do
        callback(FfiMarshaler.unpackEvent(event))
    end
end

function NativeEngine:getSlotStatus(chunk_index)
    if self.ctx then
        local status = ffi.new("TtsCoreSlotStatus")
        if self.lib.tts_core_slot_get_status(self.ctx, chunk_index, status) == 0 then
            return FfiMarshaler.unpackSlotStatus(status)
        end
    end

    return {
        chunk_index = chunk_index,
        is_cached = false,
        is_fetching = false,
        is_playing = false,
        duration_seconds = 0.0,
    }
end

function NativeEngine:destroy()
    if self.ctx and self.lib then
        self.lib.tts_core_context_destroy(self.ctx)
        self.ctx = nil
    end
end

return NativeEngine
