// Copyright (c) 2025 Zipherpunk.com dev team
// Block timestamp manager - downloads from GitHub and caches locally

import Foundation
import CryptoKit

/// Provides block timestamp lookup from multiple sources:
/// 1. Cached file downloaded from GitHub (stored in Documents)
/// 2. Runtime cache for newly synced blocks
/// 3. HeaderStore (synced at runtime from P2P network)
///
/// File format: [timestamp: UInt32 LE] × (maxHeight + 1)
/// Each timestamp is at offset (height × 4)
final class BlockTimestampManager {
    static let shared = BlockTimestampManager()

    // GitHub URLs (from ZipherX_Boost repo)
    // Manifest is always from main branch (contains latest height info)
    private static let MANIFEST_URL = "https://raw.githubusercontent.com/VictorLux/ZipherX_Boost/main/block_timestamps_manifest.json"
    // Timestamps file URL is built dynamically based on manifest height

    /// Local cache filename
    private static let CACHE_FILENAME = "block_timestamps_cache.bin"

    /// Maximum height in the loaded file
    private(set) var maxHeight: UInt64 = 0

    /// Memory-mapped file data
    private var timestampData: Data?

    /// Runtime timestamp cache (heights beyond file range)
    private var runtimeCache: [UInt64: UInt32] = [:]
    private let cacheLock = NSLock()

    /// Download state
    private var isDownloading = false

    /// Path to cached file in Documents directory
    private var cacheFilePath: URL {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return documentsURL.appendingPathComponent(Self.CACHE_FILENAME)
    }

    private init() {
        loadCachedTimestamps()
    }

    // MARK: - Loading

    /// Load cached file from Documents directory
    private func loadCachedTimestamps() {
        // Check for cached file in Documents
        guard FileManager.default.fileExists(atPath: cacheFilePath.path) else {
            print("⏰ BlockTimestampManager: No cached timestamps file, will download from GitHub")
            return
        }

        do {
            let data = try Data(contentsOf: cacheFilePath, options: .mappedIfSafe)
            self.timestampData = data

            // Calculate max height from file size (4 bytes per timestamp)
            self.maxHeight = UInt64(data.count / 4) - 1

            print("✅ BlockTimestampManager: Loaded cached timestamps for blocks 0-\(maxHeight)")
        } catch {
            print("❌ BlockTimestampManager: Failed to load cached: \(error)")
        }
    }

    // MARK: - Download from GitHub

    /// Download/update timestamps file from GitHub
    /// Returns: (success, maxHeight)
    func downloadIfNeeded(onProgress: ((Double, String) -> Void)? = nil) async -> (Bool, UInt64) {
        guard !isDownloading else {
            print("⚠️ BlockTimestampManager: Download already in progress")
            return (false, maxHeight)
        }

        isDownloading = true
        defer { isDownloading = false }

        onProgress?(0.0, "Checking for timestamp updates...")

        // Fetch manifest from GitHub
        let manifest = await fetchManifest()

        if let manifest = manifest {
            print("📡 Timestamp manifest: max height \(manifest.maxHeight), sha256: \(manifest.sha256.prefix(16))...")
        } else {
            print("⚠️ Could not fetch timestamp manifest, using local file only")
            return (timestampData != nil, maxHeight)
        }

        // Check if we need to download (newer data available)
        let localMaxHeight = maxHeight
        guard let remoteManifest = manifest, UInt64(remoteManifest.maxHeight) > localMaxHeight else {
            print("✅ Local timestamps are up to date (max height \(localMaxHeight))")
            onProgress?(1.0, "Timestamps up to date")
            return (true, maxHeight)
        }

        print("⬇️ Downloading newer timestamps (remote: \(remoteManifest.maxHeight) > local: \(localMaxHeight))...")
        onProgress?(0.1, "Downloading timestamps...")

        // Build dynamic release URL based on manifest height
        let timestampsURL = "https://github.com/VictorLux/ZipherX_Boost/releases/download/v\(remoteManifest.maxHeight)-timestamps/block_timestamps.bin"
        print("📥 Downloading from: \(timestampsURL)")

        // Download the file
        guard let downloadedURL = await downloadFile(
            from: timestampsURL,
            expectedSize: remoteManifest.fileSize,
            onProgress: { progress in
                onProgress?(0.1 + progress * 0.8, "Downloading: \(Int(progress * 100))%")
            }
        ) else {
            print("❌ Download failed, using local file")
            return (timestampData != nil, maxHeight)
        }

        // Verify checksum
        onProgress?(0.92, "Verifying checksum...")
        if !verifySHA256(fileURL: downloadedURL, expectedHash: remoteManifest.sha256) {
            print("🚨 SECURITY: Downloaded timestamps failed checksum verification!")
            try? FileManager.default.removeItem(at: downloadedURL)
            return (timestampData != nil, maxHeight)
        }

        // Move to cache location
        do {
            if FileManager.default.fileExists(atPath: cacheFilePath.path) {
                try FileManager.default.removeItem(at: cacheFilePath)
            }
            try FileManager.default.moveItem(at: downloadedURL, to: cacheFilePath)
            print("✅ Downloaded, verified, and saved timestamps to cache")

            // Reload the file
            timestampData = nil
            loadCachedTimestamps()
            onProgress?(1.0, "Ready: timestamps to height \(maxHeight)")
            return (true, maxHeight)
        } catch {
            print("❌ Failed to save downloaded timestamps: \(error)")
            return (timestampData != nil, maxHeight)
        }
    }

