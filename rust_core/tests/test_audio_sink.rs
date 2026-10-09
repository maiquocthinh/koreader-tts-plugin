//! Unit tests for `audio_sink.rs` verifying gapless rendering and event emissions.

use std::sync::Arc;
use tts_core::audio_decoder::AudioBuffer;
use tts_core::audio_sink::*;
use tts_core::c_api::TtsEventType;
use tts_core::event_ring_buffer::create_event_channel;

fn make_constant_buffer(value: i16, count: usize) -> Arc<AudioBuffer> {
    Arc::new(AudioBuffer::new(vec![value; count], 24000, 1).unwrap())
}

#[test]
fn test_audio_sink_state_transitions() {
    let (prod, mut _cons) = create_event_channel(Some(32));
    let sink = AudioSink::new(prod);

    assert_eq!(sink.state(), SINK_STATE_IDLE);

    sink.play();
    assert_eq!(sink.state(), SINK_STATE_PLAYING);

    sink.pause();
    assert_eq!(sink.state(), SINK_STATE_PAUSED);

    sink.resume();
    assert_eq!(sink.state(), SINK_STATE_PLAYING);

    sink.stop();
    assert_eq!(sink.state(), SINK_STATE_IDLE);
}

#[test]
fn test_audio_sink_silence_when_not_playing() {
    let (prod, mut _cons) = create_event_channel(Some(32));
    let sink = AudioSink::new(prod);

    let mut output = vec![999i16; 100];
    let written = sink.render_block(&mut output);

    assert_eq!(written, 0);
    assert!(
        output.iter().all(|&s| s == 0),
        "Output must be silence when idle"
    );
}

#[test]
fn test_true_gapless_sample_chaining_and_events() {
    let (prod, mut cons) = create_event_channel(Some(32));
    let sink = AudioSink::new(prod);

    // Chunk 0: 400 samples of value 100
    let buf0 = make_constant_buffer(100, 400);
    let cursor0 = AudioPlayCursor::new(1, 0, 2, buf0);

    // Chunk 1: 400 samples of value 200
    let buf1 = make_constant_buffer(200, 400);
    let cursor1 = AudioPlayCursor::new(1, 1, 2, buf1);

    sink.set_current(cursor0);
    sink.enqueue_next(cursor1);
    sink.play();

    // Verify CHUNK_STARTED event for chunk 0 was emitted on set_current
    let evt0_start = cons.pop().expect("Expected CHUNK_STARTED for chunk 0");
    assert_eq!(evt0_start.event_type, TtsEventType::ChunkStarted as i32);
    assert_eq!(evt0_start.chunk_index, 0);

    // Render block of 600 samples:
    // Should contain 400 samples of chunk 0, immediately followed by 200 samples of chunk 1!
    let mut block1 = vec![0i16; 600];
    let written1 = sink.render_block(&mut block1);
    assert_eq!(written1, 600);

    // First 400 samples must be 100
    assert!(
        block1[0..400].iter().all(|&s| s == 100),
        "Chunk 0 samples must match"
    );
    // Next 200 samples must be 200 (seamless 0ms gapless chaining!)
    assert!(
        block1[400..600].iter().all(|&s| s == 200),
        "Chunk 1 samples must immediately follow without gap"
    );

    // Events emitted during chaining:
    // 1. CHUNK_FINISHED for chunk 0
    let evt0_fin = cons.pop().expect("Expected CHUNK_FINISHED for chunk 0");
    assert_eq!(evt0_fin.event_type, TtsEventType::ChunkFinished as i32);
    assert_eq!(evt0_fin.chunk_index, 0);

    // 2. CHUNK_STARTED for chunk 1
    let evt1_start = cons.pop().expect("Expected CHUNK_STARTED for chunk 1");
    assert_eq!(evt1_start.event_type, TtsEventType::ChunkStarted as i32);
    assert_eq!(evt1_start.chunk_index, 1);

    // Render next block of 300 samples:
    // Remaining 200 samples of chunk 1, followed by 100 samples of silence (0s)
    let mut block2 = vec![99i16; 300];
    let written2 = sink.render_block(&mut block2);
    assert_eq!(written2, 200);

    assert!(
        block2[0..200].iter().all(|&s| s == 200),
        "Remaining chunk 1 samples must be 200"
    );
    assert!(
        block2[200..300].iter().all(|&s| s == 0),
        "Padded silence must be 0"
    );

    // Events emitted after chunk 1 completed:
    // 3. CHUNK_FINISHED for chunk 1
    let evt1_fin = cons.pop().expect("Expected CHUNK_FINISHED for chunk 1");
    assert_eq!(evt1_fin.event_type, TtsEventType::ChunkFinished as i32);
    assert_eq!(evt1_fin.chunk_index, 1);

    // 4. PAGE_COMPLETED (since chunk 1 was the final chunk 1/2)
    let evt_page = cons.pop().expect("Expected PAGE_COMPLETED event");
    assert_eq!(evt_page.event_type, TtsEventType::PageCompleted as i32);

    assert!(cons.is_empty());
}
