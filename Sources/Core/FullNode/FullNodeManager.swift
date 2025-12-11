import Foundation
import Combine

#if os(macOS)

/// Manages Full Node mode for ZipherX (macOS only)
///
/// IMPORTANT SECURITY DESIGN:
/// - ZipherX ALWAYS uses its own wallet (SecureKeyStorage + WalletDatabase)
/// - The local zclassicd wallet.dat is NEVER used for private keys
/// - Full Node mode only provides:
///   1. Daemon status monitoring (running/syncing)
///   2. Block height from trusted local source
///   3. Transaction verification against full blockchain
///
/// This ensures:
/// - User's private keys remain in ZipherX's encrypted storage
/// - No risk of wallet.dat exposure
/// - Consistent wallet experience across Light and Full Node modes
public class FullNodeManager: ObservableObject {
    public static let shared = FullNodeManager()

    // MARK: - Published State

    @Published public private(set) var daemonStatus: DaemonStatus = .unknown
    @Published public private(set) var isNodeInstalled: Bool = false
    @Published public private(set) var hasBlockchain: Bool = false
    @Published public private(set) var blockchainSize: String = ""
    @Published public private(set) var daemonBlockHeight: UInt64 = 0
    @Published public private(set) var daemonSyncProgress: Double = 0.0

    /// Tracks whether daemon needs restart to use Tor proxy
    /// Set to true when Tor connects and proxy is written to config
    /// Set to false when daemon is restarted (in startDaemon)
    @Published public private(set) var needsTorRestart: Bool = false

    // MARK: - Daemon Status

    public enum DaemonStatus: Equatable {
        case unknown
        case notInstalled
        case installed
        case starting
        case running
        case syncing(progress: Double)
        case stopped
        case error(String)

        public var displayText: String {
            switch self {
            case .unknown: return "Checking..."
            case .notInstalled: return "Not Installed"
            case .installed: return "Installed (Stopped)"
            case .starting: return "Starting..."
            case .running: return "Running"
            case .syncing(let progress): return "Syncing (\(Int(progress * 100))%)"
            case .stopped: return "Stopped"
            case .error(let msg): return "Error: \(msg)"
            }
        }

        public var isRunning: Bool {
            switch self {
            case .running, .syncing: return true
            default: return false
            }
        }
    }

    // MARK: - Paths

    /// Path to zclassicd daemon
    public static var daemonPath: URL {
        URL(fileURLWithPath: "/usr/local/bin/zclassicd")
    }

    /// Path to zclassic-cli
    public static var cliPath: URL {
        URL(fileURLWithPath: "/usr/local/bin/zclassic-cli")
    }

