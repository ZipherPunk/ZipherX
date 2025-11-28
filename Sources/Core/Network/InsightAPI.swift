import Foundation

/// Insight API client for Zclassic block explorer
/// Uses https://explorer.zcl.zelcore.io for blockchain data
final class InsightAPI {
    static let shared = InsightAPI()

    private let baseURL = "https://explorer.zcl.zelcore.io"

    private init() {}

    // MARK: - Status

    /// Get blockchain status
    func getStatus() async throws -> BlockchainStatus {
        let url = URL(string: "\(baseURL)/api/status")!
        let (data, _) = try await URLSession.shared.data(from: url)

        let response = try JSONDecoder().decode(StatusResponse.self, from: data)
        return BlockchainStatus(
            height: UInt64(response.info.blocks),
            difficulty: response.info.difficulty,
            connections: response.info.connections
        )
    }

    // MARK: - Blocks

    /// Get block hash by height
    func getBlockHash(height: UInt64) async throws -> String {
        let url = URL(string: "\(baseURL)/api/block-index/\(height)")!
        let (data, _) = try await URLSession.shared.data(from: url)

        let response = try JSONDecoder().decode(BlockIndexResponse.self, from: data)
        return response.blockHash
    }

    /// Get block by hash
    func getBlock(hash: String) async throws -> InsightBlock {
        let url = URL(string: "\(baseURL)/api/block/\(hash)")!
        let (data, _) = try await URLSession.shared.data(from: url)

        return try JSONDecoder().decode(InsightBlock.self, from: data)
    }

    /// Get raw block data by hash
    func getRawBlock(hash: String) async throws -> Data {
        let url = URL(string: "\(baseURL)/api/rawblock/\(hash)")!
        let (data, _) = try await URLSession.shared.data(from: url)

        let response = try JSONDecoder().decode(RawBlockResponse.self, from: data)
        guard let blockData = Data(hexString: response.rawblock) else {
            throw InsightError.invalidData
        }
        return blockData
    }

    // MARK: - Transactions

    /// Get transaction by txid
    func getTransaction(txid: String) async throws -> InsightTransaction {
        let url = URL(string: "\(baseURL)/api/tx/\(txid)")!
        let (data, _) = try await URLSession.shared.data(from: url)

        return try JSONDecoder().decode(InsightTransaction.self, from: data)
    }

    /// Verify transaction exists in mempool or blockchain
    /// Returns: (exists: Bool, confirmations: Int)
    /// - exists = true if tx is in mempool (0 confirmations) or blockchain (1+ confirmations)
    /// - exists = false if tx not found (rejected or never broadcast)
    func verifyTransactionExists(txid: String) async throws -> (exists: Bool, confirmations: Int) {
        do {
            let tx = try await getTransaction(txid: txid)
            return (exists: true, confirmations: tx.confirmations)
        } catch {
            // Check if it's a 404 (tx not found) vs network error
            if let urlError = error as? URLError {
                if urlError.code == .fileDoesNotExist || urlError.code == .resourceUnavailable {
                    return (exists: false, confirmations: 0)
                }
            }
            // For other errors, the tx might exist but we can't verify
            throw error
        }
    }

    /// Wait for transaction to appear in mempool/blockchain with retries
    /// - Parameters:
    ///   - txid: Transaction ID to check
    ///   - maxAttempts: Maximum number of retries (default 10)
    ///   - delaySeconds: Delay between retries (default 3 seconds)
    /// - Returns: True if tx found, false if not found after all attempts
    func waitForTransaction(txid: String, maxAttempts: Int = 10, delaySeconds: Double = 3.0) async throws -> Bool {
        for attempt in 1...maxAttempts {
            do {
                let (exists, confirmations) = try await verifyTransactionExists(txid: txid)
                if exists {
                    print("✅ Transaction verified on-chain: \(txid) (\(confirmations) confirmations)")
                    return true
                }
            } catch {
                // Ignore errors during retry, just continue
            }

            if attempt < maxAttempts {
                print("⏳ Waiting for tx to propagate... (attempt \(attempt)/\(maxAttempts))")
                try await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            }
        }

        return false
    }

    /// Get raw transaction
    func getRawTransaction(txid: String) async throws -> Data {
        let url = URL(string: "\(baseURL)/api/rawtx/\(txid)")!
        let (data, _) = try await URLSession.shared.data(from: url)

        let response = try JSONDecoder().decode(RawTxResponse.self, from: data)
        guard let txData = Data(hexString: response.rawtx) else {
            throw InsightError.invalidData
        }
        return txData
    }

    /// Get shielded outputs from raw transaction (full encCiphertext, not truncated)
    func getShieldedOutputsFromRaw(txid: String) async throws -> [ShieldedOutput] {
        let rawTx = try await getRawTransaction(txid: txid)
        return parseShieldedOutputs(from: rawTx)
    }

