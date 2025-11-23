import Foundation

/// Compact Block Scanner for Zclassic (ZIP-307)
/// Uses trial decryption to find shielded transactions - preserves privacy
final class FilterScanner {

    private let networkManager: NetworkManager
    private let database: WalletDatabase
    private let rustBridge: RustBridge
    private let insightAPI: InsightAPI

    // Scanning parameters
    private let batchSize = 500 // Larger batches for faster sync
    private var isScanning = false
    private var scanTask: Task<Void, Never>?

    // Progress callback - (progress, currentHeight, maxHeight)
    var onProgress: ((Double, UInt64, UInt64) -> Void)?

    // Current chain height (updated during scan)
    private(set) var currentChainHeight: UInt64 = 0

    // Tracked notes and nullifiers
    private var knownNullifiers: Set<Data> = []

    init(networkManager: NetworkManager = .shared,
         database: WalletDatabase = .shared,
         rustBridge: RustBridge = .shared,
         insightAPI: InsightAPI = .shared) {
        self.networkManager = networkManager
        self.database = database
        self.rustBridge = rustBridge
        self.insightAPI = insightAPI
    }

    // MARK: - Scanning

    /// Start scanning for transactions
    func startScan(for accountId: Int64, viewingKey: Data) async throws {
        guard !isScanning else {
            return
        }

        isScanning = true
        defer { isScanning = false }

        // Get current chain height
        print("📡 Getting chain height...")
        guard let latestHeight = try? await getChainHeight() else {
            print("❌ Failed to get chain height")
            throw ScanError.networkError
        }
        currentChainHeight = latestHeight
        print("📊 Chain height: \(latestHeight)")

        // Get last scanned height
        let lastScanned = try database.getLastScannedHeight()

        // For new wallets (lastScanned = 0), start from recent checkpoint for faster sync
        // Existing wallets continue from where they left off
        let startHeight: UInt64
        if lastScanned == 0 {
            // New wallet - start from recent checkpoint (won't see old transactions)
            startHeight = ZclassicCheckpoints.recentCheckpointHeight
            print("🆕 New wallet - starting from recent checkpoint \(startHeight)")
        } else {
            // Existing wallet - continue from last scanned
            startHeight = max(lastScanned + 1, ZclassicCheckpoints.saplingActivationHeight)
        }
        print("🔍 Scanning from \(startHeight) to \(latestHeight)")

        guard startHeight <= latestHeight else {
            // Already fully synced
            print("✅ Already synced")
            return
        }

        // Calculate total blocks to scan
        let totalBlocks = latestHeight - startHeight + 1
        var scannedBlocks: UInt64 = 0

        // Keep spending key for direct decryption (uses zcash_primitives internally)
        let spendingKey = viewingKey
        print("🔑 Using spending key: \(spendingKey.count) bytes")

        // Also derive IVK for nullifier computation
        let ivk = deriveIncomingViewingKey(from: viewingKey)
        let ivkHex = ivk.map { String(format: "%02x", $0) }.joined()
        print("🔑 Derived IVK: \(ivk.count) bytes")
        print("🔑 IVK hex: \(ivkHex)")

        // Debug: Also print the z-address we're scanning for
        let walletAddress = WalletManager.shared.zAddress
        print("🏠 Scanning for address: \(walletAddress)")

        // Decode address to see its diversifier
        if let addrBytes = ZipherXFFI.decodeAddress(walletAddress) {
            let divBytes = Array(addrBytes.prefix(11))
            let divHex = divBytes.map { String(format: "%02x", $0) }.joined()
            print("🏠 Address diversifier: \(divHex)")
        }

        // Load known nullifiers from database for spend detection
        knownNullifiers = try database.getAllNullifiers()

        // Scan in batches using Insight API raw blocks (parallel fetching)
        var currentHeight = startHeight
        let parallelFetches = 50 // Fetch 50 blocks in parallel for speed

        while currentHeight <= latestHeight && isScanning {
            let endHeight = min(currentHeight + UInt64(batchSize) - 1, latestHeight)

            // Download blocks via Insight API in parallel batches
            print("📦 Downloading blocks \(currentHeight) to \(endHeight) via Insight API...")

            // Process in parallel chunks
            var height = currentHeight
            while height <= endHeight && isScanning {
                let chunkEnd = min(height + UInt64(parallelFetches) - 1, endHeight)
                let count = Int(chunkEnd - height + 1)

                // Fetch blocks in parallel for speed
                await withTaskGroup(of: Void.self) { group in
                    for i in 0..<count {
                        let h = height + UInt64(i)
                        group.addTask {
                            do {
                                // Get block info to find transactions
                                let blockHash = try await self.insightAPI.getBlockHash(height: h)
                                let block = try await self.insightAPI.getBlock(hash: blockHash)

                                // Check each transaction for shielded outputs
                                for txid in block.tx {
                                    let tx = try await self.insightAPI.getTransaction(txid: txid)

                                    // Debug: log ALL transactions in recent blocks
                                    if h >= 2918699 {
                                        print("🔍 Block \(h) tx \(txid) - spends:\(tx.vShieldedSpend?.count ?? -1) outputs:\(tx.vShieldedOutput?.count ?? -1)")
                                    }

                                    // Process shielded outputs if any
                                    if let outputs = tx.vShieldedOutput, !outputs.isEmpty {
                                        let spendCount = tx.vShieldedSpend?.count ?? 0
                                        print("🔍 Block \(h) tx \(txid): \(spendCount) spends, \(outputs.count) outputs")
                                        try await self.processShieldedOutputs(
                                            outputs: outputs,
                                            txid: txid,
                                            accountId: accountId,
                                            spendingKey: spendingKey,
                                            ivk: ivk,
                                            height: h
                                        )
                                    }
                                }
                            } catch {
                                // Silently continue on error
                            }
                        }
                    }
                }

                scannedBlocks += UInt64(count)
                let progress = Double(scannedBlocks) / Double(totalBlocks)
                onProgress?(progress, chunkEnd, latestHeight)

                height = chunkEnd + 1
            }

            // Save progress
            try? database.updateLastScannedHeight(endHeight, hash: Data(count: 32))
            print("📦 Processed blocks \(currentHeight) to \(endHeight)")

            currentHeight = endHeight + 1
        }

        print("✅ Scan complete")
    }

