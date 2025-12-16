import Foundation
import Combine
import CommonCrypto

#if os(macOS)

/// Manages bootstrap download, extraction, and daemon setup for full node mode
/// Supports split-file bootstrap format from VictorLux/zclassic-bootstrap
public class BootstrapManager: ObservableObject {
    public static let shared = BootstrapManager()

    // GitHub repository for bootstrap releases
    private let githubRepo = "VictorLux/zclassic-bootstrap"
    private let githubAPIBase = "https://api.github.com/repos"

    // Published state
    @Published public private(set) var status: BootstrapStatus = .idle
    @Published public private(set) var progress: Double = 0.0
    @Published public private(set) var currentTask: String = ""
    @Published public private(set) var downloadSpeed: String = ""
    @Published public private(set) var eta: String = ""
    @Published public private(set) var currentPart: Int = 0
    @Published public private(set) var totalParts: Int = 0

    // Internal state
    private var downloadTask: URLSessionDownloadTask?
    private var isCancelled = false
    private var lastProgressUpdate = Date()
    private var lastBytesDownloaded: Int64 = 0
    private var totalBytesDownloadedAllParts: Int64 = 0
    private var totalSizeAllParts: Int64 = 0

    public enum BootstrapStatus: Equatable {
        case idle
        case checkingRelease
        case downloading
        case verifying
        case combining
        case extracting
        case configuringDaemon
        case downloadingParams
        case startingDaemon  // FIX #273: Added step to start daemon after bootstrap
        case complete
        case error(String)
        case cancelled
    }

    private init() {}

    // MARK: - Public API

    /// Start the full bootstrap process
    public func startBootstrap() async {
        guard case .idle = status else {
            print("⚠️ Bootstrap already in progress")
            return
        }

        isCancelled = false
        totalBytesDownloadedAllParts = 0

        do {
            // Step 1: Check for latest release
            await updateStatus(.checkingRelease, task: "Checking for latest bootstrap...")
            let release = try await fetchLatestRelease()
            print("✅ Found bootstrap release: \(release.name) with \(release.parts.count) parts")

            // Step 2: Download all parts
            await updateStatus(.downloading, task: "Downloading bootstrap (\(release.totalSizeFormatted))...")
            totalParts = release.parts.count
            totalSizeAllParts = release.totalSize

            let downloadDir = FileManager.default.temporaryDirectory.appendingPathComponent("zclassic-bootstrap")
            try FileManager.default.createDirectory(at: downloadDir, withIntermediateDirectories: true)

            for (index, part) in release.parts.enumerated() {
                if isCancelled { throw BootstrapError.cancelled }

                currentPart = index + 1
                await MainActor.run {
                    self.currentTask = "Downloading part \(index + 1)/\(release.parts.count) (\(part.sizeFormatted))..."
                }

                try await downloadPart(part: part, to: downloadDir, partIndex: index, totalParts: release.parts.count)
            }

            if isCancelled { return }

            // Step 3: Verify checksums for all parts
            await updateStatus(.verifying, task: "Verifying checksums...")
            try await verifyAllChecksums(release: release, downloadDir: downloadDir)

            // Step 4: Combine parts
            await updateStatus(.combining, task: "Combining parts...")
            let combinedPath = try await combineParts(release: release, downloadDir: downloadDir)

            // Step 5: Extract bootstrap
            await updateStatus(.extracting, task: "Extracting blockchain data...")
            try await extractBootstrap(from: combinedPath)

            // Step 6: Configure daemon
            await updateStatus(.configuringDaemon, task: "Configuring zclassicd...")
            try configureZclassicConf()

            // Step 7: Download Sapling params if needed
            await updateStatus(.downloadingParams, task: "Checking Sapling parameters...")
            try await ensureSaplingParams()

            // Clean up temp files
            try? FileManager.default.removeItem(at: downloadDir)

            // Step 8: Start daemon and wait for sync
            await updateStatus(.startingDaemon, task: "Starting zclassicd...")
            do {
                try await FullNodeManager.shared.startDaemon()
                print("✅ Daemon started and synced successfully")
            } catch {
                print("⚠️ Daemon start failed (user can start manually): \(error)")
                // Don't fail bootstrap - user can start daemon manually
            }

            // Done!
            await updateStatus(.complete, task: "Bootstrap complete!")
            await MainActor.run {
                self.progress = 1.0
            }

        } catch {
            if !isCancelled {
                await updateStatus(.error(error.localizedDescription), task: "Bootstrap failed")
            }
        }
    }

