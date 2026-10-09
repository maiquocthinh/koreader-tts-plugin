//! Two-tier caching system for neural TTS audio chunks.
//!
//! Features:
//! - Deterministic SHA-256 cache key calculation.
//! - L1 In-Memory LRU Cache for instant 0ms access on rewind/seek.
//! - L2 Atomic Disk Cache (`.tmp` write followed by `fs::rename`).
//! - Background disk quota eviction (default 50MB limit).

use bytes::Bytes;
use sha2::{Digest, Sha256};
use std::collections::{HashMap, VecDeque};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use thiserror::Error;

use crate::audio_decoder::AudioBuffer;

// ============================================================================
// Errors
// ============================================================================

#[derive(Error, Debug)]
pub enum CacheError {
    #[error("I/O error during cache access: {0}")]
    Io(#[from] std::io::Error),

    #[error("Cache directory does not exist or is invalid: {0}")]
    InvalidDirectory(String),
}

// ============================================================================
// In-Memory Bounded LRU Cache
// ============================================================================

struct BoundedMemoryCache {
    capacity: usize,
    entries: HashMap<String, Arc<AudioBuffer>>,
    order: VecDeque<String>,
}

impl BoundedMemoryCache {
    fn new(capacity: usize) -> Self {
        Self {
            capacity: capacity.max(1),
            entries: HashMap::new(),
            order: VecDeque::new(),
        }
    }

    fn get(&mut self, key: &str) -> Option<Arc<AudioBuffer>> {
        if let Some(buf) = self.entries.get(key).cloned() {
            // Move key to back of order deque (most recently used)
            if let Some(pos) = self.order.iter().position(|k| k == key) {
                self.order.remove(pos);
            }
            self.order.push_back(key.to_string());
            Some(buf)
        } else {
            None
        }
    }

    fn put(&mut self, key: String, buffer: Arc<AudioBuffer>) {
        if self.entries.contains_key(&key) {
            self.entries.insert(key.clone(), buffer);
            if let Some(pos) = self.order.iter().position(|k| *k == key) {
                self.order.remove(pos);
            }
            self.order.push_back(key);
            return;
        }

        // Evict oldest if at capacity
        while self.entries.len() >= self.capacity {
            if let Some(oldest) = self.order.pop_front() {
                self.entries.remove(&oldest);
            } else {
                break;
            }
        }

        self.entries.insert(key.clone(), buffer);
        self.order.push_back(key);
    }

    fn clear(&mut self) {
        self.entries.clear();
        self.order.clear();
    }
}

// ============================================================================
// Cache Manager Implementation
// ============================================================================

pub struct CacheManager {
    cache_dir: PathBuf,
    max_disk_bytes: u64,
    memory_cache: Mutex<BoundedMemoryCache>,
}

impl CacheManager {
    /// Initializes a new CacheManager with custom cache directory and disk limit.
    pub fn new(
        cache_dir: impl AsRef<Path>,
        max_disk_bytes: u64,
        memory_capacity: usize,
    ) -> Result<Self, CacheError> {
        let dir = cache_dir.as_ref().to_path_buf();
        if !dir.exists() {
            fs::create_dir_all(&dir)?;
        }

        Ok(Self {
            cache_dir: dir,
            max_disk_bytes: if max_disk_bytes == 0 {
                50 * 1024 * 1024
            } else {
                max_disk_bytes
            },
            memory_cache: Mutex::new(BoundedMemoryCache::new(memory_capacity)),
        })
    }

    /// Computes a deterministic SHA-256 hash cache key.
    pub fn compute_cache_key(
        text: &str,
        voice: &str,
        format: &str,
        speed: f64,
        server_url: &str,
    ) -> String {
        let mut hasher = Sha256::new();
        hasher.update(text.as_bytes());
        hasher.update(b"|");
        hasher.update(voice.as_bytes());
        hasher.update(b"|");
        hasher.update(format.as_bytes());
        hasher.update(b"|");
        // Quantize speed to 2 decimal places to avoid float representation drift
        let speed_quantized = format!("{:.2}", speed);
        hasher.update(speed_quantized.as_bytes());
        hasher.update(b"|");
        hasher.update(server_url.as_bytes());

        let result = hasher.finalize();
        // Truncate to first 16 bytes (32 hex characters) for clean file naming
        format!("{:x}", result)[..32].to_string()
    }

