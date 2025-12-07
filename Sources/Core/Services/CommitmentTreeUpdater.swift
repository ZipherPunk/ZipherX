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
    }

    // MARK: - File Header Constants

    private static let MAGIC: [UInt8] = [0x5A, 0x42, 0x4F, 0x4F, 0x53, 0x54, 0x30, 0x31] // "ZBOOST01"
    private static let HEADER_SIZE: UInt64 = 128
    private static let SECTION_ENTRY_SIZE: UInt64 = 32

    /// Local directory for downloaded boost file
    private var boostCacheDirectory: URL {
        let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documentsDir.appendingPathComponent("BoostCache")
    }

    /// Path to cached manifest
    private var cachedManifestPath: URL {
        boostCacheDirectory.appendingPathComponent("zipherx_boost_manifest.json")
    }

    /// Path to cached boost file
    private var cachedBoostPath: URL {
        boostCacheDirectory.appendingPathComponent("zipherx_boost_v1.bin")
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

        struct ManifestFiles: Codable {
            let uncompressed: FileInfo
        }

        struct FileInfo: Codable {
            let name: String
            let size: Int
            let sha256: String
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
        if let cachedManifest = loadCachedManifest() {
            if FileManager.default.fileExists(atPath: cachedBoostPath.path) {
                // Verify checksum (can be slow for 500MB file, so skip if file size matches)
                let attrs = try? FileManager.default.attributesOfItem(atPath: cachedBoostPath.path)
                let fileSize = attrs?[.size] as? Int ?? 0

                if fileSize == cachedManifest.files.uncompressed.size {
                    print("🚀 Using cached boost file at height \(cachedManifest.chain_height)")
                    onProgress?(1.0, "Using cached data")
                    return (cachedBoostPath, cachedManifest.chain_height, cachedManifest.output_count)
                }
            }
        }

        // Must download from GitHub
        onProgress?(0.05, "Fetching manifest from GitHub...")
        let remoteManifest = try await fetchRemoteManifest()

        print("🚀 Downloading boost file from GitHub (height \(remoteManifest.chain_height))...")
        let fileSizeMB = remoteManifest.files.uncompressed.size / 1024 / 1024
        onProgress?(0.1, "Downloading \(fileSizeMB) MB...")

        try await downloadBoostFile(manifest: remoteManifest) { progress in
            onProgress?(0.1 + progress * 0.85, "Downloading... \(Int(progress * 100))%")
        }

        onProgress?(0.95, "Verifying checksum...")

        // Verify file size (checksum verification is slow for 500MB)
        let attrs = try? FileManager.default.attributesOfItem(atPath: cachedBoostPath.path)
        let fileSize = attrs?[.size] as? Int ?? 0
        guard fileSize == remoteManifest.files.uncompressed.size else {
            try? FileManager.default.removeItem(at: cachedBoostPath)
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

        print("🚀 Successfully downloaded boost file at height \(remoteManifest.chain_height)")
        onProgress?(1.0, "Boost data ready!")

        return (cachedBoostPath, remoteManifest.chain_height, remoteManifest.output_count)
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

        guard FileManager.default.fileExists(atPath: cachedBoostPath.path) else {
            throw BoostFileError.fileNotFound
        }

        // Read just the tree section from the boost file
        let fileHandle = try FileHandle(forReadingFrom: cachedBoostPath)
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

        guard FileManager.default.fileExists(atPath: cachedBoostPath.path) else {
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
        let fileHandle = try FileHandle(forReadingFrom: cachedBoostPath)
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

        guard FileManager.default.fileExists(atPath: cachedBoostPath.path) else {
            throw BoostFileError.fileNotFound
        }

        // Read the outputs section
        let fileHandle = try FileHandle(forReadingFrom: cachedBoostPath)
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

        guard FileManager.default.fileExists(atPath: cachedBoostPath.path) else {
            throw BoostFileError.fileNotFound
        }

        let fileHandle = try FileHandle(forReadingFrom: cachedBoostPath)
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

        guard FileManager.default.fileExists(atPath: cachedBoostPath.path) else {
            throw BoostFileError.fileNotFound
        }

        let fileHandle = try FileHandle(forReadingFrom: cachedBoostPath)
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

        guard FileManager.default.fileExists(atPath: cachedBoostPath.path) else {
            throw BoostFileError.fileNotFound
        }

        let fileHandle = try FileHandle(forReadingFrom: cachedBoostPath)
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

        guard FileManager.default.fileExists(atPath: cachedBoostPath.path) else {
            throw BoostFileError.fileNotFound
        }

        let fileHandle = try FileHandle(forReadingFrom: cachedBoostPath)
        defer { try? fileHandle.close() }

        try fileHandle.seek(toOffset: peerSection.offset)
        guard let data = try fileHandle.read(upToCount: Int(peerSection.size)) else {
            throw BoostFileError.readError
        }

        print("🌐 Extracted peer addresses (\(data.count) bytes)")
        return data
    }

    // MARK: - Cache Status

    /// Check if we have a valid cached boost file
    func hasCachedBoostFile() -> Bool {
        guard let manifest = loadCachedManifest() else { return false }
        guard FileManager.default.fileExists(atPath: cachedBoostPath.path) else { return false }

        let attrs = try? FileManager.default.attributesOfItem(atPath: cachedBoostPath.path)
        let fileSize = attrs?[.size] as? Int ?? 0
        return fileSize == manifest.files.uncompressed.size
    }

    /// Get the cached boost file path if available
    func getCachedBoostFilePath() -> URL? {
        guard hasCachedBoostFile() else { return nil }
        return cachedBoostPath
    }

    /// Get cached manifest info
    func getCachedInfo() -> (height: UInt64, outputCount: UInt64, spendCount: UInt64)? {
        guard let manifest = loadCachedManifest() else { return nil }
        return (manifest.chain_height, manifest.output_count, manifest.spend_count)
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
        let documentsDir = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let boostCachePath = documentsDir.appendingPathComponent("BoostCache")
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

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw BoostFileError.networkError("GitHub API HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }

        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        cachedReleaseInfo = release
        print("📦 Latest release: \(release.tag_name) with \(release.assets.count) assets")
        return release
    }

    private func fetchRemoteManifest() async throws -> BoostManifest {
        // Get latest release from GitHub
        let release = try await fetchLatestRelease()

        // Find manifest asset
        guard let manifestAsset = release.assets.first(where: { $0.name == Self.manifestFileName }) else {
            throw BoostFileError.networkError("Manifest not found in latest release")
        }

        guard let url = URL(string: manifestAsset.browser_download_url) else {
            throw BoostFileError.invalidURL
        }

        let (data, response) = try await URLSession.shared.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw BoostFileError.networkError("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }

        let manifest = try JSONDecoder().decode(BoostManifest.self, from: data)
        return manifest
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

        guard let boostAsset = release.assets.first(where: { $0.name == Self.boostFileName }) else {
            throw BoostFileError.networkError("Boost file '\(Self.boostFileName)' not found in release \(release.tag_name)")
        }

        guard let url = URL(string: boostAsset.browser_download_url) else {
            throw BoostFileError.invalidURL
        }

        print("🚀 Downloading boost file from release \(release.tag_name)")
        print("📥 URL: \(boostAsset.browser_download_url)")
        print("📦 Expected size: \(boostAsset.size) bytes")

        // Create custom session with delegate for progress
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = 3600 // 1 hour timeout for large file

        let delegate = DownloadProgressDelegate { progress in
            onProgress?(progress)
        }

        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)

        let (tempURL, response) = try await session.download(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw BoostFileError.networkError("HTTP \(status) downloading boost file")
        }

        // Move to cache
        if FileManager.default.fileExists(atPath: cachedBoostPath.path) {
            try FileManager.default.removeItem(at: cachedBoostPath)
        }
        try FileManager.default.moveItem(at: tempURL, to: cachedBoostPath)

        print("✅ Downloaded boost file: \(boostAsset.size) bytes")
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
