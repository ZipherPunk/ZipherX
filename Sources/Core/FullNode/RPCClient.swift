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
    public func importPrivateKey(_ key: String, rescan: Bool = false) async throws -> String {
        let isZKey = key.hasPrefix("secret-extended-key")
        let method = isZKey ? "z_importkey" : "importprivkey"
        let params: [Any] = isZKey ? [key, rescan ? "yes" : "no"] : [key, "", rescan]

        let result = try await call(method: method, params: params)

        if let address = result as? String {
            return address
        }

        // For z_importkey, get the address from z_listaddresses
        if isZKey {
            let addresses = try await getZAddresses()
            return addresses.last ?? "Import successful"
        }

        return "Import successful"
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

    /// Unlock wallet temporarily
    public func unlockWallet(passphrase: String, timeout: Int = 60) async throws {
        _ = try await call(method: "walletpassphrase", params: [passphrase, timeout])
    }

    /// Lock wallet
    public func lockWallet() async throws {
        _ = try await call(method: "walletlock", params: [])
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
