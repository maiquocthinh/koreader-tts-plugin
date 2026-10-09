//! Unit tests for `audio_decoder.rs` verifying in-memory multi-format decoding.

use bytes::Bytes;
use tts_core::audio_decoder::*;
use tts_core::c_api::TTS_ERR_DECODE;

/// Helper function to generate a valid in-memory 16-bit PCM WAV file.
fn generate_synthetic_wav(sample_rate: u32, channels: u16, num_samples: usize) -> Vec<u8> {
    let mut wav = Vec::new();

    let byte_rate = sample_rate * (channels as u32) * 2;
    let block_align = channels * 2;
    let data_size = (num_samples * (channels as usize) * 2) as u32;
    let file_size = 36 + data_size;

    // RIFF header
    wav.extend_from_slice(b"RIFF");
    wav.extend_from_slice(&file_size.to_le_bytes());
    wav.extend_from_slice(b"WAVE");

    // fmt subchunk
    wav.extend_from_slice(b"fmt ");
    wav.extend_from_slice(&16u32.to_le_bytes()); // subchunk size
    wav.extend_from_slice(&1u16.to_le_bytes()); // PCM format
    wav.extend_from_slice(&channels.to_le_bytes());
    wav.extend_from_slice(&sample_rate.to_le_bytes());
    wav.extend_from_slice(&byte_rate.to_le_bytes());
    wav.extend_from_slice(&block_align.to_le_bytes());
    wav.extend_from_slice(&16u16.to_le_bytes()); // 16 bits per sample

    // data subchunk
    wav.extend_from_slice(b"data");
    wav.extend_from_slice(&data_size.to_le_bytes());

    // Generate sine wave samples (440 Hz tone)
    let freq = 440.0;
    for i in 0..num_samples {
        let t = i as f64 / sample_rate as f64;
        let val = (t * freq * 2.0 * std::f64::consts::PI).sin();
        let sample = (val * 16000.0) as i16;

        for _ in 0..channels {
            wav.extend_from_slice(&sample.to_le_bytes());
        }
    }

    wav
}

#[test]
fn test_audio_buffer_duration_calculation() {
    let samples = vec![0i16; 48000]; // 48000 samples at 24000Hz mono = exactly 2.0 seconds
    let buf = AudioBuffer::new(samples, 24000, 1).unwrap();

    assert_eq!(buf.total_frames(), 48000);
    assert_eq!(buf.channels, 1);
    assert_eq!(buf.sample_rate, 24000);
    assert!((buf.duration_seconds - 2.0).abs() < 1e-6);

    // Stereo buffer: 48000 interleaved samples at 24000Hz stereo = 24000 frames = 1.0 second
    let stereo_samples = vec![0i16; 48000];
    let stereo_buf = AudioBuffer::new(stereo_samples, 24000, 2).unwrap();
    assert_eq!(stereo_buf.total_frames(), 24000);
    assert_eq!(stereo_buf.channels, 2);
    assert!((stereo_buf.duration_seconds - 1.0).abs() < 1e-6);

    // Reject empty samples
    assert!(AudioBuffer::new(vec![], 24000, 1).is_err());
    assert!(AudioBuffer::new(vec![1, 2], 0, 1).is_err());
    assert!(AudioBuffer::new(vec![1, 2], 24000, 0).is_err());
}

#[test]
fn test_decode_synthetic_wav_mono() {
    let sample_rate = 24000;
    let channels = 1;
    let num_samples = 12000; // 0.5 seconds
    let wav_data = generate_synthetic_wav(sample_rate, channels, num_samples);

    let bytes = Bytes::from(wav_data);
    let decoded = AudioDecoder::decode_from_memory(bytes, Some("wav")).expect("WAV decode failed");

    assert_eq!(decoded.sample_rate, 24000);
    assert_eq!(decoded.channels, 1);
    assert_eq!(decoded.samples.len(), 12000);
    assert!((decoded.duration_seconds - 0.5).abs() < 0.01);
}

#[test]
fn test_decode_synthetic_wav_stereo() {
    let sample_rate = 48000;
    let channels = 2;
    let num_samples = 24000; // 0.5 seconds of stereo
    let wav_data = generate_synthetic_wav(sample_rate, channels, num_samples);

    let bytes = Bytes::from(wav_data);
    let decoded =
        AudioDecoder::decode_from_memory(bytes, Some("wav")).expect("Stereo WAV decode failed");

    assert_eq!(decoded.sample_rate, 48000);
    assert_eq!(decoded.channels, 2);
    assert_eq!(decoded.samples.len(), 48000); // 24000 frames * 2 channels = 48000 samples
    assert!((decoded.duration_seconds - 0.5).abs() < 0.01);
}

#[test]
fn test_decode_corrupt_data_fails_gracefully() {
    // Random garbage data should return an error and not panic
    let garbage = Bytes::from(vec![0xDE, 0xAD, 0xBE, 0xEF, 0x12, 0x34, 0x56, 0x78]);
    let result = AudioDecoder::decode_from_memory(garbage, Some("wav"));

    assert!(
        result.is_err(),
        "Decoding corrupt bytes must fail gracefully"
    );
    let err = result.unwrap_err();
    assert_eq!(err.to_c_error_code(), TTS_ERR_DECODE);
}

#[test]
fn test_decode_empty_bytes() {
    let empty = Bytes::new();
    let result = AudioDecoder::decode_from_memory(empty, None);

    assert!(matches!(result, Err(DecodeError::EmptyAudio)));
}
