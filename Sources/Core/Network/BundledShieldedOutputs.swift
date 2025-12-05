//
//  BundledShieldedOutputs.swift
//  ZipherX
//
//  Created by Claude on 2025-12-05.
//  Pre-bundled shielded outputs for fast parallel note discovery
//  Downloaded at sync start, used for scanning, then cleaned up after sync completes
//

import Foundation
import CryptoKit

/// Represents a single shielded output from the bundled file
struct ShieldedOutputData {
    let height: UInt32
    let txIndex: UInt16
    let outputIndex: UInt16
    let cmu: Data        // 32 bytes
    let epk: Data        // 32 bytes
    let encCiphertext: Data  // 580 bytes
    let nullifier: Data  // 32 bytes (placeholder, computed later)
}

/// Loader for pre-bundled shielded outputs file
/// File format:
///   Header (24 bytes):
///     - version: UInt32 (4 bytes)
///     - count: UInt64 (8 bytes)
///     - startHeight: UInt64 (8 bytes)
///     - endHeight: UInt32 (4 bytes)
///   Outputs (684 bytes each):
///     - height: UInt32 (4 bytes)
///     - tx_index: UInt16 (2 bytes)
///     - output_index: UInt16 (2 bytes)
///     - cmu: [UInt8; 32]
///     - epk: [UInt8; 32]
///     - enc_ciphertext: [UInt8; 580]
///     - nullifier: [UInt8; 32]
final class BundledShieldedOutputs {

    static let shared = BundledShieldedOutputs()

    // File format constants
    private static let HEADER_SIZE = 24
    private static let OUTPUT_SIZE = 684
    private static let FORMAT_VERSION: UInt32 = 1

    // GitHub download URLs (from ZipherX_Boost repo)
    // Manifest is in raw repo, binary is in GitHub release (too large for raw)
    private static let MANIFEST_URL = "https://raw.githubusercontent.com/VictorLux/ZipherX_Boost/main/shielded_outputs_manifest.json"
    private static let OUTPUTS_URL = "https://github.com/VictorLux/ZipherX_Boost/releases/download/v1.0.0-shielded-outputs/shielded_outputs.bin"

    // Local cache filename
    private static let CACHE_FILENAME = "shielded_outputs_cache.bin"

    // Cached file data (memory-mapped for efficiency)
    private var fileData: Data?
    private var outputCount: UInt64 = 0
    private var startHeight: UInt64 = 0
    private var endHeight: UInt32 = 0

    // Height index for binary search (built on first use)
    private var heightIndex: [(height: UInt32, offset: Int)]?

    // Download state
    private var isDownloading = false
    private var downloadTask: URLSessionDownloadTask?

    private init() {}

    /// Check if bundled outputs are available (either in memory or on disk)
    var isAvailable: Bool {
        if fileData != nil && outputCount > 0 {
            return true
        }
        // Check if bundled in app bundle first
        if Bundle.main.url(forResource: "shielded_outputs", withExtension: "bin") != nil {
            return true
        }
        // Check if cached file exists (downloaded)
        return FileManager.default.fileExists(atPath: cacheFilePath.path)
    }

    /// Get the height range covered by bundled outputs
    var heightRange: ClosedRange<UInt64>? {
        loadIfNeeded()
        guard fileData != nil else { return nil }
        return startHeight...UInt64(endHeight)
    }

    /// Get total number of bundled outputs
    var count: UInt64 {
        loadIfNeeded()
        return outputCount
    }

    /// Get the end height covered by bundled outputs
    var bundledEndHeight: UInt64 {
        loadIfNeeded()
        return UInt64(endHeight)
    }

    /// Path to the cached file in Documents directory
    private var cacheFilePath: URL {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return documentsURL.appendingPathComponent(Self.CACHE_FILENAME)
    }

    // MARK: - Download Management

