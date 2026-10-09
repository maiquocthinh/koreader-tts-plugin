//! Unit and safety tests for C-ABI facade, struct layout, and panic barrier.

use std::ffi::CString;
use std::mem::{align_of, size_of};
use std::ptr;
use tts_core::c_api::*;

#[test]
fn test_c_abi_struct_layout_and_alignment() {
    // TtsCoreEvent must be strictly 288 bytes and 8-byte aligned
    assert_eq!(
        align_of::<TtsCoreEvent>(),
        8,
        "TtsCoreEvent must be 8-byte aligned"
    );
    assert_eq!(
        size_of::<TtsCoreEvent>(),
        288,
        "TtsCoreEvent must be exactly 288 bytes"
    );

    // Verify exact byte offsets
    let event = TtsCoreEvent::default();
    let base = &event as *const _ as usize;
    assert_eq!(&event.duration_seconds as *const _ as usize - base, 0);
    assert_eq!(&event.event_type as *const _ as usize - base, 8);
    assert_eq!(&event.generation as *const _ as usize - base, 12);
    assert_eq!(&event.chunk_index as *const _ as usize - base, 16);
    assert_eq!(&event.total_chunks as *const _ as usize - base, 20);
    assert_eq!(&event.latency_ms as *const _ as usize - base, 24);
    assert_eq!(&event._reserved as *const _ as usize - base, 28);
    assert_eq!(&event.error_message as *const _ as usize - base, 32);

    // TtsCoreSlotStatus must be strictly 24 bytes and 8-byte aligned
    assert_eq!(
        align_of::<TtsCoreSlotStatus>(),
        8,
        "TtsCoreSlotStatus must be 8-byte aligned"
    );
    assert_eq!(
        size_of::<TtsCoreSlotStatus>(),
        24,
        "TtsCoreSlotStatus must be exactly 24 bytes"
    );

    let slot = TtsCoreSlotStatus::default();
    let slot_base = &slot as *const _ as usize;
    assert_eq!(&slot.duration_seconds as *const _ as usize - slot_base, 0);
    assert_eq!(&slot.chunk_index as *const _ as usize - slot_base, 8);
    assert_eq!(&slot.is_cached as *const _ as usize - slot_base, 12);
    assert_eq!(&slot.is_fetching as *const _ as usize - slot_base, 16);
    assert_eq!(&slot.is_playing as *const _ as usize - slot_base, 20);
}

#[test]
fn test_event_error_message_buffer_safety() {
    let mut event = TtsCoreEvent::default();
    assert_eq!(event.error_message[0], 0);

    // Normal message
    event.set_error_message("HTTP 404: Not Found");
    let c_str = unsafe { std::ffi::CStr::from_ptr(event.error_message.as_ptr() as *const i8) };
    assert_eq!(c_str.to_str().unwrap(), "HTTP 404: Not Found");

    // Very long message: must truncate safely at 255 bytes without buffer overflow
    let long_msg = "A".repeat(500);
    event.set_error_message(&long_msg);
    assert_eq!(
        event.error_message[255], 0,
        "Null terminator must be at index 255"
    );
    let c_str_long = unsafe { std::ffi::CStr::from_ptr(event.error_message.as_ptr() as *const i8) };
    assert_eq!(c_str_long.to_str().unwrap().len(), 255);
}

