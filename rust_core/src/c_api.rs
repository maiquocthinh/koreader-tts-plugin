//! C-ABI exports and FFI bridge boundary for `libtts_core.so`.
//!
//! Exposes an ABI-stable C interface with panic safety barriers
//! and 8-byte aligned structs compatible across 32-bit and 64-bit systems.

use std::ffi::{c_char, CStr};
use std::panic::catch_unwind;
use std::ptr;
use std::sync::atomic::{AtomicU8, Ordering};
use std::sync::Arc;

// ============================================================================
// C-ABI Error Codes & Enums
// ============================================================================

/// Standard C-ABI error codes returned by tts_core functions.
#[repr(i32)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TtsErrorCode {
    Ok = 0,
    InvalidArg = -1,
    Panic = -2,
    Network = -3,
    Decode = -4,
    AudioOutput = -5,
    QueueEmpty = -6,
}

pub const TTS_OK: i32 = TtsErrorCode::Ok as i32;
pub const TTS_ERR_INVALID_ARG: i32 = TtsErrorCode::InvalidArg as i32;
pub const TTS_ERR_PANIC: i32 = TtsErrorCode::Panic as i32;
pub const TTS_ERR_NETWORK: i32 = TtsErrorCode::Network as i32;
pub const TTS_ERR_DECODE: i32 = TtsErrorCode::Decode as i32;
pub const TTS_ERR_AUDIO_OUTPUT: i32 = TtsErrorCode::AudioOutput as i32;
pub const TTS_ERR_QUEUE_EMPTY: i32 = TtsErrorCode::QueueEmpty as i32;

/// Event types dispatched from Rust background threads to Lua.
#[repr(i32)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TtsEventType {
    None = 0,
    ChunkStarted = 1,
    ChunkFinished = 2,
    PageCompleted = 3,
    BufferUpdated = 4,
    LatencyReport = 5,
    Error = 6,
}

// ============================================================================
// C-ABI Structs (#[repr(C)], 8-byte aligned)
// ============================================================================

/// Event structure passed through the lock-free SPSC ring buffer.
///
/// Layout is strictly aligned to 8-byte boundary across both 32-bit and 64-bit.
/// Uses fixed-size `error_message` buffer to eliminate dynamic allocation and Use-After-Free.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct TtsCoreEvent {
    pub duration_seconds: f64,    // 8 bytes (offset 0..7)
    pub event_type: i32,          // 4 bytes (offset 8..11)
    pub generation: u32,          // 4 bytes (offset 12..15)
    pub chunk_index: u32,         // 4 bytes (offset 16..19)
    pub total_chunks: u32,        // 4 bytes (offset 20..23)
    pub latency_ms: i32,          // 4 bytes (offset 24..27)
    pub _reserved: u32,           // 4 bytes (offset 28..31) - preserves 8-byte alignment
    pub error_message: [u8; 256], // 256 bytes (offset 32..287) - null-terminated C string buffer
}

impl Default for TtsCoreEvent {
    fn default() -> Self {
        Self {
            duration_seconds: 0.0,
            event_type: TtsEventType::None as i32,
            generation: 0,
            chunk_index: 0,
            total_chunks: 0,
            latency_ms: 0,
            _reserved: 0,
            error_message: [0; 256],
        }
    }
}

impl TtsCoreEvent {
    /// Helper to populate error message safely with null-termination.
    pub fn set_error_message(&mut self, msg: &str) {
        let bytes = msg.as_bytes();
        let copy_len = bytes.len().min(255);
        self.error_message[..copy_len].copy_from_slice(&bytes[..copy_len]);
        self.error_message[copy_len] = 0;
    }
}

/// Slot buffer status queried by Lua to render buffer indicators (`●●○○○`).
#[repr(C)]
#[derive(Debug, Clone, Copy, Default)]
pub struct TtsCoreSlotStatus {
    pub duration_seconds: f64, // 8 bytes (offset 0..7)
    pub chunk_index: u32,      // 4 bytes (offset 8..11)
    pub is_cached: i32,        // 4 bytes (offset 12..15)
    pub is_fetching: i32,      // 4 bytes (offset 16..19)
    pub is_playing: i32,       // 4 bytes (offset 20..23)
}

// ============================================================================
// Internal Engine & Opaque Context Handle
// ============================================================================

const STATE_IDLE: u8 = 0;
const STATE_PLAYING: u8 = 1;
const STATE_PAUSED: u8 = 2;

/// Internal engine state managed behind the opaque pointer.
pub struct TtsCoreEngine {
    pub config_json: String,
    pub state: Arc<AtomicU8>,
    pub current_generation: u32,
    pub current_chunk: u32,
}

impl TtsCoreEngine {
    pub fn new(config_json: String) -> Self {
        Self {
            config_json,
            state: Arc::new(AtomicU8::new(STATE_IDLE)),
            current_generation: 0,
            current_chunk: 0,
        }
    }
}