    /// Parse raw block data into CompactBlock format
    private func parseRawBlock(_ data: Data, height: UInt64, hash: String) -> CompactBlock? {
        guard data.count >= 140 else {
            print("⚠️ Block \(height) too small: \(data.count) bytes")
            return nil
        }

        // For blocks with transactions, skip parsing for now to avoid crashes
        // We need to fix the parser - for now only parse coinbase-only blocks (653 bytes)
        if data.count > 700 {
            print("  → Block \(height) skipped (has transactions)")
            return CompactBlock(
                blockHeight: height,
                blockHash: Data(hexString: hash) ?? Data(count: 32),
                prevHash: Data(count: 32),
                time: 0,
                transactions: []
            )
        }

        var offset = 0

        // Block header (Zcash/Zclassic uses extended header)
        // Version (4) + prevHash (32) + merkleRoot (32) + reserved (32) + time (4) + bits (4) + nonce (32) = 140 bytes
        // Then Equihash solution (variable)

        let version = data.loadUInt32(at: offset)
        offset += 4

        let prevHash = Data(data[offset..<offset+32])
        offset += 32

        let merkleRoot = Data(data[offset..<offset+32])
        offset += 32

        // Skip reserved hash
        offset += 32

        let time = data.loadUInt32(at: offset)
        offset += 4

        let bits = data.loadUInt32(at: offset)
        offset += 4

        let nonce = Data(data[offset..<offset+32])
        offset += 32

        // Skip Equihash solution (variable length with compact size prefix)
        if offset < data.count {
            let solutionSize = readCompactSize(data, offset: &offset)
            guard solutionSize >= 0 && solutionSize < data.count else {
                print("⚠️ Block \(height) invalid solution size: \(solutionSize)")
                return nil
            }
            offset += solutionSize
        }

        // Parse transactions
        var transactions: [CompactTx] = []

        guard offset < data.count else {
            return CompactBlock(
                blockHeight: height,
                blockHash: Data(hexString: hash) ?? Data(count: 32),
                prevHash: prevHash,
                time: time,
                transactions: []
            )
        }

        // Transaction count
        let txCount = readCompactSize(data, offset: &offset)

        // Sanity check tx count
        guard txCount >= 0 && txCount < 10000 else {
            print("⚠️ Block \(height) invalid tx count: \(txCount)")
            return nil
        }

        for txIndex in 0..<txCount {
            guard offset < data.count else { break }

            // Parse transaction
            let (tx, newOffset) = parseTransaction(data, offset: offset, txIndex: txIndex)
            offset = newOffset

            if let tx = tx {
                transactions.append(tx)
            }
        }

        let totalOutputs = transactions.reduce(0) { $0 + $1.outputs.count }
        if totalOutputs > 0 {
            print("🔍 Block \(height): \(transactions.count) txs, \(totalOutputs) Sapling outputs")
        }

        return CompactBlock(
            blockHeight: height,
            blockHash: Data(hexString: hash) ?? Data(count: 32),
            prevHash: prevHash,
            time: time,
            transactions: transactions
        )
    }

