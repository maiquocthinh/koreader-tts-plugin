--[[
    ffi_signatures.lua - Pure C-ABI Signatures and Constants definition
    Project: KOReader TTS Plugin
    Layer: Bridge / FFI
--]]

local ffi = require("ffi")

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

local FfiSignatures = {
    EVENT_NONE = 0,
    EVENT_CHUNK_STARTED = 1,
    EVENT_CHUNK_FINISHED = 2,
    EVENT_PAGE_COMPLETED = 3,
    EVENT_BUFFER_UPDATED = 4,
    EVENT_LATENCY_REPORT = 5,
    EVENT_ERROR = 6,
}

return FfiSignatures
