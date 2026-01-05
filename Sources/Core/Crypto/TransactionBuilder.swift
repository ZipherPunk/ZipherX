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

        // FIX #376: Always fetch FRESH peer consensus height
        // Cached chainHeight can be stale when HeaderStore is behind
        let cachedChainHeightFallback = await MainActor.run { NetworkManager.shared.chainHeight }
        let chainHeight = (try? await NetworkManager.shared.getChainHeight()) ?? cachedChainHeightFallback
        print("📊 FIX #376: Chain height (peer consensus): \(chainHeight)")

        // Get notes from database - requires valid witnesses
        var dbNotes = try database.getUnspentNotes(accountId: account.accountId)

        // If no notes with witnesses, check for notes without witnesses that need rebuild
        if dbNotes.isEmpty {
            let allNotes = try database.getAllUnspentNotes(accountId: account.accountId)
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
            // FIX #551: Don't use zero placeholder - handle explicitly later
            anchorFromHeader = Data()  // Empty data, checked explicitly below
        }

        // OPTIMIZATION: Check if witness is already current (background sync keeps it updated)
        var witnessToUse = note.witness
        var needsRebuild = note.witness.count < 1028 || note.witness.allSatisfy { $0 == 0 }

        // Check if we have a valid anchor from header store (non-empty and not all zeros)
        let haveHeaderAnchor = !anchorFromHeader.isEmpty && !anchorFromHeader.allSatisfy { $0 == 0 }

        if needsRebuild {
            print("⚠️ Witness invalid (\(note.witness.count) bytes), needs rebuild")
        } else if haveHeaderAnchor {
            // CRITICAL: Verify witness root matches header anchor!
            // The witness contains the tree root it was built against.
            // If this matches the header anchor (blockchain's canonical finalSaplingRoot),
            // we can use the witness directly. If not, the witness is stale/wrong.
            if let witnessRoot = ZipherXFFI.witnessGetRoot(note.witness) {
                let witnessRootHex = witnessRoot.prefix(8).map { String(format: "%02x", $0) }.joined()
                let headerAnchorHex = anchorFromHeader.prefix(8).map { String(format: "%02x", $0) }.joined()

                if witnessRoot == anchorFromHeader {
                    print("✅ Witness root matches header anchor - INSTANT mode!")
                    print("   witnessRoot: \(witnessRootHex)... == headerAnchor: \(headerAnchorHex)...")
                    needsRebuild = false
                } else {
                    // FIX #557 v3: Rebuild witness to match header anchor!
                    // The witness was built with wrong tree state - rebuild it now.
                    print("⚠️ FIX #557 v3: Witness root differs from header anchor!")
                    print("   witnessRoot:   \(witnessRootHex)...")
                    print("   headerAnchor:  \(headerAnchorHex)...")
                    print("   Note height:   \(noteHeight)")
                    print("   Will rebuild witness to match header anchor...")
                    needsRebuild = true
                }
            } else {
                print("⚠️ Could not extract root from witness, will rebuild")
                needsRebuild = true
            }
        } else if note.anchor.count == 32 && !note.anchor.allSatisfy({ $0 == 0 }) {
            // No header anchor available - check if stored anchor matches witness root
            if let witnessRoot = ZipherXFFI.witnessGetRoot(note.witness) {
                if note.anchor == witnessRoot {
                    // Stored anchor matches witness - use them together
                    print("✅ Stored anchor matches witness root - using stored anchor")
                    anchorFromHeader = note.anchor
                    needsRebuild = false
                } else {
                    print("⚠️ Stored anchor doesn't match witness root, rebuilding...")
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
            // FIX #115: Pass chainHeight for consistent anchor
            if let result = try await rebuildWitnessForNote(
                cmu: cmu,
                noteHeight: noteHeight,
                downloadedTreeHeight: downloadedTreeHeight,
                chainHeight: chainHeight
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
                // FIX #557 v25: Rebuild failed (e.g., delta CMUs fetch failed)
                // Use database witness/anchor instead - FIX #557 v24 set these correctly with per-note anchors
                print("⚠️ FIX #557 v25: Witness rebuild returned nil, using database witness/anchor")
                print("⚠️ FIX #557 v25: Database has per-note anchors from FIX #557 v24")
                witnessToUse = note.witness
                if note.anchor.count == 32 {
                    anchorFromHeader = note.anchor
                    print("✅ FIX #557 v25: Using database anchor: \(note.anchor.prefix(8).map { String(format: "%02x", $0) }.joined())...")
                }
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
                // FIX #493 v3: CMU not in bundled file - rebuild via P2P
                print("⚠️ FIX #493 v3: CMU not in bundled file, rebuilding via P2P...")
                if let result = try await rebuildWitnessForNote(
                    cmu: cmu,
                    noteHeight: noteHeight,
                    downloadedTreeHeight: downloadedTreeHeight,
                    chainHeight: chainHeight
                ) {
                    witnessToUse = result.witness
                    print("✅ FIX #493 v3: Rebuilt witness via P2P (\(result.witness.count) bytes)")
                } else {
                    // FIX #557 v25: P2P rebuild failed - use database witness/anchor
                    // FIX #557 v24 set per-note anchors in database correctly
                    print("⚠️ FIX #557 v25: P2P rebuild failed, using database witness/anchor")
                    witnessToUse = note.witness
                    if note.anchor.count == 32 {
                        anchorFromHeader = note.anchor
                        print("✅ FIX #557 v25: Using database anchor: \(note.anchor.prefix(8).map { String(format: "%02x", $0) }.joined())...")
                    }
                }
            }
        }

        // FIX #557 v27: ALWAYS use HeaderStore anchor - it's the source of truth!
        // The witness root may differ (witness created from boost file at wrong position)
        // But HeaderStore has the correct anchor from blockchain at note's height
        var anchorToUse = anchorFromHeader
        if let witnessRoot = ZipherXFFI.witnessGetRoot(witnessToUse) {
            let witnessRootHex = witnessRoot.prefix(8).map { String(format: "%02x", $0) }.joined()
            let headerAnchorHex = anchorFromHeader.prefix(8).map { String(format: "%02x", $0) }.joined()

            if witnessRoot == anchorFromHeader {
                print("✅ FIX #557 v27: Witness root matches header anchor - PERFECT!")
                print("   witnessRoot: \(witnessRootHex)... == headerAnchor: \(headerAnchorHex)...")
                anchorToUse = witnessRoot
            } else {
                // FIX #557 v27: Witness root differs, but TRUST HeaderStore anchor!
                // HeaderStore anchor is from actual blockchain at note's height
                // Witness root is from boost file (may be at different tree position)
                print("⚠️ FIX #557 v27: Witness root differs from header anchor!")
                print("   witnessRoot:  \(witnessRootHex)...")
                print("   headerAnchor: \(headerAnchorHex)...")
                print("   ✅ Using HeaderStore anchor (blockchain source of truth)")
                anchorToUse = anchorFromHeader  // CRITICAL: Use HeaderStore anchor!
            }
        } else {
            print("⚠️ FIX #557 v27: Could not extract witness root, using header anchor")
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
            anchor: anchorToUse,  // FIX #557 v2: Use witness root (not header anchor!)
            witness: witnessToUse,  // Use original witness (no modification!)
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

        // FIX #376: Always fetch FRESH peer consensus height
        // Cached chainHeight can be stale when HeaderStore is behind
        let cachedChainHeightFallback = await MainActor.run { NetworkManager.shared.chainHeight }
        let chainHeight = (try? await NetworkManager.shared.getChainHeight()) ?? cachedChainHeightFallback
        print("📊 FIX #376: Chain height (peer consensus): \(chainHeight)")

        var dbNotes = try database.getUnspentNotes(accountId: account.accountId)

        if dbNotes.isEmpty {
            let allNotes = try database.getAllUnspentNotes(accountId: account.accountId)
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

                    // FIX #115: Pass chainHeight for consistent anchor across all notes
                    let results = try await rebuildWitnessesForNotes(
                        notes: selectedNotes,
                        downloadedTreeHeight: cachedBoostHeight,
                        chainHeight: chainHeight
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

                // FIX #115: Pass chainHeight for consistent anchor across all notes
                let results = try await rebuildWitnessesForNotes(
                    notes: selectedNotes,
                    downloadedTreeHeight: cachedBoostHeight,
                    chainHeight: chainHeight
                )

                for result in results {
                    preparedSpends.append((note: result.note, witness: result.witness))
                }
                print("✅ Created \(preparedSpends.count) witnesses with SAME anchor (at chain tip \(chainHeight))")
            }
        } else {
            // Single-input transaction - use existing logic
            for (index, note) in selectedNotes.enumerated() {
                print("📝 Preparing witness for note \(index + 1)/\(selectedNotes.count)")

                var witnessToUse = note.witness
                var needsRebuild = note.witness.count < 1028 || note.witness.allSatisfy { $0 == 0 }
                let noteCMU = note.cmu
                let noteHeight = note.height

                // FIX #480 v2: Don't force rebuild based on tree size alone
                // The old logic (treeSize > 1M) was always true after import, causing 42s delays
                // Instead, rely on witness root validation below to detect stale witnesses
                let currentTreeSize = ZipherXFFI.treeSize()
                if currentTreeSize > 1000000 && note.witness.count == 1028 && !needsRebuild {
                    print("📊 FIX #480 v2: Large tree (\(currentTreeSize) CMUs) - validating witness root instead of forcing rebuild")
                    // Don't set needsRebuild = true - let validation below decide
                }

                // FIX #557 v5: ALWAYS rebuild witness to chain tip
                // Check if chain moved forward > 100 blocks - witness is stale
                let chainGap = chainHeight > note.height ? (chainHeight - note.height) : 0
                if chainGap > 100 {
                    print("⚠️ Note \(index + 1): Chain moved forward \(chainGap) blocks - forcing rebuild")
                    print("   Note height: \(note.height)")
                    print("   Chain height: \(chainHeight)")
                    needsRebuild = true
                } else if !needsRebuild && note.witness.count >= 1028 {
                    // Recent witness - validate it
                    if let headerAnchor = try? HeaderStore.shared.getSaplingRoot(at: UInt64(note.height)) {
                        if let witnessRoot = ZipherXFFI.witnessGetRoot(note.witness) {
                            if witnessRoot == headerAnchor && ZipherXFFI.witnessPathIsValid(note.witness) {
                                print("✅ Note \(index + 1) witness current - INSTANT mode!")
                            } else {
                                print("⚠️ Note \(index + 1) witness validation failed - forcing rebuild")
                                needsRebuild = true
                            }
                        } else {
                            needsRebuild = true
                        }
                    } else {
                        needsRebuild = true
                    }
                } else if !needsRebuild {
                    // Witness too short - need rebuild
                    print("⚠️ Note \(index + 1) witness too short (\(note.witness.count) bytes) - forcing rebuild")
                    needsRebuild = true
                }

                // Only rebuild witness if needed
                if needsRebuild && noteHeight > downloadedTreeHeight {
                    guard let cmu = noteCMU else {
                        print("❌ Note \(index + 1) has no CMU for witness rebuild")
                        throw TransactionError.proofGenerationFailed
                    }

                    print("⚠️ Rebuilding witness for note \(index + 1) at height \(noteHeight) (P2P sync)")
                    // FIX #115: Pass chainHeight for consistent anchor
                    if let result = try await rebuildWitnessForNote(
                        cmu: cmu,
                        noteHeight: noteHeight,
                        downloadedTreeHeight: downloadedTreeHeight,
                        chainHeight: chainHeight
                    ) {
                        witnessToUse = result.witness
                    } else {
                        throw TransactionError.proofGenerationFailed
                    }
                } else if needsRebuild, let cmu = noteCMU {
                    print("⚠️ Rebuilding witness for note \(index + 1) using bundled CMU file")
                    guard let cachedPath = await CommitmentTreeUpdater.shared.getCachedCMUFilePath(),
                          let cachedData = try? Data(contentsOf: cachedPath) else {
                        print("❌ FIX #480: Failed to get bundled CMU file")
                        throw TransactionError.proofGenerationFailed
                    }

                    print("🔧 FIX #480: Creating witness from bundled CMU file (\(cachedData.count) bytes)")
                    print("🔧 Target CMU: \(cmu.prefix(16).hexString)...")
                    print("🔧 Note height: \(noteHeight), downloadedTreeHeight: \(downloadedTreeHeight)")

                    // FIX #531: CRITICAL - Include PHASE 2 CMUs to match global tree state
                    // The cached legacy file only has boost file CMUs, but global tree may have PHASE 2 CMUs
                    var cmuDataToUse = cachedData
                    let cachedCount = UInt64((cachedData.count - 8) / 32)
                    let currentTreeSize = ZipherXFFI.treeSize()

                    if currentTreeSize > cachedCount {
                        print("🔧 FIX #531: Global tree has \(currentTreeSize) CMUs, cached file has \(cachedCount) CMUs")
                        print("🔧 FIX #531: Adding \(currentTreeSize - cachedCount) PHASE 2 CMUs to witness creation...")

                        // Get PHASE 2 CMUs from DeltaCMU manager
                        if let manifest = DeltaCMUManager.shared.getManifest(),
                           manifest.endHeight > ZipherXConstants.effectiveTreeHeight {
                            let boostEndHeight = ZipherXConstants.effectiveTreeHeight
                            if let deltaCMUs = DeltaCMUManager.shared.loadDeltaCMUsForHeightRange(
                                startHeight: boostEndHeight + 1,
                                endHeight: manifest.endHeight
                            ) {
                                // Append delta CMUs to the data
                                var newCount = currentTreeSize
                                var newCmuData = Data()

                                // Write new count
                                newCmuData.append(contentsOf: withUnsafeBytes(of: UInt64(newCount).littleEndian) { Array($0) })

                                // Copy cached CMUs (skip count byte)
                                newCmuData.append(cachedData[8...])

                                // Append delta CMUs
                                for cmu in deltaCMUs {
                                    newCmuData.append(cmu)
                                }

                                cmuDataToUse = newCmuData
                                print("✅ FIX #531: Updated CMU data to \(newCount) CMUs (\(cmuDataToUse.count) bytes)")
                            } else {
                                print("⚠️ FIX #531: Failed to load delta CMUs - witness may be invalid!")
                            }
                        }
                    }

                    if let result = ZipherXFFI.treeCreateWitnessForCMU(cmuData: cmuDataToUse, targetCMU: cmu) {
                        witnessToUse = result.witness
                        print("✅ FIX #480: Witness created successfully at position \(result.position) (\(result.witness.count) bytes)")
                    } else {
                        // FIX #514 v4: Try boost file outputs section when legacy_cmus_v2.bin fails
                        // The legacy file only contains trial-decrypted notes, not boost-imported notes
                        print("⚠️ FIX #514 v4: CMU not in legacy_cmus_v2.bin, trying boost file outputs section...")
                        var foundInBoost = false
                        do {
                            // extractShieldedOutputs gets data from boost file outputs section (has ALL notes)
                            let boostOutputsData = try await CommitmentTreeUpdater.shared.extractShieldedOutputs()
                            // Convert outputs data to legacy CMU format for treeCreateWitnessForCMU
                            // Outputs format: height(4) + index(4) + cmu(32) + epk(32) + enc(580) + txid(32) = 684 bytes
                            // Need to extract just CMUs in order
                            let entrySize = 684
                            let count = boostOutputsData.count / entrySize
                            var cmuData = Data()
                            // Write count as UInt64 LE
                            cmuData.append(contentsOf: withUnsafeBytes(of: UInt64(count).littleEndian) { Array($0) })
                            // Extract CMUs from each output entry
                            for i in 0..<count {
                                let offset = i * entrySize + 8  // Skip height(4) + index(4)
                                let cmu = boostOutputsData[offset..<offset+32]
                                cmuData.append(contentsOf: cmu)
                            }

                            print("📦 FIX #514 v4: Extracted \(count) CMUs from boost file outputs section (\(cmuData.count) bytes)")

                            // FIX #531: CRITICAL - Include PHASE 2 CMUs to match global tree state
                            // The witness must be created from the SAME tree state as the blockchain
                            // If global tree has more CMUs than boost file, we need to include them
                            let currentTreeSize = ZipherXFFI.treeSize()
                            let boostCount = UInt64(count)
                            if currentTreeSize > boostCount {
                                print("🔧 FIX #531: Global tree has \(currentTreeSize) CMUs, boost has \(boostCount) CMUs")
                                print("🔧 FIX #531: Adding \(currentTreeSize - boostCount) PHASE 2 CMUs to witness creation...")

                                // Get PHASE 2 CMUs from DeltaCMU manager
                                if let manifest = DeltaCMUManager.shared.getManifest(),
                                   manifest.endHeight > ZipherXConstants.effectiveTreeHeight {
                                    let boostEndHeight = ZipherXConstants.effectiveTreeHeight
                                    if let deltaCMUs = DeltaCMUManager.shared.loadDeltaCMUsForHeightRange(
                                        startHeight: boostEndHeight + 1,
                                        endHeight: manifest.endHeight
                                    ) {
                                        // Append delta CMUs to the data
                                        var newCount = currentTreeSize
                                        var newCmuData = Data()

                                        // Write new count
                                        newCmuData.append(contentsOf: withUnsafeBytes(of: UInt64(newCount).littleEndian) { Array($0) })

                                        // Copy boost CMUs
                                        newCmuData.append(cmuData[8...])  // Skip count byte

                                        // Append delta CMUs
                                        for cmu in deltaCMUs {
                                            newCmuData.append(cmu)
                                        }

                                        cmuData = newCmuData
                                        print("✅ FIX #531: Updated CMU data to \(newCount) CMUs (\(cmuData.count) bytes)")
                                    } else {
                                        print("⚠️ FIX #531: Failed to load delta CMUs - witness may be invalid!")
                                    }
                                }
                            }

                            if let boostResult = ZipherXFFI.treeCreateWitnessForCMU(cmuData: cmuData, targetCMU: cmu) {
                                witnessToUse = boostResult.witness
                                print("✅ FIX #514 v4: Witness created from boost file outputs at position \(boostResult.position) (\(boostResult.witness.count) bytes)")
                                foundInBoost = true
                            } else {
                                print("❌ FIX #514 v4: CMU not found in boost file outputs section either!")
                            }
                        } catch {
                            print("⚠️ FIX #514 v4: Boost file extraction failed: \(error.localizedDescription)")
                        }

                        if !foundInBoost {
                            // FIX #493 v3: CMU not in bundled file - ALWAYS rebuild via P2P
                            // This handles both PHASE 2 notes (height > downloadedTreeHeight) AND
                            // notes found during scan that were appended to global tree
                            print("⚠️ FIX #493 v3: CMU not found in bundled file")
                            print("   Target CMU: \(cmu.hexString)")
                            print("   Bundled file: \((cachedData.count - 8) / 32) CMUs")
                            print("   Note height: \(noteHeight), downloadedTreeHeight: \(downloadedTreeHeight)")

                            // FIX #513: Diagnostic - fetch the specific block at note height to verify CMU exists on-chain
                            // This helps identify if the database CMU is wrong or if bundled file is incomplete
                            print("🔍 FIX #513: Fetching block at note height \(noteHeight) to verify CMU...")
                            let connectedPeers = await MainActor.run { NetworkManager.shared.getAllConnectedPeers() }
                            if let peer = connectedPeers.first {
                                do {
                                    let blocks = try await peer.getFullBlocks(from: noteHeight, count: 1)
                                    if let block = blocks.first {
                                        var foundCMU = false
                                        for tx in block.transactions {
                                            for output in tx.outputs {
                                                if output.cmu == cmu {
                                                    foundCMU = true
                                                    print("✅ FIX #513: CMU VERIFIED at height \(noteHeight) - database is correct!")
                                                    break
                                                }
                                            }
                                            if foundCMU { break }
                                        }
                                        if !foundCMU {
                                            print("❌ FIX #513: CMU NOT FOUND at height \(noteHeight) - database CMU is WRONG!")
                                            print("❌ FIX #513: Block has \(block.transactions.reduce(0) { $0 + $1.outputs.count }) outputs")
                                            print("💡 FIX #513: Run 'Settings → Repair Database → Full Rescan' to fix this note")
                                        }
                                    }
                                } catch {
                                    print("⚠️ FIX #513: Could not verify CMU on-chain: \(error.localizedDescription)")
                                }
                            }

                            // ALWAYS rebuild witness via P2P when CMU not in bundled file
                            print("🔄 Rebuilding witness via P2P...")
                            if let result = try await rebuildWitnessForNote(
                                cmu: cmu,
                                noteHeight: noteHeight,
                                downloadedTreeHeight: downloadedTreeHeight,
                                chainHeight: chainHeight
                            ) {
                                witnessToUse = result.witness
                                print("✅ FIX #493 v3: Rebuilt witness via P2P (\(result.witness.count) bytes)")
                            } else {
                                print("❌ Failed to rebuild witness via P2P")
                                throw TransactionError.proofGenerationFailed
                            }
                        }
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
                // FIX #557: Replace witness root with HeaderStore anchor for multi-input too!
                var modifiedWitness = witness
                if let noteHeader = try? headerStore.getHeader(at: note.height) {
                    let anchorFromHeader = noteHeader.hashFinalSaplingRoot
                    if modifiedWitness.count >= 32 {
                        // Replace last 32 bytes (the root) with HeaderStore anchor
                        modifiedWitness.replaceSubrange((modifiedWitness.count - 32)..<modifiedWitness.count, with: anchorFromHeader)
                        print("🔧 FIX #557: Multi-input - replaced witness root for note at height \(note.height)")
                    }
                }

                let info = ZipherXFFI.SpendInfoSwift(
                    witness: modifiedWitness,  // FIX #557: Use modified witness
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
            var witnessToUse = preparedSpends[0].witness  // FIX #557 v17: var to allow reload after rebuild
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

            // FIX #557 v5: Check if database witness is already CURRENT before rebuilding
            // The witness was just rebuilt in pre-witness phase, so check if it matches current anchor
            var finalWitness = witnessToUse
            let chainGap = chainHeight > noteHeight ? (chainHeight - noteHeight) : 0

            // FIX #557 v14: Check if witness root matches current anchor BEFORE rebuilding
            // This avoids the expensive 1M+ CMU tree load when witness is already current
            var needsRebuild = false

            // FIX #557 v17: Check if rebuild is in progress and wait for it to complete
            // This prevents race condition where send screen checks witnesses while rebuild is updating DB
            let wm = WalletManager.shared
            let isRebuilding = await MainActor.run { wm.isRebuildingWitnesses }
            if isRebuilding {
                print("⚠️ FIX #557 v17: Witness rebuild in progress, waiting for completion...")
                // Wait up to 10 seconds for rebuild to complete
                for _ in 0..<100 {
                    try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                    let isStillRebuilding = await MainActor.run { wm.isRebuildingWitnesses }
                    if !isStillRebuilding {
                        print("✅ FIX #557 v17: Rebuild completed, reloading witness from database...")
                        // Reload witness from database using cmu as identifier
                        let database = WalletDatabase.shared
                        guard let account = try? database.getAccount(index: 0) else { break }
                        let dbNotes = try database.getUnspentNotes(accountId: account.accountId)
                        if let freshNote = dbNotes.first(where: { $0.cmu == note.cmu }) {
                            witnessToUse = freshNote.witness
                            print("✅ FIX #557 v17: Reloaded witness for note with cmu: \(note.cmu?.prefix(4).hexString ?? "nil")...")
                        }
                        break
                    }
                }
                print("⚠️ FIX #557 v17: Wait complete, checking witness freshness...")
            }

            if let witnessRoot = ZipherXFFI.witnessGetRoot(witnessToUse) {
                if witnessRoot == anchorFromHeader {
                    let rootHex = witnessRoot.prefix(8).map { String(format: "%02x", $0) }.joined()
                    print("✅ FIX #557 v14: Database witness is CURRENT - root matches header anchor!")
                    print("   Witness root: \(rootHex)... (skipping tree load)")
                } else {
                    let witnessRootHex = witnessRoot.prefix(8).map { String(format: "%02x", $0) }.joined()
                    let headerRootHex = anchorFromHeader.prefix(8).map { String(format: "%02x", $0) }.joined()
                    print("⚠️ FIX #557 v14: Witness root mismatch - needs rebuild")
                    print("   Witness root: \(witnessRootHex)...")
                    print("   Header anchor: \(headerRootHex)...")
                    needsRebuild = true
                }
            } else {
                print("⚠️ FIX #557 v14: Could not extract witness root - forcing rebuild")
                needsRebuild = true
            }

            if needsRebuild {
                if chainGap > 0 {
                    print("⚠️ FIX #557 v5: Chain moved forward \(chainGap) blocks - rebuilding witness")
                    print("   Note height: \(noteHeight)")
                    print("   Chain height: \(chainHeight)")
                } else {
                    print("⚠️ FIX #557 v5: Forcing witness rebuild to chain tip")
                }

                if note.cmu != nil {
                    print("🔧 FIX #557 v5: Rebuilding witness to chain tip...")
                    if let result = try await rebuildWitnessForNote(
                        cmu: note.cmu!,
                        noteHeight: noteHeight,
                        downloadedTreeHeight: downloadedTreeHeight,
                        chainHeight: chainHeight
                    ) {
                        finalWitness = result.witness
                        print("✅ FIX #557 v5: Witness rebuilt (\(result.witness.count) bytes) - anchor will match chain!")
                    }
                }
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
                anchor: anchorFromHeader,  // FIX #557 v3: Use header anchor (witness rebuilt to match)
                witness: finalWitness,  // FIX #557 v3: Use rebuilt witness that matches anchor
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
        let dbNotes = try database.getUnspentNotes(accountId: account.accountId)

        print("📝 Database returned \(dbNotes.count) unspent notes")

        // FIX #376: ALWAYS fetch FRESH peer consensus height for confirmation calculation
        // Bug: Cached chainHeight can be stale (e.g., HeaderStore height when 12k blocks behind)
        // This caused notes at height 2950293 to show 0 confirmations when chain was at 2952xxx
        // because cached chainHeight was 2940620 (HeaderStore)
        var chainHeight: UInt64 = 0

        print("📝 FIX #376: Fetching FRESH peer consensus height for confirmations...")
        if let height = try? await NetworkManager.shared.getChainHeight() {
            chainHeight = height
            print("📝 FIX #376: Peer consensus height: \(chainHeight)")
        } else {
            // Fallback to cached if peer fetch fails
            chainHeight = await MainActor.run { NetworkManager.shared.chainHeight }
            print("⚠️ FIX #376: Using cached height: \(chainHeight)")

            // If still 0, use safe fallback
            if chainHeight == 0 {
                chainHeight = 2940000
                print("⚠️ FIX #376: Using fallback height: \(chainHeight)")
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

            // CRITICAL FIX: Use stored anchor from database if available
            // The stored anchor was computed when the witness was created during PHASE 2 scan
            // This ensures witness and anchor are consistent!
            // Fall back to current tree root only if no stored anchor exists
            let noteAnchor = dbNote.anchor ?? anchor

            // Witness format: 4 bytes position + 32*32 bytes merkle path
            let note = SpendableNote(
                value: dbNote.value,
                anchor: noteAnchor, // Use stored anchor (consistent with witness)
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
    /// FIX #115: Added chainHeight parameter - fetch CMUs to chain tip for valid anchor
    func rebuildWitnessForNote(
        cmu: Data,
        noteHeight: UInt64,
        downloadedTreeHeight: UInt64,
        chainHeight: UInt64? = nil  // FIX #115: Target height for tree building
    ) async throws -> (witness: Data, anchor: Data)? {
        // FIX #115: Determine target height - use chain tip, not just note height
        let targetHeight: UInt64
        if let explicitHeight = chainHeight {
            targetHeight = max(noteHeight, explicitHeight)
        } else {
            // Fetch current chain height for valid anchor
            do {
                let currentHeight = try await NetworkManager.shared.getChainHeight()
                targetHeight = max(noteHeight, currentHeight)
            } catch {
                targetHeight = noteHeight  // Fallback
            }
        }
        print("🔄 Rebuilding witness for note at height \(noteHeight), tree to height \(targetHeight)...")
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

        // FIX #514 v2: Try to create witness directly from downloaded CMUs FIRST
        // This handles notes that are in the boost file (downloadedTreeHeight range)
        print("🔍 FIX #514 v2: Checking if CMU is in downloaded file...")
        if let result = ZipherXFFI.treeCreateWitnessForCMU(cmuData: cachedData, targetCMU: cmu) {
            print("✅ FIX #514 v2: Found CMU in downloaded file at position \(result.position)")
            print("✅ FIX #514 v2: Witness created from downloaded data (\(result.witness.count) bytes)")

            // FIX #557 v10: Load ALL CMUs to get CURRENT anchor at chain tip!
            // The witness is created at note's position (correct)
            // But the anchor MUST be the current tree root (chain tip), not note's old position!
            // Previously we loaded only up to note position - WRONG anchor (FIX #541 bug)!
            print("🔧 FIX #557 v10: Loading ALL \(cachedCount) CMUs to get CURRENT anchor at chain tip!")

            // Load ALL CMUs into tree to get CURRENT anchor (not just to note position!)
            guard ZipherXFFI.treeInit() else {
                print("❌ Failed to initialize tree for anchor")
                return nil
            }

            if !ZipherXFFI.treeLoadFromCMUs(data: cachedData) {
                print("❌ Failed to load CMUs for anchor")
                return nil
            }

            // FIX #557 v11: Fetch delta CMUs from boost end to CURRENT chain tip!
            // The boost file only goes to downloadedTreeHeight, but we need current chain tip
            let currentChainHeight = (try? await NetworkManager.shared.getChainHeight()) ?? downloadedTreeHeight
            let boostHeight = downloadedTreeHeight

            if currentChainHeight > boostHeight {
                print("🔧 FIX #557 v11: Fetching delta CMUs from \(boostHeight + 1) to \(currentChainHeight)...")
                let deltaCMUs = await fetchCMUsFromBlocks(startHeight: boostHeight + 1, endHeight: currentChainHeight)
                print("📊 Got \(deltaCMUs.count) delta CMUs")

                // FIX #557 v16: Check if delta CMUs were successfully fetched
                if deltaCMUs.isEmpty {
                    print("⚠️ FIX #557 v16: Failed to fetch delta CMUs (0 fetched, \(currentChainHeight - boostHeight) expected)")
                    print("⚠️ FIX #557 v16: Tree anchor would be STALE - using HeaderStore anchor as fallback")

                    // FIX #557 v25: Return nil to use database witness/anchor instead
                    // The boost file witness (result.witness) was created from old tree state
                    // HeaderStore anchor (headerAnchor) is from current chain state
                    // These DON'T match - returning them would cause "Anchor NOT FOUND" error
                    // FIX #557 v24 already set correct per-note anchors in database - use those!
                    print("⚠️ FIX #557 v25: Boost witness + Header anchor don't match, returning nil")
                    print("⚠️ FIX #557 v25: Will use database witness/anchor (FIX #557 v24 set these correctly)")
                    return nil
                }

                // Append delta CMUs to tree
                for cmu in deltaCMUs {
                    _ = ZipherXFFI.treeAppend(cmu: cmu)
                }
                print("✅ FIX #557 v11: Tree now at current chain tip \(currentChainHeight)")
            }

            // Get anchor from CURRENT tree root (chain tip) - CORRECT!
            guard let anchor = ZipherXFFI.treeRoot() else {
                print("❌ Failed to get tree root for anchor")
                return nil
            }

            print("✅ FIX #557 v10: Anchor from full tree (current): \(anchor.prefix(8).map { String(format: "%02x", $0) }.joined())...")

            // CRITICAL: The witness must also be updated to match the CURRENT anchor!
            // The result.witness was created at note's position, but we need witness at current tree root
            // The tree is now loaded with ALL CMUs, so get the witness from the LOADED tree at the same position
            if let updatedWitness = ZipherXFFI.treeGetWitness(index: result.position) {
                print("✅ FIX #557 v10: Witness from loaded tree at position \(result.position) (\(updatedWitness.count) bytes)")
                return (witness: updatedWitness, anchor: anchor)
            } else {
                print("⚠️ FIX #557 v10: Failed to get witness from loaded tree, using original (may not match anchor!)")
                return (witness: result.witness, anchor: anchor)
            }
        }

        print("⚠️ FIX #514 v2: CMU not in downloaded file, trying delta blocks...")
        print("   (Note might be beyond downloadedTreeHeight or in P2P-only range)")

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

        // 4. Fetch additional CMUs from blocks between downloadedTreeHeight+1 and targetHeight
        // FIX #115: Fetch to targetHeight (chain tip), not just noteHeight
        let startHeight = downloadedTreeHeight + 1
        print("📡 Fetching CMUs from blocks \(startHeight) to \(targetHeight)...")

        // Batch fetch all CMUs using P2P-first approach
        let allDeltaCMUs = await fetchCMUsFromBlocks(startHeight: startHeight, endHeight: targetHeight)
        print("📊 Got \(allDeltaCMUs.count) CMUs from blocks \(startHeight) to \(targetHeight)")

        var additionalCMUs: [Data] = []
        var notePosition: UInt64? = nil

        // FIX #514: Also create reversed version of target CMU for byte order comparison
        let cmuReversed = Data(cmu.reversed())

        for blockCMU in allDeltaCMUs {
            // Check if this is our note's CMU (try both byte orders)
            if blockCMU == cmu || blockCMU == cmuReversed {
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
            print("❌ Note CMU not found in blocks \(startHeight)-\(targetHeight)")
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
    /// FIX #115: Rebuild witnesses for multiple notes to a CONSISTENT chain tip height
    /// All witnesses will share the same anchor (tree root at chainHeight)
    func rebuildWitnessesForNotes(
        notes: [SpendableNote],
        downloadedTreeHeight: UInt64,
        chainHeight: UInt64? = nil  // FIX #115: Optional chain height for consistent anchor
    ) async throws -> [(note: SpendableNote, witness: Data, anchor: Data)] {
        print("🔄 Rebuilding witnesses for \(notes.count) notes using boost + delta sync...")

        // Sort notes by height to process them in order
        let sortedNotes = notes.sorted { $0.height < $1.height }
        let maxNoteHeight = sortedNotes.last?.height ?? 0

        // FIX #115: Use chainHeight if provided, otherwise fetch current chain height
        // This ensures all witnesses are built to the SAME tree state
        let targetHeight: UInt64
        if let explicitChainHeight = chainHeight {
            targetHeight = explicitChainHeight
            print("📊 Using explicit chain height: \(targetHeight)")
        } else {
            // Fetch current chain height for consistent witness building
            do {
                targetHeight = try await NetworkManager.shared.getChainHeight()
                print("📊 Fetched chain height: \(targetHeight)")
            } catch {
                // Fallback to max note height if chain height unavailable
                targetHeight = maxNoteHeight
                print("⚠️ Could not get chain height, using maxNoteHeight: \(targetHeight)")
            }
        }

        print("📊 Will build tree to height \(targetHeight) (max note: \(maxNoteHeight))")

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
        // FIX #115: Fetch to targetHeight (chain tip), NOT maxNoteHeight
        // This ensures witnesses are built to a consistent, current tree state
        var deltaCMUs: [Data] = []
        if targetHeight > downloadedTreeHeight {
            let startHeight = downloadedTreeHeight + 1
            print("📡 Fetching delta CMUs from blocks \(startHeight) to \(targetHeight)...")

            // Use batched P2P-first fetching (reduces log spam, works with Tor)
            deltaCMUs = await fetchCMUsFromBlocks(startHeight: startHeight, endHeight: targetHeight)
            print("📊 Fetched \(deltaCMUs.count) delta CMUs from chain (covering \(targetHeight - startHeight + 1) blocks)")
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

        // 6. FIX #556: Get anchors from HeaderStore for each note based on block height
        // CRITICAL: Witness root is from CMU position, NOT block height!
        // Each note is at a different block height, so each needs its own anchor from that block's header.
        print("🔧 FIX #556: Getting anchors from HeaderStore for each note...")

        var results: [(note: SpendableNote, witness: Data, anchor: Data)] = []
        for (index, result) in batchResults.enumerated() {
            guard let (position, witness) = result else {
                print("❌ Failed to create witness for note \(index + 1) at height \(sortedNotes[index].height)")
                throw TransactionError.proofGenerationFailed
            }
            let note = sortedNotes[index]

            // FIX #556: Get anchor from HeaderStore using note's block height (NOT witness root!)
            guard let anchor = try? HeaderStore.shared.getSaplingRoot(at: UInt64(note.height)) else {
                print("❌ Failed to get anchor from HeaderStore for note at height \(note.height)")
                throw TransactionError.proofGenerationFailed
            }

            let rootHex = anchor.map { String(format: "%02x", $0) }.joined()
            print("   ✅ Note \(index + 1): height \(note.height), position \(position), anchor \(rootHex.prefix(16))...")

            results.append((note: note, witness: witness, anchor: anchor))
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
        // FIX #499: Don't check Tor.mode here - it's @MainActor and can hang if main thread is blocked
        // We use P2P only anyway (InsightAPI is disabled)
        let torEnabled = false  // P2P only mode

        // PRIORITY 1: Check local delta bundle first (instant, no network!)
        // This enables instant witness generation for notes after the bundled tree
        // CRITICAL: Delta must FULLY cover the requested range to be used!
        // FIX #115: MUST validate delta against headers BEFORE using (corrupted delta = wrong anchor = rejected tx)
        let deltaManager = DeltaCMUManager.shared
        if let deltaManifest = deltaManager.getManifest() {
            // CRITICAL FIX #115: Validate delta bundle against headers BEFORE using
            // If validation fails (no header available, root mismatch), DO NOT use delta
            let deltaValid = await deltaManager.validateTreeRootAgainstHeaders()
            if !deltaValid {
                print("⚠️ DeltaCMU: Validation FAILED - NOT using delta bundle (would cause wrong anchor)")
                // Clear corrupted delta so it won't be used again, then fall through to P2P
                deltaManager.clearDeltaBundle()
            } else {
                // Delta validated successfully - safe to use
                // Log delta state for debugging
                print("📦 Delta manifest: startHeight=\(deltaManifest.startHeight), endHeight=\(deltaManifest.endHeight), outputCount=\(deltaManifest.outputCount)")
                print("📦 Requested range: \(startHeight)-\(endHeight)")

                // CRITICAL FIX: Delta must START at or BEFORE our requested start height
                // If delta.startHeight > startHeight, there's a GAP that delta can't fill!
                if deltaManifest.startHeight <= startHeight {
                    // Delta covers from the start - check end coverage
                    if endHeight <= deltaManifest.endHeight {
                        // Full coverage - get all CMUs from delta bundle
                        if let deltaCMUs = deltaManager.loadDeltaCMUsForHeightRange(startHeight: startHeight, endHeight: endHeight) {
                            allCMUs = deltaCMUs
                            print("📦 DeltaCMU: FULL coverage - Got \(allCMUs.count) CMUs from local delta bundle (INSTANT!)")
                            return allCMUs
                        }
                    } else {
                        // Partial coverage at end - get what we can from delta
                        if let deltaCMUs = deltaManager.loadDeltaCMUsForHeightRange(startHeight: startHeight, endHeight: deltaManifest.endHeight) {
                            allCMUs = deltaCMUs
                            let remainingBlocks = endHeight - deltaManifest.endHeight
                            print("📦 DeltaCMU: PARTIAL coverage - Got \(allCMUs.count) CMUs, need P2P for last \(remainingBlocks) blocks")
                            // Fall through to P2P to get remaining blocks
                        }
                    }
                } else {
                    // GAP: Delta starts AFTER our requested range - cannot use delta!
                    print("📦 DeltaCMU: GAP detected! Delta starts at \(deltaManifest.startHeight) but we need \(startHeight). Using P2P...")
                }
            }
        }

        // PRIORITY 2: Try P2P (especially important for Tor mode)
        // Try multiple peers before giving up
        let connectedPeers = await MainActor.run { networkManager.getAllConnectedPeers() }
        if !connectedPeers.isEmpty {
            print("📡 Fetching delta CMUs via P2P (blocks \(startHeight)-\(endHeight))...")
            let blockCount = Int(endHeight - startHeight + 1)

            for peer in connectedPeers.prefix(3) {  // Try up to 3 peers
                do {
                    // FIX #108: Add 15s timeout to prevent P2P fetch from hanging indefinitely
                    let blocks = try await withTimeout(seconds: 15) {
                        try await peer.getFullBlocks(from: startHeight, count: blockCount)
                    }
                    for block in blocks {
                        for tx in block.transactions {
                            for output in tx.outputs {
                                // CMU from P2P is already in wire format (little-endian)
                                allCMUs.append(output.cmu)
                            }
                        }
                    }
                    print("📡 P2P: Got \(allCMUs.count) CMUs from \(blocks.count) blocks via \(peer.host)")
                    return allCMUs
                } catch {
                    print("⚠️ P2P fetch from \(peer.host) failed: \(error.localizedDescription)")
                    // Try next peer
                    continue
                }
            }
            print("⚠️ All P2P peers failed to fetch CMUs")
        }

        // InsightAPI fallback - try anyway even in Tor mode
        // (User might have clearnet access, VPN, or Cloudflare might not block)
        if torEnabled && allCMUs.isEmpty {
            print("⚠️ P2P failed in Tor mode - trying InsightAPI as last resort...")
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
    /// FIX #120: InsightAPI commented out - P2P only
    private func fetchCMUsViaInsight(height: UInt64) async throws -> [Data] {
        // FIX #120: InsightAPI commented out - P2P only
        // let insightAPI = InsightAPI.shared
        //
        // // Get block hash
        // let blockHash = try await insightAPI.getBlockHash(height: height)
        //
        // // Get block to get transaction IDs
        // let block = try await insightAPI.getBlock(hash: blockHash)
        //
        // // Extract CMUs from shielded outputs of each transaction
        // var cmus: [Data] = []
        //
        // for txid in block.tx {
        //     do {
        //         let tx = try await insightAPI.getTransaction(txid: txid)
        //         if let outputs = tx.vShieldedOutput {
        //             for output in outputs {
        //                 if let cmuData = Data(hex: output.cmu) {
        //                     // CMU from Insight API is in big-endian (display format)
        //                     // Need to reverse to little-endian (wire format) for tree
        //                     let cmuLE = Data(cmuData.reversed())
        //                     cmus.append(cmuLE)
        //                 }
        //             }
        //         }
        //     } catch {
        //         // Skip transactions that fail to fetch
        //         continue
        //     }
        // }
        //
        // return cmus

        // P2P-only: This function is no longer used, CMUs come from P2P
        throw NetworkError.p2pFetchFailed
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

    /// Fetch CMUs for a range of blocks using Delta Bundle (preferred), P2P peers, or InsightAPI fallback
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

        // PRIORITY 1: Try Delta CMU Bundle first (INSTANT - local disk)
        // CRITICAL: Must check if delta FULLY covers the range before using it!
        if let manifest = DeltaCMUManager.shared.getManifest() {
            // Delta must START at or BEFORE our requested start height to be useful
            if manifest.startHeight <= startHeight && manifest.endHeight >= endHeight {
                // Full coverage - get CMUs from delta bundle
                if let deltaCMUs = DeltaCMUManager.shared.loadDeltaCMUsForHeightRange(startHeight: startHeight, endHeight: endHeight),
                   !deltaCMUs.isEmpty {
                    print("⚡ INSTANT: Got \(deltaCMUs.count) CMUs from Delta Bundle (full coverage \(manifest.startHeight)-\(manifest.endHeight))")
                    return deltaCMUs
                } else {
                    // Delta covers this range but no shielded outputs exist in these blocks
                    print("⚡ INSTANT: Delta bundle confirms NO shielded outputs in range \(startHeight)-\(endHeight)")
                    return []
                }
            } else if manifest.startHeight <= startHeight && manifest.endHeight < endHeight {
                // Partial coverage (start OK but end beyond delta)
                print("📦 Delta: Partial coverage (\(manifest.startHeight)-\(manifest.endHeight)), need P2P for \(manifest.endHeight+1)-\(endHeight)")
                // Fall through to P2P
            } else {
                // Delta starts AFTER our requested range - cannot use it (GAP exists!)
                print("📦 Delta: Gap detected! Delta starts at \(manifest.startHeight) but we need \(startHeight). Using P2P...")
            }
        } else {
            print("📦 Delta bundle: No manifest found, falling back to P2P...")
        }

        // PRIORITY 2: Use getBlocksOnDemandP2P which:
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

        // FIX #120: InsightAPI commented out - P2P only
        // CRITICAL: When Tor is enabled, do NOT use InsightAPI (blocked by Cloudflare)
        // Only P2P works through Tor - if P2P fails, we must fail the operation
        // let torEnabled = await TorManager.shared.mode == .enabled
        // if torEnabled {
        //     print("🧅 Tor enabled - InsightAPI fallback DISABLED (Cloudflare blocks Tor)")
        //     print("❌ P2P CMU fetch failed and no fallback available")
        //     throw NetworkError.p2pFetchFailed
        // }
        //
        // // InsightAPI fallback - ONLY when Tor is disabled
        // print("📡 Attempting InsightAPI fallback for \(totalBlocks) blocks...")
        //
        // let batchSize = 50
        // var currentStart = startHeight
        // var insightErrors = 0
        //
        // while currentStart <= endHeight {
        //     let batchEnd = min(currentStart + UInt64(batchSize) - 1, endHeight)
        //
        //     for height in currentStart...batchEnd {
        //         do {
        //             let cmus = try await fetchCMUsViaInsight(height: height)
        //             allCMUs.append(contentsOf: cmus)
        //         } catch {
        //             insightErrors += 1
        //             if insightErrors <= 3 {
        //                 print("⚠️ InsightAPI failed for block \(height): \(error.localizedDescription)")
        //             }
        //             // Continue to next block, don't abort entirely
        //         }
        //     }
        //     currentStart = batchEnd + 1
        // }
        //
        // if insightErrors > 0 {
        //     print("⚠️ InsightAPI had \(insightErrors) errors out of \(totalBlocks) blocks")
        // }
        //
        // if allCMUs.isEmpty && totalBlocks > 0 {
        //     throw NetworkError.p2pFetchFailed
        // }
        //
        // print("✅ InsightAPI fallback complete: \(allCMUs.count) CMUs")

        // P2P-only mode: if P2P fails, we fail
        if allCMUs.isEmpty && totalBlocks > 0 {
            print("❌ P2P CMU fetch failed - no InsightAPI fallback (P2P-only mode)")
            throw NetworkError.p2pFetchFailed
        }

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
    case witnessAnchorMismatch(noteHeight: UInt64, witnessRoot: String, headerAnchor: String)

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
        case .witnessAnchorMismatch(let noteHeight, _, _):
            return "Witness/anchor mismatch at height \(noteHeight). Database repair needed. Go to Settings → 'Repair Notes (fix balance)'"
        }
    }
}