    /// Read compact size (variable int)
    private func readCompactSize(_ data: Data, offset: inout Int) -> Int {
        guard offset < data.count else { return 0 }

        let first = data[offset]
        offset += 1

        if first < 253 {
            return Int(first)
        } else if first == 253 {
            guard offset + 2 <= data.count else { return 0 }
            let value = data.loadUInt16(at: offset)
            offset += 2
            return Int(value)
        } else if first == 254 {
            guard offset + 4 <= data.count else { return 0 }
            let value = data.loadUInt32(at: offset)
            offset += 4
            return Int(value)
        } else {
            guard offset + 8 <= data.count else { return 0 }
            let value = data.loadUInt64(at: offset)
            offset += 8
            return Int(clamping: value)
        }
    }

    /// Parse a single transaction from raw data
    private func parseTransaction(_ data: Data, offset: Int, txIndex: Int) -> (CompactTx?, Int) {
        var currentOffset = offset

        guard currentOffset + 4 <= data.count else {
            return (nil, data.count)
        }

        // Read version with overwintered flag
        let header = data.loadUInt32(at: currentOffset)
        currentOffset += 4

        let isOverwintered = (header >> 31) != 0
        let version = header & 0x7FFFFFFF

        // Version group ID for Sapling
        if isOverwintered {
            guard currentOffset + 4 <= data.count else { return (nil, data.count) }
            currentOffset += 4 // versionGroupId
        }

        // Transparent inputs
        let vinCount = readCompactSize(data, offset: &currentOffset)
        guard vinCount >= 0 && vinCount < 10000 else { return (nil, data.count) }
        for _ in 0..<vinCount {
            guard currentOffset + 36 <= data.count else { return (nil, data.count) }
            currentOffset += 36 // prevout (32 hash + 4 index)

            let scriptLen = readCompactSize(data, offset: &currentOffset)
            guard scriptLen >= 0 && currentOffset + scriptLen <= data.count else { return (nil, data.count) }
            currentOffset += scriptLen // scriptSig

            guard currentOffset + 4 <= data.count else { return (nil, data.count) }
            currentOffset += 4 // sequence
        }

        // Transparent outputs
        let voutCount = readCompactSize(data, offset: &currentOffset)
        guard voutCount >= 0 && voutCount < 10000 else { return (nil, data.count) }
        for _ in 0..<voutCount {
            guard currentOffset + 8 <= data.count else { return (nil, data.count) }
            currentOffset += 8 // value

            let scriptLen = readCompactSize(data, offset: &currentOffset)
            guard scriptLen >= 0 && currentOffset + scriptLen <= data.count else { return (nil, data.count) }
            currentOffset += scriptLen // scriptPubKey
        }

        // Lock time
        guard currentOffset + 4 <= data.count else { return (nil, data.count) }
        currentOffset += 4

        // Sapling fields (version >= 4)
        var spends: [CompactSpend] = []
        var outputs: [CompactOutput] = []

        if version >= 4 && isOverwintered {
            // Expiry height
            guard currentOffset + 4 <= data.count else { return (nil, data.count) }
            currentOffset += 4

            // Value balance (int64)
            guard currentOffset + 8 <= data.count else { return (nil, data.count) }
            currentOffset += 8

            // Sapling spends
            let spendCount = readCompactSize(data, offset: &currentOffset)
            guard spendCount >= 0 && spendCount < 1000 else { return (nil, data.count) }
            for _ in 0..<spendCount {
                // cv (32) + anchor (32) + nullifier (32) + rk (32) + zkproof (192) + spendAuthSig (64) = 384
                guard currentOffset + 384 <= data.count else { break }

                currentOffset += 32 // cv
                currentOffset += 32 // anchor

                let nullifier = Data(data[currentOffset..<currentOffset+32])
                currentOffset += 32

                spends.append(CompactSpend(nullifier: nullifier))

                currentOffset += 32 // rk
                currentOffset += 192 // zkproof
                currentOffset += 64 // spendAuthSig
            }

            // Sapling outputs
            let outputCount = readCompactSize(data, offset: &currentOffset)
            guard outputCount >= 0 && outputCount < 1000 else { return (nil, data.count) }
            for _ in 0..<outputCount {
                // cv (32) + cmu (32) + ephemeralKey (32) + encCiphertext (580) + outCiphertext (80) + zkproof (192) = 948
                guard currentOffset + 948 <= data.count else { break }

                currentOffset += 32 // cv

                let cmu = Data(data[currentOffset..<currentOffset+32])
                currentOffset += 32

                let epk = Data(data[currentOffset..<currentOffset+32])
                currentOffset += 32

                let ciphertext = Data(data[currentOffset..<currentOffset+580])
                currentOffset += 580

                outputs.append(CompactOutput(cmu: cmu, epk: epk, ciphertext: ciphertext))

                currentOffset += 80 // outCiphertext
                currentOffset += 192 // zkproof
            }

            // Binding sig if there are spends or outputs
            if spendCount > 0 || outputCount > 0 {
                guard currentOffset + 64 <= data.count else { return (nil, data.count) }
                currentOffset += 64
            }
        }

        // Compute txid (double SHA256 of raw tx)
        let txData = data[offset..<currentOffset]
        let txHash = Data(txData).doubleSHA256()

        let tx = CompactTx(
            txIndex: UInt64(txIndex),
            txHash: Data(txHash.reversed()), // Reverse for display
            spends: spends,
            outputs: outputs
        )

        return (tx, currentOffset)
    }

