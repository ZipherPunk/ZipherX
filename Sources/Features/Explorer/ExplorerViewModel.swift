import Foundation
import Combine

/// View model for the blockchain explorer
class ExplorerViewModel: ObservableObject {
    @Published var searchQuery: String = ""
    @Published var searchResult: ExplorerResult?
    @Published var isLoading = false
    @Published var errorMessage: String?

    private var cancellables = Set<AnyCancellable>()

    init() {}

    /// Perform search based on query
    func search() {
        guard !searchQuery.isEmpty else { return }

        isLoading = true
        errorMessage = nil
        searchResult = nil

        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)

        Task {
            do {
                let result = try await performSearch(query)
                await MainActor.run {
                    self.searchResult = result
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }

    private func performSearch(_ query: String) async throws -> ExplorerResult {
        // Determine search type
        if query == "latest" {
            // Get latest block
            return try await searchLatestBlock()
        } else if let height = UInt64(query) {
            // Search by block height
            return try await searchBlock(height: height)
        } else if query.count == 64 && query.allSatisfy({ $0.isHexDigit }) {
            // Could be block hash or txid - try both
            if let result = try? await searchBlockByHash(query) {
                return result
            }
            return try await searchTransaction(txid: query)
        } else if query.hasPrefix("zs") || query.hasPrefix("zc") {
            // Z-address
            return try await searchAddress(query, isShielded: true)
        } else if query.hasPrefix("t1") || query.hasPrefix("t3") {
            // T-address
            return try await searchAddress(query, isShielded: false)
        } else {
            throw ExplorerError.invalidQuery
        }
    }

    // MARK: - Search Methods

    private func searchLatestBlock() async throws -> ExplorerResult {
        let modeManager = WalletModeManager.shared

        #if os(macOS)
        if modeManager.currentMode == .fullNode {
            // Use RPC
            let rpc = RPCClient.shared
            let info = try await rpc.getInfo()
            return try await searchBlock(height: info.height)
        }
        #endif

        // FIX #120: InsightAPI commented out - P2P only
        // let status = try await InsightAPI.shared.getStatus()
        // return try await searchBlock(height: status.height)

        // P2P-only: Use NetworkManager chain height
        let chainHeight = await NetworkManager.shared.chainHeight
        guard chainHeight > 0 else {
            throw ExplorerError.networkError("No P2P peers connected")
        }
        return try await searchBlock(height: chainHeight)
    }

    private func searchBlock(height: UInt64) async throws -> ExplorerResult {
        let modeManager = WalletModeManager.shared

        #if os(macOS)
        if modeManager.currentMode == .fullNode {
            let rpc = RPCClient.shared
            let blockData = try await rpc.getBlock(height: height)
            let block = parseBlockFromRPC(blockData, height: height)
            return .block(block)
        }
        #endif

        // FIX #120: InsightAPI commented out - P2P only
        // let block = try await fetchBlockFromInsight(height: height)
        // return .block(block)

        // P2P-only: Explorer requires Full Node mode or will show limited data
        throw ExplorerError.networkError("Explorer requires Full Node mode (P2P-only mode active)")
    }

    private func searchBlockByHash(_ hash: String) async throws -> ExplorerResult {
        let modeManager = WalletModeManager.shared

        #if os(macOS)
        if modeManager.currentMode == .fullNode {
            let rpc = RPCClient.shared
            let blockData = try await rpc.getBlock(hash: hash)
            let height = blockData["height"] as? UInt64 ?? 0
            let block = parseBlockFromRPC(blockData, height: height)
            return .block(block)
        }
        #endif

        // FIX #120: InsightAPI commented out - P2P only
        // let block = try await fetchBlockByHashFromInsight(hash: hash)
        // return .block(block)
        throw ExplorerError.networkError("Explorer requires Full Node mode (P2P-only mode active)")
    }

    private func searchTransaction(txid: String) async throws -> ExplorerResult {
        let modeManager = WalletModeManager.shared

        #if os(macOS)
        if modeManager.currentMode == .fullNode {
            let rpc = RPCClient.shared
            let txData = try await rpc.getTransaction(txid: txid)
            let tx = parseTransactionFromRPC(txData)
            return .transaction(tx)
        }
        #endif

        // FIX #120: InsightAPI commented out - P2P only
        // let tx = try await fetchTransactionFromInsight(txid: txid)
        // return .transaction(tx)
        throw ExplorerError.networkError("Explorer requires Full Node mode (P2P-only mode active)")
    }

    private func searchAddress(_ address: String, isShielded: Bool) async throws -> ExplorerResult {
        if isShielded {
            // Shielded addresses are private - don't expose balance
            return .address(ExplorerAddressInfo(
                address: address,
                isShielded: true,
                balance: nil,
                totalReceived: nil,
                transactionCount: nil
            ))
        }

        let modeManager = WalletModeManager.shared

        #if os(macOS)
        if modeManager.currentMode == .fullNode {
            let rpc = RPCClient.shared
            let balance = try await rpc.getAddressBalance(address)
            return .address(ExplorerAddressInfo(
                address: address,
                isShielded: false,
                balance: balance,
                totalReceived: nil,
                transactionCount: nil
            ))
        }
        #endif

        // FIX #120: InsightAPI commented out - P2P only
        // let addressInfo = try await fetchAddressFromInsight(address: address)
        // return .address(addressInfo)
        throw ExplorerError.networkError("Explorer requires Full Node mode (P2P-only mode active)")
    }

    // MARK: - RPC Parsing

    #if os(macOS)
    private func parseBlockFromRPC(_ data: [String: Any], height: UInt64) -> BlockInfo {
        let hash = data["hash"] as? String ?? ""
        let time = data["time"] as? Int ?? 0
        let size = data["size"] as? Int ?? 0
        let merkleRoot = data["merkleroot"] as? String
        let previousHash = data["previousblockhash"] as? String

        var transactions: [String] = []
        if let txArray = data["tx"] as? [[String: Any]] {
            transactions = txArray.compactMap { $0["txid"] as? String }
        } else if let txArray = data["tx"] as? [String] {
            transactions = txArray
        }

        return BlockInfo(
            hash: hash,
            height: height,
            time: TimeInterval(time),
            txCount: transactions.count,
            size: size,
            merkleRoot: merkleRoot,
            previousHash: previousHash,
            transactions: transactions
        )
    }

    private func parseTransactionFromRPC(_ data: [String: Any]) -> TransactionInfo {
        let txid = data["txid"] as? String ?? ""
        let size = data["size"] as? Int ?? 0
        let confirmations = data["confirmations"] as? Int ?? 0
        let time = data["time"] as? Int
        let blockHeight = data["height"] as? UInt64

        // Count shielded components
        let shieldedSpends = (data["vShieldedSpend"] as? [[String: Any]])?.count ?? 0
        let shieldedOutputs = (data["vShieldedOutput"] as? [[String: Any]])?.count ?? 0

        // Parse transparent inputs/outputs
        var transparentInputs: [TxIO] = []
        var transparentOutputs: [TxIO] = []

        if let vin = data["vin"] as? [[String: Any]] {
            for input in vin {
                if let address = input["address"] as? String,
                   let value = input["value"] as? Double {
                    transparentInputs.append(TxIO(address: address, value: value))
                }
            }
        }

        if let vout = data["vout"] as? [[String: Any]] {
            for output in vout {
                if let value = output["value"] as? Double,
                   let scriptPubKey = output["scriptPubKey"] as? [String: Any],
                   let addresses = scriptPubKey["addresses"] as? [String],
                   let address = addresses.first {
                    transparentOutputs.append(TxIO(address: address, value: value))
                }
            }
        }

        return TransactionInfo(
            txid: txid,
            blockHeight: blockHeight,
            confirmations: confirmations,
            time: time.map { TimeInterval($0) },
            size: size,
            shieldedSpends: shieldedSpends,
            shieldedOutputs: shieldedOutputs,
            transparentInputs: transparentInputs,
            transparentOutputs: transparentOutputs
        )
    }
    #endif

    // MARK: - InsightAPI Fetching

    private func fetchBlockFromInsight(height: UInt64) async throws -> BlockInfo {
        // Get block hash first
        let hashURL = URL(string: "https://explorer.zcl.zelcore.io/api/block-index/\(height)")!
        let (hashData, _) = try await URLSession.shared.data(from: hashURL)
        guard let hashJson = try JSONSerialization.jsonObject(with: hashData) as? [String: Any],
              let blockHash = hashJson["blockHash"] as? String else {
            throw ExplorerError.invalidResponse
        }

        return try await fetchBlockByHashFromInsight(hash: blockHash)
    }

    private func fetchBlockByHashFromInsight(hash: String) async throws -> BlockInfo {
        let url = URL(string: "https://explorer.zcl.zelcore.io/api/block/\(hash)")!
        let (data, _) = try await URLSession.shared.data(from: url)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ExplorerError.invalidResponse
        }

        let height = json["height"] as? UInt64 ?? 0
        let time = json["time"] as? Int ?? 0
        let size = json["size"] as? Int ?? 0
        let merkleRoot = json["merkleroot"] as? String
        let previousHash = json["previousblockhash"] as? String
        let transactions = json["tx"] as? [String] ?? []

        return BlockInfo(
            hash: hash,
            height: height,
            time: TimeInterval(time),
            txCount: transactions.count,
            size: size,
            merkleRoot: merkleRoot,
            previousHash: previousHash,
            transactions: transactions
        )
    }

    private func fetchTransactionFromInsight(txid: String) async throws -> TransactionInfo {
        let url = URL(string: "https://explorer.zcl.zelcore.io/api/tx/\(txid)")!
        let (data, _) = try await URLSession.shared.data(from: url)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ExplorerError.invalidResponse
        }

        let size = json["size"] as? Int ?? 0
        let confirmations = json["confirmations"] as? Int ?? 0
        let time = json["time"] as? Int
        let blockHeight = json["blockheight"] as? UInt64

        // Shielded components
        let shieldedSpends = (json["vShieldedSpend"] as? [[String: Any]])?.count ?? 0
        let shieldedOutputs = (json["vShieldedOutput"] as? [[String: Any]])?.count ?? 0

        // Transparent I/O
        var transparentInputs: [TxIO] = []
        var transparentOutputs: [TxIO] = []

        if let vin = json["vin"] as? [[String: Any]] {
            for input in vin {
                if let address = input["addr"] as? String,
                   let valueSat = input["valueSat"] as? Int64 {
                    transparentInputs.append(TxIO(address: address, value: Double(valueSat) / 100_000_000))
                }
            }
        }

        if let vout = json["vout"] as? [[String: Any]] {
            for output in vout {
                if let valueStr = output["value"] as? String,
                   let value = Double(valueStr),
                   let scriptPubKey = output["scriptPubKey"] as? [String: Any],
                   let addresses = scriptPubKey["addresses"] as? [String],
                   let address = addresses.first {
                    transparentOutputs.append(TxIO(address: address, value: value))
                }
            }
        }

        return TransactionInfo(
            txid: txid,
            blockHeight: blockHeight,
            confirmations: confirmations,
            time: time.map { TimeInterval($0) },
            size: size,
            shieldedSpends: shieldedSpends,
            shieldedOutputs: shieldedOutputs,
            transparentInputs: transparentInputs,
            transparentOutputs: transparentOutputs
        )
    }