    /// Zclassic data directory
    public static var dataDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("ZClassic")
    }

    /// Path to blocks directory
    public static var blocksDir: URL {
        dataDir.appendingPathComponent("blocks")
    }

    /// Path to wallet.dat
    public static var walletPath: URL {
        dataDir.appendingPathComponent("wallet.dat")
    }

    /// Path to zclassic.conf
    public static var configPath: URL {
        dataDir.appendingPathComponent("zclassic.conf")
    }

    // MARK: - Auto-Refresh Timer

    private var statusRefreshTimer: Timer?
    private static let STATUS_REFRESH_INTERVAL: TimeInterval = 5.0  // Refresh every 5 seconds

    // MARK: - Initialization

    private init() {
        // Load saved debug level from UserDefaults
        self.daemonDebugLevel = .none
        self.daemonDebugLevel = loadDebugLevel()

        // FIX #135: Only check node status and start polling in Full Node mode
        // In Light Mode, there's no daemon to poll - avoid "Connection refused" spam
        if WalletModeManager.shared.currentMode == .fullNode {
            checkNodeStatus()
            startAutoRefresh()
        } else {
            // In Light Mode, set status to unknown and don't poll
            daemonStatus = .unknown
        }
    }

    deinit {
        stopAutoRefresh()
    }

    /// Start automatic status refresh timer
    /// FIX #135: Only starts polling if in Full Node mode
    public func startAutoRefresh() {
        stopAutoRefresh()

        // FIX #135: Don't poll daemon in Light Mode
        guard WalletModeManager.shared.currentMode == .fullNode else {
            print("📱 FullNodeManager: Light Mode - skipping daemon status polling")
            return
        }

        statusRefreshTimer = Timer.scheduledTimer(withTimeInterval: Self.STATUS_REFRESH_INTERVAL, repeats: true) { [weak self] _ in
            self?.checkNodeStatus()
        }
    }

    /// Stop automatic status refresh
    public func stopAutoRefresh() {
        statusRefreshTimer?.invalidate()
        statusRefreshTimer = nil
    }

    // MARK: - Status Checking

    /// Check overall node status
    /// FIX #135: Only checks status in Full Node mode
    public func checkNodeStatus() {
        // FIX #135: Skip status check in Light Mode - no daemon to check
        guard WalletModeManager.shared.currentMode == .fullNode else {
            // Stop the timer if it's running in Light Mode (shouldn't happen but safety check)
            stopAutoRefresh()
            return
        }

        Task {
            await checkInstallation()
            await checkBlockchain()
            await checkDaemonRunning()
        }
    }

    /// Check if zclassicd is installed
    @MainActor
    private func checkInstallation() async {
        let fm = FileManager.default
        isNodeInstalled = fm.fileExists(atPath: Self.daemonPath.path)

        if !isNodeInstalled {
            daemonStatus = .notInstalled
        }
    }

    /// Check if blockchain data exists
    @MainActor
    private func checkBlockchain() async {
        let fm = FileManager.default

        if fm.fileExists(atPath: Self.blocksDir.path) {
            hasBlockchain = true

            // Calculate blockchain size
            if let size = getDirectorySize(Self.dataDir) {
                blockchainSize = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
            }
        } else {
            hasBlockchain = false
            blockchainSize = "No data"
        }
    }

    /// Check if daemon is currently running
    /// Detection priority: RPC connection (most reliable) > binary path check
    @MainActor
    private func checkDaemonRunning() async {
        // FIRST: Try to connect via RPC - this detects ANY running zclassicd
        // regardless of where the binary is installed (Zipher.app, /usr/local/bin, etc.)
        do {
            try RPCClient.shared.loadConfig()
            print("✅ Full Node: config loaded successfully")

            // Try to connect to running daemon
            let connected = await RPCClient.shared.checkConnection()
            print("🔄 Full Node: RPC connection result = \(connected)")

            if connected {
                isNodeInstalled = true  // Daemon is running, so it's "installed" somewhere
                print("✅ Full Node: daemon is RUNNING (detected via RPC)")

                // Set initial status to syncing - checkSyncStatus will update to .running when fully synced
                // This prevents showing "Running" while daemon is still in "Loading block index" phase
                if case .running = daemonStatus {
                    // Keep as .running only if already confirmed running
                } else if case .syncing = daemonStatus {
                    // Keep current syncing status
                } else {
                    // Initial state - assume syncing until confirmed
                    daemonStatus = .syncing(progress: 0)
                }

                // Check sync status and block height - this will update status appropriately
                await checkSyncStatus()
                return
            }
        } catch {
            print("⚠️ Full Node: config/RPC check failed - \(error.localizedDescription)")
        }

        // FALLBACK: Check if binary exists at standard path
        if !isNodeInstalled {
            print("🔴 Full Node: daemon not installed at standard path")
            daemonStatus = .notInstalled
            return
        }

        // Binary exists but daemon not running
        print("🔴 Full Node: daemon installed but not running")
        daemonStatus = hasBlockchain ? .installed : .notInstalled
    }

    /// Check blockchain sync status and get block height
    @MainActor
    private func checkSyncStatus() async {
        // Allow checking if running OR syncing
        switch daemonStatus {
        case .running, .syncing:
            break
        default:
            return
        }

        do {
            let info = try await RPCClient.shared.getBlockchainInfo()

            // Get sync progress and block info
            let headers = info["headers"] as? Int ?? 0
            let blocks = info["blocks"] as? Int ?? 0
            let verificationProgress = info["verificationprogress"] as? Double ?? 0.0

            // Note: Zclassic doesn't have initialblockdownload field
            // verificationprogress is unreliable (can be 65% even when fully synced)
            // The only reliable check is blocks == headers

            daemonBlockHeight = UInt64(blocks)

            // Calculate true sync progress based on blocks/headers ratio
            let trueSyncProgress: Double
            if headers > 0 {
                trueSyncProgress = Double(blocks) / Double(headers)
            } else {
                trueSyncProgress = verificationProgress
            }
            daemonSyncProgress = trueSyncProgress

            // Check if fully synced: headers > 0 AND blocks == headers
            let isFullySynced = headers > 0 && headers == blocks

            if isFullySynced {
                daemonStatus = .running
            } else {
                daemonStatus = .syncing(progress: trueSyncProgress)
            }
        } catch {
            // RPC failed - daemon might still be loading
            print("⚠️ checkSyncStatus: RPC failed - \(error.localizedDescription)")

            // If we thought it was running but RPC failed, it's probably still loading
            if case .running = daemonStatus {
                daemonStatus = .syncing(progress: 0)
            }
        }
    }

    /// Get the current block height from daemon (for use as trusted source)
    public func getBlockHeight() async -> UInt64? {
        guard daemonStatus.isRunning else { return nil }

        do {
            let info = try await RPCClient.shared.getInfoDict()
            if let blocks = info["blocks"] as? Int {
                return UInt64(blocks)
            }
        } catch {
            print("⚠️ FullNodeManager: Failed to get block height: \(error)")
        }
        return nil
    }

    /// Verify a transaction exists in the blockchain
    public func verifyTransaction(txid: String) async -> Bool {
        guard daemonStatus.isRunning else { return false }

        do {
            _ = try await RPCClient.shared.getTransaction(txid: txid)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Daemon Control

    /// Start the daemon (if not already running)
    /// IMPORTANT: Never stops an already running daemon!
    public func startDaemon() async throws {
        guard isNodeInstalled else {
            throw FullNodeError.daemonNotInstalled
        }

        // Check if already running - DO NOT STOP IT!
        if daemonStatus.isRunning {
            print("ℹ️ Daemon is already running, not restarting")
            return
        }

        await MainActor.run {
            daemonStatus = .starting
        }

        // Ensure config exists
        try ensureConfig()

        // Start daemon process
        let process = Process()
        process.executableURL = Self.daemonPath
        process.arguments = ["-daemon"]

        do {
            try process.run()

            // Wait for daemon to start (up to 30 seconds for RPC connection)
            var rpcConnected = false
            for i in 1...30 {
                try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second

                if await RPCClient.shared.checkConnection() {
                    rpcConnected = true
                    print("✅ Daemon RPC connected after \(i) seconds, waiting for full sync...")
                    break
                }
            }

            guard rpcConnected else {
                throw FullNodeError.startupTimeout
            }

            // Clear the Tor restart flag - daemon just started with latest config
            await MainActor.run {
                needsTorRestart = false
            }

            // Now wait for daemon to be fully synced (up to 10 minutes)
            // Check every 2 seconds
            for attempt in 1...300 {
                do {
                    let info = try await RPCClient.shared.getBlockchainInfo()

                    // Get sync progress and block info
                    let headers = info["headers"] as? Int ?? 0
                    let blocks = info["blocks"] as? Int ?? 0

                    // Note: Zclassic doesn't have initialblockdownload field
                    // verificationprogress is unreliable (can be 65% even when fully synced)
                    // The only reliable check is blocks == headers

                    // Calculate true sync progress based on blocks/headers ratio
                    let trueSyncProgress: Double
                    if headers > 0 {
                        trueSyncProgress = Double(blocks) / Double(headers)
                    } else {
                        let verificationProgress = info["verificationprogress"] as? Double ?? 0.0
                        trueSyncProgress = verificationProgress
                    }

                    await MainActor.run {
                        self.daemonSyncProgress = trueSyncProgress
                        self.daemonBlockHeight = UInt64(blocks)

                        // Update status based on sync state
                        if headers == 0 || blocks < headers {
                            self.daemonStatus = .syncing(progress: trueSyncProgress)
                        }
                    }

                    // Log progress every 10 attempts (20 seconds)
                    if attempt % 10 == 0 {
                        print("🔄 Daemon sync: \(Int(trueSyncProgress * 100))% (block \(blocks)/\(headers))")
                    }

                    // Check if fully synced: headers > 0 AND blocks == headers
                    let isFullySynced = headers > 0 && headers == blocks

                    if isFullySynced {
                        await MainActor.run {
                            self.daemonStatus = .running
                        }
                        print("✅ Daemon fully synced and ready! Block height: \(blocks)")
                        return
                    }

                } catch {
                    print("⚠️ Error checking sync status: \(error.localizedDescription)")
                }

                try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
            }

            // If we get here, daemon is still syncing after 10 minutes
            // Keep status as syncing and let user know daemon is still working
            print("⚠️ Daemon still syncing after 10 minutes - continuing in background")
            // Don't throw error - daemon is running, just not fully synced yet
            return
        } catch {
            await MainActor.run {
                daemonStatus = .error(error.localizedDescription)
            }
            throw error
        }
    }

    /// Ensure zclassic.conf exists with proper settings
    private func ensureConfig() throws {
        let fm = FileManager.default

        // Create data directory if needed
        if !fm.fileExists(atPath: Self.dataDir.path) {
            try fm.createDirectory(at: Self.dataDir, withIntermediateDirectories: true)
        }

        // Check if config already exists
        if fm.fileExists(atPath: Self.configPath.path) {
            // Config exists, don't overwrite (user may have customized it)
            return
        }

        // Generate random credentials
        let rpcUser = "zipherx\(randomString(length: 8))"
        let rpcPassword = randomString(length: 32)

        let config = """
        # ZipherX Full Node Configuration
        # Generated: \(Date())

        rpcuser=\(rpcUser)
        rpcpassword=\(rpcPassword)
        rpcport=8023
        rpcallowip=127.0.0.1

        # Network
        listen=1
        server=1

        # Performance
        dbcache=512
        maxconnections=16

        # Indexes
        txindex=1
        """

        try config.write(to: Self.configPath, atomically: true, encoding: .utf8)
        print("✅ Created zclassic.conf")
    }

    // MARK: - Daemon Installation

    /// Official source URL for building from source
    public static let officialSourceURL = "https://github.com/ZclassicCommunity/zclassic"

    /// Bootstrap download URL for fast sync
    public static let bootstrapURL = "https://github.com/VictorLux/zclassic-bootstrap"

    /// Path to bundled daemon in app bundle
    private static var bundledDaemonPath: URL? {
        Bundle.main.url(forResource: "zclassicd", withExtension: nil, subdirectory: "Binaries")
    }

    /// Path to bundled CLI in app bundle
    private static var bundledCliPath: URL? {
        Bundle.main.url(forResource: "zclassic-cli", withExtension: nil, subdirectory: "Binaries")
    }

    /// Check if daemon binaries are bundled with the app
    public var hasBundledDaemon: Bool {
        Self.bundledDaemonPath != nil && Self.bundledCliPath != nil
    }

    /// Check if daemon is installed at /usr/local/bin
    public var isDaemonInstalledAtPath: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: Self.daemonPath.path) &&
               fm.fileExists(atPath: Self.cliPath.path)
    }

    /// Install daemon binaries from app bundle to /usr/local/bin
    /// Returns true on success
    public func installDaemonFromBundle() async throws {
        guard let daemonSource = Self.bundledDaemonPath,
              let cliSource = Self.bundledCliPath else {
            throw FullNodeError.daemonNotBundled
        }

        let fm = FileManager.default

        // Check if /usr/local/bin exists, create if not
        let binDir = URL(fileURLWithPath: "/usr/local/bin")
        if !fm.fileExists(atPath: binDir.path) {
            try fm.createDirectory(at: binDir, withIntermediateDirectories: true)
        }

        // Copy daemon binary (overwrite if exists)
        let daemonDest = Self.daemonPath
        if fm.fileExists(atPath: daemonDest.path) {
            try fm.removeItem(at: daemonDest)
        }
        try fm.copyItem(at: daemonSource, to: daemonDest)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: daemonDest.path)
        print("✅ Installed zclassicd to \(daemonDest.path)")

        // Copy CLI binary (overwrite if exists)
        let cliDest = Self.cliPath
        if fm.fileExists(atPath: cliDest.path) {
            try fm.removeItem(at: cliDest)
        }
        try fm.copyItem(at: cliSource, to: cliDest)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cliDest.path)
        print("✅ Installed zclassic-cli to \(cliDest.path)")

        await MainActor.run {
            isNodeInstalled = true
            daemonStatus = .installed
        }
    }

    /// Get daemon version if installed
    public func getDaemonVersion() async -> String? {
        guard isDaemonInstalledAtPath else { return nil }

        let process = Process()
        process.executableURL = Self.daemonPath
        process.arguments = ["--version"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                return output.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } catch {
            print("⚠️ Could not get daemon version: \(error)")
        }
        return nil
    }

    // MARK: - Tor Integration

    /// Update zclassic.conf with Tor proxy settings
    /// Called by TorManager when Arti connects with a SOCKS port
    public func updateTorProxy(host: String, port: UInt16) {
        let configPath = Self.configPath

        guard FileManager.default.fileExists(atPath: configPath.path) else {
            print("⚠️ FullNodeManager: zclassic.conf not found, cannot update Tor proxy")
            return
        }

        do {
            var config = try String(contentsOf: configPath, encoding: .utf8)
            var lines = config.components(separatedBy: "\n")
            var proxyFound = false
            var onlynetFound = false

            // Update or add proxy line
            for i in 0..<lines.count {
                if lines[i].hasPrefix("proxy=") {
                    lines[i] = "proxy=\(host):\(port)"
                    proxyFound = true
                    print("🧅 FullNodeManager: Updated proxy to \(host):\(port)")
                }
                if lines[i].hasPrefix("onlynet=") {
                    onlynetFound = true
                }
            }

            if !proxyFound {
                // Add proxy setting before first blank line or at end
                let proxyLine = "proxy=\(host):\(port)"
                if let firstEmpty = lines.firstIndex(where: { $0.isEmpty }) {
                    lines.insert(proxyLine, at: firstEmpty)
                } else {
                    lines.append(proxyLine)
                }
                print("🧅 FullNodeManager: Added proxy=\(host):\(port)")
            }

            // Optionally add onlynet=onion for maximum privacy
            // (commented out - user may want clearnet fallback)
            // if !onlynetFound {
            //     lines.append("onlynet=onion")
            // }

            config = lines.joined(separator: "\n")
            try config.write(to: configPath, atomically: true, encoding: .utf8)

            print("✅ FullNodeManager: zclassic.conf updated with Tor proxy")

            // Note: Daemon needs restart to pick up new proxy
            // Mark that daemon needs restart to use Tor
            if daemonStatus.isRunning {
                DispatchQueue.main.async {
                    self.needsTorRestart = true
                    print("⚠️ FullNodeManager: Daemon needs restart to use Tor proxy")
                }
            }

        } catch {
            print("❌ FullNodeManager: Failed to update zclassic.conf: \(error)")
        }
    }

    /// Remove Tor proxy setting from zclassic.conf
    /// Called when Tor is disabled
    public func removeTorProxy() {
        let configPath = Self.configPath

        guard FileManager.default.fileExists(atPath: configPath.path) else { return }

        do {
            var config = try String(contentsOf: configPath, encoding: .utf8)
            var lines = config.components(separatedBy: "\n")

            // Remove proxy and onlynet lines
            lines.removeAll { line in
                line.hasPrefix("proxy=") || line.hasPrefix("onlynet=onion")
            }

            config = lines.joined(separator: "\n")
            try config.write(to: configPath, atomically: true, encoding: .utf8)

            print("🧅 FullNodeManager: Removed Tor proxy from zclassic.conf")

        } catch {
            print("❌ FullNodeManager: Failed to remove proxy from zclassic.conf: \(error)")
        }
    }

    /// Restart daemon's network to apply new proxy settings
    /// Note: Most settings require daemon restart to take effect
    /// This method logs that a restart is needed
    public func refreshDaemonNetwork() async {
        guard daemonStatus.isRunning else { return }

        // Most network settings (including proxy) require a full daemon restart
        // Just log a message - the daemon will pick up new proxy on next restart
        print("🧅 FullNodeManager: Proxy config updated. Daemon restart required to apply.")

        // Try to add some peer connections using onetry (doesn't require restart)
        // This won't change the proxy but may help get some connections going
        let peers = ["162.55.92.62:8033", "157.90.223.151:8033", "37.187.76.79:8033"]
        for peer in peers {
            let process = Process()
            process.executableURL = Self.cliPath
            process.arguments = ["addnode", peer, "onetry"]
            try? process.run()
            process.waitUntilExit()
        }
        print("✅ FullNodeManager: Attempted peer connections via addnode onetry")
    }

    // MARK: - Debug Level Settings

    /// Debug level options for zclassicd daemon
    public enum DaemonDebugLevel: String, CaseIterable {
        case none = "none"           // No debug logging (minimal logs)
        case network = "net"         // Network-related debug only
        case full = "1"              // Full debug (all categories)

        public var displayName: String {
            switch self {
            case .none: return "None"
            case .network: return "Network"
            case .full: return "Full"
            }
        }

        public var description: String {
            switch self {
            case .none:
                return "Minimal logging - only errors and warnings"
            case .network:
                return "Network events - peer connections, traffic"
            case .full:
                return "Full debug - all categories (very verbose)"
            }
        }
    }

    /// Current daemon debug level (persisted in UserDefaults)
    @Published public var daemonDebugLevel: DaemonDebugLevel {
        didSet {
            UserDefaults.standard.set(daemonDebugLevel.rawValue, forKey: "daemonDebugLevel")
            updateDebugLevel(daemonDebugLevel)
        }
    }

    /// Load saved debug level from UserDefaults
    private func loadDebugLevel() -> DaemonDebugLevel {
        if let saved = UserDefaults.standard.string(forKey: "daemonDebugLevel"),
           let level = DaemonDebugLevel(rawValue: saved) {
            return level
        }
        return .none  // Default to no debug
    }

    /// Update zclassic.conf with new debug level
    /// Daemon restart required to apply changes
    public func updateDebugLevel(_ level: DaemonDebugLevel) {
        let configPath = Self.configPath

        guard FileManager.default.fileExists(atPath: configPath.path) else {
            print("⚠️ FullNodeManager: zclassic.conf not found")
            return
        }

        do {
            var config = try String(contentsOf: configPath, encoding: .utf8)
            var lines = config.components(separatedBy: "\n")

            // Remove all existing debug= lines (including commented ones)
            lines.removeAll { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return trimmed.hasPrefix("debug=") || trimmed.hasPrefix("# debug=")
            }

            // Add new debug setting based on level
            switch level {
            case .none:
                // No debug line needed (defaults to minimal logging)
                print("🔧 FullNodeManager: Debug level set to NONE")
            case .network:
                // Insert debug=net before first blank line or at a sensible location
                if let insertIndex = lines.firstIndex(where: { $0.contains("rpcthreads") }) {
                    lines.insert("debug=net", at: insertIndex + 1)
                } else {
                    lines.append("debug=net")
                }
                print("🔧 FullNodeManager: Debug level set to NETWORK")
            case .full:
                // Insert debug=1 for full debug
                if let insertIndex = lines.firstIndex(where: { $0.contains("rpcthreads") }) {
                    lines.insert("debug=1", at: insertIndex + 1)
                } else {
                    lines.append("debug=1")
                }
                print("🔧 FullNodeManager: Debug level set to FULL")
            }

            config = lines.joined(separator: "\n")
            try config.write(to: configPath, atomically: true, encoding: .utf8)

            print("✅ FullNodeManager: zclassic.conf updated with debug level")

            // Note: Daemon needs restart to pick up new debug level
            if daemonStatus.isRunning {
                print("⚠️ FullNodeManager: Daemon restart required to apply debug level")
            }

        } catch {
            print("❌ FullNodeManager: Failed to update debug level: \(error)")
        }
    }

    /// Get current debug level from zclassic.conf
    public func getCurrentDebugLevel() -> DaemonDebugLevel {
        let configPath = Self.configPath

        guard FileManager.default.fileExists(atPath: configPath.path),
              let config = try? String(contentsOf: configPath, encoding: .utf8) else {
            return .none
        }

        let lines = config.components(separatedBy: "\n")
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("debug=") && !trimmed.hasPrefix("# ") {
                let value = trimmed.replacingOccurrences(of: "debug=", with: "")
                if value == "1" {
                    return .full
                } else if value == "net" {
                    return .network
                }
            }
        }
        return .none
    }

    // MARK: - Helpers

    private func getDirectorySize(_ url: URL) -> UInt64? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else {
            return nil
        }

        var total: UInt64 = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += UInt64(size)
            }
        }
        return total
    }

    private func randomString(length: Int) -> String {
        let chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        return String((0..<length).map { _ in chars.randomElement()! })
    }
}

// MARK: - Errors

public enum FullNodeError: Error, LocalizedError {
    case daemonNotInstalled
    case daemonNotRunning
    case daemonNotBundled
    case startupTimeout
    case configError(String)
    case installError(String)

    public var errorDescription: String? {
        switch self {
        case .daemonNotInstalled:
            return "Zclassic daemon is not installed. Please install zclassicd and zclassic-cli to /usr/local/bin from https://github.com/ZclassicCommunity/zclassic"
        case .daemonNotRunning:
            return "Daemon is not running"
        case .daemonNotBundled:
            return "Daemon binaries are not bundled with this version of ZipherX"
        case .startupTimeout:
            return "Daemon failed to start within timeout"
        case .configError(let msg):
            return "Configuration error: \(msg)"
        case .installError(let msg):
            return "Installation error: \(msg)"
        }
    }
}

#endif
