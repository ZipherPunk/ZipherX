import Foundation

// MARK: - Data Extension for Hex Conversion

extension Data {
    init?(hex: String) {
        let len = hex.count / 2
        var data = Data(capacity: len)
        var i = hex.startIndex
        for _ in 0..<len {
            let j = hex.index(i, offsetBy: 2)
            let bytes = hex[i..<j]
            if var num = UInt8(bytes, radix: 16) {
                data.append(&num, count: 1)
            } else {
                return nil
            }
            i = j
        }
        self = data
    }
}

/// Transaction Builder for Shielded Zclassic Transactions
/// Builds z-to-z transactions only (no transparent support)
final class TransactionBuilder {

    // MARK: - Constants
    private let TX_VERSION: Int32 = 4 // Sapling transaction version
    private let VERSION_GROUP_ID: UInt32 = 0x892F2085 // Sapling
    private let CONSENSUS_BRANCH_ID: UInt32 = 0x76b809bb // Sapling activation
    private let DEFAULT_FEE: UInt64 = 10000 // 0.0001 ZCL

    private var proverInitialized = false

    // MARK: - Prover Initialization

    /// Initialize the prover with Sapling parameters
    /// Uses bytes-based loading to avoid macOS Hardened Runtime file access restrictions
    func initializeProver() throws {
        guard !proverInitialized else { return }

        let params = SaplingParams.shared
        guard params.areParamsReady else {
            throw TransactionError.proofGenerationFailed
        }

        // Load param files in Swift (which has full file access)
        // Then pass bytes to Rust (avoids Hardened Runtime file access restrictions)
        let spendPath = params.spendParamsPath
        let outputPath = params.outputParamsPath

        print("📁 Loading Sapling params from Swift:")
        print("   Spend:  \(spendPath.path)")
        print("   Output: \(outputPath.path)")

        let spendData: Data
        do {
            spendData = try Data(contentsOf: spendPath)
        } catch {
            print("❌ Failed to read spend params file: \(error.localizedDescription)")
            print("   Path: \(spendPath.path)")
            print("   Exists: \(FileManager.default.fileExists(atPath: spendPath.path))")
            throw TransactionError.proofGenerationFailed
        }
        guard let outputData = try? Data(contentsOf: outputPath) else {
            print("❌ Failed to read output params file")
            throw TransactionError.proofGenerationFailed
        }

        print("📂 Loaded params: spend=\(spendData.count) bytes, output=\(outputData.count) bytes")

        // Initialize prover using bytes (avoids Rust file access issues)
        guard ZipherXFFI.initProverFromBytes(spendData: spendData, outputData: outputData) else {
            throw TransactionError.proofGenerationFailed
        }

        proverInitialized = true
        print("✅ Prover initialized with Sapling parameters")
    }

    // MARK: - Transaction Building

