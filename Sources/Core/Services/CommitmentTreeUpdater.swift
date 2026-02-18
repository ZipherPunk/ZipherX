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

    // ============================================================
    // TESTING MODE: Set to true to use local boost file instead of downloading from GitHub
    // ============================================================
    // When true, the app will look for a local boost file at:
    // 1. ~/Library/Application Support/ZipherX/BoostCache/zipherx_boost_v1.bin (already decompressed)
    // 2. ~/Library/Application Support/ZipherX/BoostCache/zipherx_boost_v1.bin.zst (will decompress)
    // 3. ~/Downloads/zipherx_boost_v1.bin (decompressed)
    // This is for testing purposes only - set back to false for production!
    // ============================================================
    // FIX #599: Set to false to download corrected boost file from GitHub (block hashes were reversed)
    private static let USE_LOCAL_BOOST_FILE_FOR_TESTING = false

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

    /// Path to cached core boost file COMPRESSED (.zst)
    private var cachedCorePathZst: URL {
        boostCacheDirectory.appendingPathComponent("zipherx_boost_core.bin.zst")
    }

    /// Path to cached extracted CMU data (FIX #564: Cache to avoid re-extraction)
    private var cachedCMUDataPath: URL {
        boostCacheDirectory.appendingPathComponent("zipherx_boost_cmus.bin")
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
        let source_file: String?
        let source_size: Int?
        let files: ManifestFiles
        let sections: [SectionInfo]

        /// Check if this is a three-file format (v3+) or core-only format (v4+)
        var isThreePartFormat: Bool {
            format == "zipherx_boost_v2_three_part" || format == "zipherx_boost_v2_core_only" || version >= 3
        }

        /// FIX #1349: Check if boost file is split into multiple parts for download
        var isSplitFormat: Bool {
            if let parts = files.split_parts, parts.count >= 2 { return true }
            return false
        }

        struct ManifestFiles: Codable {
            let uncompressed: FileInfo
            // Three-part format (v3+)
            let core: FileInfo?
            let equihash: FileInfo?
            // FIX #1349: Split-part download support
            let compressed: FileInfo?
            let split_parts: [FileInfo]?
            let split_count: Int?

            // For backward compatibility with single-file format
            private enum CodingKeys: String, CodingKey {
                case uncompressed
                case compressed
                case core
                case equihash
                case split_parts
                case split_count
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)

                // FIX #1349: Decode split-part fields (present in all formats)
                self.compressed = try? container.decode(FileInfo.self, forKey: .compressed)
                self.split_parts = try? container.decode([FileInfo].self, forKey: .split_parts)
                self.split_count = try? container.decode(Int.self, forKey: .split_count)

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
                // FIX #1349: Encode split-part fields
                try container.encodeIfPresent(compressed, forKey: .compressed)
                try container.encodeIfPresent(split_parts, forKey: .split_parts)
                try container.encodeIfPresent(split_count, forKey: .split_count)
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

        // ============================================================
        // TESTING MODE: Check for local boost file (skip GitHub download)
        // ============================================================
        // When USE_LOCAL_BOOST_FILE_FOR_TESTING = true:
        // 1. Check if decompressed file exists in boost cache -> use it
        // 2. Check if .zst file exists in boost cache -> decompress it
        // 3. Check Downloads for either file
        // If found, skip ALL GitHub network operations!
        // ============================================================
        if Self.USE_LOCAL_BOOST_FILE_FOR_TESTING {
            print("🧪 TESTING MODE: Looking for local boost file (skipping GitHub download)")

            // Helper function to check and return a valid boost file
            func findLocalBoostFile() -> (URL, Int)? {
                // Check 1: Decompressed file in boost cache
                let decompressedPath = cachedBoostPath
                if FileManager.default.fileExists(atPath: decompressedPath.path) {
                    let attrs = try? FileManager.default.attributesOfItem(atPath: decompressedPath.path)
                    let fileSize = attrs?[.size] as? Int ?? 0
                    if fileSize > 500_000_000 {
                        print("🧪 TESTING MODE: Found decompressed file in cache: \(decompressedPath.path) (\(fileSize / 1024 / 1024) MB)")
                        return (decompressedPath, fileSize)
                    }
                }

                // Check 2: Compressed .zst file in boost cache
                let compressedPath = boostCacheDirectory.appendingPathComponent("zipherx_boost_v1.bin.zst")
                if FileManager.default.fileExists(atPath: compressedPath.path) {
                    let attrs = try? FileManager.default.attributesOfItem(atPath: compressedPath.path)
                    let fileSize = attrs?[.size] as? Int ?? 0
                    if fileSize > 100_000_000 { // At least 100MB compressed
                        print("🧪 TESTING MODE: Found compressed file in cache: \(compressedPath.path) (\(fileSize / 1024 / 1024) MB)")
                        print("🧪 TESTING MODE: Decompressing...")

                        // Decompress using Rust FFI (actor-safe)
                        let success = ZipherXFFI.decompressZst(
                            source: compressedPath.path,
                            target: decompressedPath.path
                        )

                        if success, FileManager.default.fileExists(atPath: decompressedPath.path) {
                            let decompressedSize = try? FileManager.default.attributesOfItem(atPath: decompressedPath.path)[.size] as? Int ?? 0
                            if (decompressedSize ?? 0) > 500_000_000 {
                                print("🧪 TESTING MODE: Decompressed to \(decompressedPath.path) (\(decompressedSize ?? 0) / 1024 / 1024) MB)")
                                return (decompressedPath, decompressedSize ?? 0)
                            } else {
                                print("⚠️ TESTING MODE: Decompressed file too small")
                            }
                        } else {
                            print("⚠️ TESTING MODE: Decompression failed")
                        }
                    }
                }

                // Check 3: Known boost file locations (macOS only — iOS sandbox has no user home access)
                #if os(macOS)
                let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
                let knownPaths = [
                    "\(homeDir)/Documents/BoostCache/zipherx_boost_v1.bin",
                    "\(homeDir)/ZipherX_Boost/zipherx_boost_v1.bin"
                ]
                #else
                let knownPaths: [String] = []
                #endif

                for knownPath in knownPaths {
                    if FileManager.default.fileExists(atPath: knownPath) {
                        let attrs = try? FileManager.default.attributesOfItem(atPath: knownPath)
                        let fileSize = attrs?[.size] as? Int ?? 0
                        if fileSize > 2_000_000_000 { // At least 2GB
                            print("🧪 TESTING MODE: Found file at known location: \(knownPath) (\(fileSize / 1024 / 1024) MB)")

                            // Copy to boost cache
                            try? FileManager.default.createDirectory(at: boostCacheDirectory, withIntermediateDirectories: true)
                            try? FileManager.default.copyItem(at: URL(fileURLWithPath: knownPath), to: decompressedPath)

                            // Also copy the manifest file if it exists in the same directory
                            let knownDir = (knownPath as NSString).deletingLastPathComponent
                            let manifestPath = "\(knownDir)/zipherx_boost_manifest.json"
                            if FileManager.default.fileExists(atPath: manifestPath) {
                                let cachedManifestPath = boostCacheDirectory.appendingPathComponent("zipherx_boost_manifest.json")
                                try? FileManager.default.copyItem(at: URL(fileURLWithPath: manifestPath), to: cachedManifestPath)
                                print("🧪 TESTING MODE: Also copied manifest file")
                            }

                            return (decompressedPath, fileSize)
                        }
                    }
                }

                // Check 4: Decompressed file in Downloads (check both standard and backup names)
                let downloadsDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
                let downloadsPaths = [
                    downloadsDir.appendingPathComponent("zipherx_boost_v1.bin"),
                    downloadsDir.appendingPathComponent("zipherx_boost_v1_backup.bin")
                ]

                for downloadsPath in downloadsPaths {
                    if FileManager.default.fileExists(atPath: downloadsPath.path) {
                        let attrs = try? FileManager.default.attributesOfItem(atPath: downloadsPath.path)
                        let fileSize = attrs?[.size] as? Int ?? 0
                        if fileSize > 500_000_000 {
                            print("🧪 TESTING MODE: Found file in Downloads: \(downloadsPath.path) (\(fileSize / 1024 / 1024) MB)")

                            // Copy to boost cache
                            try? FileManager.default.createDirectory(at: boostCacheDirectory, withIntermediateDirectories: true)
                            try? FileManager.default.copyItem(at: downloadsPath, to: decompressedPath)
                            return (decompressedPath, fileSize)
                        }
                    }
                }

                return nil
            }

            // Try to find local boost file
            if let (filePath, fileSize) = findLocalBoostFile() {
                print("🧪 TESTING MODE: Using local boost file - SKIPPING GITHUB DOWNLOAD")
                print("🧪 TESTING MODE: File: \(filePath.path)")
                print("🧪 TESTING MODE: Size: \(fileSize / 1024 / 1024) MB")

                // Try to load existing manifest for height/output count
                if let manifest = loadCachedManifest() {
                    print("🧪 TESTING MODE: Using cached manifest: height=\(manifest.chain_height), outputs=\(manifest.output_count)")
                    onProgress?(1.0, "Using local boost file")
                    return (filePath, manifest.chain_height, manifest.output_count)
                } else {
                    // No manifest - use default values (will be detected from file)
                    print("🧪 TESTING MODE: No manifest found, using defaults (will detect from file)")
                    onProgress?(1.0, "Using local boost file")
                    // Return default height 2973646 with actual file - the scanner will detect real values
                    return (filePath, 2973646, 1044718)
                }
            } else {
                let downloadsDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
                print("⚠️ TESTING MODE: No local boost file found!")
                print("⚠️ TESTING MODE: Checked:")
                print("   1. \(cachedBoostPath.path)")
                print("   2. \(boostCacheDirectory.appendingPathComponent("zipherx_boost_v1.bin.zst").path)")
                print("   3. \(downloadsDir.appendingPathComponent("zipherx_boost_v1.bin").path)")
                print("   4. \(downloadsDir.appendingPathComponent("zipherx_boost_v1_backup.bin").path)")
            }
        }

        // FIX #526: Validate cached manifest before using it
        // If manifest is stale (old height from 2025-12-29), delete it to force re-download
        _ = await validateAndFixCachedManifest()

        // Check for valid cached boost file first
        let cachedManifest = loadCachedManifest()
        if let cachedManifest = cachedManifest {
            // FIX #526: Log what we have in cache
            print("🔧 FIX #526: Checking cached manifest:")
            print("   Height: \(cachedManifest.chain_height)")
            print("   Outputs: \(cachedManifest.output_count)")
            print("   Created: \(cachedManifest.created_at)")

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
                        // FIX #526: Log comparison
                        print("🔧 FIX #526: Remote vs Cached comparison:")
                        print("   Remote height: \(remoteManifest.chain_height)")
                        print("   Cached height: \(cachedManifest.chain_height)")

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

        // FIX #526: Clear cached release info to ensure we get fresh data
        cachedReleaseInfo = nil
        print("🔧 FIX #526: Cleared cached release info for fresh fetch")

        let remoteManifest = try await fetchRemoteManifest()

        // FIX #526: Log what we got from remote
        print("🔧 FIX #526: Fetched remote manifest from GitHub:")
        print("   Height: \(remoteManifest.chain_height)")
        print("   Outputs: \(remoteManifest.output_count)")
        print("   Created: \(remoteManifest.created_at)")
        print("   Tree root: \(remoteManifest.tree_root.prefix(16))...")

        let activePath = getActiveBoostPath(for: remoteManifest)
        let isThreePart = remoteManifest.isThreePartFormat

        // FIX #1339: Use actual download size (compressed .zst) not uncompressed size for progress display.
        // FIX #1349: For split format, sum all part sizes for total download display.
        let fileSizeMB: Int
        if remoteManifest.isSplitFormat, let splitParts = remoteManifest.files.split_parts {
            fileSizeMB = splitParts.reduce(0) { $0 + $1.size } / 1_000_000
        } else {
            let downloadAsset = cachedReleaseInfo?.assets.first(where: { $0.name.hasSuffix(".zst") || $0.name == Self.boostFileName })
            let coreSize = isThreePart ? (remoteManifest.files.core?.size ?? remoteManifest.files.uncompressed.size) : remoteManifest.files.uncompressed.size
            fileSizeMB = (downloadAsset?.size ?? coreSize) / 1_000_000
        }

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

        // Verify file size
        // For .zst files, the decompressed size can vary significantly
        // We only check that the file is non-empty and reasonably sized (>500MB for core files)
        let attrs = try? FileManager.default.attributesOfItem(atPath: activePath.path)
        let fileSize = attrs?[.size] as? Int ?? 0

        // Minimum size check: file should be at least 500MB for a valid boost file
        let minimumSize = 500_000_000
        guard fileSize >= minimumSize else {
            print("❌ File too small: \(fileSize) bytes (minimum \(minimumSize))")
            try? FileManager.default.removeItem(at: activePath)
            throw BoostFileError.checksumMismatch
        }

        print("✅ Size verification passed: \(fileSize) bytes (\(fileSize / 1024 / 1024) MB)")

        // Save manifest
        try saveManifest(remoteManifest)

        // FIX #469: Invalidate CMU cache when new boost file is downloaded
        // This ensures CMUs in cache match the current boost file version
        invalidateCMUCache()

        // FIX #755: Also invalidate delta bundle when boost file is updated
        // Delta CMUs are for heights after boost file - if boost file changes, delta is invalid
        // FIX #1254: force:true — boost file update is authorized to clear verified delta
        DeltaCMUManager.shared.clearDeltaBundle(force: true)
        print("🗑️ FIX #755: Cleared delta bundle (boost file updated)")

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
    /// FIX #564: Caches extracted CMU data to disk for instant loading on subsequent startups
    func extractCMUsInLegacyFormat(onProgress: ((Double) -> Void)? = nil) async throws -> Data {
        guard let manifest = loadCachedManifest() else {
            throw BoostFileError.noManifest
        }

        guard let outputSection = manifest.sections.first(where: { $0.type == SectionType.outputs.rawValue }) else {
            throw BoostFileError.sectionNotFound("outputs")
        }

        // FIX #564: Check if we have valid cached CMU data
        if let cachedData = try? loadCachedCMUData(manifest: manifest) {
            print("✅ FIX #564: Loading CMUs from cache (\(cachedData.count) bytes) - instant!")
            return cachedData
        }

        print("📦 FIX #564: No valid cached CMU data, extracting from boost file...")

        print("🔍 CMU EXTRACTION DEBUG: Found outputs section in manifest:")
        print("   type: \(outputSection.type)")
        print("   count: \(outputSection.count) (0x\(String(outputSection.count, radix: 16)))")
        print("   size: \(outputSection.size)")
        print("   offset: \(outputSection.offset)")

        let activePath = getActiveBoostPath(for: manifest)
        guard FileManager.default.fileExists(atPath: activePath.path) else {
            throw BoostFileError.fileNotFound
        }

        // Output record format in boost file:
        // NEW FORMAT (with txid - FIX #374): 684 bytes
        // OLD FORMAT (without txid): 652 bytes
        // Detect format from section size / count
        let actualRecordSize = outputSection.size / outputSection.count
        let recordSize = actualRecordSize == 684 || actualRecordSize == 652 ? actualRecordSize : 684  // Default to new format
        let cmuOffset = 8  // height(4) + index(4) = 8 (same for both formats)

        print("🔧 Boost file record size: \(recordSize) bytes (\(recordSize == 684 ? "with txid" : "without txid"))")

        let outputCount = outputSection.count
        print("🔄 Extracting \(outputCount) CMUs in legacy format...")
        print("🔍 CMU EXTRACTION DEBUG: outputSection.count = \(outputCount) (0x\(String(outputCount, radix: 16)))")

        // Allocate result buffer: 8 bytes for count + 32 bytes per CMU
        var result = Data(count: 8 + Int(outputCount) * 32)

        // Write count as UInt64 LE
        var count = outputCount
        print("🔍 CMU EXTRACTION DEBUG: count var = \(count) (0x\(String(count, radix: 16)))")

        withUnsafeBytes(of: &count) { bytes in
            print("🔍 CMU EXTRACTION DEBUG: bytes to write: \(bytes.map { String(format: "%02x", $0) }.joined(separator: " "))")
            result.replaceSubrange(0..<8, with: bytes)
        }

        print("🔍 CMU EXTRACTION DEBUG: result first 8 bytes: \(result.prefix(8).map { String(format: "%02x", $0) }.joined(separator: " "))")

        // Read and extract CMUs
        let fileHandle = try FileHandle(forReadingFrom: activePath)
        defer { try? fileHandle.close() }

        try fileHandle.seek(toOffset: outputSection.offset)

        let outputCountInt = Int(outputCount)
        let recordSizeInt = Int(recordSize)
        for i in 0..<outputCountInt {
            guard let recordData = try fileHandle.read(upToCount: recordSizeInt) else {
                throw BoostFileError.readError
            }

            // Extract CMU (32 bytes at offset 8)
            // FIX #743: Boost file CMUs are already in WIRE format (little-endian)
            // The generator does `bytes.fromhex(cmu_hex)[::-1]` which reverses RPC display → wire
            // No reversal needed here - use CMU directly as-is
            let cmu = recordData.subdata(in: cmuOffset..<(cmuOffset + 32))

            // Write CMU to result buffer
            let resultOffset = 8 + i * 32
            result.replaceSubrange(resultOffset..<(resultOffset + 32), with: cmu)

            // Progress callback every 10000 records
            if i % 10000 == 0 {
                onProgress?(Double(i) / Double(outputCountInt))
            }
        }

        onProgress?(1.0)
        print("✅ Extracted \(outputCount) CMUs in legacy format (\(result.count) bytes)")

        // FIX #564: Save extracted CMU data to cache for next startup
        try? saveCMUDataToCache(data: result, manifest: manifest)

        return result
    }

    // MARK: - FIX #564: CMU Data Caching

    /// Load cached CMU data if it matches the current boost manifest
    /// Returns nil if cache doesn't exist, is corrupted, or doesn't match manifest
    /// FIX #819: Also validates CMU byte order to detect stale cache from before FIX #743
    private func loadCachedCMUData(manifest: BoostManifest) throws -> Data? {
        // Check if cache file exists
        guard FileManager.default.fileExists(atPath: cachedCMUDataPath.path) else {
            return nil
        }

        // Read the cached data
        let cachedData = try Data(contentsOf: cachedCMUDataPath)

        // Validate the cached data matches the manifest
        guard cachedData.count >= 8 else {
            print("⚠️ FIX #564: Cached CMU data too small, ignoring")
            return nil
        }

        // Read count from first 8 bytes
        let cachedCount = cachedData.prefix(8).withUnsafeBytes { raw in
            raw.loadUnaligned(as: UInt64.self)
        }

        // Validate count matches manifest
        guard let outputSection = manifest.sections.first(where: { $0.type == SectionType.outputs.rawValue }) else {
            return nil
        }

        if cachedCount != outputSection.count {
            print("⚠️ FIX #564: Cached CMU count (\(cachedCount)) != manifest count (\(outputSection.count)), ignoring")
            return nil
        }

        // Expected size: 8 bytes + count * 32 bytes
        let expectedSize = 8 + Int(outputSection.count) * 32
        guard cachedData.count == expectedSize else {
            print("⚠️ FIX #564: Cached CMU size (\(cachedData.count)) != expected (\(expectedSize)), ignoring")
            return nil
        }

        // FIX #819: CRITICAL - Validate CMU byte order to detect stale cache
        // If cache was created before FIX #743, CMUs are in WRONG byte order (reversed)
        // This causes tree root mismatch and anchor errors
        let cmuByteOrderValid = try validateCMUByteOrder(cachedData: cachedData, manifest: manifest)
        if !cmuByteOrderValid {
            print("🗑️ FIX #819: Deleting stale CMU cache (wrong byte order detected)")
            try? FileManager.default.removeItem(at: cachedCMUDataPath)
            // Also delete legacy cache files
            clearAllLegacyCMUCaches()
            return nil
        }

        print("✅ FIX #564: Cached CMU data validated (\(cachedCount) CMUs, \(cachedData.count) bytes)")
        return cachedData
    }

    /// FIX #819: Validate that cached CMUs have correct byte order by comparing to boost file
    /// Returns true if byte order is correct, false if reversed (stale cache)
    private func validateCMUByteOrder(cachedData: Data, manifest: BoostManifest) throws -> Bool {
        guard let outputSection = manifest.sections.first(where: { $0.type == SectionType.outputs.rawValue }) else {
            return true // Can't validate, assume OK
        }

        let activePath = getActiveBoostPath(for: manifest)
        guard FileManager.default.fileExists(atPath: activePath.path) else {
            return true // Can't validate, assume OK
        }

        // Read first CMU from cache (after 8-byte header)
        guard cachedData.count >= 40 else { return true } // 8 header + 32 CMU
        let cacheCMU = cachedData.subdata(in: 8..<40)

        // Read first CMU from boost file
        // Output record format: height(4) + index(4) + CMU(32) + ...
        let fileHandle = try FileHandle(forReadingFrom: activePath)
        defer { try? fileHandle.close() }

        try fileHandle.seek(toOffset: outputSection.offset)
        guard let recordData = try fileHandle.read(upToCount: 40) else {
            return true // Can't read, assume OK
        }

        // CMU starts at offset 8 in the record (after height + index)
        let boostCMU = recordData.subdata(in: 8..<40)

        // Compare: If cache CMU equals boost CMU, byte order is correct
        // If cache CMU equals REVERSED boost CMU, cache is stale (wrong byte order)
        if cacheCMU == boostCMU {
            print("✅ FIX #819: CMU byte order validation PASSED")
            return true
        }

        // Check if reversed
        let reversedBoostCMU = Data(boostCMU.reversed())
        if cacheCMU == reversedBoostCMU {
            print("❌ FIX #819: CMU byte order REVERSED - cache is stale!")
            print("   Cache CMU:  \(cacheCMU.prefix(16).map { String(format: "%02x", $0) }.joined())")
            print("   Boost CMU:  \(boostCMU.prefix(16).map { String(format: "%02x", $0) }.joined())")
            return false
        }

        // Neither match - could be corrupt or different file
        print("⚠️ FIX #819: CMU mismatch (not matching and not reversed) - regenerating cache")
        return false
    }

    /// FIX #819: Clear all legacy CMU cache files
    private func clearAllLegacyCMUCaches() {
        let cacheDir = boostCacheDirectory
        do {
            let files = try FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil)
            for file in files {
                if file.lastPathComponent.hasPrefix("legacy_cmus_") && file.pathExtension == "bin" {
                    try FileManager.default.removeItem(at: file)
                    print("🗑️ FIX #819: Deleted stale cache: \(file.lastPathComponent)")
                }
            }
        } catch {
            print("⚠️ FIX #819: Could not clear legacy caches: \(error)")
        }
    }

    /// Save extracted CMU data to cache
    private func saveCMUDataToCache(data: Data, manifest: BoostManifest) throws {
        // Create cache directory if needed
        let cacheDir = cachedCMUDataPath.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        // Write data to cache file
        try data.write(to: cachedCMUDataPath)

        print("💾 FIX #564: Saved CMU data to cache (\(data.count) bytes)")
    }

    /// Clear cached CMU data (call when boost file is updated)
    func clearCMUCache() {
        if FileManager.default.fileExists(atPath: cachedCMUDataPath.path) {
            try? FileManager.default.removeItem(at: cachedCMUDataPath)
            print("🗑️ FIX #564: Cleared cached CMU data")
        }
    }

    /// FIX #819: Validate and clear stale CMU caches at startup
    /// Call this BEFORE loading CMUs to ensure correct byte order
    /// Returns true if cache was valid, false if cache was deleted
    /// FIX #881: Skip validation if cache was already validated this session
    func validateAndClearStaleCMUCache() async -> Bool {
        // FIX #881: PERFORMANCE - Skip redundant validation if already validated this session
        // The cache version key persists across app restarts but we clear it when cache is deleted
        let cacheValidatedKey = "CMUCacheValidatedVersion"
        let currentCacheVersion = 6 // Bump this when cache format changes (matches FIX #743)
        let lastValidatedVersion = UserDefaults.standard.integer(forKey: cacheValidatedKey)

        if lastValidatedVersion == currentCacheVersion {
            print("⚡ FIX #881: CMU cache already validated (version \(currentCacheVersion)) - skipping check")
            return true
        }

        guard let manifest = loadCachedManifest() else {
            print("ℹ️ FIX #819: No manifest found, skipping cache validation")
            // FIX #881: Mark as validated since there's nothing to validate
            UserDefaults.standard.set(currentCacheVersion, forKey: cacheValidatedKey)
            return true
        }

        // Check if cache exists
        guard FileManager.default.fileExists(atPath: cachedCMUDataPath.path) else {
            print("ℹ️ FIX #819: No CMU cache file, nothing to validate")
            // FIX #881: Mark as validated since there's no cache
            UserDefaults.standard.set(currentCacheVersion, forKey: cacheValidatedKey)
            return true
        }

        do {
            let cachedData = try Data(contentsOf: cachedCMUDataPath)
            guard cachedData.count >= 40 else {
                print("⚠️ FIX #819: CMU cache too small, deleting")
                try? FileManager.default.removeItem(at: cachedCMUDataPath)
                // FIX #881: Clear validation flag when cache is deleted
                UserDefaults.standard.removeObject(forKey: cacheValidatedKey)
                return false
            }

            let isValid = try validateCMUByteOrder(cachedData: cachedData, manifest: manifest)
            if !isValid {
                print("🗑️ FIX #819: Stale CMU cache detected and removed at startup")
                try? FileManager.default.removeItem(at: cachedCMUDataPath)
                clearAllLegacyCMUCaches()
                // FIX #881: Clear validation flag when cache is deleted
                UserDefaults.standard.removeObject(forKey: cacheValidatedKey)
                return false
            }

            print("✅ FIX #819: CMU cache validated at startup - byte order correct")
            // FIX #881: Mark as validated for future startups
            UserDefaults.standard.set(currentCacheVersion, forKey: cacheValidatedKey)
            return true
        } catch {
            print("⚠️ FIX #819: Error validating CMU cache: \(error)")
            // On error, delete cache to be safe
            try? FileManager.default.removeItem(at: cachedCMUDataPath)
            // FIX #881: Clear validation flag when cache is deleted
            UserDefaults.standard.removeObject(forKey: cacheValidatedKey)
            return false
        }
    }

    // MARK: - Shielded Outputs Extraction

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

    /// FIX #457: Check if boost file has block hashes section (type 3)
    func hasBlockHashesSection() -> Bool {
        guard let manifest = loadCachedManifest() else { return false }
        return manifest.sections.contains(where: { $0.type == SectionType.blockHashes.rawValue })
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
    }

    // FIX #526: Validate cached manifest and auto-fix if stale
    /// Checks if cached manifest matches the expected boost file data
    /// If manifest is stale (height mismatch), deletes it to force re-download
    func validateAndFixCachedManifest() async -> Bool {
        guard let manifest = loadCachedManifest() else {
            // No manifest - need to download
            return false
        }

        // Check against GitHub for latest
        do {
            // Clear cache to get fresh data
            cachedReleaseInfo = nil

            let remoteManifest = try await fetchRemoteManifest()

            print("🔧 FIX #526: Manifest validation:")
            print("   Cached height: \(manifest.chain_height)")
            print("   Remote height: \(remoteManifest.chain_height)")

            if remoteManifest.chain_height > manifest.chain_height {
                // Cached manifest is STALE - delete it to force re-download
                print("⚠️ FIX #526: Cached manifest is STALE - deleting to force re-download")
                try? FileManager.default.removeItem(at: cachedManifestPath)
                print("✅ FIX #526: Deleted stale manifest file")
                return false  // No valid cache after deletion
            }

            print("✅ FIX #526: Cached manifest is up-to-date")
            return true  // Cache is valid
        } catch {
            print("⚠️ FIX #526: Could not validate manifest against GitHub: \(error.localizedDescription)")
            // If we can't reach GitHub, assume cached is OK
            return true
        }
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
    /// Version 3: FIX #577 - Reverse CMU byte order from display (big-endian) to wire (little-endian)
    /// Version 4: FIX #733 - REVERTS FIX #577! Boost file CMUs are already in wire format (generator does [::-1])
    ///            Combined with FIX #730 (FFI no longer reverses), double-reversal was causing tree root mismatch
    /// Version 5: FIX #742 - WRONG! Added reversal again, causing double-reversal
    /// Version 6: FIX #743 - REVERTS FIX #742! Verified generator does [::-1], so CMUs are already wire format
    private static let legacyCMUCacheVersion = 6

    /// Path to cached legacy CMU file (extracted from boost file)
    private var cachedLegacyCMUPath: URL {
        boostCacheDirectory.appendingPathComponent("legacy_cmus_v\(Self.legacyCMUCacheVersion).bin")
    }

    /// FIX #496: Path to CMU cache metadata file (stores boost file signature for validation)
    private var cachedLegacyCMUMetaPath: URL {
        boostCacheDirectory.appendingPathComponent("legacy_cmus_v\(Self.legacyCMUCacheVersion).meta.json")
    }

    /// FIX #496: Metadata structure for CMU cache validation
    private struct CMUCacheMetadata: Codable {
        let chainHeight: UInt64
        let outputCount: UInt64
        let treeRoot: String
        let createdAt: Date
    }

    /// FIX #496: Check if cached CMU file is valid (matches current boost file)
    private func isCachedCMUValid() -> Bool {
        guard FileManager.default.fileExists(atPath: cachedLegacyCMUPath.path),
              FileManager.default.fileExists(atPath: cachedLegacyCMUMetaPath.path) else {
            return false
        }

        guard let manifest = loadCachedManifest(),
              let metaData = try? Data(contentsOf: cachedLegacyCMUMetaPath),
              let metadata = try? JSONDecoder().decode(CMUCacheMetadata.self, from: metaData) else {
            return false
        }

        // Validate against current boost file manifest
        let isValid = metadata.chainHeight == manifest.chain_height &&
                      metadata.outputCount == manifest.output_count &&
                      metadata.treeRoot == manifest.tree_root

        if !isValid {
            print("⚠️ FIX #496: CMU cache stale - boosting file has changed")
            print("   Cache: height=\(metadata.chainHeight), outputs=\(metadata.outputCount)")
            print("   Current: height=\(manifest.chain_height), outputs=\(manifest.output_count)")
        }

        return isValid
    }

    /// FIX #469: Invalidate CMU cache when boost file is updated
    /// This ensures the cached CMUs match the current boost file version
    private func invalidateCMUCache() {
        let fm = FileManager.default
        if fm.fileExists(atPath: cachedLegacyCMUPath.path) {
            do {
                try fm.removeItem(at: cachedLegacyCMUPath)
                print("🗑️ FIX #469: Invalidated CMU cache (will re-extract from current boost file)")
            } catch {
                print("⚠️ FIX #469: Failed to delete CMU cache: \(error.localizedDescription)")
            }
        }
        // FIX #496: Also delete metadata file
        if fm.fileExists(atPath: cachedLegacyCMUMetaPath.path) {
            try? fm.removeItem(at: cachedLegacyCMUMetaPath)
        }
    }

    /// FIX #469: Public method to invalidate CMU cache (called from FilterScanner on retry)
    /// This is called when witness creation fails due to stale CMU cache
    func invalidateCMUCachePublic() async {
        invalidateCMUCache()
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
    /// FIX #496: Validates cache against boost file manifest to detect stale cache
    func getCachedCMUFilePath() async -> URL? {
        // Clean up old cache versions first
        cleanupOldCacheVersions()

        // FIX #496: Check if we have VALID cached legacy CMU file
        if isCachedCMUValid() {
            return cachedLegacyCMUPath
        }

        // Cache is invalid or doesn't exist - need to extract from boost file
        guard hasCachedBoostFile() else { return nil }
        guard let manifest = loadCachedManifest() else { return nil }

        do {
            let cmuData = try await extractCMUsInLegacyFormat()
            try cmuData.write(to: cachedLegacyCMUPath)

            // FIX #496: Write metadata file for validation on next access
            let metadata = CMUCacheMetadata(
                chainHeight: manifest.chain_height,
                outputCount: manifest.output_count,
                treeRoot: manifest.tree_root,
                createdAt: Date()
            )
            let metaData = try JSONEncoder().encode(metadata)
            try metaData.write(to: cachedLegacyCMUMetaPath)

            print("💾 FIX #496: Cached legacy CMU data (v\(Self.legacyCMUCacheVersion)): \(cmuData.count) bytes")
            print("   Chain height: \(manifest.chain_height), Outputs: \(manifest.output_count)")
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

    /// FIX #1354: Public wrapper for boost update check
    func fetchRemoteManifestPublic() async throws -> BoostManifest {
        return try await fetchRemoteManifest()
    }

    private func fetchRemoteManifest() async throws -> BoostManifest {
        // FIX #526: Clear cached release info to ensure we get fresh data from GitHub
        // Without this, we might get old manifest data from a cached release
        cachedReleaseInfo = nil

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

    func loadCachedManifest() -> BoostManifest? {
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

    // FIX #526: Ensure manifest is saved with correct data
    // The manifest file is critical for CMU extraction and validation
    // If this file has stale data, witness creation will fail
    private func saveManifest(_ manifest: BoostManifest) throws {
        // DEBUG: Log what we're about to save
        print("🔧 FIX #526: Saving manifest with:")
        print("   Height: \(manifest.chain_height)")
        print("   Outputs: \(manifest.output_count)")
        print("   Created: \(manifest.created_at)")
        print("   Tree root: \(manifest.tree_root.prefix(16))...")
        print("   Path: \(cachedManifestPath.path)")

        let data = try JSONEncoder().encode(manifest)
        print("🔧 FIX #526: Encoded manifest size: \(data.count) bytes")

        // Ensure directory exists
        let directory = cachedManifestPath.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        // Write atomically to prevent corruption
        try data.write(to: cachedManifestPath, options: .atomic)

        // Verify the write by reading back
        if let savedData = try? Data(contentsOf: cachedManifestPath),
           let savedManifest = try? JSONDecoder().decode(BoostManifest.self, from: savedData) {
            print("🔧 FIX #526: Verified saved manifest:")
            print("   Height: \(savedManifest.chain_height)")
            print("   Outputs: \(savedManifest.output_count)")
            if savedManifest.chain_height == manifest.chain_height &&
               savedManifest.output_count == manifest.output_count {
                print("✅ FIX #526: Manifest saved and verified successfully")

                // FIX #564: Clear CMU cache when boost manifest is updated
                // This ensures we don't use stale cached CMU data with new boost file
                clearCMUCache()
            } else {
                print("⚠️ FIX #526: WARNING - Saved manifest doesn't match expected!")
            }
        } else {
            print("❌ FIX #526: ERROR - Failed to verify saved manifest!")
        }
    }

    private func downloadBoostFile(manifest: BoostManifest, onProgress: ((Double) -> Void)?) async throws {
        // ============================================================
        // TESTING MODE: Skip download if local boost file exists
        // ============================================================
        if Self.USE_LOCAL_BOOST_FILE_FOR_TESTING {
            print("🧪 TESTING MODE: downloadBoostFile called - checking for local file...")

            // Check if decompressed file exists in boost cache
            if FileManager.default.fileExists(atPath: cachedBoostPath.path) {
                let attrs = try? FileManager.default.attributesOfItem(atPath: cachedBoostPath.path)
                let fileSize = attrs?[.size] as? Int ?? 0

                if fileSize > 500_000_000 { // At least 500MB
                    print("🧪 TESTING MODE: Found decompressed file in cache - SKIPPING DOWNLOAD")
                    print("🧪 TESTING MODE: File: \(cachedBoostPath.path)")
                    print("🧪 TESTING MODE: Size: \(fileSize / 1024 / 1024) MB")
                    onProgress?(1.0)
                    return // Skip download!
                }
            }

            // Check if .zst file exists and decompress it
            let compressedPath = boostCacheDirectory.appendingPathComponent("zipherx_boost_v1.bin.zst")
            if FileManager.default.fileExists(atPath: compressedPath.path) {
                let attrs = try? FileManager.default.attributesOfItem(atPath: compressedPath.path)
                let fileSize = attrs?[.size] as? Int ?? 0

                if fileSize > 100_000_000 { // At least 100MB compressed
                    print("🧪 TESTING MODE: Found compressed file - decompressing...")
                    print("🧪 TESTING MODE: File: \(compressedPath.path)")

                    // Decompress using Rust FFI
                    let decompressedPath = cachedBoostPath.path
                    let success = ZipherXFFI.decompressZst(
                        source: compressedPath.path,
                        target: decompressedPath
                    )

                    if success, FileManager.default.fileExists(atPath: decompressedPath) {
                        let decompressedSize = try? FileManager.default.attributesOfItem(atPath: decompressedPath)[.size] as? Int ?? 0
                        print("🧪 TESTING MODE: Decompressed successfully!")
                        print("🧪 TESTING MODE: Size: \(decompressedSize ?? 0) / 1024 / 1024) MB")
                        onProgress?(1.0)
                        return // Skip download!
                    } else {
                        print("⚠️ TESTING MODE: Decompression failed - falling back to download")
                    }
                }
            }

            print("⚠️ TESTING MODE: No local file found - proceeding with download")
        }

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
                targetPath: cachedCorePathZst,  // Save with .zst extension
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

        } else if manifest.isSplitFormat, let splitParts = manifest.files.split_parts {
            // FIX #1349: Split-file format — download parts in parallel, concatenate, decompress
            print("🚀 FIX #1349: Split format detected — \(splitParts.count) parts, downloading in parallel from release \(release.tag_name)")
            try await downloadSplitPartsAndAssemble(
                manifest: manifest,
                release: release,
                splitParts: splitParts,
                onProgress: onProgress
            )
        } else {
            // Single-file format (v1/v2)
            guard let boostAsset = release.assets.first(where: { $0.name == Self.boostFileName || $0.name == Self.boostFileName + ".zst" }) else {
                throw BoostFileError.networkError("Boost file '\(Self.boostFileName)' not found in release \(release.tag_name)")
            }

            print("🚀 Single-file format: Downloading from release \(release.tag_name)")

            // Use .zst extension in target path if asset is compressed
            let targetPath: URL = boostAsset.name.hasSuffix(".zst")
                ? cachedBoostPath.appendingPathExtension("zst")
                : cachedBoostPath

            try await downloadSingleFile(
                asset: boostAsset,
                targetPath: targetPath,
                onProgress: onProgress
            )
        }
    }

    /// Download a single file with retry logic using Rust reqwest (60-100+ MB/s)
    /// FIX #342: Replaces slow Swift URLSession with fast Rust download
    private func downloadSingleFile(asset: GitHubAsset, targetPath: URL, onProgress: ((Double) -> Void)?) async throws {
        let url = asset.browser_download_url
        let destPath = targetPath.path
        let expectedSize = UInt64(asset.size)

        print("📥 URL: \(url)")
        print("📦 Expected size: \(expectedSize) bytes")
        print("🚀 FIX #342: Using fast Rust reqwest download (60-100+ MB/s)")

        // Check for partial download for resume
        let resumeFrom: UInt64
        if FileManager.default.fileExists(atPath: destPath) {
            let currentSize = (try? FileManager.default.attributesOfItem(atPath: destPath)[.size] as? UInt64) ?? 0
            if currentSize < expectedSize {
                // Partial download — resume from where we left off
                resumeFrom = currentSize
                print("📂 Resuming from byte \(resumeFrom)...")
            } else if currentSize == expectedSize {
                // File already complete — skip download
                print("📂 File already downloaded (\(currentSize) bytes = expected)")
                resumeFrom = 0
                // Fall through to let Rust verify, or return early
            } else {
                // FIX #1335: File is LARGER than expected — different boost version on disk.
                // Rust reads actual file size and sends Range header beyond expected → 416 error.
                // Must delete stale file before starting fresh download.
                print("📂 FIX #1335: Existing file (\(currentSize) bytes) larger than expected (\(expectedSize) bytes) — deleting stale file")
                try? FileManager.default.removeItem(atPath: destPath)
                resumeFrom = 0
            }
        } else {
            resumeFrom = 0
        }

        // FIX #454: Start progress timer BEFORE blocking download to show real-time progress
        // The Rust downloadFile() is synchronous blocking, so we need concurrent monitoring
        var downloadResult: Int32 = -1
        var downloadError: Error?

        print("🔧 DEBUG: Starting progress polling...")

        // FIX #457 v9: Use async Task for polling instead of blocking main thread!
        // Thread.sleep() on DispatchQueue.main blocks UI updates!
        var progressPollingActive = true

        // Start polling in background Task (non-blocking)
        Task {
            while progressPollingActive {
                let (bytes, total, speed) = ZipherXFFI.getDownloadProgress()
                if total > 0 {
                    let progress = Double(bytes) / Double(total)

                    // Update UI on main thread
                    await MainActor.run {
                        onProgress?(progress)
                    }

                    // Log speed every ~50MB or at completion (every 0.1s)
                    if Int(bytes) % 50_000_000 == 0 || bytes >= total {
                        let speedMB = speed / 1_000_000
                        let downloadedMB = Double(bytes) / 1_000_000
                        let totalMB = Double(total) / 1_000_000
                        print("📥 Progress: \(String(format: "%.1f", downloadedMB))/\(String(format: "%.1f", totalMB)) MB @ \(String(format: "%.1f", speedMB)) MB/s")
                    }
                } else {
                    print("🔧 DEBUG: Waiting for download progress... total=\(total)")
                }

                // Sleep in background thread, NOT main thread!
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
            }
        }

        print("🔧 DEBUG: Progress polling started, starting Rust download...")

        // Run blocking download on background thread
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                print("🔧 DEBUG: Background thread: Calling Rust downloadFile...")
                // Start download with Rust FFI (BLOCKING - takes 2-3 minutes)
                downloadResult = ZipherXFFI.downloadFile(
                    url: url,
                    destPath: destPath,
                    resumeFrom: resumeFrom,
                    expectedSize: expectedSize
                )
                print("🔧 DEBUG: Background thread: downloadFile returned \(downloadResult)")

                // Stop progress polling
                progressPollingActive = false

                continuation.resume()
            }
        }

        print("🔧 DEBUG: Download complete, result=\(downloadResult)")

        guard downloadResult == 0 else {
            let errorMsg = [
                "Success",
                "Network error",
                "File error",
                "Cancelled",
                "Other error"
            ][Int(min(UInt64(abs(Int32(downloadResult))), 4))] ?? "Unknown error"
            throw BoostFileError.networkError("Rust download failed: \(errorMsg) (code: \(downloadResult))")
        }

        // Verify file exists and has correct size
        guard FileManager.default.fileExists(atPath: destPath) else {
            throw BoostFileError.networkError("Downloaded file not found at \(destPath)")
        }

        let actualSize = (try? FileManager.default.attributesOfItem(atPath: destPath)[.size] as? UInt64) ?? 0
        if actualSize != expectedSize {
            throw BoostFileError.networkError("File size mismatch: got \(actualSize), expected \(expectedSize)")
        }

        print("✅ Downloaded file: \(actualSize) bytes -> \(targetPath.lastPathComponent)")

        // Decompress if .zst using Rust FFI
        if destPath.hasSuffix(".zst") || asset.name.hasSuffix(".zst") {
            let uncompressedPath = String(destPath.dropLast(4))
            print("📦 Decompressing .zst file using Rust zstd...")
            let decompressResult = ZipherXFFI.decompressZst(
                source: destPath,
                target: uncompressedPath
            )
            guard decompressResult else {
                throw BoostFileError.networkError("ZSTD decompression failed")
            }
            // Remove compressed file after successful decompression
            try? FileManager.default.removeItem(atPath: destPath)
            print("✅ Decompressed to: \(URL(fileURLWithPath: uncompressedPath).lastPathComponent)")
        }
    }

    /// FIX #1349: Download split parts in parallel using Rust FFI, concatenate, and decompress
    /// Uses DispatchQueue for parallel Rust FFI calls, file-size polling for progress
    private func downloadSplitPartsAndAssemble(
        manifest: BoostManifest,
        release: GitHubRelease,
        splitParts: [BoostManifest.FileInfo],
        onProgress: ((Double) -> Void)?
    ) async throws {
        let partPaths: [URL] = splitParts.map { part in
            boostCacheDirectory.appendingPathComponent(part.name)
        }

        // 1. Find GitHub assets for each part
        var partAssets: [(asset: GitHubAsset, info: BoostManifest.FileInfo, path: URL)] = []
        for (index, part) in splitParts.enumerated() {
            guard let asset = release.assets.first(where: { $0.name == part.name }) else {
                throw BoostFileError.networkError("FIX #1349: Split part '\(part.name)' not found in release \(release.tag_name)")
            }
            partAssets.append((asset: asset, info: part, path: partPaths[index]))
        }

        let totalSize = Int64(partAssets.reduce(0) { $0 + $1.info.size })
        print("📥 FIX #1349: Downloading \(partAssets.count) parts (\(totalSize / 1_000_000) MB total)")

        // 2. Download all parts in parallel using DispatchQueue + Rust FFI
        //    Progress tracked by polling file sizes (Rust global progress API not safe for parallel use)
        let lock = NSLock()
        var downloadErrors: [Int: Error] = [:]
        var completedParts: Set<Int> = []

        let group = DispatchGroup()
        for (index, partInfo) in partAssets.enumerated() {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let destPath = partInfo.path.path
                let expectedSize = UInt64(partInfo.info.size)

                // Check for existing partial/complete download
                if FileManager.default.fileExists(atPath: destPath) {
                    let currentSize = (try? FileManager.default.attributesOfItem(atPath: destPath)[.size] as? UInt64) ?? 0
                    if currentSize >= expectedSize {
                        print("📂 FIX #1349: Part \(index + 1) already downloaded (\(currentSize) bytes)")
                        lock.lock()
                        completedParts.insert(index)
                        lock.unlock()
                        group.leave()
                        return
                    }
                }

                let resumeFrom: UInt64 = {
                    guard FileManager.default.fileExists(atPath: destPath) else { return 0 }
                    return (try? FileManager.default.attributesOfItem(atPath: destPath)[.size] as? UInt64) ?? 0
                }()

                print("📥 FIX #1349: Starting part \(index + 1)/\(partAssets.count) download: \(partInfo.info.name) (\(expectedSize / 1_000_000) MB)")

                let result = ZipherXFFI.downloadFile(
                    url: partInfo.asset.browser_download_url,
                    destPath: destPath,
                    resumeFrom: resumeFrom,
                    expectedSize: expectedSize
                )

                lock.lock()
                if result == 0 {
                    completedParts.insert(index)
                    print("✅ FIX #1349: Part \(index + 1) download complete")
                } else {
                    let errorMsg = ["Success", "Network error", "File error", "Cancelled", "Other error"]
                    let msg = errorMsg[Int(min(abs(result), 4))]
                    downloadErrors[index] = BoostFileError.networkError("FIX #1349: Part \(index + 1) failed: \(msg) (code: \(result))")
                    print("❌ FIX #1349: Part \(index + 1) download failed (code: \(result))")
                }
                lock.unlock()
                group.leave()
            }
        }

        // 3. Poll file sizes for combined progress while downloads run
        let progressTask = Task { @Sendable in
            while true {
                lock.lock()
                let done = completedParts.count >= partAssets.count || !downloadErrors.isEmpty
                lock.unlock()
                if done { break }

                var totalDownloaded: Int64 = 0
                for partInfo in partAssets {
                    let size = (try? FileManager.default.attributesOfItem(atPath: partInfo.path.path)[.size] as? Int64) ?? 0
                    totalDownloaded += size
                }
                let progress = totalSize > 0 ? Double(totalDownloaded) / Double(totalSize) : 0
                await MainActor.run { onProgress?(progress) }
                try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
            }
        }

        // Wait for all downloads to complete
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            group.notify(queue: .global()) { continuation.resume() }
        }
        progressTask.cancel()

        // Check for errors
        if let firstError = downloadErrors.values.first {
            throw firstError
        }

        // 4. Verify each part's size
        for (index, partInfo) in partAssets.enumerated() {
            let attrs = try? FileManager.default.attributesOfItem(atPath: partInfo.path.path)
            let actualSize = attrs?[.size] as? Int ?? 0
            guard actualSize == partInfo.info.size else {
                throw BoostFileError.networkError("FIX #1349: Part \(index + 1) size mismatch: got \(actualSize), expected \(partInfo.info.size)")
            }
        }

        // 5. Verify each part's SHA256 (if available)
        for (index, partInfo) in partAssets.enumerated() {
            if !partInfo.info.sha256.isEmpty {
                onProgress?(0.92 + Double(index) * 0.02)
                let match = verifySHA256(file: partInfo.path, expected: partInfo.info.sha256)
                guard match else {
                    print("❌ FIX #1349: Part \(index + 1) SHA256 mismatch!")
                    // Delete corrupted part so it will be re-downloaded on retry
                    try? FileManager.default.removeItem(at: partInfo.path)
                    throw BoostFileError.checksumMismatch
                }
                print("✅ FIX #1349: Part \(index + 1) SHA256 verified")
            }
        }

        // 6. Concatenate parts into full .zst file
        onProgress?(0.96)
        let compressedPath = boostCacheDirectory.appendingPathComponent("zipherx_boost_v1.bin.zst")
        try concatenateFiles(parts: partPaths, output: compressedPath)
        print("✅ FIX #1349: Concatenated \(partAssets.count) parts → \(compressedPath.lastPathComponent)")

        // 6b. Delete parts immediately after concatenation to reduce peak disk usage
        // (parts 2GB + .zst 2GB + .bin 2.3GB = 6.3GB peak → .zst 2GB + .bin 2.3GB = 4.3GB)
        for partPath in partPaths {
            try? FileManager.default.removeItem(at: partPath)
        }

        // 7. Decompress .zst → .bin
        onProgress?(0.97)
        let decompressedPath = cachedBoostPath.path
        print("📦 FIX #1349: Decompressing \(compressedPath.lastPathComponent)...")
        let decompressResult = ZipherXFFI.decompressZst(
            source: compressedPath.path,
            target: decompressedPath
        )
        guard decompressResult else {
            throw BoostFileError.networkError("FIX #1349: ZSTD decompression failed")
        }
        print("✅ FIX #1349: Decompressed to \(cachedBoostPath.lastPathComponent)")

        // 8. Cleanup: remove .zst after successful decompression
        try? FileManager.default.removeItem(at: compressedPath)
        print("🗑️ FIX #1349: Cleaned up .zst file")
    }

    /// FIX #1349: Concatenate split part files into a single output file
    /// Uses 8MB chunked reads to avoid memory pressure on iOS
    private func concatenateFiles(parts: [URL], output: URL) throws {
        // Remove existing output if present
        if FileManager.default.fileExists(atPath: output.path) {
            try FileManager.default.removeItem(at: output)
        }

        // Create output file
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: output)
        defer { outputHandle.closeFile() }

        let chunkSize = 8 * 1024 * 1024 // 8MB chunks

        for (index, partURL) in parts.enumerated() {
            let inputHandle = try FileHandle(forReadingFrom: partURL)
            defer { inputHandle.closeFile() }

            while autoreleasepool(invoking: {
                let chunk = inputHandle.readData(ofLength: chunkSize)
                if chunk.isEmpty { return false }
                outputHandle.write(chunk)
                return true
            }) {}

            print("📎 FIX #1349: Appended part \(index + 1)/\(parts.count)")
        }
    }

    /// Decompress a .zst file using Rust FFI ZSTD (self-contained)
    /// No external tools required - uses bundled libzstd
    private func decompressZstFile(source: URL, target: URL) async throws {
        print("📦 Reading \(source.lastPathComponent) for decompression...")

        // Read compressed data
        let compressedData = try Data(contentsOf: source)
        print("📦 Read \(compressedData.count) bytes of compressed data")

        // Decompress using Rust FFI ZSTD
        print("📦 Decompressing with bundled ZSTD...")
        let decompressedData = try ZSTDDecoder.decompress(data: compressedData)

        print("✅ Decompressed \(compressedData.count) bytes → \(decompressedData.count) bytes")

        // Remove existing file if present
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }

        // Write decompressed data
        try decompressedData.write(to: target)
        print("✅ Successfully decompressed to: \(target.lastPathComponent)")
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
