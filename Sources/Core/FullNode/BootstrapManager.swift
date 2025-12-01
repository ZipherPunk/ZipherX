import Foundation
import Combine

#if os(macOS)

/// Manages bootstrap download, extraction, and daemon setup for full node mode
public class BootstrapManager: ObservableObject {
    public static let shared = BootstrapManager()

    // GitHub repository for bootstrap releases
    private let githubRepo = "AURYNetwork/zclassic-bootstrap"
    private let githubAPIBase = "https://api.github.com/repos"

    // Published state
    @Published public private(set) var status: BootstrapStatus = .idle
    @Published public private(set) var progress: Double = 0.0
    @Published public private(set) var currentTask: String = ""
    @Published public private(set) var downloadSpeed: String = ""
    @Published public private(set) var eta: String = ""

    // Internal state
    private var downloadTask: URLSessionDownloadTask?
    private var isCancelled = false
    private var lastProgressUpdate = Date()
    private var lastBytesDownloaded: Int64 = 0

    public enum BootstrapStatus {
        case idle
        case checkingRelease
        case downloading
        case verifying
        case extracting
        case configuringDaemon
        case downloadingParams
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

        do {
            // Step 1: Check for latest release
            await updateStatus(.checkingRelease, task: "Checking for latest bootstrap...")
            let release = try await fetchLatestRelease()
            print("✅ Found bootstrap release: \(release.name)")

            // Step 2: Download bootstrap
            await updateStatus(.downloading, task: "Downloading bootstrap (\(release.sizeFormatted))...")
            try await downloadBootstrap(release: release)

            if isCancelled { return }

            // Step 3: Verify checksum
            await updateStatus(.verifying, task: "Verifying download...")
            try verifyChecksum(release: release)

            // Step 4: Extract bootstrap
            await updateStatus(.extracting, task: "Extracting blockchain data...")
            try await extractBootstrap()

            // Step 5: Configure daemon
            await updateStatus(.configuringDaemon, task: "Configuring zclassicd...")
            try configureZclassicConf()

            // Step 6: Download Sapling params if needed
            await updateStatus(.downloadingParams, task: "Checking Sapling parameters...")
            try await ensureSaplingParams()

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

    // MARK: - Release Fetching

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

    private struct BootstrapRelease {
        let name: String
        let downloadURL: URL
        let size: Int64
        let checksum: String?

        var sizeFormatted: String {
            ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        }
    }

    private func fetchLatestRelease() async throws -> BootstrapRelease {
        let url = URL(string: "\(githubAPIBase)/\(githubRepo)/releases/latest")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")

        let (data, _) = try await URLSession.shared.data(for: request)
        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)

        // Find the main bootstrap file (tar.zst)
        guard let asset = release.assets.first(where: { $0.name.hasSuffix(".tar.zst") || $0.name.hasSuffix(".zip") }) else {
            throw BootstrapError.noAssetFound
        }

        // Find checksum file if exists
        let checksumAsset = release.assets.first(where: { $0.name.contains("sha256") || $0.name.contains("checksum") })
        var checksum: String?

        if let checksumURL = checksumAsset.map({ URL(string: $0.browser_download_url)! }) {
            let (checksumData, _) = try await URLSession.shared.data(from: checksumURL)
            checksum = String(data: checksumData, encoding: .utf8)?.components(separatedBy: .whitespaces).first
        }

        return BootstrapRelease(
            name: release.name,
            downloadURL: URL(string: asset.browser_download_url)!,
            size: asset.size,
            checksum: checksum
        )
    }

    // MARK: - Download

    private func downloadBootstrap(release: BootstrapRelease) async throws {
        let downloadDir = FileManager.default.temporaryDirectory
        let destinationPath = downloadDir.appendingPathComponent("zclassic-bootstrap.tar.zst")

        // Remove existing partial download
        try? FileManager.default.removeItem(at: destinationPath)

        // Create download delegate for progress
        let delegate = DownloadDelegate(manager: self, totalSize: release.size)

        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        var request = URLRequest(url: release.downloadURL)
        request.setValue("ZipherX/1.0", forHTTPHeaderField: "User-Agent")

        downloadTask = session.downloadTask(with: request)
        downloadTask?.resume()

        // Wait for completion
        await withCheckedContinuation { continuation in
            delegate.completion = { error in
                if let error = error {
                    print("❌ Download error: \(error)")
                }
                continuation.resume()
            }
        }

        if isCancelled {
            throw BootstrapError.cancelled
        }

        // Move to final location
        if let tempURL = delegate.downloadedFileURL {
            try FileManager.default.moveItem(at: tempURL, to: destinationPath)
        }
    }

