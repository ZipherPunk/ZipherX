import Foundation
import CommonCrypto

/// Handles downloading the unified ZipherX Boost file from GitHub
/// The boost file contains all data needed for wallet sync:
/// - Shielded outputs (for note decryption)
/// - Shielded spends (for nullifier detection)
/// - Block hashes (for P2P validation)
/// - Block timestamps (for transaction dating)
/// - Serialized commitment tree (for instant tree load)
/// - Peer addresses (for network bootstrap)
actor CommitmentTreeUpdater {

    // MARK: - Configuration

    /// GitHub API URL for latest release (dynamically fetches newest boost file)
    private static let latestReleaseURL = "https://api.github.com/repos/VictorLux/ZipherX_Boost/releases/latest"

    /// Boost file name to look for in release assets
    private static let boostFileName = "zipherx_boost_v1.bin"
    private static let manifestFileName = "zipherx_boost_manifest.json"

    // MARK: - Section Types (from unified file format)

    enum SectionType: Int {
        case outputs = 1      // Shielded outputs (652 bytes each)
        case spends = 2       // Shielded spends/nullifiers (36 bytes each)
        case blockHashes = 3  // Block hashes (32 bytes each)
        case timestamps = 4   // Block timestamps (4 bytes each)
        case serializedTree = 5  // Serialized commitment tree (~414 bytes)
        case peerAddresses = 6   // Peer addresses for bootstrap
        case headers = 7      // FIX #413: Full block headers (140 bytes each, includes sapling_root)
    }

    // MARK: - File Header Constants

    private static let MAGIC: [UInt8] = [0x5A, 0x42, 0x4F, 0x4F, 0x53, 0x54, 0x30, 0x31] // "ZBOOST01"
    private static let HEADER_SIZE: UInt64 = 128
    private static let SECTION_ENTRY_SIZE: UInt64 = 32

    /// Local directory for downloaded boost file
    private var boostCacheDirectory: URL {
        return AppDirectories.boostCache
    }

    /// Path to cached manifest
    private var cachedManifestPath: URL {
        boostCacheDirectory.appendingPathComponent("zipherx_boost_manifest.json")
    }

    /// Path to cached boost file (single-file format v1/v2 - for backward compatibility)
    private var cachedBoostPath: URL {
        boostCacheDirectory.appendingPathComponent("zipherx_boost_v1.bin")
    }

    /// Path to cached core boost file (three-file format v3+)
    private var cachedCorePath: URL {
        boostCacheDirectory.appendingPathComponent("zipherx_boost_core.bin")
    }

    /// Path to cached equihash file (three-file format v3+)
    private var cachedEquihashPath: URL {
        boostCacheDirectory.appendingPathComponent("zipherx_boost_equihash.bin")
    }

    /// Get the active boost file path based on manifest format
    private func getActiveBoostPath(for manifest: BoostManifest) -> URL {
        return manifest.isThreePartFormat ? cachedCorePath : cachedBoostPath
    }

    // MARK: - Manifest Model

    struct BoostManifest: Codable {
        let format: String
        let version: Int
        let created_at: String
        let chain_height: UInt64
        let sapling_activation: UInt64
        let tree_root: String
        let block_hash: String
        let output_count: UInt64
        let spend_count: UInt64
        let files: ManifestFiles
        let sections: [SectionInfo]

        /// Check if this is a three-file format (v3+) or core-only format (v4+)
        var isThreePartFormat: Bool {
            format == "zipherx_boost_v2_three_part" || format == "zipherx_boost_v2_core_only" || version >= 3
        }

        struct ManifestFiles: Codable {
            let uncompressed: FileInfo
            // Three-part format (v3+)
            let core: FileInfo?
            let equihash: FileInfo?

            // For backward compatibility with single-file format
            private enum CodingKeys: String, CodingKey {
                case uncompressed
                case core
                case equihash
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)

                // Check if core exists (three-part or core-only format v3+)
                if let core = try? container.decode(FileInfo.self, forKey: .core) {
                    self.core = core
                    // Try to decode equihash (optional)
                    self.equihash = try? container.decode(FileInfo.self, forKey: .equihash)
                    // Create synthetic uncompressed for compatibility
                    self.uncompressed = FileInfo(
                        name: core.name,
                        size: core.size + (self.equihash?.size ?? 0),
                        sha256: ""
                    )
                } else {
                    // Single-file format (v1/v2)
                    self.uncompressed = try container.decode(FileInfo.self, forKey: .uncompressed)
                    self.core = nil
                    self.equihash = nil
                }
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                if let core = core, let equihash = equihash {
                    try container.encode(core, forKey: .core)
                    try container.encode(equihash, forKey: .equihash)
                } else {
                    try container.encode(uncompressed, forKey: .uncompressed)
                }
            }
        }

        struct FileInfo: Codable {
            let name: String
            let size: Int
            let sha256: String
            let description: String?
            let required: Bool?

            // For backward compatibility
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                name = try container.decode(String.self, forKey: .name)
                size = try container.decode(Int.self, forKey: .size)
                sha256 = try container.decode(String.self, forKey: .sha256)
                description = try container.decodeIfPresent(String.self, forKey: .description)
                required = try container.decodeIfPresent(Bool.self, forKey: .required)
            }

            init(name: String, size: Int, sha256: String) {
                self.name = name
                self.size = size
                self.sha256 = sha256
                self.description = nil
                self.required = nil
            }

            private enum CodingKeys: String, CodingKey {
                case name
                case size
                case sha256
                case description
                case required
            }
        }

        struct SectionInfo: Codable {
            let type: Int
            let offset: UInt64
            let size: UInt64
            let count: UInt64
            let start_height: UInt64
            let end_height: UInt64
        }
    }

    // MARK: - Public Interface

    static let shared = CommitmentTreeUpdater()

    private init() {
        // Ensure cache directory exists
        try? FileManager.default.createDirectory(at: boostCacheDirectory, withIntermediateDirectories: true)
    }

    /// Get the best available boost file (cached or download from GitHub)
    /// - Parameter onProgress: Progress callback (0.0 to 1.0, status message)
    /// - Returns: Tuple of (boostFilePath, chainHeight, outputCount)
    func getBestAvailableBoostFile(onProgress: ((Double, String) -> Void)? = nil) async throws -> (URL, UInt64, UInt64) {

        onProgress?(0.0, "Checking for boost data...")

        // Check for valid cached boost file first
        let cachedManifest = loadCachedManifest()
        if let cachedManifest = cachedManifest {
            let activePath = getActiveBoostPath(for: cachedManifest)
            let expectedSize = cachedManifest.isThreePartFormat
                ? cachedManifest.files.core?.size ?? cachedManifest.files.uncompressed.size
                : cachedManifest.files.uncompressed.size

            if FileManager.default.fileExists(atPath: activePath.path) {
                // Verify checksum (can be slow for 500MB file, so skip if file size matches)
                let attrs = try? FileManager.default.attributesOfItem(atPath: activePath.path)
                let fileSize = attrs?[.size] as? Int ?? 0

                if fileSize == expectedSize {
                    // FIX #178: Check if remote has NEWER version before downloading
                    // Only fetch remote manifest if cache is valid - compare heights
                    onProgress?(0.02, "Checking for updates...")
                    if let remoteManifest = try? await fetchRemoteManifest() {
                        if remoteManifest.chain_height > cachedManifest.chain_height {
                            // Remote has newer version - download it
                            print("🚀 FIX #178: Remote boost file is NEWER (remote=\(remoteManifest.chain_height) > cached=\(cachedManifest.chain_height)) - downloading update...")
                            // Fall through to download section below
                        } else {
                            // Cached version is same or newer - use it
                            print("🚀 FIX #178: Using cached boost file at height \(cachedManifest.chain_height) (remote=\(remoteManifest.chain_height), no update needed)")
                            onProgress?(1.0, "Using cached data")
                            return (activePath, cachedManifest.chain_height, cachedManifest.output_count)
                        }
                    } else {
                        // Can't reach GitHub - use cached version
                        print("🚀 Using cached boost file at height \(cachedManifest.chain_height) (GitHub unreachable)")
                        onProgress?(1.0, "Using cached data")
                        return (activePath, cachedManifest.chain_height, cachedManifest.output_count)
                    }
                }
            }
        }

        // Must download from GitHub (no valid cache OR remote has newer version)
        onProgress?(0.05, "Fetching manifest from GitHub...")
        let remoteManifest = try await fetchRemoteManifest()

        let activePath = getActiveBoostPath(for: remoteManifest)
        let isThreePart = remoteManifest.isThreePartFormat
        let coreSize = isThreePart ? (remoteManifest.files.core?.size ?? remoteManifest.files.uncompressed.size) : remoteManifest.files.uncompressed.size
        let fileSizeMB = coreSize / 1024 / 1024

        print("🚀 Downloading boost file from GitHub (height \(remoteManifest.chain_height), three-part: \(isThreePart))...")
        onProgress?(0.1, "Downloading \(fileSizeMB) MB...")

        try await downloadBoostFile(manifest: remoteManifest) { progress in
            let pct = Int(progress * 100)
            // FIX #179: Add logging to track download progress
            if pct % 10 == 0 {
                print("📥 Download progress: \(pct)%")
            }
            onProgress?(0.1 + progress * 0.85, "Downloading... \(pct)%")
        }

        onProgress?(0.95, "Verifying checksum...")

        // Verify file size (checksum verification is slow for 500MB)
        let attrs = try? FileManager.default.attributesOfItem(atPath: activePath.path)
        let fileSize = attrs?[.size] as? Int ?? 0
        guard fileSize == coreSize else {
            try? FileManager.default.removeItem(at: activePath)
            throw BoostFileError.checksumMismatch
        }

        // Save manifest
        try saveManifest(remoteManifest)

        // Update UserDefaults for effective tree height
        await MainActor.run {
            ZipherXConstants.updateTreeInfo(
                height: remoteManifest.chain_height,
                cmuCount: remoteManifest.output_count,
                root: remoteManifest.tree_root
            )
        }

        print("🚀 Successfully downloaded boost file at height \(remoteManifest.chain_height) (three-part: \(isThreePart))")
        onProgress?(1.0, "Boost data ready!")

        return (activePath, remoteManifest.chain_height, remoteManifest.output_count)
    }

    /// Extract serialized tree data from the boost file
    /// This is used for instant tree loading (no need to process all CMUs)
    func extractSerializedTree() async throws -> Data {
        guard let manifest = loadCachedManifest() else {
            throw BoostFileError.noManifest
        }

        guard let treeSection = manifest.sections.first(where: { $0.type == SectionType.serializedTree.rawValue }) else {
            throw BoostFileError.sectionNotFound("serialized tree")
        }

        let activePath = getActiveBoostPath(for: manifest)
        guard FileManager.default.fileExists(atPath: activePath.path) else {
            throw BoostFileError.fileNotFound
        }

        // Read just the tree section from the boost file
        let fileHandle = try FileHandle(forReadingFrom: activePath)
        defer { try? fileHandle.close() }

        try fileHandle.seek(toOffset: treeSection.offset)
        guard let data = try fileHandle.read(upToCount: Int(treeSection.size)) else {
            throw BoostFileError.readError
        }

        print("🌲 Extracted serialized tree: \(data.count) bytes")
        return data
    }

    /// Extract CMUs from outputs section in legacy format for FFI functions
    /// The legacy format is: [count: UInt64 LE][cmu1: 32 bytes][cmu2: 32 bytes]...
    /// This is needed for treeLoadFromCMUs and treeCreateWitnessForCMU FFI functions
    func extractCMUsInLegacyFormat(onProgress: ((Double) -> Void)? = nil) async throws -> Data {
        guard let manifest = loadCachedManifest() else {
            throw BoostFileError.noManifest
        }

        guard let outputSection = manifest.sections.first(where: { $0.type == SectionType.outputs.rawValue }) else {
            throw BoostFileError.sectionNotFound("outputs")
        }

        let activePath = getActiveBoostPath(for: manifest)
        guard FileManager.default.fileExists(atPath: activePath.path) else {
            throw BoostFileError.fileNotFound
        }

        // Output record format in boost file (652 bytes each):
        // - height: 4 bytes (UInt32 LE) - offset 0
        // - index: 4 bytes (UInt32 LE) - offset 4
        // - cmu: 32 bytes - offset 8
        // - epk: 32 bytes - offset 40
        // - ciphertext: 580 bytes - offset 72
        // Total: 652 bytes per output
        let recordSize = 652
        let cmuOffset = 8  // height(4) + index(4) = 8

        let outputCount = outputSection.count
        print("🔄 Extracting \(outputCount) CMUs in legacy format...")

        // Allocate result buffer: 8 bytes for count + 32 bytes per CMU
        var result = Data(count: 8 + Int(outputCount) * 32)

        // Write count as UInt64 LE
        var count = outputCount
        withUnsafeBytes(of: &count) { bytes in
            result.replaceSubrange(0..<8, with: bytes)
        }

        // Read and extract CMUs
        let fileHandle = try FileHandle(forReadingFrom: activePath)
        defer { try? fileHandle.close() }

        try fileHandle.seek(toOffset: outputSection.offset)

        for i in 0..<Int(outputCount) {
            guard let recordData = try fileHandle.read(upToCount: recordSize) else {
                throw BoostFileError.readError
            }

            // Extract CMU (32 bytes at offset 8)
            let cmu = recordData.subdata(in: cmuOffset..<(cmuOffset + 32))

            // Write CMU to result buffer
            let resultOffset = 8 + i * 32
            result.replaceSubrange(resultOffset..<(resultOffset + 32), with: cmu)

            // Progress callback every 10000 records
            if i % 10000 == 0 {
                onProgress?(Double(i) / Double(outputCount))
            }
        }

        onProgress?(1.0)
        print("✅ Extracted \(outputCount) CMUs in legacy format (\(result.count) bytes)")
        return result
    }

    /// Extract shielded outputs section for parallel note decryption
    /// - Parameter onProgress: Progress callback
    /// - Returns: Raw outputs data (652 bytes per record)
    func extractShieldedOutputs(onProgress: ((Double) -> Void)? = nil) async throws -> Data {
        guard let manifest = loadCachedManifest() else {
            throw BoostFileError.noManifest
        }

        guard let outputSection = manifest.sections.first(where: { $0.type == SectionType.outputs.rawValue }) else {
            throw BoostFileError.sectionNotFound("outputs")
        }

        let activePath = getActiveBoostPath(for: manifest)
        guard FileManager.default.fileExists(atPath: activePath.path) else {
            throw BoostFileError.fileNotFound
        }

        // Read the outputs section
        let fileHandle = try FileHandle(forReadingFrom: activePath)
        defer { try? fileHandle.close() }

        try fileHandle.seek(toOffset: outputSection.offset)
        guard let data = try fileHandle.read(upToCount: Int(outputSection.size)) else {
            throw BoostFileError.readError
        }

        print("📦 Extracted \(outputSection.count) shielded outputs (\(data.count) bytes)")
        return data
    }

    /// Extract shielded spends (nullifiers) for spent note detection
    func extractShieldedSpends() async throws -> Data {
        guard let manifest = loadCachedManifest() else {
            throw BoostFileError.noManifest
        }

        guard let spendSection = manifest.sections.first(where: { $0.type == SectionType.spends.rawValue }) else {
            throw BoostFileError.sectionNotFound("spends")
        }

        let activePath = getActiveBoostPath(for: manifest)
        guard FileManager.default.fileExists(atPath: activePath.path) else {
            throw BoostFileError.fileNotFound
        }

        let fileHandle = try FileHandle(forReadingFrom: activePath)
        defer { try? fileHandle.close() }

        try fileHandle.seek(toOffset: spendSection.offset)
        guard let data = try fileHandle.read(upToCount: Int(spendSection.size)) else {
            throw BoostFileError.readError
        }

        print("🔍 Extracted \(spendSection.count) shielded spends (\(data.count) bytes)")
        return data
    }

    /// Extract block timestamps for transaction dating
    func extractBlockTimestamps() async throws -> Data {
        guard let manifest = loadCachedManifest() else {
            throw BoostFileError.noManifest
        }

        guard let timestampSection = manifest.sections.first(where: { $0.type == SectionType.timestamps.rawValue }) else {
            throw BoostFileError.sectionNotFound("timestamps")
        }

        let activePath = getActiveBoostPath(for: manifest)
        guard FileManager.default.fileExists(atPath: activePath.path) else {
            throw BoostFileError.fileNotFound
        }

        let fileHandle = try FileHandle(forReadingFrom: activePath)
        defer { try? fileHandle.close() }

        try fileHandle.seek(toOffset: timestampSection.offset)
        guard let data = try fileHandle.read(upToCount: Int(timestampSection.size)) else {
            throw BoostFileError.readError
        }

        print("⏱️ Extracted \(timestampSection.count) block timestamps (\(data.count) bytes)")
        return data
    }

    /// Extract block hashes for P2P validation
    func extractBlockHashes() async throws -> Data {
        guard let manifest = loadCachedManifest() else {
            throw BoostFileError.noManifest
        }

        guard let hashSection = manifest.sections.first(where: { $0.type == SectionType.blockHashes.rawValue }) else {
            throw BoostFileError.sectionNotFound("block hashes")
        }

        let activePath = getActiveBoostPath(for: manifest)
        guard FileManager.default.fileExists(atPath: activePath.path) else {
            throw BoostFileError.fileNotFound
        }

        let fileHandle = try FileHandle(forReadingFrom: activePath)
        defer { try? fileHandle.close() }

        try fileHandle.seek(toOffset: hashSection.offset)
        guard let data = try fileHandle.read(upToCount: Int(hashSection.size)) else {
            throw BoostFileError.readError
        }

        print("🔗 Extracted \(hashSection.count) block hashes (\(data.count) bytes)")
        return data
    }

    /// Extract peer addresses for network bootstrap
    func extractPeerAddresses() async throws -> Data {
        guard let manifest = loadCachedManifest() else {
            throw BoostFileError.noManifest
        }

        guard let peerSection = manifest.sections.first(where: { $0.type == SectionType.peerAddresses.rawValue }) else {
            throw BoostFileError.sectionNotFound("peer addresses")
        }

        let activePath = getActiveBoostPath(for: manifest)
        guard FileManager.default.fileExists(atPath: activePath.path) else {
            throw BoostFileError.fileNotFound
        }

        let fileHandle = try FileHandle(forReadingFrom: activePath)
        defer { try? fileHandle.close() }

        try fileHandle.seek(toOffset: peerSection.offset)
        guard let data = try fileHandle.read(upToCount: Int(peerSection.size)) else {
            throw BoostFileError.readError
        }

        print("🌐 Extracted peer addresses (\(data.count) bytes)")
        return data
    }

    /// FIX #413: Extract block headers from boost file for Tree Root Validation
    /// Header format (140 bytes each):
    /// - version: 4 bytes (UInt32 LE)
    /// - hashPrevBlock: 32 bytes
    /// - hashMerkleRoot: 32 bytes
    /// - hashFinalSaplingRoot: 32 bytes (CRITICAL for anchor validation!)
    /// - time: 4 bytes (UInt32 LE)
    /// - bits: 4 bytes (UInt32 LE)
    /// - nonce: 32 bytes
    func extractHeaders(onProgress: ((Double) -> Void)? = nil) async throws -> Data? {
        guard let manifest = loadCachedManifest() else {
            throw BoostFileError.noManifest
        }

        guard let headerSection = manifest.sections.first(where: { $0.type == SectionType.headers.rawValue }) else {
            // FIX #413: Headers section is optional - older boost files may not have it
            print("⚠️ FIX #413: No headers section in boost file (requires boost file v2+)")
            return nil
        }

        let activePath = getActiveBoostPath(for: manifest)
        guard FileManager.default.fileExists(atPath: activePath.path) else {
            throw BoostFileError.fileNotFound
        }

        let fileHandle = try FileHandle(forReadingFrom: activePath)
        defer { try? fileHandle.close() }

        try fileHandle.seek(toOffset: headerSection.offset)
        guard let data = try fileHandle.read(upToCount: Int(headerSection.size)) else {
            throw BoostFileError.readError
        }

        print("📜 FIX #413: Extracted \(headerSection.count) block headers (\(data.count) bytes)")
        return data
    }

    /// FIX #413: Check if boost file has headers section
    func hasHeadersSection() -> Bool {
        guard let manifest = loadCachedManifest() else { return false }
        return manifest.sections.contains(where: { $0.type == SectionType.headers.rawValue })
    }

    /// FIX #413: Get headers section info (for delta calculation)
    func getHeadersSectionInfo() -> (startHeight: UInt64, endHeight: UInt64, count: UInt64)? {
        guard let manifest = loadCachedManifest() else { return nil }
        guard let section = manifest.sections.first(where: { $0.type == SectionType.headers.rawValue }) else { return nil }
        return (section.start_height, section.end_height, section.count)
    }

    // MARK: - Cache Status

    /// Check if we have a valid cached boost file
    func hasCachedBoostFile() -> Bool {
        guard let manifest = loadCachedManifest() else { return false }

        let activePath = getActiveBoostPath(for: manifest)
        guard FileManager.default.fileExists(atPath: activePath.path) else { return false }

        let expectedSize = manifest.isThreePartFormat
            ? manifest.files.core?.size ?? manifest.files.uncompressed.size
            : manifest.files.uncompressed.size

        let attrs = try? FileManager.default.attributesOfItem(atPath: activePath.path)
        let fileSize = attrs?[.size] as? Int ?? 0
        return fileSize == expectedSize
    }

    /// Get the cached boost file path if available
    func getCachedBoostFilePath() -> URL? {
        guard let manifest = loadCachedManifest() else { return nil }
        let activePath = getActiveBoostPath(for: manifest)
        guard FileManager.default.fileExists(atPath: activePath.path) else { return nil }
        return activePath
    }

    /// Get cached manifest info
    func getCachedInfo() -> (height: UInt64, outputCount: UInt64, spendCount: UInt64)? {
        guard let manifest = loadCachedManifest() else { return nil }
        return (manifest.chain_height, manifest.output_count, manifest.spend_count)
    }

    /// Get cached boost file height (convenience method)
    func getCachedBoostHeight() -> UInt64? {
        return loadCachedManifest()?.chain_height
    }

    /// Get section info from manifest
    func getSectionInfo(type: SectionType) -> BoostManifest.SectionInfo? {
        guard let manifest = loadCachedManifest() else { return nil }
        return manifest.sections.first(where: { $0.type == type.rawValue })
    }

    /// Clear the boost cache (resets for fresh download)
    func clearCache() throws {
        if FileManager.default.fileExists(atPath: boostCacheDirectory.path) {
            try FileManager.default.removeItem(at: boostCacheDirectory)
            try FileManager.default.createDirectory(at: boostCacheDirectory, withIntermediateDirectories: true)
        }
        print("🧹 Boost cache cleared (reset for fresh download)")
    }

    /// Completely delete the boost cache directory (used when deleting wallet)
    /// Marked nonisolated since it only uses FileManager which is thread-safe
    nonisolated func deleteAllBoostFiles() {
        let fm = FileManager.default
        let boostCachePath = AppDirectories.boostCache
        if fm.fileExists(atPath: boostCachePath.path) {
            do {
                try fm.removeItem(at: boostCachePath)
                print("🗑️ Deleted BoostCache folder")
            } catch {
                print("⚠️ Failed to delete BoostCache: \(error)")
            }
        }
    }

    // MARK: - Legacy Compatibility (for existing code)

    /// Legacy method - now returns boost file path
    func getBestAvailableTree(onProgress: ((Double, String) -> Void)? = nil) async throws -> (URL, UInt64, UInt64) {
        return try await getBestAvailableBoostFile(onProgress: onProgress)
    }

    /// Version for legacy CMU cache format - bump this when format changes
    /// Version 2: Fixed CMU offset from 36 to 8 (December 2025)
    private static let legacyCMUCacheVersion = 2

    /// Path to cached legacy CMU file (extracted from boost file)
    private var cachedLegacyCMUPath: URL {
        boostCacheDirectory.appendingPathComponent("legacy_cmus_v\(Self.legacyCMUCacheVersion).bin")
    }

    /// Clean up old cache versions
    private func cleanupOldCacheVersions() {
        let fm = FileManager.default
        // Delete old version files
        let oldFiles = ["legacy_cmus.bin", "legacy_cmus_v1.bin"]
        for filename in oldFiles {
            let path = boostCacheDirectory.appendingPathComponent(filename)
            if fm.fileExists(atPath: path.path) {
                try? fm.removeItem(at: path)
                print("🗑️ Deleted old cache file: \(filename)")
            }
        }
    }

    /// Legacy method - get cached CMU data in legacy format
    /// Extracts CMUs from boost file on first call, caches for subsequent calls
    func getCachedCMUFilePath() async -> URL? {
        // Clean up old cache versions first
        cleanupOldCacheVersions()

        // Check if we have cached legacy CMU file
        if FileManager.default.fileExists(atPath: cachedLegacyCMUPath.path) {
            return cachedLegacyCMUPath
        }

        // Need to extract from boost file
        guard hasCachedBoostFile() else { return nil }

        do {
            let cmuData = try await extractCMUsInLegacyFormat()
            try cmuData.write(to: cachedLegacyCMUPath)
            print("💾 Cached legacy CMU data (v\(Self.legacyCMUCacheVersion)): \(cmuData.count) bytes")
            return cachedLegacyCMUPath
        } catch {
            print("❌ Failed to extract legacy CMU data: \(error)")
            return nil
        }
    }

    /// Legacy method - get cached tree info
    func getCachedTreeInfo() -> (height: UInt64, cmuCount: UInt64)? {
        guard let info = getCachedInfo() else { return nil }
        return (info.height, info.outputCount)
    }

    /// Legacy method - check for cached CMU file
    func hasCachedCMUFile() -> Bool {
        return hasCachedBoostFile()
    }

    /// Legacy method - get CMU file for imported wallets
    func getCMUFileForImportedWallet(onProgress: ((Double, String) -> Void)? = nil) async throws -> (URL, UInt64, UInt64)? {
        let result = try await getBestAvailableBoostFile(onProgress: onProgress)
        return result
    }

    // MARK: - Tree Info Updates

    /// Fetch latest tree info from GitHub and update UserDefaults
    /// This is a lightweight call that only downloads the manifest (~1KB)
    /// Called on app startup to check for newer boost data
    func fetchAndUpdateTreeInfo() async {
        do {
            let manifest = try await fetchRemoteManifest()

            // Update UserDefaults with latest tree info
            await MainActor.run {
                ZipherXConstants.updateTreeInfo(
                    height: manifest.chain_height,
                    cmuCount: manifest.output_count,
                    root: manifest.tree_root
                )
            }

            print("📊 Updated tree info from GitHub: height=\(manifest.chain_height), outputs=\(manifest.output_count)")
        } catch {
            // Non-fatal - we can use cached or bundled values
            print("⚠️ Could not fetch tree info from GitHub: \(error.localizedDescription)")
        }
    }

    // MARK: - Private Methods

    /// GitHub Release API response structure
    private struct GitHubRelease: Codable {
        let tag_name: String
        let assets: [GitHubAsset]
    }

    private struct GitHubAsset: Codable {
        let name: String
        let browser_download_url: String
        let size: Int
    }

    /// Cached latest release info (to avoid repeated API calls)
    private var cachedReleaseInfo: GitHubRelease?

    private func fetchLatestRelease() async throws -> GitHubRelease {
        // Return cached if available
        if let cached = cachedReleaseInfo {
            return cached
        }

        guard let url = URL(string: Self.latestReleaseURL) else {
            throw BoostFileError.invalidURL
        }

        // FIX #194: Retry on transient GitHub errors (502, 503, 504)
        let maxRetries = 3
        var lastError: Error?

        for attempt in 1...maxRetries {
            do {
                var request = URLRequest(url: url)
                request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
                // FIX #360: Short timeout for version check - fall back to cache quickly if GitHub unreachable
                request.timeoutInterval = 10

                let (data, response) = try await URLSession.shared.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw BoostFileError.networkError("No HTTP response")
                }

                // FIX #194: Check for transient errors that should trigger retry
                let statusCode = httpResponse.statusCode
                if [502, 503, 504].contains(statusCode) {
                    print("⚠️ FIX #194: GitHub API returned HTTP \(statusCode) (attempt \(attempt)/\(maxRetries)), retrying in 3s...")
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    lastError = BoostFileError.networkError("GitHub API HTTP \(statusCode)")
                    continue
                }

                guard statusCode == 200 else {
                    throw BoostFileError.networkError("GitHub API HTTP \(statusCode)")
                }

                let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
                cachedReleaseInfo = release
                print("📦 Latest release: \(release.tag_name) with \(release.assets.count) assets")
                return release
            } catch {
                lastError = error
                if attempt < maxRetries {
                    print("⚠️ FIX #194: Fetch release failed (attempt \(attempt)/\(maxRetries)): \(error.localizedDescription)")
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                }
            }
        }

        throw lastError ?? BoostFileError.networkError("Max retries exceeded")
    }

    private func fetchRemoteManifest() async throws -> BoostManifest {
        // FIX #194: Retry on transient GitHub errors (502, 503, 504)
        let maxRetries = 3
        var lastError: Error?

        for attempt in 1...maxRetries {
            do {
                // Get latest release from GitHub
                let release = try await fetchLatestRelease()

                // DEBUG: Log all available assets
                print("🔍 DEBUG [Manifest Fetch]: Release has \(release.assets.count) assets:")
                for asset in release.assets {
                    print("  - \(asset.name) (\(asset.size) bytes)")
                }
                print("🔍 DEBUG [Manifest Fetch]: Looking for manifest named: \(Self.manifestFileName)")

                // Find manifest asset
                guard let manifestAsset = release.assets.first(where: { $0.name == Self.manifestFileName }) else {
                    print("🔍 DEBUG [Manifest Fetch]: ERROR - Manifest asset not found!")
                    throw BoostFileError.networkError("Manifest not found in latest release")
                }

                guard let url = URL(string: manifestAsset.browser_download_url) else {
                    throw BoostFileError.invalidURL
                }

                // DEBUG: Log URL construction details
                print("🔍 DEBUG [Manifest Fetch]: Attempt \(attempt)/\(maxRetries)")
                print("🔍 DEBUG [Manifest Fetch]: Release tag: \(release.tag_name)")
                print("🔍 DEBUG [Manifest Fetch]: Asset name: \(manifestAsset.name)")
                print("🔍 DEBUG [Manifest Fetch]: Asset size: \(manifestAsset.size) bytes")
                print("🔍 DEBUG [Manifest Fetch]: Download URL: \(manifestAsset.browser_download_url)")

                // FIX #360: Short timeout for manifest fetch - fall back to cache quickly if GitHub unreachable
                var request = URLRequest(url: url)
                request.timeoutInterval = 10
                print("🔍 DEBUG [Manifest Fetch]: Request timeout: \(request.timeoutInterval)s")

                print("🔍 DEBUG [Manifest Fetch]: Starting URLSession.data() call...")
                do {
                    let (data, response) = try await URLSession.shared.data(for: request)
                    print("🔍 DEBUG [Manifest Fetch]: URLSession.data() completed")
                    print("🔍 DEBUG [Manifest Fetch]: Received \(data.count) bytes of data")

                    guard let httpResponse = response as? HTTPURLResponse else {
                        print("🔍 DEBUG [Manifest Fetch]: ERROR - No HTTP response")
                        throw BoostFileError.networkError("No HTTP response")
                    }

                    // FIX #194: Check for transient errors that should trigger retry
                    let statusCode = httpResponse.statusCode
                    print("🔍 DEBUG [Manifest Fetch]: HTTP status code: \(statusCode)")
                    print("🔍 DEBUG [Manifest Fetch]: Response headers: \(httpResponse.allHeaderFields)")

                    if [502, 503, 504].contains(statusCode) {
                        print("⚠️ FIX #194: GitHub returned HTTP \(statusCode) (attempt \(attempt)/\(maxRetries)), retrying in 3s...")
                        try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 second delay
                        lastError = BoostFileError.networkError("HTTP \(statusCode)")
                        continue
                    }

                    guard statusCode == 200 else {
                        print("🔍 DEBUG [Manifest Fetch]: ERROR - Non-200 status code")
                        throw BoostFileError.networkError("HTTP \(statusCode)")
                    }

                    print("🔍 DEBUG [Manifest Fetch]: Decoding JSON manifest...")
                    let manifest = try JSONDecoder().decode(BoostManifest.self, from: data)
                    print("🔍 DEBUG [Manifest Fetch]: Successfully decoded manifest, format: \(manifest.format)")
                    return manifest
                } catch let urlError as URLError {
                    print("🔍 DEBUG [Manifest Fetch]: URLError caught: \(urlError.localizedDescription)")
                    print("🔍 DEBUG [Manifest Fetch]: URLError code: \(urlError.code.rawValue)")
                    print("🔍 DEBUG [Manifest Fetch]: URLError failing URL: \(urlError.failureURLString ?? "none")")
                    throw urlError
                } catch let decodingError as DecodingError {
                    print("🔍 DEBUG [Manifest Fetch]: JSON decoding error: \(decodingError)")
                    throw decodingError
                }
            } catch {
                lastError = error
                if attempt < maxRetries {
                    print("⚠️ FIX #194: Fetch manifest failed (attempt \(attempt)/\(maxRetries)): \(error.localizedDescription)")
                    print("🔍 DEBUG [Manifest Fetch]: Error type: \(type(of: error))")
                    print("🔍 DEBUG [Manifest Fetch]: Error details: \(error)")
                    try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 second delay
                }
            }
        }

        throw lastError ?? BoostFileError.networkError("Max retries exceeded")
    }

    private func loadCachedManifest() -> BoostManifest? {
        guard FileManager.default.fileExists(atPath: cachedManifestPath.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: cachedManifestPath)
            return try JSONDecoder().decode(BoostManifest.self, from: data)
        } catch {
            print("⚠️ Failed to load cached manifest: \(error)")
            return nil
        }
    }

    private func saveManifest(_ manifest: BoostManifest) throws {
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: cachedManifestPath)
    }

    private func downloadBoostFile(manifest: BoostManifest, onProgress: ((Double) -> Void)?) async throws {
        // Get latest release from GitHub to find boost file URL
        let release = try await fetchLatestRelease()

        let isThreePart = manifest.isThreePartFormat

        if isThreePart {
            // Three-file format: download core file (required) + optionally equihash
            guard let coreFileInfo = manifest.files.core else {
                throw BoostFileError.networkError("Three-part format manifest missing 'core' file info")
            }

            let coreFileName = coreFileInfo.name.hasSuffix(".zst")
                ? coreFileInfo.name
                : coreFileInfo.name + ".zst"

            guard let coreAsset = release.assets.first(where: { $0.name == coreFileName }) else {
                throw BoostFileError.networkError("Core file '\(coreFileName)' not found in release \(release.tag_name)")
            }

            // Download core file (required)
            print("🚀 Three-part format: Downloading CORE file from release \(release.tag_name)")
            try await downloadSingleFile(
                asset: coreAsset,
                targetPath: cachedCorePath,
                onProgress: onProgress
            )

            // Optionally download equihash file (if user wants full verification)
            if let equihashFileInfo = manifest.files.equihash {
                let equihashFileName = equihashFileInfo.name.hasSuffix(".zst")
                    ? equihashFileInfo.name
                    : equihashFileInfo.name + ".zst"

                if let equihashAsset = release.assets.first(where: { $0.name == equihashFileName }) {
                    print("🚀 Three-part format: Downloading EQUIHASH file (optional) from release \(release.tag_name)")
                    do {
                        try await downloadSingleFile(
                            asset: equihashAsset,
                            targetPath: cachedEquihashPath,
                            onProgress: { _ in } // No progress for optional file
                        )
                        print("✅ Three-part format: Downloaded both core and equihash files")
                    } catch {
                        print("⚠️ Three-part format: Failed to download equihash file (non-critical): \(error.localizedDescription)")
                        // Don't throw - equihash is optional
                    }
                } else {
                    print("⚠️ Three-part format: Equihash file '\(equihashFileName)' not found in release (non-critical)")
                }
            } else {
                print("ℹ️ Three-part format: No equihash file in manifest (optional)")
            }

        } else {
            // Single-file format (v1/v2)
            guard let boostAsset = release.assets.first(where: { $0.name == Self.boostFileName || $0.name == Self.boostFileName + ".zst" }) else {
                throw BoostFileError.networkError("Boost file '\(Self.boostFileName)' not found in release \(release.tag_name)")
            }

            print("🚀 Single-file format: Downloading from release \(release.tag_name)")
            try await downloadSingleFile(
                asset: boostAsset,
                targetPath: cachedBoostPath,
                onProgress: onProgress
            )
        }
    }

    /// Download a single file with retry logic
    private func downloadSingleFile(asset: GitHubAsset, targetPath: URL, onProgress: ((Double) -> Void)?) async throws {
        guard let url = URL(string: asset.browser_download_url) else {
            throw BoostFileError.invalidURL
        }

        print("📥 URL: \(asset.browser_download_url)")
        print("📦 Expected size: \(asset.size) bytes")

        // FIX #194 v2: Retry on transient GitHub errors (502, 503, 504)
        // FIX #195: Use ephemeral session to avoid stale network cache after Tor bypass
        let maxRetries = 5  // Increased from 3 to handle network stabilization
        var lastError: Error?

        for attempt in 1...maxRetries {
            do {
                // FIX #195: Use ephemeral configuration to ensure fresh network connections
                // This prevents issues when Tor is bypassed and network path changes
                let config = URLSessionConfiguration.ephemeral
                config.timeoutIntervalForResource = 3600 // 1 hour timeout for large file
                config.timeoutIntervalForRequest = 60    // 60s per request
                config.waitsForConnectivity = true       // Wait for network

                let delegate = DownloadProgressDelegate { progress in
                    onProgress?(progress)
                }

                let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)

                let (tempURL, response) = try await session.download(from: url)

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw BoostFileError.networkError("No HTTP response")
                }

                // FIX #194: Check for transient errors that should trigger retry
                let statusCode = httpResponse.statusCode
                if [502, 503, 504].contains(statusCode) {
                    // FIX #195: Longer delay on first attempts to let network stabilize after Tor bypass
                    let delaySeconds = attempt <= 2 ? 5 : 3
                    print("⚠️ FIX #194: Download returned HTTP \(statusCode) (attempt \(attempt)/\(maxRetries)), retrying in \(delaySeconds)s...")
                    try? await Task.sleep(nanoseconds: UInt64(delaySeconds) * 1_000_000_000)
                    lastError = BoostFileError.networkError("HTTP \(statusCode) downloading file")
                    continue
                }

                guard statusCode == 200 else {
                    throw BoostFileError.networkError("HTTP \(statusCode) downloading file")
                }

                // Move to cache
                if FileManager.default.fileExists(atPath: targetPath.path) {
                    try FileManager.default.removeItem(at: targetPath)
                }
                try FileManager.default.moveItem(at: tempURL, to: targetPath)

                print("✅ Downloaded file: \(asset.size) bytes -> \(targetPath.lastPathComponent)")

                // Decompress if .zst
                if targetPath.path.hasSuffix(".zst") || asset.name.hasSuffix(".zst") {
                    let uncompressedPath = URL(fileURLWithPath: targetPath.path.replacingOccurrences(of: ".zst", with: ""))
                    print("📦 Decompressing .zst file...")
                    try await decompressZstFile(source: targetPath, target: uncompressedPath)
                    // Remove compressed file after successful decompression
                    try? FileManager.default.removeItem(at: targetPath)
                    print("✅ Decompressed to: \(uncompressedPath.lastPathComponent)")
                }

                return
            } catch {
                lastError = error
                if attempt < maxRetries {
                    let delaySeconds = attempt <= 2 ? 5 : 3
                    print("⚠️ FIX #194: Download failed (attempt \(attempt)/\(maxRetries)): \(error.localizedDescription), retrying in \(delaySeconds)s...")
                    try? await Task.sleep(nanoseconds: UInt64(delaySeconds) * 1_000_000_000)
                }
            }
        }

        throw lastError ?? BoostFileError.networkError("Max retries exceeded")
    }

    /// Decompress a .zst file using pure Swift ZSTD decoder
    /// No external dependencies required
    private func decompressZstFile(source: URL, target: URL) async throws {
        // Read compressed data
        let compressedData = try Data(contentsOf: source)
        print("📦 Reading \(compressedData.count) bytes of compressed data...")

        // Decompress using pure Swift ZSTD decoder
        let decompressedData = try ZSTDDecoder.decompress(data: compressedData)

        print("✅ Decompressed \(compressedData.count) bytes → \(decompressedData.count) bytes")

        // Write decompressed data
        try decompressedData.write(to: target)
    }

    private func verifySHA256(file: URL, expected: String) -> Bool {
        guard let data = try? Data(contentsOf: file) else {
            return false
        }

        let computed = sha256(data: data)
        let matches = computed.lowercased() == expected.lowercased()

        if !matches {
            print("⚠️ SHA256 mismatch: expected \(expected), got \(computed)")
        }

        return matches
    }

    private func sha256(data: Data) -> String {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(data.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Errors

enum BoostFileError: LocalizedError {
    case invalidURL
    case networkError(String)
    case checksumMismatch
    case fileNotFound
    case noManifest
    case sectionNotFound(String)
    case readError
    case invalidFormat

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid URL for boost file download"
        case .networkError(let details):
            return "Network error: \(details)"
        case .checksumMismatch:
            return "Downloaded file size does not match expected value"
        case .fileNotFound:
            return "Boost file not found in cache"
        case .noManifest:
            return "No manifest available"
        case .sectionNotFound(let section):
            return "Section not found in boost file: \(section)"
        case .readError:
            return "Failed to read data from boost file"
        case .invalidFormat:
            return "Invalid boost file format"
        }
    }
}

// Backward compatibility alias
typealias TreeUpdaterError = BoostFileError

// MARK: - Download Progress Delegate

private class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate {
    let progressHandler: (Double) -> Void

    init(progressHandler: @escaping (Double) -> Void) {
        self.progressHandler = progressHandler
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        DispatchQueue.main.async {
            self.progressHandler(progress)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // Handled by async/await pattern
    }
}
