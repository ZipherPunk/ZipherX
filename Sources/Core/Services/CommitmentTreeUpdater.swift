import Foundation
import CommonCrypto

/// Handles checking for and downloading updated commitment trees from GitHub
/// This allows the app to use newer trees without requiring an app update
actor CommitmentTreeUpdater {

    // MARK: - Configuration

    /// GitHub raw URL for the manifest file (PUBLIC repo - no auth needed)
    private static let manifestURL = "https://raw.githubusercontent.com/VictorLux/ZipherX_Boost/main/commitment_tree_manifest.json"

    /// GitHub raw URL for the serialized tree file (tiny ~500 bytes, instant load)
    private static let serializedTreeURL = "https://raw.githubusercontent.com/VictorLux/ZipherX_Boost/main/commitment_tree_serialized.bin"

    /// GitHub raw URL for the compressed tree file (fallback if serialized not available)
    private static let compressedTreeURL = "https://raw.githubusercontent.com/VictorLux/ZipherX_Boost/main/commitment_tree.bin.zst"

    /// GitHub raw URL for the uncompressed CMU file (needed for imported wallets - position lookups)
    /// This is a large file (~33MB) but required for nullifier computation on imported wallets
    private static let cmuFileURL = "https://raw.githubusercontent.com/VictorLux/ZipherX_Boost/main/commitment_tree.bin"

    /// Whether tree updates from GitHub are enabled
    /// Set to false to disable remote tree updates (use bundled only)
    private static let enableRemoteUpdates = true


    /// Local directory for downloaded trees
    private var treeCacheDirectory: URL {
        let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documentsDir.appendingPathComponent("TreeCache")
    }

    /// Path to cached manifest
    private var cachedManifestPath: URL {
        treeCacheDirectory.appendingPathComponent("manifest.json")
    }

    /// Path to cached uncompressed tree
    private var cachedTreePath: URL {
        treeCacheDirectory.appendingPathComponent("commitment_tree.bin")
    }

    /// Path to cached serialized tree (preferred - tiny ~500 bytes)
    private var cachedSerializedTreePath: URL {
        treeCacheDirectory.appendingPathComponent("commitment_tree_serialized.bin")
    }

    // MARK: - Manifest Model

    struct TreeManifest: Codable {
        let version: Int
        let created_at: String
        let height: UInt64
        let cmu_count: UInt64
        let block_hash: String
        let tree_root: String
        let files: ManifestFiles

        struct ManifestFiles: Codable {
            let uncompressed: FileInfo
            let compressed: FileInfo
            let serialized: FileInfo?  // Optional: instant-load serialized tree (~500 bytes)
        }

        struct FileInfo: Codable {
            let name: String
            let size: Int
            let sha256: String
        }
    }

    // MARK: - Public Interface

    static let shared = CommitmentTreeUpdater()

    private init() {
        // Ensure cache directory exists
        try? FileManager.default.createDirectory(at: treeCacheDirectory, withIntermediateDirectories: true)
    }

    /// Check if a newer tree is available and download it if so
    /// Returns the path to the best available tree (downloaded or bundled)
    /// - Parameter onProgress: Progress callback (0.0 to 1.0, status message)
    /// - Returns: Tuple of (treePath, height, cmuCount) for the best available tree
    func getBestAvailableTree(onProgress: ((Double, String) -> Void)? = nil) async throws -> (URL, UInt64, UInt64) {
        // Get bundled tree info
        let bundledHeight = ZipherXConstants.bundledTreeHeight
        let bundledCMUCount = ZipherXConstants.bundledTreeCMUCount

        guard let bundledTreeURL = Bundle.main.url(forResource: "commitment_tree", withExtension: "bin") else {
            throw TreeUpdaterError.bundledTreeNotFound
        }

        onProgress?(0.0, "Checking for tree updates...")

        // Skip remote updates if disabled
        guard Self.enableRemoteUpdates else {
            print("🌲 Remote tree updates disabled, using bundled tree")
            onProgress?(1.0, "Using bundled tree")
            return (bundledTreeURL, bundledHeight, bundledCMUCount)
        }

        // Check for cached SERIALIZED tree first (preferred - instant load)
        if let cachedManifest = loadCachedManifest() {
            if cachedManifest.height > bundledHeight {
                // Check serialized tree first (tiny, instant load)
                if let serializedInfo = cachedManifest.files.serialized,
                   FileManager.default.fileExists(atPath: cachedSerializedTreePath.path),
                   verifySHA256(file: cachedSerializedTreePath, expected: serializedInfo.sha256) {
                    print("🌲 Using cached serialized tree at height \(cachedManifest.height)")
                    onProgress?(1.0, "Using cached tree")
                    return (cachedSerializedTreePath, cachedManifest.height, cachedManifest.cmu_count)
                }

                // Fallback to full tree cache
                if FileManager.default.fileExists(atPath: cachedTreePath.path),
                   verifySHA256(file: cachedTreePath, expected: cachedManifest.files.uncompressed.sha256) {
                    print("🌲 Using cached tree at height \(cachedManifest.height)")
                    onProgress?(1.0, "Using cached tree")
                    return (cachedTreePath, cachedManifest.height, cachedManifest.cmu_count)
                }
            }
        }

        // Try to fetch remote manifest
        do {
            onProgress?(0.1, "Checking GitHub for updates...")
            let remoteManifest = try await fetchRemoteManifest()

            if remoteManifest.height > bundledHeight {
                // Newer tree available!
                print("🌲 Newer tree available on GitHub: \(remoteManifest.height) vs bundled \(bundledHeight)")

                // PREFER serialized tree (tiny ~500 bytes, instant download)
                if let serializedInfo = remoteManifest.files.serialized {
                    print("🌲 Downloading serialized tree (\(serializedInfo.size) bytes)...")
                    onProgress?(0.2, "Downloading tree update...")

                    do {
                        try await downloadSerializedTree(manifest: remoteManifest)
                        onProgress?(0.9, "Verifying...")

                        if verifySHA256(file: cachedSerializedTreePath, expected: serializedInfo.sha256) {
                            try saveManifest(remoteManifest)
                            print("🌲 Successfully downloaded serialized tree at height \(remoteManifest.height)")
                            onProgress?(1.0, "Tree updated!")
                            return (cachedSerializedTreePath, remoteManifest.height, remoteManifest.cmu_count)
                        } else {
                            print("⚠️ Serialized tree checksum mismatch, trying full tree...")
                        }
                    } catch {
                        print("⚠️ Serialized tree download failed: \(error), trying full tree...")
                    }
                }

                // Fallback: download full tree (33MB compressed)
                print("🌲 Downloading full tree...")
                onProgress?(0.2, "Downloading full tree...")
                try await downloadAndDecompressTree(manifest: remoteManifest, onProgress: { progress in
                    onProgress?(0.2 + progress * 0.7, "Downloading... \(Int(progress * 100))%")
                })

                onProgress?(0.9, "Verifying checksum...")
                guard verifySHA256(file: cachedTreePath, expected: remoteManifest.files.uncompressed.sha256) else {
                    throw TreeUpdaterError.checksumMismatch
                }

                try saveManifest(remoteManifest)
                print("🌲 Successfully downloaded tree at height \(remoteManifest.height)")
                onProgress?(1.0, "Tree updated!")
                return (cachedTreePath, remoteManifest.height, remoteManifest.cmu_count)
            } else {
                print("🌲 Bundled tree is current or newer")
            }
        } catch {
            print("⚠️ Could not check for tree updates: \(error.localizedDescription)")
            // Fall through to use bundled tree
        }

        // Use bundled tree
        onProgress?(1.0, "Using bundled tree")
        return (bundledTreeURL, bundledHeight, bundledCMUCount)
    }

    /// Download the serialized tree (tiny ~500 bytes, instant)
    private func downloadSerializedTree(manifest: TreeManifest) async throws {
        guard let url = URL(string: Self.serializedTreeURL) else {
            throw TreeUpdaterError.invalidURL
        }

        let (data, response) = try await URLSession.shared.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw TreeUpdaterError.networkError("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }

        // Write directly to cache
        try data.write(to: cachedSerializedTreePath)
        print("🌲 Downloaded serialized tree: \(data.count) bytes")
    }

    /// Clear the cached tree (useful for debugging or if cache becomes corrupted)
    func clearCache() throws {
        if FileManager.default.fileExists(atPath: treeCacheDirectory.path) {
            try FileManager.default.removeItem(at: treeCacheDirectory)
            try FileManager.default.createDirectory(at: treeCacheDirectory, withIntermediateDirectories: true)
        }
        print("🌲 Tree cache cleared")
    }

    // MARK: - CMU File Access (for imported wallets)

    /// Get CMU file for imported wallet position lookups
    /// This downloads the full 33MB CMU file from GitHub if a newer version is available
    /// Returns: (cmuFilePath, height, cmuCount) or nil if using bundled only
    ///
    /// IMPORTANT: This is needed for imported wallets because:
    /// 1. The serialized tree (~574 bytes) only contains the tree frontier (final state)
    /// 2. Imported wallets need to find CMU positions for notes within the tree range
    /// 3. Position lookup requires the full list of CMUs in blockchain order
    func getCMUFileForImportedWallet(onProgress: ((Double, String) -> Void)? = nil) async throws -> (URL, UInt64, UInt64)? {
        guard Self.enableRemoteUpdates else {
            print("🌲 Remote updates disabled, using bundled CMU file")
            return nil  // Caller should use bundled tree
        }

        // Check for cached CMU file first
        if let cachedManifest = loadCachedManifest() {
            if FileManager.default.fileExists(atPath: cachedTreePath.path),
               verifySHA256(file: cachedTreePath, expected: cachedManifest.files.uncompressed.sha256) {
                print("🌲 Using cached CMU file at height \(cachedManifest.height)")
                return (cachedTreePath, cachedManifest.height, cachedManifest.cmu_count)
            }
        }

        // Try to fetch remote manifest
        onProgress?(0.0, "Checking for updated CMU data...")
        let remoteManifest: TreeManifest
        do {
            remoteManifest = try await fetchRemoteManifest()
        } catch {
            print("⚠️ Could not fetch manifest: \(error)")
            return nil
        }

        // Check if remote is newer than bundled
        let bundledHeight = ZipherXConstants.bundledTreeHeight
        if remoteManifest.height <= bundledHeight {
            print("🌲 Bundled CMU file is current, no download needed")
            return nil  // Use bundled
        }

        // Download the uncompressed CMU file (33MB) directly
        // Note: We download uncompressed because iOS cannot decompress zstd
        print("🌲 Downloading CMU file (\(remoteManifest.files.uncompressed.size / 1024 / 1024) MB)...")
        onProgress?(0.1, "Downloading CMU data...")

        guard let url = URL(string: Self.cmuFileURL) else {
            throw TreeUpdaterError.invalidURL
        }

        // Create a download delegate to track progress
        let delegate = DownloadProgressDelegate { progress in
            onProgress?(0.1 + progress * 0.8, "Downloading... \(Int(progress * 100))%")
        }

        let (tempURL, response) = try await URLSession.shared.download(from: url, delegate: delegate)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw TreeUpdaterError.networkError("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }

        // Move to cache
        if FileManager.default.fileExists(atPath: cachedTreePath.path) {
            try FileManager.default.removeItem(at: cachedTreePath)
        }
        try FileManager.default.moveItem(at: tempURL, to: cachedTreePath)

        onProgress?(0.9, "Verifying checksum...")

        // Verify checksum
        guard verifySHA256(file: cachedTreePath, expected: remoteManifest.files.uncompressed.sha256) else {
            try? FileManager.default.removeItem(at: cachedTreePath)
            throw TreeUpdaterError.checksumMismatch
        }

        // Save manifest
        try saveManifest(remoteManifest)

        // Update UserDefaults for effective tree height (used by ZipherXConstants)
        await MainActor.run {
            UserDefaults.standard.set(Int(remoteManifest.height), forKey: "effectiveTreeHeight")
            UserDefaults.standard.set(Int(remoteManifest.cmu_count), forKey: "effectiveTreeCMUCount")
        }

        print("🌲 Downloaded CMU file at height \(remoteManifest.height) with \(remoteManifest.cmu_count) CMUs")
        onProgress?(1.0, "CMU data ready!")

        return (cachedTreePath, remoteManifest.height, remoteManifest.cmu_count)
    }

    /// Check if we have a cached CMU file that's newer than bundled
    func hasCachedCMUFile() -> Bool {
        guard let manifest = loadCachedManifest() else { return false }
        guard FileManager.default.fileExists(atPath: cachedTreePath.path) else { return false }
        return manifest.height > ZipherXConstants.bundledTreeHeight
    }

    /// Get the cached CMU file path if available and valid
    func getCachedCMUFilePath() -> URL? {
        guard let manifest = loadCachedManifest(),
              manifest.height > ZipherXConstants.bundledTreeHeight,
              FileManager.default.fileExists(atPath: cachedTreePath.path),
              verifySHA256(file: cachedTreePath, expected: manifest.files.uncompressed.sha256) else {
            return nil
        }
        return cachedTreePath
    }

    /// Get the height and CMU count of the cached tree (if available)
    func getCachedTreeInfo() -> (height: UInt64, cmuCount: UInt64)? {
        guard let manifest = loadCachedManifest() else { return nil }
        return (manifest.height, manifest.cmu_count)
    }

    // MARK: - Private Methods

    private func fetchRemoteManifest() async throws -> TreeManifest {
        guard let url = URL(string: Self.manifestURL) else {
            throw TreeUpdaterError.invalidURL
        }

        let (data, response) = try await URLSession.shared.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw TreeUpdaterError.networkError("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }

        let manifest = try JSONDecoder().decode(TreeManifest.self, from: data)
        return manifest
    }

    private func loadCachedManifest() -> TreeManifest? {
        guard FileManager.default.fileExists(atPath: cachedManifestPath.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: cachedManifestPath)
            return try JSONDecoder().decode(TreeManifest.self, from: data)
        } catch {
            print("⚠️ Failed to load cached manifest: \(error)")
            return nil
        }
    }

    private func saveManifest(_ manifest: TreeManifest) throws {
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: cachedManifestPath)
    }

    private func downloadAndDecompressTree(manifest: TreeManifest, onProgress: ((Double) -> Void)?) async throws {
        guard let url = URL(string: Self.compressedTreeURL) else {
            throw TreeUpdaterError.invalidURL
        }

        // Download compressed file
        let compressedPath = treeCacheDirectory.appendingPathComponent("commitment_tree.bin.zst")

        // Use URLSession with delegate for progress tracking
        let (tempURL, response) = try await URLSession.shared.download(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw TreeUpdaterError.networkError("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }

        // Move to our cache directory
        if FileManager.default.fileExists(atPath: compressedPath.path) {
            try FileManager.default.removeItem(at: compressedPath)
        }
        try FileManager.default.moveItem(at: tempURL, to: compressedPath)

        onProgress?(0.5)

        // Verify compressed file checksum
        guard verifySHA256(file: compressedPath, expected: manifest.files.compressed.sha256) else {
            try? FileManager.default.removeItem(at: compressedPath)
            throw TreeUpdaterError.checksumMismatch
        }

        onProgress?(0.6)

        // Decompress using zstd
        try decompressZstd(from: compressedPath, to: cachedTreePath)

        onProgress?(1.0)

        // Clean up compressed file
        try? FileManager.default.removeItem(at: compressedPath)
    }

    private func decompressZstd(from source: URL, to destination: URL) throws {
        // Remove existing destination
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }

        #if os(macOS)
        // On macOS, try to use zstd command line tool
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["zstd", "-d", source.path, "-o", destination.path, "-f"]

        let pipe = Pipe()
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                return
            }
        } catch {
            print("⚠️ zstd command failed: \(error)")
        }

        // Fallback: Try using libcompression if zstd not available
        throw TreeUpdaterError.decompressionFailed("zstd not available - install with: brew install zstd")
        #else
        // On iOS, we need to use a different approach
        // iOS doesn't have command-line zstd, so we'll need to bundle a decompressor
        // or use a different compression format

        // For now, try using the compression framework with a compatible algorithm
        // Note: iOS doesn't natively support zstd, so we may need to include a library

        throw TreeUpdaterError.decompressionFailed("zstd decompression not available on iOS - tree updates disabled")
        #endif
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

enum TreeUpdaterError: LocalizedError {
    case bundledTreeNotFound
    case invalidURL
    case networkError(String)
    case checksumMismatch
    case decompressionFailed(String)

    var errorDescription: String? {
        switch self {
        case .bundledTreeNotFound:
            return "Bundled commitment tree not found in app bundle"
        case .invalidURL:
            return "Invalid URL for tree download"
        case .networkError(let details):
            return "Network error: \(details)"
        case .checksumMismatch:
            return "Downloaded file checksum does not match expected value"
        case .decompressionFailed(let details):
            return "Failed to decompress tree: \(details)"
        }
    }
}

// MARK: - Download Progress Delegate

/// URLSession delegate for tracking download progress
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
        // This is handled by the async/await pattern - no action needed here
    }
}