    private func fetchAddressFromInsight(address: String) async throws -> ExplorerAddressInfo {
        let url = URL(string: "https://explorer.zcl.zelcore.io/api/addr/\(address)")!
        let (data, _) = try await URLSession.shared.data(from: url)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ExplorerError.invalidResponse
        }

        let balance = json["balance"] as? Double
        let totalReceived = json["totalReceived"] as? Double
        let txCount = json["txApperances"] as? Int

        return ExplorerAddressInfo(
            address: address,
            isShielded: false,
            balance: balance,
            totalReceived: totalReceived,
            transactionCount: txCount
        )
    }
}

// MARK: - Explorer Data Models

enum ExplorerResult {
    case block(BlockInfo)
    case transaction(TransactionInfo)
    case address(ExplorerAddressInfo)
}

struct BlockInfo {
    let hash: String
    let height: UInt64
    let time: TimeInterval
    let txCount: Int
    let size: Int
    let merkleRoot: String?
    let previousHash: String?
    let transactions: [String]

    // Cached DateFormatter — avoid per-call creation (ICU init is expensive)
    private static let cachedDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .medium
        return f
    }()

    var timeFormatted: String {
        let date = Date(timeIntervalSince1970: time)
        return Self.cachedDateFormatter.string(from: date)
    }
}

