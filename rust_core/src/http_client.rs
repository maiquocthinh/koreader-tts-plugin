//! Asynchronous HTTP client for neural TTS synthesis.
//!
//! Features:
//! - Pure Rust TLS 1.3 via `rustls` (zero dynamic OpenSSL dependency).
//! - HTTP/1.1 and HTTP/2 connection pooling with persistent keep-alive.
//! - Cooperative cancellation via `tokio_util::sync::CancellationToken`.
//! - OpenAI-compatible `/v1/audio/speech` request serialization.

use bytes::Bytes;
use reqwest::{header, Client, Url};
use serde::{Deserialize, Serialize};
use std::time::Duration;
use thiserror::Error;
use tokio_util::sync::CancellationToken;

// ============================================================================
// Errors
// ============================================================================

#[derive(Error, Debug)]
pub enum NetworkError {
    #[error("Invalid server URL: {0}")]
    InvalidUrl(String),

    #[error("Failed to build HTTP request: {0}")]
    RequestBuild(String),

    #[error("Connection failed: {0}")]
    ConnectionFailed(String),

    #[error("Request timed out")]
    Timeout,

    #[error("Request cancelled")]
    Cancelled,

    #[error("HTTP error {status}: {body}")]
    HttpStatus { status: u16, body: String },

    #[error("Server returned empty audio payload")]
    EmptyResponse,
}

impl NetworkError {
    /// Maps the error to a standard C-ABI error code.
    pub fn to_c_error_code(&self) -> i32 {
        match self {
            NetworkError::InvalidUrl(_) => crate::c_api::TTS_ERR_INVALID_ARG,
            NetworkError::Cancelled => crate::c_api::TTS_OK, // Cancellation is normal control flow
            _ => crate::c_api::TTS_ERR_NETWORK,
        }
    }
}

// ============================================================================
// Data Structures
// ============================================================================

/// Configuration for the HTTP client instance.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HttpClientConfig {
    pub server_url: String,
    pub api_key: Option<String>,
    #[serde(default = "default_timeout_secs")]
    pub timeout_secs: u64,
    #[serde(default = "default_connect_timeout_secs")]
    pub connect_timeout_secs: u64,
    #[serde(default = "default_pool_max_idle_per_host")]
    pub pool_max_idle_per_host: usize,
    #[serde(default = "default_tcp_keepalive_secs")]
    pub tcp_keepalive_secs: u64,
}

fn default_timeout_secs() -> u64 {
    15
}
fn default_connect_timeout_secs() -> u64 {
    5
}
fn default_pool_max_idle_per_host() -> usize {
    5
}
fn default_tcp_keepalive_secs() -> u64 {
    60
}

    impl Default for HttpClientConfig {
    fn default() -> Self {
        Self {
            server_url: "https://api.openai.com/v1/audio/speech".to_string(),
            api_key: None,
            timeout_secs: default_timeout_secs(),
            connect_timeout_secs: default_connect_timeout_secs(),
            pool_max_idle_per_host: default_pool_max_idle_per_host(),
            tcp_keepalive_secs: default_tcp_keepalive_secs(),
        }
    }
}

/// OpenAI-compatible speech synthesis payload.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SpeechRequest {
    pub model: String,
    pub input: String,
    pub voice: String,
    pub response_format: String,
    pub speed: f64,
}

impl SpeechRequest {
    pub fn new(
        input: impl Into<String>,
        voice: impl Into<String>,
        format: impl Into<String>,
        speed: f64,
    ) -> Self {
        Self {
            model: "tts-1".to_string(),
            input: input.into(),
            voice: voice.into(),
            response_format: format.into(),
            speed,
        }
    }
}

// ============================================================================
// HTTP Client Implementation
// ============================================================================

pub struct HttpClient {
    client: Client,
    endpoint_url: Url,
    api_key: Option<String>,
}

impl HttpClient {
    /// Creates a new `HttpClient` instance with connection pooling and timeouts.
    pub fn new(config: HttpClientConfig) -> Result<Self, NetworkError> {
        let endpoint_url = Self::resolve_endpoint_url(&config.server_url)?;

        let mut default_headers = header::HeaderMap::new();
        default_headers.insert(
            header::USER_AGENT,
            header::HeaderValue::from_static("KOReader-TTS/0.1.0"),
        );

        let client = Client::builder()
            .use_rustls_tls()
            .default_headers(default_headers)
            .pool_max_idle_per_host(config.pool_max_idle_per_host)
            .tcp_keepalive(Some(Duration::from_secs(config.tcp_keepalive_secs)))
            .connect_timeout(Duration::from_secs(config.connect_timeout_secs))
            .timeout(Duration::from_secs(config.timeout_secs))
            .build()
            .map_err(|e| NetworkError::RequestBuild(e.to_string()))?;

        Ok(Self {
            client,
            endpoint_url,
            api_key: config.api_key.filter(|k| !k.trim().is_empty()),
        })
    }

    /// Returns a reference to the resolved target endpoint URL.
    pub fn endpoint_url(&self) -> &Url {
        &self.endpoint_url
    }

    /// Normalizes endpoint URL, appending `/v1/audio/speech` if path is root.
    fn resolve_endpoint_url(raw_url: &str) -> Result<Url, NetworkError> {
        let trimmed = raw_url.trim();
        let mut url = Url::parse(trimmed).map_err(|e| NetworkError::InvalidUrl(e.to_string()))?;

        if url.path() == "/" || url.path().is_empty() {
            url.set_path("/v1/audio/speech");
        }

        Ok(url)
    }

    /// Fetches speech audio bytes asynchronously with cancellation support.
    pub async fn fetch_speech(
        &self,
        request: &SpeechRequest,
        cancel_token: Option<&CancellationToken>,
    ) -> Result<Bytes, NetworkError> {
        let mut req_builder = self
            .client
            .post(self.endpoint_url.clone())
            .header(header::CONTENT_TYPE, "application/json")
            .json(request);

        if let Some(ref key) = self.api_key {
            req_builder = req_builder.bearer_auth(key);
        }

        let send_future = async {
            let response = req_builder.send().await.map_err(|e| {
                if e.is_timeout() {
                    NetworkError::Timeout
                } else {
                    NetworkError::ConnectionFailed(e.to_string())
                }
            })?;

            let status = response.status();
            if !status.is_success() {
                let body = response.text().await.unwrap_or_default();
                return Err(NetworkError::HttpStatus {
                    status: status.as_u16(),
                    body,
                });
            }

            let bytes = response.bytes().await.map_err(|e| {
                if e.is_timeout() {
                    NetworkError::Timeout
                } else {
                    NetworkError::ConnectionFailed(e.to_string())
                }
            })?;

            if bytes.is_empty() {
                return Err(NetworkError::EmptyResponse);
            }

            Ok(bytes)
        };

        match cancel_token {
            Some(token) => {
                tokio::select! {
                    _ = token.cancelled() => {
                        log::debug!("Speech request was cancelled by generation token");
                        Err(NetworkError::Cancelled)
                    }
                    result = send_future => result,
                }
            }
            None => send_future.await,
        }
    }
}
