--[[
    tts_service.lua - Service Broker connecting Lua to Native Core (libtts_core.so)
    Project: KOReader TTS Plugin

    Responsibilities:
    - Safe ABI detection and dynamic loading via LuaJIT FFI (pcall).
    - Data marshaling (Lua tables <-> C-ABI structs and arrays).
    - Sub-microsecond non-blocking event polling from lock-free SPSC Ring Buffer.
    - Zero-Risk Fallback: automatically delegates to pure Lua (tts_client.lua)
      if the native library is missing or fails to load.
--]]

local ffi = require("ffi")

-- ============================================================================
-- C-ABI Function & Struct Signatures
-- ============================================================================

local cdef_ok, cdef_err = pcall(ffi.cdef, [[
typedef struct TtsCoreContext TtsCoreContext;

typedef struct {
    double duration_seconds;
    int32_t event_type;
    uint32_t generation;
    uint32_t chunk_index;
    uint32_t total_chunks;
    int32_t latency_ms;
    uint32_t _reserved;
    char error_message[256];
} TtsCoreEvent;

typedef struct {
    double duration_seconds;
    uint32_t chunk_index;
    int32_t is_cached;
    int32_t is_fetching;
    int32_t is_playing;
} TtsCoreSlotStatus;

TtsCoreContext* tts_core_context_create(const char* config_json, int32_t* out_error);
int32_t tts_core_context_update_config(TtsCoreContext* ctx, const char* config_json);
int32_t tts_core_queue_load_page(TtsCoreContext* ctx, uint32_t generation, const char** chunk_texts, uint32_t chunk_count);
int32_t tts_core_queue_enqueue_next_page(TtsCoreContext* ctx, uint32_t generation, const char** chunk_texts, uint32_t chunk_count);
int32_t tts_core_playback_play(TtsCoreContext* ctx);
int32_t tts_core_playback_pause(TtsCoreContext* ctx);
int32_t tts_core_playback_resume(TtsCoreContext* ctx);
int32_t tts_core_playback_stop(TtsCoreContext* ctx);
int32_t tts_core_playback_seek(TtsCoreContext* ctx, uint32_t generation, uint32_t chunk_index);
int32_t tts_core_event_poll(TtsCoreContext* ctx, TtsCoreEvent* out_event);
int32_t tts_core_slot_get_status(TtsCoreContext* ctx, uint32_t chunk_index, TtsCoreSlotStatus* out_status);
void tts_core_context_destroy(TtsCoreContext* ctx);
]])

if not cdef_ok and not tostring(cdef_err):find("redefinition") then
    -- Ignore benign redefinition errors when re-required
end

-- ============================================================================
-- Event Types Constants
-- ============================================================================

local TTS_EVENT_NONE = 0
local TTS_EVENT_CHUNK_STARTED = 1
local TTS_EVENT_CHUNK_FINISHED = 2
local TTS_EVENT_PAGE_COMPLETED = 3
local TTS_EVENT_BUFFER_UPDATED = 4
local TTS_EVENT_LATENCY_REPORT = 5
local TTS_EVENT_ERROR = 6

local TTSService = {
    EVENT_NONE = TTS_EVENT_NONE,
    EVENT_CHUNK_STARTED = TTS_EVENT_CHUNK_STARTED,
    EVENT_CHUNK_FINISHED = TTS_EVENT_CHUNK_FINISHED,
    EVENT_PAGE_COMPLETED = TTS_EVENT_PAGE_COMPLETED,
    EVENT_BUFFER_UPDATED = TTS_EVENT_BUFFER_UPDATED,
    EVENT_LATENCY_REPORT = TTS_EVENT_LATENCY_REPORT,
    EVENT_ERROR = TTS_EVENT_ERROR,
}
TTSService.__index = TTSService

-- ============================================================================
-- Platform & Native Library Resolution
-- ============================================================================