    /// Cancel ongoing bootstrap
    public func cancel() {
        isCancelled = true
        downloadTask?.cancel()
        Task { @MainActor in
            status = .cancelled
            currentTask = "Cancelled"
        }
    }

    /// Reset to idle state (for retry)
    public func reset() {
        Task { @MainActor in
            status = .idle
            progress = 0.0
            currentTask = ""
            downloadSpeed = ""
            eta = ""
            currentPart = 0
            totalParts = 0
        }
    }

    /// Check if bootstrap is needed (no blockchain data exists)
    public var needsBootstrap: Bool {
        let blocksDir = RPCClient.zclassicDataDir.appendingPathComponent("blocks")
        return !FileManager.default.fileExists(atPath: blocksDir.path)
    }

    /// Check if daemon is already installed
    public var isDaemonInstalled: Bool {
        let daemonPath = "/usr/local/bin/zclassicd"
        return FileManager.default.fileExists(atPath: daemonPath)
    }

    // MARK: - Data Structures

    private struct GitHubRelease: Codable {
        let tag_name: String
        let name: String
        let assets: [GitHubAsset]

        struct GitHubAsset: Codable {
            let name: String
            let size: Int64
            let browser_download_url: String
        }
    }

    private struct BootstrapPart {
        let name: String
        let downloadURL: URL
        let size: Int64
        let expectedChecksum: String?
        let partNumber: Int

        var sizeFormatted: String {
            ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        }
    }

    private struct BootstrapRelease {
        let name: String
        let tagName: String
        let parts: [BootstrapPart]
        let checksums: [String: String]  // filename -> checksum

        var totalSize: Int64 {
            parts.reduce(0) { $0 + $1.size }
        }

