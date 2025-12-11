// Copyright (c) 2025 Zipherpunk.com dev team
// Block timestamp manager - extracts from boost file or uses legacy cache

import Foundation
import CryptoKit

/// Provides block timestamp lookup from multiple sources:
/// 1. Boost file (extracted from ZipherX_Boost unified file)
/// 2. Legacy cached file (previously downloaded)
/// 3. Runtime cache for newly synced blocks
/// 4. HeaderStore (synced at runtime from P2P network)
///
/// Boost file format: [timestamp: UInt32 LE] × count (4 bytes each)
/// Legacy format: [timestamp: UInt32 LE] × (maxHeight + 1) - Each timestamp is at offset (height × 4)
final class BlockTimestampManager {
    static let shared = BlockTimestampManager()

    /// Local cache filename (legacy format)
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

    /// Path to cached file in app data directory
    private var cacheFilePath: URL {
        return AppDirectories.appData.appendingPathComponent(Self.CACHE_FILENAME)
    }

    private init() {
        loadCachedTimestamps()
    }

    // MARK: - Loading

    /// Load cached file from Documents directory or check HeaderStore.block_times
    private func loadCachedTimestamps() {
        // First, check for cached file in Documents
        if FileManager.default.fileExists(atPath: cacheFilePath.path) {
            do {
                let data = try Data(contentsOf: cacheFilePath, options: .mappedIfSafe)
                self.timestampData = data
                self.maxHeight = UInt64(data.count / 4) - 1
                print("✅ BlockTimestampManager: Loaded cached timestamps for blocks 0-\(maxHeight)")
                return
            } catch {
                print("❌ BlockTimestampManager: Failed to load file cache: \(error)")
            }
        }

        // FIX #120: Check HeaderStore.block_times table (timestamps may already be in DB from previous session)
        // This is the unified timestamp storage that was populated when boost file was downloaded
        do {
            try HeaderStore.shared.open()
            let dbCount = try HeaderStore.shared.getBlockTimesCount()
            if dbCount > 0 {
                // Timestamps exist in database - set maxHeight so getTimestamp() will use HeaderStore
                // We don't load into memory, just mark that timestamps are available via DB
                self.maxHeight = UInt64(dbCount) + 476969 - 1  // dbCount covers Sapling activation onwards
                self.isBoostFormat = true
                self.boostStartHeight = 476969  // Sapling activation
                print("✅ BlockTimestampManager: Found \(dbCount) timestamps in HeaderStore.block_times (max height ~\(maxHeight))")
                return
            }
        } catch {
            print("⚠️ BlockTimestampManager: HeaderStore check failed: \(error.localizedDescription)")
        }

        print("⏰ BlockTimestampManager: No cached timestamps, will download from GitHub on sync")
    }

    // MARK: - Load from Boost File

    /// Load timestamps from boost file or legacy sources
    /// Priority: 1) Boost file, 2) Legacy cache, 3) Download boost file
    /// Returns: (success, maxHeight)
    func downloadIfNeeded(onProgress: ((Double, String) -> Void)? = nil) async -> (Bool, UInt64) {
        guard !isDownloading else {
            print("⚠️ BlockTimestampManager: Load already in progress")
            return (false, maxHeight)
        }

        isDownloading = true
        defer { isDownloading = false }

        // Already loaded in memory?
        if let data = timestampData, maxHeight > 0 {
            print("✅ BlockTimestampManager: Timestamps already loaded (max height \(maxHeight))")

            // CRITICAL: Even if timestamps are in memory, ensure HeaderStore.block_times is populated
            // This handles the case where timestamps were loaded in a previous session but HeaderStore wasn't synced
            await ensureHeaderStorePopulated(data: data)

            onProgress?(1.0, "Timestamps ready")
            return (true, maxHeight)
        }

        onProgress?(0.0, "Loading timestamps...")

        // 1) Try to extract from boost file
        if await CommitmentTreeUpdater.shared.hasCachedBoostFile(),
           let sectionInfo = await CommitmentTreeUpdater.shared.getSectionInfo(type: .timestamps) {
            do {
                let data = try await CommitmentTreeUpdater.shared.extractBlockTimestamps()
                try loadFromBoostSection(data, startHeight: sectionInfo.start_height, count: sectionInfo.count)
                print("✅ BlockTimestampManager: Loaded \(sectionInfo.count) timestamps from boost file")
                onProgress?(1.0, "Timestamps ready")
                return (true, maxHeight)
            } catch {
                print("⚠️ BlockTimestampManager: Failed to extract from boost: \(error)")
            }
        }

        // 2) Try legacy cache
        if FileManager.default.fileExists(atPath: cacheFilePath.path) {
            do {
                let data = try Data(contentsOf: cacheFilePath, options: .mappedIfSafe)
                timestampData = data
                maxHeight = UInt64(data.count / 4) - 1
                print("✅ BlockTimestampManager: Loaded legacy cache (max height \(maxHeight))")
                onProgress?(1.0, "Timestamps ready")
                return (true, maxHeight)
            } catch {
                print("⚠️ BlockTimestampManager: Failed to load legacy cache: \(error)")
            }
        }

        // 3) Download boost file from GitHub if nothing available
        print("⬇️ BlockTimestampManager: Downloading boost file for timestamps...")
        onProgress?(0.1, "Downloading boost file...")

        do {
            _ = try await CommitmentTreeUpdater.shared.getBestAvailableBoostFile { progress, status in
                onProgress?(0.1 + progress * 0.8, status)
            }

            if let sectionInfo = await CommitmentTreeUpdater.shared.getSectionInfo(type: .timestamps) {
                let data = try await CommitmentTreeUpdater.shared.extractBlockTimestamps()
                try loadFromBoostSection(data, startHeight: sectionInfo.start_height, count: sectionInfo.count)
                print("✅ BlockTimestampManager: Loaded \(sectionInfo.count) timestamps from downloaded boost file")
                onProgress?(1.0, "Timestamps ready")
                return (true, maxHeight)
            }
        } catch {
            print("❌ BlockTimestampManager: Failed to download boost file: \(error)")
        }

        return (timestampData != nil, maxHeight)
    }