    /// Path to the cached disk file for a given key and extension.
    pub fn get_disk_path(&self, key: &str, format: &str) -> PathBuf {
        let clean_ext = format.trim().trim_start_matches('.');
        self.cache_dir.join(format!("chunk_{}.{}", key, clean_ext))
    }

    /// Checks if a valid cached file exists on disk.
    pub fn has_valid_disk_cache(&self, key: &str, format: &str) -> bool {
        let path = self.get_disk_path(key, format);
        match fs::metadata(path) {
            Ok(meta) => meta.is_file() && meta.len() > 0,
            Err(_) => false,
        }
    }

    /// Retrieves L1 in-memory decoded audio buffer if present.
    pub fn get_memory(&self, key: &str) -> Option<Arc<AudioBuffer>> {
        let mut mem = self.memory_cache.lock().unwrap();
        mem.get(key)
    }

    /// Stores L1 in-memory decoded audio buffer.
    pub fn put_memory(&self, key: String, buffer: Arc<AudioBuffer>) {
        let mut mem = self.memory_cache.lock().unwrap();
        mem.put(key, buffer);
    }

    /// Reads raw audio bytes from L2 disk cache.
    pub fn get_disk_bytes(&self, key: &str, format: &str) -> Result<Option<Bytes>, CacheError> {
        let path = self.get_disk_path(key, format);
        if !path.exists() {
            return Ok(None);
        }

        let data = fs::read(&path)?;
        if data.is_empty() {
            let _ = fs::remove_file(path);
            return Ok(None);
        }

        Ok(Some(Bytes::from(data)))
    }

    /// Atomically writes raw audio bytes to L2 disk cache via `.tmp` swap.
    pub fn put_disk_bytes(
        &self,
        key: &str,
        format: &str,
        data: &[u8],
    ) -> Result<PathBuf, CacheError> {
        let target_path = self.get_disk_path(key, format);
        let tmp_path = self.cache_dir.join(format!("chunk_{}.tmp", key));

        fs::write(&tmp_path, data)?;
        fs::rename(&tmp_path, &target_path)?;

        Ok(target_path)
    }

    /// Prunes disk cache if total size exceeds configured maximum quota.
    ///
    /// Evicts oldest modified files first until total size is below 80% of limit.
    pub fn prune_disk_cache(&self) -> Result<usize, CacheError> {
        let entries = match fs::read_dir(&self.cache_dir) {
            Ok(e) => e,
            Err(_) => return Ok(0),
        };

        struct FileMeta {
            path: PathBuf,
            size: u64,
            modified: std::time::SystemTime,
        }

        let mut files = Vec::new();
        let mut total_bytes = 0u64;

        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_file() {
                if let Ok(meta) = entry.metadata() {
                    let len = meta.len();
                    total_bytes += len;
                    let modified = meta.modified().unwrap_or(std::time::SystemTime::UNIX_EPOCH);
                    files.push(FileMeta {
                        path,
                        size: len,
                        modified,
                    });
                }
            }
        }

        if total_bytes <= self.max_disk_bytes {
            return Ok(0);
        }

        // Sort oldest first
        files.sort_by_key(|f| f.modified);

        let target_bytes = (self.max_disk_bytes as f64 * 0.8) as u64;
        let mut pruned_count = 0;

        for file in files {
            if total_bytes <= target_bytes {
                break;
            }
            if fs::remove_file(&file.path).is_ok() {
                total_bytes = total_bytes.saturating_sub(file.size);
                pruned_count += 1;
            }
        }

        Ok(pruned_count)
    }

    /// Clears all L1 memory cache entries.
    pub fn clear_memory(&self) {
        let mut mem = self.memory_cache.lock().unwrap();
        mem.clear();
    }
}
