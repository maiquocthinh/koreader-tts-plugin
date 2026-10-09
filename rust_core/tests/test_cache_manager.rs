//! Unit tests for `cache_manager.rs` verifying two-tier caching and LRU quota pruning.

use std::sync::Arc;
use tts_core::audio_decoder::AudioBuffer;
use tts_core::cache_manager::*;

fn make_dummy_buffer(samples_count: usize) -> Arc<AudioBuffer> {
    Arc::new(AudioBuffer::new(vec![0i16; samples_count], 24000, 1).unwrap())
}

#[test]
fn test_deterministic_cache_key_generation() {
    let key1 = CacheManager::compute_cache_key(
        "Xin chào thế giới.",
        "duc_tri",
        "wav",
        1.0,
        "https://api.tts.com",
    );
    let key2 = CacheManager::compute_cache_key(
        "Xin chào thế giới.",
        "duc_tri",
        "wav",
        1.0,
        "https://api.tts.com",
    );
    assert_eq!(
        key1, key2,
        "Identical inputs must produce identical cache keys"
    );

    // Changing voice alters key
    let key_diff_voice = CacheManager::compute_cache_key(
        "Xin chào thế giới.",
        "nam_minh",
        "wav",
        1.0,
        "https://api.tts.com",
    );
    assert_ne!(key1, key_diff_voice);

    // Changing speed alters key
    let key_diff_speed = CacheManager::compute_cache_key(
        "Xin chào thế giới.",
        "duc_tri",
        "wav",
        1.25,
        "https://api.tts.com",
    );
    assert_ne!(key1, key_diff_speed);

    // Floating-point precision quantization (1.000 vs 1.00)
    let key_speed_float = CacheManager::compute_cache_key(
        "Xin chào thế giới.",
        "duc_tri",
        "wav",
        1.000001,
        "https://api.tts.com",
    );
    assert_eq!(
        key1, key_speed_float,
        "Quantized speeds should produce identical keys"
    );
}

#[test]
fn test_l1_in_memory_lru_cache() {
    let temp_dir = std::env::temp_dir().join("koreader_tts_test_mem_cache");
    let manager = CacheManager::new(&temp_dir, 1024 * 1024, 2).unwrap(); // Capacity = 2 items

    let buf1 = make_dummy_buffer(100);
    let buf2 = make_dummy_buffer(200);
    let buf3 = make_dummy_buffer(300);

    manager.put_memory("key1".to_string(), buf1.clone());
    manager.put_memory("key2".to_string(), buf2.clone());

    assert_eq!(manager.get_memory("key1"), Some(buf1.clone()));
    assert_eq!(manager.get_memory("key2"), Some(buf2.clone()));

    // Accessing key1 makes key2 the oldest. Now insert key3: key2 should be evicted!
    let _ = manager.get_memory("key1");
    manager.put_memory("key3".to_string(), buf3.clone());

    assert_eq!(manager.get_memory("key1"), Some(buf1));
    assert_eq!(manager.get_memory("key3"), Some(buf3));
    assert_eq!(
        manager.get_memory("key2"),
        None,
        "key2 should be evicted by LRU"
    );

    let _ = std::fs::remove_dir_all(&temp_dir);
}

#[test]
fn test_l2_atomic_disk_cache_read_write() {
    let temp_dir = std::env::temp_dir().join("koreader_tts_test_disk_cache");
    let manager = CacheManager::new(&temp_dir, 10 * 1024 * 1024, 5).unwrap();

    let dummy_audio_bytes = vec![0x52, 0x49, 0x46, 0x46, 0x01, 0x02, 0x03, 0x04];
    let key = "test_chunk_key_123";

    assert!(!manager.has_valid_disk_cache(key, "wav"));

    // Write atomically
    let path = manager
        .put_disk_bytes(key, "wav", &dummy_audio_bytes)
        .unwrap();
    assert!(path.exists());
    assert!(manager.has_valid_disk_cache(key, "wav"));

    // Read back
    let read_back = manager
        .get_disk_bytes(key, "wav")
        .unwrap()
        .expect("Cache file should exist");
    assert_eq!(read_back.as_ref(), dummy_audio_bytes.as_slice());

    let _ = std::fs::remove_dir_all(&temp_dir);
}

#[test]
fn test_disk_cache_lru_quota_prune() {
    let temp_dir = std::env::temp_dir().join("koreader_tts_test_disk_prune");
    // Limit to 5000 bytes
    let manager = CacheManager::new(&temp_dir, 5000, 5).unwrap();

    // Create 10 files of 1000 bytes each (Total 10,000 bytes > 5000 limit)
    let payload = vec![0xAA; 1000];
    for i in 0..10 {
        let key = format!("prune_test_{}", i);
        manager.put_disk_bytes(&key, "wav", &payload).unwrap();
        // Brief sleep so modified timestamps differ slightly
        std::thread::sleep(std::time::Duration::from_millis(10));
    }

    // Prune must reduce total size below 80% of 5000 (i.e. <= 4000 bytes)
    let pruned_count = manager.prune_disk_cache().unwrap();
    assert!(
        pruned_count >= 6,
        "Expected at least 6 files pruned, got {}",
        pruned_count
    );

    let _ = std::fs::remove_dir_all(&temp_dir);
}
