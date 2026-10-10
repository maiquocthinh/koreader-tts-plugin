--[[
    ffi_marshaler.lua - Two-way Data Marshaling between Lua Tables and C-ABI Structs
    Project: KOReader TTS Plugin
    Layer: Bridge / FFI
--]]

local ffi = require("ffi")

local FfiMarshaler = {}

--- Marshals configuration table into a null-terminated C char array JSON string.
-- @param config_table Table of configuration fields
-- @return cdata char[?] C string
function FfiMarshaler.marshalConfigJson(config_table)
    local json_str = ""
    local ok_json, JSON = pcall(require, "json")
    if ok_json and JSON and JSON.encode then
        json_str = JSON.encode(config_table)
    else
        -- Minimal fallback JSON serializer for basic configuration types
        json_str = string.format(
            '{"server_url":"%s","voice":"%s","audio_format":"%s","speed":%s,"cache_dir":"%s","preload_count":%d}',
            config_table.server_url or "",
            config_table.voice or "",
            config_table.audio_format or "wav",
            tostring(config_table.speed or 1.0),
            (config_table.cache_dir or "cache/tts"):gsub("\\", "/"),
            config_table.preload_count or 3
        )
    end

    local c_json = ffi.new("char[?]", #json_str + 1)
    ffi.copy(c_json, json_str)
    return c_json
end

--- Marshals Lua array of strings into C const char*[count].
-- @param chunk_texts Array of sentence strings
-- @return cdata const char*[count]
-- @return integer Count of chunks
function FfiMarshaler.marshalTextArray(chunk_texts)
    local count = #chunk_texts
    local c_array = ffi.new("const char*[?]", count)
    for i = 1, count do
        c_array[i - 1] = chunk_texts[i]
    end
    return c_array, count
end

--- Unpacks a C TtsCoreEvent struct into a pure Lua table.
-- @param event cdata TtsCoreEvent
-- @return table Pure Lua event representation
function FfiMarshaler.unpackEvent(event)
    local err_str = nil
    if event.error_message[0] ~= 0 then
        err_str = ffi.string(event.error_message)
    end

    return {
        event_type = event.event_type,
        generation = event.generation,
        chunk_index = event.chunk_index,
        total_chunks = event.total_chunks,
        duration_seconds = event.duration_seconds,
        latency_ms = event.latency_ms,
        error_message = err_str,
    }
end

--- Unpacks a C TtsCoreSlotStatus struct into a pure Lua table.
-- @param status cdata TtsCoreSlotStatus
-- @return table Pure Lua slot status representation
function FfiMarshaler.unpackSlotStatus(status)
    return {
        chunk_index = status.chunk_index,
        is_cached = status.is_cached == 1,
        is_fetching = status.is_fetching == 1,
        is_playing = status.is_playing == 1,
        duration_seconds = status.duration_seconds,
    }
end

--- Allocates a writable char buffer for path retrieval.
-- @param size Buffer size in bytes (default 1024)
-- @return cdata char[size] buffer
function FfiMarshaler.newPathBuffer(size)
    return ffi.new("char[?]", size or 1024)
end

return FfiMarshaler
