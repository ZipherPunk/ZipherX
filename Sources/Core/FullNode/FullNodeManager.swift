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

    // MARK: - Initialization

    private init() {
        checkNodeStatus()
    }

    // MARK: - Status Checking

    /// Check overall node status
    public func checkNodeStatus() {
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
                daemonStatus = .running
                isNodeInstalled = true  // Daemon is running, so it's "installed" somewhere
                print("✅ Full Node: daemon is RUNNING (detected via RPC)")

                // Check sync status and block height
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
        guard daemonStatus.isRunning else { return }

        do {
            let info = try await RPCClient.shared.getInfoDict()

            // Get block height
            if let blocks = info["blocks"] as? Int {
                daemonBlockHeight = UInt64(blocks)
            }

            // Get sync progress
            if let progress = info["verificationprogress"] as? Double {
                daemonSyncProgress = progress
                if progress < 0.9999 {
                    daemonStatus = .syncing(progress: progress)
                } else {
                    daemonStatus = .running
                }
            } else {
                daemonStatus = .running
            }
        } catch {
            // Keep running status, just couldn't get sync progress
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

            // Wait for daemon to start (up to 30 seconds)
            for i in 1...30 {
                try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second

                if await RPCClient.shared.checkConnection() {
                    await MainActor.run {
                        daemonStatus = .running
                    }
                    print("✅ Daemon started successfully after \(i) seconds")
                    return
                }
            }

            throw FullNodeError.startupTimeout
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
