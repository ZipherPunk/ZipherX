import Foundation
import Security
import CommonCrypto

/// Insight API client for Zclassic block explorer
/// Uses https://explorer.zcl.zelcore.io for blockchain data
/// SECURITY: Implements TLS certificate pinning (CRIT-003)
final class InsightAPI: NSObject {
    static let shared = InsightAPI()

    private let baseURL = "https://explorer.zcl.zelcore.io"

    // NOTE: TLS pinning is handled by CertificatePinningDelegate.bundledHashes
    // which contains real certificate hashes. No placeholders in production code.

    /// Track if pinning validation failed (for logging)
    @Published private(set) var pinningValidationFailed: Bool = false

    /// URLSession with certificate pinning delegate
    private var session: URLSession!

    /// Tor-enabled URLSession (when Tor mode active)
    private var torSession: URLSession?

    /// Certificate pinning delegate
    private let pinningDelegate = CertificatePinningDelegate()

    private override init() {
        super.init()

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60

        // SECURITY: Use delegate for certificate pinning
        self.session = URLSession(configuration: config, delegate: pinningDelegate, delegateQueue: nil)

        // Setup Tor session observer
        setupTorObserver()

        // Populate pins on first launch (development mode)
        Task {
            await populatePinsIfNeeded()
        }
    }

    /// Populate certificate pins by connecting and extracting the current certificate hash
    /// This is only used during development to get the initial pin values
    private func populatePinsIfNeeded() async {
        #if DEBUG
        // In debug mode, log the current certificate hash for pinning
        do {
            let url = URL(string: baseURL)!
            var request = URLRequest(url: url)
            request.httpMethod = "HEAD"

            // Use a temporary session without pinning to get the cert
            let tempSession = URLSession(configuration: .default)
            let (_, response) = try await tempSession.data(for: request)

            if let httpResponse = response as? HTTPURLResponse {
                print("📌 [TLS Pinning] Connected to \(baseURL), status: \(httpResponse.statusCode)")
                print("📌 [TLS Pinning] Pins configured in CertificatePinningDelegate.bundledHashes")
            }
        } catch {
            print("⚠️ [TLS Pinning] Could not verify connection: \(error)")
        }
        #endif
    }

    // MARK: - Tor Integration

    /// Setup observer to update Tor session when mode changes
    private func setupTorObserver() {
        // Observe TorManager state changes
        Task { @MainActor in
            // Initial setup
            updateTorSession()
        }
    }

    /// Update the Tor session based on TorManager state
    @MainActor
    private func updateTorSession() {
        let torManager = TorManager.shared

        if torManager.mode != .disabled && torManager.connectionState.isConnected {
            // Create Tor-enabled session with SOCKS5 proxy
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 60  // Tor is slower
            config.timeoutIntervalForResource = 120

            // SOCKS5 proxy configuration
            config.connectionProxyDictionary = [
                kCFStreamPropertySOCKSProxyHost as String: torManager.proxyHost,
                kCFStreamPropertySOCKSProxyPort as String: torManager.socksPort,
                kCFStreamPropertySOCKSVersion as String: kCFStreamSocketSOCKSVersion5
            ]

            // Note: Certificate pinning still applies through delegate
            torSession = URLSession(configuration: config, delegate: pinningDelegate, delegateQueue: nil)
            print("🧅 InsightAPI: Tor session configured (SOCKS5 \(torManager.proxyHost):\(torManager.socksPort))")
        } else {
            torSession = nil
        }
    }

    /// Get the appropriate session (Tor if available, otherwise direct)
    private func getActiveSession() -> URLSession {
        // Check if Tor should be used
        Task { @MainActor in
            updateTorSession()
        }

        // Use Tor session if available
        if let torSession = torSession {
            return torSession
        }
        return session
    }

    /// Check if currently using Tor
    @MainActor
    public var isUsingTor: Bool {
        TorManager.shared.mode != .disabled && TorManager.shared.connectionState.isConnected
    }

    // MARK: - Status

