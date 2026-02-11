import Foundation

#if os(macOS)

/// RPC-based wallet operations using the Full Node's wallet.dat
/// All operations go through the zclassicd daemon via JSON-RPC
public class RPCWalletOperations: WalletOperationsProtocol, ObservableObject {
    public static let shared = RPCWalletOperations()

    private let rpcClient = RPCClient.shared

    @Published public var isConnected: Bool = false
    @Published public var lastError: String?

    private init() {}

    // MARK: - Connection

    /// Initialize connection to daemon
    public func connect() async throws {
        try rpcClient.loadConfig()
        let connected = await rpcClient.checkConnection()
        await MainActor.run {
            self.isConnected = connected
        }
        if !connected {
            throw RPCError.daemonNotRunning
        }
    }

    // MARK: - Address Management

    public func listZAddresses() async throws -> [WalletAddress] {
        let addresses = try await rpcClient.getZAddresses()
        var result: [WalletAddress] = []

        for address in addresses {
            let balance = try await getZBalance(address: address)
            result.append(WalletAddress(
                address: address,
                balance: balance,
                isShielded: true
            ))
        }

        return result.sorted { $0.balance > $1.balance }
    }

    public func listTAddresses() async throws -> [WalletAddress] {
        let addresses = try await rpcClient.getTAddresses()

        // Get actual unspent balance for each t-address using listunspent
        let unspentOutputs = try await rpcClient.listUnspent(minConf: 0, addresses: nil)

        // Sum up balances per address
        // FIX #287: Use rounded() to avoid floating-point precision errors
        var balanceMap: [String: UInt64] = [:]
        for utxo in unspentOutputs {
            if let addr = utxo["address"] as? String,
               let amount = utxo["amount"] as? Double {
                let zatoshis = UInt64((amount * 100_000_000).rounded())
                balanceMap[addr, default: 0] += zatoshis
            }
        }

        var result: [WalletAddress] = []
        for address in addresses {
            let balance = balanceMap[address] ?? 0
            result.append(WalletAddress(
                address: address,
                balance: balance,
                isShielded: false
            ))
        }

        return result.sorted { $0.balance > $1.balance }
    }

    public func createZAddress() async throws -> String {
        return try await rpcClient.createZAddress()
    }

    public func createTAddress() async throws -> String {
        return try await rpcClient.createTAddress()
    }

    // MARK: - Balance

    // FIX #287: Use rounded() to avoid floating-point precision errors
    // Double 0.00960000 * 100_000_000 can produce 959999.9999... due to IEEE 754
    // UInt64() truncates, so we must round first to get correct 960000

    // Protocol conformance: getZBalance(address:) with default minconf=1
    public func getZBalance(address: String) async throws -> UInt64 {
        let balance = try await rpcClient.getZBalance(address: address, minconf: 1)
        return UInt64((balance * 100_000_000).rounded())
    }

    // FIX #1272: Overload with explicit minconf parameter for pending balance queries.
    public func getZBalance(address: String, minconf: Int) async throws -> UInt64 {
        let balance = try await rpcClient.getZBalance(address: address, minconf: minconf)
        return UInt64((balance * 100_000_000).rounded())
    }

    public func getTBalance(address: String) async throws -> UInt64 {
        let balance = try await rpcClient.getTBalance(address: address)
        return UInt64((balance * 100_000_000).rounded())
    }

    public func getTotalBalance() async throws -> (transparent: UInt64, private: UInt64, total: UInt64) {
        let balance = try await rpcClient.getDetailedBalance()
        let transparent = UInt64((balance.transparent * 100_000_000).rounded())
        let privateBalance = UInt64((balance.private_ * 100_000_000).rounded())
        let total = UInt64((balance.total * 100_000_000).rounded())
        return (transparent, privateBalance, total)
    }

    // MARK: - Send Operations

    public func sendFromZ(from: String, to: String, amount: UInt64, memo: String?) async throws -> String {
        let amountZCL = Double(amount) / 100_000_000.0
        return try await rpcClient.sendTransaction(from: from, to: to, amount: amountZCL, memo: memo)
    }

    public func sendFromT(from: String, to: String, amount: UInt64) async throws -> String {
        let amountZCL = Double(amount) / 100_000_000.0
        return try await rpcClient.sendToAddress(from: from, to: to, amount: amountZCL)
    }

    // MARK: - Transaction History

    public func getTransactionHistory(address: String?, limit: Int) async throws -> [WalletTransaction] {
        // FIX #286: Use the new comprehensive transaction fetching method
        // This includes both incoming AND outgoing transactions for all address types
        print("📜 FIX #286: Getting transaction history (limit: \(limit), address: \(address ?? "all"))")

        if let specificAddress = address {
            // Filter by specific address
            let allTxs = try await rpcClient.getAllWalletTransactions(limit: limit * 2)
            return allTxs.filter { $0.address == specificAddress || $0.address.isEmpty }
                .prefix(limit)
                .map { $0 }
        } else {
            // Get all wallet transactions
            return try await rpcClient.getAllWalletTransactions(limit: limit)
        }
    }

    // MARK: - Sync Status

    public func getSyncStatus() async throws -> (height: UInt64, synced: Bool) {
        let info = try await rpcClient.getInfo()
        let blockchainInfo = try await rpcClient.getBlockchainInfo()

        // FIX #286 v4: Fixed sync status detection
        // Note: verificationprogress is BUGGY in zclassic daemon (stuck at 0.65)
        // Use blocks vs headers comparison instead (most reliable)
        let synced: Bool

        let blocks = blockchainInfo["blocks"] as? Int ?? 0
        let headers = blockchainInfo["headers"] as? Int ?? 0
        let initialBlockDownload = blockchainInfo["initialblockdownload"] as? Bool
        let verificationProgress = blockchainInfo["verificationprogress"] as? Double

        print("📊 FIX #286 v4: blocks=\(blocks), headers=\(headers), initialblockdownload=\(String(describing: initialBlockDownload)), verificationprogress=\(String(describing: verificationProgress))")

        // Method 1 (MOST RELIABLE): Compare blocks to headers
        // If we have all blocks up to known headers, we're synced
        if headers > 0 {
            // Allow 2 block difference for network propagation delay
            synced = blocks >= headers - 2
            print("📊 FIX #286 v4: Using blocks/headers comparison: \(blocks) >= \(headers - 2) = \(synced)")
        }
        // Method 2: Check initialblockdownload flag
        else if let ibd = initialBlockDownload {
            synced = !ibd
            print("📊 FIX #286 v4: Using initialblockdownload: \(!ibd)")
        }
        // Fallback: Assume synced if we have blocks and connections
        else {
            synced = blocks > 0 && info.connections > 0
            print("📊 FIX #286 v4: Fallback - blocks=\(blocks), connections=\(info.connections)")
        }

        print("📊 FIX #286 v4: Sync status - height: \(info.height), synced: \(synced)")
        return (info.height, synced)
    }

    // MARK: - Key Management

    public func exportPrivateKey(address: String) async throws -> String {
        return try await rpcClient.exportPrivateKey(address)
    }

    public func importPrivateKey(_ key: String, rescan: Bool) async throws -> String {
        return try await rpcClient.importPrivateKey(key, rescan: rescan)
    }
}

#endif