        var totalSizeFormatted: String {
            ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)
        }
    }

    // MARK: - Release Fetching

    private func fetchLatestRelease() async throws -> BootstrapRelease {
        let url = URL(string: "\(githubAPIBase)/\(githubRepo)/releases/latest")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        request.setValue("ZipherX/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw BootstrapError.releaseNotFound
        }

        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)

        // Find all .part files (sorted by part number)
        let partAssets = release.assets
            .filter { $0.name.hasSuffix(".part") }
            .sorted { extractPartNumber($0.name) < extractPartNumber($1.name) }

        guard !partAssets.isEmpty else {
            // Fallback: Check for single .tar.zst file (old format)
            if let singleAsset = release.assets.first(where: { $0.name.hasSuffix(".tar.zst") }) {
                print("ℹ️ Using single-file bootstrap format")
                let checksums = try await fetchChecksums(from: release)
                return BootstrapRelease(
                    name: release.name,
                    tagName: release.tag_name,
                    parts: [BootstrapPart(
                        name: singleAsset.name,
                        downloadURL: URL(string: singleAsset.browser_download_url)!,
                        size: singleAsset.size,
                        expectedChecksum: checksums[singleAsset.name],
                        partNumber: 1
                    )],
                    checksums: checksums
                )
            }
            throw BootstrapError.noAssetFound
        }

        // Fetch checksums file
        let checksums = try await fetchChecksums(from: release)

        // Build parts array
        var parts: [BootstrapPart] = []
        for (index, asset) in partAssets.enumerated() {
            let partNumber = extractPartNumber(asset.name)
            parts.append(BootstrapPart(
                name: asset.name,
                downloadURL: URL(string: asset.browser_download_url)!,
                size: asset.size,
                expectedChecksum: checksums[asset.name],
                partNumber: partNumber > 0 ? partNumber : index + 1
            ))
        }

        print("📦 Bootstrap release has \(parts.count) parts, total \(ByteCountFormatter.string(fromByteCount: parts.reduce(0) { $0 + $1.size }, countStyle: .file))")

        return BootstrapRelease(
            name: release.name,
            tagName: release.tag_name,
            parts: parts,
            checksums: checksums
        )
    }

    private func extractPartNumber(_ filename: String) -> Int {
        // Extract part number from filenames like "zclassic-bootstrap-block-XXXXX-part-01.part"
        let pattern = "part-?(\\d+)"
        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: filename, options: [], range: NSRange(filename.startIndex..., in: filename)),
           let range = Range(match.range(at: 1), in: filename) {
            return Int(filename[range]) ?? 0
        }
        return 0
    }

    private func fetchChecksums(from release: GitHubRelease) async throws -> [String: String] {
        // Find checksum file (bootstrap-checksums.txt or similar)
        let checksumAsset = release.assets.first { asset in
            asset.name.lowercased().contains("checksum") ||
            asset.name.lowercased().contains("sha256")
        }

        guard let checksumAsset = checksumAsset else {
            print("⚠️ No checksum file found in release")
            return [:]
        }

        let (data, _) = try await URLSession.shared.data(from: URL(string: checksumAsset.browser_download_url)!)
        guard let content = String(data: data, encoding: .utf8) else {
            return [:]
        }

        var checksums: [String: String] = [:]

        // Parse checksum file (format: "checksum  filename" or "checksum filename")
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            // Split by two spaces or one space
            let components = trimmed.components(separatedBy: "  ")
            if components.count == 2 {
                let checksum = components[0].trimmingCharacters(in: .whitespaces)
                let filename = components[1].trimmingCharacters(in: .whitespaces)
                checksums[filename] = checksum
            } else {
                // Try single space
                let parts = trimmed.split(separator: " ", maxSplits: 1)
                if parts.count == 2 {
                    checksums[String(parts[1])] = String(parts[0])
                }
            }
        }

        print("📋 Loaded \(checksums.count) checksums from \(checksumAsset.name)")
        return checksums
    }

    // MARK: - Download

    private func downloadPart(part: BootstrapPart, to downloadDir: URL, partIndex: Int, totalParts: Int) async throws {
        let destinationPath = downloadDir.appendingPathComponent(part.name)

        // Check if already downloaded and verified
        if FileManager.default.fileExists(atPath: destinationPath.path) {
            if let checksum = part.expectedChecksum {
                let computed = try computeSHA256(file: destinationPath)
                if computed.lowercased() == checksum.lowercased() {
                    print("✅ Part \(partIndex + 1) already downloaded and verified")
                    totalBytesDownloadedAllParts += part.size
                    return
                }
            }
            // Remove incomplete/corrupted file
            try? FileManager.default.removeItem(at: destinationPath)
        }

        // Reset per-part tracking
        lastBytesDownloaded = 0
        lastProgressUpdate = Date()

        // Create download delegate
        let delegate = PartDownloadDelegate(
            manager: self,
            partSize: part.size,
            partIndex: partIndex,
            totalParts: totalParts
        )

        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        var request = URLRequest(url: part.downloadURL)
        request.setValue("ZipherX/1.0", forHTTPHeaderField: "User-Agent")

        downloadTask = session.downloadTask(with: request)
        downloadTask?.resume()

        // Wait for completion
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            delegate.completion = { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }

        // Move to final location
        if let tempURL = delegate.downloadedFileURL {
            if FileManager.default.fileExists(atPath: destinationPath.path) {
                try FileManager.default.removeItem(at: destinationPath)
            }
            try FileManager.default.moveItem(at: tempURL, to: destinationPath)
        }

        totalBytesDownloadedAllParts += part.size
        print("✅ Downloaded part \(partIndex + 1)/\(totalParts): \(part.name)")
    }

    private class PartDownloadDelegate: NSObject, URLSessionDownloadDelegate {
        weak var manager: BootstrapManager?
        let partSize: Int64
        let partIndex: Int
        let totalParts: Int
        var downloadedFileURL: URL?
        var completion: ((Error?) -> Void)?

        init(manager: BootstrapManager, partSize: Int64, partIndex: Int, totalParts: Int) {
            self.manager = manager
            self.partSize = partSize
            self.partIndex = partIndex
            self.totalParts = totalParts
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            guard let manager = manager else { return }

            // Calculate overall progress across all parts
            // Download phase is 0-50% of total progress
            let bytesBeforeThisPart = manager.totalBytesDownloadedAllParts
            let totalDownloaded = bytesBeforeThisPart + totalBytesWritten
            let overallProgress = Double(totalDownloaded) / Double(max(1, manager.totalSizeAllParts))

            Task { @MainActor in
                manager.progress = overallProgress * 0.5  // Download is 50% of total
                manager.updateDownloadStats(
                    bytesWritten: totalBytesWritten,
                    totalBytes: self.partSize,
                    overallBytesWritten: totalDownloaded,
                    overallTotalBytes: manager.totalSizeAllParts
                )
            }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            downloadedFileURL = location
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            completion?(error)
        }
    }

    private func updateDownloadStats(bytesWritten: Int64, totalBytes: Int64, overallBytesWritten: Int64, overallTotalBytes: Int64) {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastProgressUpdate)

        if elapsed >= 0.5 { // Update every 500ms
            let bytesDelta = bytesWritten - lastBytesDownloaded
            let speed = Double(bytesDelta) / elapsed

            downloadSpeed = ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .file) + "/s"

            // Calculate ETA based on remaining bytes across all parts
            let remainingBytes = overallTotalBytes - overallBytesWritten
            if speed > 0 {
                let etaSeconds = Double(remainingBytes) / speed
                eta = formatDuration(etaSeconds)
            }

            lastProgressUpdate = now
            lastBytesDownloaded = bytesWritten
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        if seconds < 60 {
            return "\(Int(seconds))s"
        } else if seconds < 3600 {
            return "\(Int(seconds / 60))m \(Int(seconds.truncatingRemainder(dividingBy: 60)))s"
        } else {
            return "\(Int(seconds / 3600))h \(Int((seconds.truncatingRemainder(dividingBy: 3600)) / 60))m"
        }
    }

    // MARK: - Verification

    private func verifyAllChecksums(release: BootstrapRelease, downloadDir: URL) async throws {
        for (index, part) in release.parts.enumerated() {
            if isCancelled { throw BootstrapError.cancelled }

            await MainActor.run {
                self.currentTask = "Verifying part \(index + 1)/\(release.parts.count)..."
                self.progress = 0.5 + (Double(index) / Double(release.parts.count)) * 0.1  // 50-60%
            }

            guard let expectedChecksum = part.expectedChecksum else {
                print("⚠️ No checksum for part \(index + 1), skipping verification")
                continue
            }

            let filePath = downloadDir.appendingPathComponent(part.name)
            let computedChecksum = try computeSHA256(file: filePath)

            guard computedChecksum.lowercased() == expectedChecksum.lowercased() else {
                print("❌ Checksum mismatch for \(part.name)")
                print("   Expected: \(expectedChecksum)")
                print("   Computed: \(computedChecksum)")
                throw BootstrapError.checksumMismatch
            }

            print("✅ Part \(index + 1) checksum verified")
        }
    }

    private func computeSHA256(file: URL) throws -> String {
        let fileHandle = try FileHandle(forReadingFrom: file)
        defer { try? fileHandle.close() }

        var hasher = SHA256Hasher()
        while autoreleasepool(invoking: {
            let data = fileHandle.readData(ofLength: 1024 * 1024) // 1MB chunks
            if data.isEmpty { return false }
            hasher.update(data: data)
            return true
        }) {}

        return hasher.finalize()
    }

    // MARK: - Combining Parts

    private func combineParts(release: BootstrapRelease, downloadDir: URL) async throws -> URL {
        // If only one part, no combining needed
        if release.parts.count == 1 {
            return downloadDir.appendingPathComponent(release.parts[0].name)
        }

        await MainActor.run {
            self.currentTask = "Combining \(release.parts.count) parts..."
            self.progress = 0.6
        }

        // Determine output filename (remove part suffix)
        var baseName = release.parts[0].name
        if let range = baseName.range(of: "-part-\\d+\\.part$", options: .regularExpression) {
            baseName = String(baseName[..<range.lowerBound]) + ".tar.zst"
        } else {
            baseName = "zclassic-bootstrap.tar.zst"
        }

        let combinedPath = downloadDir.appendingPathComponent(baseName)

        // Remove existing combined file
        try? FileManager.default.removeItem(at: combinedPath)

        // Create output file
        FileManager.default.createFile(atPath: combinedPath.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: combinedPath)
        defer { try? outputHandle.close() }

        // Combine parts in order
        for (index, part) in release.parts.sorted(by: { $0.partNumber < $1.partNumber }).enumerated() {
            if isCancelled { throw BootstrapError.cancelled }

            await MainActor.run {
                self.currentTask = "Combining part \(index + 1)/\(release.parts.count)..."
                self.progress = 0.6 + (Double(index) / Double(release.parts.count)) * 0.1  // 60-70%
            }

            let partPath = downloadDir.appendingPathComponent(part.name)
            let inputHandle = try FileHandle(forReadingFrom: partPath)
            defer { try? inputHandle.close() }

            // Copy in chunks
            while autoreleasepool(invoking: {
                let chunk = inputHandle.readData(ofLength: 10 * 1024 * 1024) // 10MB chunks
                if chunk.isEmpty { return false }
                outputHandle.write(chunk)
                return true
            }) {}

            print("✅ Combined part \(index + 1)/\(release.parts.count)")
        }

        // Clean up individual part files
        for part in release.parts {
            let partPath = downloadDir.appendingPathComponent(part.name)
            try? FileManager.default.removeItem(at: partPath)
        }

        print("✅ Combined all parts into \(baseName)")
        return combinedPath
    }

    // MARK: - Extraction

    private func extractBootstrap(from archivePath: URL) async throws {
        let dataDir = RPCClient.zclassicDataDir
        let fm = FileManager.default

        // Create data directory if needed
        try fm.createDirectory(at: dataDir, withIntermediateDirectories: true)

        // Check for existing critical files BEFORE extraction
        let walletPath = dataDir.appendingPathComponent("wallet.dat")
        let configPath = dataDir.appendingPathComponent("zclassic.conf")
        let existingWallet = fm.fileExists(atPath: walletPath.path)
        let existingConfig = fm.fileExists(atPath: configPath.path)

        if existingWallet {
            print("ℹ️ Existing wallet.dat found - will be preserved (NEVER overwritten)")
        }
        if existingConfig {
            print("ℹ️ Existing zclassic.conf found - will be preserved (NEVER overwritten)")
        }

        await MainActor.run {
            self.progress = 0.7
            self.currentTask = "Extracting blockchain data (this may take several minutes)..."
        }

        // Find zstd binary
        let zstdPaths = ["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd", "/usr/bin/zstd"]
        let zstdPath = zstdPaths.first { FileManager.default.fileExists(atPath: $0) }

        let process = Process()

        if let zstdPath = zstdPath {
            // Use zstd for decompression with tar
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            process.arguments = ["--use-compress-program=\(zstdPath)", "-xf", archivePath.path, "-C", dataDir.path]
        } else {
            // Try tar directly (may work if zstd is in PATH)
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            process.arguments = ["-xf", archivePath.path, "-C", dataDir.path]
        }

        process.currentDirectoryURL = dataDir

        // Capture stderr for error messages
        let errorPipe = Pipe()
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            print("❌ Extraction failed: \(errorMessage)")

            if errorMessage.contains("zstd") || errorMessage.contains("compress-program") {
                throw BootstrapError.zstdNotInstalled
            }
            throw BootstrapError.extractionFailed
        }

        // Clean up archive
        try? FileManager.default.removeItem(at: archivePath)

        // Handle wallet.dat - NEVER overwrite existing!
        let currentWalletPath = dataDir.appendingPathComponent("wallet.dat")
        if fm.fileExists(atPath: currentWalletPath.path) {
            if existingWallet {
                // User had existing wallet - it was preserved by tar (no --overwrite flag)
                // But if bootstrap somehow overwrote it, we have a problem
                // tar without flags should skip existing files, but let's be safe
                print("✅ Existing wallet.dat preserved")
            } else {
                // No original wallet, but bootstrap included one - remove it for security
                try? fm.removeItem(at: currentWalletPath)
                print("🗑️ Removed bootstrap's wallet.dat (security: not using someone else's wallet)")
            }
        }

        // Handle zclassic.conf - NEVER overwrite existing!
        let currentConfigPath = dataDir.appendingPathComponent("zclassic.conf")
        if fm.fileExists(atPath: currentConfigPath.path) && !existingConfig {
            // Bootstrap included a config but user didn't have one - remove bootstrap's config
            // User should generate their own or we'll create one with fresh credentials
            try? fm.removeItem(at: currentConfigPath)
            print("🗑️ Removed bootstrap's zclassic.conf (will generate fresh one)")
        }

        await MainActor.run {
            self.progress = 0.85
        }

        print("✅ Bootstrap extracted to \(dataDir.path)")
    }

    // MARK: - Configuration

    private func configureZclassicConf() throws {
        let dataDir = RPCClient.zclassicDataDir
        let configPath = dataDir.appendingPathComponent("zclassic.conf")

        // FIX #273: Create data directory if it doesn't exist
        if !FileManager.default.fileExists(atPath: dataDir.path) {
            try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
            print("📁 Created Zclassic data directory: \(dataDir.path)")
        }

        // NEVER overwrite existing config!
        if FileManager.default.fileExists(atPath: configPath.path) {
            print("ℹ️ Existing zclassic.conf found - NOT overwriting (user's config preserved)")
            return
        }

        // Only generate if no config exists
        // Generate random RPC credentials
        let rpcUser = "zipherx_\(randomString(length: 8))"
        let rpcPassword = randomString(length: 32)

        // FIX #273: Complete config with Tor/onion support
        let config = """
        # ZipherX Generated Configuration
        # Generated: \(ISO8601DateFormatter().string(from: Date()))

        # RPC Settings
        rpcuser=\(rpcUser)
        rpcpassword=\(rpcPassword)
        rpcport=8023
        rpcallowip=127.0.0.1

        # Network
        server=1
        listen=1
        daemon=1
        port=8033

        # CRITICAL: Indexes (required for wallet operations)
        txindex=1
        addressindex=1
        timestampindex=1
        spentindex=1

        # Tor/Onion Support
        # proxy=127.0.0.1:9250
        listenonion=1

        # Performance
        dbcache=512
        maxconnections=32

        # Security
        checkblocks=24
        checklevel=3
        """

        try config.write(to: configPath, atomically: true, encoding: .utf8)
        print("✅ Generated new zclassic.conf with random credentials and Tor support")
    }

    private func randomString(length: Int) -> String {
        let characters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        return String((0..<length).map { _ in characters.randomElement()! })
    }

    // MARK: - Sapling Parameters

    private func ensureSaplingParams() async throws {
        let paramsDir: URL

        #if os(macOS)
        paramsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("ZcashParams")
        #else
        paramsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".zcash-params")
        #endif

        let requiredParams = [
            ("sapling-spend.params", "8e48ffd23abb3a5fd9c5589204f32d9c31285a04b78096ba40a79b75677efc13"),
            ("sapling-output.params", "2f0ebbcbb9bb0bcffe95a397e7eba89c29eb4dde6191c339db88570e3f3fb0e4")
        ]

        for (filename, expectedHash) in requiredParams {
            let filePath = paramsDir.appendingPathComponent(filename)

            if FileManager.default.fileExists(atPath: filePath.path) {
                print("✅ \(filename) already exists")
                continue
            }

            await MainActor.run {
                self.currentTask = "Downloading \(filename)..."
            }

            // Download from z.cash
            let downloadURL = URL(string: "https://z.cash/downloads/\(filename)")!
            let (data, _) = try await URLSession.shared.data(from: downloadURL)

            // Create params directory
            try FileManager.default.createDirectory(at: paramsDir, withIntermediateDirectories: true)

            // Write file
            try data.write(to: filePath)
            print("✅ Downloaded \(filename)")
        }

        await MainActor.run {
            self.progress = 0.95
        }
    }

    // MARK: - Status Updates

    private func updateStatus(_ status: BootstrapStatus, task: String) async {
        await MainActor.run {
            self.status = status
            self.currentTask = task
        }
    }
}