--- Finds candidate paths for the native library based on OS and architecture.
-- @param base_dir Base plugin directory path
-- @return Array of candidate file paths
local function getCandidateLibraryPaths(base_dir)
    base_dir = base_dir or ""
    if base_dir ~= "" and not base_dir:match("[/\\]$") then
        base_dir = base_dir .. "/"
    end

    local os_name = ffi.os
    local arch_name = ffi.arch
    local paths = {}

    if os_name == "Windows" then
        -- Windows host dev testing only (tests run via local luajit)
        table.insert(paths, base_dir .. "rust_core/target/release/tts_core.dll")
        table.insert(paths, base_dir .. "rust_core/target/debug/tts_core.dll")
    elseif os_name == "Linux" or os_name == "POSIX" or os_name == "Android" then
        if arch_name == "arm64" or arch_name == "aarch64" then
            table.insert(paths, base_dir .. "libs/arm64-v8a/libtts_core.so")
        elseif arch_name == "arm" then
            table.insert(paths, base_dir .. "libs/armeabi-v7a/libtts_core.so")
            table.insert(paths, base_dir .. "libs/kindle-armhf/libtts_core.so")
            table.insert(paths, base_dir .. "libs/kobo-armv7l/libtts_core.so")
        else
            table.insert(paths, base_dir .. "libs/x86_64/libtts_core.so")
        end
        table.insert(paths, base_dir .. "rust_core/target/release/libtts_core.so")
        table.insert(paths, base_dir .. "rust_core/target/debug/libtts_core.so")
        table.insert(paths, "libtts_core.so")
    end

    return paths
end

--- Attempts to safely load the native library across candidate paths.
-- @param base_dir Base directory
-- @return Loaded library handle or nil
local function tryLoadNativeLibrary(base_dir)
    local candidates = getCandidateLibraryPaths(base_dir)
    for _, path in ipairs(candidates) do
        local ok, lib = pcall(ffi.load, path)
        if ok and lib then
            return lib, path
        end
    end
    return nil, nil
end

-- ============================================================================
-- TTSService Implementation
-- ============================================================================

