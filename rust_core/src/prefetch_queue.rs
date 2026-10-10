//! Sliding-window prioritized prefetch queue and cross-page pipeline.
//!
//! Scheduling Rules:
//! 1. Slot 0 (currently needed / seeked chunk) has absolute top priority.
//! 2. Speculative background prefetching (Slots 1..k) runs sequentially up to `preload_count`.
//! 3. Cross-page prefetching automatically fetches Slot 0 of next page when nearing end of current page.
//! 4. Atomic generation tokens instantly invalidate old requests on seek or page turn.

use crate::audio_decoder::AudioBuffer;
use crate::c_api::TtsCoreSlotStatus;
use std::sync::Arc;

// ============================================================================
// Data Structures
// ============================================================================

/// State of an individual chunk in the prefetch queue.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SlotState {
    Idle,
    Fetching,
    Ready,
    Failed,
}

/// Representation of an individual sentence slot.
#[derive(Debug, Clone)]
pub struct ChunkSlot {
    pub chunk_index: usize,
    pub text: String,
    pub state: SlotState,
    pub audio: Option<Arc<AudioBuffer>>,
    pub file_path: Option<String>,
    pub duration_seconds: f64,
}

impl ChunkSlot {
    pub fn new(chunk_index: usize, text: String) -> Self {
        Self {
            chunk_index,
            text,
            state: SlotState::Idle,
            audio: None,
            file_path: None,
            duration_seconds: 0.0,
        }
    }
}

/// Target chunk identified for the next network download.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FetchTarget {
    pub generation: u32,
    pub is_next_page: bool,
    pub chunk_index: usize,
    pub text: String,
    pub is_urgent: bool,
}

// ============================================================================
// Prefetch Queue Implementation
// ============================================================================

pub struct PrefetchQueue {
    pub current_generation: u32,
    pub current_playing_index: usize,
    pub current_slots: Vec<ChunkSlot>,
    pub next_page_generation: u32,
    pub next_page_slots: Option<Vec<ChunkSlot>>,
    pub preload_count: usize,
}

impl PrefetchQueue {
    /// Initializes a new prefetch queue with configured preload sliding window count.
    pub fn new(preload_count: usize) -> Self {
        Self {
            current_generation: 0,
            current_playing_index: 0,
            current_slots: Vec::new(),
            next_page_generation: 0,
            next_page_slots: None,
            preload_count: if preload_count == 0 {
                1
            } else {
                preload_count.min(10)
            },
        }
    }

    /// Loads a new set of sentences for the current page, advancing generation token.
    pub fn load_page(&mut self, generation: u32, texts: Vec<String>) {
        self.current_generation = generation;
        self.current_playing_index = 0;

        // Cross-page promotion: If next page was prefetched and generation matches, promote existing slots!
        if self.next_page_generation == generation && self.next_page_slots.is_some() {
            let next_slots = self.next_page_slots.take().unwrap();
            if next_slots.len() == texts.len() {
                self.current_slots = next_slots;
                return;
            }
        }

        self.current_slots = texts
            .into_iter()
            .enumerate()
            .map(|(idx, txt)| ChunkSlot::new(idx, txt))
            .collect();

        // Clear next page if generation advanced past it
        if self.next_page_generation <= generation {
            self.next_page_slots = None;
        }
    }

    /// Enqueues the next page for speculative background prefetching (Cross-Page Pipeline).
    pub fn enqueue_next_page(&mut self, next_generation: u32, texts: Vec<String>) {
        self.next_page_generation = next_generation;
        self.next_page_slots = Some(
            texts
                .into_iter()
                .enumerate()
                .map(|(idx, txt)| ChunkSlot::new(idx, txt))
                .collect(),
        );
    }

    /// Seeks to a specific chunk index on a given generation token.
    pub fn seek(&mut self, generation: u32, target_index: usize) {
        self.current_generation = generation;
        if target_index < self.current_slots.len() {
            self.current_playing_index = target_index;
        }
    }

    /// Advances the currently playing index.
    pub fn advance_playing(&mut self) -> Option<usize> {
        if self.current_playing_index + 1 < self.current_slots.len() {
            self.current_playing_index += 1;
            Some(self.current_playing_index)
        } else {
            None
        }
    }

    /// Sets a chunk to Fetching state.
    pub fn set_chunk_fetching(&mut self, generation: u32, is_next_page: bool, chunk_index: usize) {
        if is_next_page {
            if self.next_page_generation == generation {
                if let Some(ref mut slots) = self.next_page_slots {
                    if let Some(slot) = slots.get_mut(chunk_index) {
                        slot.state = SlotState::Fetching;
                    }
                }
            }
        } else if self.current_generation == generation {
            if let Some(slot) = self.current_slots.get_mut(chunk_index) {
                slot.state = SlotState::Fetching;
            }
        }
    }

    /// Marks a chunk as Ready with its decoded PCM audio buffer.
    pub fn set_chunk_ready(
        &mut self,
        generation: u32,
        is_next_page: bool,
        chunk_index: usize,
        audio: Arc<AudioBuffer>,
    ) {
        let duration = audio.duration_seconds;
        self.set_chunk_ready_full(generation, is_next_page, chunk_index, Some(audio), None, duration);
    }

