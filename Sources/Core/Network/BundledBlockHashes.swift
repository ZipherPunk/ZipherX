// BundledBlockHashes.swift
// ZipherX
//
// Loads and provides fast lookup of block hashes from boost file.
// Enables P2P block fetching without syncing headers from network.
//
// Boost file format: raw hashes, 32 bytes each (wire format, little-endian)

import Foundation

/// Manager for block hashes - enables fast P2P block fetching
/// without needing to sync headers from the network first.
final class BundledBlockHashes {

    static let shared = BundledBlockHashes()

    // MARK: - Properties

    /// In-memory hash table for O(1) lookup
    /// Key: block height, Value: block hash (32 bytes, wire format)
    private var hashTable: [UInt64: Data] = [:]

    /// Start height of bundled data (Sapling activation)
    private(set) var startHeight: UInt64 = 0

    /// End height of bundled data
    private(set) var endHeight: UInt64 = 0

    /// Number of hashes loaded
    private(set) var count: UInt64 = 0

    /// Whether hashes are loaded
    private(set) var isLoaded: Bool = false

    /// Loading state
    private var isLoading = false

    // MARK: - Initialization

    private init() {}

    // MARK: - Public Methods

    /// Load block hashes from boost file
    /// Priority: 1) Boost file (extracted from GitHub boost), 2) Legacy bundle, 3) Legacy cache, 4) Download
    /// - Parameter onProgress: Optional progress callback (current, total)
    func loadBundledHashes(onProgress: ((UInt64, UInt64) -> Void)? = nil) async throws {
        // Check loading state
        if isLoaded || isLoading {
            return
        }
        isLoading = true

        defer {
            isLoading = false
        }

        print("📦 Loading block hashes...")
        let startTime = Date()

        // 1) Try to extract from boost file (new format)
        if await CommitmentTreeUpdater.shared.hasCachedBoostFile(),
           let sectionInfo = await CommitmentTreeUpdater.shared.getSectionInfo(type: .blockHashes) {
            do {
                let hashData = try await CommitmentTreeUpdater.shared.extractBlockHashes()
                try loadFromBoostSection(hashData, startHeight: sectionInfo.start_height, count: sectionInfo.count, onProgress: onProgress)
                let elapsed = Date().timeIntervalSince(startTime)
                print("✅ Loaded \(count) block hashes from boost file in \(String(format: "%.1f", elapsed))s")
                return
            } catch {
                print("⚠️ Failed to extract block hashes from boost file: \(error)")
            }
        }

        // 2) Try to load from legacy bundle (old format - will be removed in future)
        if let url = Bundle.main.url(forResource: "block_hashes", withExtension: "bin") {
            let data = try Data(contentsOf: url)
            try loadFromLegacyData(data, onProgress: onProgress)
            let elapsed = Date().timeIntervalSince(startTime)
            print("✅ Loaded \(count) block hashes from legacy bundle in \(String(format: "%.1f", elapsed))s")
            return
        }

        // 3) Try app data cache (previously downloaded legacy format)
        let cachedURL = AppDirectories.blockHashes
        if FileManager.default.fileExists(atPath: cachedURL.path) {
            let data = try Data(contentsOf: cachedURL)
            try loadFromLegacyData(data, onProgress: onProgress)
            let elapsed = Date().timeIntervalSince(startTime)
            print("✅ Loaded \(count) block hashes from legacy cache in \(String(format: "%.1f", elapsed))s")
            return
        }

        // 4) Download boost file from GitHub if nothing available
        print("📥 No block hashes available, downloading boost file...")
        _ = try await CommitmentTreeUpdater.shared.getBestAvailableBoostFile(onProgress: nil)

        if let sectionInfo = await CommitmentTreeUpdater.shared.getSectionInfo(type: .blockHashes) {
            let hashData = try await CommitmentTreeUpdater.shared.extractBlockHashes()
            try loadFromBoostSection(hashData, startHeight: sectionInfo.start_height, count: sectionInfo.count, onProgress: onProgress)
            let elapsed = Date().timeIntervalSince(startTime)
            print("✅ Downloaded and loaded \(count) block hashes in \(String(format: "%.1f", elapsed))s")
        }
    }