/// Opaque context handle exposed across C-ABI boundary.
pub struct TtsCoreContext {
    pub engine: TtsCoreEngine,
}

// ============================================================================
// Panic Safety Guard Macro
// ============================================================================

macro_rules! catch_unwind_ffi {
    ($fallback:expr, $block:block) => {
        match catch_unwind(std::panic::AssertUnwindSafe(|| $block)) {
            Ok(result) => result,
            Err(e) => {
                log::error!(
                    "[tts_core C-ABI FATAL] Caught panic in FFI boundary: {:?}",
                    e
                );
                $fallback
            }
        }
    };
}

// ============================================================================
// Exported C-ABI Functions
// ============================================================================

/// Creates a new TTS Core context instance with configuration JSON.
///
/// # Safety
/// - `config_json` must be a valid, null-terminated C string pointer.
/// - `out_error` may be null or must point to an initialized writable `i32`.
#[no_mangle]
pub unsafe extern "C" fn tts_core_context_create(
    config_json: *const c_char,
    out_error: *mut i32,
) -> *mut TtsCoreContext {
    catch_unwind_ffi!(ptr::null_mut(), {
        if config_json.is_null() {
            if !out_error.is_null() {
                *out_error = TTS_ERR_INVALID_ARG;
            }
            return ptr::null_mut();
        }

        let c_str = match CStr::from_ptr(config_json).to_str() {
            Ok(s) => s,
            Err(_) => {
                if !out_error.is_null() {
                    *out_error = TTS_ERR_INVALID_ARG;
                }
                return ptr::null_mut();
            }
        };

        crate::init_logging();

        let ctx = Box::new(TtsCoreContext {
            engine: TtsCoreEngine::new(c_str.to_string()),
        });

        if !out_error.is_null() {
            *out_error = TTS_OK;
        }

        Box::into_raw(ctx)
    })
}

/// Updates engine configuration dynamically.
///
/// # Safety
/// - `ctx` must be a valid non-null pointer returned by `tts_core_context_create`.
/// - `config_json` must be a valid, null-terminated C string pointer.
#[no_mangle]
pub unsafe extern "C" fn tts_core_context_update_config(
    ctx: *mut TtsCoreContext,
    config_json: *const c_char,
) -> i32 {
    catch_unwind_ffi!(TTS_ERR_PANIC, {
        if ctx.is_null() || config_json.is_null() {
            return TTS_ERR_INVALID_ARG;
        }

        let c_str = match CStr::from_ptr(config_json).to_str() {
            Ok(s) => s,
            Err(_) => return TTS_ERR_INVALID_ARG,
        };

        let context = &mut *ctx;
        context.engine.config_json = c_str.to_string();

        TTS_OK
    })
}

/// Loads chunks of the current page with a generation token.
///
/// # Safety
/// - `ctx` must be a valid non-null pointer returned by `tts_core_context_create`.
/// - `chunk_texts` must point to an array of valid null-terminated C string pointers.
/// - `chunk_count` must be greater than 0.
#[no_mangle]
pub unsafe extern "C" fn tts_core_queue_load_page(
    ctx: *mut TtsCoreContext,
    generation: u32,
    chunk_texts: *const *const c_char,
    chunk_count: u32,
) -> i32 {
    catch_unwind_ffi!(TTS_ERR_PANIC, {
        if ctx.is_null() || chunk_texts.is_null() || chunk_count == 0 {
            return TTS_ERR_INVALID_ARG;
        }

        let context = &mut *ctx;
        context.engine.current_generation = generation;
        context.engine.current_chunk = 0;

        TTS_OK
    })
}

/// Enqueues the next page for background prefetching (Cross-Page Pipeline).
///
/// # Safety
/// - `ctx` must be a valid non-null pointer returned by `tts_core_context_create`.
/// - `chunk_texts` must point to an array of valid null-terminated C string pointers.
/// - `chunk_count` must be greater than 0.
#[no_mangle]
pub unsafe extern "C" fn tts_core_queue_enqueue_next_page(
    ctx: *mut TtsCoreContext,
    _generation: u32,
    chunk_texts: *const *const c_char,
    chunk_count: u32,
) -> i32 {
    catch_unwind_ffi!(TTS_ERR_PANIC, {
        if ctx.is_null() || chunk_texts.is_null() || chunk_count == 0 {
            return TTS_ERR_INVALID_ARG;
        }

        TTS_OK
    })
}

/// Starts audio playback.
///
/// # Safety
/// - `ctx` must be a valid non-null pointer returned by `tts_core_context_create`.
#[no_mangle]
pub unsafe extern "C" fn tts_core_playback_play(ctx: *mut TtsCoreContext) -> i32 {
    catch_unwind_ffi!(TTS_ERR_PANIC, {
        if ctx.is_null() {
            return TTS_ERR_INVALID_ARG;
        }

        let context = &mut *ctx;
        context.engine.state.store(STATE_PLAYING, Ordering::SeqCst);

        TTS_OK
    })
}