    /// Fetch manifest from GitHub
    private func fetchManifest() async -> TimestampManifest? {
        guard let url = URL(string: Self.MANIFEST_URL) else { return nil }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return nil
            }
            return parseManifest(data)
        } catch {
            print("⚠️ BlockTimestampManager: Manifest fetch error: \(error)")
            return nil
        }
    }

    /// Parse manifest JSON
    private func parseManifest(_ data: Data) -> TimestampManifest? {
        do {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let maxHeight = json["max_height"] as? Int,
                  let fileSize = json["file_size"] as? Int,
                  let sha256 = json["sha256"] as? String else {
                return nil
            }
            return TimestampManifest(maxHeight: maxHeight, fileSize: fileSize, sha256: sha256)
        } catch {
            return nil
        }
    }

    /// Verify SHA256 checksum
    private func verifySHA256(fileURL: URL, expectedHash: String) -> Bool {
        do {
            let data = try Data(contentsOf: fileURL)
            let hash = SHA256.hash(data: data)
            let computedHash = hash.compactMap { String(format: "%02x", $0) }.joined()
            let matches = computedHash.lowercased() == expectedHash.lowercased()
            if matches {
                print("✅ SHA256 checksum verified: \(computedHash.prefix(16))...")
            } else {
                print("❌ SHA256 mismatch! Expected: \(expectedHash.prefix(16))..., Got: \(computedHash.prefix(16))...")
            }
            return matches
        } catch {
            print("❌ Failed to read file for checksum: \(error)")
            return false
        }
    }

    /// Download file with progress
    private func downloadFile(from urlString: String, expectedSize: Int, onProgress: @escaping (Double) -> Void) async -> URL? {
        guard let url = URL(string: urlString) else { return nil }

        return await withCheckedContinuation { continuation in
            let session = URLSession(
                configuration: .default,
                delegate: DownloadProgressDelegate(expectedSize: expectedSize, onProgress: onProgress) { tempURL in
                    continuation.resume(returning: tempURL)
                },
                delegateQueue: nil
            )

            let task = session.downloadTask(with: url)
            task.resume()
        }
    }

    // MARK: - Public API

    /// Get real block timestamp for a given height
    /// Checks: 1) Cached file, 2) Runtime cache, 3) HeaderStore
    func getTimestamp(at height: UInt64) -> UInt32? {
        // 1. Check cached file
        if let cached = getFileTimestamp(at: height) {
            return cached
        }

        // 2. Check runtime cache
        cacheLock.lock()
        if let runtime = runtimeCache[height] {
            cacheLock.unlock()
            return runtime
        }
        cacheLock.unlock()

        // 3. Check HeaderStore
        if let headerTime = try? HeaderStore.shared.getBlockTime(at: height) {
            // Cache for future lookups
            cacheLock.lock()
            runtimeCache[height] = UInt32(headerTime)
            cacheLock.unlock()
            return UInt32(headerTime)
        }

        return nil
    }

    /// Get timestamp from file only (for performance when we know it's in range)
    func getFileTimestamp(at height: UInt64) -> UInt32? {
        guard let data = timestampData else { return nil }
        guard height <= maxHeight else { return nil }

        let offset = Int(height) * 4
        guard offset + 4 <= data.count else { return nil }

        // Read UInt32 little-endian
        return data.withUnsafeBytes { ptr in
            ptr.load(fromByteOffset: offset, as: UInt32.self)
        }
    }

    /// Add timestamp to runtime cache (called during sync)
    func cacheTimestamp(height: UInt64, timestamp: UInt32) {
        guard height > maxHeight else { return }  // Don't cache file range
        cacheLock.lock()
        runtimeCache[height] = timestamp
        cacheLock.unlock()
    }

    /// Batch cache timestamps (for efficiency during sync)
    func cacheTimestamps(_ timestamps: [(UInt64, UInt32)]) {
        cacheLock.lock()
        for (height, timestamp) in timestamps {
            if height > maxHeight {
                runtimeCache[height] = timestamp
            }
        }
        cacheLock.unlock()
    }

    /// Check if timestamp is available for height
    func hasTimestamp(at height: UInt64) -> Bool {
        return getTimestamp(at: height) != nil
    }

    /// Get timestamp as Date for display
    func getDate(at height: UInt64) -> Date? {
        guard let timestamp = getTimestamp(at: height) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(timestamp))
    }

    /// Get formatted date string for height
    func getFormattedDate(at height: UInt64) -> String? {
        guard let date = getDate(at: height) else { return nil }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// Clear runtime cache (e.g., on wallet reset)
    func clearRuntimeCache() {
        cacheLock.lock()
        runtimeCache.removeAll()
        cacheLock.unlock()
    }

    // MARK: - Async Fetch for Missing Timestamps

    /// Fetch timestamp from InsightAPI for a specific height
    func fetchTimestamp(at height: UInt64) async -> UInt32? {
        // Get block hash first
        guard let blockHash = try? await InsightAPI.shared.getBlockHash(height: height) else {
            return nil
        }
        // Get block info
        guard let block = try? await InsightAPI.shared.getBlock(hash: blockHash) else {
            return nil
        }
        let timestamp = UInt32(block.time)
        cacheTimestamp(height: height, timestamp: timestamp)
        return timestamp
    }

    /// Batch fetch timestamps for heights without timestamps
    func fetchMissingTimestamps(heights: [UInt64]) async {
        for height in heights {
            guard getTimestamp(at: height) == nil else { continue }
            _ = await fetchTimestamp(at: height)
        }
    }
}

// MARK: - Manifest Structure

private struct TimestampManifest {
    let maxHeight: Int
    let fileSize: Int
    let sha256: String
}

// MARK: - Download Delegate

private class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate {
    let expectedSize: Int
    let onProgress: (Double) -> Void
    let onComplete: (URL?) -> Void

    init(expectedSize: Int, onProgress: @escaping (Double) -> Void, onComplete: @escaping (URL?) -> Void) {
        self.expectedSize = expectedSize
        self.onProgress = onProgress
        self.onComplete = onComplete
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bin")
        do {
            try FileManager.default.copyItem(at: location, to: tempURL)
            onComplete(tempURL)
        } catch {
            print("❌ DownloadProgressDelegate: Failed to copy file: \(error)")
            onComplete(nil)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : Int64(expectedSize)
        let progress = Double(totalBytesWritten) / Double(total)
        onProgress(min(progress, 1.0))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if error != nil {
            onComplete(nil)
        }
    }
}