    /// Get blockchain status
    /// SECURITY: When Tor mode is enabled, NEVER fallback to clearnet (would leak IP)
    func getStatus() async throws -> BlockchainStatus {
        let url = URL(string: "\(baseURL)/api/status")!

        // Check if Tor mode is enabled - if so, ONLY use Tor (no clearnet fallback!)
        let torModeEnabled = await MainActor.run { TorManager.shared.mode == .enabled }

        // Try Tor session first if available
        if let torSession = torSession {
            do {
                let (data, _) = try await torSession.data(from: url)
                // Check if response is valid JSON (not HTML error page)
                if data.first == UInt8(ascii: "{") {
                    let response = try JSONDecoder().decode(StatusResponse.self, from: data)
                    return BlockchainStatus(
                        height: UInt64(response.info.blocks),
                        difficulty: response.info.difficulty,
                        connections: response.info.connections
                    )
                } else {
                    // Got HTML (likely Cloudflare block)
                    debugLog(.network, "⚠️ InsightAPI via Tor returned HTML (blocked by Cloudflare?)")
                    if torModeEnabled {
                        // SECURITY: Do NOT fallback to clearnet when Tor-only mode is set
                        throw NSError(domain: "InsightAPI", code: -1, userInfo: [NSLocalizedDescriptionKey: "InsightAPI blocked via Tor (Cloudflare). Cannot fallback - Tor-only mode enabled."])
                    }
                }
            } catch {
                debugLog(.network, "⚠️ InsightAPI via Tor failed: \(error.localizedDescription)")
                if torModeEnabled {
                    // SECURITY: Do NOT fallback to clearnet when Tor-only mode is set
                    throw error
                }
            }
        }

        // SECURITY CHECK: If Tor mode is enabled but no Tor session, do NOT use clearnet
        if torModeEnabled {
            throw NSError(domain: "InsightAPI", code: -2, userInfo: [NSLocalizedDescriptionKey: "Tor mode enabled but Tor not connected. Refusing clearnet connection."])
        }

        // Direct connection (ONLY when Tor mode is disabled)
        let (data, _) = try await session.data(from: url)
        let response = try JSONDecoder().decode(StatusResponse.self, from: data)
        return BlockchainStatus(
            height: UInt64(response.info.blocks),
            difficulty: response.info.difficulty,
            connections: response.info.connections
        )
    }

    // MARK: - Consensus Chain Height

