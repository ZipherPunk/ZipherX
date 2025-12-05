import Foundation
import Combine

#if os(macOS)

/// Manages Full Node mode for ZipherX (macOS only)
/// Handles daemon detection, startup, and wallet.dat management
public class FullNodeManager: ObservableObject {
    public static let shared = FullNodeManager()

    // MARK: - Published State

    @Published public private(set) var daemonStatus: DaemonStatus = .unknown
    @Published public private(set) var isNodeInstalled: Bool = false
    @Published public private(set) var hasBlockchain: Bool = false
    @Published public private(set) var blockchainSize: String = ""
    @Published public private(set) var walletAddresses: [WalletAddress] = []
    @Published public private(set) var totalBalance: Double = 0
    @Published public private(set) var shieldedBalance: Double = 0
    @Published public private(set) var transparentBalance: Double = 0

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

    // MARK: - Wallet Address

    public struct WalletAddress: Identifiable {
        public let id = UUID()
        public let address: String
        public let type: AddressType
        public let balance: Double

        public enum AddressType: String {
            case shielded = "Shielded (z)"
            case transparent = "Transparent (t)"
        }

        public var isShielded: Bool {
            type == .shielded
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
    @MainActor
    private func checkDaemonRunning() async {
        guard isNodeInstalled else {
            print("🔴 Full Node: daemon not installed")
            daemonStatus = .notInstalled
            return
        }

        // Try to connect via RPC
        do {
            try RPCClient.shared.loadConfig()
            print("✅ Full Node: config loaded successfully")
        } catch {
            print("⚠️ Full Node: config load failed - \(error.localizedDescription)")
            daemonStatus = hasBlockchain ? .installed : .notInstalled
            return
        }

        // Now try to connect
        let connected = await RPCClient.shared.checkConnection()
        print("🔄 Full Node: connection check result = \(connected)")

        if connected {
            daemonStatus = .running
            print("✅ Full Node: daemon is RUNNING")

            // Check sync status
            await checkSyncStatus()

            // Load wallet addresses
            await loadWalletAddresses()
        } else {
            print("🔴 Full Node: daemon connection FAILED, marking as \(hasBlockchain ? "installed" : "not installed")")
            daemonStatus = hasBlockchain ? .installed : .notInstalled
        }
    }

    /// Check blockchain sync status
    @MainActor
    private func checkSyncStatus() async {
        guard daemonStatus.isRunning else { return }

        do {
            let info = try await RPCClient.shared.getInfoDict()

            if let progress = info["verificationprogress"] as? Double, progress < 0.9999 {
                daemonStatus = .syncing(progress: progress)
            } else {
                daemonStatus = .running
            }
        } catch {
            // Keep running status, just couldn't get sync progress
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

    // MARK: - Wallet Operations

    /// Load addresses from wallet.dat via RPC
    @MainActor
    private func loadWalletAddresses() async {
        guard daemonStatus.isRunning else { return }

        do {
            // Get z-addresses
            let zAddresses = try await RPCClient.shared.getZAddresses()
            var addresses: [WalletAddress] = []

            for addr in zAddresses {
                let balance = try await RPCClient.shared.getZBalance(address: addr)
                addresses.append(WalletAddress(
                    address: addr,
                    type: .shielded,
                    balance: balance
                ))
            }

            // Get t-addresses
            let tAddresses = try await RPCClient.shared.getTAddresses()
            for addr in tAddresses {
                let balance = try await RPCClient.shared.getTBalance(address: addr)
                addresses.append(WalletAddress(
                    address: addr,
                    type: .transparent,
                    balance: balance
                ))
            }

            walletAddresses = addresses

            // Calculate totals
            shieldedBalance = addresses.filter { $0.isShielded }.reduce(0) { $0 + $1.balance }
            transparentBalance = addresses.filter { !$0.isShielded }.reduce(0) { $0 + $1.balance }
            totalBalance = shieldedBalance + transparentBalance

        } catch {
            print("⚠️ Failed to load wallet addresses: \(error)")
        }
    }

    /// Create a new z-address in wallet.dat
    public func createZAddress() async throws -> String {
        guard daemonStatus.isRunning else {
            throw FullNodeError.daemonNotRunning
        }

        return try await RPCClient.shared.createZAddress()
    }

    /// Create a new t-address in wallet.dat
    public func createTAddress() async throws -> String {
        guard daemonStatus.isRunning else {
            throw FullNodeError.daemonNotRunning
        }

        return try await RPCClient.shared.createTAddress()
    }

    /// Send ZCL using the full node's wallet.dat
    public func sendZCL(from: String, to: String, amount: Double, memo: String? = nil) async throws -> String {
        guard daemonStatus.isRunning else {
            throw FullNodeError.daemonNotRunning
        }

        return try await RPCClient.shared.sendTransaction(from: from, to: to, amount: amount, memo: memo)
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
    case startupTimeout
    case configError(String)
    case walletError(String)

    public var errorDescription: String? {
        switch self {
        case .daemonNotInstalled:
            return "Zclassic daemon is not installed"
        case .daemonNotRunning:
            return "Daemon is not running"
        case .startupTimeout:
            return "Daemon failed to start within timeout"
        case .configError(let msg):
            return "Configuration error: \(msg)"
        case .walletError(let msg):
            return "Wallet error: \(msg)"
        }
    }
}

#endif
