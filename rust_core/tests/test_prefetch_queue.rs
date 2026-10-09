//! Unit tests for `prefetch_queue.rs` verifying sliding window and cross-page pipeline.

use std::sync::Arc;
use tts_core::audio_decoder::AudioBuffer;
use tts_core::prefetch_queue::*;

fn make_dummy_audio(duration_secs: f64) -> Arc<AudioBuffer> {
    let sample_rate = 24000;
    let num_samples = (sample_rate as f64 * duration_secs) as usize;
    Arc::new(AudioBuffer::new(vec![0i16; num_samples], sample_rate, 1).unwrap())
}

#[test]
fn test_sliding_window_prioritized_scheduling() {
    let mut queue = PrefetchQueue::new(3); // Preload count = 3

    let sentences = (0..10).map(|i| format!("Câu văn số {}.", i)).collect();
    queue.load_page(1, sentences);

    // Initial target must be Urgent Slot 0
    let target0 = queue
        .get_next_fetch_target()
        .expect("Expected fetch target for Slot 0");
    assert_eq!(target0.chunk_index, 0);
    assert_eq!(target0.generation, 1);
    assert!(target0.is_urgent, "Slot 0 must be urgent");
    assert!(!target0.is_next_page);

    // Mark Slot 0 as fetching, next target must be Slot 1 (background)
    queue.set_chunk_fetching(1, false, 0);
    let target1 = queue
        .get_next_fetch_target()
        .expect("Expected fetch target for Slot 1");
    assert_eq!(target1.chunk_index, 1);
    assert!(!target1.is_urgent, "Slot 1 should be background prefetch");

    // Complete Slot 0 and Slot 1
    queue.set_chunk_ready(1, false, 0, make_dummy_audio(1.5));
    queue.set_chunk_ready(1, false, 1, make_dummy_audio(2.0));

    // Next target should be Slot 2, then Slot 3
    let target2 = queue.get_next_fetch_target().expect("Expected Slot 2");
    assert_eq!(target2.chunk_index, 2);
    queue.set_chunk_ready(1, false, 2, make_dummy_audio(1.0));

    let target3 = queue.get_next_fetch_target().expect("Expected Slot 3");
    assert_eq!(target3.chunk_index, 3);
    queue.set_chunk_ready(1, false, 3, make_dummy_audio(1.0));

    // Now window (0 + 3 = 3) is full. Slot 4 should NOT be fetched yet while playing index is 0
    assert!(
        queue.get_next_fetch_target().is_none(),
        "Sliding window of 3 slots should be saturated"
    );

    // Advance playing index to 1: window shifts to include Slot 4!
    assert_eq!(queue.advance_playing(), Some(1));
    let target4 = queue
        .get_next_fetch_target()
        .expect("Expected Slot 4 after window shift");
    assert_eq!(target4.chunk_index, 4);
}

#[test]
fn test_seek_invalidates_and_prioritizes_new_target() {
    let mut queue = PrefetchQueue::new(3);
    let sentences = (0..10).map(|i| format!("Câu {}.", i)).collect();
    queue.load_page(1, sentences);

    // Initial target is Slot 0
    assert_eq!(queue.get_next_fetch_target().unwrap().chunk_index, 0);

    // User seeks to Chunk 6 with generation 2
    queue.seek(2, 6);

    // Urgent target must now immediately become Chunk 6!
    let seek_target = queue
        .get_next_fetch_target()
        .expect("Expected target after seek");
    assert_eq!(seek_target.chunk_index, 6);
    assert_eq!(seek_target.generation, 2);
    assert!(seek_target.is_urgent);
}

#[test]
fn test_cross_page_prefetch_pipeline() {
    let mut queue = PrefetchQueue::new(2); // Preload count = 2
    let page1_texts = vec!["P1 C0".to_string(), "P1 C1".to_string()];
    queue.load_page(1, page1_texts);

    // Make Page 1 slots ready
    queue.set_chunk_ready(1, false, 0, make_dummy_audio(1.0));
    queue.set_chunk_ready(1, false, 1, make_dummy_audio(1.0));

    // Page 1 is fully prefetched. Enqueue Page 2!
    let page2_texts = vec!["P2 C0".to_string(), "P2 C1".to_string()];
    queue.enqueue_next_page(2, page2_texts);

    // Next fetch target must automatically be Slot 0 of Page 2!
    let next_target = queue
        .get_next_fetch_target()
        .expect("Expected cross-page prefetch target");
    assert!(next_target.is_next_page, "Target must be cross-page");
    assert_eq!(next_target.generation, 2);
    assert_eq!(next_target.chunk_index, 0);
    assert_eq!(next_target.text, "P2 C0");
}

#[test]
fn test_slot_status_for_ui_rendering() {
    let mut queue = PrefetchQueue::new(3);
    queue.load_page(1, vec!["Câu 0".to_string(), "Câu 1".to_string()]);

    let status0 = queue.get_slot_status(0);
    assert_eq!(status0.is_cached, 0);
    assert_eq!(status0.is_fetching, 0);
    assert_eq!(status0.is_playing, 1);

    queue.set_chunk_fetching(1, false, 0);
    assert_eq!(queue.get_slot_status(0).is_fetching, 1);

    queue.set_chunk_ready(1, false, 0, make_dummy_audio(2.5));
    let status0_ready = queue.get_slot_status(0);
    assert_eq!(status0_ready.is_cached, 1);
    assert_eq!(status0_ready.is_fetching, 0);
    assert!((status0_ready.duration_seconds - 2.5).abs() < 1e-6);
}