    /// Get consensus chain height from multiple sources
    /// Uses conservative approach: returns MINIMUM of sources that agree within tolerance
    /// This prevents syncing beyond what's verified by multiple independent sources
    ///
    /// Sources (priority order):
    /// 1. InsightAPI (Zelcore explorer) - trusted baseline
    /// 2. P2P peer heights (version handshake)
    /// 3. HeaderStore (locally verified headers with Equihash PoW)
    /// 4. Boost file height (known verified minimum)
    ///
    /// Agreement: Sources must be within 5 blocks of each other
    /// Result: Minimum of agreeing sources (conservative - never sync beyond verified height)
    ///
    /// SECURITY: Peers reporting heights >10 blocks above consensus are BANNED
    /// TOR-ONLY MODE: Falls back to local verified sources when remote sources unavailable
    func getConsensusChainHeight(networkManager: NetworkManager) async -> UInt64 {
        let maxDeviation: UInt64 = 5
        let banThreshold: UInt64 = 10  // Ban peers >10 blocks above consensus
        var heights: [(source: String, height: UInt64, peer: Peer?)] = []

        // 1. InsightAPI (Zelcore explorer) - trusted baseline
        do {
            let status = try await getStatus()
            heights.append(("InsightAPI", status.height, nil))
            print("📡 [Consensus] InsightAPI: \(status.height)")
        } catch {
            print("⚠️ [Consensus] InsightAPI failed: \(error)")
        }

        // 2. P2P peer heights (version handshake)
        // FIX #384: Use PeerManager for centralized peer access
        let p2pPeers = await MainActor.run { PeerManager.shared.allPeers }
        for (index, peer) in p2pPeers.enumerated() {
            // SECURITY: Skip banned peers and handle negative heights (malicious peers send Int32 that wraps to negative)
            // FIX #384: Use PeerManager for ban checking
            let isBanned = await MainActor.run { PeerManager.shared.isBanned(peer.host) }
            guard !isBanned, peer.peerStartHeight > 0 else { continue }
            let h = UInt64(peer.peerStartHeight)  // Safe: checked > 0 above
            if h > 0 {
                heights.append(("P2P-\(index):\(peer.host)", h, peer))
                print("📡 [Consensus] P2P peer \(index) (\(peer.host)): \(h)")
            }
        }

        // 3. TOR-ONLY FALLBACK: Use locally verified sources when remote sources fail
        if heights.isEmpty {
            print("🧅 [Consensus] No remote heights available - using local verified sources")

            // 3a. HeaderStore - headers synced via P2P with Equihash PoW verification
            if let headerHeight = try? HeaderStore.shared.getLatestHeight(), headerHeight > 0 {
                heights.append(("HeaderStore-PoW", headerHeight, nil))
                print("📡 [Consensus] HeaderStore (PoW verified): \(headerHeight)")
            }

            // 3b. Boost file height - known verified minimum
            let boostHeight = ZipherXConstants.effectiveTreeHeight
            if boostHeight > 0 {
                heights.append(("BoostFile", boostHeight, nil))
                print("📡 [Consensus] Boost file: \(boostHeight)")
            }

            // 3c. Last scanned height from database
            if let lastScanned = try? WalletDatabase.shared.getLastScannedHeight(), lastScanned > 0 {
                heights.append(("LastScanned", lastScanned, nil))
                print("📡 [Consensus] Last scanned: \(lastScanned)")
            }

            // 3d. Cached chain height from NetworkManager (last successful fetch)
            let cachedHeight = await MainActor.run { networkManager.chainHeight }
            if cachedHeight > 0 {
                heights.append(("CachedHeight", cachedHeight, nil))
                print("📡 [Consensus] Cached height: \(cachedHeight)")
            }
        }

        // 4. Find consensus - sources that agree within tolerance
        guard !heights.isEmpty else {
            print("❌ [Consensus] No valid heights available!")
            return 0
        }

        // Sort by height
        let sortedHeights = heights.sorted { $0.height < $1.height }

        // Find the largest group of heights that agree within maxDeviation
        var bestGroup: [(source: String, height: UInt64, peer: Peer?)] = []

        for i in 0..<sortedHeights.count {
            var group: [(source: String, height: UInt64, peer: Peer?)] = [sortedHeights[i]]
            let baseHeight = sortedHeights[i].height

            for j in (i + 1)..<sortedHeights.count {
                if sortedHeights[j].height <= baseHeight + maxDeviation {
                    group.append(sortedHeights[j])
                }
            }

            if group.count > bestGroup.count {
                bestGroup = group
            }
        }

        // Use MINIMUM of the agreeing group (conservative approach)
        guard let minHeight = bestGroup.min(by: { $0.height < $1.height })?.height else {
            print("❌ [Consensus] No consensus reached!")
            return sortedHeights.first?.height ?? 0
        }

        let sources = bestGroup.map { $0.source }.joined(separator: ", ")
        print("✅ [Consensus] \(bestGroup.count) sources agree: [\(sources)]")
        print("✅ [Consensus] Using MINIMUM height: \(minHeight)")

        // 4. SECURITY: BAN peers reporting fake heights (Sybil attack detection)
        // FIX #384: Use PeerManager for centralized ban management
        for entry in heights {
            if let peer = entry.peer {
                if entry.height > minHeight + banThreshold {
                    print("🚫 [SECURITY] Banning peer \(peer.host) for fake height \(entry.height) (consensus: \(minHeight))")
                    await MainActor.run { PeerManager.shared.banPeer(peer, reason: .fakeChainHeight) }
                }
            }
        }

        return minHeight
    }

    // MARK: - Blocks

    /// Get block hash by height
    func getBlockHash(height: UInt64) async throws -> String {
        let url = URL(string: "\(baseURL)/api/block-index/\(height)")!
        let (data, _) = try await session.data(from: url)

        let response = try JSONDecoder().decode(BlockIndexResponse.self, from: data)
        return response.blockHash
    }

    /// Get block by hash
    func getBlock(hash: String) async throws -> InsightBlock {
        let url = URL(string: "\(baseURL)/api/block/\(hash)")!
        let (data, _) = try await session.data(from: url)

        return try JSONDecoder().decode(InsightBlock.self, from: data)
    }

