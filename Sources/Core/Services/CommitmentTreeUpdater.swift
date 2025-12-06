import Foundation
import CommonCrypto

/// Handles checking for and downloading updated commitment trees from GitHub
/// This allows the app to use newer trees without requiring an app update
actor CommitmentTreeUpdater {

    // MARK: - Configuration

    /// GitHub API URL to get latest tree release
    private static let latestReleaseURL = "https://api.github.com/repos/VictorLux/ZipherX_Boost/releases"

    /// Base URL for GitHub raw files (manifest only - other files from releases)
    private static let rawBaseURL = "https://raw.githubusercontent.com/VictorLux/ZipherX_Boost/main"

    /// GitHub raw URL for the manifest file (always from main branch for latest info)
    private static let manifestURL = "\(rawBaseURL)/commitment_tree_manifest.json"

    /// Whether tree updates from GitHub are enabled
    /// Set to false to disable remote tree updates (use bundled only)
    private static let enableRemoteUpdates = true

    /// Cached release tag for downloads
    private var cachedReleaseTag: String?


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

    /// Fetch tree info from GitHub manifest and update ZipherXConstants
    /// Should be called on app startup BEFORE any tree operations
    /// This ensures we always have the latest tree height/count/root from GitHub
    func fetchAndUpdateTreeInfo() async {
        guard Self.enableRemoteUpdates else {
            print("🌲 Remote updates disabled, using cached tree info")
            return
        }

        do {
            print("🌲 Fetching tree manifest from GitHub...")
            let manifest = try await fetchRemoteManifest()

            await MainActor.run {
                ZipherXConstants.updateTreeInfo(
                    height: manifest.height,
                    cmuCount: manifest.cmu_count,
                    root: manifest.tree_root
                )
            }

            print("🌲 Tree info updated from GitHub: height=\(manifest.height), CMUs=\(manifest.cmu_count)")
        } catch {
            print("⚠️ Could not fetch tree manifest from GitHub: \(error.localizedDescription)")
            // App will use cached values from UserDefaults or fallback to Sapling activation
        }
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
                            // Update ZipherXConstants with downloaded tree info
                            await MainActor.run {
                                ZipherXConstants.updateTreeInfo(
                                    height: remoteManifest.height,
                                    cmuCount: remoteManifest.cmu_count,
                                    root: remoteManifest.tree_root
                                )
                            }
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
                // Update ZipherXConstants with downloaded tree info
                await MainActor.run {
                    ZipherXConstants.updateTreeInfo(
                        height: remoteManifest.height,
                        cmuCount: remoteManifest.cmu_count,
                        root: remoteManifest.tree_root
                    )
                }
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
        // Get URL from GitHub Releases
        let urlString = getReleaseDownloadURL(for: "commitment_tree_serialized.bin", height: manifest.height)
        guard let url = URL(string: urlString) else {
            throw TreeUpdaterError.invalidURL
        }

        print("🌲 Downloading serialized tree from: \(urlString)")
        let (data, response) = try await URLSession.shared.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw TreeUpdaterError.networkError("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }

        // Verify checksum BEFORE writing
        if let serializedInfo = manifest.files.serialized {
            let computedHash = sha256(data: data)
            guard computedHash.lowercased() == serializedInfo.sha256.lowercased() else {
                print("🚨 SECURITY: Serialized tree checksum mismatch!")
                print("   Expected: \(serializedInfo.sha256)")
                print("   Got:      \(computedHash)")
                throw TreeUpdaterError.checksumMismatch
            }
            print("✅ Serialized tree checksum verified")
        }

        // Write to cache
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

        // Download the COMPRESSED CMU file from GitHub Releases and decompress
        // This saves bandwidth (compressed is ~10MB vs uncompressed ~33MB)
        let compressedSize = remoteManifest.files.compressed.size
        print("🌲 Downloading compressed CMU file (\(compressedSize / 1024 / 1024) MB)...")
        onProgress?(0.1, "Downloading CMU data...")

        // Get URL from GitHub Releases
        let urlString = getReleaseDownloadURL(for: "commitment_tree.bin.zst", height: remoteManifest.height)
        guard let url = URL(string: urlString) else {
            throw TreeUpdaterError.invalidURL
        }

        print("🌲 Downloading from: \(urlString)")

        // Create a download delegate to track progress
        let delegate = DownloadProgressDelegate { progress in
            onProgress?(0.1 + progress * 0.5, "Downloading... \(Int(progress * 100))%")
        }

        let (tempURL, response) = try await URLSession.shared.download(from: url, delegate: delegate)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw TreeUpdaterError.networkError("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }

        // Move compressed file to cache
        let compressedPath = treeCacheDirectory.appendingPathComponent("commitment_tree.bin.zst")
        if FileManager.default.fileExists(atPath: compressedPath.path) {
            try FileManager.default.removeItem(at: compressedPath)
        }
        try FileManager.default.moveItem(at: tempURL, to: compressedPath)

        onProgress?(0.65, "Verifying compressed checksum...")

        // Verify compressed checksum
        print("🔐 Verifying compressed file checksum...")
        guard verifySHA256(file: compressedPath, expected: remoteManifest.files.compressed.sha256) else {
            print("🚨 SECURITY: Compressed CMU checksum mismatch!")
            try? FileManager.default.removeItem(at: compressedPath)
            throw TreeUpdaterError.checksumMismatch
        }
        print("✅ Compressed CMU checksum verified")

        onProgress?(0.7, "Decompressing...")

        // Decompress
        try decompressZstd(from: compressedPath, to: cachedTreePath)

        // Clean up compressed file
        try? FileManager.default.removeItem(at: compressedPath)

        onProgress?(0.9, "Verifying decompressed checksum...")

        // Verify decompressed checksum
        print("🔐 Verifying decompressed CMU checksum...")
        guard verifySHA256(file: cachedTreePath, expected: remoteManifest.files.uncompressed.sha256) else {
            print("🚨 SECURITY: Decompressed CMU checksum mismatch!")
            try? FileManager.default.removeItem(at: cachedTreePath)
            throw TreeUpdaterError.checksumMismatch
        }
        print("✅ Decompressed CMU checksum verified")

        // Save manifest
        try saveManifest(remoteManifest)

        // Update ZipherXConstants with downloaded tree info
        await MainActor.run {
            ZipherXConstants.updateTreeInfo(
                height: remoteManifest.height,
                cmuCount: remoteManifest.cmu_count,
                root: remoteManifest.tree_root
            )
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

    /// Get the GitHub Releases download URL for a specific file
    /// Files are hosted in releases tagged as "v{height}-tree"
    private func getReleaseDownloadURL(for filename: String, height: UInt64) -> String {
        // GitHub Releases URL format: https://github.com/{owner}/{repo}/releases/download/{tag}/{filename}
        return "https://github.com/VictorLux/ZipherX_Boost/releases/download/v\(height)-tree/\(filename)"
    }

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
        // Get URL from GitHub Releases (compressed file only)
        let urlString = getReleaseDownloadURL(for: "commitment_tree.bin.zst", height: manifest.height)
        guard let url = URL(string: urlString) else {
            throw TreeUpdaterError.invalidURL
        }

        print("🌲 Downloading compressed tree from: \(urlString)")

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

        // Verify compressed file checksum BEFORE decompressing
        print("🔐 Verifying compressed file checksum...")
        guard verifySHA256(file: compressedPath, expected: manifest.files.compressed.sha256) else {
            print("🚨 SECURITY: Compressed tree checksum mismatch!")
            try? FileManager.default.removeItem(at: compressedPath)
            throw TreeUpdaterError.checksumMismatch
        }
        print("✅ Compressed tree checksum verified")

        onProgress?(0.6)

        // Decompress using zstd
        try decompressZstd(from: compressedPath, to: cachedTreePath)

        onProgress?(0.9)

        // Verify decompressed file checksum
        print("🔐 Verifying decompressed file checksum...")
        guard verifySHA256(file: cachedTreePath, expected: manifest.files.uncompressed.sha256) else {
            print("🚨 SECURITY: Decompressed tree checksum mismatch!")
            try? FileManager.default.removeItem(at: cachedTreePath)
            try? FileManager.default.removeItem(at: compressedPath)
            throw TreeUpdaterError.checksumMismatch
        }
        print("✅ Decompressed tree checksum verified")

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
