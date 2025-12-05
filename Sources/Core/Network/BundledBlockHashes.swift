// BundledBlockHashes.swift
// ZipherX
//
// Loads and provides fast lookup of block hashes from bundled file.
// Enables P2P block fetching without syncing headers from network.
//
// File format:
// - count: UInt64 LE (number of hashes)
// - start_height: UInt64 LE (first block height, e.g., Sapling activation)
// - hashes: 32 bytes each (wire format, little-endian)

import Foundation

/// Manager for bundled block hashes - enables fast P2P block fetching
/// without needing to sync headers from the network first.
final class BundledBlockHashes {

    static let shared = BundledBlockHashes()

    // MARK: - Properties

    /// In-memory hash table for O(1) lookup
    /// Key: block height, Value: block hash (32 bytes, wire format)
    private var hashTable: [UInt64: Data] = [:]

    /// Start height of bundled data (Sapling activation)
    private(set) var startHeight: UInt64 = 0

    /// End height of bundled data (bundledTreeHeight)
    private(set) var endHeight: UInt64 = 0

    /// Number of hashes loaded
    private(set) var count: UInt64 = 0

    /// Whether hashes are loaded
    private(set) var isLoaded: Bool = false

    /// Loading lock to prevent concurrent loads
    private let loadLock = NSLock()
    private var isLoading = false

    // MARK: - Initialization

    private init() {}

    // MARK: - Public Methods

    /// Load bundled block hashes from Resources
    /// Priority: 1) Bundle, 2) Documents (cached download), 3) GitHub download
    /// - Parameter onProgress: Optional progress callback (current, total)
    func loadBundledHashes(onProgress: ((UInt64, UInt64) -> Void)? = nil) async throws {
        loadLock.lock()
        if isLoaded || isLoading {
            loadLock.unlock()
            return
        }
        isLoading = true
        loadLock.unlock()

        defer {
            loadLock.lock()
            isLoading = false
            loadLock.unlock()
        }

        print("📦 Loading bundled block hashes...")
        let startTime = Date()

        // 1) Try to load from bundle first (fastest)
        if let url = Bundle.main.url(forResource: "block_hashes", withExtension: "bin") {
            let data = try Data(contentsOf: url)
            try loadFromData(data, onProgress: onProgress)
            let elapsed = Date().timeIntervalSince(startTime)
            print("✅ Loaded \(count) block hashes from bundle in \(String(format: "%.1f", elapsed))s")
            return
        }

        // 2) Try Documents cache (previously downloaded)
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let cachedURL = documentsURL.appendingPathComponent("block_hashes.bin")
        if FileManager.default.fileExists(atPath: cachedURL.path) {
            let data = try Data(contentsOf: cachedURL)
            try loadFromData(data, onProgress: onProgress)
            let elapsed = Date().timeIntervalSince(startTime)
            print("✅ Loaded \(count) block hashes from cache in \(String(format: "%.1f", elapsed))s")
            return
        }

        // 3) Download from GitHub as fallback
        try await downloadFromGitHub(onProgress: onProgress)
        let elapsed = Date().timeIntervalSince(startTime)
        print("✅ Downloaded and loaded \(count) block hashes in \(String(format: "%.1f", elapsed))s")
    }

    /// Download block hashes from GitHub (fallback if not bundled/cached)
    private func downloadFromGitHub(onProgress: ((UInt64, UInt64) -> Void)? = nil) async throws {
        let urlString = "https://raw.githubusercontent.com/VictorLux/ZipherX_Boost/main/block_hashes.bin"

        guard let url = URL(string: urlString) else {
            throw BundledHashesError.invalidURL
        }

        print("📥 Downloading block hashes from GitHub...")

        let (data, response) = try await URLSession.shared.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw BundledHashesError.downloadFailed
        }

        try loadFromData(data, onProgress: onProgress)

        // Save to Documents for future use
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let savedURL = documentsURL.appendingPathComponent("block_hashes.bin")
        try data.write(to: savedURL)
        print("💾 Saved block hashes to Documents for future use")
    }

    /// Load hashes from data
    private func loadFromData(_ data: Data, onProgress: ((UInt64, UInt64) -> Void)? = nil) throws {
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

        print("📦 Block hashes: \(count) hashes from height \(startHeight)")

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

    /// Clear loaded hashes (for testing or memory management)
    func clear() {
        loadLock.lock()
        defer { loadLock.unlock() }

        hashTable.removeAll()
        startHeight = 0
        endHeight = 0
        count = 0
        isLoaded = false
    }
}

// MARK: - Errors

enum BundledHashesError: Error, LocalizedError {
    case invalidURL
    case downloadFailed
    case invalidFormat

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid block hashes URL"
        case .downloadFailed:
            return "Failed to download block hashes"
        case .invalidFormat:
            return "Invalid block hashes file format"
        }
    }
}
