import Foundation
import Combine
import CommonCrypto

#if os(macOS)

/// Manages bootstrap download, extraction, and daemon setup for full node mode
/// Supports split-file bootstrap format from ZipherPunk/zclassic-bootstrap
public class BootstrapManager: ObservableObject {
    public static let shared = BootstrapManager()

    // GitHub repository for bootstrap releases
    private let githubRepo = "ZipherPunk/zclassic-bootstrap"
    private let githubAPIBase = "https://api.github.com/repos"

    // Published state
    @Published public private(set) var status: BootstrapStatus = .idle
    @Published public private(set) var progress: Double = 0.0
    @Published public private(set) var currentTask: String = ""
    @Published public private(set) var downloadSpeed: String = ""
    @Published public private(set) var eta: String = ""
    @Published public private(set) var currentPart: Int = 0
    @Published public private(set) var totalParts: Int = 0
    @Published public private(set) var elapsedTime: String = ""  // FIX #312: Overall elapsed time

    // Internal state
    private var downloadTask: URLSessionDownloadTask?
    private var sharedSession: URLSession?  // FIX #322: Reuse session for all downloads
    // FIX #1459: Track all active download sessions for proper cancellation
    private var activeDownloadSessions: [URLSession] = []
    private let sessionLock = NSLock()
    private var isCancelled = false
    private var lastProgressUpdate = Date()
    private var lastBytesDownloaded: Int64 = 0
    private var totalBytesDownloadedAllParts: Int64 = 0
    private var totalSizeAllParts: Int64 = 0
    private var bootstrapStartTime: Date?  // FIX #312: Track start time
    private var elapsedTimeTimer: Timer?   // FIX #312: Timer to update elapsed time

    // FIX #313: Thread-safe tracking of each parallel download's progress
    private var partBytesDownloaded: [Int: Int64] = [:]
    private let progressLock = NSLock()

    // FIX #314: Prevent concurrent bootstrap operations
    private var isBootstrapRunning = false
    private let bootstrapLock = NSLock()

    // FIX #1458: Track last step before error for task list display
    @Published public private(set) var lastStepBeforeError: BootstrapStatus?

    // FIX #315: Reduce logging verbosity - only log errors and key milestones
    private let verboseLogging = false
    fileprivate func logVerbose(_ message: String) {
        if verboseLogging { print(message) }
    }

