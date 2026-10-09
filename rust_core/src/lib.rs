//! Native Rust core engine for KOReader TTS plugin (`libtts_core.so`).
//!
//! Provides non-blocking background network I/O, audio decoding,
//! prefetch queue scheduling, and native audio sink integration.

pub mod audio_decoder;
pub mod audio_sink;
pub mod c_api;
pub mod cache_manager;
pub mod event_ring_buffer;
pub mod http_client;
pub mod prefetch_queue;

#[cfg(target_os = "android")]
pub fn init_logging() {
    android_logger::init_once(
        android_logger::Config::default()
            .with_tag("KOReaderTTS_Native")
            .with_max_level(log::LevelFilter::Debug),
    );
}

#[cfg(not(target_os = "android"))]
pub fn init_logging() {
    // Host development logging initialization
    let _ = env_logger::builder().is_test(true).try_init();
}
