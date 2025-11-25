import Foundation
import Network
import CommonCrypto

/// Individual peer connection for Zclassic P2P network
final class Peer {
    let id: String
    let host: String
    let port: UInt16

    private let networkMagic: [UInt8]
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "com.zipherx.peer")

    // Protocol version
    private let protocolVersion: Int32 = 170011 // Latest Sapling support
    private let services: UInt64 = 1 // NODE_NETWORK
    private let userAgent = "/ZipherX:1.0.0/"

    // Peer scoring
    var score: PeerScore
    var lastSuccess: Date?
    var lastAttempt: Date?
    var consecutiveFailures: Int = 0
    var peerVersion: Int32 = 0
    var peerUserAgent: String = ""
    var peerStartHeight: Int32 = 0

    init(host: String, port: UInt16, networkMagic: [UInt8]) {
        self.id = UUID().uuidString
        self.host = host
        self.port = port
        self.networkMagic = networkMagic
        self.score = PeerScore()
    }

    // MARK: - Scoring

    func recordSuccess() {
        lastSuccess = Date()
        consecutiveFailures = 0
        score.successCount += 1
        score.lastResponseTime = Date()
    }

    func recordFailure() {
        consecutiveFailures += 1
        score.failureCount += 1
    }

    /// Calculate selection probability (higher = better peer)
    func getChance() -> Double {
        // Base chance
        var chance = 1.0

        // Reduce chance based on consecutive failures
        if consecutiveFailures > 0 {
            chance *= pow(0.66, Double(min(consecutiveFailures, 8)))
        }

        // Boost for recent success
        if let lastSuccess = lastSuccess {
            let hoursSinceSuccess = Date().timeIntervalSince(lastSuccess) / 3600
            if hoursSinceSuccess < 1 {
                chance *= 1.5
            } else if hoursSinceSuccess > 24 {
                chance *= 0.5
            }
        }

        // Boost for higher protocol version
        if peerVersion >= 170011 {
            chance *= 1.2
        }

        return chance
    }

    /// Check if peer should be banned
    func shouldBan() -> Bool {
        // Ban after 10 consecutive failures
        if consecutiveFailures >= 10 {
            return true
        }

        // Ban if success rate is terrible (after enough attempts)
        let totalAttempts = score.successCount + score.failureCount
        if totalAttempts >= 10 {
            let successRate = Double(score.successCount) / Double(totalAttempts)
            if successRate < 0.1 {
                return true
            }
        }

        return false
    }

    // MARK: - Connection

    func connect() async throws {
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(integerLiteral: port))

        let parameters = NWParameters.tcp
        // Don't restrict to wifi - allow any network interface
        // parameters.requiredInterfaceType = .wifi

        connection = NWConnection(to: endpoint, using: parameters)

        // Add timeout for connection
        return try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    var hasResumed = false

                    self.connection?.stateUpdateHandler = { state in
                        guard !hasResumed else { return }

                        switch state {
                        case .ready:
                            hasResumed = true
                            continuation.resume()
                        case .failed(let error):
                            hasResumed = true
                            continuation.resume(throwing: NetworkError.connectionFailed(error.localizedDescription))
                        case .cancelled:
                            hasResumed = true
                            continuation.resume(throwing: NetworkError.connectionFailed("Connection cancelled"))
                        default:
                            break
                        }
                    }

                    self.connection?.start(queue: self.queue)
                }
            }

            group.addTask {
                try await Task.sleep(nanoseconds: 5_000_000_000) // 5 second timeout
                throw NetworkError.timeout
            }

            // Wait for first to complete (connection or timeout)
            try await group.next()
            group.cancelAll()
        }
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
    }

    // MARK: - Handshake

    func performHandshake() async throws {
        lastAttempt = Date()

        // Send version message
        let versionPayload = buildVersionPayload()
        try await sendMessage(command: "version", payload: versionPayload)

        // Receive version and parse peer info
        let (_, versionResponse) = try await receiveMessage()
        parseVersionPayload(versionResponse)

        // Send verack
        try await sendMessage(command: "verack", payload: Data())

        // Receive verack
        let _ = try await receiveMessage()

        recordSuccess()
    }

    private func parseVersionPayload(_ data: Data) {
        guard data.count >= 80 else { return }

        // Protocol version (bytes 0-3) - use safe loading
        peerVersion = data.loadInt32(at: 0)

        // Skip services (8), timestamp (8), addr_recv (26), addr_from (26), nonce (8)
        // = 76 bytes, then user agent

        var offset = 80
        if offset < data.count {
            let agentLength = Int(data[offset])
            offset += 1
            if offset + agentLength <= data.count {
                peerUserAgent = String(bytes: data[offset..<(offset + agentLength)], encoding: .utf8) ?? ""
                offset += agentLength
            }
        }

        // Start height
        if offset + 4 <= data.count {
            peerStartHeight = data.loadInt32(at: offset)
        }
    }

    // MARK: - Peer Discovery

    /// Request addresses from this peer
    func getAddresses() async throws -> [PeerAddress] {
        try await sendMessage(command: "getaddr", payload: Data())

        let (command, response) = try await receiveMessage()

        guard command == "addr" else {
            return []
        }

        return parseAddrPayload(response)
    }

    private func parseAddrPayload(_ data: Data) -> [PeerAddress] {
        var addresses: [PeerAddress] = []
        var offset = 0

        // First byte is count (varint, simplified as single byte for now)
        guard data.count > 0 else { return [] }
        let count = Int(data[0])
        offset = 1

        // Each addr entry: timestamp (4) + services (8) + IPv6 (16) + port (2) = 30 bytes
        let entrySize = 30

        for _ in 0..<count {
            guard offset + entrySize <= data.count else { break }

            // Skip timestamp (4) and services (8)
            offset += 12

            // IPv6 address (16 bytes) - IPv4 mapped as ::ffff:x.x.x.x
            let ipBytes = data[offset..<(offset + 16)]
            offset += 16

            // Port (big endian)
            let port = data.loadUInt16BE(at: offset)
            offset += 2

            // Convert to IPv4 if mapped
            if let host = parseIPAddress(Array(ipBytes)) {
                addresses.append(PeerAddress(host: host, port: port))
            }
        }

        return addresses
    }

    private func parseIPAddress(_ bytes: [UInt8]) -> String? {
        guard bytes.count == 16 else { return nil }

        // Check for IPv4-mapped IPv6 (::ffff:x.x.x.x)
        let ipv4Prefix: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff]
        if Array(bytes.prefix(12)) == ipv4Prefix {
            return "\(bytes[12]).\(bytes[13]).\(bytes[14]).\(bytes[15])"
        }

        // Pure IPv6 - format as hex
        var parts: [String] = []
        for i in stride(from: 0, to: 16, by: 2) {
            let value = (UInt16(bytes[i]) << 8) | UInt16(bytes[i + 1])
            parts.append(String(format: "%x", value))
        }
        return parts.joined(separator: ":")
    }

    private func buildVersionPayload() -> Data {
        var payload = Data()

        // Protocol version
        payload.append(contentsOf: withUnsafeBytes(of: protocolVersion.littleEndian) { Array($0) })

        // Services
        payload.append(contentsOf: withUnsafeBytes(of: services.littleEndian) { Array($0) })

        // Timestamp
        let timestamp = Int64(Date().timeIntervalSince1970)
        payload.append(contentsOf: withUnsafeBytes(of: timestamp.littleEndian) { Array($0) })

        // Recipient address (26 bytes)
        payload.append(contentsOf: [UInt8](repeating: 0, count: 26))

        // Sender address (26 bytes)
        payload.append(contentsOf: [UInt8](repeating: 0, count: 26))

        // Nonce
        let nonce = UInt64.random(in: 0...UInt64.max)
        payload.append(contentsOf: withUnsafeBytes(of: nonce.littleEndian) { Array($0) })

        // User agent
        let agentData = userAgent.data(using: .utf8)!
        payload.append(UInt8(agentData.count))
        payload.append(agentData)

        // Start height
        let startHeight: Int32 = 0
        payload.append(contentsOf: withUnsafeBytes(of: startHeight.littleEndian) { Array($0) })

        return payload
    }

    // MARK: - Message Protocol

    func sendMessage(command: String, payload: Data) async throws {
        var message = Data()

        // Magic bytes
        message.append(contentsOf: networkMagic)

        // Command (12 bytes, null-padded)
        var commandBytes = [UInt8](command.utf8)
        commandBytes.append(contentsOf: [UInt8](repeating: 0, count: 12 - commandBytes.count))
        message.append(contentsOf: commandBytes)

        // Payload length
        let length = UInt32(payload.count)
        message.append(contentsOf: withUnsafeBytes(of: length.littleEndian) { Array($0) })

        // Checksum (first 4 bytes of double SHA256)
        let checksum = payload.doubleSHA256().prefix(4)
        message.append(checksum)

        // Payload
        message.append(payload)

        try await send(message)
    }

    func receiveMessage() async throws -> (String, Data) {
        // Read header (24 bytes)
        let header = try await receive(count: 24)

        // Verify magic
        guard Array(header.prefix(4)) == networkMagic else {
            throw NetworkError.handshakeFailed
        }

        // Parse command
        let commandBytes = header[4..<16]
        let command = String(bytes: commandBytes.prefix(while: { $0 != 0 }), encoding: .utf8) ?? ""

        // Parse length (safe loading)
        let length = header.loadUInt32(at: 16)

        // Read payload
        var payload = Data()
        if length > 0 {
            payload = try await receive(count: Int(length))
        }

        return (command, payload)
    }

    // MARK: - Network I/O

    private func send(_ data: Data) async throws {
        guard let connection = connection else {
            throw NetworkError.notConnected
        }

        return try await withCheckedThrowingContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private func receive(count: Int) async throws -> Data {
        guard let connection = connection else {
            throw NetworkError.notConnected
        }

        return try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let data = data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: NetworkError.timeout)
                }
            }
        }
    }

    // MARK: - RPC Methods

    func getShieldedBalance(address: String) async throws -> ShieldedBalance {
        // Build getaddressbalance request
        let payload = buildAddressPayload(address)
        try await sendMessage(command: "getbalance", payload: payload)

        let (_, response) = try await receiveMessage()

        // Parse balance response
        guard response.count >= 16 else {
            throw NetworkError.consensusNotReached
        }

        let confirmed = response.loadUInt64(at: 0)
        let pending = response.loadUInt64(at: 8)

        return ShieldedBalance(confirmed: confirmed, pending: pending)
    }

    func broadcastTransaction(_ rawTx: Data) async throws -> String {
        try await sendMessage(command: "tx", payload: rawTx)

        let (command, response) = try await receiveMessage()

        // Check for rejection
        if command == "reject" {
            // Parse reject message: varint message_type + reason_code + varint reason_text
            var offset = 0
            // Skip message type (varint + string)
            if response.count > 0 {
                let msgLen = Int(response[0])
                offset = 1 + msgLen
            }
            if offset < response.count {
                let rejectCode = response[offset]
                let codeNames = ["MALFORMED", "INVALID", "OBSOLETE", "DUPLICATE", "NONSTANDARD", "DUST", "INSUFFICIENTFEE", "CHECKPOINT"]
                let codeName = rejectCode < codeNames.count ? codeNames[Int(rejectCode)] : "UNKNOWN(\(rejectCode))"

                // Get reason text
                var reason = ""
                if offset + 1 < response.count {
                    let reasonLen = Int(response[offset + 1])
                    if offset + 2 + reasonLen <= response.count {
                        reason = String(data: response[(offset + 2)..<(offset + 2 + reasonLen)], encoding: .utf8) ?? ""
                    }
                }
                print("❌ Transaction rejected: \(codeName) - \(reason)")
                throw NetworkError.transactionRejected
            }
        }

        print("📨 Broadcast response: \(command)")

        // TX ID is the double SHA256 hash of the raw transaction
        let txId = rawTx.doubleSHA256().reversed()
        return txId.map { String(format: "%02x", $0) }.joined()
    }

    func getBlockHeaders(from height: UInt64, count: Int) async throws -> [BlockHeader] {
        // Build getheaders message with block locator
        var payload = Data()

        // Protocol version
        payload.append(contentsOf: withUnsafeBytes(of: UInt32(170011).littleEndian) { Array($0) })

        // Hash count = 1 (we'll use genesis or a known hash)
        payload.append(UInt8(1))

        // Block locator hash - use genesis hash to get headers from beginning
        // For specific height, we'd need to know that block's hash
        let genesisHash = Data(repeating: 0, count: 32)
        payload.append(genesisHash)

        // Stop hash (zeros = get up to 2000 headers)
        payload.append(Data(repeating: 0, count: 32))

        try await sendMessage(command: "getheaders", payload: payload)

        // Skip any non-headers messages
        var command = ""
        var response = Data()
        var attempts = 0

        while command != "headers" && attempts < 5 {
            let (cmd, resp) = try await receiveMessage()
            if cmd == "headers" {
                command = cmd
                response = resp
                break
            }
            print("⏭️ Skipping \(cmd), waiting for headers...")
            attempts += 1
        }

        guard command == "headers" else {
            return []
        }

        // Parse headers response
        var headers: [BlockHeader] = []
        var offset = 0

        // First byte is varint count
        guard response.count >= 1 else { return [] }
        let headerCount = Int(response[offset])
        offset += 1

        let headerSize = 1487 // Zcash/Zclassic header size with Equihash solution

        for _ in 0..<min(headerCount, count) {
            guard offset + headerSize <= response.count else { break }

            let header = BlockHeader(
                version: response.loadInt32(at: offset),
                prevBlockHash: Data(response[(offset + 4)..<(offset + 36)]),
                merkleRoot: Data(response[(offset + 36)..<(offset + 68)]),
                timestamp: response.loadUInt32(at: offset + 100),
                bits: response.loadUInt32(at: offset + 104),
                nonce: Data(response[(offset + 108)..<(offset + 140)]),
                solution: Data(response[(offset + 140)..<(offset + headerSize)])
            )

            headers.append(header)
            offset += headerSize
        }

        print("📋 Received \(headers.count) headers")
        return headers
    }

    func getCompactFilters(from height: UInt64, count: Int) async throws -> [CompactFilter] {
        var payload = Data()
        payload.append(UInt8(0)) // Filter type (basic)
        payload.append(contentsOf: withUnsafeBytes(of: height.littleEndian) { Array($0) })
        payload.append(contentsOf: withUnsafeBytes(of: UInt32(count).littleEndian) { Array($0) })

        try await sendMessage(command: "getcfilters", payload: payload)

        let (_, response) = try await receiveMessage()

        // Parse filters
        var filters: [CompactFilter] = []
        var offset = 0

        while offset < response.count {
            // Filter type
            let filterType = response[offset]
            offset += 1

            // Block hash
            let blockHash = Data(response[offset..<(offset + 32)])
            offset += 32

            // Filter length (varint)
            let filterLength = Int(response[offset])
            offset += 1

            // Filter data
            let filterData = Data(response[offset..<(offset + filterLength)])
            offset += filterLength

            filters.append(CompactFilter(blockHash: blockHash, filterType: filterType, filterData: filterData))
        }

        return filters
    }

    /// Get compact blocks (ZIP-307) for shielded scanning
    func getCompactBlocks(from height: UInt64, count: Int) async throws -> [CompactBlock] {
        // Request blocks using getdata with compact block type
        var payload = Data()

        // Number of items
        payload.append(UInt8(count))

        // For each block height, request the compact block
        for i in 0..<count {
            let blockHeight = height + UInt64(i)
            // Inventory type: 4 = compact block (MSG_CMPCT_BLOCK)
            payload.append(contentsOf: withUnsafeBytes(of: UInt32(4).littleEndian) { Array($0) })
            // Block hash placeholder - in real impl, we'd need the actual hash
            // For now, encode height as identifier
            var hashData = Data(count: 32)
            hashData.replaceSubrange(0..<8, with: withUnsafeBytes(of: blockHeight.littleEndian) { Data($0) })
            payload.append(hashData)
        }

        try await sendMessage(command: "getdata", payload: payload)

        var blocks: [CompactBlock] = []

        // Receive compact blocks
        for _ in 0..<count {
            let (command, response) = try await receiveMessage()

            guard command == "cmpctblock" || command == "block" else {
                continue
            }

            // Parse compact block
            if let block = parseCompactBlock(response) {
                blocks.append(block)
            }
        }

        return blocks
    }

    /// Get full blocks by height range using getheaders then getdata
    func getFullBlocks(from height: UInt64, count: Int) async throws -> [CompactBlock] {
        // Step 1: Get block headers to obtain hashes
        let headers = try await getBlockHeaders(from: height, count: count)

        guard !headers.isEmpty else {
            print("⚠️ No headers received")
            return []
        }

        // Extract block hashes from headers
        let blockHashes = headers.map { $0.hash }

        // Step 2: Request full blocks via getdata
        var getdataPayload = Data()
        getdataPayload.append(UInt8(blockHashes.count))

        for hash in blockHashes {
            // Type 2 = MSG_BLOCK
            getdataPayload.append(contentsOf: withUnsafeBytes(of: UInt32(2).littleEndian) { Array($0) })
            getdataPayload.append(hash)
        }

        try await sendMessage(command: "getdata", payload: getdataPayload)

        // Receive block messages
        var blocks: [CompactBlock] = []

        for (index, hash) in blockHashes.enumerated() {
            let (command, response) = try await receiveMessage()

            guard command == "block" else {
                print("⚠️ Expected block, got \(command)")
                continue
            }

            // Parse the full block
            if var block = parseCompactBlock(response) {
                // Set correct height
                block = CompactBlock(
                    blockHeight: height + UInt64(index),
                    blockHash: hash,
                    prevHash: block.prevHash,
                    time: block.time,
                    transactions: block.transactions
                )
                blocks.append(block)
                print("📦 Got block \(height + UInt64(index))")
            }
        }

        return blocks
    }

    /// Parse a compact block from raw data
    private func parseCompactBlock(_ data: Data) -> CompactBlock? {
        guard data.count >= 80 else { return nil }

        var offset = 0

        // Block header (80 bytes)
        let version = data.loadUInt32(at: offset)
        offset += 4

        let prevHash = Data(data[offset..<offset+32])
        offset += 32

        let merkleRoot = Data(data[offset..<offset+32])
        offset += 32

        let time = data.loadUInt32(at: offset)
        offset += 4

        let bits = data.loadUInt32(at: offset)
        offset += 4

        let nonce = data.loadUInt32(at: offset)
        offset += 4

        // Compute block hash from header
        let headerData = data.prefix(80)
        let blockHash = headerData.doubleSHA256()

        // Parse transactions
        var transactions: [CompactTx] = []

        // Read tx count (varint)
        guard offset < data.count else {
            return CompactBlock(
                blockHeight: 0, // Will be set by caller
                blockHash: blockHash,
                prevHash: prevHash,
                time: time,
                transactions: []
            )
        }

        let txCount = Int(data[offset])
        offset += 1

        for txIndex in 0..<txCount {
            guard offset < data.count else { break }

            // Parse Sapling bundle from transaction
            let (spends, outputs, newOffset) = parseSaplingBundle(data, offset: offset)
            offset = newOffset

            // Create compact transaction
            let txHash = Data(repeating: 0, count: 32) // Placeholder
            transactions.append(CompactTx(
                txIndex: UInt64(txIndex),
                txHash: txHash,
                spends: spends,
                outputs: outputs
            ))
        }

        return CompactBlock(
            blockHeight: 0, // Will be set by caller based on request
            blockHash: blockHash,
            prevHash: prevHash,
            time: time,
            transactions: transactions
        )
    }

    /// Parse Sapling spends and outputs from transaction data
    private func parseSaplingBundle(_ data: Data, offset: Int) -> ([CompactSpend], [CompactOutput], Int) {
        var currentOffset = offset
        var spends: [CompactSpend] = []
        var outputs: [CompactOutput] = []

        guard currentOffset + 1 <= data.count else {
            return (spends, outputs, currentOffset)
        }

        // Number of Sapling spends
        let spendCount = Int(data[currentOffset])
        currentOffset += 1

        for _ in 0..<spendCount {
            guard currentOffset + 32 <= data.count else { break }
            // Nullifier (32 bytes)
            let nullifier = Data(data[currentOffset..<currentOffset+32])
            currentOffset += 32
            spends.append(CompactSpend(nullifier: nullifier))

            // Skip rest of spend description (cv, anchor, rk, proof, sig)
            currentOffset += 32 + 32 + 32 + 192 + 64 // Approximate
        }

        guard currentOffset + 1 <= data.count else {
            return (spends, outputs, currentOffset)
        }

        // Number of Sapling outputs
        let outputCount = Int(data[currentOffset])
        currentOffset += 1

        for _ in 0..<outputCount {
            guard currentOffset + 32 + 32 + 580 <= data.count else { break }

            // cmu - note commitment (32 bytes)
            let cmu = Data(data[currentOffset..<currentOffset+32])
            currentOffset += 32

            // epk - ephemeral key (32 bytes)
            let epk = Data(data[currentOffset..<currentOffset+32])
            currentOffset += 32

            // enc_ciphertext (580 bytes)
            let ciphertext = Data(data[currentOffset..<currentOffset+580])
            currentOffset += 580

            outputs.append(CompactOutput(cmu: cmu, epk: epk, ciphertext: ciphertext))

            // Skip rest of output (out_ciphertext, proof)
            currentOffset += 80 + 192 // Approximate
        }

        return (spends, outputs, currentOffset)
    }

    // MARK: - Helpers

    private func buildAddressPayload(_ address: String) -> Data {
        var payload = Data()
        let addressData = address.data(using: .utf8)!
        payload.append(UInt8(addressData.count))
        payload.append(addressData)
        return payload
    }
}