    /// Build a shielded transaction (z-to-z only)
    /// - Parameters:
    ///   - from: Source z-address
    ///   - to: Destination z-address
    ///   - amount: Amount in zatoshis
    ///   - memo: Optional encrypted memo
    ///   - spendingKey: Spending key for signing
    /// - Returns: Tuple of (raw transaction bytes, nullifier of spent note)
    func buildShieldedTransaction(
        from: String,
        to: String,
        amount: UInt64,
        memo: String?,
        spendingKey: Data
    ) async throws -> (Data, Data) {

        // Initialize prover if needed
        try initializeProver()

        // Validate addresses are z-addresses
        guard isValidZAddress(from), isValidZAddress(to) else {
            throw TransactionError.invalidAddress
        }

        // VUL-020: Validate memo (UTF-8 + length check)
        if let memoText = memo {
            // Check UTF-8 validity (Swift strings are always valid UTF-8)
            let memoBytes = Array(memoText.utf8)
            if memoBytes.count > ZipherXConstants.maxMemoLength {
                throw TransactionError.memoTooLong(length: memoBytes.count, max: ZipherXConstants.maxMemoLength)
            }
        }

        // VUL-024: Detect dust outputs (unspendable due to fees)
        if amount > 0 && amount < ZipherXConstants.dustThreshold {
            throw TransactionError.dustOutput(amount: amount, threshold: ZipherXConstants.dustThreshold)
        }

        // Decode destination address
        guard let toAddressBytes = ZipherXFFI.decodeAddress(to) else {
            throw TransactionError.invalidAddress
        }

        // Get notes from database with existing witnesses
        print("🔄 Getting spendable notes...")
        let database = WalletDatabase.shared
        guard let account = try database.getAccount(index: 0) else {
            throw TransactionError.proofGenerationFailed
        }

        // Get current chain height (use cached first to avoid network delay)
        var chainHeight = NetworkManager.shared.chainHeight
        if chainHeight == 0 {
            chainHeight = try await NetworkManager.shared.getChainHeight()
        }
        print("📊 Current chain height: \(chainHeight)")

        // Get notes from database - requires valid witnesses
        var dbNotes = try database.getUnspentNotes(accountId: account.id)

        // If no notes with witnesses, check for notes without witnesses that need rebuild
        if dbNotes.isEmpty {
            let allNotes = try database.getAllUnspentNotes(accountId: account.id)
            if allNotes.isEmpty {
                print("📝 No notes found in database")
                throw TransactionError.insufficientFunds
            }

            print("📝 Found \(allNotes.count) notes without valid witnesses")
            print("⚠️ Notes need witness rebuild - please use 'Rebuild Witnesses' button in Settings first")
            throw TransactionError.proofGenerationFailed
        }

        print("📝 Found \(dbNotes.count) notes with valid witnesses")

        // Use downloaded tree height from GitHub
        let downloadedTreeHeight = ZipherXConstants.effectiveTreeHeight

        // Check if tree is already loaded in memory (from startup preload)
        let currentTreeSize = ZipherXFFI.treeSize()
        if currentTreeSize > 0 {
            print("✅ Commitment tree already in memory: \(currentTreeSize) commitments")
        } else if let treeData = try? database.getTreeState() {
            // Load from database (fast)
            _ = ZipherXFFI.treeDeserialize(data: treeData)
            print("✅ Commitment tree loaded from database")
        } else {
            // Load tree from GitHub boost file cache
            print("🌳 Loading commitment tree from boost file...")

            // First ensure boost file is downloaded
            if await !CommitmentTreeUpdater.shared.hasCachedBoostFile() {
                print("🌳 Downloading boost file from GitHub...")
                _ = try await CommitmentTreeUpdater.shared.getBestAvailableBoostFile()
            }

            // Extract and deserialize the tree
            do {
                let serializedTree = try await CommitmentTreeUpdater.shared.extractSerializedTree()
                if ZipherXFFI.treeDeserialize(data: serializedTree) {
                    let treeSize = ZipherXFFI.treeSize()
                    print("✅ Loaded commitment tree with \(treeSize) commitments")

                    // CRITICAL: Save to database so we don't need to reload next time
                    if let serializedTreeData = ZipherXFFI.treeSerialize() {
                        try? database.saveTreeState(serializedTreeData)
                        print("💾 Tree state saved to database for future use")
                    }
                } else {
                    print("❌ Failed to deserialize tree from boost file")
                    throw TransactionError.proofGenerationFailed
                }
            } catch {
                print("❌ Failed to extract tree from boost file: \(error)")
                throw TransactionError.proofGenerationFailed
            }
        }

        // Get spendable notes with FRESH witnesses
        let notes = try await getSpendableNotes(for: from, spendingKey: spendingKey)

        // CURRENT LIMITATION: Single-note transactions only
        // Find the largest note that can cover the amount + fee
        let requiredAmount = amount + DEFAULT_FEE
        let sortedNotes = notes.sorted { $0.value > $1.value }

        // Find a single note large enough for the transaction
        guard let note = sortedNotes.first(where: { $0.value >= requiredAmount }) else {
            // Calculate what the user CAN send with their largest note
            let largestNote = sortedNotes.first?.value ?? 0
            let maxSendable = largestNote > DEFAULT_FEE ? largestNote - DEFAULT_FEE : 0
            let totalBalance = notes.reduce(0) { $0 + $1.value }

            print("❌ No single note large enough for this transaction")
            print("   Required: \(requiredAmount) zatoshis (amount: \(amount) + fee: \(DEFAULT_FEE))")
            print("   Largest note: \(largestNote) zatoshis")
            print("   Max sendable: \(maxSendable) zatoshis (\(Double(maxSendable) / 100_000_000) ZCL)")
            print("   Total balance: \(totalBalance) zatoshis across \(notes.count) notes")
            print("   NOTE: Multi-input transactions not yet supported - must use single note")

            throw TransactionError.noteLargeEnough(largestNote: largestNote, required: requiredAmount)
        }

        print("📝 Selected note: \(note.value) zatoshis at height \(note.height)")

        // Prepare memo (512 bytes)
        var memoData = Data(repeating: 0, count: 512)
        if let memoText = memo {
            let memoBytes = memoText.utf8
            memoData.replaceSubrange(0..<min(memoBytes.count, 512), with: memoBytes)
        }

        // CRITICAL: Get anchor from block header at NOTE HEIGHT
        // The anchor MUST match the tree state at the height where the note was received
        // NOT the current tree state!
        let headerStore = HeaderStore.shared

        // Ensure HeaderStore is open
        try? headerStore.open()

        // Get the note height (this is where the note was received)
        let noteHeight = note.height
        print("📝 Note received at height: \(noteHeight)")

        // CRITICAL FIX: Get the Sapling tree root from the block header at note height
        // This is the anchor that zcashd knows about for this note
        var anchorFromHeader: Data

        if let noteHeader = try? headerStore.getHeader(at: noteHeight) {
            anchorFromHeader = noteHeader.hashFinalSaplingRoot
            let anchorHex = anchorFromHeader.prefix(16).map { String(format: "%02x", $0) }.joined()
            print("📝 Using anchor from block header at height \(noteHeight)")
            print("📝 Anchor: \(anchorHex)...")
            print("✅ This anchor matches zcashd's tree state at the note's block")
        } else {
            print("⚠️ Block header not available at height \(noteHeight)")
            print("📝 Will compute anchor by building tree to note height...")
            // anchorFromHeader will be set after rebuilding witness
            anchorFromHeader = Data(count: 32) // placeholder
        }

        // OPTIMIZATION: Check if witness is already current (background sync keeps it updated)
        // If note.anchor matches current tree root, we can use the stored witness directly!
        var witnessToUse = note.witness
        var needsRebuild = note.witness.count < 1028 || note.witness.allSatisfy { $0 == 0 }

        if needsRebuild {
            print("⚠️ Witness invalid (\(note.witness.count) bytes), needs rebuild")
        } else if note.anchor.count == 32 && !note.anchor.allSatisfy({ $0 == 0 }) {
            // Check if stored anchor matches current tree root
            if let currentTreeRoot = ZipherXFFI.treeRoot() {
                if note.anchor == currentTreeRoot {
                    print("✅ Witness is current (anchor matches tree root) - INSTANT mode!")
                    // Use the current tree root as anchor since witness is already synced
                    anchorFromHeader = currentTreeRoot
                    needsRebuild = false
                } else {
                    let storedHex = note.anchor.prefix(8).map { String(format: "%02x", $0) }.joined()
                    let currentHex = currentTreeRoot.prefix(8).map { String(format: "%02x", $0) }.joined()
                    print("⚠️ Witness anchor (\(storedHex)...) differs from tree root (\(currentHex)...), rebuilding...")
                    needsRebuild = true
                }
            }
        }

        let noteCMU = note.cmu

        if noteCMU == nil && needsRebuild {
            print("❌ Note CMU not stored - cannot rebuild witness")
            print("💡 Tip: Do a full rescan to populate CMU field")
            throw TransactionError.proofGenerationFailed
        }

        // For notes beyond downloaded tree height, rebuild witness if needed
        // OPTIMIZATION: Skip if witness is already current (background sync)
        if noteHeight > downloadedTreeHeight && needsRebuild {
            print("📝 Note is beyond downloaded tree height (\(downloadedTreeHeight)), rebuilding witness...")

            guard let cmu = noteCMU else {
                print("❌ Cannot rebuild witness without CMU")
                throw TransactionError.proofGenerationFailed
            }

            // Rebuild witness using downloaded tree + fetched CMUs
            if let result = try await rebuildWitnessForNote(
                cmu: cmu,
                noteHeight: noteHeight,
                downloadedTreeHeight: downloadedTreeHeight
            ) {
                print("✅ Successfully rebuilt witness for note at height \(noteHeight)")
                witnessToUse = result.witness

                // Use computed anchor if we don't have it from header store
                if anchorFromHeader.allSatisfy({ $0 == 0 }) {
                    anchorFromHeader = result.anchor
                    let anchorHex = anchorFromHeader.prefix(16).map { String(format: "%02x", $0) }.joined()
                    print("📝 Using computed anchor: \(anchorHex)...")
                }
            } else {
                print("❌ Failed to rebuild witness")
                throw TransactionError.proofGenerationFailed
            }
        } else if noteHeight <= downloadedTreeHeight && needsRebuild, let cmu = noteCMU {
            // Note is within downloaded tree range - use treeCreateWitnessForCMU
            print("📝 Note is within downloaded tree range, creating witness from downloaded CMUs...")

            guard let cachedPath = await CommitmentTreeUpdater.shared.getCachedCMUFilePath(),
                  let cachedData = try? Data(contentsOf: cachedPath) else {
                print("❌ Failed to load commitment tree from GitHub cache")
                throw TransactionError.proofGenerationFailed
            }

            if let result = ZipherXFFI.treeCreateWitnessForCMU(cmuData: cachedData, targetCMU: cmu) {
                print("✅ Created witness at position \(result.position)")
                witnessToUse = result.witness
            } else {
                print("❌ Failed to find note CMU in downloaded tree")
                throw TransactionError.proofGenerationFailed
            }
        }

        // VUL-002 FIX: Use encrypted key FFI to ensure key is decrypted only in Rust
        // and immediately zeroed after use by Rust's secure_zero()
        let (encryptedKey, encryptionKey) = try SecureKeyStorage.shared.getEncryptedKeyAndPassword()
        print("🔐 VUL-002: Using encrypted key FFI (key decrypted only in Rust)")

        guard let rawTx = ZipherXFFI.buildTransactionEncrypted(
            encryptedSpendingKey: encryptedKey,
            encryptionKey: encryptionKey,
            toAddress: toAddressBytes,
            amount: amount,
            memo: memoData,
            anchor: anchorFromHeader,  // CRITICAL: Use anchor from block header at note height
            witness: witnessToUse,     // Use rebuilt witness that matches anchor
            noteValue: note.value,
            noteRcm: note.rcm,
            noteDiversifier: note.diversifier,
            chainHeight: chainHeight  // Use CURRENT chain height for expiry calculation
        ) else {
            throw TransactionError.proofGenerationFailed
        }

        print("✅ Transaction built: \(rawTx.count) bytes")

        // Print raw transaction hex for manual broadcast debugging
        let txHex = rawTx.map { String(format: "%02x", $0) }.joined()
        print("📋 Raw TX hex: \(txHex)")

        // Return both transaction and nullifier of spent note
        print("📝 Spent note nullifier: \(note.nullifier.map { String(format: "%02x", $0) }.joined().prefix(16))...")
        return (rawTx, note.nullifier)
    }

    /// Progress callback type
    typealias ProgressCallback = (_ step: String, _ detail: String?, _ progress: Double?) -> Void

