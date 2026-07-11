//! Sidecar digest cache for direct GGUF source files.
//!
//! Building a synthetic direct-GGUF package identity requires a content digest
//! of every source shard. Recomputing those digests reads each shard end to
//! end, which costs seconds to minutes of sequential I/O on every model load
//! even when the files have not changed. This cache persists one small JSON
//! record per source file and reuses the stored digest when the file's size
//! and mtime still match, skipping the full-file read entirely.
//!
//! The cache is advisory: it is a performance optimization for identity keys
//! that never leave Rust-side coordination (stage deduplication, cache keys,
//! split topology planning), not a security boundary. A `(size, mtime)` match
//! is treated as sufficient evidence that the content is unchanged. Every
//! failure mode (unreadable entry, corrupt JSON, schema or algorithm
//! mismatch, unwritable cache directory) degrades to recomputing the digest.
//!
//! Records live under a per-user cache directory (one file per source path)
//! rather than the runtime root, because runtime directories are per-instance
//! and may sit on tmpfs via `XDG_RUNTIME_DIR`, while digests stay valid across
//! reboots. Writes go through a temp file and rename so concurrent processes
//! never observe a torn record.

use std::{
    fs,
    path::{Path, PathBuf},
    time::UNIX_EPOCH,
};

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

/// Bump when the record layout or digest algorithm changes so stale entries
/// from older builds miss cleanly instead of being misread.
const CACHE_SCHEMA_VERSION: u32 = 1;
const CACHE_DIGEST_ALGO: &str = "sha256";

/// Explicit cache directory override, mirroring `MESH_LLM_RUNTIME_ROOT`.
/// Useful for deployments without a home directory (e.g. systemd services).
const CACHE_DIR_ENV: &str = "MESH_LLM_HASH_CACHE_DIR";

#[derive(Serialize, Deserialize)]
struct CachedFileDigest {
    version: u32,
    algo: String,
    path: String,
    size: u64,
    mtime_nanos: u128,
    digest: String,
}

/// Persistent map from `(path, size, mtime)` to a source-file content digest.
pub(crate) struct SidecarDigestCache {
    dir: PathBuf,
}

impl SidecarDigestCache {
    /// Resolve the default cache location.
    ///
    /// Precedence:
    /// 1. `MESH_LLM_HASH_CACHE_DIR` environment variable
    /// 2. `~/.mesh-llm/cache/hashes`
    /// 3. `None` (caching disabled, digests are always recomputed)
    pub(crate) fn open_default() -> Option<Self> {
        if let Some(dir) = std::env::var_os(CACHE_DIR_ENV) {
            return Some(Self::open_in(PathBuf::from(dir)));
        }
        let home = dirs::home_dir()?;
        Some(Self::open_in(
            home.join(".mesh-llm").join("cache").join("hashes"),
        ))
    }

    /// Open a cache rooted at an explicit directory (used by tests).
    pub(crate) fn open_in(dir: PathBuf) -> Self {
        Self { dir }
    }

    /// Return the cached digest for `path` when the stored record matches the
    /// file's current size and mtime. Any read, parse, or validation failure
    /// is a miss.
    pub(crate) fn lookup(&self, path: &Path, size: u64, mtime_nanos: u128) -> Option<String> {
        let bytes = fs::read(self.entry_path(path)).ok()?;
        let record: CachedFileDigest = serde_json::from_slice(&bytes).ok()?;
        let valid = record.version == CACHE_SCHEMA_VERSION
            && record.algo == CACHE_DIGEST_ALGO
            && record.path == path.to_string_lossy()
            && record.size == size
            && record.mtime_nanos == mtime_nanos;
        valid.then_some(record.digest)
    }

    /// Persist a digest record for `path`. Best-effort: failures are logged at
    /// debug level and otherwise ignored so an unwritable cache directory can
    /// never fail a model load.
    pub(crate) fn store(&self, path: &Path, size: u64, mtime_nanos: u128, digest: &str) {
        let record = CachedFileDigest {
            version: CACHE_SCHEMA_VERSION,
            algo: CACHE_DIGEST_ALGO.to_string(),
            path: path.to_string_lossy().to_string(),
            size,
            mtime_nanos,
            digest: digest.to_string(),
        };
        if let Err(error) = self.write_record(path, &record) {
            tracing::debug!(
                path = %path.display(),
                cache_dir = %self.dir.display(),
                %error,
                "failed to persist GGUF source digest cache entry"
            );
        }
    }

    fn write_record(&self, path: &Path, record: &CachedFileDigest) -> std::io::Result<()> {
        fs::create_dir_all(&self.dir)?;
        let bytes = serde_json::to_vec(record)?;
        let entry = self.entry_path(path);
        // Write-then-rename keeps concurrent readers and writers safe: readers
        // never see a partial record, and the last writer of identical content
        // wins.
        let tmp = entry.with_extension(format!("tmp.{}", std::process::id()));
        fs::write(&tmp, &bytes)?;
        if let Err(error) = fs::rename(&tmp, &entry) {
            let _ = fs::remove_file(&tmp);
            return Err(error);
        }
        Ok(())
    }

