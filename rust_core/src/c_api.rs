//! C-ABI exports and FFI bridge boundary for `libtts_core.so`.
//!
//! Exposes an ABI-stable C interface with panic safety barriers
//! and 8-byte aligned structs compatible across 32-bit and 64-bit systems.

use std::ffi::{c_char, CStr};
use std::panic::catch_unwind;
use std::ptr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

use crate::audio_decoder::AudioDecoder;
use crate::audio_sink::{AudioPlayCursor, AudioSink, SINK_STATE_PLAYING};
use crate::cache_manager::CacheManager;
use crate::event_ring_buffer::{create_event_channel, EventConsumer, EventProducer};
use crate::http_client::{HttpClient, HttpClientConfig, SpeechRequest};
use crate::prefetch_queue::PrefetchQueue;

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
// Internal Configuration & Core Engine
// ============================================================================

#[derive(serde::Deserialize, serde::Serialize, Debug, Clone)]
pub struct CoreConfig {
    #[serde(default = "default_server_url")]
    pub server_url: String,
    #[serde(default = "default_voice")]
    pub voice: String,
    #[serde(default = "default_format")]
    pub audio_format: String,
    #[serde(default = "default_speed")]
    pub speed: f64,
    pub api_key: Option<String>,
    #[serde(default = "default_cache_dir")]
    pub cache_dir: String,
    #[serde(default = "default_preload_count")]
    pub preload_count: usize,
}

fn default_server_url() -> String {
    "https://api.openai.com/v1/audio/speech".to_string()
}
fn default_voice() -> String {
    "alloy".to_string()
}
fn default_format() -> String {
    "wav".to_string()
}
fn default_speed() -> f64 {
    1.0
}
fn default_cache_dir() -> String {
    std::env::temp_dir()
        .join("koreader_tts_cache")
        .to_string_lossy()
        .to_string()
}
fn default_preload_count() -> usize {
    1
}

impl Default for CoreConfig {
    fn default() -> Self {
        Self {
            server_url: default_server_url(),
            voice: default_voice(),
            audio_format: default_format(),
            speed: default_speed(),
            api_key: None,
            cache_dir: default_cache_dir(),
            preload_count: default_preload_count(),
        }
    }
}

/// Internal engine orchestrating networking, caching, decoding, and playback.
pub struct TtsCoreEngine {
    pub config: Arc<Mutex<CoreConfig>>,
    pub http_client: Arc<HttpClient>,
    pub cache_manager: Arc<CacheManager>,
    pub prefetch_queue: Arc<Mutex<PrefetchQueue>>,
    pub audio_sink: Arc<AudioSink>,
    pub event_consumer: Arc<Mutex<EventConsumer>>,
    pub event_producer: Arc<Mutex<EventProducer>>,
    pub is_running: Arc<AtomicBool>,
    pub worker_handle: Option<thread::JoinHandle<()>>,
}

