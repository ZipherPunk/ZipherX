import Foundation

/// Transaction type for wallet operations
public enum WalletTransactionType: String, Codable {
    case sent = "sent"
    case received = "received"
}

/// Unified transaction model for both ZipherX and RPC wallets
public struct WalletTransaction: Identifiable, Codable {
    public let id: String
    public let txid: String
    public let address: String
    public let amount: UInt64          // In zatoshis
    public let fee: UInt64             // In zatoshis
    public let type: WalletTransactionType
    public let timestamp: Date
    public let confirmations: Int
    public let memo: String?
    public let height: UInt64?

    public init(
        id: String = UUID().uuidString,
        txid: String,
        address: String,
        amount: UInt64,
        fee: UInt64 = 0,
        type: WalletTransactionType,
        timestamp: Date,
        confirmations: Int = 0,
        memo: String? = nil,
        height: UInt64? = nil
    ) {
        self.id = id
        self.txid = txid
        self.address = address
        self.amount = amount
        self.fee = fee
        self.type = type
        self.timestamp = timestamp
        self.confirmations = confirmations
        self.memo = memo
        self.height = height
    }
}

/// Wallet address with balance information
public struct WalletAddress: Identifiable, Codable {
    public let id: String
    public let address: String
    public let balance: UInt64         // In zatoshis
    public let isShielded: Bool
    public let label: String?

    public init(
        id: String = UUID().uuidString,
        address: String,
        balance: UInt64,
        isShielded: Bool,
        label: String? = nil
    ) {
        self.id = id
        self.address = address
        self.balance = balance
        self.isShielded = isShielded
        self.label = label
    }
}

/// Protocol defining wallet operations - abstraction layer for both ZipherX and RPC wallets
public protocol WalletOperationsProtocol: AnyObject {
    // MARK: - Address Management

    /// List all shielded (z) addresses in the wallet
    func listZAddresses() async throws -> [WalletAddress]

    /// List all transparent (t) addresses in the wallet
    func listTAddresses() async throws -> [WalletAddress]

    /// Create a new shielded (z) address
    func createZAddress() async throws -> String

    /// Create a new transparent (t) address
    func createTAddress() async throws -> String

    // MARK: - Balance

    /// Get balance for a specific z-address (in zatoshis)
    func getZBalance(address: String) async throws -> UInt64

    /// Get balance for a specific t-address (in zatoshis)
    func getTBalance(address: String) async throws -> UInt64

    /// Get total wallet balance
    /// Returns: (transparent, private/shielded, total) all in zatoshis
    func getTotalBalance() async throws -> (transparent: UInt64, private: UInt64, total: UInt64)

    // MARK: - Send Operations

    /// Send from a z-address
    /// - Parameters:
    ///   - from: Source z-address
    ///   - to: Destination address (z or t)
    ///   - amount: Amount in zatoshis
    ///   - memo: Optional memo (only for z-to-z transactions)
    /// - Returns: Transaction ID
    func sendFromZ(from: String, to: String, amount: UInt64, memo: String?) async throws -> String

    /// Send from a t-address
    /// - Parameters:
    ///   - from: Source t-address
    ///   - to: Destination address (t or z)
    ///   - amount: Amount in zatoshis
    /// - Returns: Transaction ID
    func sendFromT(from: String, to: String, amount: UInt64) async throws -> String

    // MARK: - Transaction History

    /// Get transaction history
    /// - Parameters:
    ///   - address: Optional specific address filter
    ///   - limit: Maximum number of transactions to return
    /// - Returns: Array of transactions sorted by timestamp (newest first)
    func getTransactionHistory(address: String?, limit: Int) async throws -> [WalletTransaction]

    // MARK: - Sync Status

    /// Get current sync status
    /// - Returns: (current height, is fully synced)
    func getSyncStatus() async throws -> (height: UInt64, synced: Bool)

    // MARK: - Key Management

    /// Export private key for an address
    func exportPrivateKey(address: String) async throws -> String

    /// Import a private key
    /// - Parameters:
    ///   - key: Private key (z or t format)
    ///   - rescan: Whether to rescan blockchain for transactions
    /// - Returns: The imported address
    func importPrivateKey(_ key: String, rescan: Bool) async throws -> String
}

/// Extension for convenience methods
public extension WalletOperationsProtocol {
    /// Get all addresses (both z and t)
    func getAllAddresses() async throws -> [WalletAddress] {
        async let zAddresses = listZAddresses()
        async let tAddresses = listTAddresses()

        return try await zAddresses + tAddresses
    }

    /// Convert zatoshis to ZCL
    func zatoshisToZCL(_ zatoshis: UInt64) -> Double {
        return Double(zatoshis) / 100_000_000.0
    }

    /// Convert ZCL to zatoshis
    func zclToZatoshis(_ zcl: Double) -> UInt64 {
        return UInt64(zcl * 100_000_000.0)
    }
}