    /// Parse Sapling shielded outputs from raw transaction data
    /// This extracts the full 580-byte encCiphertext that the /api/tx endpoint truncates
    private func parseShieldedOutputs(from txData: Data) -> [ShieldedOutput] {
        var outputs: [ShieldedOutput] = []

        // Sapling transaction structure (v4):
        // - header (4 bytes)
        // - nVersionGroupId (4 bytes)
        // - vin (varint + inputs)
        // - vout (varint + outputs)
        // - nLockTime (4 bytes)
        // - nExpiryHeight (4 bytes)
        // - valueBalance (8 bytes)
        // - vShieldedSpend (varint + spends)
        // - vShieldedOutput (varint + outputs)
        // - bindingSig (64 bytes)

        guard txData.count > 20 else { return outputs }

        var offset = 0

        // Skip header (4 bytes) and nVersionGroupId (4 bytes)
        offset += 8

        // Skip transparent inputs
        let vinCount = readCompactSize(from: txData, at: &offset)
        for _ in 0..<vinCount {
            offset += 36 // prevout (32 + 4)
            let scriptLen = readCompactSize(from: txData, at: &offset)
            offset += Int(scriptLen) // scriptSig
            offset += 4 // sequence
        }

        // Skip transparent outputs
        let voutCount = readCompactSize(from: txData, at: &offset)
        for _ in 0..<voutCount {
            offset += 8 // value
            let scriptLen = readCompactSize(from: txData, at: &offset)
            offset += Int(scriptLen) // scriptPubKey
        }

        // Skip nLockTime (4) + nExpiryHeight (4) + valueBalance (8)
        offset += 16

        // Skip shielded spends
        let spendCount = readCompactSize(from: txData, at: &offset)
        for _ in 0..<spendCount {
            offset += 384 // cv(32) + anchor(32) + nullifier(32) + rk(32) + proof(192) + spendAuthSig(64)
        }

        // Read shielded outputs
        let outputCount = readCompactSize(from: txData, at: &offset)
        for _ in 0..<outputCount {
            guard offset + 948 <= txData.count else { break }

            let cv = txData[offset..<offset+32]
            offset += 32

            let cmu = txData[offset..<offset+32]
            offset += 32

            let ephemeralKey = txData[offset..<offset+32]
            offset += 32

            let encCiphertext = txData[offset..<offset+580]
            offset += 580

            let outCiphertext = txData[offset..<offset+80]
            offset += 80

            let proof = txData[offset..<offset+192]
            offset += 192

            // Convert to hex strings
            // cv, cmu, ephemeralKey need to be reversed to match display format (big-endian)
            // that the original API returns, since FilterScanner reverses them back
            // encCiphertext should NOT be reversed - it's raw ciphertext bytes
            let output = ShieldedOutput(
                cv: Data(cv.reversed()).map { String(format: "%02x", $0) }.joined(),
                cmu: Data(cmu.reversed()).map { String(format: "%02x", $0) }.joined(),
                ephemeralKey: Data(ephemeralKey.reversed()).map { String(format: "%02x", $0) }.joined(),
                encCiphertext: Data(encCiphertext).map { String(format: "%02x", $0) }.joined(),
                outCiphertext: Data(outCiphertext).map { String(format: "%02x", $0) }.joined(),
                proof: Data(proof).map { String(format: "%02x", $0) }.joined()
            )

            outputs.append(output)
        }

        return outputs
    }

    /// Read Bitcoin-style compact size (varint)
    private func readCompactSize(from data: Data, at offset: inout Int) -> UInt64 {
        guard offset < data.count else { return 0 }

        let first = data[offset]
        offset += 1

        if first < 253 {
            return UInt64(first)
        } else if first == 253 {
            guard offset + 2 <= data.count else { return 0 }
            let value = UInt16(data[offset]) | (UInt16(data[offset+1]) << 8)
            offset += 2
            return UInt64(value)
        } else if first == 254 {
            guard offset + 4 <= data.count else { return 0 }
            let value = UInt32(data[offset]) | (UInt32(data[offset+1]) << 8) | (UInt32(data[offset+2]) << 16) | (UInt32(data[offset+3]) << 24)
            offset += 4
            return UInt64(value)
        } else {
            guard offset + 8 <= data.count else { return 0 }
            var value: UInt64 = 0
            for i in 0..<8 {
                value |= UInt64(data[offset+i]) << (i * 8)
            }
            offset += 8
            return value
        }
    }

    /// Broadcast transaction
    func broadcastTransaction(rawTx: Data) async throws -> String {
        let url = URL(string: "\(baseURL)/api/tx/send")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = ["rawtx": rawTx.map { String(format: "%02x", $0) }.joined()]
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)

