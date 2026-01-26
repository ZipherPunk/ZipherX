import Foundation

#if os(macOS)

/// RPC configuration loaded from zclassic.conf
public struct RPCConfig {
    let host: String
    let port: UInt16
    let username: String
    let password: String

    var url: URL? {
        URL(string: "http://\(host):\(port)")
    }

    var authHeader: String {
        let credentials = "\(username):\(password)"
        let encoded = Data(credentials.utf8).base64EncodedString()
        return "Basic \(encoded)"
    }
}

/// Errors that can occur during RPC operations
public enum RPCError: Error, LocalizedError {
    case configNotFound
    case invalidConfig(String)
    case connectionFailed(String)
    case requestFailed(String)
    case invalidResponse
    case daemonNotRunning
    case walletLocked
    case insufficientFunds
    case invalidAddress
    case operationFailed(String)
    case serverError(Int, String)  // FIX #286 v10: RPC server error with code and message
    case keyAlreadyExists(String)  // FIX #286 v10: Key already in wallet.dat

    public var errorDescription: String? {
        switch self {
        case .configNotFound:
            return "Zclassic configuration file not found"
        case .invalidConfig(let detail):
            return "Invalid configuration: \(detail)"
        case .connectionFailed(let detail):
            return "Connection failed: \(detail)"
        case .requestFailed(let detail):
            return "Request failed: \(detail)"
        case .invalidResponse:
            return "Invalid response from daemon"
        case .daemonNotRunning:
            return "Zclassic daemon is not running"
        case .walletLocked:
            return "Wallet is locked"
        case .insufficientFunds:
            return "Insufficient funds"
        case .invalidAddress:
            return "Invalid address"
        case .operationFailed(let detail):
            return "Operation failed: \(detail)"
        case .serverError(_, let message):
            return "Server error: \(message)"
        case .keyAlreadyExists(let detail):
            return detail
        }
    }
}

/// JSON-RPC client for communicating with zclassicd
public class RPCClient: ObservableObject {
    public static let shared = RPCClient()

    @Published public private(set) var isConnected = false
    @Published public private(set) var blockHeight: UInt64 = 0
    @Published public private(set) var peerCount: Int = 0
    @Published public private(set) var version: String = ""

    private var config: RPCConfig?
    private let session: URLSession
    private var requestId: Int = 0

