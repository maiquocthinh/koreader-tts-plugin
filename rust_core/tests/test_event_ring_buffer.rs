//! Unit tests for `event_ring_buffer.rs` verifying multi-threaded lock-free SPSC queue.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::Instant;

use tts_core::c_api::{TtsCoreEvent, TtsEventType};
use tts_core::event_ring_buffer::create_event_channel;

#[test]
fn test_ring_buffer_basic_push_pop() {
    let (mut prod, mut cons) = create_event_channel(Some(32));

    assert!(cons.is_empty());
    assert!(cons.pop().is_none());

    let event1 = TtsCoreEvent {
        event_type: TtsEventType::ChunkStarted as i32,
        chunk_index: 0,
        ..Default::default()
    };
    let event2 = TtsCoreEvent {
        event_type: TtsEventType::ChunkFinished as i32,
        chunk_index: 0,
        ..Default::default()
    };

    assert!(prod.push(event1));
    assert!(prod.push(event2));
    assert!(!cons.is_empty());

    let pop1 = cons.pop().expect("Expected event1");
    assert_eq!(pop1.event_type, TtsEventType::ChunkStarted as i32);
    assert_eq!(pop1.chunk_index, 0);

    let pop2 = cons.pop().expect("Expected event2");
    assert_eq!(pop2.event_type, TtsEventType::ChunkFinished as i32);
    assert_eq!(pop2.chunk_index, 0);

    assert!(cons.is_empty());
    assert!(cons.pop().is_none());
}

#[test]
fn test_ring_buffer_full_overflow_handling() {
    let (mut prod, mut cons) = create_event_channel(Some(16));

    // Fill ring buffer to capacity
    let mut pushed_count = 0;
    for i in 0..16 {
        let evt = TtsCoreEvent {
            chunk_index: i as u32,
            ..Default::default()
        };
        if prod.push(evt) {
            pushed_count += 1;
        }
    }
    assert_eq!(pushed_count, 16);

    // 17th push should fail cleanly without panicking
    let overflow_evt = TtsCoreEvent {
        chunk_index: 999,
        ..Default::default()
    };
    assert!(
        !prod.push(overflow_evt),
        "Push on full ring buffer must return false"
    );

    // Can still pop all 16 items
    for i in 0..16 {
        let evt = cons.pop().unwrap();
        assert_eq!(evt.chunk_index, i as u32);
    }
    assert!(cons.is_empty());
}

#[test]
fn test_ring_buffer_concurrent_stress() {
    let (mut prod, mut cons) = create_event_channel(Some(256));
    let total_events = 50_000u32;
    let done = Arc::new(AtomicBool::new(false));

    let done_clone = done.clone();
    let producer_handle = thread::spawn(move || {
        for i in 0..total_events {
            let evt = TtsCoreEvent {
                event_type: TtsEventType::ChunkStarted as i32,
                chunk_index: i,
                ..Default::default()
            };
            // Retry until pushed (spin lock simulation)
            while !prod.push(evt) {
                thread::yield_now();
            }
        }
        done_clone.store(true, Ordering::SeqCst);
    });

    let mut received_count = 0u32;
    while received_count < total_events {
        if let Some(evt) = cons.pop() {
            assert_eq!(evt.chunk_index, received_count);
            received_count += 1;
        } else if done.load(Ordering::SeqCst) && cons.is_empty() {
            break;
        } else {
            thread::yield_now();
        }
    }

    producer_handle.join().unwrap();
    assert_eq!(received_count, total_events);
}

#[test]
fn test_ring_buffer_sub_microsecond_polling_latency() {
    let (_prod, mut cons) = create_event_channel(Some(64));

    // Measure 100,000 empty pop operations (simulating Lua UIManager event loop ticks)
    let iterations = 100_000;
    let start = Instant::now();
    for _ in 0..iterations {
        let _ = cons.pop();
    }
    let elapsed = start.elapsed();
    let nanos_per_op = elapsed.as_nanos() / iterations as u128;

    // Must be well below 1000 ns (1 us)
    assert!(
        nanos_per_op < 500,
        "Empty poll latency too high: {} ns/op (SLA requires < 500ns)",
        nanos_per_op
    );
}