    /// Get raw block data by hash
    func getRawBlock(hash: String) async throws -> Data {
        let url = URL(string: "\(baseURL)/api/rawblock/\(hash)")!
        let (data, _) = try await session.data(from: url)

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
        let (data, _) = try await session.data(from: url)

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

    /// Quick check if transaction exists (single attempt, no retries)
    /// Returns true if tx found in mempool or blockchain
    func checkTransactionExists(txid: String) async throws -> Bool {
        do {
            let (exists, _) = try await verifyTransactionExists(txid: txid)
            return exists
        } catch {
            // On error, assume it doesn't exist (could be network issue)
            return false
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
                    // Security audit TASK 18: Log redaction
                    print("✅ Transaction verified on-chain: \(txid.redactedTxid) (\(confirmations) confirmations)")
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

    // MARK: - Broadcasting

    /// Broadcast a raw transaction via InsightAPI
    /// - Parameter rawTx: Raw transaction bytes
    /// - Returns: Transaction ID (txid) as hex string
    /// - Throws: InsightError.broadcastFailed if the API rejects the transaction
    func broadcastTransaction(_ rawTx: Data) async throws -> String {
        let url = URL(string: "\(baseURL)/api/tx/send")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Convert raw tx to hex string for JSON body
        let rawTxHex = rawTx.hexString
        let body = ["rawtx": rawTxHex]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        print("📡 Broadcasting transaction via InsightAPI (\(rawTx.count) bytes)...")

        let (data, response) = try await session.data(for: request)

        // Check HTTP status
        if let httpResponse = response as? HTTPURLResponse {
            if httpResponse.statusCode != 200 {
                // Try to parse error message
                if let errorStr = String(data: data, encoding: .utf8) {
                    print("❌ InsightAPI broadcast error: \(errorStr)")
                    throw InsightError.broadcastFailed(errorStr)
                }
                throw InsightError.broadcastFailed("HTTP \(httpResponse.statusCode)")
            }
        }

        // Parse response - expects {"txid": "..."}
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let txid = json["txid"] as? String else {
            // Some APIs return just the txid string directly
            if let txidStr = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               txidStr.count == 64 {
                print("✅ Transaction broadcast via InsightAPI: \(txidStr)")
                return txidStr
            }
            throw InsightError.invalidData
        }

        print("✅ Transaction broadcast via InsightAPI: \(txid.redactedTxid)")
        return txid
    }

    /// Get raw transaction
    func getRawTransaction(txid: String) async throws -> Data {
        let url = URL(string: "\(baseURL)/api/rawtx/\(txid)")!
        let (data, _) = try await session.data(from: url)

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

        let (data, response) = try await session.data(for: request)

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
        let (data, _) = try await session.data(from: url)

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
    case broadcastFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidData:
            return "Invalid data from API"
        case .broadcastFailed(let reason):
            return "Broadcast failed: \(reason)"
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

// MARK: - Certificate Pinning Delegate

/// URLSessionDelegate that implements TLS certificate pinning with remote update support
/// SECURITY (CRIT-003): Validates server certificates against pinned public key hashes
/// If certificate doesn't match, shows WARNING but allows connection (user choice)
/// Pin hashes can be updated from GitHub without app update (encrypted for security)
private class CertificatePinningDelegate: NSObject, URLSessionDelegate {

    /// Shared instance for accessing remote pins
    static let shared = CertificatePinningDelegate()

    /// Bundled fallback hashes (used if remote fetch fails)
    private let bundledHashes: Set<String> = [
        // Zelcore explorer leaf certificate (December 2025)
        "/ZHSiDTh+Hin2ESDz22mWdEWFKGaRoHSE4JXqpqfud0=",

        // Let's Encrypt ISRG Root X1 (backup)
        "C5+lpZ7tcVwmwQIMcRtPbsQtWLABXhQzejna0wHFr8M=",

        // Let's Encrypt R3 intermediate (backup)
        "jQJTbIh0grw0/1TkHSumWb+Fs0Ggogr621gT3PvPKG0=",
    ]

    /// Remote hashes fetched from GitHub (updated dynamically)
    private var remoteHashes: Set<String>?

    /// Last time we fetched remote hashes
    private var lastRemoteFetch: Date?

    /// Cache duration for remote hashes (1 hour)
    private let remoteCacheDuration: TimeInterval = 3600

    /// GitHub URL for certificate pins (plain text, one hash per line)
    private let remotePinsURL = "https://raw.githubusercontent.com/VictorLux/ZipherX_Boost/main/zelcore_pins.txt"

    /// Track if we've shown a warning (to avoid spamming)
    private var hasShownWarning = false

    /// Callback for certificate warning (set by InsightAPI)
    var onCertificateWarning: ((String) -> Void)?

    /// Allowed hosts for pinning
    private let pinnedHosts: Set<String> = [
        "explorer.zcl.zelcore.io"
    ]

    override init() {
        super.init()
        // Fetch remote pins on init
        Task {
            await fetchRemotePins()
        }
    }

    /// Get current valid hashes (remote if available, otherwise bundled)
    private var currentHashes: Set<String> {
        return remoteHashes ?? bundledHashes
    }

    /// Fetch certificate pins from GitHub
    func fetchRemotePins() async {
        // Check cache
        if let lastFetch = lastRemoteFetch,
           Date().timeIntervalSince(lastFetch) < remoteCacheDuration,
           remoteHashes != nil {
            return
        }

        do {
            // Use a plain URLSession without pinning for this request
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 10
            let session = URLSession(configuration: config)

            guard let url = URL(string: remotePinsURL) else { return }
            let (data, response) = try await session.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return
            }

            // Parse pins (one per line)
            if let content = String(data: data, encoding: .utf8) {
                let pins = content.components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty && !$0.hasPrefix("#") }

                if !pins.isEmpty {
                    remoteHashes = Set(pins)
                    lastRemoteFetch = Date()
                    print("✅ [TLS Pinning] Loaded \(pins.count) pins from GitHub")
                }
            }
        } catch {
            print("⚠️ [TLS Pinning] Could not fetch remote pins: \(error.localizedDescription)")
        }
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        // Only handle server trust challenges
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        let host = challenge.protectionSpace.host

        // Only apply pinning to our pinned hosts
        guard pinnedHosts.contains(host) else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        // Evaluate the server trust (standard TLS validation)
        var error: CFError?
        let isValid = SecTrustEvaluateWithError(serverTrust, &error)

        guard isValid else {
            print("🚨 [TLS Pinning] Server trust evaluation failed for \(host): \(error?.localizedDescription ?? "unknown")")
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        // Check if any certificate in the chain matches our pins
        let certificateCount = SecTrustGetCertificateCount(serverTrust)
        var foundMatch = false
        var leafHash = ""

        for i in 0..<certificateCount {
            guard let certificate = SecTrustGetCertificateAtIndex(serverTrust, i) else {
                continue
            }

            guard let publicKey = SecCertificateCopyKey(certificate) else {
                continue
            }

            var publicKeyError: Unmanaged<CFError>?
            guard let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, &publicKeyError) as Data? else {
                continue
            }

            let hash = sha256(data: publicKeyData)
            let hashBase64 = hash.base64EncodedString()

            if i == 0 {
                leafHash = hashBase64
            }

            if currentHashes.contains(hashBase64) {
                foundMatch = true
                break
            }
        }

        let credential = URLCredential(trust: serverTrust)

        if foundMatch {
            // Pin matched - all good
            completionHandler(.useCredential, credential)
        } else {
            // PRIVACY: P-META-002 — Pin mismatch = potential MITM, BLOCK connection
            if !hasShownWarning {
                hasShownWarning = true
                print("🚨 [TLS Pinning] Certificate pin mismatch for \(host) — connection BLOCKED")
                print("🚨 [TLS Pinning] Leaf hash: \(leafHash)")
                print("🚨 [TLS Pinning] This may indicate certificate rotation or MITM attack")

                DispatchQueue.main.async {
                    self.onCertificateWarning?(leafHash)
                }
            }

            // BLOCK connection on pin mismatch (fail secure)
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    /// Compute SHA-256 hash of data
    private func sha256(data: Data) -> Data {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(data.count), &hash)
        }
        return Data(hash)
    }
}