    /// Build shielded transaction with progress reporting
    func buildShieldedTransactionWithProgress(
        from: String,
        to: String,
        amount: UInt64,
        memo: String?,
        spendingKey: Data,
        onProgress: @escaping ProgressCallback
    ) async throws -> (Data, Data) {

        // Initialize prover
        try initializeProver()
        onProgress("prover", nil, nil)

        // Validate addresses
        guard isValidZAddress(from), isValidZAddress(to) else {
            throw TransactionError.invalidAddress
        }

        // VUL-020: Validate memo (UTF-8 + length check)
        if let memoText = memo {
            let memoBytes = Array(memoText.utf8)
            if memoBytes.count > ZipherXConstants.maxMemoLength {
                throw TransactionError.memoTooLong(length: memoBytes.count, max: ZipherXConstants.maxMemoLength)
            }
        }

        // VUL-024: Detect dust outputs (unspendable due to fees)
        if amount > 0 && amount < ZipherXConstants.dustThreshold {
            throw TransactionError.dustOutput(amount: amount, threshold: ZipherXConstants.dustThreshold)
        }

        guard let toAddressBytes = ZipherXFFI.decodeAddress(to) else {
            throw TransactionError.invalidAddress
        }

        onProgress("notes", nil, nil)

        // Get notes from database
        let database = WalletDatabase.shared
        guard let account = try database.getAccount(index: 0) else {
            throw TransactionError.proofGenerationFailed
        }

        // Use cached chain height first to avoid network delay
        var chainHeight = NetworkManager.shared.chainHeight
        if chainHeight == 0 {
            chainHeight = try await NetworkManager.shared.getChainHeight()
        }
        var dbNotes = try database.getUnspentNotes(accountId: account.id)

        if dbNotes.isEmpty {
            let allNotes = try database.getAllUnspentNotes(accountId: account.id)
            if allNotes.isEmpty {
                throw TransactionError.insufficientFunds
            }
            throw TransactionError.proofGenerationFailed
        }

        // Use downloaded tree height from GitHub
        let downloadedTreeHeight = ZipherXConstants.effectiveTreeHeight

        // Check if tree is already loaded in memory (from startup preload)
        let currentTreeSize = ZipherXFFI.treeSize()
        if currentTreeSize > 0 {
            onProgress("tree", "Tree ready (\(currentTreeSize.formatted()) CMUs)", 1.0)
        } else if let treeData = try? database.getTreeState() {
            onProgress("tree", "Loading from cache...", 0.5)
            _ = ZipherXFFI.treeDeserialize(data: treeData)
            onProgress("tree", "Tree loaded from cache", 1.0)
        } else {
            onProgress("tree", "Loading tree from GitHub cache...", 0.0)

            if let cachedPath = await CommitmentTreeUpdater.shared.getCachedCMUFilePath(),
               let cachedData = try? Data(contentsOf: cachedPath) {

                // Count CMUs for progress display
                let cmuCount = cachedData.count >= 8 ?
                    cachedData.prefix(8).withUnsafeBytes { $0.load(as: UInt64.self) } : 0

                // Use the new FFI function with real progress callback
                let success = ZipherXFFI.treeLoadFromCMUsWithProgress(data: cachedData) { current, total in
                    let progress = Double(current) / Double(total)
                    let currentFormatted = NumberFormatter.localizedString(from: NSNumber(value: current), number: .decimal)
                    let totalFormatted = NumberFormatter.localizedString(from: NSNumber(value: total), number: .decimal)
                    onProgress("tree", "\(currentFormatted)/\(totalFormatted) CMUs", progress)
                }

                if !success {
                    throw TransactionError.proofGenerationFailed
                }

                // CRITICAL: Save to database so we don't need to reload next time
                if let serializedTree = ZipherXFFI.treeSerialize() {
                    try? database.saveTreeState(serializedTree)
                    print("💾 Tree state saved to database for future use")
                }

                onProgress("tree", "\(cmuCount.formatted()) CMUs loaded", 1.0)
            } else {
                // Download boost file from GitHub if not cached
                onProgress("tree", "Downloading boost file...", 0.1)
                _ = try await CommitmentTreeUpdater.shared.getBestAvailableBoostFile { progress, status in
                    onProgress("tree", status, progress * 0.8)
                }

                // Extract and deserialize the tree
                onProgress("tree", "Extracting tree...", 0.85)
                let serializedTree = try await CommitmentTreeUpdater.shared.extractSerializedTree()
                if ZipherXFFI.treeDeserialize(data: serializedTree) {
                    if let serializedTreeData = ZipherXFFI.treeSerialize() {
                        try? database.saveTreeState(serializedTreeData)
                    }
                    onProgress("tree", "Tree ready", 1.0)
                } else {
                    throw TransactionError.proofGenerationFailed
                }
            }
        }

        // Get spendable notes
        let notes = try await getSpendableNotes(for: from, spendingKey: spendingKey)

        // Note selection - prefer single note, fall back to multi-input
        let requiredAmount = amount + DEFAULT_FEE
        let sortedNotes = notes.sorted { $0.value > $1.value }
        let totalBalance = notes.reduce(0) { $0 + $1.value }

        // Check if we have enough total balance
        guard totalBalance >= requiredAmount else {
            print("❌ Insufficient total balance: have \(totalBalance), need \(requiredAmount)")
            throw TransactionError.insufficientFunds
        }

        // Try to find a single note large enough (preferred for simplicity/fee)
        var selectedNotes: [SpendableNote] = []
        if let singleNote = sortedNotes.first(where: { $0.value >= requiredAmount }) {
            selectedNotes = [singleNote]
            print("📝 Single note selected: \(singleNote.value) zatoshis at height \(singleNote.height)")
        } else {
            // Multi-input mode: select notes until we have enough
            print("📝 No single note large enough, using multi-input mode...")
            var accumulated: UInt64 = 0
            for note in sortedNotes {
                selectedNotes.append(note)
                accumulated += note.value
                print("   + Note: \(note.value) zatoshis (running total: \(accumulated))")
                if accumulated >= requiredAmount {
                    break
                }
            }
            print("📝 Selected \(selectedNotes.count) notes totaling \(accumulated) zatoshis")
        }

        let isMultiInput = selectedNotes.count > 1

        // Prepare memo
        var memoData = Data(repeating: 0, count: 512)
        if let memoText = memo {
            let memoBytes = memoText.utf8
            memoData.replaceSubrange(0..<min(memoBytes.count, 512), with: memoBytes)
        }

        onProgress("witness", nil, nil)

        // Get anchor and rebuild witnesses for all selected notes
        let headerStore = HeaderStore.shared
        try? headerStore.open()

        // Prepare witnesses for all selected notes
        var preparedSpends: [(note: SpendableNote, witness: Data)] = []

        // CRITICAL FIX: For multi-input transactions, ALL witnesses MUST have the same anchor.
        if isMultiInput {
            print("🔧 Multi-input: Checking if database witnesses can be used directly...")

            // OPTIMIZATION: First check if ALL notes have valid witnesses with MATCHING anchors
            // This is the INSTANT path - no network or file I/O needed!
            var allValid = true
            var commonAnchor: Data?

            for note in selectedNotes {
                // Check if witness is valid
                let witnessValid = note.witness.count >= 1028 && !note.witness.allSatisfy { $0 == 0 }
                if !witnessValid {
                    print("   Note at height \(note.height): invalid witness (\(note.witness.count) bytes)")
                    allValid = false
                    break
                }

                // Extract anchor from witness to verify all match
                guard let witnessAnchor = ZipherXFFI.witnessGetRoot(note.witness) else {
                    print("   Note at height \(note.height): failed to extract anchor from witness")
                    allValid = false
                    break
                }

                if let expected = commonAnchor {
                    if witnessAnchor != expected {
                        let expectedHex = expected.prefix(8).map { String(format: "%02x", $0) }.joined()
                        let actualHex = witnessAnchor.prefix(8).map { String(format: "%02x", $0) }.joined()
                        print("   Note at height \(note.height): anchor mismatch! Expected \(expectedHex)..., got \(actualHex)...")
                        allValid = false
                        break
                    }
                } else {
                    commonAnchor = witnessAnchor
                }
            }

            // VALIDATION: The common anchor must match the current tree root!
            // The witnesses must reflect the CURRENT tree state, not an old one.
            let currentTreeRoot = ZipherXFFI.treeRoot()

            // CRITICAL SECURITY FIX: Validate tree root against blockchain's finalsaplingroot!
            // The FFI tree can become corrupted. We MUST verify against trusted chain data.
            var treeIsValid = true
            var validationHeight: UInt64 = 0

            if let currentTreeRoot = currentTreeRoot,
               let lastScanned = try? WalletDatabase.shared.getLastScannedHeight() {

                // Try to get header at lastScanned height
                var trustedHeader = try? headerStore.getHeader(at: lastScanned)
                validationHeight = lastScanned

                // FIX: If lastScanned > max header height, use max available header instead
                if trustedHeader == nil {
                    if let maxHeaderHeight = try? headerStore.getLatestHeight(),
                       let fallbackHeader = try? headerStore.getHeader(at: maxHeaderHeight) {
                        print("📝 lastScanned (\(lastScanned)) > max header (\(maxHeaderHeight)), using max header for validation")
                        trustedHeader = fallbackHeader
                        validationHeight = maxHeaderHeight
                    }
                }

                if let header = trustedHeader {
                    let trustedRoot = header.hashFinalSaplingRoot
                    let treeRootHex = currentTreeRoot.prefix(16).map { String(format: "%02x", $0) }.joined()
                    let trustedRootHex = trustedRoot.prefix(16).map { String(format: "%02x", $0) }.joined()

                    if currentTreeRoot != trustedRoot {
                        print("🚨 [SECURITY] Tree root mismatch detected!")
                        print("   FFI tree root:      \(treeRootHex)...")
                        print("   Blockchain expects: \(trustedRootHex)... at height \(validationHeight)")

                        // Try checkpoint-based recovery FIRST (faster than full rebuild)
                        if await tryRestoreFromCheckpoint(targetHeight: validationHeight) {
                            print("✅ Tree restored from checkpoint - retrying validation...")
                            // Re-check tree root after restoration
                            if let newRoot = ZipherXFFI.treeRoot(), newRoot == trustedRoot {
                                print("✅ Checkpoint restoration successful - tree is now valid!")
                                treeIsValid = true
                            } else {
                                print("⚠️ Checkpoint restoration didn't fix tree - will rebuild witnesses")
                                treeIsValid = false
                            }
                        } else {
                            print("⚠️ No valid checkpoint available - forcing witness rebuild!")
                            treeIsValid = false
                        }
                    } else {
                        print("✅ Tree root validated against blockchain finalsaplingroot at height \(validationHeight)")
                    }
                } else {
                    // No headers available at all - trust anchors if they match tree
                    print("⚠️ No headers available for validation - checking anchor match...")
                    if commonAnchor == currentTreeRoot {
                        print("✅ Anchors match current tree root - assuming valid")
                        treeIsValid = true
                    } else {
                        print("⚠️ Anchors don't match tree root - will rebuild")
                        treeIsValid = false
                    }
                }
            } else {
                print("⚠️ Could not validate tree root (missing tree root or lastScanned)")
                treeIsValid = false
            }

            let anchorMatchesTree = allValid && commonAnchor != nil && commonAnchor == currentTreeRoot && treeIsValid

            if allValid && anchorMatchesTree {
                // INSTANT MODE: All witnesses are valid with matching anchors that match current tree!
                print("✅ Multi-input INSTANT mode: All \(selectedNotes.count) notes have valid witnesses with matching anchors!")
                for note in selectedNotes {
                    preparedSpends.append((note: note, witness: note.witness))
                }
            } else if allValid && commonAnchor != nil && currentTreeRoot != nil {
                // Check if anchors match but tree validation failed, OR if anchors are actually stale
                let commonHex = commonAnchor!.prefix(8).map { String(format: "%02x", $0) }.joined()
                let treeHex = currentTreeRoot!.prefix(8).map { String(format: "%02x", $0) }.joined()

                if commonAnchor == currentTreeRoot {
                    // Anchors match tree, but treeIsValid=false (validation couldn't confirm against blockchain)
                    print("⚠️ Anchors match tree (\(commonHex)...) but blockchain validation failed - rebuilding witnesses...")
                } else {
                    // Anchors are genuinely stale (tree has moved on)
                    print("⚠️ Witness anchors (\(commonHex)...) don't match current tree (\(treeHex)...) - STALE!")
                }

                // FAST PATH: Try checkpoint-based delta sync (max ~10 blocks)
                // This is MUCH faster than rebuilding from boost file
                let lastScanned = (try? WalletDatabase.shared.getLastScannedHeight()) ?? 0
                let chainHeight = try await NetworkManager.shared.getChainHeight()

                // CRITICAL FIX: Detect when checkpoint is ahead of chain height
                // This can happen when HeaderStore lags behind the real blockchain
                // Note: chainHeight comes from getChainHeight() which may use lagging HeaderStore
                if lastScanned > chainHeight {
                    // Only warn, don't reset - the checkpoint might be correct, HeaderStore might be lagging
                    let diff = lastScanned - chainHeight
                    print("⚠️ Checkpoint \(lastScanned) is \(diff) blocks AHEAD of returned chain height \(chainHeight)")
                    print("   This likely means HeaderStore is lagging behind. Skipping delta sync...")
                    // Don't reset - just skip fast path and use boost rebuild which handles this correctly
                }

                let blocksBehind = chainHeight > lastScanned ? chainHeight - lastScanned : 0

                print("⚡ FAST PATH: Checkpoint at \(lastScanned), chain at \(chainHeight) (\(blocksBehind) blocks behind)")

                if blocksBehind <= 50 && blocksBehind > 0 && lastScanned > 0 {
                    // FAST: Delta sync from checkpoint (max 50 blocks)
                    print("⚡ Using fast delta sync (\(blocksBehind) blocks)...")

                    // 1. Restore tree from checkpoint
                    if let treeState = try? WalletDatabase.shared.getTreeState() {
                        if ZipherXFFI.treeDeserialize(data: treeState) {
                            print("✅ Tree restored from checkpoint")

                            // 2. Load witnesses into FFI for auto-update, track indices
                            var witnessIndices: [(SpendableNote, UInt64)] = []
                            for note in selectedNotes {
                                if note.witness.count >= 1028 {
                                    let witnessIndex = note.witness.withUnsafeBytes { ptr in
                                        ZipherXFFI.treeLoadWitness(
                                            witnessData: ptr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                                            witnessLen: note.witness.count
                                        )
                                    }
                                    if witnessIndex != UInt64.max {
                                        witnessIndices.append((note, witnessIndex))
                                    }
                                }
                            }

                            guard witnessIndices.count == selectedNotes.count else {
                                print("⚠️ Could not load all witnesses into FFI")
                                throw TransactionError.proofGenerationFailed
                            }

                            // 3. Fetch and append delta CMUs
                            let deltaCMUs = try await fetchCMUsForBlockRange(from: lastScanned + 1, to: chainHeight)
                            print("📡 Fetched \(deltaCMUs.count) CMUs from \(blocksBehind) blocks")

                            for cmu in deltaCMUs {
                                _ = ZipherXFFI.treeAppend(cmu: cmu)
                            }

                            // 4. Get updated anchor
                            guard let newAnchor = ZipherXFFI.treeRoot() else {
                                throw TransactionError.proofGenerationFailed
                            }
                            print("📝 New anchor after delta sync: \(newAnchor.prefix(8).map { String(format: "%02x", $0) }.joined())...")

                            // 5. Extract updated witnesses using tracked indices
                            for (note, witnessIndex) in witnessIndices {
                                if let witness = ZipherXFFI.treeGetWitness(index: witnessIndex) {
                                    preparedSpends.append((note: note, witness: witness))
                                } else {
                                    throw TransactionError.proofGenerationFailed
                                }
                            }

                            // 6. Save updated tree state
                            if let treeData = ZipherXFFI.treeSerialize() {
                                try? WalletDatabase.shared.saveTreeState(treeData)
                                try? WalletDatabase.shared.updateLastScannedHeight(chainHeight, hash: Data(count: 32))
                            }

                            print("✅ FAST delta sync complete - \(preparedSpends.count) witnesses updated")
                        }
                    }
                }

                // SLOW PATH: Fall back to boost + delta if fast path didn't work
                if preparedSpends.isEmpty {
                    print("⚠️ Fast path failed, falling back to boost + delta...")
                    let cachedBoostHeight = await CommitmentTreeUpdater.shared.getCachedBoostHeight() ?? 0
                    let maxNoteHeight = selectedNotes.map { $0.height }.max() ?? 0
                    print("📊 Cached boost height: \(cachedBoostHeight), max note height: \(maxNoteHeight)")

                    let results = try await rebuildWitnessesForNotes(
                        notes: selectedNotes,
                        downloadedTreeHeight: cachedBoostHeight
                    )

                    for result in results {
                        preparedSpends.append((note: result.note, witness: result.witness))
                    }
                }
                print("✅ Created \(preparedSpends.count) witnesses")
            } else {
                // FALLBACK: Rebuild witnesses using boost + delta
                print("⚠️ Database witnesses not usable, rebuilding from boost + delta...")

                let cachedBoostHeight = await CommitmentTreeUpdater.shared.getCachedBoostHeight() ?? 0
                let maxNoteHeight = selectedNotes.map { $0.height }.max() ?? 0
                print("📊 Cached boost height: \(cachedBoostHeight), max note height: \(maxNoteHeight)")

                let results = try await rebuildWitnessesForNotes(
                    notes: selectedNotes,
                    downloadedTreeHeight: cachedBoostHeight
                )

                for result in results {
                    preparedSpends.append((note: result.note, witness: result.witness))
                }
                print("✅ Created \(preparedSpends.count) witnesses with SAME anchor")
            }
        } else {
            // Single-input transaction - use existing logic
            for (index, note) in selectedNotes.enumerated() {
                print("📝 Preparing witness for note \(index + 1)/\(selectedNotes.count)")

                var witnessToUse = note.witness
                var needsRebuild = note.witness.count < 1028 || note.witness.allSatisfy { $0 == 0 }
                let noteCMU = note.cmu
                let noteHeight = note.height

                // CRITICAL SECURITY FIX: Validate witness anchor against blockchain's finalsaplingroot!
                // Even if witness looks valid, it might have a corrupted anchor.
                if !needsRebuild && note.anchor.count == 32 && !note.anchor.allSatisfy({ $0 == 0 }) {
                    // Check if anchor matches a valid blockchain state
                    if let lastScanned = try? WalletDatabase.shared.getLastScannedHeight(),
                       let trustedHeader = try? headerStore.getHeader(at: lastScanned) {
                        let trustedRoot = trustedHeader.hashFinalSaplingRoot
                        if note.anchor != trustedRoot {
                            let noteAnchorHex = note.anchor.prefix(16).map { String(format: "%02x", $0) }.joined()
                            let trustedRootHex = trustedRoot.prefix(16).map { String(format: "%02x", $0) }.joined()
                            print("🚨 [SECURITY] Note \(index + 1) anchor mismatch!")
                            print("   Stored anchor:      \(noteAnchorHex)...")
                            print("   Blockchain expects: \(trustedRootHex)... at height \(lastScanned)")

                            // Try checkpoint-based tree restoration first
                            if await tryRestoreFromCheckpoint(targetHeight: lastScanned) {
                                print("✅ Tree restored from checkpoint - witness still needs rebuild")
                            } else {
                                print("📍 No valid checkpoint - will rebuild from boost + delta")
                            }
                            needsRebuild = true
                        } else {
                            print("✅ Note \(index + 1) witness validated - INSTANT mode!")
                        }
                    } else {
                        print("⚠️ Could not validate anchor (missing header data) - forcing rebuild")
                        needsRebuild = true
                    }
                }

                // Only rebuild witness if needed
                if needsRebuild && noteHeight > downloadedTreeHeight {
                    guard let cmu = noteCMU else {
                        print("❌ Note \(index + 1) has no CMU for witness rebuild")
                        throw TransactionError.proofGenerationFailed
                    }

                    print("⚠️ Rebuilding witness for note \(index + 1) at height \(noteHeight)")
                    if let result = try await rebuildWitnessForNote(
                        cmu: cmu,
                        noteHeight: noteHeight,
                        downloadedTreeHeight: downloadedTreeHeight
                    ) {
                        witnessToUse = result.witness
                    } else {
                        throw TransactionError.proofGenerationFailed
                    }
                } else if needsRebuild, let cmu = noteCMU {
                    guard let cachedPath = await CommitmentTreeUpdater.shared.getCachedCMUFilePath(),
                          let cachedData = try? Data(contentsOf: cachedPath) else {
                        throw TransactionError.proofGenerationFailed
                    }

                    if let result = ZipherXFFI.treeCreateWitnessForCMU(cmuData: cachedData, targetCMU: cmu) {
                        witnessToUse = result.witness
                    } else {
                        print("❌ Failed to create witness for note \(index + 1)")
                        throw TransactionError.proofGenerationFailed
                    }
                }

                preparedSpends.append((note: note, witness: witnessToUse))
            }
        }

        onProgress("proof", nil, nil)

        if isMultiInput {
            // MULTI-INPUT TRANSACTION
            print("🔨 Building multi-input transaction with \(preparedSpends.count) spends...")

            // Convert to SpendInfoSwift array
            var spendInfos: [ZipherXFFI.SpendInfoSwift] = []
            for (note, witness) in preparedSpends {
                let info = ZipherXFFI.SpendInfoSwift(
                    witness: witness,
                    value: note.value,
                    rcm: note.rcm,
                    diversifier: note.diversifier
                )
                spendInfos.append(info)
            }

            // VUL-002 FIX: Use encrypted key FFI for multi-input transaction
            let (encryptedKey, encryptionKey) = try SecureKeyStorage.shared.getEncryptedKeyAndPassword()
            print("🔐 VUL-002: Using encrypted key FFI for multi-input (key decrypted only in Rust)")

            guard let result = ZipherXFFI.buildTransactionMultiEncrypted(
                encryptedSpendingKey: encryptedKey,
                encryptionKey: encryptionKey,
                toAddress: toAddressBytes,
                amount: amount,
                memo: memoData,
                spends: spendInfos,
                chainHeight: chainHeight
            ) else {
                print("❌ Multi-input transaction build failed")
                throw TransactionError.proofGenerationFailed
            }

            print("✅ Multi-input transaction built: \(result.txData.count) bytes, \(result.nullifiers.count) nullifiers")

            // Return first nullifier (for primary tracking) - TODO: track all nullifiers
            let primaryNullifier = result.nullifiers.first ?? preparedSpends[0].note.nullifier
            return (result.txData, primaryNullifier)

        } else {
            // SINGLE-INPUT TRANSACTION (existing logic)
            let note = preparedSpends[0].note
            let witnessToUse = preparedSpends[0].witness
            let noteHeight = note.height

            // Get anchor from header store
            var anchorFromHeader: Data
            if let noteHeader = try? headerStore.getHeader(at: noteHeight) {
                anchorFromHeader = noteHeader.hashFinalSaplingRoot
            } else if let currentTreeRoot = ZipherXFFI.treeRoot() {
                anchorFromHeader = currentTreeRoot
            } else {
                anchorFromHeader = Data(count: 32)
            }

            // VUL-002 FIX: Use encrypted key FFI for single-input transaction
            let (encryptedKey, encryptionKey) = try SecureKeyStorage.shared.getEncryptedKeyAndPassword()
            print("🔐 VUL-002: Using encrypted key FFI (key decrypted only in Rust)")

            guard let rawTx = ZipherXFFI.buildTransactionEncrypted(
                encryptedSpendingKey: encryptedKey,
                encryptionKey: encryptionKey,
                toAddress: toAddressBytes,
                amount: amount,
                memo: memoData,
                anchor: anchorFromHeader,
                witness: witnessToUse,
                noteValue: note.value,
                noteRcm: note.rcm,
                noteDiversifier: note.diversifier,
                chainHeight: chainHeight
            ) else {
                throw TransactionError.proofGenerationFailed
            }

            print("✅ Transaction built: \(rawTx.count) bytes")
            return (rawTx, note.nullifier)
        }
    }