    /// Marks a chunk as Ready with optional in-memory audio buffer and cached disk file path.
    pub fn set_chunk_ready_full(
        &mut self,
        generation: u32,
        is_next_page: bool,
        chunk_index: usize,
        audio: Option<Arc<AudioBuffer>>,
        file_path: Option<String>,
        duration: f64,
    ) {
        if is_next_page {
            if self.next_page_generation == generation {
                if let Some(ref mut slots) = self.next_page_slots {
                    if let Some(slot) = slots.get_mut(chunk_index) {
                        slot.state = SlotState::Ready;
                        slot.duration_seconds = duration;
                        slot.audio = audio;
                        slot.file_path = file_path;
                    }
                }
            }
        } else if self.current_generation == generation {
            if let Some(slot) = self.current_slots.get_mut(chunk_index) {
                slot.state = SlotState::Ready;
                slot.duration_seconds = duration;
                slot.audio = audio;
                slot.file_path = file_path;
            }
        }
    }

    /// Returns the cached audio file path for a given chunk index if ready.
    pub fn get_slot_path(&self, chunk_index: usize) -> Option<String> {
        self.current_slots
            .get(chunk_index)
            .and_then(|s| {
                if s.state == SlotState::Ready {
                    s.file_path.clone()
                } else {
                    None
                }
            })
    }

    /// Marks a chunk as Failed.
    pub fn set_chunk_failed(&mut self, generation: u32, is_next_page: bool, chunk_index: usize) {
        if is_next_page {
            if self.next_page_generation == generation {
                if let Some(ref mut slots) = self.next_page_slots {
                    if let Some(slot) = slots.get_mut(chunk_index) {
                        slot.state = SlotState::Failed;
                    }
                }
            }
        } else if self.current_generation == generation {
            if let Some(slot) = self.current_slots.get_mut(chunk_index) {
                slot.state = SlotState::Failed;
            }
        }
    }

    /// Returns the audio buffer for a given chunk index on the current page.
    pub fn get_chunk_audio(&self, chunk_index: usize) -> Option<Arc<AudioBuffer>> {
        self.current_slots
            .get(chunk_index)
            .and_then(|s| s.audio.clone())
    }

    /// Determines the next chunk that needs to be fetched from the network.
    ///
    /// Priority Order:
    /// 1. Slot 0 (current playing chunk) if not Ready/Fetching.
    /// 2. Subsequent chunks in current page up to `preload_count`.
    /// 3. Cross-page chunk 0 of next page if current page window is satisfied.
    pub fn get_next_fetch_target(&self) -> Option<FetchTarget> {
        if self.current_slots.is_empty() {
            return None;
        }

        // Rule 1: Urgent Slot 0 (Current playing chunk)
        if let Some(current_slot) = self.current_slots.get(self.current_playing_index) {
            if current_slot.state == SlotState::Idle {
                return Some(FetchTarget {
                    generation: self.current_generation,
                    is_next_page: false,
                    chunk_index: self.current_playing_index,
                    text: current_slot.text.clone(),
                    is_urgent: true,
                });
            }
        }

        // Rule 2: Background prefetch in current page sliding window
        let window_end =
            (self.current_playing_index + self.preload_count + 1).min(self.current_slots.len());
        for idx in (self.current_playing_index + 1)..window_end {
            if let Some(slot) = self.current_slots.get(idx) {
                if slot.state == SlotState::Idle {
                    return Some(FetchTarget {
                        generation: self.current_generation,
                        is_next_page: false,
                        chunk_index: idx,
                        text: slot.text.clone(),
                        is_urgent: false,
                    });
                }
            }
        }

        // Rule 3: Cross-Page Prefetch (Slot 0 of next page)
        // Triggered when current page is near end or fully prefetched
        if let Some(ref next_slots) = self.next_page_slots {
            if let Some(next_slot_0) = next_slots.first() {
                if next_slot_0.state == SlotState::Idle {
                    return Some(FetchTarget {
                        generation: self.next_page_generation,
                        is_next_page: true,
                        chunk_index: 0,
                        text: next_slot_0.text.clone(),
                        is_urgent: false,
                    });
                }
            }
        }

        None
    }

    /// Returns the C-ABI compatible slot status for UI rendering.
    pub fn get_slot_status(&self, chunk_index: usize) -> TtsCoreSlotStatus {
        if let Some(slot) = self.current_slots.get(chunk_index) {
            TtsCoreSlotStatus {
                duration_seconds: slot.duration_seconds,
                chunk_index: chunk_index as u32,
                is_cached: if slot.state == SlotState::Ready { 1 } else { 0 },
                is_fetching: if slot.state == SlotState::Fetching {
                    1
                } else {
                    0
                },
                is_playing: if chunk_index == self.current_playing_index {
                    1
                } else {
                    0
                },
            }
        } else {
            TtsCoreSlotStatus {
                duration_seconds: 0.0,
                chunk_index: chunk_index as u32,
                is_cached: 0,
                is_fetching: 0,
                is_playing: 0,
            }
        }
    }

    /// Checks if current page has played through the final chunk.
    pub fn is_page_completed(&self) -> bool {
        if self.current_slots.is_empty() {
            return false;
        }
        self.current_playing_index >= self.current_slots.len() - 1
            && self
                .current_slots
                .last()
                .map(|s| s.state == SlotState::Ready)
                .unwrap_or(false)
    }
}