/// Pauses audio playback.
///
/// # Safety
/// - `ctx` must be a valid non-null pointer returned by `tts_core_context_create`.
#[no_mangle]
pub unsafe extern "C" fn tts_core_playback_pause(ctx: *mut TtsCoreContext) -> i32 {
    catch_unwind_ffi!(TTS_ERR_PANIC, {
        if ctx.is_null() {
            return TTS_ERR_INVALID_ARG;
        }

        let context = &mut *ctx;
        context.engine.state.store(STATE_PAUSED, Ordering::SeqCst);

        TTS_OK
    })
}

/// Resumes paused audio playback.
///
/// # Safety
/// - `ctx` must be a valid non-null pointer returned by `tts_core_context_create`.
#[no_mangle]
pub unsafe extern "C" fn tts_core_playback_resume(ctx: *mut TtsCoreContext) -> i32 {
    catch_unwind_ffi!(TTS_ERR_PANIC, {
        if ctx.is_null() {
            return TTS_ERR_INVALID_ARG;
        }

        let context = &mut *ctx;
        context.engine.state.store(STATE_PLAYING, Ordering::SeqCst);

        TTS_OK
    })
}

/// Stops audio playback and resets engine state.
///
/// # Safety
/// - `ctx` must be a valid non-null pointer returned by `tts_core_context_create`.
#[no_mangle]
pub unsafe extern "C" fn tts_core_playback_stop(ctx: *mut TtsCoreContext) -> i32 {
    catch_unwind_ffi!(TTS_ERR_PANIC, {
        if ctx.is_null() {
            return TTS_ERR_INVALID_ARG;
        }

        let context = &mut *ctx;
        context.engine.state.store(STATE_IDLE, Ordering::SeqCst);

        TTS_OK
    })
}

/// Seeks to a specific chunk index on a given generation.
///
/// # Safety
/// - `ctx` must be a valid non-null pointer returned by `tts_core_context_create`.
#[no_mangle]
pub unsafe extern "C" fn tts_core_playback_seek(
    ctx: *mut TtsCoreContext,
    generation: u32,
    chunk_index: u32,
) -> i32 {
    catch_unwind_ffi!(TTS_ERR_PANIC, {
        if ctx.is_null() {
            return TTS_ERR_INVALID_ARG;
        }

        let context = &mut *ctx;
        context.engine.current_generation = generation;
        context.engine.current_chunk = chunk_index;

        TTS_OK
    })
}

/// Non-blocking poll for pending events from the SPSC Ring Buffer.
///
/// # Safety
/// - `ctx` must be a valid non-null pointer returned by `tts_core_context_create`.
/// - `out_event` must point to an initialized writable `TtsCoreEvent` buffer.
#[no_mangle]
pub unsafe extern "C" fn tts_core_event_poll(
    ctx: *mut TtsCoreContext,
    out_event: *mut TtsCoreEvent,
) -> i32 {
    catch_unwind_ffi!(TTS_ERR_PANIC, {
        if ctx.is_null() || out_event.is_null() {
            return TTS_ERR_INVALID_ARG;
        }

        // Return 0 (no event available in stub)
        0
    })
}

/// Retrieves slot buffer and caching status for UI rendering.
///
/// # Safety
/// - `ctx` must be a valid non-null pointer returned by `tts_core_context_create`.
/// - `out_status` must point to an initialized writable `TtsCoreSlotStatus` buffer.
#[no_mangle]
pub unsafe extern "C" fn tts_core_slot_get_status(
    ctx: *mut TtsCoreContext,
    chunk_index: u32,
    out_status: *mut TtsCoreSlotStatus,
) -> i32 {
    catch_unwind_ffi!(TTS_ERR_PANIC, {
        if ctx.is_null() || out_status.is_null() {
            return TTS_ERR_INVALID_ARG;
        }

        *out_status = TtsCoreSlotStatus {
            duration_seconds: 0.0,
            chunk_index,
            is_cached: 0,
            is_fetching: 0,
            is_playing: 0,
        };

        TTS_OK
    })
}

/// Destroys context and gracefully frees all native resources.
///
/// # Safety
/// - `ctx` must be a pointer returned by `tts_core_context_create` or NULL.
#[no_mangle]
pub unsafe extern "C" fn tts_core_context_destroy(ctx: *mut TtsCoreContext) {
    let _ = catch_unwind(std::panic::AssertUnwindSafe(|| {
        if !ctx.is_null() {
            drop(Box::from_raw(ctx));
        }
    }));
}

/// Helper function specifically for unit tests to verify the panic barrier.
///
/// # Safety
/// - Designed for unit testing FFI panic safety.
#[doc(hidden)]
#[no_mangle]
pub unsafe extern "C" fn tts_core_test_deliberate_panic(_ctx: *mut TtsCoreContext) -> i32 {
    catch_unwind_ffi!(TTS_ERR_PANIC, {
        panic!("Deliberate panic to test FFI boundary catch_unwind safety guard");
    })
}
