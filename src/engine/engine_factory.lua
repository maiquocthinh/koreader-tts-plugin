--[[
    engine_factory.lua - Strategy Factory for creating ITtsEngine instances
    Project: KOReader TTS Plugin
    Layer: Engine Strategy
--]]

local ok_iface, ITtsEngine = pcall(require, "src.engine.engine_interface")
if not ok_iface then ITtsEngine = require("engine_interface") end

local ok_native, NativeEngine = pcall(require, "src.engine.native_engine")
if not ok_native then
    pcall(function() NativeEngine = require("native_engine") end)
end

local ok_fallback, FallbackEngine = pcall(require, "src.engine.fallback_engine")
if not ok_fallback then
    pcall(function() FallbackEngine = require("fallback_engine") end)
end

local EngineFactory = {
    EVENT_NONE = ITtsEngine.EVENT_NONE,
    EVENT_CHUNK_STARTED = ITtsEngine.EVENT_CHUNK_STARTED,
    EVENT_CHUNK_FINISHED = ITtsEngine.EVENT_CHUNK_FINISHED,
    EVENT_PAGE_COMPLETED = ITtsEngine.EVENT_PAGE_COMPLETED,
    EVENT_BUFFER_UPDATED = ITtsEngine.EVENT_BUFFER_UPDATED,
    EVENT_LATENCY_REPORT = ITtsEngine.EVENT_LATENCY_REPORT,
    EVENT_ERROR = ITtsEngine.EVENT_ERROR,
}
EngineFactory.__index = EngineFactory

--- Creates an ITtsEngine instance, preferring NativeEngine and falling back to FallbackEngine.
-- @param options Configuration options table
-- @return ITtsEngine implementation instance
function EngineFactory.create(options)
    options = options or {}

    if not options._force_fallback and NativeEngine then
        local engine, err = NativeEngine:new(options)
        if engine then
            return engine
        end
    end

    if FallbackEngine then
        return FallbackEngine:new(options)
    end

    error("No TTS engine implementation available (neither Native nor Fallback)")
end

--- Factory method alias allowing EngineFactory:new(options) instantiation.
function EngineFactory:new(options)
    return EngineFactory.create(options)
end

return EngineFactory