    /// Load hashes from boost file section (raw hashes, 32 bytes each)
    private func loadFromBoostSection(_ data: Data, startHeight: UInt64, count: UInt64, onProgress: ((UInt64, UInt64) -> Void)? = nil) throws {
        // Validate data size (32 bytes per hash)
        let expectedSize = Int(count) * 32
        guard data.count >= expectedSize else {
            throw BundledHashesError.invalidFormat
        }

        print("📦 Block hashes: \(count) hashes from height \(startHeight)")

        // Build hash table
        var table: [UInt64: Data] = [:]
        table.reserveCapacity(Int(count))

        let progressInterval = count / 100  // Update progress every 1%
        var offset = 0

        for i in 0..<count {
            let height = startHeight + i
            let hash = data.subdata(in: offset..<(offset + 32))
            table[height] = hash
            offset += 32

            // Progress callback
            if progressInterval > 0 && i % progressInterval == 0 {
                onProgress?(i, count)
            }
        }

        // Update state
        self.hashTable = table
        self.startHeight = startHeight
        self.endHeight = startHeight + count - 1
        self.count = count
        self.isLoaded = true

        onProgress?(count, count)
    }

    /// Load hashes from legacy data format (with count + start_height header)
    private func loadFromLegacyData(_ data: Data, onProgress: ((UInt64, UInt64) -> Void)? = nil) throws {
        guard data.count >= 16 else {
            throw BundledHashesError.invalidFormat
        }

        // Read header
        let count = data.withUnsafeBytes { ptr -> UInt64 in
            ptr.load(fromByteOffset: 0, as: UInt64.self)
        }

        let startHeight = data.withUnsafeBytes { ptr -> UInt64 in
            ptr.load(fromByteOffset: 8, as: UInt64.self)
        }

        // Validate data size
        let expectedSize = 16 + Int(count) * 32
        guard data.count >= expectedSize else {
            throw BundledHashesError.invalidFormat
        }

        print("📦 Block hashes (legacy): \(count) hashes from height \(startHeight)")

        // Build hash table
        var table: [UInt64: Data] = [:]
        table.reserveCapacity(Int(count))

        let progressInterval = count / 100  // Update progress every 1%
        var offset = 16

        for i in 0..<count {
            let height = startHeight + i
            let hash = data.subdata(in: offset..<(offset + 32))
            table[height] = hash
            offset += 32

            // Progress callback
            if progressInterval > 0 && i % progressInterval == 0 {
                onProgress?(i, count)
            }
        }

        // Update state
        self.hashTable = table
        self.startHeight = startHeight
        self.endHeight = startHeight + count - 1
        self.count = count
        self.isLoaded = true

        onProgress?(count, count)
    }

    /// Get block hash for a specific height
    /// - Parameter height: Block height
    /// - Returns: Block hash in wire format (32 bytes), or nil if not available
    func getBlockHash(at height: UInt64) -> Data? {
        return hashTable[height]
    }

    /// Check if a height is covered by bundled hashes
    func contains(height: UInt64) -> Bool {
        return hashTable[height] != nil
    }

    /// Get block hashes for a range of heights
    /// - Parameters:
    ///   - startHeight: Starting height (inclusive)
    ///   - count: Number of hashes to get
    /// - Returns: Array of (height, hash) tuples
    func getBlockHashes(from startHeight: UInt64, count: Int) -> [(UInt64, Data)] {
        var result: [(UInt64, Data)] = []
        result.reserveCapacity(count)

        for i in 0..<count {
            let height = startHeight + UInt64(i)
            if let hash = hashTable[height] {
                result.append((height, hash))
            }
        }

        return result
    }

    /// Clear loaded hashes (for memory management)
    func clear() {
        hashTable.removeAll()
        startHeight = 0
        endHeight = 0
        count = 0
        isLoaded = false
    }
}

// MARK: - Errors

enum BundledHashesError: Error, LocalizedError {
    case invalidFormat
    case downloadFailed

    var errorDescription: String? {
        switch self {
        case .invalidFormat:
            return "Invalid block hashes file format"
        case .downloadFailed:
            return "Failed to download block hashes"
        }
    }
}