    /// Download shielded outputs file from GitHub for sync
    /// Returns: (success, outputCount, endHeight)
    /// ALWAYS checks GitHub manifest for newer version, even if bundled file exists
    func downloadForSync(onProgress: @escaping (Double, String) -> Void) async -> (Bool, UInt64, UInt64) {
        guard !isDownloading else {
            print("⚠️ BundledShieldedOutputs: Download already in progress")
            return (false, 0, 0)
        }

        isDownloading = true
        defer { isDownloading = false }

        onProgress(0.0, "Checking for updates...")

        // ALWAYS check GitHub manifest for newer version
        let manifestData = await fetchManifest()
        let manifest = manifestData.flatMap { parseManifest($0) }

        let remoteHeight = manifest?.endHeight ?? 0
        let remoteCount = manifest?.outputCount ?? 0
        let remoteSize = manifest?.fileSize ?? 0
        let remoteSHA256 = manifest?.sha256 ?? ""

        if manifest != nil {
            print("📡 GitHub manifest: height \(remoteHeight), \(remoteCount) outputs, sha256: \(remoteSHA256.prefix(16))...")
        } else {
            print("⚠️ Could not fetch GitHub manifest, will use local files only")
        }

        // Check bundled file in app bundle
        var bundledHeight: UInt64 = 0
        if let bundledURL = Bundle.main.url(forResource: "shielded_outputs", withExtension: "bin") {
            // Temporarily load to check height
            loadFromURL(bundledURL)
            bundledHeight = UInt64(endHeight)
            print("📦 Bundled file: height \(bundledHeight), \(outputCount) outputs")
        }

        // Check cached/downloaded file
        var cachedHeight: UInt64 = 0
        if FileManager.default.fileExists(atPath: cacheFilePath.path) {
            // Temporarily clear to load cached
            fileData = nil
            loadFromURL(cacheFilePath)
            cachedHeight = UInt64(endHeight)
            print("💾 Cached file: height \(cachedHeight), \(outputCount) outputs")
        }

        // Determine best source: GitHub (if newer) > cached > bundled
        let localBestHeight = max(bundledHeight, cachedHeight)

        // If GitHub has newer data, download it
        if remoteHeight > localBestHeight && manifest != nil {
            print("⬇️ GitHub has newer data (remote: \(remoteHeight) > local: \(localBestHeight)), downloading...")
            onProgress(0.05, "Found \(remoteCount) outputs up to height \(remoteHeight)")

            // Check disk space before download (need file size + ~100MB buffer for processing)
            let requiredSpace = remoteSize + 100_000_000
            if !Self.hasEnoughDiskSpace(requiredBytes: requiredSpace) {
                print("🚨 Insufficient disk space for download")
                onProgress(0.0, "Error: Need \(formatBytes(requiredSpace)) free space")
                return await useBestLocalFile(bundledHeight: bundledHeight, cachedHeight: cachedHeight, onProgress: onProgress)
            }

            // Need to download from GitHub
            onProgress(0.1, "Downloading \(formatBytes(remoteSize))...")

            guard let fileURL = await downloadFile(from: Self.OUTPUTS_URL, expectedSize: remoteSize, onProgress: { progress in
                let downloadProgress = 0.1 + progress * 0.80
                onProgress(downloadProgress, "Downloading: \(Int(progress * 100))%")
            }) else {
                print("❌ Download failed, falling back to local file")
                return await useBestLocalFile(bundledHeight: bundledHeight, cachedHeight: cachedHeight, onProgress: onProgress)
            }

            // CRITICAL: Verify SHA256 checksum before using downloaded file
            onProgress(0.92, "Verifying checksum...")
            if !remoteSHA256.isEmpty {
                if !verifySHA256(fileURL: fileURL, expectedHash: remoteSHA256) {
                    print("🚨 SECURITY: Downloaded file failed checksum verification! Deleting...")
                    try? FileManager.default.removeItem(at: fileURL)
                    return await useBestLocalFile(bundledHeight: bundledHeight, cachedHeight: cachedHeight, onProgress: onProgress)
                }
            } else {
                print("⚠️ No checksum in manifest - skipping verification (not recommended)")
            }

            // Move to cache location
            do {
                if FileManager.default.fileExists(atPath: cacheFilePath.path) {
                    try FileManager.default.removeItem(at: cacheFilePath)
                }
                try FileManager.default.moveItem(at: fileURL, to: cacheFilePath)
                print("✅ Downloaded, verified, and saved to cache")

                // Load the downloaded file
                fileData = nil
                loadFromURL(cacheFilePath)
                onProgress(1.0, "Ready: \(outputCount) outputs to height \(endHeight)")
                return (true, outputCount, UInt64(endHeight))
            } catch {
                print("❌ Failed to save downloaded file: \(error)")
                return await useBestLocalFile(bundledHeight: bundledHeight, cachedHeight: cachedHeight, onProgress: onProgress)
            }
        }

        // Use best local file (no download needed or download failed)
        return await useBestLocalFile(bundledHeight: bundledHeight, cachedHeight: cachedHeight, onProgress: onProgress)
    }

