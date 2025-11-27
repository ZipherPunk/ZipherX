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

    // Static lock to prevent concurrent scans across all instances
    private static var globalScanLock = false

    /// Check if any scan is currently in progress
    static var isScanInProgress: Bool {
        return globalScanLock
    }

    // Progress callback - (progress, currentHeight, maxHeight)
    var onProgress: ((Double, UInt64, UInt64) -> Void)?

    // Current chain height (updated during scan)
    private(set) var currentChainHeight: UInt64 = 0

    // Tracked notes and nullifiers
    private var knownNullifiers: Set<Data> = []

    // Commitment tree state
    private var treeInitialized = false
    private var pendingWitnesses: [(noteId: Int64, witnessIndex: UInt64)] = []
    private var existingWitnessIndices: [(noteId: Int64, witnessIndex: UInt64)] = []

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
    /// - Parameters:
    ///   - accountId: Account to scan for
    ///   - viewingKey: Spending key (used as viewing key)
    ///   - fromHeight: Optional custom start height (for quick scan)
    func startScan(for accountId: Int64, viewingKey: Data, fromHeight customStartHeight: UInt64? = nil) async throws {
        // Check both instance and global lock
        guard !isScanning && !FilterScanner.globalScanLock else {
            print("⚠️ Scan already in progress, skipping")
            return
        }

        isScanning = true
        FilterScanner.globalScanLock = true
        defer {
            isScanning = false
            FilterScanner.globalScanLock = false
        }

        // Get current chain height
        print("📡 Getting chain height...")
        guard let latestHeight = try? await getChainHeight() else {
            print("❌ Failed to get chain height")
            throw ScanError.networkError
        }
        currentChainHeight = latestHeight
        print("📊 Chain height: \(latestHeight)")

        // Determine start height
        var startHeight: UInt64

        // Height where bundled commitment tree ends (verified root matches chain)
        let bundledTreeHeight: UInt64 = 2923123

        // Track if we're scanning within bundled tree range (notes only, no tree building)
        var scanWithinBundledRange = false

        // If custom start height provided (quick scan), use it
        if let customStart = customStartHeight {
            startHeight = customStart
            // Check if this is within bundled tree range
            if startHeight <= bundledTreeHeight {
                scanWithinBundledRange = true
                print("🔍 Scan mode: starting from user-specified height \(startHeight) (within bundled tree range)")
            } else {
                print("🔍 Scan mode: starting from user-specified height \(startHeight)")
            }
        } else {
            // Normal scan - determine start height automatically
            // Get last scanned height
            let lastScanned = try database.getLastScannedHeight()

            // Check if we have tree state (database or bundled)
            let treeExists = (try? database.getTreeState()) != nil
            let bundledTreeAvailable = Bundle.main.url(forResource: "commitment_tree", withExtension: "bin") != nil

            if lastScanned > 0 {
                // Existing wallet - continue from last scanned
                startHeight = lastScanned + 1
                print("📊 Continuing from last scanned height \(lastScanned)")
            } else if treeExists {
                // Have database tree but no scan history - use recent checkpoint
                startHeight = ZclassicCheckpoints.recentCheckpointHeight
                print("🆕 New wallet with tree - starting from checkpoint \(startHeight)")
            } else if bundledTreeAvailable {
                // CRITICAL FIX: Fresh install with bundled tree
                // We need to scan the ENTIRE bundled range to find:
                // 1. Notes addressed to us (via trial decryption)
                // 2. Nullifiers that mark our notes as spent
                //
                // The bundled tree has all CMUs, but we haven't scanned for OUR notes yet!
                // Without this, imported keys will show old balance (spent notes appear unspent)
                //
                // Strategy: Use PHASE 1 (parallel note discovery) from Sapling activation
                // to bundledTreeHeight, then PHASE 2 from bundledTreeHeight+1 to current
                startHeight = ZclassicCheckpoints.saplingActivationHeight
                scanWithinBundledRange = true
                print("📦 Fresh install with bundled tree - scanning from Sapling activation \(startHeight)")
                print("   PHASE 1: Will scan \(startHeight) to \(bundledTreeHeight) for notes + nullifiers (parallel, no tree changes)")
                print("   PHASE 2: Will scan \(bundledTreeHeight + 1) to chain tip (sequential, tree building)")
            } else {
                // No tree anywhere - full scan from Sapling activation
                startHeight = ZclassicCheckpoints.saplingActivationHeight
                print("🔄 Full rescan - starting from Sapling activation \(startHeight)")
            }
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
        // SECURITY: Never log keys or IVK

        // Derive IVK for nullifier computation
        let ivk = deriveIncomingViewingKey(from: viewingKey)
        // SECURITY: IVK and address details not logged

        let walletAddress = WalletManager.shared.zAddress
        _ = ZipherXFFI.decodeAddress(walletAddress) // Decode for internal use only

        // Load known nullifiers from database for spend detection
        knownNullifiers = try database.getAllNullifiers()

        // Load existing note witnesses into FFI memory for updating
        // This is critical - witnesses become stale when new CMUs are added
        let existingNotes = try database.getUnspentNotes(accountId: accountId)
        existingWitnessIndices = []
        var notesWithoutWitnesses = 0
        for note in existingNotes {
            if note.witness.count >= 1028 {
                // Load witness into FFI - it will be updated as we append CMUs
                let witnessIndex = note.witness.withUnsafeBytes { ptr in
                    ZipherXFFI.treeLoadWitness(
                        witnessData: ptr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        witnessLen: note.witness.count
                    )
                }
                if witnessIndex != UInt64.max {
                    existingWitnessIndices.append((noteId: note.id, witnessIndex: witnessIndex))
                    print("📝 Loaded witness for existing note \(note.id)")
                }
            } else {
                // Note exists but has no witness (cleared during rebuild)
                // Its witness will be rebuilt when rediscovered during scan
                notesWithoutWitnesses += 1
                print("📝 Note \(note.id) has no witness, will be rebuilt during scan")
            }
        }
        if notesWithoutWitnesses > 0 {
            print("📝 Found \(notesWithoutWitnesses) existing notes without witnesses")
        }

        // Initialize commitment tree
        // Priority: 1) Database state, 2) Bundled tree, 3) Empty tree
        if let treeData = try? database.getTreeState() {
            if ZipherXFFI.treeDeserialize(data: treeData) {
                let treeSize = ZipherXFFI.treeSize()
                print("🌳 Restored commitment tree with \(treeSize) commitments")
                treeInitialized = true
            } else {
                print("⚠️ Failed to restore tree from database")
                treeInitialized = false
            }
        }

        // Try bundled CMUs if database tree failed or doesn't exist
        // CMUs allow us to build the tree properly and create valid witnesses
        if !treeInitialized {
            // First try complete tree (includes all outputs up to current), then fall back to partial tree
            let treeFileName = Bundle.main.url(forResource: "commitment_tree_complete", withExtension: "bin") != nil
                ? "commitment_tree_complete"
                : "commitment_tree"

            if let bundledCMUsURL = Bundle.main.url(forResource: treeFileName, withExtension: "bin"),
               let bundledData = try? Data(contentsOf: bundledCMUsURL) {
                print("🌳 Loading bundled CMUs (\(bundledData.count / 1024 / 1024) MB)...")

                // Initialize empty tree
                _ = ZipherXFFI.treeInit()

                // Parse CMUs file: [count: UInt64][cmu1: 32 bytes][cmu2: 32 bytes]...
                guard bundledData.count >= 8 else {
                    print("⚠️ Invalid bundled CMUs file")
                    treeInitialized = false
                    return
                }

                let count = bundledData.withUnsafeBytes { ptr -> UInt64 in
                    ptr.load(as: UInt64.self)
                }

                print("🌳 Building tree from \(count) bundled CMUs...")
                let buildStart = Date()

                // Append all CMUs to tree
                bundledData.withUnsafeBytes { ptr in
                    let basePtr = ptr.baseAddress!.advanced(by: 8)
                    for i in 0..<Int(count) {
                        let cmuPtr = basePtr.advanced(by: i * 32)
                        _ = ZipherXFFI.treeAppendRaw(cmu: cmuPtr.assumingMemoryBound(to: UInt8.self))
                    }
                }

                let buildTime = Date().timeIntervalSince(buildStart)
                let treeSize = ZipherXFFI.treeSize()
                print("🌳 Built commitment tree with \(treeSize) commitments in \(String(format: "%.1f", buildTime))s")

                // The bundled CMUs are from Sapling activation to current scanned height
                // commitment_tree_complete.bin includes ALL outputs from ALL transactions
                print("📦 Loaded complete commitment tree with ALL Sapling outputs")
                treeInitialized = true

                // Save tree state to database
                if let treeData = ZipherXFFI.treeSerialize() {
                    try? database.saveTreeState(treeData)
                }
            } else if let bundledTreeURL = Bundle.main.url(forResource: "sapling_tree", withExtension: "bin"),
               let bundledData = try? Data(contentsOf: bundledTreeURL) {
                // Fallback to serialized tree (less useful but faster to load)
                if ZipherXFFI.treeDeserialize(data: bundledData) {
                    let treeSize = ZipherXFFI.treeSize()
                    print("🌳 Loaded bundled tree with \(treeSize) commitments (frontier only)")
                    treeInitialized = true
                    try? database.saveTreeState(bundledData)
                }
            }
        }

        // Fall back to empty tree
        if !treeInitialized {
            treeInitialized = ZipherXFFI.treeInit()
            print("🌳 Initialized empty commitment tree")
        }

        guard treeInitialized else {
            print("❌ Failed to initialize commitment tree")
            throw ScanError.databaseError
        }

        // Clear pending witnesses for this scan
        pendingWitnesses = []

        // Determine scanning strategy:
        // - If scanning within bundled tree range: use PARALLEL mode (note discovery only)
        // - If scanning after bundled tree: use SEQUENTIAL mode (tree building + note discovery)
        var currentHeight = startHeight

        // PHASE 1: If we're scanning within bundled tree range, scan those blocks first (parallel/fast)
        if scanWithinBundledRange && startHeight <= bundledTreeHeight {
            print("⚡ PHASE 1: Scanning blocks \(startHeight) to \(bundledTreeHeight) for notes (parallel, no tree building)")

            let parallelEndHeight = min(bundledTreeHeight, latestHeight)
            let parallelTotalBlocks = parallelEndHeight - startHeight + 1
            var parallelScannedBlocks: UInt64 = 0
            let parallelBatchSize = 100

            while currentHeight <= parallelEndHeight && isScanning {
                let endHeight = min(currentHeight + UInt64(parallelBatchSize) - 1, parallelEndHeight)
                let heights = Array(currentHeight...endHeight)

                print("⚡ Parallel scanning blocks \(currentHeight) to \(endHeight)...")

                // Fetch all blocks in parallel - now also fetch spends for nullifier detection
                await withTaskGroup(of: (UInt64, [(String, [ShieldedOutput], [ShieldedSpend]?)]?).self) { group in
                    for height in heights {
                        group.addTask {
                            do {
                                let blockHash = try await self.insightAPI.getBlockHash(height: height)
                                let block = try await self.insightAPI.getBlock(hash: blockHash)

                                var txData: [(String, [ShieldedOutput], [ShieldedSpend]?)] = []
                                for txid in block.tx {
                                    let tx = try await self.insightAPI.getTransaction(txid: txid)
                                    // Fetch both outputs AND spends (for nullifier detection)
                                    let hasOutputs = tx.vShieldedOutput?.isEmpty == false
                                    let hasSpends = tx.vShieldedSpend?.isEmpty == false
                                    if hasOutputs || hasSpends {
                                        txData.append((txid, tx.vShieldedOutput ?? [], tx.vShieldedSpend))
                                    }
                                }
                                return (height, txData.isEmpty ? nil : txData)
                            } catch {
                                return (height, nil)
                            }
                        }
                    }

                    // Process results - for bundled range we skip tree building but DO find notes AND detect spent notes
                    for await (height, txData) in group {
                        guard isScanning else { break }

                        if let transactions = txData {
                            for (txid, shieldedOutputs, shieldedSpends) in transactions {
                                do {
                                    try await MainActor.run {
                                        // Use note-discovery-only mode (no tree append)
                                        // Now also passes spends for nullifier detection
                                        try self.processShieldedOutputsForNotesOnly(
                                            outputs: shieldedOutputs,
                                            spends: shieldedSpends,
                                            txid: txid,
                                            accountId: accountId,
                                            spendingKey: spendingKey,
                                            ivk: ivk,
                                            height: height
                                        )
                                    }
                                } catch {
                                    print("❌ Error processing tx \(txid): \(error)")
                                }
                            }
                        }

                        parallelScannedBlocks += 1
                        if parallelScannedBlocks % 50 == 0 || parallelScannedBlocks == parallelTotalBlocks {
                            let progress = Double(parallelScannedBlocks) / Double(parallelTotalBlocks)
                            onProgress?(progress * 0.5, height, latestHeight) // 50% for phase 1
                        }
                    }
                }

                // Save progress for bundled range scan
                try? database.updateLastScannedHeight(endHeight, hash: Data(count: 32))
                print("⚡ Parallel scanned \(currentHeight) to \(endHeight)")
                currentHeight = endHeight + 1
            }

            print("✅ PHASE 1 complete: scanned \(startHeight) to \(parallelEndHeight)")

            // Move to blocks after bundled tree
            currentHeight = bundledTreeHeight + 1
        }

        // PHASE 2: Continue scanning blocks after bundled tree (tree building mode)
        // This runs if:
        // - We did PHASE 1 and there are more blocks after bundledTreeHeight
        // - OR no custom start height was provided (normal auto-scan)
        let continueAfterBundledRange = scanWithinBundledRange && currentHeight <= latestHeight
        let isQuickScanOnly = customStartHeight != nil && !scanWithinBundledRange

        if continueAfterBundledRange {
            print("⚡ PHASE 2: Scanning blocks \(currentHeight) to \(latestHeight) for notes + tree building (sequential)")
        }

        if isQuickScanOnly {
            // PARALLEL MODE - much faster for note discovery only
            // Now also fetches spends for nullifier detection
            let parallelBatchSize = 100 // Process 100 blocks at a time in parallel

            while currentHeight <= latestHeight && isScanning {
                let endHeight = min(currentHeight + UInt64(parallelBatchSize) - 1, latestHeight)
                let heights = Array(currentHeight...endHeight)

                print("⚡ Parallel scanning blocks \(currentHeight) to \(endHeight)...")

                // Fetch all blocks in parallel - also fetch spends for nullifier detection
                await withTaskGroup(of: (UInt64, [(String, [ShieldedOutput], [ShieldedSpend]?)]?).self) { group in
                    for height in heights {
                        group.addTask {
                            do {
                                let blockHash = try await self.insightAPI.getBlockHash(height: height)
                                let block = try await self.insightAPI.getBlock(hash: blockHash)

                                var txData: [(String, [ShieldedOutput], [ShieldedSpend]?)] = []
                                for txid in block.tx {
                                    let tx = try await self.insightAPI.getTransaction(txid: txid)
                                    // Fetch both outputs AND spends (for nullifier detection)
                                    let hasOutputs = tx.vShieldedOutput?.isEmpty == false
                                    let hasSpends = tx.vShieldedSpend?.isEmpty == false
                                    if hasOutputs || hasSpends {
                                        txData.append((txid, tx.vShieldedOutput ?? [], tx.vShieldedSpend))
                                    }
                                }
                                return (height, txData.isEmpty ? nil : txData)
                            } catch {
                                return (height, nil)
                            }
                        }
                    }

                    // Process results - note: for quick scan we skip tree building but DO check nullifiers
                    for await (height, txData) in group {
                        guard isScanning else { break }

                        if let transactions = txData {
                            for (txid, shieldedOutputs, shieldedSpends) in transactions {
                                // Only try to decrypt for our notes, skip tree building
                                // Now also checks spends for nullifiers
                                do {
                                    try await MainActor.run {
                                        try self.processShieldedOutputsForNotesOnly(
                                            outputs: shieldedOutputs,
                                            spends: shieldedSpends,
                                            txid: txid,
                                            accountId: accountId,
                                            spendingKey: spendingKey,
                                            ivk: ivk,
                                            height: height
                                        )
                                    }
                                } catch {
                                    print("❌ Error processing tx \(txid): \(error)")
                                }
                            }
                        }

                        scannedBlocks += 1
                        if scannedBlocks % 50 == 0 || scannedBlocks == totalBlocks {
                            let progress = Double(scannedBlocks) / Double(totalBlocks)
                            onProgress?(progress, height, latestHeight)
                        }
                    }
                }

                // Save progress
                try? database.updateLastScannedHeight(endHeight, hash: Data(count: 32))
                print("⚡ Parallel scanned \(currentHeight) to \(endHeight)")
                currentHeight = endHeight + 1
            }
        } else if !isQuickScanOnly || continueAfterBundledRange {
            // SEQUENTIAL MODE - for full rescan that needs tree building
            // Runs when: no custom start OR after PHASE 1 for blocks beyond bundled tree
            // OPTIMIZED: Batch fetch blocks and prefetch transactions
            while currentHeight <= latestHeight && isScanning {
                let endHeight = min(currentHeight + UInt64(batchSize) - 1, latestHeight)
                let heights = Array(currentHeight...endHeight)

                print("📦 Fetching blocks \(currentHeight) to \(endHeight)...")

                // OPTIMIZATION 1: Fetch all block hashes in parallel
                var blockData: [(UInt64, [String])] = [] // (height, txids)
                await withTaskGroup(of: (UInt64, [String]?).self) { group in
                    for height in heights {
                        group.addTask {
                            do {
                                let blockHash = try await self.insightAPI.getBlockHash(height: height)
                                let block = try await self.insightAPI.getBlock(hash: blockHash)
                                return (height, block.tx)
                            } catch {
                                return (height, nil)
                            }
                        }
                    }
                    for await (height, txids) in group {
                        if let txids = txids {
                            blockData.append((height, txids))
                        }
                    }
                }

                // Sort by height for sequential tree processing
                blockData.sort { $0.0 < $1.0 }

                // OPTIMIZATION 2: Prefetch all transactions in parallel
                var allTxids: [(UInt64, String)] = [] // (height, txid)
                for (height, txids) in blockData {
                    for txid in txids {
                        allTxids.append((height, txid))
                    }
                }

                // Fetch transactions in parallel batches of 50
                // Now also fetches spends for nullifier detection
                var txCache: [String: (UInt64, [ShieldedOutput]?, [ShieldedSpend]?)] = [:] // txid -> (height, outputs, spends)
                let txBatchSize = 50
                for i in stride(from: 0, to: allTxids.count, by: txBatchSize) {
                    let batch = Array(allTxids[i..<min(i + txBatchSize, allTxids.count)])

                    await withTaskGroup(of: (String, UInt64, [ShieldedOutput]?, [ShieldedSpend]?).self) { group in
                        for (height, txid) in batch {
                            group.addTask {
                                do {
                                    let tx = try await self.insightAPI.getTransaction(txid: txid)
                                    return (txid, height, tx.vShieldedOutput, tx.vShieldedSpend)
                                } catch {
                                    return (txid, height, nil, nil)
                                }
                            }
                        }
                        for await (txid, height, outputs, spends) in group {
                            txCache[txid] = (height, outputs, spends)
                        }
                    }
                }

                // OPTIMIZATION 3: Process sequentially but with cached data (no network wait)
                for (height, txids) in blockData {
                    guard isScanning else { break }

                    var blockTxWithShieldedCount = 0
                    for txid in txids {
                        if let (_, outputs, spends) = txCache[txid] {
                            // Process if there are outputs OR spends (for nullifier detection)
                            let hasOutputs = outputs?.isEmpty == false
                            let hasSpends = spends?.isEmpty == false
                            if hasOutputs || hasSpends {
                                blockTxWithShieldedCount += 1
                                let outputCount = outputs?.count ?? 0
                                let spendCount = spends?.count ?? 0
                                print("🔍 Block \(height): Processing tx \(txid) with \(outputCount) outputs, \(spendCount) spends")

                                // Process on main actor to avoid SQLite threading issues
                                do {
                                    try await MainActor.run {
                                        try self.processShieldedOutputsSync(
                                            outputs: outputs ?? [],
                                            spends: spends,
                                            txid: txid,
                                            accountId: accountId,
                                            spendingKey: spendingKey,
                                            ivk: ivk,
                                            height: height
                                        )
                                    }
                                } catch {
                                    print("⚠️ Error processing tx \(txid): \(error)")
                                }
                            }
                        }
                    }

                    if blockTxWithShieldedCount > 0 {
                        print("📊 Block \(height): Found \(blockTxWithShieldedCount) transactions with shielded outputs (out of \(txids.count) total)")
                    }

                    scannedBlocks += 1
                    // Report progress every 10 blocks for better UI feedback
                    if scannedBlocks % 10 == 0 || scannedBlocks == 1 {
                        let progress = Double(scannedBlocks) / Double(totalBlocks)
                        onProgress?(progress, height, latestHeight)
                    }
                }

                // Save progress
                try? database.updateLastScannedHeight(endHeight, hash: Data(count: 32))

                // Persist tree state periodically
                if let treeData = ZipherXFFI.treeSerialize() {
                    try? database.saveTreeState(treeData)
                }

                print("📦 Processed blocks \(currentHeight) to \(endHeight)")

                currentHeight = endHeight + 1
            }
        }

        // Final tree persistence
        if let treeData = ZipherXFFI.treeSerialize() {
            try? database.saveTreeState(treeData)
            let treeSize = ZipherXFFI.treeSize()
            print("🌳 Saved commitment tree with \(treeSize) commitments")
        }

        // IMPORTANT: Do NOT update witnesses for NEW notes here!
        // New notes already have the correct witness saved at discovery time (insertNote).
        // The witness at discovery time corresponds to the tree root at that block,
        // which is the anchor we need when spending.
        // Updating witnesses here would give them the FINAL tree root, which is wrong.
        //
        // pendingWitnesses is only used to track witness indices in FFI memory,
        // NOT for updating database. The witnesses were already saved correctly.
        print("📝 Serialized witness: \(pendingWitnesses.count > 0 ? "saved at discovery" : "none") for \(pendingWitnesses.count) new note(s)")

        // CRITICAL FIX: Do NOT update existing note witnesses either!
        //
        // Previous logic assumed we'd use the "current" tree root as anchor,
        // which required updating witnesses to match. But this is WRONG because:
        // 1. We now get the anchor from block header at NOTE's received height
        // 2. The witness must match that specific anchor (tree state at note height)
        // 3. Updating witness here would make it point to CURRENT tree root
        // 4. This causes anchor/witness mismatch → transaction rejection
        //
        // The correct approach:
        // - Witness is saved at note discovery time (points to tree root at that block)
        // - Anchor is retrieved from block header at note's height
        // - Both match → valid transaction
        //
        // for (noteId, witnessIndex) in existingWitnessIndices {
        //     if let witnessData = ZipherXFFI.treeGetWitness(index: witnessIndex) {
        //         try? database.updateNoteWitness(noteId: noteId, witness: witnessData)
        //         print("📝 Updated witness for existing note \(noteId)")
        //     }
        // }
        if !existingWitnessIndices.isEmpty {
            print("📝 Preserved \(existingWitnessIndices.count) existing witness(es) - NOT updated to maintain anchor consistency")
        }

        print("✅ Scan complete")
    }

    /// Parse raw block data into CompactBlock format
    private func parseRawBlock(_ data: Data, height: UInt64, hash: String) -> CompactBlock? {
        guard data.count >= 140 else {
            print("⚠️ Block \(height) too small: \(data.count) bytes")
            return nil
        }

        // Parse all blocks including those with transactions
        // This is necessary to get all CMUs for the commitment tree

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

        _ = Data(data[offset..<offset+32]) // nonce - not used
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

    /// Process shielded outputs from Insight API transaction (synchronous version for MainActor)
    /// IMPORTANT: Must be called sequentially per block to maintain tree order
    /// Also checks spends for nullifiers to detect spent notes
    @MainActor
    private func processShieldedOutputsSync(
        outputs: [ShieldedOutput],
        spends: [ShieldedSpend]? = nil,
        txid: String,
        accountId: Int64,
        spendingKey: Data,
        ivk: Data,
        height: UInt64
    ) throws {
        // CRITICAL: Check for spent notes (nullifier detection) FIRST
        // This must be done before processing outputs
        if let spends = spends {
            for spend in spends {
                guard let nullifierData = Data(hexString: spend.nullifier) else {
                    continue
                }
                if knownNullifiers.contains(nullifierData) {
                    // One of our notes was spent!
                    try database.markNoteSpent(nullifier: nullifierData, spentHeight: height)
                    print("💸 Note spent at height \(height) - nullifier: \(spend.nullifier.prefix(16))...")
                }
            }
        }

        for (_, output) in outputs.enumerated() {
            // Convert hex strings to binary data
            guard let cmuDisplay = Data(hexString: output.cmu),
                  let epkDisplay = Data(hexString: output.ephemeralKey),
                  let encCiphertext = Data(hexString: output.encCiphertext) else {
                continue
            }

            // Reverse byte order: display format (big-endian) -> wire format (little-endian)
            let epk = epkDisplay.reversedBytes()
            let cmu = cmuDisplay.reversedBytes()

            // Append CMU to commitment tree (must be done for ALL outputs, not just ours)
            let treePosition = ZipherXFFI.treeAppend(cmu: cmu)

            // Try to decrypt with spending key
            guard let decryptedData = ZipherXFFI.tryDecryptNoteWithSK(
                spendingKey: spendingKey,
                epk: epk,
                cmu: cmu,
                ciphertext: encCiphertext
            ) else {
                continue
            }

            // Create witness for this note
            let witnessIndex = ZipherXFFI.treeWitnessCurrent()

            // Parse decrypted note data
            // Format: diversifier (11) + value (8) + rcm (32) + memo (512) = 563 bytes
            // Note: FFI returns plaintext without version byte
            guard decryptedData.count >= 51 else { continue }

            let diversifier = decryptedData.prefix(11)
            let valueBytes = Data(decryptedData[11..<19])
            let value = valueBytes.withUnsafeBytes { $0.load(as: UInt64.self) }
            let rcm = decryptedData[19..<51]
            let memo = decryptedData.count >= 563 ? decryptedData[51..<563] : Data()

            print("💰 Found note: \(value) zatoshis at height \(height)")
            print("📝 Diversifier bytes to store: \(Array(Data(diversifier)).map { String(format: "%02x", $0) }.joined(separator: ", "))")

            // Send notification
            NotificationManager.shared.notifyReceived(amount: value, txid: txid)

            let txidData = Data(hexString: txid) ?? Data()

            // Compute nullifier
            let nullifier = try rustBridge.computeNullifier(
                ivk: ivk,
                diversifier: Data(diversifier),
                value: value,
                rcm: Data(rcm),
                position: treePosition
            )

            knownNullifiers.insert(nullifier)

            // Get witness
            let witness = ZipherXFFI.treeGetWitness(index: witnessIndex) ?? Data(count: 1028)

            // Store note with CMU
            let noteId = try database.insertNote(
                accountId: accountId,
                diversifier: Data(diversifier),
                value: value,
                rcm: Data(rcm),
                memo: Data(memo),
                nullifier: nullifier,
                txid: txidData,
                height: height,
                witness: witness,
                cmu: cmu // Store CMU for potential witness rebuild
            )

            pendingWitnesses.append((noteId: noteId, witnessIndex: witnessIndex))
        }
    }

    /// Process shielded outputs for note discovery only (no tree building)
    /// Used by quick scan - much faster as it skips CMU appending
    /// Also checks spends for nullifiers to detect spent notes
    private func processShieldedOutputsForNotesOnly(
        outputs: [ShieldedOutput],
        spends: [ShieldedSpend]? = nil,
        txid: String,
        accountId: Int64,
        spendingKey: Data,
        ivk: Data,
        height: UInt64
    ) throws {
        // CRITICAL: Check for spent notes (nullifier detection) FIRST
        // This must be done before processing outputs so we can catch spends
        // of notes we already know about
        if let spends = spends {
            for spend in spends {
                guard let nullifierData = Data(hexString: spend.nullifier) else {
                    continue
                }
                if knownNullifiers.contains(nullifierData) {
                    // One of our notes was spent!
                    try database.markNoteSpent(nullifier: nullifierData, spentHeight: height)
                    print("💸 Note spent at height \(height) - nullifier: \(spend.nullifier.prefix(16))...")
                }
            }
        }
        for output in outputs {
            // Convert hex strings to binary data
            guard let cmuDisplay = Data(hexString: output.cmu),
                  let epkDisplay = Data(hexString: output.ephemeralKey),
                  let encCiphertext = Data(hexString: output.encCiphertext) else {
                continue
            }

            // DEBUG: Log encCiphertext info
            print("🔐 encCiphertext length: \(encCiphertext.count) bytes, first 4: \(encCiphertext.prefix(4).map { String(format: "%02x", $0) }.joined())")

            // Reverse byte order: display format (big-endian) -> wire format (little-endian)
            let epk = epkDisplay.reversedBytes()
            let cmu = cmuDisplay.reversedBytes()

            // Skip tree operations for speed - just try to decrypt
            guard let decryptedData = ZipherXFFI.tryDecryptNoteWithSK(
                spendingKey: spendingKey,
                epk: epk,
                cmu: cmu,
                ciphertext: encCiphertext
            ) else {
                continue
            }

            // Parse decrypted note data
            // Format: diversifier (11) + value (8) + rcm (32) + memo (512) = 563 bytes
            // Note: FFI returns plaintext without version byte
            guard decryptedData.count >= 51 else { continue }

            let diversifier = decryptedData.prefix(11)
            let valueBytes = Data(decryptedData[11..<19])
            let value = valueBytes.withUnsafeBytes { $0.load(as: UInt64.self) }
            let rcm = decryptedData[19..<51]
            let memo = decryptedData.count >= 563 ? decryptedData[51..<563] : Data()

            print("💰 Found note: \(value) zatoshis at height \(height)")
            print("📝 Diversifier bytes to store: \(Array(Data(diversifier)).map { String(format: "%02x", $0) }.joined(separator: ", "))")

            // Send notification
            NotificationManager.shared.notifyReceived(amount: value, txid: txid)

            let txidData = Data(hexString: txid) ?? Data()

            // Compute nullifier (use 0 for position since we don't have tree)
            let nullifier = try rustBridge.computeNullifier(
                ivk: ivk,
                diversifier: Data(diversifier),
                value: value,
                rcm: Data(rcm),
                position: 0 // Position unknown without tree
            )

            knownNullifiers.insert(nullifier)

            // Store note with CMU and empty witness (will need to rebuild for spending)
            let noteId = try database.insertNote(
                accountId: accountId,
                diversifier: Data(diversifier),
                value: value,
                rcm: Data(rcm),
                memo: Data(memo),
                nullifier: nullifier,
                txid: txidData,
                height: height,
                witness: Data(count: 1028), // Empty witness - needs rebuild for spending
                cmu: cmu // Store CMU for witness rebuild
            )

            print("📝 Stored note \(noteId) with value \(value)")
        }
    }

    /// Process shielded outputs from Insight API transaction (async version - legacy)
    /// IMPORTANT: Must be called sequentially per block to maintain tree order
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

            // Append CMU to commitment tree (must be done for ALL outputs, not just ours)
            let treePosition = ZipherXFFI.treeAppend(cmu: cmu)
            if treePosition == UInt64.max {
                print("⚠️ Failed to append CMU to tree at height \(height)")
            }

            // Debug: print sizes
            if height >= 2918699 {
                print("📊 Output \(index): cmu=\(cmu.count)B epk=\(epk.count)B enc=\(encCiphertext.count)B pos=\(treePosition)")
            }

            // Try to decrypt with spending key (uses zcash_primitives internally for IVK derivation)
            guard let decryptedData = ZipherXFFI.tryDecryptNoteWithSK(
                spendingKey: spendingKey,
                epk: epk,
                cmu: cmu,
                ciphertext: encCiphertext
            ) else {
                // Not addressed to us - CMU still added to tree above
                if height >= 2918699 {
                    print("🔒 Output \(index) at height \(height) not for us (could not decrypt)")
                }
                continue
            }
            print("🔓 Successfully decrypted note \(index) at height \(height)!")

            // Create witness for this note (must be done immediately after append)
            let witnessIndex = ZipherXFFI.treeWitnessCurrent()
            if witnessIndex == UInt64.max {
                print("⚠️ Failed to create witness for note at height \(height)")
            }

            // Parse decrypted note data: diversifier(11) + value(8) + rcm(32) + memo(512)
            guard decryptedData.count >= 51 else {
                print("⚠️ Decrypted data too short: \(decryptedData.count)")
                continue
            }

            let diversifier = decryptedData.prefix(11)
            let valueBytes = Data(decryptedData[11..<19])
            let value = valueBytes.withUnsafeBytes { $0.load(as: UInt64.self) }
            let rcm = decryptedData[19..<51]
            let memo = decryptedData.count >= 564 ? decryptedData[52..<564] : Data()

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

            // Use real tree position for nullifier computation
            let position = treePosition

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

            // Get current witness (will be updated at end of scan with final tree state)
            let witness = ZipherXFFI.treeGetWitness(index: witnessIndex) ?? Data(count: 1028)

            // Store note in database with CMU
            let noteId = try database.insertNote(
                accountId: accountId,
                diversifier: note.diversifier,
                value: note.value,
                rcm: note.rcm,
                memo: note.memo,
                nullifier: nullifier,
                txid: txidData,
                height: height,
                witness: witness,
                cmu: cmu // Store CMU for potential witness rebuild
            )

            // Track for final witness update
            pendingWitnesses.append((noteId: noteId, witnessIndex: witnessIndex))

            print("💰 Stored note \(noteId): \(note.value) zatoshis at height \(height), tree pos \(position)")
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
        // Legacy placeholder - real witnesses are now generated via commitment tree
        // This is kept for processCompactBlock compatibility
        return Data(count: 1028) // Real witness size: 4 + 32*32
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

