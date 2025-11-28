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
                // Set correct height and preserve finalSaplingRoot
                block = CompactBlock(
                    blockHeight: height + UInt64(index),
                    blockHash: hash,
                    prevHash: block.prevHash,
                    finalSaplingRoot: block.finalSaplingRoot,
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
    /// Zcash/Zclassic uses 140-byte headers (not 80 like Bitcoin!)
    /// Format: version(4) + prevHash(32) + merkleRoot(32) + finalSaplingRoot(32) + time(4) + bits(4) + nonce(32)
    private func parseCompactBlock(_ data: Data) -> CompactBlock? {
        // Zcash/Zclassic block format:
        // - Header (140 bytes): version(4) + prevHash(32) + merkleRoot(32) + finalSaplingRoot(32) + time(4) + bits(4) + nonce(32)
        // - Equihash solution (compactSize + solution)
        // - Transaction count (compactSize)
        // - Transactions
        guard data.count >= 140 else { return nil }

        var offset = 0

        // Version (4 bytes)
        offset += 4

        // Previous block hash (32 bytes)
        let prevHash = Data(data[offset..<offset+32])
        offset += 32

        // Merkle root (32 bytes)
        offset += 32

        // *** CRITICAL: Final Sapling Root (32 bytes) - THIS IS THE ANCHOR! ***
        let finalSaplingRoot = Data(data[offset..<offset+32])
        offset += 32

        // Time (4 bytes)
        let time = data.loadUInt32(at: offset)
        offset += 4

        // Bits (4 bytes)
        offset += 4

        // Nonce (32 bytes for Equihash)
        offset += 32

        // Now at end of 140-byte header
        // Equihash solution follows: compactSize + solution data
        let (solutionSize, solutionSizeBytes) = readCompactSize(data, at: offset)
        offset += solutionSizeBytes
        offset += Int(solutionSize) // Skip solution data

        // Compute block hash from header + solution
        let headerAndSolution = data.prefix(offset)
        let blockHash = headerAndSolution.doubleSHA256()

        // Parse transactions
        var transactions: [CompactTx] = []

        guard offset < data.count else {
            return CompactBlock(blockHeight: 0, blockHash: blockHash, prevHash: prevHash,
                                finalSaplingRoot: finalSaplingRoot, time: time, transactions: [])
        }

        // Read transaction count (compactSize)
        let (txCount, txCountBytes) = readCompactSize(data, at: offset)
        offset += txCountBytes

        for txIndex in 0..<Int(txCount) {
            guard offset < data.count else { break }

            // Parse full Zcash v4 transaction
            let (txHash, spends, outputs, newOffset) = parseZcashTransaction(data, offset: offset)
            offset = newOffset

            // Only add if we successfully parsed something
            if !spends.isEmpty || !outputs.isEmpty || txHash != Data(repeating: 0, count: 32) {
                transactions.append(CompactTx(
                    txIndex: UInt64(txIndex),
                    txHash: txHash,
                    spends: spends,
                    outputs: outputs
                ))
            }
        }

        return CompactBlock(
            blockHeight: 0,
            blockHash: blockHash,
            prevHash: prevHash,
            finalSaplingRoot: finalSaplingRoot,
            time: time,
            transactions: transactions
        )
    }

    /// Read a Bitcoin-style compactSize varint
    private func readCompactSize(_ data: Data, at offset: Int) -> (UInt64, Int) {
        guard offset < data.count else { return (0, 0) }

        let first = data[offset]
        if first < 253 {
            return (UInt64(first), 1)
        } else if first == 253 {
            guard offset + 2 < data.count else { return (0, 1) }
            return (UInt64(data.loadUInt16(at: offset + 1)), 3)
        } else if first == 254 {
            guard offset + 4 < data.count else { return (0, 1) }
            return (UInt64(data.loadUInt32(at: offset + 1)), 5)
        } else {
            guard offset + 8 < data.count else { return (0, 1) }
            return (data.loadUInt64(at: offset + 1), 9)
        }
    }

    /// Parse a Zcash v4 (Sapling) transaction
    /// Returns: (txHash, spends, outputs, newOffset)
    private func parseZcashTransaction(_ data: Data, offset: Int) -> (Data, [CompactSpend], [CompactOutput], Int) {
        var pos = offset
        let txStart = offset
        var spends: [CompactSpend] = []
        var outputs: [CompactOutput] = []

        guard pos + 4 <= data.count else {
            return (Data(repeating: 0, count: 32), [], [], pos)
        }

        // Header (4 bytes): version and fOverwintered flag
        let header = data.loadUInt32(at: pos)
        let version = header & 0x7FFFFFFF
        let fOverwintered = (header & 0x80000000) != 0
        pos += 4

        // Check for Sapling transaction (v4 with overwintered)
        guard fOverwintered && version >= 4 else {
            // Not a Sapling transaction - skip it entirely
            // For older versions, we can't reliably parse, so skip
            return (Data(repeating: 0, count: 32), [], [], skipLegacyTransaction(data, offset: offset))
        }

        // nVersionGroupId (4 bytes)
        guard pos + 4 <= data.count else { return (Data(repeating: 0, count: 32), [], [], pos) }
        pos += 4

        // vin (transparent inputs)
        let (vinCount, vinBytes) = readCompactSize(data, at: pos)
        pos += vinBytes
        for _ in 0..<vinCount {
            pos = skipTransparentInput(data, offset: pos)
        }

        // vout (transparent outputs)
        let (voutCount, voutBytes) = readCompactSize(data, at: pos)
        pos += voutBytes
        for _ in 0..<voutCount {
            pos = skipTransparentOutput(data, offset: pos)
        }

        // nLockTime (4 bytes)
        guard pos + 4 <= data.count else { return (Data(repeating: 0, count: 32), [], [], pos) }
        pos += 4

        // nExpiryHeight (4 bytes)
        guard pos + 4 <= data.count else { return (Data(repeating: 0, count: 32), [], [], pos) }
        pos += 4

        // valueBalance (8 bytes)
        guard pos + 8 <= data.count else { return (Data(repeating: 0, count: 32), [], [], pos) }
        pos += 8

        // vShieldedSpend
        let (spendCount, spendBytes) = readCompactSize(data, at: pos)
        pos += spendBytes

        for _ in 0..<spendCount {
            // SpendDescription: cv(32) + anchor(32) + nullifier(32) + rk(32) + zkproof(192) + spendAuthSig(64)
            // Total: 384 bytes
            guard pos + 384 <= data.count else { break }

            // cv (32 bytes) - skip
            pos += 32

            // anchor (32 bytes) - skip
            pos += 32

            // nullifier (32 bytes) - EXTRACT THIS
            let nullifier = Data(data[pos..<pos+32])
            pos += 32
            spends.append(CompactSpend(nullifier: nullifier))

            // rk (32 bytes) - skip
            pos += 32

            // zkproof (192 bytes) - skip
            pos += 192

            // spendAuthSig (64 bytes) - skip
            pos += 64
        }

        // vShieldedOutput
        let (outputCount, outputBytes) = readCompactSize(data, at: pos)
        pos += outputBytes

        for _ in 0..<outputCount {
            // OutputDescription: cv(32) + cmu(32) + ephemeralKey(32) + encCiphertext(580) + outCiphertext(80) + zkproof(192)
            // Total: 948 bytes
            guard pos + 948 <= data.count else { break }

            // cv (32 bytes) - skip
            pos += 32

            // cmu (32 bytes) - EXTRACT THIS
            let cmu = Data(data[pos..<pos+32])
            pos += 32

            // ephemeralKey (32 bytes) - EXTRACT THIS
            let epk = Data(data[pos..<pos+32])
            pos += 32

            // encCiphertext (580 bytes) - EXTRACT THIS
            let ciphertext = Data(data[pos..<pos+580])
            pos += 580

            outputs.append(CompactOutput(cmu: cmu, epk: epk, ciphertext: ciphertext))

            // outCiphertext (80 bytes) - skip
            pos += 80

            // zkproof (192 bytes) - skip
            pos += 192
        }

        // JoinSplits (usually empty for Sapling era)
        let (jsCount, jsBytes) = readCompactSize(data, at: pos)
        pos += jsBytes
        if jsCount > 0 {
            // Skip JoinSplit data (each is 1698 bytes + 64 byte sig if any)
            pos += Int(jsCount) * 1698
            if jsCount > 0 {
                pos += 64 // joinsplitSig
            }
        }

        // Binding signature (64 bytes) - only if spends or outputs exist
        if spendCount > 0 || outputCount > 0 {
            pos += 64
        }

        // Compute txHash (double SHA256 of the raw transaction)
        let txEnd = pos
        guard txEnd > txStart && txEnd <= data.count else {
            return (Data(repeating: 0, count: 32), spends, outputs, pos)
        }
        let txData = data[txStart..<txEnd]
        let txHash = Data(txData).doubleSHA256()

        return (txHash, spends, outputs, pos)
    }

    /// Skip a legacy (pre-Sapling) transaction
    private func skipLegacyTransaction(_ data: Data, offset: Int) -> Int {
        var pos = offset

        // Version (4 bytes)
        pos += 4

        // For non-overwintered, standard Bitcoin-like format
        // vin
        let (vinCount, vinBytes) = readCompactSize(data, at: pos)
        pos += vinBytes
        for _ in 0..<vinCount {
            pos = skipTransparentInput(data, offset: pos)
        }

        // vout
        let (voutCount, voutBytes) = readCompactSize(data, at: pos)
        pos += voutBytes
        for _ in 0..<voutCount {
            pos = skipTransparentOutput(data, offset: pos)
        }

        // nLockTime (4 bytes)
        pos += 4

        return pos
    }

    /// Skip a transparent input
    private func skipTransparentInput(_ data: Data, offset: Int) -> Int {
        var pos = offset

        // prevout: txid (32) + vout index (4)
        pos += 36

        // scriptSig length + scriptSig
        let (scriptLen, scriptBytes) = readCompactSize(data, at: pos)
        pos += scriptBytes
        pos += Int(scriptLen)

        // sequence (4 bytes)
        pos += 4

        return pos
    }

    /// Skip a transparent output
    private func skipTransparentOutput(_ data: Data, offset: Int) -> Int {
        var pos = offset

        // value (8 bytes)
        pos += 8

        // scriptPubKey length + scriptPubKey
        let (scriptLen, scriptBytes) = readCompactSize(data, at: pos)
        pos += scriptBytes
        pos += Int(scriptLen)

        return pos
    }

    // MARK: - Helpers

    private func buildAddressPayload(_ address: String) -> Data {
        var payload = Data()
        let addressData = address.data(using: .utf8)!
        payload.append(UInt8(addressData.count))
        payload.append(addressData)
        return payload
    }

    // MARK: - Block/Transaction P2P Methods

    /// Get a single block by its hash via P2P getdata
    func getBlockByHash(hash: Data) async throws -> CompactBlock {
        guard hash.count == 32 else {
            throw PeerError.invalidData
        }

        // Build getdata message for single block
        var payload = Data()
        payload.append(1) // count = 1
        payload.append(contentsOf: withUnsafeBytes(of: UInt32(2).littleEndian) { Array($0) }) // MSG_BLOCK = 2
        payload.append(hash)

        try await sendMessage(command: "getdata", payload: payload)

        // Wait for block response with timeout
        // Peers may send ping, inv, addr messages - we need to handle them
        var attempts = 0
        let maxAttempts = 30 // Increased from 10 - blocks can be large and slow
        while attempts < maxAttempts {
            attempts += 1

            // Add timeout for each receive attempt
            do {
                let result = try await withThrowingTaskGroup(of: (String, Data).self) { group in
                    group.addTask {
                        try await self.receiveMessage()
                    }
                    group.addTask {
                        try await Task.sleep(nanoseconds: 5_000_000_000) // 5 second timeout per message
                        throw PeerError.timeout
                    }

                    let result = try await group.next()!
                    group.cancelAll()
                    return result
                }

                let (command, response) = result

                if command == "block" {
                    if let block = parseCompactBlock(response) {
                        return block
                    }
                    throw PeerError.invalidData
                } else if command == "notfound" {
                    // Peer doesn't have this block
                    throw PeerError.invalidData
                } else if command == "ping" {
                    // Respond to ping with pong
                    try? await sendMessage(command: "pong", payload: response)
                }
                // Continue waiting for block message
            } catch is CancellationError {
                // Timeout on this attempt, continue to next
                continue
            } catch PeerError.timeout {
                // Timeout, continue to next attempt
                continue
            }
        }

        throw PeerError.timeout
    }

    /// Get a transaction by its hash via P2P getdata
    func getTransaction(hash: Data) async throws -> Data {
        guard hash.count == 32 else {
            throw PeerError.invalidData
        }

        // Build getdata message for single transaction
        var payload = Data()
        payload.append(1) // count = 1
        payload.append(contentsOf: withUnsafeBytes(of: UInt32(1).littleEndian) { Array($0) }) // MSG_TX = 1
        payload.append(hash)

        try await sendMessage(command: "getdata", payload: payload)

        // Wait for tx response
        var attempts = 0
        while attempts < 10 {
            attempts += 1
            let (command, response) = try await receiveMessage()

            if command == "tx" {
                return response
            }
            // Ignore other messages
        }

        throw PeerError.timeout
    }
}

// MARK: - Peer Errors

enum PeerError: Error, LocalizedError {
    case invalidData
    case timeout
    case connectionClosed

    var errorDescription: String? {
        switch self {
        case .invalidData: return "Invalid data received from peer"
        case .timeout: return "Peer request timed out"
        case .connectionClosed: return "Peer connection closed"
        }
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