    /// Helper to use the best available local file
    private func useBestLocalFile(bundledHeight: UInt64, cachedHeight: UInt64, onProgress: @escaping (Double, String) -> Void) async -> (Bool, UInt64, UInt64) {
        fileData = nil  // Clear any previous load

        if cachedHeight >= bundledHeight && cachedHeight > 0 {
            print("📦 Using cached file (height \(cachedHeight))")
            loadFromURL(cacheFilePath)
        } else if let bundledURL = Bundle.main.url(forResource: "shielded_outputs", withExtension: "bin") {
            print("📦 Using bundled file (height \(bundledHeight))")
            loadFromURL(bundledURL)
        } else {
            print("⚠️ No shielded outputs file available")
            return (false, 0, 0)
        }

        onProgress(1.0, "Using local outputs to height \(endHeight)")
        return (true, outputCount, UInt64(endHeight))
    }

    /// Fetch manifest from GitHub
    private func fetchManifest() async -> Data? {
        guard let url = URL(string: Self.MANIFEST_URL) else { return nil }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return nil
            }
            return data
        } catch {
            print("⚠️ BundledShieldedOutputs: Manifest fetch error: \(error)")
            return nil
        }
    }

    /// Parse manifest JSON - returns (endHeight, outputCount, fileSize, sha256)
    private func parseManifest(_ data: Data) -> (endHeight: UInt64, outputCount: UInt64, fileSize: Int, sha256: String)? {
        do {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let height = json["end_height"] as? Int,
                  let count = json["output_count"] as? Int,
                  let size = json["file_size"] as? Int,
                  let sha256 = json["sha256"] as? String else {
                return nil
            }
            return (endHeight: UInt64(height), outputCount: UInt64(count), fileSize: size, sha256: sha256)
        } catch {
            return nil
        }
    }

    /// Check available disk space (returns bytes available)
    static func getAvailableDiskSpace() -> Int64 {
        let documentDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        do {
            let values = try documentDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            if let capacity = values.volumeAvailableCapacityForImportantUsage {
                return capacity
            }
        } catch {
            print("⚠️ Failed to get disk space: \(error)")
        }
        return 0
    }

    /// Check if enough disk space is available for download (requires ~700 MB for download + processing)
    static func hasEnoughDiskSpace(requiredBytes: Int = 750_000_000) -> Bool {
        let available = getAvailableDiskSpace()
        let hasSpace = available >= Int64(requiredBytes)
        if !hasSpace {
            print("⚠️ Insufficient disk space: \(formatBytesStatic(Int(available))) available, need \(formatBytesStatic(requiredBytes))")
        }
        return hasSpace
    }

    /// Format bytes to human readable string (static version)
    private static func formatBytesStatic(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        if bytes < 1024 * 1024 * 1024 { return String(format: "%.1f MB", Double(bytes) / (1024 * 1024)) }
        return String(format: "%.2f GB", Double(bytes) / (1024 * 1024 * 1024))
    }

    /// Verify SHA256 checksum of a file
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
            print("❌ Failed to read file for checksum verification: \(error)")
            return false
        }
    }

    /// Download file with progress
    private func downloadFile(from urlString: String, expectedSize: Int, onProgress: @escaping (Double) -> Void) async -> URL? {
        guard let url = URL(string: urlString) else { return nil }

        return await withCheckedContinuation { continuation in
            let session = URLSession(configuration: .default, delegate: DownloadDelegate(expectedSize: expectedSize, onProgress: onProgress) { tempURL in
                continuation.resume(returning: tempURL)
            }, delegateQueue: nil)

            let task = session.downloadTask(with: url)
            self.downloadTask = task
            task.resume()
        }
    }

    /// Clean up downloaded file after sync completes
    /// NOTE: Only removes the CACHE file, not any source files
    func cleanupAfterSync() {
        // Clear memory
        fileData = nil
        heightIndex = nil
        outputCount = 0
        startHeight = 0
        endHeight = 0

        // Delete cached file
        if FileManager.default.fileExists(atPath: cacheFilePath.path) {
            do {
                try FileManager.default.removeItem(at: cacheFilePath)
                print("🧹 BundledShieldedOutputs: Cleaned up cache file after sync")
            } catch {
                print("⚠️ BundledShieldedOutputs: Failed to cleanup cache: \(error)")
            }
        }
    }

    /// Cancel ongoing download
    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        isDownloading = false
    }

    // MARK: - File Loading

    /// Load bundled file if not already loaded
    private func loadIfNeeded() {
        guard fileData == nil else { return }

        // PRIORITY 1: Try bundled resource in app bundle (fastest - no download needed!)
        if let bundledURL = Bundle.main.url(forResource: "shielded_outputs", withExtension: "bin") {
            print("📦 Loading shielded outputs from app bundle...")
            loadFromURL(bundledURL)
            return
        }

        // PRIORITY 2: Try cached/downloaded file
        if FileManager.default.fileExists(atPath: cacheFilePath.path) {
            print("📦 Loading shielded outputs from cache...")
            loadFromURL(cacheFilePath)
            return
        }

        print("⚠️ BundledShieldedOutputs: No bundled or cached file found")
    }

    /// Load and validate file from URL
    private func loadFromURL(_ url: URL) {
        // CRITICAL: Clear heightIndex when loading new file - it was built for previous file!
        heightIndex = nil

        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)

            guard data.count >= Self.HEADER_SIZE else {
                print("❌ BundledShieldedOutputs: File too small for header")
                return
            }

            // Parse header using safe byte-by-byte reading (avoids alignment issues)
            let version = readUInt32(from: data, at: 0)
            guard version == Self.FORMAT_VERSION else {
                print("❌ BundledShieldedOutputs: Unknown format version \(version)")
                return
            }

            outputCount = readUInt64(from: data, at: 4)
            startHeight = readUInt64(from: data, at: 12)
            endHeight = readUInt32(from: data, at: 20)

            // Validate size
            let expectedSize = Self.HEADER_SIZE + Int(outputCount) * Self.OUTPUT_SIZE
            guard data.count >= expectedSize else {
                print("❌ BundledShieldedOutputs: File size mismatch. Expected \(expectedSize), got \(data.count)")
                return
            }

            fileData = data
            print("✅ BundledShieldedOutputs: Loaded \(outputCount) outputs from height \(startHeight) to \(endHeight)")

        } catch {
            print("❌ BundledShieldedOutputs: Failed to load file: \(error)")
        }
    }

    // MARK: - Safe Byte Reading (avoids alignment crashes with memory-mapped files)

    private func readUInt32(from data: Data, at offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        return data.withUnsafeBytes { ptr in
            let bytes = ptr.baseAddress!.advanced(by: offset).assumingMemoryBound(to: UInt8.self)
            return UInt32(bytes[0]) |
                   (UInt32(bytes[1]) << 8) |
                   (UInt32(bytes[2]) << 16) |
                   (UInt32(bytes[3]) << 24)
        }
    }

    private func readUInt64(from data: Data, at offset: Int) -> UInt64 {
        guard offset + 8 <= data.count else { return 0 }
        return data.withUnsafeBytes { ptr in
            let bytes = ptr.baseAddress!.advanced(by: offset).assumingMemoryBound(to: UInt8.self)
            return UInt64(bytes[0]) |
                   (UInt64(bytes[1]) << 8) |
                   (UInt64(bytes[2]) << 16) |
                   (UInt64(bytes[3]) << 24) |
                   (UInt64(bytes[4]) << 32) |
                   (UInt64(bytes[5]) << 40) |
                   (UInt64(bytes[6]) << 48) |
                   (UInt64(bytes[7]) << 56)
        }
    }

    private func readUInt16(from data: Data, at offset: Int) -> UInt16 {
        guard offset + 2 <= data.count else { return 0 }
        return data.withUnsafeBytes { ptr in
            let bytes = ptr.baseAddress!.advanced(by: offset).assumingMemoryBound(to: UInt8.self)
            return UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
        }
    }

    // MARK: - Output Access

    /// Build height index for binary search (lazy initialization)
    private func buildHeightIndex() {
        guard heightIndex == nil, let data = fileData else { return }

        var index: [(height: UInt32, offset: Int)] = []
        var lastHeight: UInt32 = 0

        for i in 0..<Int(outputCount) {
            let offset = Self.HEADER_SIZE + i * Self.OUTPUT_SIZE
            let height = readUInt32(from: data, at: offset)

            // Record first occurrence of each height
            if height != lastHeight {
                index.append((height: height, offset: offset))
                lastHeight = height
            }
        }

        heightIndex = index
        print("📊 BundledShieldedOutputs: Built height index with \(index.count) unique heights")
    }

    /// Get all shielded outputs in a height range
    /// Uses binary search for efficient range lookup
    func getOutputsInRange(from: UInt64, to: UInt64) -> [ShieldedOutputData] {
        loadIfNeeded()
        guard let data = fileData else {
            print("⚠️ getOutputsInRange: fileData is nil")
            return []
        }

        // Build index if needed
        if heightIndex == nil {
            buildHeightIndex()
        }

        guard let index = heightIndex, !index.isEmpty else {
            print("⚠️ getOutputsInRange: heightIndex is nil or empty")
            return []
        }

        // Binary search for start position
        var lo = 0
        var hi = index.count

        while lo < hi {
            let mid = (lo + hi) / 2
            if index[mid].height < UInt32(from) {
                lo = mid + 1
            } else {
                hi = mid
            }
        }

        // Handle edge case: start height not found (request is for heights beyond bundled range)
        if lo >= index.count {
            // This is NORMAL when scanning heights beyond bundled data
            // Only log if debugging specific issues
            return []
        }

        // Check if first matching index is actually in our range
        // (binary search finds first >= from, but that might be > to)
        if index[lo].height > UInt32(to) {
            // Range has no outputs (sparse area of chain)
            return []
        }

        // Collect outputs in range
        var outputs: [ShieldedOutputData] = []
        var offset = index[lo].offset

        let dataCount = data.count
        while offset + Self.OUTPUT_SIZE <= dataCount {
            let output = parseOutput(at: offset, in: data)

            if output.height > UInt32(to) {
                break
            }

            if output.height >= UInt32(from) {
                outputs.append(output)
            }

            offset += Self.OUTPUT_SIZE
        }

        return outputs
    }

    /// Parse a single output at the given offset
    private func parseOutput(at offset: Int, in data: Data) -> ShieldedOutputData {
        let height = readUInt32(from: data, at: offset)
        let txIndex = readUInt16(from: data, at: offset + 4)
        let outputIndex = readUInt16(from: data, at: offset + 6)

        let cmu = data.subdata(in: (offset + 8)..<(offset + 40))
        let epk = data.subdata(in: (offset + 40)..<(offset + 72))
        let encCiphertext = data.subdata(in: (offset + 72)..<(offset + 652))
        let nullifier = data.subdata(in: (offset + 652)..<(offset + 684))

        return ShieldedOutputData(
            height: height,
            txIndex: txIndex,
            outputIndex: outputIndex,
            cmu: cmu,
            epk: epk,
            encCiphertext: encCiphertext,
            nullifier: nullifier
        )
    }

    /// Get outputs for parallel decryption (returns FFI-compatible format)
    /// Also returns metadata for each output to correlate decryption results
    func getOutputsForParallelDecryption(from: UInt64, to: UInt64) -> [(output: ZipherXFFI.FFIShieldedOutput, height: UInt32, txIndex: UInt16, outputIndex: UInt16, cmu: Data)] {
        let outputs = getOutputsInRange(from: from, to: to)

        return outputs.map { output in
            let ffiOutput = ZipherXFFI.FFIShieldedOutput(
                epk: output.epk,
                cmu: output.cmu,
                ciphertext: output.encCiphertext
            )
            return (output: ffiOutput, height: output.height, txIndex: output.txIndex, outputIndex: output.outputIndex, cmu: output.cmu)
        }
    }

    /// Get CMU data for tree building (in blockchain order)
    func getCMUsInRange(from: UInt64, to: UInt64) -> [Data] {
        let outputs = getOutputsInRange(from: from, to: to)
        return outputs.map { $0.cmu }
    }

    // MARK: - Helpers

    private func formatBytes(_ bytes: Int) -> String {
        let mb = Double(bytes) / 1_000_000
        if mb >= 1 {
            return String(format: "%.1f MB", mb)
        } else {
            let kb = Double(bytes) / 1_000
            return String(format: "%.0f KB", kb)
        }
    }
}

// MARK: - Download Delegate

private class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let expectedSize: Int
    let onProgress: (Double) -> Void
    let onComplete: (URL?) -> Void

    init(expectedSize: Int, onProgress: @escaping (Double) -> Void, onComplete: @escaping (URL?) -> Void) {
        self.expectedSize = expectedSize
        self.onProgress = onProgress
        self.onComplete = onComplete
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // Copy to a temp location we control (original will be deleted)
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bin")
        do {
            try FileManager.default.copyItem(at: location, to: tempURL)
            onComplete(tempURL)
        } catch {
            print("❌ DownloadDelegate: Failed to copy file: \(error)")
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
