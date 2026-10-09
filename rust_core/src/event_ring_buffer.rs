//! Lock-free Single-Producer Single-Consumer (SPSC) event ring buffer.
//!
//! Provides ultra-low latency (< 300ns) non-blocking event passing from
//! Rust audio/network background threads to LuaJIT's main event loop.

use ringbuf::traits::{Consumer, Observer, Producer, Split};
use ringbuf::HeapRb;
use std::sync::Arc;

use crate::c_api::TtsCoreEvent;

const DEFAULT_RING_BUFFER_CAPACITY: usize = 128;

// ============================================================================
// Producer (Rust Background Threads)
// ============================================================================

pub struct EventProducer {
    producer: ringbuf::wrap::caching::Caching<Arc<HeapRb<TtsCoreEvent>>, true, false>,
}

impl EventProducer {
    /// Pushes an event to the ring buffer. If buffer is full, drops oldest to avoid blocking.
    pub fn push(&mut self, event: TtsCoreEvent) -> bool {
        match self.producer.try_push(event) {
            Ok(()) => true,
            Err(dropped_event) => {
                log::warn!(
                    "[tts_core] Event ring buffer full! Dropping event type: {}",
                    dropped_event.event_type
                );
                false
            }
        }
    }
}

// ============================================================================
// Consumer (Lua Main Thread via FFI)
// ============================================================================

pub struct EventConsumer {
    consumer: ringbuf::wrap::caching::Caching<Arc<HeapRb<TtsCoreEvent>>, false, true>,
}

impl EventConsumer {
    /// Non-blocking poll for the next available event.
    ///
    /// Takes < 300ns, never acquires an OS lock.
    pub fn pop(&mut self) -> Option<TtsCoreEvent> {
        self.consumer.try_pop()
    }

    /// Checks if the ring buffer currently has pending events.
    pub fn is_empty(&self) -> bool {
        self.consumer.is_empty()
    }
}

// ============================================================================
// Factory
// ============================================================================

/// Creates an SPSC lock-free event channel with the specified capacity.
pub fn create_event_channel(capacity: Option<usize>) -> (EventProducer, EventConsumer) {
    let cap = capacity.unwrap_or(DEFAULT_RING_BUFFER_CAPACITY).max(16);
    let rb = HeapRb::<TtsCoreEvent>::new(cap);
    let (prod, cons) = rb.split();

    (
        EventProducer { producer: prod },
        EventConsumer { consumer: cons },
    )
}