    /// One record file per source path, named by a digest of the path so
    /// arbitrary absolute paths map to flat, filesystem-safe names.
    fn entry_path(&self, path: &Path) -> PathBuf {
        let name = hex::encode(Sha256::digest(path.to_string_lossy().as_bytes()));
        self.dir.join(format!("{name}.json"))
    }
}

/// Nanoseconds since the Unix epoch of the file's mtime, or `None` when the
/// platform reports no mtime or a pre-epoch time (such files are uncacheable).
pub(crate) fn file_mtime_nanos(metadata: &fs::Metadata) -> Option<u128> {
    let mtime = metadata.modified().ok()?;
    let since_epoch = mtime.duration_since(UNIX_EPOCH).ok()?;
    Some(since_epoch.as_nanos())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cache_in_tempdir() -> (tempfile::TempDir, SidecarDigestCache) {
        let dir = tempfile::tempdir().unwrap();
        let cache = SidecarDigestCache::open_in(dir.path().join("hashes"));
        (dir, cache)
    }

    #[test]
    fn lookup_returns_stored_digest_on_exact_match() {
        let (_dir, cache) = cache_in_tempdir();
        let path = Path::new("/models/model.gguf");

        cache.store(path, 42, 1_700_000_000_000_000_000, "abc123");

        assert_eq!(
            cache.lookup(path, 42, 1_700_000_000_000_000_000),
            Some("abc123".to_string())
        );
    }

    #[test]
    fn lookup_misses_when_size_or_mtime_changed() {
        let (_dir, cache) = cache_in_tempdir();
        let path = Path::new("/models/model.gguf");

        cache.store(path, 42, 1_700_000_000_000_000_000, "abc123");

        assert_eq!(cache.lookup(path, 43, 1_700_000_000_000_000_000), None);
        assert_eq!(cache.lookup(path, 42, 1_700_000_000_000_000_001), None);
    }

    #[test]
    fn lookup_misses_for_different_path_with_same_metadata() {
        let (_dir, cache) = cache_in_tempdir();

        cache.store(Path::new("/models/a.gguf"), 42, 1, "abc123");

        assert_eq!(cache.lookup(Path::new("/models/b.gguf"), 42, 1), None);
    }

    #[test]
    fn lookup_misses_on_corrupt_entry() {
        let (_dir, cache) = cache_in_tempdir();
        let path = Path::new("/models/model.gguf");

        cache.store(path, 42, 1, "abc123");
        fs::write(cache.entry_path(path), b"not json").unwrap();

        assert_eq!(cache.lookup(path, 42, 1), None);
    }

    #[test]
    fn lookup_misses_on_schema_or_algo_mismatch() {
        let (_dir, cache) = cache_in_tempdir();
        let path = Path::new("/models/model.gguf");

        let stale = CachedFileDigest {
            version: CACHE_SCHEMA_VERSION + 1,
            algo: CACHE_DIGEST_ALGO.to_string(),
            path: path.to_string_lossy().to_string(),
            size: 42,
            mtime_nanos: 1,
            digest: "abc123".to_string(),
        };
        cache.write_record(path, &stale).unwrap();
        assert_eq!(cache.lookup(path, 42, 1), None);

        let wrong_algo = CachedFileDigest {
            version: CACHE_SCHEMA_VERSION,
            algo: "xxh3-128".to_string(),
            ..stale
        };
        cache.write_record(path, &wrong_algo).unwrap();
        assert_eq!(cache.lookup(path, 42, 1), None);
    }

    #[test]
    fn lookup_misses_when_cache_dir_does_not_exist() {
        let (_dir, cache) = cache_in_tempdir();

        assert_eq!(cache.lookup(Path::new("/models/model.gguf"), 42, 1), None);
    }

    #[test]
    fn store_into_unwritable_dir_is_silent() {
        let file = tempfile::NamedTempFile::new().unwrap();
        // The cache dir path points at an existing regular file, so directory
        // creation fails; store must swallow the error.
        let cache = SidecarDigestCache::open_in(file.path().to_path_buf());

        cache.store(Path::new("/models/model.gguf"), 42, 1, "abc123");

        assert_eq!(cache.lookup(Path::new("/models/model.gguf"), 42, 1), None);
    }

    #[test]
    fn store_overwrites_previous_record() {
        let (_dir, cache) = cache_in_tempdir();
        let path = Path::new("/models/model.gguf");

        cache.store(path, 42, 1, "old");
        cache.store(path, 42, 2, "new");

        assert_eq!(cache.lookup(path, 42, 1), None);
        assert_eq!(cache.lookup(path, 42, 2), Some("new".to_string()));
    }

    #[test]
    fn file_mtime_nanos_reports_recent_files() {
        let file = tempfile::NamedTempFile::new().unwrap();
        let metadata = file.path().metadata().unwrap();

        let mtime = file_mtime_nanos(&metadata).unwrap();

        // Sanity: strictly after 2020-01-01 in nanoseconds.
        assert!(mtime > 1_577_836_800_000_000_000);
    }
}
