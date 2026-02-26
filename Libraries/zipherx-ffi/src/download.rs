//! FIX #342: Fast HTTP downloads using reqwest
//! FIX #345: Static runtime + persistent client for maximum speed
//!
//! Replaces slow Swift URLSession downloads with Rust reqwest streaming.
//! Achieves 60-100+ MB/s with connection reuse.

use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::OnceLock;
use std::time::Instant;

use futures::StreamExt;
use reqwest::Client;
use tokio::fs::File;
use tokio::io::{AsyncWriteExt, BufWriter};
use tokio::runtime::Runtime;

// FIX #345: Static client for HTTP connection reuse (runtime created per-download to avoid block_on deadlock)
static CLIENT: OnceLock<Client> = OnceLock::new();

fn get_client() -> &'static Client {
    CLIENT.get_or_init(|| {
        // FIX #463: More aggressive TCP configuration for faster network change detection
        // - Shorter keepalive (10s) to detect broken connections faster on network change
        // - pool_max_idle_per_host(0) = don't keep stale connections across network changes
        // - connect_timeout for faster initial connection
        // FIX #886: Stall detection handled by STALL_TIMEOUT_SECS (5s) in streaming loop
        // Note: read_timeout not available in reqwest 0.11
        Client::builder()
            .timeout(std::time::Duration::from_secs(3600)) // 1 hour total timeout
            .connect_timeout(std::time::Duration::from_secs(10)) // FIX #463: Faster connection timeout
            .pool_max_idle_per_host(0) // FIX #463: Don't reuse connections across network changes
            .tcp_keepalive(std::time::Duration::from_secs(10)) // FIX #463: Detect dead connections faster
            .build()
            .expect("Failed to create HTTP client")
    })
}

/// Progress callback type for Swift interop
/// Parameters: bytes_downloaded, total_bytes, speed_bps
pub type ProgressCallback = extern "C" fn(u64, u64, f64);

/// Global download state for progress tracking
static DOWNLOAD_BYTES: AtomicU64 = AtomicU64::new(0);
static DOWNLOAD_TOTAL: AtomicU64 = AtomicU64::new(0);
static DOWNLOAD_SPEED: AtomicU64 = AtomicU64::new(0); // bits stored as u64
static DOWNLOAD_CANCELLED: AtomicBool = AtomicBool::new(false);

/// Get current download progress (called from Swift timer)
#[no_mangle]
pub extern "C" fn zipherx_download_get_progress(
    bytes_downloaded: *mut u64,
    total_bytes: *mut u64,
    speed_bps: *mut f64,
) {
    unsafe {
        if !bytes_downloaded.is_null() {
            *bytes_downloaded = DOWNLOAD_BYTES.load(Ordering::Relaxed);
        }
        if !total_bytes.is_null() {
            *total_bytes = DOWNLOAD_TOTAL.load(Ordering::Relaxed);
        }
        if !speed_bps.is_null() {
            *speed_bps = f64::from_bits(DOWNLOAD_SPEED.load(Ordering::Relaxed));
        }
    }
}

/// Cancel current download
#[no_mangle]
pub extern "C" fn zipherx_download_cancel() {
    DOWNLOAD_CANCELLED.store(true, Ordering::Relaxed);
}

/// Reset download state
/// NOTE: Don't reset DOWNLOAD_TOTAL to 0 - keep old value to prevent progress bar flicker
fn reset_download_state() {
    DOWNLOAD_BYTES.store(0, Ordering::Relaxed);
    // DOWNLOAD_TOTAL.store(0, Ordering::Relaxed);  // DON'T reset - will be set to expected_size immediately after
    DOWNLOAD_SPEED.store(0, Ordering::Relaxed);
    DOWNLOAD_CANCELLED.store(false, Ordering::Relaxed);
}