    /// Process a ZIP-307 compact block using trial decryption
    private func processCompactBlock(_ block: CompactBlock, accountId: Int64, ivk: Data, height: UInt64) async throws {
        // Check for spent notes (nullifier detection)
        for tx in block.transactions {
            for spend in tx.spends {
                if knownNullifiers.contains(spend.nullifier) {
                    // One of our notes was spent!
                    try database.markNoteSpent(nullifier: spend.nullifier, spentHeight: height)
                    print("💸 Note spent at height \(height)")
                }
            }
        }

        // Count total outputs in this block
        var totalOutputs = 0
        for tx in block.transactions {
            totalOutputs += tx.outputs.count
        }

        if totalOutputs > 0 {
            print("🔍 Block \(height): \(block.transactions.count) txs, \(totalOutputs) shielded outputs to check")
        }

        // Trial-decrypt each output to find notes for us
        for tx in block.transactions {
            for (outputIndex, output) in tx.outputs.enumerated() {
                // Try to decrypt with our incoming viewing key
                if let note = tryDecryptOutput(output, ivk: ivk) {
                    print("🔓 Successfully decrypted note at height \(height)!")
                    // We found a note addressed to us!
                    try await processDecryptedNote(
                        note: note,
                        output: output,
                        txid: tx.txHash,
                        outputIndex: UInt32(outputIndex),
                        accountId: accountId,
                        height: height,
                        ivk: ivk
                    )
                }
            }
        }
    }

