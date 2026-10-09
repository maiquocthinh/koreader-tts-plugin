//! Unit tests for `http_client.rs` using wiremock local HTTP mock server.

use std::time::Duration;
use tokio_util::sync::CancellationToken;
use tts_core::http_client::*;
use wiremock::matchers::{header, method, path};
use wiremock::{Mock, MockServer, ResponseTemplate};

#[tokio::test]
async fn test_successful_speech_fetch_with_auth() {
    let mock_server = MockServer::start().await;

    let fake_audio_bytes = vec![0x52, 0x49, 0x46, 0x46, 0x00, 0x01, 0x02, 0x03]; // Fake RIFF

    Mock::given(method("POST"))
        .and(path("/v1/audio/speech"))
        .and(header("content-type", "application/json"))
        .and(header("authorization", "Bearer secret_api_token"))
        .and(header("user-agent", "KOReader-TTS/0.1.0"))
        .respond_with(ResponseTemplate::new(200).set_body_bytes(fake_audio_bytes.clone()))
        .expect(1)
        .mount(&mock_server)
        .await;

    let config = HttpClientConfig {
        server_url: mock_server.uri(),
        api_key: Some("secret_api_token".to_string()),
        timeout_secs: 5,
        connect_timeout_secs: 2,
        pool_max_idle_per_host: 5,
        tcp_keepalive_secs: 60,
    };

    let client = HttpClient::new(config).expect("Failed to create HttpClient");

    let req = SpeechRequest::new("Xin chào các bạn.", "duc_tri", "wav", 1.0);
    let audio = client
        .fetch_speech(&req, None)
        .await
        .expect("Failed to fetch audio");

    assert_eq!(audio.as_ref(), fake_audio_bytes.as_slice());
}

#[tokio::test]
async fn test_connection_pooling_keep_alive() {
    let mock_server = MockServer::start().await;
    let fake_audio = vec![1, 2, 3, 4];

    // Expect 5 consecutive requests on the same mock server
    Mock::given(method("POST"))
        .and(path("/v1/audio/speech"))
        .respond_with(ResponseTemplate::new(200).set_body_bytes(fake_audio.clone()))
        .expect(5)
        .mount(&mock_server)
        .await;

    let config = HttpClientConfig {
        server_url: mock_server.uri(),
        api_key: None,
        timeout_secs: 5,
        connect_timeout_secs: 2,
        pool_max_idle_per_host: 5,
        tcp_keepalive_secs: 60,
    };

    let client = HttpClient::new(config).expect("Failed to create HttpClient");

    for i in 1..=5 {
        let req = SpeechRequest::new(format!("Câu số {}", i), "duc_tri", "flac", 1.0);
        let audio = client
            .fetch_speech(&req, None)
            .await
            .expect("Failed in pooled request");
        assert_eq!(audio.as_ref(), fake_audio.as_slice());
    }
}

#[tokio::test]
async fn test_cancellation_token_instant_abort() {
    let mock_server = MockServer::start().await;

    // Server delays response by 2000ms
    Mock::given(method("POST"))
        .and(path("/v1/audio/speech"))
        .respond_with(
            ResponseTemplate::new(200)
                .set_body_bytes(vec![1, 2, 3])
                .set_delay(Duration::from_millis(2000)),
        )
        .mount(&mock_server)
        .await;

    let config = HttpClientConfig {
        server_url: mock_server.uri(),
        api_key: None,
        timeout_secs: 10,
        connect_timeout_secs: 2,
        pool_max_idle_per_host: 5,
        tcp_keepalive_secs: 60,
    };

    let client = HttpClient::new(config).unwrap();
    let cancel_token = CancellationToken::new();

    // Trigger cancellation after 20ms
    let cancel_clone = cancel_token.clone();
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_millis(20)).await;
        cancel_clone.cancel();
    });

    let start = std::time::Instant::now();
    let req = SpeechRequest::new("Câu dài bị hủy bỏ.", "duc_tri", "wav", 1.0);
    let result = client.fetch_speech(&req, Some(&cancel_token)).await;

    let elapsed = start.elapsed();
    assert!(
        elapsed < Duration::from_millis(300),
        "Cancellation took too long: {:?}",
        elapsed
    );

    match result {
        Err(NetworkError::Cancelled) => {} // Expected
        other => panic!("Expected NetworkError::Cancelled, got {:?}", other),
    }
}

#[tokio::test]
async fn test_http_error_status_handling() {
    let mock_server = MockServer::start().await;

    Mock::given(method("POST"))
        .and(path("/v1/audio/speech"))
        .respond_with(ResponseTemplate::new(401).set_body_string("Invalid Bearer Token"))
        .mount(&mock_server)
        .await;

    let config = HttpClientConfig {
        server_url: mock_server.uri(),
        api_key: Some("wrong_token".to_string()),
        ..Default::default()
    };

    let client = HttpClient::new(config).unwrap();
    let req = SpeechRequest::new("Thử nghiệm lỗi 401.", "duc_tri", "wav", 1.0);
    let result = client.fetch_speech(&req, None).await;

    match result {
        Err(NetworkError::HttpStatus { status, body }) => {
            assert_eq!(status, 401);
            assert_eq!(body, "Invalid Bearer Token");
        }
        other => panic!("Expected NetworkError::HttpStatus 401, got {:?}", other),
    }
}

#[tokio::test]
async fn test_empty_response_handling() {
    let mock_server = MockServer::start().await;

    Mock::given(method("POST"))
        .and(path("/v1/audio/speech"))
        .respond_with(ResponseTemplate::new(200).set_body_bytes(vec![]))
        .mount(&mock_server)
        .await;

    let config = HttpClientConfig {
        server_url: mock_server.uri(),
        ..Default::default()
    };

    let client = HttpClient::new(config).unwrap();
    let req = SpeechRequest::new("Phản hồi rỗng.", "duc_tri", "wav", 1.0);
    let result = client.fetch_speech(&req, None).await;

    match result {
        Err(NetworkError::EmptyResponse) => {}
        other => panic!("Expected NetworkError::EmptyResponse, got {:?}", other),
    }
}

#[test]
fn test_url_normalization() {
    let config = HttpClientConfig {
        server_url: "http://192.168.1.100:8000".to_string(),
        ..Default::default()
    };
    let client = HttpClient::new(config).unwrap();
    // Default root path should be normalized to /v1/audio/speech
    assert_eq!(client.endpoint_url().path(), "/v1/audio/speech");

    let bad_config = HttpClientConfig {
        server_url: "not a valid url".to_string(),
        ..Default::default()
    };
    assert!(HttpClient::new(bad_config).is_err());
}