/// Download a file with resume support and progress tracking
///
/// # Arguments
/// * `url` - URL to download from
/// * `dest_path` - Destination file path
/// * `resume_from` - Byte offset to resume from (0 for fresh download)
/// * `expected_size` - Expected total file size (for progress calculation)
///
/// # Returns
/// * 0 on success
/// * 1 on network error
/// * 2 on file error
/// * 3 on cancelled
/// * 4 on other error
#[no_mangle]
pub extern "C" fn zipherx_download_file(
    url_ptr: *const u8,
    url_len: usize,
    dest_path_ptr: *const u8,
    dest_path_len: usize,
    resume_from: u64,
    expected_size: u64,
) -> i32 {
    // FIX #1385: Validate pointers before unsafe from_raw_parts
    if url_ptr.is_null() || url_len == 0 || url_len > 8192 {
        return 4;
    }
    if dest_path_ptr.is_null() || dest_path_len == 0 || dest_path_len > 4096 {
        return 4;
    }

    // VUL-FFI-004: Use safe_slice instead of raw from_raw_parts
    let url = match unsafe { crate::safe_slice(url_ptr, url_len) } {
        Some(slice) => match std::str::from_utf8(slice) {
            Ok(s) => s.to_string(),
            Err(_) => return 4,
        },
        None => return 4,
    };

    let dest_path = match unsafe { crate::safe_slice(dest_path_ptr, dest_path_len) } {
        Some(slice) => match std::str::from_utf8(slice) {
            Ok(s) => s.to_string(),
            Err(_) => return 4,
        },
        None => return 4,
    };

    // Reset state
    reset_download_state();
    DOWNLOAD_TOTAL.store(expected_size, Ordering::Relaxed);
    DOWNLOAD_BYTES.store(resume_from, Ordering::Relaxed);

    // FIX #346: Create new runtime per download to allow parallel calls from Swift
    // (static runtime + block_on from multiple threads = deadlock)
    let runtime = match Runtime::new() {
        Ok(rt) => rt,
        Err(_) => return 4,
    };

    // Run async download
    runtime.block_on(async {
        match download_file_async(&url, &dest_path, resume_from, expected_size).await {
            Ok(_) => 0,
            Err(DownloadError::Network(_)) => 1,
            Err(DownloadError::File(_)) => 2,
            Err(DownloadError::Cancelled) => 3,
            Err(DownloadError::Other(_)) => 4,
        }
    })
}

#[derive(Debug)]
enum DownloadError {
    Network(String),
    File(String),
    Cancelled,
    Other(String),
}

async fn download_file_async(
    url: &str,
    dest_path: &str,
    resume_from: u64,
    expected_size: u64,
) -> Result<(), DownloadError> {
    // FIX #463: Reduced stall timeout for faster network change detection
    // 30 seconds is too long when WiFi/network changes - 5 seconds is enough
    const STALL_TIMEOUT_SECS: u64 = 5;
    const MAX_RETRIES: u32 = 5;  // More retries for better recovery

    // FIX #345: Use static client for HTTP/2 connection reuse
    let client = get_client();

    let mut retry_count = 0;

    loop {
        // Check current file size for resume
        let current_size = if Path::new(dest_path).exists() {
            std::fs::metadata(dest_path)
                .map(|m| m.len())
                .unwrap_or(resume_from)
        } else {
            resume_from
        };

        // FIX #1335: If file already >= expected size, download is complete.
        // Sending Range: bytes=N- where N >= total causes 416 Range Not Satisfiable.
        if expected_size > 0 && current_size >= expected_size {
            DOWNLOAD_BYTES.store(current_size, Ordering::Relaxed);
            DOWNLOAD_TOTAL.store(expected_size, Ordering::Relaxed);
            return Ok(());
        }

        // Build request with Range header for resume
        let mut request = client.get(url).header("User-Agent", "ZipherX/1.0");

        if current_size > 0 {
            request = request.header("Range", format!("bytes={}-", current_size));
        }

        // FIX #457 v4: Set DOWNLOAD_TOTAL to expected_size IMMEDIATELY
        // This allows progress bar to show from 0% even before HTTP response arrives
        // GitHub can take 30+ seconds to respond, so we show progress based on expected size
        DOWNLOAD_TOTAL.store(expected_size, Ordering::Relaxed);
        DOWNLOAD_BYTES.store(current_size, Ordering::Relaxed);

        let response = match request.send().await {
            Ok(resp) => resp,
            Err(e) => {
                retry_count += 1;
                if retry_count > MAX_RETRIES {
                    return Err(DownloadError::Network(format!("Failed after {} retries: {}", MAX_RETRIES, e)));
                }
                // FIX #463: Shorter retry delay for faster network change recovery
                tokio::time::sleep(std::time::Duration::from_secs(1)).await;
                continue;
            }
        };

        // Check response status
        let status = response.status();
        if !status.is_success() && status.as_u16() != 206 {
            retry_count += 1;
            if retry_count > MAX_RETRIES {
                return Err(DownloadError::Network(format!("HTTP error: {}", status)));
            }
            // FIX #463: Shorter retry delay for faster network change recovery
            tokio::time::sleep(std::time::Duration::from_secs(1)).await;
            continue;
        }

        // Get total size from Content-Range or Content-Length
        let total_size = if status.as_u16() == 206 {
            response.headers()
                .get("content-range")
                .and_then(|v| v.to_str().ok())
                .and_then(|s| s.split('/').last())
                .and_then(|s| s.parse().ok())
                .unwrap_or(expected_size)
        } else {
            response.content_length().unwrap_or(expected_size)
        };

        // FIX #457 v6: Only set DOWNLOAD_TOTAL if HTTP response provides valid size
        // Don't overwrite the expected_size we set earlier - it's already correct!
        // If expected_size > 0 and total_size is smaller, HTTP response is wrong, use expected_size
        if total_size == 0 || (expected_size > 0 && total_size < expected_size) {
            DOWNLOAD_TOTAL.store(expected_size, Ordering::Relaxed);
        } else {
            DOWNLOAD_TOTAL.store(total_size, Ordering::Relaxed);
        }

        // FIX #345: Open file with async I/O and large buffer (8MB) for maximum throughput
        let file = if current_size > 0 && Path::new(dest_path).exists() {
            File::options()
                .append(true)
                .open(dest_path)
                .await
                .map_err(|e| DownloadError::File(e.to_string()))?
        } else {
            File::create(dest_path)
                .await
                .map_err(|e| DownloadError::File(e.to_string()))?
        };

        // 8MB buffer for efficient batched writes
        let mut writer = BufWriter::with_capacity(8 * 1024 * 1024, file);

        let mut downloaded = current_size;
        let mut last_update = Instant::now();
        let mut last_bytes = downloaded;
        let mut stream = response.bytes_stream();
        let mut download_error: Option<String> = None;

        // Stream download with stall detection
        loop {
            let chunk_result = tokio::select! {
                chunk = stream.next() => chunk,
                _ = tokio::time::sleep(std::time::Duration::from_secs(STALL_TIMEOUT_SECS)) => {
                    download_error = Some("Download stalled - no data received".to_string());
                    break;
                }
            };

            // Check for cancellation
            if DOWNLOAD_CANCELLED.load(Ordering::Relaxed) {
                let _ = writer.flush().await;
                return Err(DownloadError::Cancelled);
            }

            match chunk_result {
                Some(Ok(chunk)) => {
                    // FIX #345: Async write with buffering
                    writer.write_all(&chunk)
                        .await
                        .map_err(|e| DownloadError::File(e.to_string()))?;

                    downloaded += chunk.len() as u64;
                    DOWNLOAD_BYTES.store(downloaded, Ordering::Relaxed);

                    // Update speed every 500ms
                    let now = Instant::now();
                    let elapsed = now.duration_since(last_update).as_secs_f64();
                    if elapsed >= 0.5 {
                        let bytes_delta = downloaded - last_bytes;
                        let speed = bytes_delta as f64 / elapsed;
                        DOWNLOAD_SPEED.store(speed.to_bits(), Ordering::Relaxed);
                        last_update = now;
                        last_bytes = downloaded;
                    }
                }
                Some(Err(e)) => {
                    download_error = Some(format!("Stream error: {}", e));
                    break;
                }
                None => {
                    // Stream complete
                    break;
                }
            }
        }

        // Flush remaining buffer to disk
        writer.flush().await.map_err(|e| DownloadError::File(e.to_string()))?;

        // Check if download completed
        if download_error.is_none() && (total_size == 0 || downloaded >= total_size) {
            return Ok(());
        }

        // Retry on error
        retry_count += 1;
        if retry_count > MAX_RETRIES {
            return Err(DownloadError::Network(
                download_error.unwrap_or_else(|| "Download incomplete".to_string())
            ));
        }

        // FIX #463: Shorter retry delay for faster network change recovery
        tokio::time::sleep(std::time::Duration::from_secs(1)).await;
    }
}

