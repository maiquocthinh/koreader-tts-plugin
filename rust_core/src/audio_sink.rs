//! Native audio output sink with true 0.00ms gapless sample chaining.
//!
//! Features:
//! - Real-time PCM audio rendering loop.
//! - Continuous sample feeding between chunks without stopping/restarting audio device.
//! - Automatic emission of `CHUNK_STARTED`, `CHUNK_FINISHED`, and `PAGE_COMPLETED` events.
//! - Safe state transitions: Idle, Playing, Paused.

use std::sync::atomic::{AtomicU8, Ordering};
use std::sync::{Arc, Mutex};
use thiserror::Error;

use crate::audio_decoder::AudioBuffer;
use crate::c_api::{TtsCoreEvent, TtsEventType};
use crate::event_ring_buffer::EventProducer;

// ============================================================================
// Errors
// ============================================================================

#[derive(Error, Debug)]
pub enum AudioError {
    #[error("Audio output device is not available on this hardware: {0}")]
    DeviceNotAvailable(String),

    #[error("Failed to initialize audio stream: {0}")]
    InitFailed(String),

    #[error("Audio sink internal render error")]
    RenderFailed,
}

impl AudioError {
    pub fn to_c_error_code(&self) -> i32 {
        crate::c_api::TTS_ERR_AUDIO_OUTPUT
    }
}

// ============================================================================
// Playback State
// ============================================================================

pub const SINK_STATE_IDLE: u8 = 0;
pub const SINK_STATE_PLAYING: u8 = 1;
pub const SINK_STATE_PAUSED: u8 = 2;

/// Playback cursor tracking position inside a decoded PCM audio buffer.
#[derive(Clone)]
pub struct AudioPlayCursor {
    pub generation: u32,
    pub chunk_index: u32,
    pub total_chunks: u32,
    pub buffer: Arc<AudioBuffer>,
    pub sample_offset: usize,
}

impl AudioPlayCursor {
    pub fn new(
        generation: u32,
        chunk_index: u32,
        total_chunks: u32,
        buffer: Arc<AudioBuffer>,
    ) -> Self {
        Self {
            generation,
            chunk_index,
            total_chunks,
            buffer,
            sample_offset: 0,
        }
    }

    /// Remaining samples in this chunk.
    pub fn remaining_samples(&self) -> usize {
        self.buffer.samples.len().saturating_sub(self.sample_offset)
    }
}

// ============================================================================
// Gapless PCM Renderer Core
// ============================================================================

pub struct GaplessRenderer {
    pub current_chunk: Option<AudioPlayCursor>,
    pub next_chunk: Option<AudioPlayCursor>,
    pub state: Arc<AtomicU8>,
    pub event_producer: Mutex<EventProducer>,
}

impl GaplessRenderer {
    pub fn new(event_producer: EventProducer, state: Arc<AtomicU8>) -> Self {
        Self {
            current_chunk: None,
            next_chunk: None,
            state,
            event_producer: Mutex::new(event_producer),
        }
    }

    /// Sets the current chunk and immediately emits `CHUNK_STARTED`.
    pub fn set_current(&mut self, cursor: AudioPlayCursor) {
        let event = TtsCoreEvent {
            duration_seconds: cursor.buffer.duration_seconds,
            event_type: TtsEventType::ChunkStarted as i32,
            generation: cursor.generation,
            chunk_index: cursor.chunk_index,
            total_chunks: cursor.total_chunks,
            latency_ms: 0,
            _reserved: 0,
            error_message: [0; 256],
        };
        if let Ok(mut prod) = self.event_producer.lock() {
            prod.push(event);
        }
        self.current_chunk = Some(cursor);
    }

    /// Queues the next chunk for zero-gap chaining.
    pub fn enqueue_next(&mut self, cursor: AudioPlayCursor) {
        self.next_chunk = Some(cursor);
    }