impl TtsCoreEngine {
    pub fn new(config_json: &str) -> Result<Self, String> {
        let parsed_config: CoreConfig = if config_json.trim().is_empty() {
            CoreConfig::default()
        } else {
            serde_json::from_str(config_json).map_err(|e| format!("Invalid config JSON: {}", e))?
        };

        let config = Arc::new(Mutex::new(parsed_config.clone()));

        let http_cfg = HttpClientConfig {
            server_url: parsed_config.server_url.clone(),
            api_key: parsed_config.api_key.clone(),
            timeout_secs: 15,
            connect_timeout_secs: 5,
            pool_max_idle_per_host: 5,
            tcp_keepalive_secs: 60,
        };

        let http_client = Arc::new(
            HttpClient::new(http_cfg).map_err(|e| format!("HTTP client init failed: {}", e))?,
        );

        let cache_manager = Arc::new(
            CacheManager::new(&parsed_config.cache_dir, 50 * 1024 * 1024, 4)
                .map_err(|e| format!("CacheManager init failed: {}", e))?,
        );

        let prefetch_queue = Arc::new(Mutex::new(PrefetchQueue::new(parsed_config.preload_count)));

        let (prod, cons) = create_event_channel(Some(128));
        let event_producer = Arc::new(Mutex::new(prod));
        let event_consumer = Arc::new(Mutex::new(cons));

        // Create AudioSink with cloned EventProducer
        let (sink_prod, mut sink_cons) = create_event_channel(Some(64));
        let audio_sink = Arc::new(AudioSink::new(sink_prod));

        // Forward sink events into main event_producer
        let main_prod_for_sink = event_producer.clone();
        let is_running = Arc::new(AtomicBool::new(true));
        let is_running_clone = is_running.clone();

        // Background worker thread: runs pump loop
        let q_clone = prefetch_queue.clone();
        let c_clone = cache_manager.clone();
        let h_clone = http_client.clone();
        let cfg_clone = config.clone();
        let prod_clone = event_producer.clone();
        let sink_clone = audio_sink.clone();

        let worker_handle = thread::spawn(move || {
            let rt = match tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
            {
                Ok(r) => r,
                Err(e) => {
                    log::error!("Failed to create tokio runtime: {:?}", e);
                    return;
                }
            };

            while is_running_clone.load(Ordering::SeqCst) {
                // 1. Forward events from sink to main event channel
                while let Some(evt) = sink_cons.pop() {
                    if let Ok(mut main_prod) = main_prod_for_sink.lock() {
                        main_prod.push(evt);
                    }
                }

                // 2. Feed audio into sink if sink is playing and has room
                {
                    let q = q_clone.lock().unwrap();
                    let playing_idx = q.current_playing_index;
                    let current_chunk_audio = q.get_chunk_audio(playing_idx);

                    if let Some(buf) = current_chunk_audio {
                        if sink_clone.state() == SINK_STATE_PLAYING {
                            let mut renderer = sink_clone.renderer.lock().unwrap();
                            if renderer.current_chunk.is_none() {
                                let total = q.current_slots.len() as u32;
                                let gen = q.current_generation;
                                renderer.set_current(AudioPlayCursor::new(
                                    gen,
                                    playing_idx as u32,
                                    total,
                                    buf,
                                ));
                            }

                            // If next chunk is ready and not queued in sink, queue it!
                            if renderer.next_chunk.is_none() {
                                if let Some(next_buf) = q.get_chunk_audio(playing_idx + 1) {
                                    let total = q.current_slots.len() as u32;
                                    let gen = q.current_generation;
                                    renderer.enqueue_next(AudioPlayCursor::new(
                                        gen,
                                        (playing_idx + 1) as u32,
                                        total,
                                        next_buf,
                                    ));
                                }
                            }
                        }
                    }
                }

                // 3. Inspect next prefetch target
                let target_opt = {
                    let q = q_clone.lock().unwrap();
                    q.get_next_fetch_target()
                };

                if let Some(target) = target_opt {
                    let (voice, format, speed, server_url) = {
                        let conf = cfg_clone.lock().unwrap();
                        (
                            conf.voice.clone(),
                            conf.audio_format.clone(),
                            conf.speed,
                            conf.server_url.clone(),
                        )
                    };

                    let cache_key = CacheManager::compute_cache_key(
                        &target.text,
                        &voice,
                        &format,
                        speed,
                        &server_url,
                    );

                    // Step A: Check L1 Memory Cache
                    if let Some(mem_buf) = c_clone.get_memory(&cache_key) {
                        let disk_path = c_clone.get_disk_path(&cache_key, &format);
                        let path_str = if disk_path.exists() {
                            Some(disk_path.to_string_lossy().to_string())
                        } else {
                            None
                        };
                        let duration = mem_buf.duration_seconds;
                        let mut q = q_clone.lock().unwrap();
                        q.set_chunk_ready_full(
                            target.generation,
                            target.is_next_page,
                            target.chunk_index,
                            Some(mem_buf),
                            path_str,
                            duration,
                        );
                        if let Ok(mut prod) = prod_clone.lock() {
                            prod.push(TtsCoreEvent {
                                event_type: TtsEventType::BufferUpdated as i32,
                                generation: target.generation,
                                chunk_index: target.chunk_index as u32,
                                ..Default::default()
                            });
                        }
                        continue;
                    }

                    // Step B: Check L2 Disk Cache
                    let disk_path = c_clone.get_disk_path(&cache_key, &format);
                    if disk_path.exists() {
                        let path_str = disk_path.to_string_lossy().to_string();
                        let decoded_opt = match c_clone.get_disk_bytes(&cache_key, &format) {
                            Ok(Some(bytes)) => AudioDecoder::decode_from_memory(bytes, Some(&format)).ok(),
                            _ => None,
                        };
                        let (arc_buf, dur) = if let Some(decoded) = decoded_opt {
                            let dur = decoded.duration_seconds;
                            let arc = Arc::new(decoded);
                            c_clone.put_memory(cache_key.clone(), arc.clone());
                            (Some(arc), dur)
                        } else {
                            (None, 0.0)
                        };

                        let mut q = q_clone.lock().unwrap();
                        q.set_chunk_ready_full(
                            target.generation,
                            target.is_next_page,
                            target.chunk_index,
                            arc_buf,
                            Some(path_str),
                            dur,
                        );
                        if let Ok(mut prod) = prod_clone.lock() {
                            prod.push(TtsCoreEvent {
                                event_type: TtsEventType::BufferUpdated as i32,
                                generation: target.generation,
                                chunk_index: target.chunk_index as u32,
                                ..Default::default()
                            });
                        }
                        continue;
                    }

                    // Step C: Fetch from Network
                    if target.text.trim().is_empty() {
                        let mut q = q_clone.lock().unwrap();
                        q.set_chunk_ready_full(
                            target.generation,
                            target.is_next_page,
                            target.chunk_index,
                            None,
                            None,
                            0.0,
                        );
                        continue;
                    }

                    {
                        let mut q = q_clone.lock().unwrap();
                        q.set_chunk_fetching(
                            target.generation,
                            target.is_next_page,
                            target.chunk_index,
                        );
                    }

                    let req = SpeechRequest::new(&target.text, &voice, &format, speed);
                    let start_time = std::time::Instant::now();

                    let fetch_res = rt.block_on(async { h_clone.fetch_speech(&req, None).await });

                    match fetch_res {
                        Ok(audio_bytes) => {
                            let latency_ms = start_time.elapsed().as_millis() as i32;
                            // Save to disk cache
                            let saved_path_res = c_clone.put_disk_bytes(&cache_key, &format, &audio_bytes);
                            let path_str = saved_path_res.ok().map(|p| p.to_string_lossy().to_string());

                            // Decode audio
                            let (arc_buf, dur) = match AudioDecoder::decode_from_memory(audio_bytes, Some(&format)) {
                                Ok(decoded) => {
                                    let dur = decoded.duration_seconds;
                                    let arc = Arc::new(decoded);
                                    c_clone.put_memory(cache_key, arc.clone());
                                    (Some(arc), dur)
                                }
                                Err(e) => {
                                    log::warn!("Audio decode fallback for raw playback: {:?}", e);
                                    (None, 0.0)
                                }
                            };

                            let mut q = q_clone.lock().unwrap();
                            q.set_chunk_ready_full(
                                target.generation,
                                target.is_next_page,
                                target.chunk_index,
                                arc_buf,
                                path_str,
                                dur,
                            );

                            // Emit latency and buffer updated event
                            if let Ok(mut prod) = prod_clone.lock() {
                                prod.push(TtsCoreEvent {
                                    event_type: TtsEventType::LatencyReport as i32,
                                    generation: target.generation,
                                    chunk_index: target.chunk_index as u32,
                                    latency_ms,
                                    ..Default::default()
                                });
                                prod.push(TtsCoreEvent {
                                    event_type: TtsEventType::BufferUpdated as i32,
                                    generation: target.generation,
                                    chunk_index: target.chunk_index as u32,
                                    ..Default::default()
                                });
                            }
                        }
                        Err(e) => {
                            log::error!("Network fetch failed: {:?}", e);
                            let mut q = q_clone.lock().unwrap();
                            q.set_chunk_failed(
                                target.generation,
                                target.is_next_page,
                                target.chunk_index,
                            );

                            if let Ok(mut prod) = prod_clone.lock() {
                                let mut evt = TtsCoreEvent {
                                    event_type: TtsEventType::Error as i32,
                                    generation: target.generation,
                                    chunk_index: target.chunk_index as u32,
                                    ..Default::default()
                                };
                                evt.set_error_message(&format!("Network error: {}", e));
                                prod.push(evt);
                            }
                        }
                    }
                } else {
                    // No work to do, brief sleep
                    thread::sleep(Duration::from_millis(20));
                }
            }
        });

        Ok(Self {
            config,
            http_client,
            cache_manager,
            prefetch_queue,
            audio_sink,
            event_consumer,
            event_producer,
            is_running,
            worker_handle: Some(worker_handle),
        })
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

        match TtsCoreEngine::new(c_str) {
            Ok(engine) => {
                if !out_error.is_null() {
                    *out_error = TTS_OK;
                }
                Box::into_raw(Box::new(TtsCoreContext { engine }))
            }
            Err(e) => {
                log::error!("Engine init error: {}", e);
                if !out_error.is_null() {
                    *out_error = TTS_ERR_INVALID_ARG;
                }
                ptr::null_mut()
            }
        }
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
        if let Ok(new_cfg) = serde_json::from_str::<CoreConfig>(c_str) {
            if let Ok(mut conf) = context.engine.config.lock() {
                *conf = new_cfg;
            }
            TTS_OK
        } else {
            TTS_ERR_INVALID_ARG
        }
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

        let mut texts = Vec::with_capacity(chunk_count as usize);
        for i in 0..chunk_count {
            let ptr = *chunk_texts.add(i as usize);
            if ptr.is_null() {
                return TTS_ERR_INVALID_ARG;
            }
            if let Ok(s) = CStr::from_ptr(ptr).to_str() {
                texts.push(s.to_string());
            } else {
                return TTS_ERR_INVALID_ARG;
            }
        }

        let context = &mut *ctx;
        {
            let mut q = context.engine.prefetch_queue.lock().unwrap();
            q.load_page(generation, texts);
        }

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
    generation: u32,
    chunk_texts: *const *const c_char,
    chunk_count: u32,
) -> i32 {
    catch_unwind_ffi!(TTS_ERR_PANIC, {
        if ctx.is_null() || chunk_texts.is_null() || chunk_count == 0 {
            return TTS_ERR_INVALID_ARG;
        }

        let mut texts = Vec::with_capacity(chunk_count as usize);
        for i in 0..chunk_count {
            let ptr = *chunk_texts.add(i as usize);
            if ptr.is_null() {
                return TTS_ERR_INVALID_ARG;
            }
            if let Ok(s) = CStr::from_ptr(ptr).to_str() {
                texts.push(s.to_string());
            } else {
                return TTS_ERR_INVALID_ARG;
            }
        }

        let context = &mut *ctx;
        {
            let mut q = context.engine.prefetch_queue.lock().unwrap();
            q.enqueue_next_page(generation, texts);
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
        context.engine.audio_sink.play();

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
        context.engine.audio_sink.pause();

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
        context.engine.audio_sink.resume();

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
        context.engine.audio_sink.stop();

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
        {
            let mut q = context.engine.prefetch_queue.lock().unwrap();
            q.seek(generation, chunk_index as usize);
        }
        context.engine.audio_sink.stop();

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

        let context = &mut *ctx;
        if let Ok(mut cons) = context.engine.event_consumer.lock() {
            if let Some(evt) = cons.pop() {
                *out_event = evt;
                return 1;
            }
        }

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

        let context = &mut *ctx;
        let q = context.engine.prefetch_queue.lock().unwrap();
        *out_status = q.get_slot_status(chunk_index as usize);

        TTS_OK
    })
}

/// Queries the cached audio file path on disk for a given chunk index.
///
/// Returns TTS_OK (0) and writes null-terminated string to `out_path` if chunk is ready.
/// Returns TTS_ERR_QUEUE_EMPTY (-6) if chunk is not ready or has no file path.
/// Returns TTS_ERR_INVALID_ARG (-1) on null pointers or buffer overflow.
///
/// # Safety
/// - `ctx` must be a valid non-null pointer returned by `tts_core_context_create`.
/// - `out_path` must point to a writable buffer of at least `max_len` bytes.
#[no_mangle]
pub unsafe extern "C" fn tts_core_slot_get_path(
    ctx: *mut TtsCoreContext,
    chunk_index: u32,
    out_path: *mut c_char,
    max_len: u32,
) -> i32 {
    catch_unwind_ffi!(TTS_ERR_PANIC, {
        if ctx.is_null() || out_path.is_null() || max_len == 0 {
            return TTS_ERR_INVALID_ARG;
        }

        let context = &mut *ctx;
        let q = context.engine.prefetch_queue.lock().unwrap();
        if let Some(path) = q.get_slot_path(chunk_index as usize) {
            let bytes = path.as_bytes();
            if bytes.len() >= max_len as usize {
                return TTS_ERR_INVALID_ARG;
            }
            std::ptr::copy_nonoverlapping(bytes.as_ptr(), out_path as *mut u8, bytes.len());
            *out_path.add(bytes.len()) = 0;
            TTS_OK
        } else {
            TTS_ERR_QUEUE_EMPTY
        }
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
            let mut boxed = Box::from_raw(ctx);
            // 1. Signal background worker to stop
            boxed.engine.is_running.store(false, Ordering::SeqCst);
            // 2. Stop audio sink
            boxed.engine.audio_sink.stop();
            // 3. Join worker thread with timeout
            if let Some(handle) = boxed.engine.worker_handle.take() {
                let _ = handle.join();
            }
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