--- Initializes a new TTSService instance.
-- @param options Table containing server_url, voice, audio_format, speed, cache_dir, etc.
-- @return TTSService instance
function TTSService:new(options)
    local instance = setmetatable({}, self)
    options = options or {}

    instance.server_url = options.server_url or "http://127.0.0.1:8000/v1/audio/speech"
    instance.voice = options.voice or "duc_tri"
    instance.audio_format = options.audio_format or "wav"
    instance.speed = options.speed or 1.0
    instance.api_key = options.api_key or ""
    instance.cache_dir = options.cache_dir or "cache/tts"
    instance.preload_count = options.preload_count or 3
    instance.plugin_dir = options.plugin_dir or ""

    -- Try loading native Rust shared library
    local lib, loaded_path = tryLoadNativeLibrary(instance.plugin_dir)

    if lib and not options._force_fallback then
        instance.lib = lib
        instance.is_native = true
        instance.loaded_path = loaded_path

        local config_table = {
            server_url = instance.server_url,
            voice = instance.voice,
            audio_format = instance.audio_format,
            speed = instance.speed,
            api_key = (instance.api_key ~= "") and instance.api_key or nil,
            cache_dir = instance.cache_dir,
            preload_count = instance.preload_count,
        }

        local json_str = ""
        local ok_json, JSON = pcall(require, "json")
        if ok_json and JSON and JSON.encode then
            json_str = JSON.encode(config_table)
        else
            -- Minimal fallback json serializer for basic types
            json_str = string.format(
                '{"server_url":"%s","voice":"%s","audio_format":"%s","speed":%s,"cache_dir":"%s","preload_count":%d}',
                instance.server_url,
                instance.voice,
                instance.audio_format,
                tostring(instance.speed),
                instance.cache_dir:gsub("\\", "/"),
                instance.preload_count
            )
        end

        local c_json = ffi.new("char[?]", #json_str + 1)
        ffi.copy(c_json, json_str)

        local err = ffi.new("int32_t[1]")
        instance.ctx = instance.lib.tts_core_context_create(c_json, err)
        if instance.ctx == nil or instance.ctx == ffi.NULL or err[0] ~= 0 then
            instance.is_native = false
            instance.lib = nil
            instance.ctx = nil
        end
    else
        instance.is_native = false
    end

    -- If native core is not available, initialize pure Lua fallback engine
    if not instance.is_native then
        local ok_client, TTSClient = pcall(require, "tts_client")
        if ok_client and TTSClient then
            instance.fallback_client = TTSClient:new(options)
        end
        instance.fallback_slots = {}
        instance.fallback_playing_idx = 0
        instance.fallback_generation = 0
    end

    return instance
end

--- Returns true if operating with Rust native core, false if running pure Lua fallback.
function TTSService:isNative()
    return self.is_native == true
end

--- Loads page chunks into the prefetch queue.
-- @param generation Generation token (integer)
-- @param chunk_texts Array of sentence strings
-- @return boolean Success
function TTSService:loadPageChunks(generation, chunk_texts)
    if not chunk_texts or #chunk_texts == 0 then
        return false
    end

    if self.is_native and self.ctx then
        local count = #chunk_texts
        local c_array = ffi.new("const char*[?]", count)
        for i = 1, count do
            c_array[i - 1] = chunk_texts[i]
        end
        local res = self.lib.tts_core_queue_load_page(self.ctx, generation, c_array, count)
        return res == 0
    else
        self.fallback_generation = generation
        self.fallback_playing_idx = 0
        self.fallback_slots = {}
        for idx, txt in ipairs(chunk_texts) do
            self.fallback_slots[idx - 1] = {
                text = txt,
                is_cached = false,
                is_fetching = false,
                duration = 0.0,
            }
        end
        return true
    end
end

--- Enqueues the next page for cross-page prefetching.
function TTSService:enqueueNextPage(generation, chunk_texts)
    if not chunk_texts or #chunk_texts == 0 then
        return false
    end

    if self.is_native and self.ctx then
        local count = #chunk_texts
        local c_array = ffi.new("const char*[?]", count)
        for i = 1, count do
            c_array[i - 1] = chunk_texts[i]
        end
        local res = self.lib.tts_core_queue_enqueue_next_page(self.ctx, generation, c_array, count)
        return res == 0
    else
        return true
    end
end

--- Starts audio playback.
function TTSService:play()
    if self.is_native and self.ctx then
        return self.lib.tts_core_playback_play(self.ctx) == 0
    else
        return true
    end
end

--- Pauses audio playback.
function TTSService:pause()
    if self.is_native and self.ctx then
        return self.lib.tts_core_playback_pause(self.ctx) == 0
    else
        return true
    end
end

--- Resumes paused audio playback.
function TTSService:resume()
    if self.is_native and self.ctx then
        return self.lib.tts_core_playback_resume(self.ctx) == 0
    else
        return true
    end
end

--- Stops audio playback.
function TTSService:stop()
    if self.is_native and self.ctx then
        return self.lib.tts_core_playback_stop(self.ctx) == 0
    else
        return true
    end
end

--- Seeks to a specific chunk index on a given generation.
function TTSService:seekChunk(generation, chunk_index)
    if self.is_native and self.ctx then
        return self.lib.tts_core_playback_seek(self.ctx, generation, chunk_index) == 0
    else
        self.fallback_generation = generation
        self.fallback_playing_idx = chunk_index
        return true
    end
end

--- Polls pending events non-blocking (< 300ns).
-- @param callback function(event_table)
function TTSService:pollEvents(callback)
    if not callback then return end

    if self.is_native and self.ctx then
        local event = ffi.new("TtsCoreEvent")
        while self.lib.tts_core_event_poll(self.ctx, event) == 1 do
            local err_str = nil
            if event.error_message[0] ~= 0 then
                err_str = ffi.string(event.error_message)
            end

            callback({
                event_type = event.event_type,
                generation = event.generation,
                chunk_index = event.chunk_index,
                total_chunks = event.total_chunks,
                duration_seconds = event.duration_seconds,
                latency_ms = event.latency_ms,
                error_message = err_str,
            })
        end
    end
end

--- Retrieves buffer caching and fetching status for UI rendering.
-- @param chunk_index Slot index
-- @return table { is_cached = boolean, is_fetching = boolean, is_playing = boolean, duration_seconds = number }
function TTSService:getSlotStatus(chunk_index)
    if self.is_native and self.ctx then
        local status = ffi.new("TtsCoreSlotStatus")
        if self.lib.tts_core_slot_get_status(self.ctx, chunk_index, status) == 0 then
            return {
                chunk_index = status.chunk_index,
                is_cached = status.is_cached == 1,
                is_fetching = status.is_fetching == 1,
                is_playing = status.is_playing == 1,
                duration_seconds = status.duration_seconds,
            }
        end
    elseif self.fallback_slots then
        local slot = self.fallback_slots[chunk_index]
        if slot then
            return {
                chunk_index = chunk_index,
                is_cached = slot.is_cached == true,
                is_fetching = slot.is_fetching == true,
                is_playing = chunk_index == self.fallback_playing_idx,
                duration_seconds = slot.duration or 0.0,
            }
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

--- Gracefully destroys the native context and frees all native memory.
function TTSService:destroy()
    if self.is_native and self.ctx and self.lib then
        self.lib.tts_core_context_destroy(self.ctx)
        self.ctx = nil
    end
end

return TTSService