#[test]
fn test_context_lifecycle_and_null_safety() {
    unsafe {
        let mut err = 0;

        // Creating context with NULL config should fail gracefully
        let null_ctx = tts_core_context_create(ptr::null(), &mut err);
        assert!(null_ctx.is_null());
        assert_eq!(err, TTS_ERR_INVALID_ARG);

        // Creating context with valid JSON config
        let config = CString::new(
            r#"{"server_url":"https://api.example.com","voice":"duc_tri","audio_format":"wav"}"#,
        )
        .unwrap();
        let ctx = tts_core_context_create(config.as_ptr(), &mut err);
        assert!(!ctx.is_null());
        assert_eq!(err, TTS_OK);

        // Update config
        let updated_config = CString::new(
            r#"{"server_url":"https://api.example.com","voice":"duc_tri","audio_format":"flac"}"#,
        )
        .unwrap();
        let res_update = tts_core_context_update_config(ctx, updated_config.as_ptr());
        assert_eq!(res_update, TTS_OK);

        // Calling update config with NULL context or NULL config
        assert_eq!(
            tts_core_context_update_config(ptr::null_mut(), updated_config.as_ptr()),
            TTS_ERR_INVALID_ARG
        );
        assert_eq!(
            tts_core_context_update_config(ctx, ptr::null()),
            TTS_ERR_INVALID_ARG
        );

        // Playback controls
        assert_eq!(tts_core_playback_play(ctx), TTS_OK);
        assert_eq!(tts_core_playback_pause(ctx), TTS_OK);
        assert_eq!(tts_core_playback_resume(ctx), TTS_OK);
        assert_eq!(tts_core_playback_seek(ctx, 1, 3), TTS_OK);
        assert_eq!(tts_core_playback_stop(ctx), TTS_OK);

        // Null pointer safety on playback controls
        assert_eq!(tts_core_playback_play(ptr::null_mut()), TTS_ERR_INVALID_ARG);
        assert_eq!(
            tts_core_playback_pause(ptr::null_mut()),
            TTS_ERR_INVALID_ARG
        );
        assert_eq!(
            tts_core_playback_resume(ptr::null_mut()),
            TTS_ERR_INVALID_ARG
        );
        assert_eq!(
            tts_core_playback_seek(ptr::null_mut(), 1, 0),
            TTS_ERR_INVALID_ARG
        );
        assert_eq!(tts_core_playback_stop(ptr::null_mut()), TTS_ERR_INVALID_ARG);

        // Page load
        let text1 = CString::new("Câu thứ nhất.").unwrap();
        let text2 = CString::new("Câu thứ hai.").unwrap();
        let texts = [text1.as_ptr(), text2.as_ptr()];
        assert_eq!(tts_core_queue_load_page(ctx, 1, texts.as_ptr(), 2), TTS_OK);
        assert_eq!(
            tts_core_queue_enqueue_next_page(ctx, 1, texts.as_ptr(), 2),
            TTS_OK
        );

        // Null pointer safety on queue functions
        assert_eq!(
            tts_core_queue_load_page(ptr::null_mut(), 1, texts.as_ptr(), 2),
            TTS_ERR_INVALID_ARG
        );
        assert_eq!(
            tts_core_queue_load_page(ctx, 1, ptr::null(), 2),
            TTS_ERR_INVALID_ARG
        );
        assert_eq!(
            tts_core_queue_load_page(ctx, 1, texts.as_ptr(), 0),
            TTS_ERR_INVALID_ARG
        );

        // Slot status
        let mut status = TtsCoreSlotStatus::default();
        assert_eq!(tts_core_slot_get_status(ctx, 0, &mut status), TTS_OK);
        assert_eq!(
            tts_core_slot_get_status(ptr::null_mut(), 0, &mut status),
            TTS_ERR_INVALID_ARG
        );
        assert_eq!(
            tts_core_slot_get_status(ctx, 0, ptr::null_mut()),
            TTS_ERR_INVALID_ARG
        );

        // Event poll (stub returns 0 for empty)
        let mut event = TtsCoreEvent::default();
        assert_eq!(tts_core_event_poll(ctx, &mut event), 0);
        assert_eq!(
            tts_core_event_poll(ptr::null_mut(), &mut event),
            TTS_ERR_INVALID_ARG
        );
        assert_eq!(
            tts_core_event_poll(ctx, ptr::null_mut()),
            TTS_ERR_INVALID_ARG
        );

        // Destroy context cleanly
        tts_core_context_destroy(ctx);

        // Destroying NULL pointer must not crash
        tts_core_context_destroy(ptr::null_mut());
    }
}

#[test]
fn test_panic_safety_barrier() {
    unsafe {
        let config = CString::new(r#"{"server_url":"https://api.example.com"}"#).unwrap();
        let mut err = 0;
        let ctx = tts_core_context_create(config.as_ptr(), &mut err);
        assert!(!ctx.is_null());

        // Call the test function that deliberately triggers a panic inside Rust
        let result = tts_core_test_deliberate_panic(ctx);

        // The panic must be caught by catch_unwind_ffi! and converted to TTS_ERR_PANIC
        assert_eq!(
            result, TTS_ERR_PANIC,
            "FFI boundary must catch panic and return TTS_ERR_PANIC without aborting"
        );

        tts_core_context_destroy(ctx);
    }
}