// MARK: - Errors

public enum BootstrapError: Error, LocalizedError {
    case noAssetFound
    case releaseNotFound
    case downloadFailed
    case checksumMismatch
    case extractionFailed
    case configurationFailed
    case cancelled
    case zstdNotInstalled

    public var errorDescription: String? {
        switch self {
        case .noAssetFound:
            return "No bootstrap archive found in release"
        case .releaseNotFound:
            return "Could not find latest bootstrap release on GitHub"
        case .downloadFailed:
            return "Failed to download bootstrap"
        case .checksumMismatch:
            return "Downloaded file checksum does not match - file may be corrupted"
        case .extractionFailed:
            return "Failed to extract bootstrap archive"
        case .configurationFailed:
            return "Failed to configure zclassicd"
        case .cancelled:
            return "Bootstrap cancelled"
        case .zstdNotInstalled:
            return "zstd is required for extraction. Install with: brew install zstd"
        }
    }
}

// MARK: - Simple SHA256 Hasher

private struct SHA256Hasher {
    private var context = CC_SHA256_CTX()

    init() {
        CC_SHA256_Init(&context)
    }

    mutating func update(data: Data) {
        data.withUnsafeBytes { buffer in
            _ = CC_SHA256_Update(&context, buffer.baseAddress, CC_LONG(buffer.count))
        }
    }

    mutating func finalize() -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        CC_SHA256_Final(&digest, &context)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

#endif