        // Check HTTP status code
        if let httpResponse = response as? HTTPURLResponse {
            if httpResponse.statusCode != 200 {
                // Try to parse error message from response
                if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let errorMessage = errorJson["error"] as? String ?? errorJson["message"] as? String {
                    print("Transaction broadcast rejected: \(errorMessage)")
                    throw InsightError.transactionRejected(errorMessage)
                }
                throw InsightError.transactionRejected("HTTP \(httpResponse.statusCode)")
            }
        }

        // Try to decode success response
        do {
            let broadcastResponse = try JSONDecoder().decode(BroadcastResponse.self, from: data)
            return broadcastResponse.txid
        } catch {
            // Check if the response contains an error message instead
            if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errorMessage = errorJson["error"] as? String ?? errorJson["message"] as? String {
                print("Transaction broadcast rejected: \(errorMessage)")
                throw InsightError.transactionRejected(errorMessage)
            }
            throw error
        }
    }

    // MARK: - Address

    /// Get address info (for transparent addresses)
    func getAddressInfo(address: String) async throws -> InsightAddressInfo {
        let url = URL(string: "\(baseURL)/api/addr/\(address)")!
        let (data, _) = try await URLSession.shared.data(from: url)

        return try JSONDecoder().decode(InsightAddressInfo.self, from: data)
    }
}

// MARK: - Response Types

private struct StatusResponse: Codable {
    let info: StatusInfo
}

private struct StatusInfo: Codable {
    let version: Int
    let protocolversion: Int
    let blocks: Int
    let timeoffset: Int
    let connections: Int
    let difficulty: Double
    let testnet: Bool
    let relayfee: Double
    let network: String
    let reward: Int
}

private struct BlockIndexResponse: Codable {
    let blockHash: String
}

private struct RawBlockResponse: Codable {
    let rawblock: String
}

private struct RawTxResponse: Codable {
    let rawtx: String
}

private struct BroadcastResponse: Codable {
    let txid: String
}

// MARK: - Public Types

struct BlockchainStatus {
    let height: UInt64
    let difficulty: Double
    let connections: Int
}

struct InsightBlock: Codable {
    let hash: String
    let height: Int
    let confirmations: Int
    let size: Int
    let time: Int
    let tx: [String] // Transaction IDs
    let previousblockhash: String?
    let nextblockhash: String?
}

struct InsightTransaction: Codable {
    let txid: String
    let blockhash: String?
    let blockheight: Int?
    let confirmations: Int
    let time: Int?
    let valueOut: Double
    let size: Int
    let spendDescs: [ShieldedSpend]?
    let outputDescs: [ShieldedOutput]?

    // Computed properties for compatibility with existing code
    var vShieldedSpend: [ShieldedSpend]? { spendDescs }
    var vShieldedOutput: [ShieldedOutput]? { outputDescs }
}

struct ShieldedSpend: Codable {
    let cv: String
    let anchor: String
    let nullifier: String
    let rk: String
    let proof: String
    let spendAuthSig: String
}

struct ShieldedOutput: Codable {
    let cv: String
    let cmu: String
    let ephemeralKey: String
    let encCiphertext: String
    let outCiphertext: String
    let proof: String
}

struct InsightAddressInfo: Codable {
    let addrStr: String
    let balance: Double
    let balanceSat: Int
    let totalReceived: Double
    let totalReceivedSat: Int
    let totalSent: Double
    let totalSentSat: Int
    let unconfirmedBalance: Double
    let unconfirmedBalanceSat: Int
    let unconfirmedTxApperances: Int
    let txApperances: Int
}

// MARK: - Errors

enum InsightError: LocalizedError {
    case invalidData
    case networkError
    case notFound
    case transactionRejected(String)

    var errorDescription: String? {
        switch self {
        case .invalidData:
            return "Invalid data from API"
        case .networkError:
            return "Network error"
        case .notFound:
            return "Resource not found"
        case .transactionRejected(let reason):
            return "Transaction rejected: \(reason)"
        }
    }
}

// MARK: - Data Extension

extension Data {
    init?(hexString: String) {
        let hex = hexString.dropFirst(hexString.hasPrefix("0x") ? 2 : 0)
        guard hex.count % 2 == 0 else { return nil }

        var data = Data()
        var index = hex.startIndex

        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else {
                return nil
            }
            data.append(byte)
            index = nextIndex
        }

        self = data
    }

    /// Reverse byte order (for converting between display format and wire format)
    /// Use this for EPK, cmu, cv from JSON APIs - these are displayed in big-endian
    /// but librustzcash expects little-endian wire format
    func reversedBytes() -> Data {
        Data(self.reversed())
    }

    /// Convert Data to hex string
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