    /// Trial-decrypt a single output with our viewing key
    private func tryDecryptOutput(_ output: CompactOutput, ivk: Data) -> DecryptedNote? {
        // Use RustBridge for Sapling trial decryption
        return rustBridge.tryDecryptNote(
            ivk: ivk,
            ephemeralKey: output.epk,
            cmu: output.cmu,
            encCiphertext: output.ciphertext
        )
    }

    /// Stop scanning
    func stopScan() {
        isScanning = false
        scanTask?.cancel()
    }

    /// Process shielded outputs from Insight API transaction
    private func processShieldedOutputs(
        outputs: [ShieldedOutput],
        txid: String,
        accountId: Int64,
        spendingKey: Data,
        ivk: Data,
        height: UInt64
    ) async throws {
        for (index, output) in outputs.enumerated() {
            // Convert hex strings to binary data
            // IMPORTANT: EPK and CMU from JSON are in display format (big-endian)
            // but librustzcash expects wire format (little-endian), so we reverse bytes
            guard let cmuDisplay = Data(hexString: output.cmu),
                  let epkDisplay = Data(hexString: output.ephemeralKey),
                  let encCiphertext = Data(hexString: output.encCiphertext) else {
                print("⚠️ Failed to parse output \(index) hex data")
                continue
            }

            // Reverse byte order: display format (big-endian) -> wire format (little-endian)
            let epk = epkDisplay.reversedBytes()
            let cmu = cmuDisplay.reversedBytes()

            // Debug: print sizes
            if height >= 2918699 {
                print("📊 Output \(index): cmu=\(cmu.count)B epk=\(epk.count)B enc=\(encCiphertext.count)B sk=\(spendingKey.count)B")
            }

            // Try to decrypt with spending key (uses zcash_primitives internally for IVK derivation)
            guard let decryptedData = ZipherXFFI.tryDecryptNoteWithSK(
                spendingKey: spendingKey,
                epk: epk,
                cmu: cmu,
                ciphertext: encCiphertext
            ) else {
                // Not addressed to us
                print("🔒 Note \(index) not for us (decryption failed)")
                continue
            }
            print("🔓 Successfully decrypted note \(index)!")

            // Parse decrypted note data: diversifier(11) + value(8) + rcm(32) + memo(512)
            guard decryptedData.count >= 51 else {
                print("⚠️ Decrypted data too short: \(decryptedData.count)")
                continue
            }

            let diversifier = decryptedData.prefix(11)
            let valueBytes = Data(decryptedData[11..<19])
            let value = valueBytes.withUnsafeBytes { $0.load(as: UInt64.self) }
            let rcm = decryptedData[19..<51]
            let memo = decryptedData.count >= 563 ? decryptedData[51..<563] : Data()

            let note = DecryptedNote(
                diversifier: Data(diversifier),
                value: value,
                rcm: Data(rcm),
                memo: Data(memo)
            )

            // We found a note addressed to us!
            print("💰 Found note: \(value) zatoshis at height \(height)")

            // Send notification for received ZCL
            NotificationManager.shared.notifyReceived(amount: value, txid: txid)

            let txidData = Data(hexString: txid) ?? Data()

            // Calculate position in commitment tree
            let position = height * 1000 + UInt64(index)

            // Compute nullifier for this note
            let nullifier = try rustBridge.computeNullifier(
                ivk: ivk,
                diversifier: note.diversifier,
                value: note.value,
                rcm: note.rcm,
                position: position
            )

            // Track this nullifier for spend detection
            knownNullifiers.insert(nullifier)

            // Get witness for the note commitment
            let witness = try await getWitness(for: cmu, at: height)

            // Store note in database
            _ = try database.insertNote(
                accountId: accountId,
                diversifier: note.diversifier,
                value: note.value,
                rcm: note.rcm,
                memo: note.memo,
                nullifier: nullifier,
                txid: txidData,
                height: height,
                witness: witness
            )

            print("💰 Found note: \(note.value) zatoshis at height \(height)")
        }
    }