    /// Load timestamps from boost section (4 bytes per timestamp)
    /// Also populates HeaderStore.block_times for unified timestamp storage
    private func loadFromBoostSection(_ data: Data, startHeight: UInt64, count: UInt64) throws {
        guard data.count >= Int(count) * 4 else {
            throw NSError(domain: "BlockTimestampManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid boost section size"])
        }

        // Store data and metadata in memory
        timestampData = data
        maxHeight = startHeight + count - 1
        boostStartHeight = startHeight
        isBoostFormat = true

        print("⏰ BlockTimestampManager: Loaded timestamps from boost (heights \(startHeight) to \(maxHeight))")

        // UNIFIED STORAGE: Also populate HeaderStore.block_times table
        // This ensures timestamps are available via HeaderStore.getBlockTime()
        // which is the single source of truth for the wallet
        do {
            // CRITICAL: Ensure HeaderStore is opened (creates block_times table if needed)
            try HeaderStore.shared.open()

            // Check if HeaderStore already has these timestamps to avoid duplicate work
            let existingCount = try HeaderStore.shared.getBlockTimesCount()
            if existingCount < Int(count) {
                try HeaderStore.shared.insertBlockTimesFromBoostData(data, startHeight: startHeight)
                print("✅ BlockTimestampManager: Synced \(count) timestamps to HeaderStore.block_times")
            } else {
                print("✅ BlockTimestampManager: HeaderStore.block_times already populated (\(existingCount) entries)")
            }
        } catch {
            print("⚠️ BlockTimestampManager: Failed to sync to HeaderStore: \(error.localizedDescription)")
            // Non-fatal - in-memory cache still works
        }
    }

    /// Ensure HeaderStore.block_times is populated from in-memory timestamp data
    /// Called when timestamps are already in memory but HeaderStore might be empty
    private func ensureHeaderStorePopulated(data: Data) async {
        do {
            // Ensure HeaderStore is opened (creates block_times table if needed)
            try HeaderStore.shared.open()

            let existingCount = try HeaderStore.shared.getBlockTimesCount()
            let expectedCount = data.count / 4

            if existingCount < expectedCount {
                print("⏰ BlockTimestampManager: Syncing \(expectedCount) timestamps to HeaderStore (had \(existingCount))...")
                try HeaderStore.shared.insertBlockTimesFromBoostData(data, startHeight: boostStartHeight)
                print("✅ BlockTimestampManager: Synced \(expectedCount) timestamps to HeaderStore.block_times")
            } else {
                print("✅ BlockTimestampManager: HeaderStore.block_times already populated (\(existingCount) entries)")
            }
        } catch {
            print("⚠️ BlockTimestampManager: Failed to ensure HeaderStore populated: \(error.localizedDescription)")
        }
    }

    /// Start height for boost format (Sapling activation)
    private var boostStartHeight: UInt64 = 0
    /// Whether loaded from boost format (vs legacy)
    private var isBoostFormat: Bool = false

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

        // Calculate offset based on format
        let offset: Int
        if isBoostFormat {
            // Boost format: timestamps start at boostStartHeight
            guard height >= boostStartHeight else { return nil }
            offset = Int(height - boostStartHeight) * 4
        } else {
            // Legacy format: timestamps start at height 0
            offset = Int(height) * 4
        }

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

        // Also clear in-memory boost data to force re-read from boost file
        timestampData = nil
        maxHeight = 0
        boostStartHeight = 0
        isBoostFormat = false
        print("🗑️ BlockTimestampManager: Cleared runtime cache and in-memory data")
    }

    /// Clear all timestamp data including HeaderStore block_times
    /// Call this during full repair/reset to force re-sync from boost file
    func clearAllTimestampData() {
        // Clear in-memory data
        cacheLock.lock()
        runtimeCache.removeAll()
        cacheLock.unlock()
        timestampData = nil
        maxHeight = 0
        boostStartHeight = 0
        isBoostFormat = false

        // Clear HeaderStore block_times table
        do {
            try HeaderStore.shared.clearBlockTimes()
            print("🗑️ BlockTimestampManager: Cleared HeaderStore.block_times table")
        } catch {
            print("⚠️ BlockTimestampManager: Failed to clear HeaderStore: \(error.localizedDescription)")
        }

        print("🗑️ BlockTimestampManager: Cleared ALL timestamp data")
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