// MARK: - Data Extensions

extension Data {
    func doubleSHA256() -> Data {
        var firstHash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        var secondHash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))

        self.withUnsafeBytes { ptr in
            _ = CC_SHA256(ptr.baseAddress, CC_LONG(self.count), &firstHash)
        }

        _ = CC_SHA256(firstHash, CC_LONG(firstHash.count), &secondHash)

        return Data(secondHash)
    }

    // Safe integer loading (avoids alignment issues)
    func loadUInt16(at offset: Int) -> UInt16 {
        guard offset + 2 <= count else { return 0 }
        return UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func loadUInt16BE(at offset: Int) -> UInt16 {
        guard offset + 2 <= count else { return 0 }
        return (UInt16(self[offset]) << 8) | UInt16(self[offset + 1])
    }

    func loadUInt32(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        return UInt32(self[offset]) |
               (UInt32(self[offset + 1]) << 8) |
               (UInt32(self[offset + 2]) << 16) |
               (UInt32(self[offset + 3]) << 24)
    }

    func loadInt32(at offset: Int) -> Int32 {
        return Int32(bitPattern: loadUInt32(at: offset))
    }

    func loadUInt64(at offset: Int) -> UInt64 {
        guard offset + 8 <= count else { return 0 }
        let b0 = UInt64(self[offset])
        let b1 = UInt64(self[offset + 1]) << 8
        let b2 = UInt64(self[offset + 2]) << 16
        let b3 = UInt64(self[offset + 3]) << 24
        let b4 = UInt64(self[offset + 4]) << 32
        let b5 = UInt64(self[offset + 5]) << 40
        let b6 = UInt64(self[offset + 6]) << 48
        let b7 = UInt64(self[offset + 7]) << 56
        return b0 | b1 | b2 | b3 | b4 | b5 | b6 | b7
    }
}

// MARK: - Peer Score

struct PeerScore {
    var successCount: Int = 0
    var failureCount: Int = 0
    var lastResponseTime: Date?
    var bytesReceived: UInt64 = 0
    var bytesSent: UInt64 = 0
}

// MARK: - Banned Peer

struct BannedPeer {
    let address: String
    let banTime: Date
    let banDuration: TimeInterval // Default 24 hours
    let reason: BanReason

    var isExpired: Bool {
        Date() > banTime.addingTimeInterval(banDuration)
    }
}

enum BanReason: String {
    case tooManyFailures = "Too many consecutive failures"
    case lowSuccessRate = "Very low success rate"
    case invalidMessages = "Sent invalid messages"
    case protocolViolation = "Protocol violation"
}