    // MARK: - Note Management

    private func getSpendableNotes(for address: String, spendingKey: Data) async throws -> [SpendableNote] {
        // Query the wallet database for unspent notes
        let database = WalletDatabase.shared
        // Get correct account ID (database row ID starts at 1)
        guard let account = try database.getAccount(index: 0) else {
            print("📝 No account found in database")
            return []
        }
        let dbNotes = try database.getUnspentNotes(accountId: account.id)

        print("📝 Database returned \(dbNotes.count) unspent notes")

        // Get current chain height for confirmation calculation
        var chainHeight = NetworkManager.shared.chainHeight

        // If chain height is 0, fetch it now
        if chainHeight == 0 {
            print("📝 Chain height not set, fetching now...")
            if let height = try? await NetworkManager.shared.getChainHeight() {
                chainHeight = height
                print("📝 Fetched chain height: \(chainHeight)")
            } else {
                print("⚠️ Failed to get chain height, using 2920000 as fallback")
                chainHeight = 2920000
            }
        }

        // Convert database notes to SpendableNotes
        var spendableNotes: [SpendableNote] = []

        // Try to get tree root - if not in memory, load from database
        var anchor = ZipherXFFI.treeRoot()
        if anchor == nil {
            print("📝 Tree not in memory, loading from database...")
            if let treeData = try? database.getTreeState() {
                _ = ZipherXFFI.treeDeserialize(data: treeData)
                anchor = ZipherXFFI.treeRoot()
                print("📝 Loaded tree from database")
            }
        }

        guard let anchor = anchor else {
            print("📝 Failed to get tree root - need to rescan blockchain")
            return []
        }
        print("📝 Current tree root: \(anchor.map { String(format: "%02x", $0) }.joined().prefix(16))...")

        for dbNote in dbNotes {
            // Calculate confirmations: chainHeight - noteHeight + 1
            let confirmations = chainHeight > dbNote.height ? Int(chainHeight - dbNote.height + 1) : 0
            print("📝 Note: value=\(dbNote.value), height=\(dbNote.height), chainHeight=\(chainHeight), confirmations=\(confirmations), witness=\(dbNote.witness.count) bytes")
            // Only include confirmed notes (1+ confirmations)
            guard confirmations >= 1 else {
                print("📝 Skipping note: insufficient confirmations")
                continue
            }

            // The anchor is the current tree root, not from the witness
            // Witness format: 4 bytes position + 32*32 bytes merkle path
            let note = SpendableNote(
                value: dbNote.value,
                anchor: anchor, // Use current tree root
                witness: dbNote.witness,
                diversifier: dbNote.diversifier,
                rcm: dbNote.rcm,
                position: UInt64(dbNote.height) * 1000, // Approximate position
                nullifier: dbNote.nullifier, // For marking as spent
                height: UInt64(dbNote.height), // Store note height for anchor lookup
                cmu: dbNote.cmu // Note commitment for witness rebuild
            )

            spendableNotes.append(note)
        }

        print("📝 Found \(spendableNotes.count) spendable notes")
        return spendableNotes
    }

