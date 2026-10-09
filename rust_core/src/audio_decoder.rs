//! In-memory multi-format audio decoder.
//!
//! Decodes audio streams (WAV, FLAC, MP3, OPUS/Ogg) from RAM directly into
//! raw 16-bit signed PCM sample buffers with exact microsecond duration.

use bytes::Bytes;
use std::io::Cursor;
use symphonia::core::audio::SampleBuffer;
use symphonia::core::codecs::DecoderOptions;
use symphonia::core::errors::Error as SymphoniaError;
use symphonia::core::formats::FormatOptions;
use symphonia::core::io::MediaSourceStream;
use symphonia::core::meta::MetadataOptions;
use symphonia::core::probe::Hint;
use thiserror::Error;

// ============================================================================
// Errors
// ============================================================================

#[derive(Error, Debug)]
pub enum DecodeError {
    #[error("Failed to probe audio format: {0}")]
    ProbeFailed(String),

    #[error("No supported audio track found in stream")]
    NoTrackFound,

    #[error("Unsupported audio codec: {0}")]
    UnsupportedCodec(String),

    #[error("Failed to decode audio packet: {0}")]
    DecodeFailed(String),

    #[error("Audio stream contains no playable sample data")]
    EmptyAudio,
}

impl DecodeError {
    /// Maps decode errors to standard C-ABI error codes.
    pub fn to_c_error_code(&self) -> i32 {
        crate::c_api::TTS_ERR_DECODE
    }
}

// ============================================================================
// Data Structures
// ============================================================================

/// In-memory decoded PCM audio buffer ready for hardware output.
#[derive(Debug, Clone, PartialEq)]
pub struct AudioBuffer {
    /// Interleaved 16-bit signed PCM samples.
    pub samples: Vec<i16>,
    /// Sample rate in Hz (e.g., 24000, 48000).
    pub sample_rate: u32,
    /// Number of channels (1 for Mono, 2 for Stereo).
    pub channels: u16,
    /// Exact audio duration in seconds.
    pub duration_seconds: f64,
}

impl AudioBuffer {
    /// Creates a new `AudioBuffer` and calculates exact duration.
    pub fn new(samples: Vec<i16>, sample_rate: u32, channels: u16) -> Result<Self, DecodeError> {
        if samples.is_empty() || sample_rate == 0 || channels == 0 {
            return Err(DecodeError::EmptyAudio);
        }

        let total_frames = samples.len() / (channels as usize);
        let duration_seconds = total_frames as f64 / sample_rate as f64;

        Ok(Self {
            samples,
            sample_rate,
            channels,
            duration_seconds,
        })
    }

    /// Number of audio frames (samples / channels).
    pub fn total_frames(&self) -> usize {
        if self.channels == 0 {
            0
        } else {
            self.samples.len() / (self.channels as usize)
        }
    }
}

// ============================================================================
// Audio Decoder Implementation
// ============================================================================

pub struct AudioDecoder;

impl AudioDecoder {
    /// Decodes raw audio bytes from RAM into an `AudioBuffer`.
    ///
    /// # Arguments
    /// - `data`: In-memory audio byte stream (WAV, FLAC, MP3, OPUS/Ogg).
    /// - `format_hint`: Optional extension or mime hint (e.g., "wav", "flac", "mp3", "opus").
    pub fn decode_from_memory(
        data: Bytes,
        format_hint: Option<&str>,
    ) -> Result<AudioBuffer, DecodeError> {
        if data.is_empty() {
            return Err(DecodeError::EmptyAudio);
        }

        let mut hint = Hint::new();
        if let Some(ext) = format_hint {
            let clean_ext = ext.trim().trim_start_matches('.');
            hint.with_extension(clean_ext);
        }

        let cursor = Cursor::new(data);
        let mss = MediaSourceStream::new(Box::new(cursor), Default::default());

        let format_opts = FormatOptions {
            enable_gapless: true,
            ..Default::default()
        };
        let metadata_opts = MetadataOptions::default();
        let decoder_opts = DecoderOptions::default();

        // Use symphonia default probe
        let probed = symphonia::default::get_probe()
            .format(&hint, mss, &format_opts, &metadata_opts)
            .map_err(|e| DecodeError::ProbeFailed(e.to_string()))?;

        let mut format_reader = probed.format;

        // Select the default audio track
        let track = format_reader
            .default_track()
            .ok_or(DecodeError::NoTrackFound)?;

        let track_id = track.id;
        let codec_params = track.codec_params.clone();

        let sample_rate = codec_params
            .sample_rate
            .ok_or_else(|| DecodeError::ProbeFailed("Unknown sample rate".to_string()))?;

        let channels = codec_params.channels.map(|c| c.count() as u16).unwrap_or(1);

        // Instantiate codec decoder
        let mut decoder = symphonia::default::get_codecs()
            .make(&codec_params, &decoder_opts)
            .map_err(|e| DecodeError::UnsupportedCodec(e.to_string()))?;

        let mut all_samples: Vec<i16> = Vec::new();
        let mut sample_buf: Option<SampleBuffer<i16>> = None;

        // Packet decode loop
        loop {
            let packet = match format_reader.next_packet() {
                Ok(packet) => packet,
                Err(SymphoniaError::IoError(e))
                    if e.kind() == std::io::ErrorKind::UnexpectedEof =>
                {
                    break;
                }
                Err(SymphoniaError::ResetRequired) => {
                    decoder.reset();
                    continue;
                }
                Err(e) => {
                    log::debug!("End of stream or packet read error: {:?}", e);
                    break;
                }
            };

            if packet.track_id() != track_id {
                continue;
            }

            match decoder.decode(&packet) {
                Ok(audio_buf_ref) => {
                    // Initialize or resize sample buffer for interleaved i16 extraction
                    if sample_buf.is_none() {
                        let spec = *audio_buf_ref.spec();
                        let duration = audio_buf_ref.capacity() as u64;
                        sample_buf = Some(SampleBuffer::<i16>::new(duration, spec));
                    }

                    if let Some(buf) = sample_buf.as_mut() {
                        buf.copy_interleaved_ref(audio_buf_ref);
                        all_samples.extend_from_slice(buf.samples());
                    }
                }
                Err(SymphoniaError::DecodeError(e)) => {
                    log::warn!("Recoverable packet decode error: {:?}", e);
                    continue;
                }
                Err(SymphoniaError::ResetRequired) => {
                    decoder.reset();
                    continue;
                }
                Err(e) => {
                    return Err(DecodeError::DecodeFailed(e.to_string()));
                }
            }
        }

        if all_samples.is_empty() {
            return Err(DecodeError::EmptyAudio);
        }

        AudioBuffer::new(all_samples, sample_rate, channels)
    }
}