    /// Process a successfully decrypted note
    private func processDecryptedNote(
        note: DecryptedNote,
        output: CompactOutput,
        txid: Data,
        outputIndex: UInt32,
        accountId: Int64,
        height: UInt64,
        ivk: Data
    ) async throws {
        // Calculate position in commitment tree (simplified)
        let position = height * 1000 + UInt64(outputIndex)

        // Compute nullifier for this note
        let nullifier = try rustBridge.computeNullifier(
            ivk: ivk,
            diversifier: note.diversifier,
            value: note.value,
            rcm: note.rcm,
            position: position
        )

        // Track this nullifier for spend detection
        knownNullifiers.insert(nullifier)

        // Get witness for the note commitment
        let witness = try await getWitness(for: output.cmu, at: height)

        // Store note in database
        _ = try database.insertNote(
            accountId: accountId,
            diversifier: note.diversifier,
            value: note.value,
            rcm: note.rcm,
            memo: note.memo,
            nullifier: nullifier,
            txid: txid,
            height: height,
            witness: witness
        )

        print("💰 Found note: \(note.value) zatoshis at height \(height)")
    }

    // MARK: - Helper Methods

    private func getChainHeight() async throws -> UInt64 {
        // Query current chain height from Insight API (more reliable)
        let status = try await insightAPI.getStatus()
        return status.height
    }

    private func deriveIncomingViewingKey(from viewingKey: Data) -> Data {
        // The viewingKey passed in is actually the full viewing key data
        // We need to derive the IVK properly using the FFI
        // If viewingKey is 169 bytes, it's the spending key - derive IVK from it
        if viewingKey.count == 169 {
            if let ivk = ZipherXFFI.deriveIVK(from: viewingKey) {
                return ivk
            }
        }
        // Fallback: extract first 32 bytes (this may not work correctly)
        return Data(viewingKey.prefix(32))
    }

    private func getWitness(for cmu: Data, at height: UInt64) async throws -> Data {
        // Get Merkle witness for note commitment
        // This is needed for spending the note
        return Data(count: 1065) // Placeholder witness size
    }
}

// MARK: - ZIP-307 Compact Block Types

/// Compact block containing only shielded transaction data
struct CompactBlock: Hashable {
    let blockHeight: UInt64
    let blockHash: Data
    let prevHash: Data
    let time: UInt32
    let transactions: [CompactTx]
}

/// Compact transaction with spends and outputs
struct CompactTx: Hashable {
    let txIndex: UInt64
    let txHash: Data
    let spends: [CompactSpend]
    let outputs: [CompactOutput]
}

/// Nullifier for spend detection
struct CompactSpend: Hashable {
    let nullifier: Data  // 32 bytes
}

/// Encrypted output for trial decryption
struct CompactOutput: Hashable {
    let cmu: Data        // Note commitment (32 bytes)
    let epk: Data        // Ephemeral public key (32 bytes)
    let ciphertext: Data // Encrypted note plaintext (~580 bytes)
}


// MARK: - Errors

enum ScanError: LocalizedError {
    case networkError
    case decodingError
    case databaseError

    var errorDescription: String? {
        switch self {
        case .networkError:
            return "Network error during scan"
        case .decodingError:
            return "Failed to decode filter or block"
        case .databaseError:
            return "Database error during scan"
        }
    }
}

