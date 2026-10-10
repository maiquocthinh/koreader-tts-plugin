--[[
    engine_interface.lua - Abstract ITtsEngine Contract & Event Constants
    Project: KOReader TTS Plugin
    Layer: Engine Strategy
--]]

local ITtsEngine = {
    EVENT_NONE = 0,
    EVENT_CHUNK_STARTED = 1,
    EVENT_CHUNK_FINISHED = 2,
    EVENT_PAGE_COMPLETED = 3,
    EVENT_BUFFER_UPDATED = 4,
    EVENT_LATENCY_REPORT = 5,
    EVENT_ERROR = 6,
}
ITtsEngine.__index = ITtsEngine

--- Returns true if this engine runs natively via C-ABI / Rust, false if pure Lua.
function ITtsEngine:isNative()
    return false
end

--- Loads page chunks into the engine playback queue.
-- @param generation integer Generation token
-- @param chunk_texts table Array of sentence strings
-- @return boolean Success
function ITtsEngine:loadPage(generation, chunk_texts)
    error("ITtsEngine:loadPage must be implemented by subclass")
end

--- Enqueues next page chunks for cross-page prefetching.
-- @param generation integer Generation token
-- @param chunk_texts table Array of sentence strings
-- @return boolean Success
function ITtsEngine:enqueueNextPage(generation, chunk_texts)
    error("ITtsEngine:enqueueNextPage must be implemented by subclass")
end

--- Starts audio playback.
-- @return boolean Success
function ITtsEngine:play()
    error("ITtsEngine:play must be implemented by subclass")
end

--- Pauses audio playback.
-- @return boolean Success
function ITtsEngine:pause()
    error("ITtsEngine:pause must be implemented by subclass")
end

--- Resumes audio playback.
-- @return boolean Success
function ITtsEngine:resume()
    error("ITtsEngine:resume must be implemented by subclass")
end

--- Stops audio playback.
-- @return boolean Success
function ITtsEngine:stop()
    error("ITtsEngine:stop must be implemented by subclass")
end

--- Seeks to a specific chunk within a given generation.
-- @param generation integer Generation token
-- @param chunk_index integer Target 0-based chunk index
-- @return boolean Success
function ITtsEngine:seekChunk(generation, chunk_index)
    error("ITtsEngine:seekChunk must be implemented by subclass")
end

--- Polls queued engine events (non-blocking).
-- @param callback function(event_table)
function ITtsEngine:pollEvents(callback)
    error("ITtsEngine:pollEvents must be implemented by subclass")
end

--- Retrieves buffer/playback status for a given chunk index.
-- @param chunk_index integer Slot index
-- @return table { chunk_index, is_cached, is_fetching, is_playing, duration_seconds }
function ITtsEngine:getSlotStatus(chunk_index)
    error("ITtsEngine:getSlotStatus must be implemented by subclass")
end

--- Retrieves the cached audio file path for a ready chunk.
-- @param chunk_index integer 0-based chunk index
-- @return string|nil File path on disk, or nil if not ready
function ITtsEngine:getSlotPath(chunk_index)
    return nil
end

--- Synthesizes a single independent text snippet (used for sentence tests and selection reading).
-- @param text string Sentence text to synthesize
-- @param callback function(success, path_or_err)
function ITtsEngine:synthesizeSingle(text, callback)
    error("ITtsEngine:synthesizeSingle must be implemented by subclass")
end

--- Dynamically updates engine configuration (server_url, voice, format, speed, api_key).
-- @param options Configuration options table
-- @return boolean Success
function ITtsEngine:updateConfig(options)
    return true
end

--- Destroys the engine context and frees allocated resources.
function ITtsEngine:destroy()
end

return ITtsEngine