    /// Renders PCM samples into the hardware output buffer.
    ///
    /// Nối thẳng sample giữa câu N và N+1 trong cùng một render block mà không dừng luồng âm thanh!
    pub fn render_samples(&mut self, output: &mut [i16]) -> usize {
        if self.state.load(Ordering::SeqCst) != SINK_STATE_PLAYING {
            output.fill(0);
            return 0;
        }

        let mut samples_written = 0;
        let total_needed = output.len();

        while samples_written < total_needed {
            if let Some(ref mut current) = self.current_chunk {
                let remaining = current.remaining_samples();
                if remaining > 0 {
                    let to_copy = remaining.min(total_needed - samples_written);
                    let start = current.sample_offset;
                    let end = start + to_copy;

                    output[samples_written..samples_written + to_copy]
                        .copy_from_slice(&current.buffer.samples[start..end]);

                    current.sample_offset += to_copy;
                    samples_written += to_copy;

                    if current.remaining_samples() > 0 {
                        // Chunk still has remaining samples, continue
                        continue;
                    }
                }

                // Current chunk has finished playing!
                let finished_generation = current.generation;
                let finished_chunk = current.chunk_index;
                let finished_total = current.total_chunks;
                let finished_duration = current.buffer.duration_seconds;

                // 1. Emit CHUNK_FINISHED event
                let finished_event = TtsCoreEvent {
                    duration_seconds: finished_duration,
                    event_type: TtsEventType::ChunkFinished as i32,
                    generation: finished_generation,
                    chunk_index: finished_chunk,
                    total_chunks: finished_total,
                    latency_ms: 0,
                    _reserved: 0,
                    error_message: [0; 256],
                };
                if let Ok(mut prod) = self.event_producer.lock() {
                    prod.push(finished_event);
                }

                // 2. Chaining: Check if next chunk is ready!
                if let Some(next) = self.next_chunk.take() {
                    // True 0.00ms gapless transition!
                    let started_event = TtsCoreEvent {
                        duration_seconds: next.buffer.duration_seconds,
                        event_type: TtsEventType::ChunkStarted as i32,
                        generation: next.generation,
                        chunk_index: next.chunk_index,
                        total_chunks: next.total_chunks,
                        latency_ms: 0,
                        _reserved: 0,
                        error_message: [0; 256],
                    };
                    if let Ok(mut prod) = self.event_producer.lock() {
                        prod.push(started_event);
                    }
                    self.current_chunk = Some(next);
                } else {
                    // No next chunk available -> Page completed or underrun
                    self.current_chunk = None;
                    if finished_chunk + 1 >= finished_total {
                        let page_event = TtsCoreEvent {
                            duration_seconds: 0.0,
                            event_type: TtsEventType::PageCompleted as i32,
                            generation: finished_generation,
                            chunk_index: finished_chunk,
                            total_chunks: finished_total,
                            latency_ms: 0,
                            _reserved: 0,
                            error_message: [0; 256],
                        };
                        if let Ok(mut prod) = self.event_producer.lock() {
                            prod.push(page_event);
                        }
                    }
                    break;
                }
            } else {
                break;
            }
        }

        // Fill remaining output with silence
        if samples_written < total_needed {
            output[samples_written..].fill(0);
        }

        samples_written
    }

    /// Stops playback and clears both current and next chunks.
    pub fn stop(&mut self) {
        self.state.store(SINK_STATE_IDLE, Ordering::SeqCst);
        self.current_chunk = None;
        self.next_chunk = None;
    }
}

// ============================================================================
// AudioSink Handle
// ============================================================================

pub struct AudioSink {
    pub state: Arc<AtomicU8>,
    pub renderer: Arc<Mutex<GaplessRenderer>>,
}

impl AudioSink {
    /// Initializes a new AudioSink instance with an EventProducer channel.
    pub fn new(event_producer: EventProducer) -> Self {
        let state = Arc::new(AtomicU8::new(SINK_STATE_IDLE));
        let renderer = Arc::new(Mutex::new(GaplessRenderer::new(
            event_producer,
            state.clone(),
        )));

        Self { state, renderer }
    }

    /// Sets the current chunk and starts playback.
    pub fn set_current(&self, cursor: AudioPlayCursor) {
        let mut r = self.renderer.lock().unwrap();
        r.set_current(cursor);
    }

    /// Enqueues the next chunk for gapless chaining.
    pub fn enqueue_next(&self, cursor: AudioPlayCursor) {
        let mut r = self.renderer.lock().unwrap();
        r.enqueue_next(cursor);
    }

    /// Starts or resumes audio playback.
    pub fn play(&self) {
        self.state.store(SINK_STATE_PLAYING, Ordering::SeqCst);
    }

    /// Pauses audio playback without dropping current buffers.
    pub fn pause(&self) {
        self.state.store(SINK_STATE_PAUSED, Ordering::SeqCst);
    }

    /// Resumes paused audio playback.
    pub fn resume(&self) {
        self.state.store(SINK_STATE_PLAYING, Ordering::SeqCst);
    }

    /// Stops playback and clears queues.
    pub fn stop(&self) {
        let mut r = self.renderer.lock().unwrap();
        r.stop();
    }

    /// Current playback state (IDLE, PLAYING, PAUSED).
    pub fn state(&self) -> u8 {
        self.state.load(Ordering::SeqCst)
    }

    /// Pulls a block of samples (used by audio driver callback or test verification).
    pub fn render_block(&self, output: &mut [i16]) -> usize {
        let mut r = self.renderer.lock().unwrap();
        r.render_samples(output)
    }
}