struct TransactionInfo {
    let txid: String
    let blockHeight: UInt64?
    let confirmations: Int
    let time: TimeInterval?
    let size: Int
    let shieldedSpends: Int
    let shieldedOutputs: Int
    let transparentInputs: [TxIO]
    let transparentOutputs: [TxIO]

    // Cached DateFormatter — avoid per-call creation (ICU init is expensive)
    private static let cachedDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .medium
        return f
    }()

    var timeFormatted: String? {
        guard let time = time else { return nil }
        let date = Date(timeIntervalSince1970: time)
        return Self.cachedDateFormatter.string(from: date)
    }
}

struct TxIO: Identifiable {
    let id = UUID()
    let address: String
    let value: Double
}

struct ExplorerAddressInfo {
    let address: String
    let isShielded: Bool
    let balance: Double?
    let totalReceived: Double?
    let transactionCount: Int?
}

enum ExplorerError: Error, LocalizedError {
    case invalidQuery
    case invalidResponse
    case notFound
    case networkError(String)

    var errorDescription: String? {
        switch self {
        case .invalidQuery:
            return "Invalid search query. Enter a block height, hash, transaction ID, or address."
        case .invalidResponse:
            return "Invalid response from explorer"
        case .notFound:
            return "Not found"
        case .networkError(let message):
            return message
        }
    }
}