    private func selectNotes(_ notes: [SpendableNote], targetAmount: UInt64) throws -> ([SpendableNote], UInt64) {
        // Simple greedy selection
        var selected: [SpendableNote] = []
        var total: UInt64 = 0

        let sortedNotes = notes.sorted { $0.value > $1.value }

        for note in sortedNotes {
            selected.append(note)
            total += note.value

            if total >= targetAmount {
                break
            }
        }

        guard total >= targetAmount else {
            throw TransactionError.insufficientFunds
        }

        let change = total - targetAmount
        return (selected, change)
    }

    // MARK: - Address Validation

    /// Bech32 character set for decoding
    private static let bech32Charset = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"

    /// Bech32 generator polynomial for checksum
    private static let bech32Generator: [UInt32] = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3]

    /// Bech32 polymod function for checksum verification
    private func bech32Polymod(_ values: [UInt8]) -> UInt32 {
        var chk: UInt32 = 1
        for v in values {
            let b = chk >> 25
            chk = ((chk & 0x1ffffff) << 5) ^ UInt32(v)
            for i in 0..<5 {
                if ((b >> i) & 1) == 1 {
                    chk ^= TransactionBuilder.bech32Generator[i]
                }
            }
        }
        return chk
    }

    /// Expand human-readable part for checksum calculation
    private func bech32HrpExpand(_ hrp: String) -> [UInt8] {
        var ret: [UInt8] = []
        for c in hrp.utf8 {
            ret.append(c >> 5)
        }
        ret.append(0)
        for c in hrp.utf8 {
            ret.append(c & 31)
        }
        return ret
    }

    /// Verify Bech32 checksum
    private func bech32VerifyChecksum(_ hrp: String, _ data: [UInt8]) -> Bool {
        let expanded = bech32HrpExpand(hrp)
        return bech32Polymod(expanded + data) == 1
    }

    /// Validate z-address with full Bech32 checksum verification
    /// SECURITY: Validates checksum to prevent typos and malformed addresses
    private func isValidZAddress(_ address: String) -> Bool {
        // Zclassic Sapling addresses use Bech32 encoding with "zs1" prefix
        guard address.hasPrefix("zs1"), address.count == 78 else {
            return false
        }

        // Find separator (last '1' in address)
        guard let separatorIndex = address.lastIndex(of: "1") else {
            return false
        }

        let hrp = String(address[..<separatorIndex])
        let dataPart = String(address[address.index(after: separatorIndex)...])

        // Validate HRP
        guard hrp == "zs" else { return false }

        // Decode Bech32 data part
        var data: [UInt8] = []
        for c in dataPart.lowercased() {
            guard let index = TransactionBuilder.bech32Charset.firstIndex(of: c) else {
                return false // Invalid character
            }
            data.append(UInt8(TransactionBuilder.bech32Charset.distance(from: TransactionBuilder.bech32Charset.startIndex, to: index)))
        }

        // Verify checksum (last 6 characters)
        guard data.count >= 6 else { return false }

        // Verify the Bech32 checksum
        guard bech32VerifyChecksum(hrp, data) else {
            print("⚠️ SECURITY: Invalid Bech32 checksum for address")
            return false
        }

        return true
    }

    // MARK: - Witness Rebuild

    /// Rebuild witness for a note that's beyond the bundled tree height
    /// This fetches CMUs from the chain and builds the tree up to the note's position
    /// Returns tuple of (witness, anchor) where anchor is the tree root at noteHeight
    func rebuildWitnessForNote(
        cmu: Data,
        noteHeight: UInt64,
        downloadedTreeHeight: UInt64
    ) async throws -> (witness: Data, anchor: Data)? {
        print("🔄 Rebuilding witness for note at height \(noteHeight)...")
        print("📝 Note CMU: \(cmu.map { String(format: "%02x", $0) }.joined().prefix(16))...")

        // 1. Load CMU file from GitHub cache
        guard let cachedPath = await CommitmentTreeUpdater.shared.getCachedCMUFilePath(),
              let cachedData = try? Data(contentsOf: cachedPath) else {
            print("❌ Failed to load commitment tree from GitHub cache")
            return nil
        }

        // Parse CMU count
        guard cachedData.count >= 8 else { return nil }
        let cachedCount = cachedData.prefix(8).withUnsafeBytes { $0.load(as: UInt64.self) }
        print("📊 Downloaded tree has \(cachedCount) CMUs ending at height \(downloadedTreeHeight)")

        // 2. Initialize fresh tree
        guard ZipherXFFI.treeInit() else {
            print("❌ Failed to initialize tree")
            return nil
        }

        // 3. Load downloaded CMUs into tree
        print("🌳 Loading downloaded CMUs into tree...")
        if !ZipherXFFI.treeLoadFromCMUs(data: cachedData) {
            print("❌ Failed to load downloaded CMUs")
            return nil
        }

        let treeSize = ZipherXFFI.treeSize()
        print("✅ Tree now has \(treeSize) commitments")

        // 4. Fetch additional CMUs from blocks between downloadedTreeHeight+1 and noteHeight
        let startHeight = downloadedTreeHeight + 1
        print("📡 Fetching CMUs from blocks \(startHeight) to \(noteHeight)...")

        // Batch fetch all CMUs using P2P-first approach
        let allDeltaCMUs = await fetchCMUsFromBlocks(startHeight: startHeight, endHeight: noteHeight)
        print("📊 Got \(allDeltaCMUs.count) CMUs from blocks \(startHeight) to \(noteHeight)")

        var additionalCMUs: [Data] = []
        var notePosition: UInt64? = nil

        for blockCMU in allDeltaCMUs {
            // Check if this is our note's CMU
            if blockCMU == cmu {
                // Found our note! Append it and capture witness
                let position = ZipherXFFI.treeAppend(cmu: blockCMU)
                if position == UInt64.max {
                    print("❌ Failed to append note CMU")
                    return nil
                }

                // Create witness immediately after appending our note
                let witnessIndex = ZipherXFFI.treeWitnessCurrent()
                if witnessIndex == UInt64.max {
                    print("❌ Failed to create witness at note position")
                    return nil
                }

                // Continue adding remaining CMUs to update the witness
                notePosition = position
                print("✅ Found note CMU at position \(position)")

                additionalCMUs.append(blockCMU)
            } else if notePosition != nil {
                // After finding note, continue appending to update witness
                _ = ZipherXFFI.treeAppend(cmu: blockCMU)
                additionalCMUs.append(blockCMU)
            } else {
                // Before finding note, just append
                let pos = ZipherXFFI.treeAppend(cmu: blockCMU)
                if pos == UInt64.max {
                    print("⚠️ Failed to append CMU")
                }
                additionalCMUs.append(blockCMU)
            }
        }

        guard notePosition != nil else {
            print("❌ Note CMU not found in blocks \(startHeight)-\(noteHeight)")
            return nil
        }

        print("📊 Added \(additionalCMUs.count) CMUs from chain")
        print("📊 Final tree size: \(ZipherXFFI.treeSize())")

        // 5. Get the witness - it's index 0 since we only created one
        guard let witness = ZipherXFFI.treeGetWitness(index: 0) else {
            print("❌ Failed to get witness from tree")
            return nil
        }

        print("✅ Witness rebuilt: \(witness.count) bytes")

        // 6. Get the tree root - this is the anchor for the transaction
        guard let anchor = ZipherXFFI.treeRoot() else {
            print("❌ Failed to get tree root")
            return nil
        }

        let rootHex = anchor.map { String(format: "%02x", $0) }.joined()
        print("📝 Computed anchor from rebuilt tree: \(rootHex.prefix(16))...")

        // 7. CRITICAL: Save updated tree to database for future transactions
        // This avoids re-fetching CMUs from chain next time
        if let serializedTree = ZipherXFFI.treeSerialize() {
            try? WalletDatabase.shared.saveTreeState(serializedTree)
            print("💾 Updated tree state saved to database")
        }

        return (witness: witness, anchor: anchor)
    }

    /// Rebuild witnesses for MULTIPLE notes in a single tree-building pass
    /// This ensures all witnesses have the SAME anchor (required for multi-input transactions)
    /// Handles notes both within AND beyond the downloaded CMU range
    func rebuildWitnessesForNotes(
        notes: [SpendableNote],
        downloadedTreeHeight: UInt64
    ) async throws -> [(note: SpendableNote, witness: Data, anchor: Data)] {
        print("🔄 Rebuilding witnesses for \(notes.count) notes using boost + delta sync...")

        // Sort notes by height to process them in order
        let sortedNotes = notes.sorted { $0.height < $1.height }
        let maxNoteHeight = sortedNotes.last?.height ?? 0

        // 1. Collect all note CMUs from database (they're already stored there!)
        var allNoteCMUs: [Data] = []
        var cmuToNote: [Data: SpendableNote] = [:]
        for note in sortedNotes {
            guard let cmu = note.cmu else {
                print("❌ Note at height \(note.height) has no CMU")
                throw TransactionError.proofGenerationFailed
            }
            allNoteCMUs.append(cmu)
            cmuToNote[cmu] = note
            let status = note.height <= downloadedTreeHeight ? "(in boost)" : "(in delta)"
            print("   CMU: \(cmu.prefix(8).map { String(format: "%02x", $0) }.joined())... at height \(note.height) \(status)")
        }

        // 2. Extract CMUs from boost file in legacy format (fast bulk read)
        print("📦 Extracting CMUs from boost file...")
        let boostCMUData = try await CommitmentTreeUpdater.shared.extractCMUsInLegacyFormat { progress in
            if Int(progress * 100) % 10 == 0 {
                print("   Extracting boost CMUs: \(Int(progress * 100))%")
            }
        }

        // Parse CMU count from boost data
        guard boostCMUData.count >= 8 else { throw TransactionError.proofGenerationFailed }
        let boostCMUCount = boostCMUData.prefix(8).withUnsafeBytes { $0.load(as: UInt64.self) }
        print("📊 Boost file has \(boostCMUCount) CMUs up to height \(downloadedTreeHeight)")

        // 3. Fetch delta CMUs from chain (only blocks beyond boost file)
        var deltaCMUs: [Data] = []
        if maxNoteHeight > downloadedTreeHeight {
            let startHeight = downloadedTreeHeight + 1
            print("📡 Fetching delta CMUs from blocks \(startHeight) to \(maxNoteHeight)...")

            // Use batched P2P-first fetching (reduces log spam, works with Tor)
            deltaCMUs = await fetchCMUsFromBlocks(startHeight: startHeight, endHeight: maxNoteHeight)
            print("📊 Fetched \(deltaCMUs.count) delta CMUs from chain")
        }

        // 4. Build combined CMU data: boost + delta
        // Format: [count: UInt64 LE][cmu1: 32 bytes][cmu2: 32 bytes]...
        let totalCMUCount = boostCMUCount + UInt64(deltaCMUs.count)
        var combinedCMUData = Data(capacity: 8 + Int(totalCMUCount) * 32)

        // Write new count
        var count = totalCMUCount
        withUnsafeBytes(of: &count) { bytes in
            combinedCMUData.append(contentsOf: bytes)
        }

        // Append boost CMUs (skip the 8-byte header from boost data)
        combinedCMUData.append(boostCMUData.suffix(from: 8))

        // Append delta CMUs
        for cmu in deltaCMUs {
            combinedCMUData.append(cmu)
        }

        print("📊 Combined CMU data: \(totalCMUCount) CMUs (\(combinedCMUData.count) bytes)")

        // 5. Use batch witness creation (Rust parallel processing)
        print("🌳 Creating witnesses using batch processing...")
        let batchResults = ZipherXFFI.treeCreateWitnessesBatch(cmuData: combinedCMUData, targetCMUs: allNoteCMUs)

        // 6. Get anchor FROM THE FIRST WITNESS (NOT from global tree!)
        // CRITICAL: treeCreateWitnessesBatch builds its OWN local tree, NOT the global COMMITMENT_TREE.
        // So ZipherXFFI.treeRoot() returns the WRONG anchor - it returns the global tree's root.
        // We must extract the anchor from the witness data itself using witnessGetRoot().
        guard let firstResult = batchResults.first, let (_, firstWitness) = firstResult else {
            print("❌ Failed to create first witness")
            throw TransactionError.proofGenerationFailed
        }

        guard let anchor = ZipherXFFI.witnessGetRoot(firstWitness) else {
            print("❌ Failed to extract anchor from witness")
            throw TransactionError.proofGenerationFailed
        }
        let rootHex = anchor.map { String(format: "%02x", $0) }.joined()
        print("📝 Extracted anchor from witness (same for all): \(rootHex.prefix(16))...")

        // 7. Build results with same anchor for all (all witnesses from same batch have same root)
        var results: [(note: SpendableNote, witness: Data, anchor: Data)] = []
        for (index, result) in batchResults.enumerated() {
            guard let (position, witness) = result else {
                print("❌ Failed to create witness for note \(index + 1) at height \(sortedNotes[index].height)")
                throw TransactionError.proofGenerationFailed
            }
            let note = sortedNotes[index]
            results.append((note: note, witness: witness, anchor: anchor))
            print("   ✅ Note \(index + 1): position \(position), witness \(witness.count) bytes")
        }

        // 8. Save updated tree state to database
        if let serializedTree = ZipherXFFI.treeSerialize() {
            try? WalletDatabase.shared.saveTreeState(serializedTree)
            print("💾 Updated tree state saved to database")
        }

        print("✅ Rebuilt \(results.count) witnesses with SAME anchor using boost + delta")
        return results
    }

    /// Fetch CMUs from a range of blocks using P2P first, then InsightAPI fallback
    /// This batches requests to reduce log spam and uses P2P when Tor mode is enabled
    private func fetchCMUsFromBlocks(startHeight: UInt64, endHeight: UInt64) async -> [Data] {
        var allCMUs: [Data] = []
        let networkManager = NetworkManager.shared
        let torEnabled = await TorManager.shared.mode == .enabled

        // Try P2P first (especially important for Tor mode)
        if networkManager.isConnected, let peer = networkManager.getConnectedPeer() {
            print("📡 Fetching delta CMUs via P2P (blocks \(startHeight)-\(endHeight))...")

            let blockCount = Int(endHeight - startHeight + 1)
            do {
                let blocks = try await peer.getFullBlocks(from: startHeight, count: blockCount)
                for block in blocks {
                    for tx in block.transactions {
                        for output in tx.outputs {
                            // CMU from P2P is already in wire format (little-endian)
                            allCMUs.append(output.cmu)
                        }
                    }
                }
                print("📡 P2P: Got \(allCMUs.count) CMUs from \(blocks.count) blocks")
                return allCMUs
            } catch {
                print("⚠️ P2P fetch failed: \(error.localizedDescription)")
                // Fall through to InsightAPI if not in Tor mode
            }
        }

        // InsightAPI fallback (skip if Tor mode and API blocked)
        if torEnabled {
            print("⚠️ Skipping InsightAPI - Tor mode enabled and API likely blocked by Cloudflare")
            return allCMUs
        }

        // InsightAPI fallback (batch with reduced logging)
        print("📡 Fetching delta CMUs via InsightAPI (blocks \(startHeight)-\(endHeight))...")
        var failCount = 0

        for height in startHeight...endHeight {
            do {
                let blockCMUs = try await fetchCMUsViaInsight(height: height)
                allCMUs.append(contentsOf: blockCMUs)
            } catch {
                failCount += 1
                // Only log every 10th failure to reduce spam
                if failCount == 1 || failCount % 10 == 0 {
                    print("⚠️ Failed to fetch CMUs from block \(height): \(error.localizedDescription)")
                }
            }
        }

        if failCount > 0 {
            print("⚠️ Total InsightAPI failures: \(failCount)/\(endHeight - startHeight + 1) blocks")
        }

        return allCMUs
    }

    /// Fetch CMUs from a specific block height via Insight API
    private func fetchCMUsViaInsight(height: UInt64) async throws -> [Data] {
        let insightAPI = InsightAPI.shared

        // Get block hash
        let blockHash = try await insightAPI.getBlockHash(height: height)

        // Get block to get transaction IDs
        let block = try await insightAPI.getBlock(hash: blockHash)

        // Extract CMUs from shielded outputs of each transaction
        var cmus: [Data] = []

        for txid in block.tx {
            do {
                let tx = try await insightAPI.getTransaction(txid: txid)
                if let outputs = tx.vShieldedOutput {
                    for output in outputs {
                        if let cmuData = Data(hex: output.cmu) {
                            // CMU from Insight API is in big-endian (display format)
                            // Need to reverse to little-endian (wire format) for tree
                            let cmuLE = Data(cmuData.reversed())
                            cmus.append(cmuLE)
                        }
                    }
                }
            } catch {
                // Skip transactions that fail to fetch
                continue
            }
        }

        return cmus
    }

    // MARK: - Checkpoint-Based Tree Restoration

    /// Attempt to restore tree from a verified checkpoint
    /// Returns true if restoration successful, false if no valid checkpoint available
    private func tryRestoreFromCheckpoint(targetHeight: UInt64) async -> Bool {
        do {
            // Try to get a checkpoint at or before the target height
            guard let checkpoint = try WalletDatabase.shared.getTreeCheckpoint(atOrBefore: targetHeight) else {
                print("📍 No checkpoint available for height \(targetHeight)")
                return false
            }

            // Validate checkpoint against HeaderStore
            guard WalletDatabase.shared.validateTreeCheckpoint(checkpoint) else {
                print("⚠️ Checkpoint at height \(checkpoint.height) failed validation - will use fallback")
                return false
            }

            print("📍 Found valid checkpoint at height \(checkpoint.height) (target: \(targetHeight))")
            print("   CMU count: \(checkpoint.cmuCount)")
            print("   Tree root: \(checkpoint.treeRoot.prefix(8).hexString)...")

            // Restore tree from checkpoint serialized data
            guard ZipherXFFI.treeDeserialize(data: checkpoint.treeSerialized) else {
                print("⚠️ Failed to deserialize tree from checkpoint")
                return false
            }

            // Verify restored tree has correct root
            guard let restoredRoot = ZipherXFFI.treeRoot() else {
                print("⚠️ Restored tree has no root")
                return false
            }

            if restoredRoot != checkpoint.treeRoot {
                print("⚠️ Restored tree root doesn't match checkpoint")
                print("   Expected: \(checkpoint.treeRoot.hexString)")
                print("   Got:      \(restoredRoot.hexString)")
                return false
            }

            print("✅ Tree restored from checkpoint at height \(checkpoint.height)")

            // If checkpoint is behind target height, we need to sync forward
            if checkpoint.height < targetHeight {
                let blocksNeeded = targetHeight - checkpoint.height
                print("📍 Checkpoint is \(blocksNeeded) blocks behind target, syncing forward...")

                // Fetch and append CMUs for missing blocks
                let cmus = try await fetchCMUsForBlockRange(from: checkpoint.height + 1, to: targetHeight)
                if !cmus.isEmpty {
                    print("📍 Appending \(cmus.count) CMUs for blocks \(checkpoint.height + 1) to \(targetHeight)")
                    for cmu in cmus {
                        _ = ZipherXFFI.treeAppend(cmu: cmu)
                    }

                    // Verify tree root after appending
                    if let header = try? HeaderStore.shared.getHeader(at: targetHeight),
                       let newRoot = ZipherXFFI.treeRoot() {
                        if newRoot == header.hashFinalSaplingRoot {
                            print("✅ Tree synced forward and validated at height \(targetHeight)")
                            return true
                        } else {
                            print("⚠️ Tree root mismatch after forward sync - checkpoint may be stale")
                            return false
                        }
                    }
                }
            }

            return true

        } catch {
            print("⚠️ Checkpoint restoration failed: \(error)")
            return false
        }
    }

    /// Fetch CMUs for a range of blocks using P2P peers (preferred) or InsightAPI fallback
    /// Uses on-demand P2P which fetches headers directly via getheaders (no pre-synced HeaderStore required)
    private func fetchCMUsForBlockRange(from startHeight: UInt64, to endHeight: UInt64) async throws -> [Data] {
        // SAFETY: Prevent crash from integer underflow when startHeight > endHeight
        guard startHeight <= endHeight else {
            print("⚠️ fetchCMUsForBlockRange: Invalid range \(startHeight) to \(endHeight) - returning empty")
            return []
        }

        var allCMUs: [Data] = []
        let totalBlocks = Int(endHeight - startHeight + 1)

        print("🔗 Fetching CMUs for blocks \(startHeight)-\(endHeight) (\(totalBlocks) blocks)")

        // Use getBlocksOnDemandP2P which:
        // - Fetches headers on-demand via getheaders (NO pre-synced HeaderStore required!)
        // - Has multi-peer retry with reconnection logic
        // - Uses peer.getFullBlocks() which is fully decentralized
        do {
            let batchSize = 100  // P2P getheaders returns max 160 headers per request
            var currentStart = startHeight

            while currentStart <= endHeight {
                let batchEnd = min(currentStart + UInt64(batchSize) - 1, endHeight)
                let batchCount = Int(batchEnd - currentStart + 1)

                let blocks = try await NetworkManager.shared.getBlocksOnDemandP2P(from: currentStart, count: batchCount)

                for block in blocks {
                    for tx in block.transactions {
                        for output in tx.outputs {
                            // CMU from CompactBlock.CompactOutput is already in wire format (little-endian)
                            allCMUs.append(output.cmu)
                        }
                    }
                }

                print("📦 P2P batch: \(currentStart)-\(batchEnd) → \(blocks.count) blocks")
                currentStart = batchEnd + 1
            }

            print("✅ P2P on-demand fetch complete: \(allCMUs.count) CMUs from \(totalBlocks) blocks")
            return allCMUs

        } catch NetworkError.notConnected {
            print("⚠️ P2P not connected")
        } catch NetworkError.p2pFetchFailed {
            print("⚠️ P2P fetch failed")
        } catch {
            print("⚠️ P2P fetch error: \(error.localizedDescription)")
        }

        // CRITICAL: When Tor is enabled, do NOT use InsightAPI (blocked by Cloudflare)
        // Only P2P works through Tor - if P2P fails, we must fail the operation
        let torEnabled = await TorManager.shared.mode == .enabled
        if torEnabled {
            print("🧅 Tor enabled - InsightAPI fallback DISABLED (Cloudflare blocks Tor)")
            print("❌ P2P CMU fetch failed and no fallback available")
            throw NetworkError.p2pFetchFailed
        }

        // InsightAPI fallback - ONLY when Tor is disabled
        print("📡 Attempting InsightAPI fallback for \(totalBlocks) blocks...")

        let batchSize = 50
        var currentStart = startHeight
        var insightErrors = 0

        while currentStart <= endHeight {
            let batchEnd = min(currentStart + UInt64(batchSize) - 1, endHeight)

            for height in currentStart...batchEnd {
                do {
                    let cmus = try await fetchCMUsViaInsight(height: height)
                    allCMUs.append(contentsOf: cmus)
                } catch {
                    insightErrors += 1
                    if insightErrors <= 3 {
                        print("⚠️ InsightAPI failed for block \(height): \(error.localizedDescription)")
                    }
                    // Continue to next block, don't abort entirely
                }
            }
            currentStart = batchEnd + 1
        }

        if insightErrors > 0 {
            print("⚠️ InsightAPI had \(insightErrors) errors out of \(totalBlocks) blocks")
        }

        if allCMUs.isEmpty && totalBlocks > 0 {
            throw NetworkError.p2pFetchFailed
        }

        print("✅ InsightAPI fallback complete: \(allCMUs.count) CMUs")
        return allCMUs
    }
}