    // FIX #317: Track elapsed time for each task
    @Published public private(set) var taskElapsedTimes: [String: String] = [:]
    private var currentTaskStartTime: Date?
    private var taskStartTimes: [String: Date] = [:]

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
        case syncingBlocks(progress: Double, eta: String)  // FIX #285: Syncing remaining blocks after bootstrap
        case complete
        case completeNeedsDaemon  // FIX #285: Bootstrap done but daemon not installed
        case completeDaemonStopped  // FIX #285: Bootstrap done, daemon exists but not running
        case error(String)
        case cancelled
    }

    // FIX #285: Post-bootstrap completion info
    @Published public private(set) var bootstrapBlockHeight: UInt64 = 0
    @Published public private(set) var currentChainHeight: UInt64 = 0
    @Published public private(set) var blocksDelta: UInt64 = 0

    private init() {}

    // MARK: - FIX #317: Task Timing Helpers

    /// Start timing a task
    private func startTaskTiming(_ taskKey: String) {
        taskStartTimes[taskKey] = Date()
    }

    /// End timing a task and record elapsed time
    @MainActor
    private func endTaskTiming(_ taskKey: String) {
        guard let startTime = taskStartTimes[taskKey] else { return }
        let elapsed = Date().timeIntervalSince(startTime)
        taskElapsedTimes[taskKey] = formatTaskElapsedTime(elapsed)
        taskStartTimes.removeValue(forKey: taskKey)
    }

    /// Format elapsed time as human readable string (e.g., "5m 32s")
    private func formatTaskElapsedTime(_ interval: TimeInterval) -> String {
        let seconds = Int(interval)
        if seconds < 60 {
            return "\(seconds)s"
        } else if seconds < 3600 {
            let mins = seconds / 60
            let secs = seconds % 60
            return "\(mins)m \(secs)s"
        } else {
            let hours = seconds / 3600
            let mins = (seconds % 3600) / 60
            return "\(hours)h \(mins)m"
        }
    }

    /// Reset all task timings
    @MainActor
    private func resetTaskTimings() {
        taskElapsedTimes.removeAll()
        taskStartTimes.removeAll()
    }

    // MARK: - Public API

    /// Start the full bootstrap process
    public func startBootstrap() async {
        // FIX #314: Thread-safe check to prevent concurrent bootstrap operations
        bootstrapLock.lock()
        if isBootstrapRunning {
            bootstrapLock.unlock()
            print("⚠️ FIX #314: Bootstrap already running - ignoring duplicate call")
            return
        }
        isBootstrapRunning = true
        bootstrapLock.unlock()

        // FIX #307 v2: Reset status if stuck in error/cancelled/checkingRelease state
        // checkingRelease can get stuck if network fails during GitHub API call
        switch status {
        case .error, .cancelled, .checkingRelease:
            logVerbose("🔧 FIX #307: Resetting bootstrap status from \(status) to idle")
            await MainActor.run { self.status = .idle }
        case .idle:
            break
        case .downloading, .verifying, .combining, .extracting, .configuringDaemon, .downloadingParams, .startingDaemon, .syncingBlocks:
            // These are active states - don't interrupt (shouldn't happen with FIX #314)
            print("⚠️ Bootstrap already in progress (status: \(status))")
            bootstrapLock.lock()
            isBootstrapRunning = false
            bootstrapLock.unlock()
            return
        case .complete, .completeNeedsDaemon, .completeDaemonStopped:
            // Allow restart after completion
            logVerbose("🔧 FIX #307: Resetting from completed state to allow fresh bootstrap")
            await MainActor.run { self.status = .idle }
        }

        isCancelled = false
        totalBytesDownloadedAllParts = 0

        // FIX #1458: Clean up stale temp files from previous failed attempt
        cleanupPartialDownloads()
        await MainActor.run { self.lastStepBeforeError = nil }

        // FIX #313: Reset parallel download progress tracking
        progressLock.lock()
        partBytesDownloaded.removeAll()
        progressLock.unlock()

        // FIX #312: Start elapsed time tracking
        await startElapsedTimeTimer()

        // FIX #317: Reset task elapsed times for new bootstrap
        await MainActor.run { resetTaskTimings() }

        do {
            // FIX #304: Pre-flight check for zstd BEFORE downloading
            await updateStatus(.checkingRelease, task: "Checking prerequisites...")
            let zstdPaths = ["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd", "/usr/bin/zstd"]
            guard zstdPaths.contains(where: { FileManager.default.fileExists(atPath: $0) }) else {
                print("❌ FIX #304: zstd not found - required for bootstrap extraction")
                throw BootstrapError.zstdNotInstalled
            }
            logVerbose("✅ FIX #304: zstd found - prerequisite check passed")

            // FIX #308: Install daemon binaries FIRST (before downloading blockchain)
            // FIX #338: Use print() instead of logVerbose() for visibility
            let daemonPath = "/usr/local/bin/zclassicd"
            if !FileManager.default.fileExists(atPath: daemonPath) {
                print("📦 FIX #338: Daemon not installed at \(daemonPath), checking for bundled binaries...")
                print("📦 FIX #338: hasBundledDaemon = \(hasBundledDaemon)")
                if hasBundledDaemon {
                    print("📦 FIX #338: Found bundled daemon, installing BEFORE bootstrap...")
                    await updateStatus(.configuringDaemon, task: "Installing daemon binaries...")
                    do {
                        let installed = try await installBundledDaemon()
                        if installed {
                            print("✅ FIX #338: Daemon pre-installed successfully to /usr/local/bin/")
                        }
                    } catch {
                        print("❌ FIX #338: Could not pre-install daemon: \(error.localizedDescription)")
                        print("❌ FIX #338: Full error: \(error)")
                        // Continue with bootstrap anyway - will try again after extraction
                    }
                } else {
                    print("⚠️ FIX #338: No bundled daemon found in app bundle - will need manual install")
                    if let bundlePath = Bundle.main.resourcePath {
                        print("⚠️ FIX #338: Bundle path: \(bundlePath)")
                        // List what's in the bundle for debugging
                        let fm = FileManager.default
                        if let contents = try? fm.contentsOfDirectory(atPath: bundlePath) {
                            print("⚠️ FIX #338: Bundle contents: \(contents.joined(separator: ", "))")
                        }
                    }
                }
            } else {
                print("✅ FIX #338: Daemon already installed at \(daemonPath)")
            }

            // Step 1: Check for latest release
            await updateStatus(.checkingRelease, task: "Checking for latest bootstrap...")
            print("🔧 Bootstrap: Fetching release from \(githubRepo)...")
            let release = try await fetchLatestRelease()
            print("✅ Bootstrap: \(release.name) - \(release.parts.count) parts, \(release.totalSizeFormatted)")

            // Step 2: Download all parts (FIX #311: Parallel downloads, 4 at a time)
            await updateStatus(.downloading, task: "Downloading bootstrap (\(release.totalSizeFormatted))...")
            totalParts = release.parts.count
            totalSizeAllParts = release.totalSize

            let downloadDir = FileManager.default.temporaryDirectory.appendingPathComponent("zclassic-bootstrap")
            try FileManager.default.createDirectory(at: downloadDir, withIntermediateDirectories: true)

            // FIX #322: Create shared session for connection reuse
            // FIX #340: Reverted to single-stream downloads (parallel chunks were slower: 2 MB/s vs 60 MB/s)
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForResource = 3600  // 1 hour for large file
            config.timeoutIntervalForRequest = 120    // 2 minutes per request (GitHub can be slow)
            config.waitsForConnectivity = true
            self.sharedSession = URLSession(configuration: config)

            // FIX #340: Single-stream download per part (40-60 MB/s)
            // Note: Each part creates its own session with delegate for proper callback routing
            // FIX #346: Download 3 parts in parallel (each Rust call creates its own runtime)
            let concurrencyLimit = 3
            var downloadedCount = 0
            let partsArray = release.parts

            for batchStart in stride(from: 0, to: partsArray.count, by: concurrencyLimit) {
                if isCancelled { throw BootstrapError.cancelled }

                let batchEnd = min(batchStart + concurrencyLimit, partsArray.count)
                let batch = Array(partsArray[batchStart..<batchEnd])

                await MainActor.run {
                    // FIX #321: Sequential download, so just show single part number
                    self.currentTask = "Downloading part \(batchStart + 1)/\(partsArray.count)..."
                }

                logVerbose("📥 FIX #321: Sequential download - part \(batchStart + 1)/\(partsArray.count)")

                // Download batch in parallel using TaskGroup
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for (batchIndex, part) in batch.enumerated() {
                        let partIndex = batchStart + batchIndex
                        group.addTask {
                            try await self.downloadPart(part: part, to: downloadDir, partIndex: partIndex, totalParts: partsArray.count)
                        }
                    }

                    // Wait for all tasks in batch to complete (throws if any fail)
                    try await group.waitForAll()
                }

                downloadedCount += batch.count
                // FIX #1459: Clear completed download sessions after each batch
                sessionLock.lock()
                activeDownloadSessions.removeAll()
                sessionLock.unlock()
                await MainActor.run {
                    self.currentPart = downloadedCount
                }
                // FIX #321: Sequential download completion message
                print("✅ Bootstrap: Downloaded \(downloadedCount)/\(partsArray.count) parts")
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

            // FIX #285 + FIX #308 + FIX #338: Check daemon installation and auto-install if missing
            // daemonPath already declared above
            var daemonExists = FileManager.default.fileExists(atPath: daemonPath)
            print("📦 FIX #338: Post-bootstrap daemon check: \(daemonPath) exists = \(daemonExists)")

            if !daemonExists {
                // FIX #308: Try to install bundled daemon automatically
                print("📦 FIX #338: Daemon not found after bootstrap, attempting install...")
                print("📦 FIX #338: hasBundledDaemon = \(hasBundledDaemon)")
                if hasBundledDaemon {
                    print("📦 FIX #338: Found bundled daemon, installing...")
                    await updateStatus(.configuringDaemon, task: "Installing daemon binaries...")
                    do {
                        let installed = try await installBundledDaemon()
                        if installed {
                            print("✅ FIX #338: Daemon installed successfully from bundle")
                            daemonExists = true
                        }
                    } catch {
                        print("❌ FIX #338: Failed to install bundled daemon: \(error)")
                    }
                } else {
                    print("⚠️ FIX #338: No bundled daemon available")
                }

                // If still not installed after trying bundled, inform user
                if !daemonExists {
                    print("⚠️ FIX #338: Bootstrap complete but zclassicd not found at \(daemonPath)")
                    await updateStatus(.completeNeedsDaemon, task: "Bootstrap complete! Install daemon manually.")
                    await MainActor.run {
                        self.progress = 1.0
                    }
                    stopElapsedTimeTimer()  // FIX #314
                    return
                }
            }

            // Step 8: Start daemon and wait for sync
            await updateStatus(.startingDaemon, task: "Starting zclassicd...")
            do {
                try await FullNodeManager.shared.startDaemon()
            logVerbose("✅ Daemon started successfully")

                // FIX #285: Check sync status and show delta if needed
                await checkSyncStatusAfterBootstrap()

            } catch {
                print("⚠️ Daemon start failed (user can start manually): \(error)")
                // Daemon exists but couldn't start
                await updateStatus(.completeDaemonStopped, task: "Bootstrap complete! Start daemon from Node Management.")
                await MainActor.run {
                    self.progress = 1.0
                }
                stopElapsedTimeTimer()  // FIX #314
                return
            }

        } catch {
            if !isCancelled {
                print("❌ Bootstrap failed: \(error.localizedDescription)")
                print("❌ Full error: \(error)")
                await updateStatus(.error(error.localizedDescription), task: "Bootstrap failed")
            }
            // FIX #314: Clear running flag on error
            stopElapsedTimeTimer()
        }
    }

    /// Cancel ongoing bootstrap
    public func cancel() {
        isCancelled = true
        downloadTask?.cancel()
        // FIX #1459: Cancel ALL active download sessions (not just the legacy single task)
        sessionLock.lock()
        let sessions = activeDownloadSessions
        activeDownloadSessions.removeAll()
        sessionLock.unlock()
        for session in sessions {
            session.invalidateAndCancel()
        }
        sharedSession?.invalidateAndCancel()
        sharedSession = nil
        stopElapsedTimeTimer()  // FIX #312
        Task { @MainActor in
            status = .cancelled
            currentTask = "Cancelled"
        }
    }

    /// Reset to idle state (for retry)
    public func reset() {
        stopElapsedTimeTimer()  // FIX #312
        Task { @MainActor in
            status = .idle
            progress = 0.0
            currentTask = ""
            downloadSpeed = ""
            eta = ""
            elapsedTime = ""  // FIX #312
            currentPart = 0
            totalParts = 0
        }
    }

    /// FIX #1458: Clean up partial downloads from failed bootstrap attempt
    private func cleanupPartialDownloads() {
        let downloadDir = FileManager.default.temporaryDirectory.appendingPathComponent("zclassic-bootstrap")
        if FileManager.default.fileExists(atPath: downloadDir.path) {
            try? FileManager.default.removeItem(at: downloadDir)
            print("🧹 FIX #1458: Cleaned up partial downloads from previous attempt")
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

    // MARK: - FIX #312: Elapsed Time Tracking

    /// Start the elapsed time timer
    @MainActor
    private func startElapsedTimeTimer() {
        bootstrapStartTime = Date()
        elapsedTime = "0:00"

        // Update elapsed time every second
        elapsedTimeTimer?.invalidate()
        elapsedTimeTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self, let startTime = self.bootstrapStartTime else { return }
            let elapsed = Date().timeIntervalSince(startTime)
            Task { @MainActor in
                self.elapsedTime = self.formatElapsedTime(elapsed)
            }
        }
    }

    /// Stop the elapsed time timer and clear bootstrap running flag
    private func stopElapsedTimeTimer() {
        elapsedTimeTimer?.invalidate()
        elapsedTimeTimer = nil

        // FIX #314: Clear running flag when bootstrap ends
        bootstrapLock.lock()
        isBootstrapRunning = false
        bootstrapLock.unlock()
    }

    /// Format elapsed time as "M:SS" or "H:MM:SS"
    private func formatElapsedTime(_ seconds: TimeInterval) -> String {
        let totalSeconds = Int(seconds)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        } else {
            return String(format: "%d:%02d", minutes, secs)
        }
    }

    // MARK: - FIX #285: Post-Bootstrap Sync Check

    /// Check sync status after bootstrap and show progress for remaining blocks
    private func checkSyncStatusAfterBootstrap() async {
        do {
            // Get current blockchain info from RPC
            let blockchainInfo = try await RPCClient.shared.getBlockchainInfo()

            guard let blocks = blockchainInfo["blocks"] as? UInt64,
                  let headers = blockchainInfo["headers"] as? UInt64 else {
                // Can't determine sync status, just mark complete
                await updateStatus(.complete, task: "Bootstrap complete!")
                await MainActor.run { self.progress = 1.0 }
                stopElapsedTimeTimer()  // FIX #314
                return
            }

            await MainActor.run {
                self.bootstrapBlockHeight = blocks
                self.currentChainHeight = headers
                self.blocksDelta = headers > blocks ? headers - blocks : 0
            }

            if blocksDelta == 0 {
                // Fully synced!
                logVerbose("✅ FIX #285: Daemon fully synced at block \(blocks)")
                await updateStatus(.complete, task: "Bootstrap complete! Fully synced.")
                await MainActor.run { self.progress = 1.0 }
                stopElapsedTimeTimer()  // FIX #314
                return
            }

            logVerbose("📊 FIX #285: Bootstrap at block \(blocks), chain height \(headers), delta: \(blocksDelta) blocks")

            // Show sync progress for remaining blocks
            await monitorSyncProgress()

        } catch {
            print("⚠️ FIX #285: Could not get sync status: \(error.localizedDescription)")
            await updateStatus(.complete, task: "Bootstrap complete!")
            await MainActor.run { self.progress = 1.0 }
            stopElapsedTimeTimer()  // FIX #314
        }
    }

    /// Monitor sync progress until fully synced
    private func monitorSyncProgress() async {
        let startTime = Date()
        var lastBlocks: UInt64 = bootstrapBlockHeight
        var lastCheckTime = Date()

        while !isCancelled {
            do {
                try await Task.sleep(nanoseconds: 5_000_000_000)  // Check every 5 seconds

                let blockchainInfo = try await RPCClient.shared.getBlockchainInfo()

                guard let blocks = blockchainInfo["blocks"] as? UInt64,
                      let headers = blockchainInfo["headers"] as? UInt64 else {
                    continue
                }

                let remaining = headers > blocks ? headers - blocks : 0
                let totalToSync = currentChainHeight - bootstrapBlockHeight
                let synced = blocks - bootstrapBlockHeight
                let progress = totalToSync > 0 ? Double(synced) / Double(totalToSync) : 1.0

                // Calculate ETA based on sync speed
                let now = Date()
                let elapsed = now.timeIntervalSince(lastCheckTime)
                let blocksSynced = blocks > lastBlocks ? blocks - lastBlocks : 0
                let blocksPerSecond = elapsed > 0 ? Double(blocksSynced) / elapsed : 0

                var etaString = "calculating..."
                if blocksPerSecond > 0 && remaining > 0 {
                    let etaSeconds = Double(remaining) / blocksPerSecond
                    etaString = formatDuration(etaSeconds)
                }

                await MainActor.run {
                    self.blocksDelta = remaining
                }

                await updateStatus(
                    .syncingBlocks(progress: progress, eta: etaString),
                    task: "Syncing \(remaining) remaining blocks..."
                )
                await MainActor.run {
                    self.progress = 0.95 + (progress * 0.05)  // 95-100% for sync phase
                }

                lastBlocks = blocks
                lastCheckTime = now

                if remaining == 0 {
                    // Fully synced!
                    logVerbose("✅ FIX #285: Sync complete! Took \(formatDuration(Date().timeIntervalSince(startTime)))")
                    await updateStatus(.complete, task: "Bootstrap complete! Fully synced.")
                    await MainActor.run { self.progress = 1.0 }
                    stopElapsedTimeTimer()  // FIX #314
                    return
                }

            } catch {
                print("⚠️ FIX #285: Sync check error: \(error.localizedDescription)")
                // Continue monitoring
            }
        }
    }

    // MARK: - FIX #285: Daemon Installation

    /// Check if bundled daemon binaries exist in app bundle
    /// FIX #308: Look in Binaries subdirectory
    /// FIX #312: Cache result to avoid log spam (was logging every 30ms in SwiftUI view)
    private var _hasBundledDaemonCached: Bool?
    private var _hasBundledDaemonCheckedOnce = false

    public var hasBundledDaemon: Bool {
        // Return cached value if already checked
        if let cached = _hasBundledDaemonCached {
            return cached
        }

        guard let bundlePath = Bundle.main.resourcePath else {
            print("🔍 FIX #338: Bundle.main.resourcePath is nil!")
            _hasBundledDaemonCached = false
            return false
        }

        // Check both direct path and Binaries subdirectory
        let directPath = (bundlePath as NSString).appendingPathComponent("zclassicd")
        let binariesPath = (bundlePath as NSString).appendingPathComponent("Binaries/zclassicd")
        let directExists = FileManager.default.fileExists(atPath: directPath)
        let binariesExists = FileManager.default.fileExists(atPath: binariesPath)
        let result = directExists || binariesExists

        // FIX #338: Always log for visibility (only once due to caching)
        if !_hasBundledDaemonCheckedOnce {
            _hasBundledDaemonCheckedOnce = true
            print("🔍 FIX #338: hasBundledDaemon check:")
            print("   Bundle path: \(bundlePath)")
            print("   Direct path (\(directPath)): \(directExists)")
            print("   Binaries path (\(binariesPath)): \(binariesExists)")
            print("   Result: \(result)")
        }

        _hasBundledDaemonCached = result
        return result
    }

    /// Install bundled daemon binaries to /usr/local/bin (macOS only)
    /// Returns true if successful
    /// FIX #308: Look in Binaries subdirectory, zclassic-tx is optional
    /// FIX #338: Added print statements for visibility
    public func installBundledDaemon() async throws -> Bool {
        print("📦 FIX #338: installBundledDaemon() called")

        guard let bundlePath = Bundle.main.resourcePath else {
            print("❌ FIX #338: Bundle.main.resourcePath is nil")
            throw BootstrapError.daemonInstallFailed("Could not locate app bundle")
        }
        print("📦 FIX #338: Bundle path: \(bundlePath)")

        // Required binaries (zclassic-tx is optional)
        let requiredBinaries = ["zclassicd", "zclassic-cli"]
        let optionalBinaries = ["zclassic-tx"]
        let targetDir = "/usr/local/bin"

        // Determine source directory (direct or Binaries subdirectory)
        var sourceDir = bundlePath
        let binariesSubdir = (bundlePath as NSString).appendingPathComponent("Binaries")
        if FileManager.default.fileExists(atPath: (binariesSubdir as NSString).appendingPathComponent("zclassicd")) {
            sourceDir = binariesSubdir
            print("📦 FIX #338: Using Binaries subdirectory: \(sourceDir)")
        } else {
            print("📦 FIX #338: Binaries subdirectory not found, using: \(sourceDir)")
        }

        // Verify required binaries exist
        for binary in requiredBinaries {
            let sourcePath = (sourceDir as NSString).appendingPathComponent(binary)
            let exists = FileManager.default.fileExists(atPath: sourcePath)
            print("📦 FIX #338: Checking \(binary) at \(sourcePath): \(exists ? "✅" : "❌")")
            guard exists else {
                throw BootstrapError.daemonInstallFailed("Bundled \(binary) not found at \(sourcePath)")
            }
        }

        // Collect all binaries to install (required + optional if they exist)
        var binariesToInstall = requiredBinaries
        for binary in optionalBinaries {
            let sourcePath = (sourceDir as NSString).appendingPathComponent(binary)
            if FileManager.default.fileExists(atPath: sourcePath) {
                binariesToInstall.append(binary)
                print("📦 FIX #338: Optional binary \(binary) found, will install")
            }
        }

        // Create /usr/local/bin if it doesn't exist (may need admin privileges)
        if !FileManager.default.fileExists(atPath: targetDir) {
            print("❌ FIX #338: Target directory \(targetDir) does not exist")
            throw BootstrapError.daemonInstallFailed("/usr/local/bin does not exist. Please create it manually or install Homebrew.")
        }
        print("📦 FIX #338: Target directory exists: \(targetDir)")

        // Copy binaries (FIX #338: Skip if already exists, don't remove existing)
        for binary in binariesToInstall {
            let sourcePath = (sourceDir as NSString).appendingPathComponent(binary)
            let targetPath = (targetDir as NSString).appendingPathComponent(binary)

            // FIX #338: If binary already exists, skip it (don't remove user's existing binaries)
            if FileManager.default.fileExists(atPath: targetPath) {
                print("✅ FIX #338: \(binary) already exists at \(targetPath) - skipping")
                continue
            }

            print("📦 FIX #338: Installing \(binary): \(sourcePath) → \(targetPath)")

            // Copy from bundle
            try FileManager.default.copyItem(atPath: sourcePath, toPath: targetPath)

            // Make executable
            let attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o755]
            try FileManager.default.setAttributes(attributes, ofItemAtPath: targetPath)

            print("✅ FIX #338: Installed \(binary) to \(targetPath)")
        }

        print("✅ FIX #338: All daemon binaries installed successfully")
        return true
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
        request.timeoutInterval = 30  // FIX #307: 30 second timeout for GitHub API

        logVerbose("📡 Fetching latest release from GitHub...")
        logVerbose("📡 URL: \(url.absoluteString)")

        let (data, response): (Data, URLResponse)
        do {
            // FIX #1537: Route through Tor when available (GitHub API leak)
            let ghSession: URLSession
            let torMode = await TorManager.shared.mode
            let torConnected = await TorManager.shared.connectionState.isConnected
            if torMode == .enabled && torConnected {
                ghSession = await TorManager.shared.getTorURLSession(isolate: true)
            } else {
                ghSession = URLSession.shared
            }
            (data, response) = try await ghSession.data(for: request)
        } catch {
            print("❌ GitHub API request failed: \(error.localizedDescription)")
            throw error
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            print("❌ Invalid response type from GitHub")
            throw BootstrapError.releaseNotFound
        }

        logVerbose("📡 GitHub response status: \(httpResponse.statusCode)")

        guard httpResponse.statusCode == 200 else {
            print("❌ GitHub API returned status \(httpResponse.statusCode)")
            if let responseText = String(data: data, encoding: .utf8) {
                print("❌ Response: \(responseText.prefix(500))")
            }
            throw BootstrapError.releaseNotFound
        }

        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)

        // FIX #309: Find all .part* files (split uses .partaa, .partab, etc. naming)
        // Files are named like: zclassic-bootstrap-20251218.tar.zst.partaa
        let partAssets = release.assets
            .filter { $0.name.contains(".part") && !$0.name.lowercased().contains("checksum") }
            .sorted { $0.name < $1.name }  // Alphabetical sort works: .partaa < .partab < .partac

        guard !partAssets.isEmpty else {
            // Fallback: Check for single .tar.zst file (old format)
            if let singleAsset = release.assets.first(where: { $0.name.hasSuffix(".tar.zst") }) {
                logVerbose("ℹ️ Using single-file bootstrap format")
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

        logVerbose("📦 Bootstrap release has \(parts.count) parts, total \(ByteCountFormatter.string(fromByteCount: parts.reduce(0) { $0 + $1.size }, countStyle: .file))")

        return BootstrapRelease(
            name: release.name,
            tagName: release.tag_name,
            parts: parts,
            checksums: checksums
        )
    }

    private func extractPartNumber(_ filename: String) -> Int {
        // FIX #309: Handle both naming conventions:
        // - Old format: "zclassic-bootstrap-block-XXXXX-part-01.part"
        // - Split format: "zclassic-bootstrap-20251218.tar.zst.partaa" (aa=1, ab=2, etc.)

        // Try split format first (.partaa, .partab, etc.)
        let splitPattern = "\\.part([a-z]{2})$"
        if let regex = try? NSRegularExpression(pattern: splitPattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: filename, options: [], range: NSRange(filename.startIndex..., in: filename)),
           let range = Range(match.range(at: 1), in: filename) {
            let suffix = filename[range].lowercased()
            // Convert aa=1, ab=2, ..., az=26, ba=27, etc.
            let chars = Array(suffix)
            if chars.count == 2 {
                let first = Int(chars[0].asciiValue! - Character("a").asciiValue!)
                let second = Int(chars[1].asciiValue! - Character("a").asciiValue!)
                return (first * 26) + second + 1
            }
        }

        // Try old format (part-01, part-02, etc.)
        let oldPattern = "part-?(\\d+)"
        if let regex = try? NSRegularExpression(pattern: oldPattern, options: .caseInsensitive),
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

        // FIX #1537: Route through Tor when available
        let csSession: URLSession
        let torMode = await TorManager.shared.mode
        let torConnected = await TorManager.shared.connectionState.isConnected
        if torMode == .enabled && torConnected {
            csSession = await TorManager.shared.getTorURLSession(isolate: true)
        } else {
            csSession = URLSession.shared
        }
        let (data, _) = try await csSession.data(from: URL(string: checksumAsset.browser_download_url)!)
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

        logVerbose("📋 Loaded \(checksums.count) checksums from \(checksumAsset.name)")
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
                    logVerbose("✅ Part \(partIndex + 1) already downloaded and verified")
                    // FIX #313: Thread-safe update
                    progressLock.lock()
                    totalBytesDownloadedAllParts += part.size
                    partBytesDownloaded.removeValue(forKey: partIndex)
                    progressLock.unlock()
                    return
                }
            }
            // Remove corrupt/incomplete file (checksum mismatch means data is bad)
            // FIX #336/340: Resume is handled via HTTP Range header in download loop
            try? FileManager.default.removeItem(at: destinationPath)
        }

        // Reset per-part tracking
        lastBytesDownloaded = 0
        lastProgressUpdate = Date()

        // FIX #347: Revert to Swift URLSession - Rust FFI was 10x slower (37 min vs 3 min)
        // URLSession with StreamingDownloadDelegate achieves full bandwidth from GitHub CDN
        print("📥 Bootstrap: Starting part \(partIndex + 1)/\(totalParts) (\(ByteCountFormatter.string(fromByteCount: part.size, countStyle: .file)))")

        // Check for partial download to resume
        var resumeOffset: Int64 = 0
        if FileManager.default.fileExists(atPath: destinationPath.path),
           let attrs = try? FileManager.default.attributesOfItem(atPath: destinationPath.path),
           let existingSize = attrs[.size] as? Int64,
           existingSize > 0 && existingSize < part.size {
            resumeOffset = existingSize
            logVerbose("📥 FIX #347: Resuming part \(partIndex + 1) from \(ByteCountFormatter.string(fromByteCount: existingSize, countStyle: .file))")
        }

        // Build request with Range header for resume
        var request = URLRequest(url: part.downloadURL)
        request.setValue("ZipherX/1.0", forHTTPHeaderField: "User-Agent")
        if resumeOffset > 0 {
            request.setValue("bytes=\(resumeOffset)-", forHTTPHeaderField: "Range")
        }

        // FIX #1459: Check cancellation before starting download
        if isCancelled { throw BootstrapError.cancelled }

        // Use continuation to bridge delegate callbacks to async/await
        _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            // FIX #1459: Check cancellation inside continuation
            guard !self.isCancelled else {
                continuation.resume(throwing: BootstrapError.cancelled)
                return
            }

            let delegate = StreamingDownloadDelegate(
                manager: self,
                partSize: part.size,
                partIndex: partIndex,
                totalParts: totalParts,
                destinationURL: destinationPath,
                resumeOffset: resumeOffset,
                continuation: continuation
            )

            // Create dedicated session for this download with delegate
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 300
            config.timeoutIntervalForResource = 3600
            let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)

            // FIX #1459: Track session for cancellation
            self.sessionLock.lock()
            self.activeDownloadSessions.append(session)
            self.sessionLock.unlock()

            let task = session.downloadTask(with: request)
            task.resume()
        }

        // FIX #313: Thread-safe update
        progressLock.lock()
        totalBytesDownloadedAllParts += part.size
        partBytesDownloaded.removeValue(forKey: partIndex)
        progressLock.unlock()
        print("✅ Bootstrap: Part \(partIndex + 1)/\(totalParts) complete")
    }

    // FIX #322 v2: Streaming download delegate with continuation for async/await
    // FIX #336: Added resume support with HTTP Range requests
    // Uses shared session for connection reuse + download task for efficient streaming to disk
    private class StreamingDownloadDelegate: NSObject, URLSessionDownloadDelegate {
        weak var manager: BootstrapManager?
        let partSize: Int64
        let partIndex: Int
        let totalParts: Int
        let destinationURL: URL
        let resumeOffset: Int64  // FIX #336: Bytes already downloaded
        var continuation: CheckedContinuation<URL, Error>?
        var moveError: Error?

        init(manager: BootstrapManager, partSize: Int64, partIndex: Int, totalParts: Int, destinationURL: URL, resumeOffset: Int64 = 0, continuation: CheckedContinuation<URL, Error>) {
            self.manager = manager
            self.partSize = partSize
            self.partIndex = partIndex
            self.totalParts = totalParts
            self.destinationURL = destinationURL
            self.resumeOffset = resumeOffset
            self.continuation = continuation
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            guard let manager = manager else { return }

            // FIX #336: Include resume offset in progress calculation
            let effectiveBytesWritten = resumeOffset + totalBytesWritten

            // FIX #313: Thread-safe update of this part's downloaded bytes
            manager.progressLock.lock()
            manager.partBytesDownloaded[partIndex] = effectiveBytesWritten
            let allPartsBytes = manager.totalBytesDownloadedAllParts + manager.partBytesDownloaded.values.reduce(0, +)
            manager.progressLock.unlock()

            // Download phase is 0-50% of total progress
            let overallProgress = Double(allPartsBytes) / Double(max(1, manager.totalSizeAllParts))

            Task { @MainActor in
                manager.progress = overallProgress * 0.5
                manager.updateDownloadStats(
                    bytesWritten: effectiveBytesWritten,
                    totalBytes: self.partSize,
                    overallBytesWritten: allPartsBytes,
                    overallTotalBytes: manager.totalSizeAllParts
                )
            }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            // CRITICAL: Must move/append file INSIDE this callback - temp file deleted after return
            do {
                // FIX #336: If resuming, append to existing file instead of replacing
                if resumeOffset > 0 && FileManager.default.fileExists(atPath: destinationURL.path) {
                    // Append downloaded data to existing partial file
                    let existingHandle = try FileHandle(forWritingTo: destinationURL)
                    defer { try? existingHandle.close() }
                    existingHandle.seekToEndOfFile()

                    let newData = try Data(contentsOf: location)
                    existingHandle.write(newData)
                    manager?.logVerbose("✅ FIX #336: Appended \(ByteCountFormatter.string(fromByteCount: Int64(newData.count), countStyle: .file)) to \(destinationURL.lastPathComponent)")
                } else {
                    // Fresh download - move file
                    if FileManager.default.fileExists(atPath: destinationURL.path) {
                        try FileManager.default.removeItem(at: destinationURL)
                    }
                    try FileManager.default.moveItem(at: location, to: destinationURL)
                    manager?.logVerbose("✅ FIX #322 v2: Downloaded to \(destinationURL.lastPathComponent)")
                }
            } catch {
                moveError = error
                print("❌ FIX #336: Failed to save download: \(error.localizedDescription)")
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error = error ?? moveError {
                continuation?.resume(throwing: error)
            } else {
                continuation?.resume(returning: destinationURL)
            }
            continuation = nil  // Prevent double resume
        }
    }

    // FIX #340: ChunkDownloadDelegate removed - reverted to single-stream downloads
    // Parallel chunk downloads were slower (2 MB/s) due to GitHub CDN per-connection throttling
    // Single-stream achieves full bandwidth (40-60 MB/s)

    // FIX #310: Must run on MainActor since it updates @Published properties
    @MainActor
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

            logVerbose("✅ Part \(index + 1) checksum verified")
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

        // FIX #309: Determine output filename (remove part suffix)
        // Handles both: "name-part-01.part" and "name.tar.zst.partaa"
        var baseName = release.parts[0].name
        if let range = baseName.range(of: "-part-\\d+\\.part$", options: .regularExpression) {
            // Old format: name-part-01.part → name.tar.zst
            baseName = String(baseName[..<range.lowerBound]) + ".tar.zst"
        } else if let range = baseName.range(of: "\\.part[a-z]{2}$", options: .regularExpression) {
            // Split format: name.tar.zst.partaa → name.tar.zst
            baseName = String(baseName[..<range.lowerBound])
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

            logVerbose("✅ Combined part \(index + 1)/\(release.parts.count)")
        }

        // Clean up individual part files
        for part in release.parts {
            let partPath = downloadDir.appendingPathComponent(part.name)
            try? FileManager.default.removeItem(at: partPath)
        }

        logVerbose("✅ Combined all parts into \(baseName)")
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
            logVerbose("ℹ️ Existing wallet.dat found - will be preserved (NEVER overwritten)")
        }
        if existingConfig {
            logVerbose("ℹ️ Existing zclassic.conf found - will be preserved (NEVER overwritten)")
        }

        await MainActor.run {
            self.progress = 0.7
            self.currentTask = "Extracting blockchain data (this may take several minutes)..."
        }

        // Find zstd binary
        let zstdPaths = ["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd", "/usr/bin/zstd"]
        guard let zstdPath = zstdPaths.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            throw BootstrapError.zstdNotInstalled
        }

        // FIX #282: Two-step extraction to avoid BSD tar piping issues
        // macOS BSD tar's --use-compress-program causes "broken pipe" errors
        // Step 1: Decompress .tar.zst → .tar
        // Step 2: Extract .tar → directory

        let tarPath = archivePath.deletingPathExtension()  // Remove .zst extension

        await MainActor.run {
            self.currentTask = "Decompressing archive..."
        }

        // Step 1: Decompress with zstd
        let decompressProcess = Process()
        decompressProcess.executableURL = URL(fileURLWithPath: zstdPath)
        decompressProcess.arguments = ["-d", archivePath.path, "-o", tarPath.path, "--force"]

        let decompressErrorPipe = Pipe()
        decompressProcess.standardError = decompressErrorPipe

        try decompressProcess.run()
        decompressProcess.waitUntilExit()

        guard decompressProcess.terminationStatus == 0 else {
            let errorData = decompressErrorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            print("❌ Decompression failed: \(errorMessage)")
            throw BootstrapError.extractionFailed
        }

        logVerbose("✅ FIX #282: Decompressed to \(tarPath.lastPathComponent)")

        // FIX #283 v3: Verify tar file exists and check size
        if let attrs = try? FileManager.default.attributesOfItem(atPath: tarPath.path),
           let size = attrs[.size] as? Int64 {
            logVerbose("🔧 FIX #283 v3: Tar file size: \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))")
        } else {
            logVerbose("🔧 FIX #283 v3: Tar file doesn't exist or can't read attributes!")
        }

        // Clean up .tar.zst file
        try? FileManager.default.removeItem(at: archivePath)

        await MainActor.run {
            self.progress = 0.8
            self.currentTask = "Extracting blockchain data..."
        }

        // FIX #283 v6: Extract to temp directory, then move to final location
        // This ensures clean, predictable behavior regardless of archive structure
        let tempExtractDir = dataDir.appendingPathComponent("ZipherX-bootstrap-temp")

        // Clean up any previous temp directory
        try? fm.removeItem(at: tempExtractDir)
        try fm.createDirectory(at: tempExtractDir, withIntermediateDirectories: true)

        logVerbose("🔧 FIX #283 v6: Extracting to temp directory...")

        let extractProcess = Process()
        extractProcess.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        extractProcess.arguments = ["-xf", tarPath.path, "-C", tempExtractDir.path]

        let extractErrorPipe = Pipe()
        extractProcess.standardError = extractErrorPipe

        try extractProcess.run()
        extractProcess.waitUntilExit()

        guard extractProcess.terminationStatus == 0 else {
            let errorData = extractErrorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            print("❌ Extraction failed: \(errorMessage)")
            try? fm.removeItem(at: tempExtractDir)
            throw BootstrapError.extractionFailed
        }

        logVerbose("✅ FIX #283 v6: Extraction complete")

        // Clean up .tar file
        try? FileManager.default.removeItem(at: tarPath)

        // FIX #283 v6: Find blocks and chainstate in temp directory (may be nested)
        func findDirectory(in dir: URL, containing keyword: String) -> URL? {
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey]) else {
                return nil
            }
            for item in items {
                let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDir {
                    if item.lastPathComponent.lowercased().contains(keyword) {
                        return item
                    }
                    // Check one level deeper
                    if let nested = findDirectory(in: item, containing: keyword) {
                        return nested
                    }
                }
            }
            return nil
        }

        let extractedContents = (try? fm.contentsOfDirectory(atPath: tempExtractDir.path)) ?? []
        logVerbose("🔧 FIX #283 v6: Extracted contents: \(extractedContents.joined(separator: ", "))")

        guard let blocksSource = findDirectory(in: tempExtractDir, containing: "block"),
              let chainstateSource = findDirectory(in: tempExtractDir, containing: "chainstate") else {
            print("❌ FIX #283 v6: Could not find blocks/chainstate directories in extracted archive!")
            try? fm.removeItem(at: tempExtractDir)
            throw BootstrapError.extractionFailed
        }

        logVerbose("🔧 FIX #283 v6: Found blocks at: \(blocksSource.lastPathComponent)")
        logVerbose("🔧 FIX #283 v6: Found chainstate at: \(chainstateSource.lastPathComponent)")

        // FIX #323: Check for ZcashParams in bootstrap archive
        if let zcashParamsSource = findDirectory(in: tempExtractDir, containing: "ZcashParams") {
            logVerbose("🔧 FIX #323: Found ZcashParams in bootstrap archive")

            let zcashParamsDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library")
                .appendingPathComponent("Application Support")
                .appendingPathComponent("ZcashParams")

            // Create ZcashParams directory if needed
            try fm.createDirectory(at: zcashParamsDir, withIntermediateDirectories: true)

            // Copy each param file (don't overwrite existing)
            if let paramFiles = try? fm.contentsOfDirectory(at: zcashParamsSource, includingPropertiesForKeys: nil) {
                for paramFile in paramFiles {
                    let destPath = zcashParamsDir.appendingPathComponent(paramFile.lastPathComponent)
                    if !fm.fileExists(atPath: destPath.path) {
                        try? fm.copyItem(at: paramFile, to: destPath)
                        print("✅ FIX #323: Installed \(paramFile.lastPathComponent)")
                    } else {
                        logVerbose("✅ FIX #323: \(paramFile.lastPathComponent) already exists")
                    }
                }
            }
        } else {
            logVerbose("ℹ️ FIX #323: No ZcashParams in bootstrap - will download separately if needed")
        }

        // Move to final locations
        let finalBlocksDir = dataDir.appendingPathComponent("blocks")
        let finalChainstateDir = dataDir.appendingPathComponent("chainstate")

        // Remove existing directories if any
        try? fm.removeItem(at: finalBlocksDir)
        try? fm.removeItem(at: finalChainstateDir)

        do {
            try fm.moveItem(at: blocksSource, to: finalBlocksDir)
            logVerbose("✅ FIX #283 v6: Moved blocks to final location")

            try fm.moveItem(at: chainstateSource, to: finalChainstateDir)
            logVerbose("✅ FIX #283 v6: Moved chainstate to final location")
        } catch {
            print("❌ FIX #283 v6: Failed to move directories: \(error.localizedDescription)")
            try? fm.removeItem(at: tempExtractDir)
            throw BootstrapError.extractionFailed
        }

        // Clean up temp directory
        try? fm.removeItem(at: tempExtractDir)
        logVerbose("✅ FIX #283 v6: Cleaned up temp directory")

        // Also clean up any old temp directories from previous bootstrap attempts
        let oldTempDirs = try? fm.contentsOfDirectory(at: dataDir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("zclassic-bootstrap-temp-") }
        for oldDir in oldTempDirs ?? [] {
            try? fm.removeItem(at: oldDir)
            logVerbose("🗑️ Cleaned up old temp directory: \(oldDir.lastPathComponent)")
        }

        // Handle wallet.dat - NEVER overwrite existing!
        let currentWalletPath = dataDir.appendingPathComponent("wallet.dat")
        if fm.fileExists(atPath: currentWalletPath.path) {
            if existingWallet {
                // User had existing wallet - it was preserved by tar (no --overwrite flag)
                // But if bootstrap somehow overwrote it, we have a problem
                // tar without flags should skip existing files, but let's be safe
                logVerbose("✅ Existing wallet.dat preserved")
            } else {
                // No original wallet, but bootstrap included one - remove it for security
                try? fm.removeItem(at: currentWalletPath)
                logVerbose("🗑️ Removed bootstrap's wallet.dat (security: not using someone else's wallet)")
            }
        }

        // Handle zclassic.conf - NEVER overwrite existing!
        let currentConfigPath = dataDir.appendingPathComponent("zclassic.conf")
        if fm.fileExists(atPath: currentConfigPath.path) && !existingConfig {
            // Bootstrap included a config but user didn't have one - remove bootstrap's config
            // User should generate their own or we'll create one with fresh credentials
            try? fm.removeItem(at: currentConfigPath)
            logVerbose("🗑️ Removed bootstrap's zclassic.conf (will generate fresh one)")
        }

        await MainActor.run {
            self.progress = 0.85
        }

        print("✅ Bootstrap complete")
    }

    // MARK: - Configuration

    private func configureZclassicConf() throws {
        let dataDir = RPCClient.zclassicDataDir
        let configPath = dataDir.appendingPathComponent("zclassic.conf")

        // FIX #273: Create data directory if it doesn't exist
        if !FileManager.default.fileExists(atPath: dataDir.path) {
            try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
            logVerbose("📁 Created Zclassic data directory: \(dataDir.path)")
        }

        // NEVER overwrite existing config!
        if FileManager.default.fileExists(atPath: configPath.path) {
            logVerbose("ℹ️ Existing zclassic.conf found - NOT overwriting (user's config preserved)")
            return
        }

        // Only generate if no config exists
        // Generate random RPC credentials
        let rpcUser = "zipherx_\(randomString(length: 8))"
        let rpcPassword = randomString(length: 32)

        // FIX #324: Comprehensive zclassic.conf with ALL valid parameters
        let config = """
        # ═══════════════════════════════════════════════════════════════════════════════
        # ZCLASSIC CONFIGURATION FILE
        # Generated by ZipherX on \(ISO8601DateFormatter().string(from: Date()))
        # ═══════════════════════════════════════════════════════════════════════════════
        #
        # This file contains all valid Zclassic daemon parameters.
        # Lines starting with # are comments (disabled options).
        # Remove # to enable an option.
        #
        # Documentation: https://github.com/AegeusCoin/aegeus/blob/master/doc/man/aegeusd.1
        # ═══════════════════════════════════════════════════════════════════════════════

        # ───────────────────────────────────────────────────────────────────────────────
        # RPC SERVER SETTINGS
        # Required for wallet applications to communicate with the daemon
        # ───────────────────────────────────────────────────────────────────────────────

        # Enable RPC server (required for ZipherX wallet communication)
        server=1

        # RPC authentication credentials (KEEP THESE SECRET!)
        rpcuser=\(rpcUser)
        rpcpassword=\(rpcPassword)

        # RPC port (default: 8023 mainnet, 18023 testnet)
        rpcport=8023

        # Allow RPC connections from these IPs (use 127.0.0.1 for local only)
        rpcallowip=127.0.0.1

        # Bind RPC to specific address (default: bind to all interfaces)
        # rpcbind=127.0.0.1

        # Number of threads to service RPC calls (default: 4)
        # rpcthreads=4

        # Enable public REST requests (default: 0)
        # rest=0

        # ───────────────────────────────────────────────────────────────────────────────
        # NETWORK SETTINGS
        # Control how the daemon connects to the P2P network
        # ───────────────────────────────────────────────────────────────────────────────

        # Accept incoming connections (default: 1)
        listen=1

        # Run as background daemon (default: 0)
        daemon=1

        # P2P port (default: 8033 mainnet, 18033 testnet)
        port=8033

        # Maximum peer connections (default: 125)
        maxconnections=32

        # Discover own IP addresses (default: 1)
        # discover=1

        # Allow DNS lookups for -addnode, -seednode, -connect (default: 1)
        # dns=1

        # Query for peer addresses via DNS lookup (default: 1)
        # dnsseed=1

        # Always query for peer addresses via DNS lookup (default: 0)
        # forcednsseed=0

        # Add specific nodes to connect to (can specify multiple times)
        # addnode=seed.zclassic.org
        # addnode=dnsseed.zclassic.org

        # Connect ONLY to specified nodes (isolates from public network)
        # connect=192.168.1.100

        # Seed node to retrieve peer addresses then disconnect
        # seednode=seed.example.com

        # Specify your own public IP address
        # externalip=1.2.3.4

        # Bind to specific address (use [host]:port for IPv6)
        # bind=0.0.0.0

        # Only connect to nodes in network: ipv4, ipv6, or onion
        # onlynet=ipv4

        # Connection timeout in milliseconds (default: 5000)
        # timeout=5000

        # Maximum per-connection receive buffer in KB (default: 5000)
        # maxreceivebuffer=5000

        # Maximum per-connection send buffer in KB (default: 1000)
        # maxsendbuffer=1000

        # ───────────────────────────────────────────────────────────────────────────────
        # TOR / ONION SETTINGS (Privacy Network)
        # Route connections through Tor for enhanced privacy
        # ───────────────────────────────────────────────────────────────────────────────

        # Connect through SOCKS5 proxy (Tor default: 127.0.0.1:9050)
        # proxy=127.0.0.1:9050

        # Automatically create Tor hidden service (default: 1 if Tor detected)
        # listenonion=1

        # Use separate SOCKS5 proxy for Tor hidden services
        # onion=127.0.0.1:9050

        # Tor control port for hidden service management (default: 127.0.0.1:9051)
        # torcontrol=127.0.0.1:9051

        # Tor control port password (if set in torrc)
        # torpassword=

        # Randomize credentials for each proxy connection (Tor stream isolation, default: 1)
        # proxyrandomize=1

        # Enable BIP155 addrv2 for Tor v3 address discovery (default: 1)
        # enablebip155=1

        # ───────────────────────────────────────────────────────────────────────────────
        # BLOCKCHAIN & DATABASE SETTINGS
        # Control storage, indexing, and verification
        # ───────────────────────────────────────────────────────────────────────────────

        # Maintain full transaction index for getrawtransaction RPC (default: 0)
        # REQUIRED for full wallet functionality
        txindex=1

        # Database cache size in megabytes (default: 450, min: 4, max: 16384)
        dbcache=512

        # Number of script verification threads (0=auto, default: 0)
        # par=0

        # How many blocks to check at startup (default: 288, 0=all)
        checkblocks=24

        # Block verification thoroughness 0-4 (default: 3)
        checklevel=3

        # Rebuild blockchain index from blk*.dat files on startup
        # reindex=0

        # Disable fast-sync from Arweave, sync from genesis (default: 0)
        # nofastsync=0

        # Reduce storage by pruning old blocks (DISABLES wallet & txindex!)
        # prune=0

        # ───────────────────────────────────────────────────────────────────────────────
        # WALLET SETTINGS
        # Control wallet behavior, fees, and security
        # ───────────────────────────────────────────────────────────────────────────────

        # Disable wallet functionality entirely (default: 0)
        # disablewallet=0

        # Wallet file name (default: wallet.dat)
        # wallet=wallet.dat

        # Key pool size for address pre-generation (default: 100)
        # keypool=100

        # Rescan blockchain for missing wallet transactions on startup
        # rescan=0

        # Attempt to recover private keys from corrupt wallet.dat
        # salvagewallet=0

        # Upgrade wallet to latest format on startup
        # upgradewallet=0

        # Delete wallet transactions and recover via rescan (mode: 1 or 2)
        # zapwallettxes=1

        # Spend unconfirmed change when sending (default: 1)
        # spendzeroconfchange=1

        # Make wallet broadcast transactions (default: 1)
        # walletbroadcast=1

        # Execute command when wallet transaction changes (%s = TxID)
        # walletnotify=/path/to/script.sh %s

        # ───────────────────────────────────────────────────────────────────────────────
        # TRANSACTION FEE SETTINGS
        # Control transaction fees for sending
        # ───────────────────────────────────────────────────────────────────────────────

        # Fee per kB to add to transactions you send (default: 0.00001)
        # paytxfee=0.00001

        # Minimum fee per kB for transaction creation (default: 0.00001)
        # mintxfee=0.00001

        # Minimum fee per kB for relaying transactions (default: 0.00001)
        # minrelaytxfee=0.00001

        # Target blocks for transaction confirmation (default: 2)
        # txconfirmtarget=2

        # Send zero-fee transactions if possible (default: 0)
        # sendfreetransactions=0

        # Maximum total fees in single wallet transaction (default: 0.1)
        # maxtxfee=0.1

        # Blocks until unmined transaction expires (default: 20)
        # txexpirydelta=20

        # ───────────────────────────────────────────────────────────────────────────────
        # MINING SETTINGS
        # Configure local mining (if enabled)
        # ───────────────────────────────────────────────────────────────────────────────

        # Enable mining (default: 0)
        # gen=0

        # Number of mining threads (-1=all cores, default: 1)
        # genproclimit=1

        # Send mined coins to specific address
        # mineraddress=

        # Mine to local wallet addresses (default: 1 if mineraddress not set)
        # minetolocalwallet=1

        # Equihash solver to use (default: "default")
        # equihashsolver=default

        # ───────────────────────────────────────────────────────────────────────────────
        # BLOCK SETTINGS
        # Control block creation and relay
        # ───────────────────────────────────────────────────────────────────────────────

        # Minimum block size in bytes (default: 0)
        # blockminsize=0

        # Maximum block size in bytes (default: 2000000)
        # blockmaxsize=2000000

        # Max size of high-priority/low-fee transactions (default: 50000)
        # blockprioritysize=50000

        # Relay and mine data carrier transactions (default: 1)
        # datacarrier=1

        # Max size of OP_RETURN data in bytes (default: 80)
        # datacarriersize=80

        # ───────────────────────────────────────────────────────────────────────────────
        # PEER MANAGEMENT & SECURITY
        # Control peer behavior and ban policies
        # ───────────────────────────────────────────────────────────────────────────────

        # Ban score threshold for misbehaving peers (default: 100)
        # banscore=100

        # Seconds to ban misbehaving peers (default: 86400 = 24 hours)
        # bantime=86400

        # Whitelist peers from specific IP/netmask (won't be banned)
        # whitelist=192.168.1.0/24

        # Bind and whitelist peers connecting to this address
        # whitebind=0.0.0.0:8033

        # Relay non-P2SH multisig transactions (default: 1)
        # permitbaremultisig=1

        # Support Bloom filter queries from peers (default: 1)
        # peerbloomfilters=1

        # Receive and display P2P network alerts (default: 1)
        # alerts=1

        # ───────────────────────────────────────────────────────────────────────────────
        # NOTIFICATION SETTINGS
        # Execute commands on blockchain events
        # ───────────────────────────────────────────────────────────────────────────────

        # Execute command when relevant alert received (%s = message)
        # alertnotify=/path/to/alert.sh %s

        # Execute command when best block changes (%s = block hash)
        # blocknotify=/path/to/block.sh %s

        # ───────────────────────────────────────────────────────────────────────────────
        # ZMQ NOTIFICATION SETTINGS
        # Publish blockchain events via ZeroMQ (for external applications)
        # ───────────────────────────────────────────────────────────────────────────────

        # Publish block hash via ZMQ
        # zmqpubhashblock=tcp://127.0.0.1:28332

        # Publish transaction hash via ZMQ
        # zmqpubhashtx=tcp://127.0.0.1:28332

        # Publish raw block data via ZMQ
        # zmqpubrawblock=tcp://127.0.0.1:28332

        # Publish raw transaction data via ZMQ
        # zmqpubrawtx=tcp://127.0.0.1:28332

        # ───────────────────────────────────────────────────────────────────────────────
        # DEBUG & LOGGING SETTINGS
        # Control debug output and log files
        # ───────────────────────────────────────────────────────────────────────────────

        # Write debug output to debug.log file (default: 0 for privacy)
        debuglogfile=1

        # Debug categories: addrman, alert, bench, coindb, db, estimatefee,
        # http, libevent, lock, mempool, net, partitioncheck, pow, proxy,
        # prune, rand, reindex, rpc, selectcoins, tor, zmq, zrpc, zrpcunsafe
        # Use debug=1 for ALL categories
        debug=net

        # Include IP addresses in debug output (default: 0)
        # logips=0

        # Prepend timestamps to debug output (default: 1)
        # logtimestamps=1

        # Send debug output to console instead of debug.log
        # printtoconsole=0

        # ───────────────────────────────────────────────────────────────────────────────
        # EXPERIMENTAL FEATURES
        # Enable experimental/testing features (use with caution!)
        # ───────────────────────────────────────────────────────────────────────────────

        # Enable experimental features (required for some zk-SNARK options)
        # experimentalfeatures=0

        # Use testnet instead of mainnet
        # testnet=0

        # ───────────────────────────────────────────────────────────────────────────────
        # PERFORMANCE TUNING
        # Advanced settings for performance optimization
        # ───────────────────────────────────────────────────────────────────────────────

        # Keep at most N unconnectable transactions in memory (default: 100)
        # maxorphantx=100

        # Max tip age in seconds to consider node in IBD (default: 86400)
        # maxtipage=86400

        # Limit signature cache size in MiB (default: 40)
        # maxsigcachesize=40

        # Enable checkpoints for known chain history (default: 1)
        # checkpoints=1

        # ═══════════════════════════════════════════════════════════════════════════════
        # END OF CONFIGURATION
        # ═══════════════════════════════════════════════════════════════════════════════
        """

        try config.write(to: configPath, atomically: true, encoding: .utf8)
        logVerbose("✅ Generated new zclassic.conf with random credentials and Tor support")
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

        // FIX #323: Download ALL required params (Sapling + Sprout)
        // Without Sprout params, zclassicd downloads them from Arweave on first start
        let requiredParams: [(String, String, String)] = [
            // Sapling params (from z.cash)
            ("sapling-spend.params", "8e48ffd23abb3a5fd9c5589204f32d9c31285a04b78096ba40a79b75677efc13", "https://z.cash/downloads/sapling-spend.params"),
            ("sapling-output.params", "2f0ebbcbb9bb0bcffe95a397e7eba89c29eb4dde6191c339db88570e3f3fb0e4", "https://z.cash/downloads/sapling-output.params"),
            // Sprout params (from z.cash)
            ("sprout-groth16.params", "b685d700c60328498fbde589c8c7c484c722b788b265b72af448a5bf0ee55b50", "https://z.cash/downloads/sprout-groth16.params"),
            ("sprout-proving.key", "8bc20a7f013b2b58970cddd2e7ea028975c88ae7ceb9259a5344a16bc2c0eef7", "https://z.cash/downloads/sprout-proving.key.deprecated-sworn-elves"),
            ("sprout-verifying.key", "4bd498dae0aacfd8e98dc306338d017d9c08dd0918ead18172bd0aec2fc5df82", "https://z.cash/downloads/sprout-verifying.key")
        ]

        // Create params directory
        try FileManager.default.createDirectory(at: paramsDir, withIntermediateDirectories: true)

        for (index, (filename, expectedHash, downloadURLString)) in requiredParams.enumerated() {
            let filePath = paramsDir.appendingPathComponent(filename)

            if FileManager.default.fileExists(atPath: filePath.path) {
                logVerbose("✅ \(filename) already exists")
                continue
            }

            await MainActor.run {
                self.currentTask = "Downloading \(filename) (\(index + 1)/\(requiredParams.count))..."
            }

            // Download param file
            guard let downloadURL = URL(string: downloadURLString) else {
                print("❌ Invalid URL for \(filename)")
                continue
            }

            // FIX #1537: Route through Tor when available
            let dlSession: URLSession
            let torMode = await TorManager.shared.mode
            let torConnected = await TorManager.shared.connectionState.isConnected
            if torMode == .enabled && torConnected {
                dlSession = await TorManager.shared.getTorURLSession(isolate: true)
            } else {
                dlSession = URLSession.shared
            }
            let (data, _) = try await dlSession.data(from: downloadURL)

            // Write file
            try data.write(to: filePath)
            print("✅ Downloaded \(filename) (\(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)))")
        }

        await MainActor.run {
            self.progress = 0.95
        }
    }

    // MARK: - Status Updates

    private func updateStatus(_ status: BootstrapStatus, task: String) async {
        // FIX #317: End timing for previous task
        let previousStatus = self.status
        await endTaskTimingForStatus(previousStatus)

        // FIX #317: Start timing for new task
        startTaskTimingForStatus(status)

        // FIX #1458: Track last active step before error/cancel for task list display
        switch status {
        case .error, .cancelled:
            await MainActor.run { self.lastStepBeforeError = previousStatus }
        default:
            break
        }

        // FIX #312: Stop timer on completion/error states
        switch status {
        case .complete, .completeNeedsDaemon, .completeDaemonStopped, .error, .cancelled:
            stopElapsedTimeTimer()
            // FIX #317: End timing for final task
            await endTaskTimingForStatus(status)
        default:
            break
        }

        await MainActor.run {
            self.status = status
            self.currentTask = task
        }
    }

    // FIX #317: Get task key for status
    private func taskKeyForStatus(_ status: BootstrapStatus) -> String? {
        switch status {
        case .checkingRelease: return "checkingRelease"
        case .downloading: return "downloading"
        case .verifying: return "verifying"
        case .combining: return "combining"
        case .extracting: return "extracting"
        case .configuringDaemon: return "configuringDaemon"
        case .downloadingParams: return "downloadingParams"
        case .startingDaemon: return "startingDaemon"
        case .syncingBlocks: return "syncingBlocks"
        default: return nil
        }
    }

    // FIX #317: Start timing for a status
    private func startTaskTimingForStatus(_ status: BootstrapStatus) {
        if let key = taskKeyForStatus(status) {
            startTaskTiming(key)
        }
    }

    // FIX #317: End timing for a status
    @MainActor
    private func endTaskTimingForStatus(_ status: BootstrapStatus) {
        if let key = taskKeyForStatus(status) {
            endTaskTiming(key)
        }
    }
}

// MARK: - Errors

public enum BootstrapError: Error, LocalizedError {
    case noAssetFound
    case releaseNotFound
    case downloadFailed(String)  // FIX #279: Added message parameter
    case checksumMismatch
    case extractionFailed
    case configurationFailed
    case cancelled
    case zstdNotInstalled
    case daemonInstallFailed(String)  // FIX #285: Daemon installation failed

    public var errorDescription: String? {
        switch self {
        case .noAssetFound:
            return "No bootstrap archive found in release"
        case .releaseNotFound:
            return "Could not find latest bootstrap release on GitHub"
        case .downloadFailed(let message):
            return "Failed to download bootstrap: \(message)"
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
        case .daemonInstallFailed(let message):
            return "Failed to install daemon: \(message)"
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