    private init() {
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = 30
        sessionConfig.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: sessionConfig)
    }

    // MARK: - Configuration

    /// Load RPC configuration from zclassic.conf
    public func loadConfig() throws {
        let configPath = Self.zclassicDataDir.appendingPathComponent("zclassic.conf")

        guard FileManager.default.fileExists(atPath: configPath.path) else {
            throw RPCError.configNotFound
        }

        let content = try String(contentsOf: configPath, encoding: .utf8)
        var host = "127.0.0.1"
        var port: UInt16 = 8023
        var username: String?
        var password: String?

        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#") && !trimmed.isEmpty else { continue }

            let parts = trimmed.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }

            let key = String(parts[0]).trimmingCharacters(in: .whitespaces)
            let value = String(parts[1]).trimmingCharacters(in: .whitespaces)

            switch key {
            case "rpcuser":
                username = value
            case "rpcpassword":
                password = value
            case "rpcport":
                port = UInt16(value) ?? 8023
            case "rpcbind":
                // Only allow localhost for security
                if value == "127.0.0.1" || value == "::1" || value == "localhost" {
                    host = value
                }
            default:
                break
            }
        }

        guard let user = username, let pass = password else {
            throw RPCError.invalidConfig("Missing rpcuser or rpcpassword")
        }

        config = RPCConfig(host: host, port: port, username: user, password: pass)
        print("✅ RPC config loaded: \(host):\(port)")
    }

    /// Zclassic data directory path
    public static var zclassicDataDir: URL {
        #if os(macOS)
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("ZClassic")
        #else
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".zclassic")
        #endif
    }

    // MARK: - Connection

    /// Check if daemon is running and responsive
    public func checkConnection() async -> Bool {
        do {
            print("🔄 RPCClient: checking connection to daemon...")
            let info = try await getInfo()
            print("✅ RPCClient: daemon responded - height=\(info.height), peers=\(info.connections), version=\(info.version)")
            await MainActor.run {
                self.isConnected = true
                self.blockHeight = info.height
                self.peerCount = info.connections
                self.version = info.version
            }
            return true
        } catch {
            print("❌ RPCClient: connection check failed - \(error.localizedDescription)")
            await MainActor.run {
                self.isConnected = false
            }
            return false
        }
    }

    // MARK: - RPC Methods

    /// Get blockchain info
    public func getInfo() async throws -> (height: UInt64, connections: Int, version: String) {
        let result = try await call(method: "getinfo", params: [])

        guard let dict = result as? [String: Any],
              let blocks = dict["blocks"] as? Int,
              let connections = dict["connections"] as? Int,
              let versionNum = dict["version"] as? Int else {
            throw RPCError.invalidResponse
        }

        let version = formatVersion(versionNum)
        return (UInt64(blocks), connections, version)
    }

    /// Get blockchain info as dictionary (for sync progress)
    public func getInfoDict() async throws -> [String: Any] {
        let result = try await call(method: "getinfo", params: [])
        guard let dict = result as? [String: Any] else {
            throw RPCError.invalidResponse
        }
        return dict
    }

    /// Get blockchain info (newer RPC method with more details)
    public func getBlockchainInfo() async throws -> [String: Any] {
        let result = try await call(method: "getblockchaininfo", params: [])
        guard let dict = result as? [String: Any] else {
            throw RPCError.invalidResponse
        }
        return dict
    }

    /// Get network info (connections, version, etc.)
    public func getNetworkInfo() async throws -> [String: Any] {
        let result = try await call(method: "getnetworkinfo", params: [])
        guard let dict = result as? [String: Any] else {
            throw RPCError.invalidResponse
        }
        return dict
    }

    /// Get balance for a specific z-address
    public func getZBalance(address: String) async throws -> Double {
        let result = try await call(method: "z_getbalance", params: [address])
        if let balance = result as? Double {
            return balance
        }
        if let balanceStr = result as? String, let balance = Double(balanceStr) {
            return balance
        }
        throw RPCError.invalidResponse
    }

    /// Get balance for a specific t-address
    public func getTBalance(address: String) async throws -> Double {
        // Use getreceivedbyaddress for t-addresses
        let result = try await call(method: "getreceivedbyaddress", params: [address, 1])
        if let balance = result as? Double {
            return balance
        }
        if let balanceInt = result as? Int {
            return Double(balanceInt)
        }
        throw RPCError.invalidResponse
    }

    /// Get total balance (confirmed, unconfirmed, transparent, private)
    public func getDetailedBalance() async throws -> (total: Double, transparent: Double, private_: Double, unconfirmed: Double) {
        // Get confirmed balance (minconf=1)
        let confirmedResult = try await call(method: "z_gettotalbalance", params: [1])
        guard let confirmed = confirmedResult as? [String: Any],
              let totalStr = confirmed["total"] as? String,
              let transparentStr = confirmed["transparent"] as? String,
              let privateStr = confirmed["private"] as? String,
              let total = Double(totalStr),
              let transparent = Double(transparentStr),
              let privateBalance = Double(privateStr) else {
            throw RPCError.invalidResponse
        }

        // Get unconfirmed (minconf=0)
        let unconfirmedResult = try await call(method: "z_gettotalbalance", params: [0])
        guard let unconfirmedDict = unconfirmedResult as? [String: Any],
              let unconfTotalStr = unconfirmedDict["total"] as? String,
              let unconfTotal = Double(unconfTotalStr) else {
            throw RPCError.invalidResponse
        }

        let unconfirmed = unconfTotal - total
        return (total, transparent, privateBalance, unconfirmed)
    }

    /// Get all z-addresses
    public func getZAddresses() async throws -> [String] {
        let result = try await call(method: "z_listaddresses", params: [])
        guard let addresses = result as? [String] else {
            throw RPCError.invalidResponse
        }
        return addresses
    }

    /// Get all t-addresses
    public func getTAddresses() async throws -> [String] {
        // Try listaddressgroupings first
        do {
            let result = try await call(method: "listaddressgroupings", params: [])
            if let groupings = result as? [[[Any]]] {
                var addresses: [String] = []
                for group in groupings {
                    for entry in group {
                        if let address = entry.first as? String {
                            addresses.append(address)
                        }
                    }
                }
                return addresses
            }
        } catch {
            // Fallback to getaddressesbyaccount
        }

        let result = try await call(method: "getaddressesbyaccount", params: [""])
        guard let addresses = result as? [String] else {
            return []
        }
        return addresses
    }

    /// Get balance for specific address
    public func getAddressBalance(_ address: String) async throws -> Double {
        if address.hasPrefix("zs") || address.hasPrefix("zc") {
            // Z-address
            let result = try await call(method: "z_getbalance", params: [address])
            guard let balance = result as? Double else {
                if let balanceStr = result as? String, let balance = Double(balanceStr) {
                    return balance
                }
                throw RPCError.invalidResponse
            }
            return balance
        } else {
            // T-address - use getreceivedbyaddress
            let result = try await call(method: "getreceivedbyaddress", params: [address, 1])
            guard let balance = result as? Double else {
                if let balanceInt = result as? Int {
                    return Double(balanceInt)
                }
                throw RPCError.invalidResponse
            }
            return balance
        }
    }

    /// Create new z-address
    public func createZAddress() async throws -> String {
        let result = try await call(method: "z_getnewaddress", params: ["sapling"])
        guard let address = result as? String else {
            throw RPCError.invalidResponse
        }
        return address
    }

    /// Create new t-address
    public func createTAddress() async throws -> String {
        let result = try await call(method: "getnewaddress", params: [])
        guard let address = result as? String else {
            throw RPCError.invalidResponse
        }
        return address
    }

    /// Send transaction
    public func sendTransaction(from: String, to: String, amount: Double, memo: String? = nil) async throws -> String {
        var recipient: [String: Any] = [
            "address": to,
            "amount": amount
        ]

        if let memo = memo, to.hasPrefix("zs") || to.hasPrefix("zc") {
            recipient["memo"] = memo.data(using: .utf8)?.hexEncodedString() ?? ""
        }

        let params: [Any] = [from, [recipient], 1, 0.0001]
        let result = try await call(method: "z_sendmany", params: params)

        guard let opid = result as? String else {
            throw RPCError.invalidResponse
        }

        // Poll for operation result
        return try await waitForOperation(opid)
    }

    /// FIX #717: Send raw transaction via RPC
    /// This broadcasts through the local zclassicd node and returns clear error if TX is invalid
    /// Useful as fallback when P2P broadcast fails with unclear DUPLICATE/timeout errors
    public func sendRawTransaction(_ rawTxHex: String) async throws -> String {
        let result = try await call(method: "sendrawtransaction", params: [rawTxHex])

        guard let txid = result as? String else {
            throw RPCError.invalidResponse
        }

        print("✅ FIX #717: RPC sendrawtransaction success: \(txid)")
        return txid
    }

    /// FIX #717: Verify if a transaction exists in mempool via RPC
    /// Returns true if TX is in mempool, false otherwise
    public func checkMempoolForTx(_ txid: String) async throws -> Bool {
        do {
            let result = try await call(method: "getrawtransaction", params: [txid, false])
            return result as? String != nil
        } catch {
            // TX not found in mempool
            return false
        }
    }

    /// Shield transparent funds to z-address
    public func shieldFunds(toZAddress: String) async throws -> String {
        let params: [Any] = ["*", toZAddress, 0.0001]
        let result = try await call(method: "z_shieldcoinbase", params: params)

        guard let dict = result as? [String: Any],
              let opid = dict["opid"] as? String else {
            throw RPCError.invalidResponse
        }

        return try await waitForOperation(opid)
    }

    /// Export private key for address
    public func exportPrivateKey(_ address: String) async throws -> String {
        let method = (address.hasPrefix("zs") || address.hasPrefix("zc")) ? "z_exportkey" : "dumpprivkey"
        let result = try await call(method: method, params: [address])

        guard let key = result as? String else {
            throw RPCError.invalidResponse
        }
        return key
    }

    /// Import private key
    /// FIX #286 v9: Use async operation for rescan with progress callback
    /// FIX #286 v10: Check for duplicate keys before importing
    public func importPrivateKey(_ key: String, rescan: Bool = false, progressCallback: ((Double, String) -> Void)? = nil) async throws -> String {
        let isZKey = key.hasPrefix("secret-extended-key")

        // FIX #286 v10: Check if key already exists BEFORE importing
        progressCallback?(0.05, "Checking for duplicate key...")

        if isZKey {
            // Get existing z-addresses before attempting import
            let existingAddresses = try await getZAddresses()

            // Try a quick import with no rescan to check if key exists
            do {
                let checkResult = try await call(method: "z_importkey", params: [key, "no"])

                // If we get here without error, key was imported (new key)
                // Now check if address count changed
                let newAddresses = try await getZAddresses()
                let newAddress = newAddresses.first { !existingAddresses.contains($0) }

                if newAddress == nil && newAddresses.count == existingAddresses.count {
                    // Key already existed - daemon accepted but no new address
                    throw RPCError.keyAlreadyExists("This z-address private key is already in your wallet.dat")
                }

                // New key was added successfully
                if !rescan {
                    progressCallback?(1.0, "Import complete")
                    return newAddress ?? newAddresses.last ?? "Import successful"
                }

                // User wants rescan - need to trigger it
                progressCallback?(0.1, "Key imported, starting rescan...")
                let rescanResult = try await call(method: "z_importkey", params: [key, "yes"])

                if let opid = rescanResult as? String, opid.hasPrefix("opid-") {
                    print("📥 FIX #286 v9: z_importkey rescan started: \(opid)")
                    let address = try await waitForImportOperation(opid, progressCallback: progressCallback)
                    return address
                }

                progressCallback?(1.0, "Import complete")
                return newAddress ?? newAddresses.last ?? "Import successful"

            } catch let error as RPCError {
                // Check if error indicates key already exists
                if case .requestFailed(let message) = error {
                    let lowerMessage = message.lowercased()
                    if lowerMessage.contains("already") || lowerMessage.contains("exists") || lowerMessage.contains("duplicate") {
                        throw RPCError.keyAlreadyExists("This z-address private key is already in your wallet.dat")
                    }
                }
                // Re-throw keyAlreadyExists as-is
                if case .keyAlreadyExists = error {
                    throw error
                }
                throw error
            }

        } else {
            // T-address import
            // Get existing t-addresses before attempting import
            let existingAddresses = try await getTAddresses()

            // Try a quick import with no rescan first
            do {
                progressCallback?(0.1, "Verifying key...")
                let _ = try await call(method: "importprivkey", params: [key, "", false])

                // Check if a new address was added
                let newAddresses = try await getTAddresses()
                let newAddress = newAddresses.first { !existingAddresses.contains($0) }

                if newAddress == nil && newAddresses.count == existingAddresses.count {
                    // Key already existed
                    throw RPCError.keyAlreadyExists("This t-address private key is already in your wallet.dat")
                }

                // New key was added
                if !rescan {
                    progressCallback?(1.0, "Import complete")
                    return newAddress ?? newAddresses.last ?? "Import successful"
                }

                // User wants rescan - need to trigger it
                progressCallback?(0.2, "Key imported, starting rescan (this may take hours)...")

                // Note: importprivkey rescan is synchronous and blocking
                // We re-import with rescan=true (key exists, so just triggers rescan)
                let _ = try await call(method: "importprivkey", params: [key, "", true])

                progressCallback?(1.0, "Import and rescan complete")
                return newAddress ?? newAddresses.last ?? "Import successful"

            } catch let error as RPCError {
                // Check if error indicates key already exists
                if case .requestFailed(let message) = error {
                    let lowerMessage = message.lowercased()
                    if lowerMessage.contains("already") || lowerMessage.contains("exists") || lowerMessage.contains("duplicate") {
                        throw RPCError.keyAlreadyExists("This t-address private key is already in your wallet.dat")
                    }
                }
                // Re-throw keyAlreadyExists as-is
                if case .keyAlreadyExists = error {
                    throw error
                }
                throw error
            }
        }
    }

    /// FIX #286 v9: Wait for z_importkey operation with progress
    private func waitForImportOperation(_ opid: String, progressCallback: ((Double, String) -> Void)?) async throws -> String {
        let startTime = Date()
        let maxWait: TimeInterval = 86400  // 24 hours max for rescan

        var lastProgress: Double = 0.1

        while Date().timeIntervalSince(startTime) < maxWait {
            let statusResult = try await call(method: "z_getoperationstatus", params: [[opid]])

            guard let statusArray = statusResult as? [[String: Any]],
                  let status = statusArray.first else {
                try await Task.sleep(nanoseconds: 2_000_000_000)  // 2 seconds
                continue
            }

            let state = status["status"] as? String ?? ""
            let method = status["method"] as? String ?? ""

            // Check for progress info
            if let executionSecs = status["execution_secs"] as? Double {
                // Estimate progress based on typical rescan time (rough estimate)
                let estimatedTotal: Double = 7200  // 2 hours typical
                let progress = min(0.95, 0.1 + (executionSecs / estimatedTotal) * 0.85)
                if progress > lastProgress {
                    lastProgress = progress
                    let elapsed = Int(executionSecs)
                    let mins = elapsed / 60
                    let secs = elapsed % 60
                    progressCallback?(progress, "Rescanning... (\(mins)m \(secs)s elapsed)")
                }
            }

            switch state {
            case "success":
                progressCallback?(1.0, "Import complete!")
                // Get the result and clean up
                _ = try? await call(method: "z_getoperationresult", params: [[opid]])

                // Return the imported address
                let addresses = try await getZAddresses()
                return addresses.last ?? "Import successful"

            case "failed":
                let error = status["error"] as? [String: Any]
                let message = error?["message"] as? String ?? "Import failed"
                throw RPCError.operationFailed(message)

            case "executing":
                progressCallback?(lastProgress, "Rescan in progress...")

            default:
                break
            }

            try await Task.sleep(nanoseconds: 3_000_000_000)  // 3 seconds between polls
        }

        throw RPCError.operationFailed("Import operation timed out after 24 hours")
    }

    // MARK: - Explorer Methods

    /// Get block by height
    public func getBlock(height: UInt64) async throws -> [String: Any] {
        let hashResult = try await call(method: "getblockhash", params: [Int(height)])
        guard let hash = hashResult as? String else {
            throw RPCError.invalidResponse
        }

        let blockResult = try await call(method: "getblock", params: [hash, 2])
        guard let block = blockResult as? [String: Any] else {
            throw RPCError.invalidResponse
        }

        return block
    }

    /// Get block by hash
    public func getBlock(hash: String) async throws -> [String: Any] {
        let result = try await call(method: "getblock", params: [hash, 2])
        guard let block = result as? [String: Any] else {
            throw RPCError.invalidResponse
        }
        return block
    }

    /// Get transaction by txid
    public func getTransaction(txid: String) async throws -> [String: Any] {
        // Try getrawtransaction first (works for all transactions)
        do {
            let result = try await call(method: "getrawtransaction", params: [txid, 1])
            if let tx = result as? [String: Any] {
                return tx
            }
        } catch {
            // Fallback to gettransaction (wallet transactions only)
        }

        let result = try await call(method: "gettransaction", params: [txid])
        guard let tx = result as? [String: Any] else {
            throw RPCError.invalidResponse
        }
        return tx
    }

    /// Get network hashrate
    public func getNetworkHashrate() async throws -> Double {
        let result = try await call(method: "getnetworkhashps", params: [])
        if let hashrate = result as? Double {
            return hashrate
        }
        if let hashrate = result as? Int {
            return Double(hashrate)
        }
        throw RPCError.invalidResponse
    }

    /// Rescan blockchain from height
    public func rescan(fromHeight: UInt64? = nil) async throws {
        if let height = fromHeight {
            _ = try await call(method: "rescan", params: [Int(height)])
        } else {
            _ = try await call(method: "rescan", params: [])
        }
    }

    // MARK: - Wallet Encryption

    /// Check if wallet is encrypted
    public func isWalletEncrypted() async throws -> Bool {
        let result = try await call(method: "getwalletinfo", params: [])
        guard let info = result as? [String: Any] else {
            throw RPCError.invalidResponse
        }

        // If unlocked_until key exists, wallet is encrypted
        return info["unlocked_until"] != nil
    }

    // MARK: - FIX #286 v12: Rescan Detection

    /// Rescan status information
    public struct RescanStatus {
        public let isScanning: Bool
        public let progress: Double  // 0.0 to 1.0
        public let duration: Int     // seconds elapsed
        public let source: String    // "wallet" or "z_importkey" or "none"
    }

    // MARK: - FIX #286 v13: Detailed Sync Status

    /// Detailed sync status for UI display
    public struct DetailedSyncStatus {
        public let blocks: Int           // Current block height
        public let headers: Int          // Known header height
        public let progress: Double      // 0.0 to 1.0 verification progress
        public let isSyncing: Bool       // Is blockchain syncing
        public let isRescanning: Bool    // Is wallet rescanning
        public let rescanProgress: Double // Rescan progress if rescanning
        public let rescanBlock: Int      // Current rescan block
        public let connections: Int      // Number of peer connections
        public let statusMessage: String // Human-readable status
    }

    /// Get detailed sync status including blockchain and wallet scan
    public func getDetailedSyncStatus() async throws -> DetailedSyncStatus {
        // Get blockchain info
        let blockchainInfo = try await getBlockchainInfo()
        let blocks = blockchainInfo["blocks"] as? Int ?? 0
        let headers = blockchainInfo["headers"] as? Int ?? 0
        let verificationProgress = blockchainInfo["verificationprogress"] as? Double ?? 0
        let initialBlockDownload = blockchainInfo["initialblockdownload"] as? Bool ?? false

        // Get network info for connections
        var connections = 0
        if let networkInfo = try? await getNetworkInfo() {
            connections = networkInfo["connections"] as? Int ?? 0
        }

        // Check for wallet rescan status
        var isRescanning = false
        var rescanProgress: Double = 0
        var rescanBlock = 0

        if let walletInfo = try? await call(method: "getwalletinfo", params: []) as? [String: Any] {
            // Check for scanning field (format: { "scanning": { "duration": N, "progress": P } })
            if let scanning = walletInfo["scanning"] as? [String: Any] {
                isRescanning = true
                rescanProgress = scanning["progress"] as? Double ?? 0
                // Estimate block from progress
                rescanBlock = Int(Double(headers) * rescanProgress)
                print("📊 FIX #286 v13: Wallet rescanning - progress: \(Int(rescanProgress * 100))%, block ~\(rescanBlock)")
            }
        }

        // Determine if blockchain is syncing
        let isSyncing = initialBlockDownload || blocks < headers - 2

        // Generate human-readable status message
        let statusMessage: String
        if isRescanning {
            statusMessage = "Rescanning wallet at block \(rescanBlock) (\(Int(rescanProgress * 100))%)"
        } else if initialBlockDownload {
            statusMessage = "Downloading blockchain: \(blocks)/\(headers) blocks (\(Int(verificationProgress * 100))%)"
        } else if blocks < headers - 2 {
            let blocksRemaining = headers - blocks
            statusMessage = "Syncing: \(blocksRemaining) blocks behind"
        } else {
            statusMessage = "Synchronized at block \(blocks)"
        }

        return DetailedSyncStatus(
            blocks: blocks,
            headers: headers,
            progress: isRescanning ? rescanProgress : verificationProgress,
            isSyncing: isSyncing,
            isRescanning: isRescanning,
            rescanProgress: rescanProgress,
            rescanBlock: rescanBlock,
            connections: connections,
            statusMessage: statusMessage
        )
    }

    /// Detect if a rescan is currently in progress
    /// Checks both wallet scanning status and z_importkey operations
    public func getRescanStatus() async throws -> RescanStatus {
        // Method 1: Check getwalletinfo for scanning field (Bitcoin Core style)
        if let walletScan = try? await getWalletScanningStatus() {
            if walletScan.isScanning {
                return walletScan
            }
        }

        // Method 2: Check for ongoing z_importkey operations
        if let zOpScan = try? await getZOperationScanningStatus() {
            if zOpScan.isScanning {
                return zOpScan
            }
        }

        return RescanStatus(isScanning: false, progress: 0, duration: 0, source: "none")
    }

    /// Check wallet scanning status via getwalletinfo
    private func getWalletScanningStatus() async throws -> RescanStatus {
        let result = try await call(method: "getwalletinfo", params: [])
        guard let info = result as? [String: Any] else {
            throw RPCError.invalidResponse
        }

        // Check for "scanning" field (available in some Bitcoin-derived clients)
        // Format: { "scanning": { "duration": 1234, "progress": 0.5 } } or { "scanning": false }
        if let scanning = info["scanning"] {
            if let scanInfo = scanning as? [String: Any] {
                let duration = scanInfo["duration"] as? Int ?? 0
                let progress = scanInfo["progress"] as? Double ?? 0.0
                print("📊 FIX #286 v12: Wallet rescan detected - progress: \(Int(progress * 100))%, duration: \(duration)s")
                return RescanStatus(isScanning: true, progress: progress, duration: duration, source: "wallet")
            } else if let scanBool = scanning as? Bool, scanBool == false {
                return RescanStatus(isScanning: false, progress: 0, duration: 0, source: "none")
            }
        }

        return RescanStatus(isScanning: false, progress: 0, duration: 0, source: "none")
    }

    /// Check for ongoing z_importkey operations via z_getoperationstatus
    private func getZOperationScanningStatus() async throws -> RescanStatus {
        let result = try await call(method: "z_getoperationstatus", params: [] as [Any])

        guard let operations = result as? [[String: Any]] else {
            return RescanStatus(isScanning: false, progress: 0, duration: 0, source: "none")
        }

        // Look for executing z_importkey operations
        for op in operations {
            let method = op["method"] as? String ?? ""
            let status = op["status"] as? String ?? ""

            if method == "z_importkey" && status == "executing" {
                let executionSecs = op["execution_secs"] as? Double ?? 0
                // Estimate progress based on typical rescan time (2 hours)
                let estimatedTotal: Double = 7200
                let progress = min(0.95, executionSecs / estimatedTotal)

                print("📊 FIX #286 v12: z_importkey rescan detected - elapsed: \(Int(executionSecs))s, progress: \(Int(progress * 100))%")
                return RescanStatus(isScanning: true, progress: progress, duration: Int(executionSecs), source: "z_importkey")
            }
        }

        return RescanStatus(isScanning: false, progress: 0, duration: 0, source: "none")
    }

    /// Unlock wallet temporarily
    public func unlockWallet(passphrase: String, timeout: Int = 60) async throws {
        _ = try await call(method: "walletpassphrase", params: [passphrase, timeout])
    }

    /// Lock wallet
    public func lockWallet() async throws {
        _ = try await call(method: "walletlock", params: [])
    }

    // MARK: - Transaction History Methods

    /// Send to a t-address (transparent transaction)
    /// - Parameters:
    ///   - from: Source t-address (used for coin selection, can be "*" for any)
    ///   - to: Destination address
    ///   - amount: Amount in ZCL
    /// - Returns: Transaction ID
    public func sendToAddress(from: String, to: String, amount: Double) async throws -> String {
        // For t-to-t, use sendtoaddress or z_sendmany
        // z_sendmany works for both z and t source addresses
        var recipient: [String: Any] = [
            "address": to,
            "amount": amount
        ]

        let params: [Any] = [from, [recipient], 1, 0.0001]
        let result = try await call(method: "z_sendmany", params: params)

        guard let opid = result as? String else {
            throw RPCError.invalidResponse
        }

        return try await waitForOperation(opid)
    }

    /// List recent transactions from wallet
    /// - Parameters:
    ///   - count: Number of transactions to return
    ///   - from: Skip this many transactions
    /// - Returns: Array of transactions
    public func listTransactions(count: Int, from: Int) async throws -> [WalletTransaction] {
        // FIX #286 v7: Fetch ALL wallet transactions (both t and z address)
        let result = try await call(method: "listtransactions", params: ["*", count, from])

        guard let txList = result as? [[String: Any]] else {
            print("⚠️ FIX #286 v7: listtransactions returned invalid format")
            return []
        }

        // FIX #286 v7 debug logs removed for cleaner output

        var transactions: [WalletTransaction] = []

        for tx in txList {
            guard let txid = tx["txid"] as? String,
                  let category = tx["category"] as? String else {
                continue
            }

            let address = tx["address"] as? String ?? ""
            let amountDouble = tx["amount"] as? Double ?? 0
            let amount = UInt64(abs(amountDouble) * 100_000_000)
            let feeDouble = tx["fee"] as? Double ?? 0
            let fee = UInt64(abs(feeDouble) * 100_000_000)

            // FIX #286 v7: Parse confirmations with multiple type attempts
            let confirmations: Int
            if let conf = tx["confirmations"] as? Int {
                confirmations = conf
            } else if let conf = tx["confirmations"] as? Int64 {
                confirmations = Int(conf)
            } else if let conf = tx["confirmations"] as? Double {
                confirmations = Int(conf)
            } else {
                confirmations = 0
            }

            // FIX #286 v7: Parse time with multiple type attempts
            let time: Int
            if let t = tx["time"] as? Int {
                time = t
            } else if let t = tx["time"] as? Int64 {
                time = Int(t)
            } else if let t = tx["timereceived"] as? Int {
                time = t
            } else if let t = tx["timereceived"] as? Int64 {
                time = Int(t)
            } else {
                time = Int(Date().timeIntervalSince1970)
            }

            // FIX #286 v7: Parse blockheight with multiple type attempts
            let blockheight: Int?
            if let h = tx["blockheight"] as? Int {
                blockheight = h
            } else if let h = tx["blockheight"] as? Int64 {
                blockheight = Int(h)
            } else if let h = tx["blockheight"] as? Double {
                blockheight = Int(h)
            } else {
                blockheight = nil
            }

            // FIX #286 v7: Handle all transaction categories
            // Categories: "send", "receive", "generate", "immature", "orphan"
            let type: WalletTransactionType
            switch category {
            case "send":
                type = .sent
            case "receive", "generate":
                type = .received
            default:
                // Skip orphan/immature transactions
                continue
            }

            transactions.append(WalletTransaction(
                txid: txid,
                address: address,
                amount: amount,
                fee: fee,
                type: type,
                timestamp: Date(timeIntervalSince1970: TimeInterval(time)),
                confirmations: confirmations,
                height: blockheight != nil ? UInt64(blockheight!) : nil
            ))
        }

        // FIX #286 v7: Log summary
        let sentCount = transactions.filter { $0.type == .sent }.count
        let recvCount = transactions.filter { $0.type == .received }.count
        _ = (sentCount, recvCount)  // Used for debugging if needed

        return transactions
    }

    /// FIX #286: Get all wallet transactions including z-address sends
    /// Uses both listtransactions and z_listunspent to build complete history
    /// FIX #685: Now fetches ALL transactions using pagination (no limit)
    public func getAllWalletTransactions(limit: Int) async throws -> [WalletTransaction] {
        var allTransactions: [WalletTransaction] = []
        var seenTxids = Set<String>()

        // FIX #725: Use listsinceblock for complete t-address history (more reliable than pagination)
        // This gets ALL transactions since genesis block
        print("📜 FIX #725: Fetching all transactions via listsinceblock...")
        do {
            let sinceTxs = try await listSinceBlock()
            for tx in sinceTxs {
                if !seenTxids.contains(tx.txid) {
                    allTransactions.append(tx)
                    seenTxids.insert(tx.txid)
                }
            }
            print("📜 FIX #725: listsinceblock returned \(sinceTxs.count) transactions (\(allTransactions.count) unique)")
        } catch {
            // Fallback to pagination if listsinceblock fails
            print("⚠️ FIX #725: listsinceblock failed, falling back to pagination: \(error)")
            var fetchMoreTxs = true
            var fromOffset = 0
            let batchSize = 1000

            while fetchMoreTxs {
                let tTxs = try await listTransactions(count: batchSize, from: fromOffset)
                if tTxs.isEmpty {
                    fetchMoreTxs = false
                } else {
                    for tx in tTxs {
                        if !seenTxids.contains(tx.txid) {
                            allTransactions.append(tx)
                            seenTxids.insert(tx.txid)
                        }
                    }
                    fromOffset += tTxs.count
                    if tTxs.count < batchSize {
                        fetchMoreTxs = false
                    }
                }
            }
        }
        print("📜 FIX #725: After t-address fetch: \(allTransactions.count) transactions")

        // 2. Get z-address received transactions for all z-addresses
        // z_listreceivedbyaddress returns RECEIVED z-transactions with full details
        let zAddresses = try await getZAddresses()
        print("📜 FIX #725: Found \(zAddresses.count) z-addresses in wallet")
        var zReceivedCount = 0
        for zAddr in zAddresses {
            let zReceived = try await zListReceivedByAddress(zAddr, minconf: 0)
            for tx in zReceived {
                if !seenTxids.contains(tx.txid) {
                    allTransactions.append(tx)
                    seenTxids.insert(tx.txid)
                    zReceivedCount += 1
                }
            }
        }
        print("📜 FIX #725: Added \(zReceivedCount) z-address RECEIVED transactions")

        // 3. Get z-address SENT transactions from operation status
        // FIX #725: Use z_getoperationstatus (non-destructive) to get recent sends
        // Note: This only captures operations from current daemon session
        let opResults = try await getZOperationResults()
        var zSentCount = 0
        for opResult in opResults {
            // Check if operation is complete and has a txid
            guard let status = opResult["status"] as? String, status == "success",
                  let result = opResult["result"] as? [String: Any],
                  let txidStr = result["txid"] as? String,
                  !seenTxids.contains(txidStr) else {
                continue
            }

            // Get creation time if available
            let creationTime = opResult["creation_time"] as? Double ?? Date().timeIntervalSince1970

            // Try to get amount from params
            var totalAmount: UInt64 = 0
            var toAddress = ""
            if let params = opResult["params"] as? [String: Any],
               let amounts = params["amounts"] as? [[String: Any]] {
                for amt in amounts {
                    if let amtDouble = amt["amount"] as? Double {
                        totalAmount += UInt64(amtDouble * 100_000_000)
                    }
                    if let addr = amt["address"] as? String, toAddress.isEmpty {
                        toAddress = addr
                    }
                }
            }

            allTransactions.append(WalletTransaction(
                txid: txidStr,
                address: toAddress,
                amount: totalAmount,
                fee: 0,
                type: .sent,
                timestamp: Date(timeIntervalSince1970: creationTime),
                confirmations: 0,
                height: nil
            ))
            seenTxids.insert(txidStr)
            zSentCount += 1
        }
        print("📜 FIX #725: Added \(zSentCount) z-address SENT transactions from operations")

        // 4. For any transaction we found, try to enrich with full details
        // This helps get accurate timestamps and heights for z-transactions
        print("📜 FIX #725: Enriching \(allTransactions.count) transactions with full details...")
        var enrichedTransactions: [WalletTransaction] = []
        for tx in allTransactions {
            // If transaction is missing height or has zero timestamp, try to get details
            if tx.height == nil || tx.timestamp.timeIntervalSince1970 < 1000000 {
                do {
                    let details = try await getTransaction(txid: tx.txid)
                    var enrichedTx = tx

                    if let height = details["height"] as? Int, tx.height == nil {
                        enrichedTx = WalletTransaction(
                            txid: tx.txid,
                            address: tx.address,
                            amount: tx.amount,
                            fee: tx.fee,
                            type: tx.type,
                            timestamp: tx.timestamp,
                            confirmations: tx.confirmations,
                            memo: tx.memo,
                            height: UInt64(height)
                        )
                    }

                    if let blocktime = details["blocktime"] as? Int {
                        enrichedTx = WalletTransaction(
                            txid: enrichedTx.txid,
                            address: enrichedTx.address,
                            amount: enrichedTx.amount,
                            fee: enrichedTx.fee,
                            type: enrichedTx.type,
                            timestamp: Date(timeIntervalSince1970: TimeInterval(blocktime)),
                            confirmations: enrichedTx.confirmations,
                            memo: enrichedTx.memo,
                            height: enrichedTx.height
                        )
                    }

                    enrichedTransactions.append(enrichedTx)
                } catch {
                    // Keep original if enrichment fails
                    enrichedTransactions.append(tx)
                }
            } else {
                enrichedTransactions.append(tx)
            }
        }

        // FIX #725: Sort by block height DESC (most recent first), then by timestamp for unconfirmed
        // This gives proper chronological order
        print("📜 FIX #725: Returning \(enrichedTransactions.count) total transactions from Full Node RPC")
        return enrichedTransactions.sorted { tx1, tx2 in
            // First sort by height (higher = more recent)
            if let h1 = tx1.height, let h2 = tx2.height {
                if h1 != h2 { return h1 > h2 }
            } else if tx1.height != nil {
                return true  // tx1 has height, tx2 doesn't - tx1 is confirmed, comes first
            } else if tx2.height != nil {
                return false  // tx2 has height, tx1 doesn't
            }
            // If same height or both unconfirmed, sort by timestamp
            return tx1.timestamp > tx2.timestamp
        }
    }

    /// FIX #286: Get z-address operation results (completed send operations)
    /// FIX #725: Use z_getoperationstatus instead of z_getoperationresult
    /// z_getoperationresult is DESTRUCTIVE - it clears the operation list after returning!
    /// z_getoperationstatus returns the same data but keeps it for future queries
    public func getZOperationResults() async throws -> [[String: Any]] {
        do {
            // FIX #725: Use z_getoperationstatus (non-destructive) instead of z_getoperationresult
            let result = try await call(method: "z_getoperationstatus", params: [] as [Any])
            if let results = result as? [[String: Any]] {
                return results
            }
            return []
        } catch {
            // z_getoperationstatus may fail if no operations exist
            return []
        }
    }

    /// FIX #725: Get ALL wallet transactions using listsinceblock
    /// This is more reliable than listtransactions pagination for getting complete history
    /// Returns transactions since genesis block (all history)
    public func listSinceBlock() async throws -> [WalletTransaction] {
        // Use empty string for blockhash to get all transactions since genesis
        // Parameters: blockhash, target_confirmations, include_watchonly
        let result = try await call(method: "listsinceblock", params: ["", 1, true])

        guard let response = result as? [String: Any],
              let txList = response["transactions"] as? [[String: Any]] else {
            print("⚠️ FIX #725: listsinceblock returned invalid format")
            return []
        }

        print("📜 FIX #725: listsinceblock returned \(txList.count) transactions")

        var transactions: [WalletTransaction] = []

        for tx in txList {
            guard let txid = tx["txid"] as? String,
                  let category = tx["category"] as? String else {
                continue
            }

            let address = tx["address"] as? String ?? ""
            let amountDouble = tx["amount"] as? Double ?? 0
            let amount = UInt64(abs(amountDouble) * 100_000_000)
            let feeDouble = tx["fee"] as? Double ?? 0
            let fee = UInt64(abs(feeDouble) * 100_000_000)

            // Parse confirmations
            let confirmations: Int
            if let conf = tx["confirmations"] as? Int {
                confirmations = conf
            } else if let conf = tx["confirmations"] as? Int64 {
                confirmations = Int(conf)
            } else {
                confirmations = 0
            }

            // Parse time
            let time: Int
            if let t = tx["time"] as? Int {
                time = t
            } else if let t = tx["blocktime"] as? Int {
                time = t
            } else if let t = tx["timereceived"] as? Int {
                time = t
            } else {
                time = Int(Date().timeIntervalSince1970)
            }

            // Parse blockheight
            let blockheight: Int?
            if let h = tx["blockheight"] as? Int {
                blockheight = h
            } else if let h = tx["blockindex"] as? Int {
                // Some versions use blockindex
                blockheight = nil  // blockindex is position in block, not height
            } else {
                blockheight = nil
            }

            // Handle transaction categories
            let type: WalletTransactionType
            switch category {
            case "send":
                type = .sent
            case "receive", "generate":
                type = .received
            default:
                // Skip orphan/immature transactions
                continue
            }

            transactions.append(WalletTransaction(
                txid: txid,
                address: address,
                amount: amount,
                fee: fee,
                type: type,
                timestamp: Date(timeIntervalSince1970: TimeInterval(time)),
                confirmations: confirmations,
                height: blockheight != nil ? UInt64(blockheight!) : nil
            ))
        }

        print("📜 FIX #725: Parsed \(transactions.count) valid transactions from listsinceblock")
        return transactions
    }

    // MARK: - FIX #286 v17: Mempool and Pending Transaction Monitoring

    /// Pending transaction info from z_sendmany operations
    public struct PendingOperation {
        public let opid: String
        public let method: String
        public let status: String   // "queued", "executing", "success", "failed"
        public let txid: String?    // Only available after success
        public let creationTime: Date?
        public let executionSecs: Double
    }

    /// Get all pending z_sendmany operations (not yet confirmed)
    public func getPendingOperations() async throws -> [PendingOperation] {
        let result = try await call(method: "z_getoperationstatus", params: [] as [Any])

        guard let operations = result as? [[String: Any]] else {
            return []
        }

        var pending: [PendingOperation] = []

        for op in operations {
            let opid = op["id"] as? String ?? ""
            let method = op["method"] as? String ?? ""
            let status = op["status"] as? String ?? ""
            let execSecs = op["execution_secs"] as? Double ?? 0

            // Get txid from result if available
            var txid: String? = nil
            if let resultDict = op["result"] as? [String: Any] {
                txid = resultDict["txid"] as? String
            }

            // Get creation time
            var creationTime: Date? = nil
            if let timeInt = op["creation_time"] as? Int {
                creationTime = Date(timeIntervalSince1970: TimeInterval(timeInt))
            }

            pending.append(PendingOperation(
                opid: opid,
                method: method,
                status: status,
                txid: txid,
                creationTime: creationTime,
                executionSecs: execSecs
            ))
        }

        return pending
    }

    /// Get unconfirmed balance (transactions in mempool)
    public func getUnconfirmedBalance() async throws -> (transparent: Double, private_: Double) {
        // Get balance with minconf=0 (includes unconfirmed)
        let unconfResult = try await call(method: "z_gettotalbalance", params: [0])

        // Get balance with minconf=1 (confirmed only)
        let confResult = try await call(method: "z_gettotalbalance", params: [1])

        guard let unconf = unconfResult as? [String: Any],
              let conf = confResult as? [String: Any],
              let unconfTransparent = Double(unconf["transparent"] as? String ?? "0"),
              let confTransparent = Double(conf["transparent"] as? String ?? "0"),
              let unconfPrivate = Double(unconf["private"] as? String ?? "0"),
              let confPrivate = Double(conf["private"] as? String ?? "0") else {
            throw RPCError.invalidResponse
        }

        let pendingTransparent = unconfTransparent - confTransparent
        let pendingPrivate = unconfPrivate - confPrivate

        return (pendingTransparent, pendingPrivate)
    }

    /// Check if a specific transaction is confirmed
    public func getTransactionConfirmations(txid: String) async throws -> Int {
        let tx = try await getTransaction(txid: txid)
        return tx["confirmations"] as? Int ?? 0
    }

    /// Get raw mempool transaction IDs
    public func getRawMempool() async throws -> [String] {
        let result = try await call(method: "getrawmempool", params: [])
        guard let txids = result as? [String] else {
            return []
        }
        return txids
    }

    /// List received transactions for a z-address
    /// - Parameters:
    ///   - address: The z-address to query
    ///   - minconf: Minimum confirmations (default 1)
    /// - Returns: Array of received transactions
    public func zListReceivedByAddress(_ address: String, minconf: Int = 1) async throws -> [WalletTransaction] {
        let result = try await call(method: "z_listreceivedbyaddress", params: [address, minconf])

        guard let txList = result as? [[String: Any]] else {
            return []
        }

        // Verbose log removed

        // Get current chain height for timestamp estimation
        let chainHeight = blockHeight > 0 ? Int(blockHeight) : (try? await getInfo().height).map { Int($0) } ?? 2945000

        var transactions: [WalletTransaction] = []

        for tx in txList {
            guard let txid = tx["txid"] as? String else {
                continue
            }

            // FIX #286 v8: z_listreceivedbyaddress does NOT return confirmations/blockheight!
            // Fields returned: ["amount", "change", "memo", "outindex", "txid"]
            // We must call gettransaction to get the actual confirmations

            let amountDouble = tx["amount"] as? Double ?? 0
            let amount = UInt64(amountDouble * 100_000_000)
            let memoHex = tx["memo"] as? String
            let memo = memoHex.flatMap { Self.decodeMemo($0) }

            // FIX #286 v8: Call gettransaction to get confirmations and timestamp
            var confirmations = 0
            var blockheight: Int? = nil
            var timestamp = Date()

            do {
                let txDetails = try await getTransaction(txid: txid)
                confirmations = txDetails["confirmations"] as? Int ?? 0
                if let time = txDetails["time"] as? Int {
                    timestamp = Date(timeIntervalSince1970: TimeInterval(time))
                } else if let blocktime = txDetails["blocktime"] as? Int {
                    timestamp = Date(timeIntervalSince1970: TimeInterval(blocktime))
                }
                if let height = txDetails["height"] as? Int {
                    blockheight = height
                }
            } catch {
                // If gettransaction fails, estimate from chain height
                // Silently continue - this is not critical
            }

            transactions.append(WalletTransaction(
                txid: txid,
                address: address,
                amount: amount,
                fee: 0,
                type: .received,
                timestamp: timestamp,
                confirmations: confirmations,
                memo: memo,
                height: blockheight != nil ? UInt64(blockheight!) : nil
            ))
        }

        return transactions
    }

    /// List unspent outputs
    /// - Parameters:
    ///   - minConf: Minimum confirmations
    ///   - addresses: Optional filter by addresses
    /// - Returns: Array of unspent outputs
    public func listUnspent(minConf: Int = 1, addresses: [String]? = nil) async throws -> [[String: Any]] {
        var params: [Any] = [minConf, 9999999]
        if let addrs = addresses {
            params.append(addrs)
        }

        let result = try await call(method: "listunspent", params: params)

        guard let unspent = result as? [[String: Any]] else {
            return []
        }

        return unspent
    }

    /// FIX #367: Get shielded unspent outputs from full node (z_listunspent)
    /// This is FAST - uses RPC instead of P2P block scanning
    /// - Parameters:
    ///   - minConf: Minimum confirmations (0 for mempool)
    ///   - addresses: Optional list of z-addresses to filter
    /// - Returns: Array of shielded unspent outputs with txid, outindex, amount, address
    public func zListUnspent(minConf: Int = 0, addresses: [String]? = nil) async throws -> [[String: Any]] {
        var params: [Any] = [minConf, 9999999]

        // z_listunspent uses: minconf, maxconf, includeWatchonly, [addresses]
        params.append(false)  // includeWatchonly
        if let addrs = addresses, !addrs.isEmpty {
            params.append(addrs)
        }

        let result = try await call(method: "z_listunspent", params: params)

        guard let unspent = result as? [[String: Any]] else {
            return []
        }

        return unspent
    }

    /// Decode memo from hex string
    private static func decodeMemo(_ hex: String) -> String? {
        guard hex.count % 2 == 0 else { return nil }

        var bytes: [UInt8] = []
        var index = hex.startIndex

        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            if let byte = UInt8(hex[index..<nextIndex], radix: 16) {
                // Stop at null terminator or 0xf6 padding
                if byte == 0 || byte == 0xf6 { break }
                bytes.append(byte)
            }
            index = nextIndex
        }

        return String(bytes: bytes, encoding: .utf8)
    }

    // MARK: - Private Helpers

    private func call(method: String, params: [Any]) async throws -> Any {
        guard let config = config, let url = config.url else {
            throw RPCError.configNotFound
        }

        requestId += 1
        let body: [String: Any] = [
            "jsonrpc": "1.0",
            "id": requestId,
            "method": method,
            "params": params
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.authHeader, forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw RPCError.connectionFailed("Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            // Parse error message if available
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = json["error"] as? [String: Any],
               let message = error["message"] as? String {
                throw RPCError.requestFailed(sanitizeError(message))
            }
            throw RPCError.requestFailed("HTTP \(httpResponse.statusCode)")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RPCError.invalidResponse
        }

        if let error = json["error"] as? [String: Any],
           let message = error["message"] as? String {
            throw RPCError.requestFailed(sanitizeError(message))
        }

        return json["result"] as Any
    }

    private func waitForOperation(_ opid: String, timeout: TimeInterval = 300) async throws -> String {
        let startTime = Date()

        while Date().timeIntervalSince(startTime) < timeout {
            let result = try await call(method: "z_getoperationstatus", params: [[opid]])

            guard let operations = result as? [[String: Any]],
                  let operation = operations.first else {
                throw RPCError.invalidResponse
            }

            let status = operation["status"] as? String ?? ""

            switch status {
            case "success":
                if let resultDict = operation["result"] as? [String: Any],
                   let txid = resultDict["txid"] as? String {
                    return txid
                }
                throw RPCError.invalidResponse

            case "failed":
                let error = (operation["error"] as? [String: Any])?["message"] as? String ?? "Unknown error"
                throw RPCError.operationFailed(sanitizeError(error))

            case "executing", "queued":
                // Still in progress, wait and retry
                try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second

            default:
                throw RPCError.operationFailed("Unknown status: \(status)")
            }
        }

        throw RPCError.operationFailed("Operation timed out")
    }

    private func formatVersion(_ version: Int) -> String {
        let major = version / 1_000_000
        let minor = (version / 10_000) % 100
        let patch = (version / 100) % 100
        return "\(major).\(minor).\(patch)"
    }

    // MARK: - FIX #698: Block Header Methods for Sapling Root Recovery

    /// FIX #698: Get block hash at a specific height
    /// Used for sapling root recovery when P2P headers have zeros
    public func getBlockHash(height: UInt64) async throws -> String {
        let result = try await call(method: "getblockhash", params: [Int(height)])
        guard let hash = result as? String else {
            throw RPCError.invalidResponse
        }
        return hash
    }

    /// FIX #698: Get block header with sapling root
    /// Returns finalsaplingroot for anchor recovery
    public func getBlockHeader(hash: String) async throws -> (height: UInt64, saplingRoot: String, prevHash: String) {
        let result = try await call(method: "getblockheader", params: [hash])
        guard let header = result as? [String: Any],
              let height = header["height"] as? Int,
              let saplingRoot = header["finalsaplingroot"] as? String,
              let prevHash = header["previousblockhash"] as? String else {
            throw RPCError.invalidResponse
        }
        return (UInt64(height), saplingRoot, prevHash)
    }

    /// FIX #698: Get sapling root at a specific height
    /// Convenience method combining getBlockHash and getBlockHeader
    public func getSaplingRoot(at height: UInt64) async throws -> String {
        let hash = try await getBlockHash(height: height)
        let header = try await getBlockHeader(hash: hash)
        return header.saplingRoot
    }

    /// FIX #698: Recover sapling roots for a range of heights
    /// Returns dictionary of height -> saplingRoot (in little-endian storage format)
    public func recoverSaplingRoots(from startHeight: UInt64, to endHeight: UInt64, onProgress: ((Int, Int) -> Void)? = nil) async throws -> [UInt64: Data] {
        var results: [UInt64: Data] = [:]
        let total = Int(endHeight - startHeight + 1)

        for height in startHeight...endHeight {
            do {
                let saplingRootHex = try await getSaplingRoot(at: height)

                // Convert hex string to Data and reverse for little-endian storage
                if let saplingData = Data(hexString: saplingRootHex) {
                    let reversedData = Data(saplingData.reversed())
                    results[height] = reversedData
                }

                let progress = Int(height - startHeight + 1)
                onProgress?(progress, total)

            } catch {
                print("⚠️ FIX #698: Failed to get sapling root at height \(height): \(error)")
                // Continue with other heights
            }
        }

        return results
    }

    private func sanitizeError(_ message: String) -> String {
        // Remove sensitive information from error messages
        var sanitized = message

        // Remove file paths
        let pathPattern = #"/[^\s\"']+"#
        sanitized = sanitized.replacingOccurrences(of: pathPattern, with: "[path]", options: .regularExpression)

        // Remove IP addresses
        let ipPattern = #"\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}"#
        sanitized = sanitized.replacingOccurrences(of: ipPattern, with: "[ip]", options: .regularExpression)

        // Remove wallet addresses
        let zAddrPattern = #"zs[a-zA-Z0-9]{76}"#
        sanitized = sanitized.replacingOccurrences(of: zAddrPattern, with: "[z-addr]", options: .regularExpression)

        let tAddrPattern = #"t[13][a-zA-Z0-9]{33}"#
        sanitized = sanitized.replacingOccurrences(of: tAddrPattern, with: "[t-addr]", options: .regularExpression)

        return sanitized
    }
}

// MARK: - Data Extension

extension Data {
    func hexEncodedString() -> String {
        return map { String(format: "%02x", $0) }.joined()
    }
}

#endif