// MARK: - Supporting Types

struct SpendableNote {
    let value: UInt64
    let anchor: Data
    let witness: Data
    let diversifier: Data
    let rcm: Data // note randomness
    let position: UInt64 // position in note commitment tree
    let nullifier: Data // nullifier for spending detection
    let height: UInt64 // block height where note was received
    let cmu: Data? // note commitment - needed for witness rebuild
}

// MARK: - Transaction Errors

enum TransactionError: LocalizedError {
    case invalidAddress
    case insufficientFunds
    case proofGenerationFailed
    case signingFailed
    case serializationFailed
    case noteLargeEnough(largestNote: UInt64, required: UInt64)
    case memoTooLong(length: Int, max: Int)  // VUL-020
    case dustOutput(amount: UInt64, threshold: UInt64)  // VUL-024

    var errorDescription: String? {
        switch self {
        case .invalidAddress:
            return "Invalid z-address"
        case .insufficientFunds:
            return "Insufficient funds"
        case .proofGenerationFailed:
            return "Failed to generate zero-knowledge proof"
        case .signingFailed:
            return "Failed to sign transaction"
        case .serializationFailed:
            return "Failed to serialize transaction"
        case .noteLargeEnough(let largestNote, let required):
            let maxSendable = largestNote > 10000 ? largestNote - 10000 : 0
            let maxZCL = Double(maxSendable) / 100_000_000
            return "No single note large enough. Your largest note is \(String(format: "%.4f", Double(largestNote) / 100_000_000)) ZCL. Max you can send: \(String(format: "%.4f", maxZCL)) ZCL (multi-note spending coming soon)"
        case .memoTooLong(let length, let max):
            return "Memo too long: \(length) bytes (maximum \(max) bytes)"
        case .dustOutput(let amount, let threshold):
            let amountZCL = Double(amount) / 100_000_000
            let thresholdZCL = Double(threshold) / 100_000_000
            return "Output too small: \(String(format: "%.8f", amountZCL)) ZCL (minimum \(String(format: "%.8f", thresholdZCL)) ZCL to cover fees)"
        }
    }
}