    private class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
        weak var manager: BootstrapManager?
        let totalSize: Int64
        var downloadedFileURL: URL?
        var completion: ((Error?) -> Void)?

        init(manager: BootstrapManager, totalSize: Int64) {
            self.manager = manager
            self.totalSize = totalSize
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            let progress = Double(totalBytesWritten) / Double(max(totalSize, totalBytesExpectedToWrite))

            Task { @MainActor in
                self.manager?.progress = progress * 0.6 // Download is 60% of total
                self.manager?.updateDownloadStats(bytesWritten: totalBytesWritten, totalBytes: self.totalSize)
            }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            downloadedFileURL = location
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            completion?(error)
        }
    }

    private func updateDownloadStats(bytesWritten: Int64, totalBytes: Int64) {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastProgressUpdate)

        if elapsed >= 0.5 { // Update every 500ms
            let bytesDelta = bytesWritten - lastBytesDownloaded
            let speed = Double(bytesDelta) / elapsed

            downloadSpeed = ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .file) + "/s"

            let remaining = totalBytes - bytesWritten
            if speed > 0 {
                let etaSeconds = Double(remaining) / speed
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

    private func verifyChecksum(release: BootstrapRelease) throws {
        guard let expectedChecksum = release.checksum else {
            print("⚠️ No checksum available, skipping verification")
            return
        }

        let downloadPath = FileManager.default.temporaryDirectory.appendingPathComponent("zclassic-bootstrap.tar.zst")
        let computedChecksum = try computeSHA256(file: downloadPath)

        guard computedChecksum.lowercased() == expectedChecksum.lowercased() else {
            throw BootstrapError.checksumMismatch
        }

        print("✅ Checksum verified")
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

    // MARK: - Extraction

    private func extractBootstrap() async throws {
        let downloadPath = FileManager.default.temporaryDirectory.appendingPathComponent("zclassic-bootstrap.tar.zst")
        let dataDir = RPCClient.zclassicDataDir

        // Create data directory if needed
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)

        await MainActor.run {
            self.progress = 0.7 // Extraction starts at 70%
        }

        // Use tar to extract (macOS has zstd support via brew or built-in)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xf", downloadPath.path, "-C", dataDir.path]
        process.currentDirectoryURL = dataDir

        // Check if zstd is available
        if FileManager.default.fileExists(atPath: "/opt/homebrew/bin/zstd") ||
           FileManager.default.fileExists(atPath: "/usr/local/bin/zstd") {
            // Use zstd for decompression
            process.arguments = ["--use-compress-program=zstd", "-xf", downloadPath.path, "-C", dataDir.path]
        }

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw BootstrapError.extractionFailed
        }

        // Clean up download
        try? FileManager.default.removeItem(at: downloadPath)

        await MainActor.run {
            self.progress = 0.85
        }

        print("✅ Bootstrap extracted to \(dataDir.path)")
    }

    // MARK: - Configuration

    private func configureZclassicConf() throws {
        let configPath = RPCClient.zclassicDataDir.appendingPathComponent("zclassic.conf")

        // Check if config already exists
        if FileManager.default.fileExists(atPath: configPath.path) {
            // Backup existing config
            let backupPath = RPCClient.zclassicDataDir.appendingPathComponent("zclassic.conf.backup.\(Int(Date().timeIntervalSince1970))")
            try FileManager.default.copyItem(at: configPath, to: backupPath)
            print("📁 Backed up existing config to \(backupPath.lastPathComponent)")
        }

        // Generate random RPC credentials
        let rpcUser = "zipherx_\(randomString(length: 8))"
        let rpcPassword = randomString(length: 32)

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

        # Indexes (required for explorer)
        txindex=1
        addressindex=1
        timestampindex=1
        spentindex=1

        # Performance
        dbcache=512
        maxconnections=32

        # Sapling
        experimentalfeatures=1
        zmergetoaddress=1
        """

        try config.write(to: configPath, atomically: true, encoding: .utf8)
        print("✅ Generated zclassic.conf with random credentials")
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
    case downloadFailed
    case checksumMismatch
    case extractionFailed
    case configurationFailed
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .noAssetFound:
            return "No bootstrap archive found in release"
        case .downloadFailed:
            return "Failed to download bootstrap"
        case .checksumMismatch:
            return "Downloaded file checksum does not match"
        case .extractionFailed:
            return "Failed to extract bootstrap archive"
        case .configurationFailed:
            return "Failed to configure zclassicd"
        case .cancelled:
            return "Bootstrap cancelled"
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

import CommonCrypto

#endif