/// Verify SHA256 checksum of a file
/// Returns 1 if checksum matches, 0 if mismatch, -1 on error
#[no_mangle]
pub extern "C" fn zipherx_verify_sha256(
    file_path_ptr: *const u8,
    file_path_len: usize,
    expected_hash_ptr: *const u8,
    expected_hash_len: usize,
) -> i32 {
    use sha2::{Sha256, Digest};
    use std::io::Read;

    // FIX #1385: Validate pointers before unsafe from_raw_parts
    if file_path_ptr.is_null() || file_path_len == 0 || file_path_len > 4096 {
        return -1;
    }
    if expected_hash_ptr.is_null() || expected_hash_len == 0 || expected_hash_len > 256 {
        return -1;
    }

    // VUL-FFI-004: Use safe_slice instead of raw from_raw_parts
    let file_path = match unsafe { crate::safe_slice(file_path_ptr, file_path_len) } {
        Some(slice) => match std::str::from_utf8(slice) {
            Ok(s) => s,
            Err(_) => return -1,
        },
        None => return -1,
    };

    let expected_hash = match unsafe { crate::safe_slice(expected_hash_ptr, expected_hash_len) } {
        Some(slice) => match std::str::from_utf8(slice) {
            Ok(s) => s.to_lowercase(),
            Err(_) => return -1,
        },
        None => return -1,
    };

    // Read file and compute hash (use std::fs::File for sync operation)
    let mut file = match std::fs::File::open(file_path) {
        Ok(f) => f,
        Err(_) => return -1,
    };

    let mut hasher = Sha256::new();
    let mut buffer = [0u8; 65536]; // 64KB buffer

    loop {
        match file.read(&mut buffer) {
            Ok(0) => break,
            Ok(n) => hasher.update(&buffer[..n]),
            Err(_) => return -1,
        }
    }

    let result = hasher.finalize();
    let actual_hash = format!("{:x}", result);

    if actual_hash == expected_hash {
        1
    } else {
        0
    }
}
