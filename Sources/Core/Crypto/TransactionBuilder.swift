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

    /// FIX #1328: Static guard prevents concurrent proof generation sessions.
    /// When user closes/reopens Send window, old build may still be in Rust FFI.
    /// This flag ensures only ONE buildShieldedTransactionWithProgress runs at a time.
    private static var isBuilding = false

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

        print("📁 Loading Sapling params from Swift")

        let spendData: Data
        do {
            spendData = try Data(contentsOf: spendPath)
        } catch {
            print("❌ Failed to read spend params file: \(error.localizedDescription)")
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
        var chainHeight = await MainActor.run { NetworkManager.shared.chainHeight }
        if chainHeight == 0 {
            chainHeight = try await NetworkManager.shared.getChainHeight()
        }
        print("📊 Current chain height: \(chainHeight)")

        // FIX #580: Debug branch ID before building transaction
        ZipherXFFI.debugBranchId(chainHeight: chainHeight)

        // FIX #1330: Include notes with NULL witnesses — rebuilt on-demand during TX build
        var dbNotes = try database.getAllUnspentNotes(accountId: account.accountId)

        if dbNotes.isEmpty {
            print("📝 No notes found in database")
            throw TransactionError.insufficientFunds
        }

        print("📝 Found \(dbNotes.count) unspent notes (witnesses rebuilt on-demand)")

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
                    // FIX #1138: Save tree state WITH HEIGHT
                    if let serializedTreeData = ZipherXFFI.treeSerialize() {
                        try? database.saveTreeState(serializedTreeData, height: UInt64(downloadedTreeHeight))
                        print("💾 FIX #1138: Tree state saved at height \(downloadedTreeHeight)")
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
        // PRIVACY: P-TX-001 — Randomized note selection to prevent UTXO fingerprinting
        let shuffledNotes = notes.shuffled()
        let sortedNotes: [SpendableNote]
        if let exactFit = shuffledNotes.first(where: { $0.value >= requiredAmount && $0.value <= requiredAmount * 2 }) {
            sortedNotes = [exactFit] + shuffledNotes.filter { $0.position != exactFit.position }
        } else {
            sortedNotes = shuffledNotes.sorted { a, b in
                if Bool.random() && Bool.random() { return a.value < b.value }
                return a.value > b.value
            }
        }

        // Find a single note large enough for the transaction
        guard let note = sortedNotes.first(where: { $0.value >= requiredAmount }) else {
            // Calculate what the user CAN send with their largest note
            let largestNote = sortedNotes.first?.value ?? 0
            let maxSendable = largestNote > DEFAULT_FEE ? largestNote - DEFAULT_FEE : 0
            let totalBalance = notes.reduce(0) { $0 + $1.value }

            print("❌ No single note large enough for this transaction")
            print("   Required: \(requiredAmount.redactedAmount) (amount: \(amount.redactedAmount) + fee: \(DEFAULT_FEE.redactedAmount))")
            print("   Largest note: \(largestNote.redactedAmount)")
            print("   Max sendable: \(maxSendable.redactedAmount)")
            print("   Total balance: \(totalBalance.redactedAmount) across \(notes.count) notes")
            print("   NOTE: Multi-input transactions not yet supported - must use single note")

            throw TransactionError.noteLargeEnough(largestNote: largestNote, required: requiredAmount)
        }

        print("📝 Selected note: \(note.value.redactedAmount) at height \(note.height)") // PRIVACY: Intentionally unredacted for critical diagnostics

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
        var witnessToUse = note.witness
        // FIX #1107: Changed from 1028 to 100 - witnesses are smaller (838 bytes) with current tree depth
        var needsRebuild = note.witness.count < 100 || note.witness.allSatisfy { $0 == 0 }

        // Check if we have a valid anchor from header store
        let haveHeaderAnchor = !anchorFromHeader.allSatisfy { $0 == 0 }

        if needsRebuild {
            print("⚠️ Witness invalid (\(note.witness.count) bytes), needs rebuild")
        } else if haveHeaderAnchor {
            // CRITICAL FIX #557 v38: Extract anchor FROM THE WITNESS!
            // After FIX #557 v36, witnesses are updated to chain tip root.
            // The witness anchor is the CORRECT anchor for transactions.
            if let witnessRoot = ZipherXFFI.witnessGetRoot(note.witness) {
                let witnessRootHex = witnessRoot.prefix(8).map { String(format: "%02x", $0) }.joined()
                let headerAnchorHex = anchorFromHeader.prefix(8).map { String(format: "%02x", $0) }.joined()

                // Use witness anchor instead of header anchor
                anchorFromHeader = witnessRoot
                print("✅ FIX #557 v38: Using anchor from WITNESS")
                print("   witnessAnchor: \(witnessRootHex)...")
                print("   (headerAnchor was: \(headerAnchorHex)...)")
                needsRebuild = false
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

                // CRITICAL FIX #557 v38: Extract anchor FROM THE WITNESS!
                // After FIX #557 v36, witness has chain tip root, not note height root.
                // The witness anchor is the CORRECT anchor to use for the transaction.
                if let witnessAnchor = ZipherXFFI.witnessGetRoot(witnessToUse) {
                    anchorFromHeader = witnessAnchor
                    let anchorHex = anchorFromHeader.prefix(8).map { String(format: "%02x", $0) }.joined()
                    print("📝 FIX #557 v38: Using anchor from WITNESS: \(anchorHex)...")
                } else if anchorFromHeader.allSatisfy({ $0 == 0 }) {
                    // Fallback to computed anchor
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
            // FIX #947: This path is used when witnesses were deferred during import
            // The tree is rebuilt from CMUs (~15-20 seconds on first SEND)
            print("📝 Note is within downloaded tree range, creating witness from downloaded CMUs...")
            print("⚡ FIX #947: This may take 15-20 seconds if witnesses were deferred during import...")

            guard let cachedPath = await CommitmentTreeUpdater.shared.getCachedCMUFilePath(),
                  let cachedData = try? Data(contentsOf: cachedPath) else {
                print("❌ Failed to load commitment tree from GitHub cache")
                throw TransactionError.proofGenerationFailed
            }

            if let result = ZipherXFFI.treeCreateWitnessForCMU(cmuData: cachedData, targetCMU: cmu) {
                print("✅ Created witness at position \(result.position)")
                witnessToUse = result.witness

                // FIX #947: Extract anchor from the newly created witness
                // This is critical when witnesses were deferred - anchorFromHeader might be a placeholder
                if let witnessAnchor = ZipherXFFI.witnessGetRoot(witnessToUse) {
                    anchorFromHeader = witnessAnchor
                    let anchorHex = anchorFromHeader.prefix(8).map { String(format: "%02x", $0) }.joined()
                    print("📝 FIX #947: Using anchor from rebuilt witness: \(anchorHex)...")
                }
            } else {
                print("❌ Failed to find note CMU in downloaded tree")
                throw TransactionError.proofGenerationFailed
            }
        }

        // VUL-002 FIX: Use encrypted key FFI to ensure key is decrypted only in Rust
        // and immediately zeroed after use by Rust's secure_zero()
        let (encryptedKey, encryptionKey) = try SecureKeyStorage.shared.getEncryptedKeyAndPassword()
        print("🔐 VUL-002: Using encrypted key FFI (key decrypted only in Rust)")

        // FIX #803: Log anchor and witness info BEFORE FFI call for debugging
        let anchorHex = anchorFromHeader.prefix(16).map { String(format: "%02x", $0) }.joined()
        print("🔍 FIX #803: Building TX with anchor: \(anchorHex)... (witness: \(witnessToUse.count) bytes)")

        // FIX #982: Log all note components for CMU debugging
        // VUL-CRYPTO-007: Diversifier is privacy-sensitive — only log in debug builds
        #if DEBUG
        print("🔍 FIX #982: Note components being sent to Rust FFI:")
        print("   Diversifier: [redacted]")
        print("   RCM: [redacted]")
        print("   Value: \(note.value.redactedAmount)")
        #endif
        if let cmu = noteCMU {
            print("   Stored CMU: \(cmu.prefix(8).map { String(format: "%02x", $0) }.joined())...")
            // Also print reversed CMU for comparison with Rust logs
            let reversedCMU = Data(cmu.reversed())
            print("   Stored CMU (reversed): \(reversedCMU.prefix(8).map { String(format: "%02x", $0) }.joined())...")
        }

        // FIX #838: CRITICAL - Verify witness consistency BEFORE building TX
        // The Sapling library uses merkle_path.root(node) to compute the anchor, NOT witness.root()
        // If these differ, the TX will be rejected by the network with "joinsplit requirements not met"
        // This catches corrupted witnesses BEFORE wasting time on proof generation
        if let cmu = noteCMU, !cmu.isEmpty {
            if !ZipherXFFI.witnessVerifyAnchor(witnessToUse, cmu: cmu) {
                let witnessRootHex = ZipherXFFI.witnessGetRoot(witnessToUse)?.prefix(8).map { String(format: "%02x", $0) }.joined() ?? "nil"
                print("❌ FIX #838: WITNESS CORRUPTED - stored root (\(witnessRootHex)...) != merkle_path.root(cmu)")
                print("   The merkle path computes to a DIFFERENT anchor than witness.root()")
                print("   TX would be rejected by network with 'joinsplit requirements not met'")
                print("   💡 Run 'Settings → Repair Database' to rebuild witnesses")
                throw TransactionError.witnessCorrupted
            }
            print("✅ FIX #838: Witness consistency verified (stored root == computed anchor)")
        } else {
            print("⚠️ FIX #838: Cannot verify witness consistency - CMU not available")
        }

        // FIX #1224: CRITICAL — Verify anchor EXISTS on blockchain before building TX!
        // A witness can pass witnessPathIsValid AND witnessVerifyAnchor (internally consistent)
        // but have a BOGUS anchor from a corrupted/incomplete tree. This caused the phantom TX
        // of FIX #1221: anchor 523b156e... was internally consistent but never existed on chain.
        // FIX #1204 stores ALL historical finalsaplingroots in HeaderStore during P2P fetches.
        // If anchor is not found in HeaderStore, the tree was corrupted when witness was created.
        let anchorOnChain = await HeaderStore.shared.containsSaplingRoot(anchorFromHeader)
        if !anchorOnChain {
            let badAnchorHex = anchorFromHeader.prefix(16).map { String(format: "%02x", $0) }.joined()
            // FIX #1279: NEVER bypass anchor check. FIX #1256 previously let DeltaBundleVerified=true
            // skip this, but sim wallet proved tree tip root can be correct while witness anchors are
            // phantom (b6e85eb1... never existed on blockchain). Groth16 proof would be wasted.
            print("❌ FIX #1279: Anchor \(badAnchorHex)... NOT FOUND in HeaderStore!")
            print("   Witness is internally consistent but anchor never existed on blockchain")
            print("   This would create a phantom TX — REJECTING before Groth16 proof generation")
            throw TransactionError.anchorNotOnChain
        }
        print("✅ FIX #1224: Anchor verified in HeaderStore")

        // FIX #1137: CRITICAL - Verify stored CMU matches CMU computed from note parts
        // The Rust FFI recomputes CMU from note parts (diversifier, value, rcm) using Note::from_parts().cmu()
        // If stored CMU doesn't match computed CMU, the anchor will be wrong and TX will be rejected
        // This catches data integrity issues BEFORE wasting time on proof generation
        if let cmu = noteCMU, !cmu.isEmpty {
            let cmuVerifyResult = ZipherXFFI.verifyNoteCMU(
                storedCMU: cmu,
                diversifier: note.diversifier,
                rcm: note.rcm,
                value: note.value,
                spendingKey: spendingKey
            )

            if cmuVerifyResult == 0 {
                // CMU MISMATCH - the stored CMU doesn't match CMU computed from note parts!
                let storedCMUHex = cmu.prefix(16).map { String(format: "%02x", $0) }.joined()
                print("❌ FIX #1137: CMU MISMATCH DETECTED!")
                print("   Stored CMU: \(storedCMUHex)...")
                print("   But CMU computed from (diversifier, value, rcm) is DIFFERENT!")
                print("   This means the note data in the database is inconsistent.")
                print("   The anchor derived from stored CMU will NOT match the anchor Rust computes.")
                print("   TX would be rejected by network with 'joinsplit requirements not met'")
                print("   💡 Run 'Settings → Repair Database → Full Resync' to fix note data")
                throw TransactionError.cmuMismatch
            } else if cmuVerifyResult == 1 {
                print("✅ FIX #1137: CMU integrity verified (stored CMU == computed CMU)")
            } else {
                print("⚠️ FIX #1137: CMU verification returned error code \(cmuVerifyResult)")
            }
        }

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
            // FIX #803: Log detailed error for anchor mismatch debugging
            print("❌ FIX #803: ANCHOR MISMATCH - FFI transaction build failed!")
            print("   Anchor used: \(anchorHex)...")
            print("   Witness size: \(witnessToUse.count) bytes")
            print("   Note height: \(note.height), Chain height: \(chainHeight)")
            print("   💡 The witness merkle path doesn't compute to the anchor - witness is corrupted")
            print("   💡 Run 'Settings → Repair Database' to rebuild witnesses")
            throw TransactionError.proofGenerationFailed
        }

        // FIX #557 v40: Log the actual anchor being used
        let actualAnchor = anchorFromHeader.prefix(8).map { String(format: "%02x", $0) }.joined()
        print("🔑 FIX #557 v40: Transaction built with anchor: \(actualAnchor)...")
        print("   (anchor source: \(note.witness.count) byte witness)")

        print("✅ Transaction built: \(rawTx.count) bytes")

        // FIX #1486 (VULN-001): Raw TX hex MUST NOT be logged in release builds.
        // The full transaction bytes contain Groth16 proof data, nullifiers, commitments,
        // and encrypted Sapling outputs. Logging them unconditionally writes the complete
        // transaction structure to zmac.log, allowing an attacker with log access to link
        // sender notes to outputs and break Sapling privacy.
        #if DEBUG
        let txHex = rawTx.map { String(format: "%02x", $0) }.joined()
        print("📋 Raw TX hex: \(txHex)")
        #endif

        // FIX #1402 (NEW-004): Persist the change diversifier index used in this TX
        let changeDivIndex = RustBridge.shared.getLastChangeDiversifierIndex()
        if changeDivIndex >= 1_000_000_000 {
            if let fvk = try? RustBridge.shared.deriveFullViewingKey(from: SaplingSpendingKey(data: spendingKey)),
               let (changeAddr, _) = try? RustBridge.shared.derivePaymentAddress(from: fvk, diversifierIndex: changeDivIndex) {
                try? WalletDatabase.shared.insertDiversifiedAddress(
                    accountId: 1,
                    diversifierIndex: changeDivIndex,
                    address: changeAddr,
                    label: "change"
                )
                print("📝 FIX #1402 (NEW-004): Persisted change diversifier index \(changeDivIndex)")
            }
        }

        // Return both transaction and nullifier of spent note
        print("📝 Spent note nullifier: \(LogRedaction.redactNullifier(note.nullifier.map { String(format: "%02x", $0) }.joined()))")
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
        cachedChainHeight: UInt64? = nil,  // FIX #600: Cache chain height to avoid multiple network calls
        onProgress: @escaping ProgressCallback
    ) async throws -> (Data, Data) {

        // FIX #1328: Prevent concurrent proof generation sessions.
        // If another build is already in Rust FFI, cancel it first and wait briefly.
        if TransactionBuilder.isBuilding {
            print("⚠️ FIX #1328: Another build in progress — cancelling it first")
            ZipherXFFI.cancelProofGeneration()
            // Brief wait for Rust threads to notice the cancel flag
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        TransactionBuilder.isBuilding = true
        defer { TransactionBuilder.isBuilding = false }

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

        // FIX M-014: Prevent UInt64 overflow — amount + fee must not exceed MAX_MONEY or overflow UInt64.
        // Without this check, a near-UInt64.max amount + DEFAULT_FEE wraps to 0, bypassing
        // the insufficient-funds check and producing a zero-value transaction.
        let maxSendable: UInt64 = 2_100_000_000_000_000  // MAX_MONEY (21M ZCL * 10^8 zatoshis)
        guard amount <= maxSendable, amount <= maxSendable - ZipherXConstants.defaultFee else {
            throw TransactionError.invalidAmount
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

        // FIX #600: Use cached chain height from caller to avoid multiple network calls
        var chainHeight: UInt64
        if let cached = cachedChainHeight, cached > 0 {
            chainHeight = cached
            print("⚡ FIX #600: Using cached chain height: \(chainHeight)")
        } else {
            // Fallback: use cached chain height from NetworkManager, then fetch if needed
            chainHeight = await MainActor.run { NetworkManager.shared.chainHeight }
            if chainHeight == 0 {
                print("⚠️ FIX #600: No cached height, fetching from network...")
                chainHeight = try await NetworkManager.shared.getChainHeight()
            }
        }
        // FIX #1330: Use ALL unspent notes (including those with NULL witnesses).
        // TransactionBuilder rebuilds witnesses on-demand for only the selected notes.
        // getUnspentNotes() required `witness IS NOT NULL` which excluded notes needing
        // witness rebuild — forcing the slow preRebuildWitnessesForInstantPayment().
        var dbNotes = try database.getAllUnspentNotes(accountId: account.accountId)

        if dbNotes.isEmpty {
            throw TransactionError.insufficientFunds
        }

        // Use downloaded tree height from GitHub
        let downloadedTreeHeight = ZipherXConstants.effectiveTreeHeight

        // FIX #557 v46: Load cached boost file data for potential witness rebuild
        var cachedBoostFileData: Data? = nil
        if let cachedPath = await CommitmentTreeUpdater.shared.getCachedCMUFilePath() {
            cachedBoostFileData = try? Data(contentsOf: cachedPath)
        }

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

            if let cachedData = cachedBoostFileData {

                // Count CMUs for progress display
                let cmuCount = cachedData.count >= 8 ?
                    cachedData.prefix(8).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) } : 0

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
                // FIX #1138: Save tree state WITH HEIGHT
                if let serializedTree = ZipherXFFI.treeSerialize() {
                    try? database.saveTreeState(serializedTree, height: UInt64(downloadedTreeHeight))
                    print("💾 FIX #1138: Tree state saved at height \(downloadedTreeHeight)")
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
                    // FIX #1138: Save tree state WITH HEIGHT
                    if let serializedTreeData = ZipherXFFI.treeSerialize() {
                        try? database.saveTreeState(serializedTreeData, height: UInt64(downloadedTreeHeight))
                    }
                    onProgress("tree", "Tree ready", 1.0)
                } else {
                    throw TransactionError.proofGenerationFailed
                }

                // Load the newly extracted boost file data for witness rebuild
                if let cachedPath = await CommitmentTreeUpdater.shared.getCachedCMUFilePath() {
                    cachedBoostFileData = try? Data(contentsOf: cachedPath)
                }
            }
        }

        // Get spendable notes
        let notes = try await getSpendableNotes(for: from, spendingKey: spendingKey)

        // Note selection - prefer single note, fall back to multi-input
        let requiredAmount = amount + DEFAULT_FEE
        // PRIVACY: P-TX-001 — Randomized note selection to prevent UTXO fingerprinting
        let shuffledNotes = notes.shuffled()
        let sortedNotes: [SpendableNote]
        if let exactFit = shuffledNotes.first(where: { $0.value >= requiredAmount && $0.value <= requiredAmount * 2 }) {
            sortedNotes = [exactFit] + shuffledNotes.filter { $0.position != exactFit.position }
        } else {
            sortedNotes = shuffledNotes.sorted { a, b in
                if Bool.random() && Bool.random() { return a.value < b.value }
                return a.value > b.value
            }
        }
        let totalBalance = notes.reduce(0) { $0 + $1.value }

        // Check if we have enough total balance
        guard totalBalance >= requiredAmount else {
            print("❌ Insufficient total balance: have \(totalBalance.redactedAmount), need \(requiredAmount.redactedAmount)")
            throw TransactionError.insufficientFunds
        }

        // Try to find a single note large enough (preferred for simplicity/fee)
        var selectedNotes: [SpendableNote] = []
        if let singleNote = sortedNotes.first(where: { $0.value >= requiredAmount }) {
            selectedNotes = [singleNote]
            print("📝 Single note selected: \(singleNote.value.redactedAmount) at height \(singleNote.height)")
        } else {
            // Multi-input mode: select notes until we have enough
            print("📝 No single note large enough, using multi-input mode...")
            var accumulated: UInt64 = 0
            for note in sortedNotes {
                selectedNotes.append(note)
                accumulated += note.value
                print("   + Note: \(note.value.redactedAmount) (running total: \(accumulated.redactedAmount))")
                if accumulated >= requiredAmount {
                    break
                }
            }
            print("📝 Selected \(selectedNotes.count) notes totaling \(accumulated.redactedAmount)")
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
        var preparedSpends: [(note: SpendableNote, witness: Data, anchor: Data)] = []

        // CRITICAL FIX: For multi-input transactions, ALL witnesses MUST have the same anchor.
        if isMultiInput {
            print("🔧 Multi-input: Checking if database witnesses can be used directly...")

            // OPTIMIZATION: First check if ALL notes have valid witnesses with MATCHING anchors
            // This is the INSTANT path - no network or file I/O needed!
            var allValid = true
            var commonAnchor: Data?

            for note in selectedNotes {
                // Check if witness is valid
                // FIX #1107: Changed from 1028 to 100 - witnesses are smaller with current tree depth
                let witnessValid = note.witness.count >= 100 && !note.witness.allSatisfy { $0 == 0 }
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

            // FIX #1224: Verify common anchor EXISTS on blockchain before proceeding
            if allValid, let anchor = commonAnchor {
                let anchorOnChain = await HeaderStore.shared.containsSaplingRoot(anchor)
                if !anchorOnChain {
                    let anchorHex = anchor.prefix(16).map { String(format: "%02x", $0) }.joined()
                    // FIX #1279: NEVER bypass — phantom anchors cause phantom TXs
                    print("🚨 FIX #1279: Multi-input common anchor \(anchorHex)... NOT FOUND in HeaderStore!")
                    print("   All witnesses have matching anchors but anchor never existed on blockchain")
                    print("   Witness computation produces phantom anchors — forcing rebuild")
                    allValid = false
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

            var anchorMatchesTree = allValid && commonAnchor != nil && commonAnchor == currentTreeRoot && treeIsValid

            // FIX #1324: INSTANT mode for stale-but-valid witnesses.
            // After app restart, delta sync may grow the tree by 1+ CMU, making DB witnesses "stale"
            // (their anchor ≠ current FFI tree root). But if the anchor IS verified in HeaderStore,
            // the witnesses are perfectly valid for spending — Sapling allows ANY historical anchor.
            // This avoids the ~85-second witness rebuild on every first "max" send after restart.
            var usingStaleButValidWitnesses = false
            if !anchorMatchesTree && allValid, let staleAnchor = commonAnchor {
                // Anchor already passed HeaderStore check at line 754 (FIX #1224).
                // Double-check here for safety.
                let staleAnchorOnChain = await HeaderStore.shared.containsSaplingRoot(staleAnchor)
                if staleAnchorOnChain {
                    let anchorHex = staleAnchor.prefix(8).map { String(format: "%02x", $0) }.joined()
                    print("✅ FIX #1324: Stale witnesses with VALID anchor \(anchorHex)... in HeaderStore — INSTANT mode")
                    print("   Sapling allows historical anchors — no rebuild needed")
                    anchorMatchesTree = true
                    usingStaleButValidWitnesses = true
                }
            }

            if allValid && anchorMatchesTree {
                // INSTANT MODE: All witnesses are valid with matching anchors that match current tree!
                if usingStaleButValidWitnesses {
                    print("✅ FIX #1324: Multi-input INSTANT mode: \(selectedNotes.count) notes with STALE-BUT-VALID witnesses")
                } else {
                    print("✅ Multi-input INSTANT mode: All \(selectedNotes.count) notes have valid witnesses with matching anchors!")
                }

                if usingStaleButValidWitnesses {
                    // FIX #1324: Witnesses are stale but valid — use as-is with their own anchor.
                    // Do NOT attempt per-witness rebuild: that would create witnesses at the CURRENT
                    // tree root while commonAnchor is at the STALE root → anchor mismatch in TX.
                    for note in selectedNotes {
                        preparedSpends.append((note: note, witness: note.witness, anchor: commonAnchor!))
                    }
                    print("✅ FIX #1324: Using \(preparedSpends.count) stale-but-valid witnesses directly")
                } else {
                    // FIX #557 v46: Ensure tree is loaded and rebuild any stale witnesses
                    if ZipherXFFI.treeSize() == 0 {
                        print("⚠️ FIX #557 v46: Global tree not loaded, loading from database...")
                        if let treeState = try? WalletDatabase.shared.getTreeState() {
                            if ZipherXFFI.treeDeserialize(data: treeState) {
                                print("✅ FIX #557 v46: Tree state loaded (size: \(ZipherXFFI.treeSize()))")
                            }
                        }
                    }

                    let currentTreeRoot = ZipherXFFI.treeRoot()
                    var rebuildCount = 0

                    for note in selectedNotes {
                        var witnessToUse = note.witness

                        // Check if witness is stale
                        if let wRoot = ZipherXFFI.witnessGetRoot(note.witness),
                           let tRoot = currentTreeRoot,
                           wRoot != tRoot {
                            print("⚠️ FIX #557 v46: Witness is stale, rebuilding...")
                            if let cmu = note.cmu, let cachedData = cachedBoostFileData {
                                if let result = ZipherXFFI.treeCreateWitnessForCMU(
                                    cmuData: cachedData,
                                    targetCMU: cmu
                                ) {
                                    witnessToUse = result.witness
                                    rebuildCount += 1
                                }
                            }
                        }

                        preparedSpends.append((note: note, witness: witnessToUse, anchor: commonAnchor!))
                    }

                    if rebuildCount > 0 {
                        print("✅ FIX #557 v46: Rebuilt \(rebuildCount)/\(selectedNotes.count) stale witnesses")
                    }
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

                // FIX #768: Only show "blocks behind" if actually behind, otherwise show "synced"
                let lagInfo = blocksBehind > 0 ? "\(blocksBehind) blocks behind" : "synced"
                print("⚡ FAST PATH: Checkpoint at \(lastScanned), chain at \(chainHeight) (\(lagInfo))")

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
                                // FIX #1107: Changed from 1028 to 100
                                if note.witness.count >= 100 {
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
                                    preparedSpends.append((note: note, witness: witness, anchor: newAnchor))
                                } else {
                                    throw TransactionError.proofGenerationFailed
                                }
                            }

                            // 6. Save updated tree state
                            // FIX #1138: Save tree state WITH HEIGHT
                            if let treeData = ZipherXFFI.treeSerialize() {
                                try? WalletDatabase.shared.saveTreeState(treeData, height: chainHeight)
                                try? WalletDatabase.shared.updateLastScannedHeight(chainHeight, hash: Data(count: 32))
                            }

                            print("✅ FIX #1138: FAST delta sync complete - \(preparedSpends.count) witnesses updated at height \(chainHeight)")
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
                        // Store the anchor from the witness rebuild!
                        preparedSpends.append((note: result.note, witness: result.witness, anchor: result.anchor))
                    }

                    // Use the anchor from the first result (all witnesses have same anchor)
                    if let firstResult = results.first {
                        let anchorHex = firstResult.anchor.prefix(8).map { String(format: "%02x", $0) }.joined()
                        print("📝 Using anchor from rebuilt witnesses: \(anchorHex)...")
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
                    // Store the anchor from the witness rebuild!
                    preparedSpends.append((note: result.note, witness: result.witness, anchor: result.anchor))
                }

                // Use the anchor from the first result (all witnesses have same anchor)
                if let firstResult = results.first {
                    let anchorHex = firstResult.anchor.prefix(8).map { String(format: "%02x", $0) }.joined()
                    print("📝 Using anchor from rebuilt witnesses: \(anchorHex)...")
                }
                print("✅ Created \(preparedSpends.count) witnesses with SAME anchor (at chain tip \(chainHeight))")
            }
        }

        // Now build the transaction using the prepared witnesses
        if selectedNotes.count > 1 {
            // CRITICAL: For multi-input, ensure we have prepared spends before building
            guard !preparedSpends.isEmpty else {
                print("❌ No prepared spends after witness building")
                throw TransactionError.proofGenerationFailed
            }

            // Build multi-input transaction — verify witnesses then generate proofs
            onProgress("building", "Verifying witnesses...", nil)

            // Convert preparedSpends to SpendInfoSwift array
            let spends = preparedSpends.map { spend in
                ZipherXFFI.SpendInfoSwift(
                    witness: spend.witness,
                    value: spend.note.value,
                    rcm: spend.note.rcm,
                    diversifier: spend.note.diversifier
                )
            }

            // VUL-002 FIX: Use encrypted key FFI for multi-input transaction
            let (encryptedKey, encryptionKey) = try SecureKeyStorage.shared.getEncryptedKeyAndPassword()
            print("🔐 VUL-002: Using encrypted key FFI (key decrypted only in Rust)")

            // FIX #803: Log spend info BEFORE FFI call for debugging
            print("🔍 FIX #803: Building multi-input TX with \(spends.count) spends")
            for (i, spend) in spends.enumerated() {
                print("   Spend \(i): witness=\(spend.witness.count) bytes, value=\(spend.value.redactedAmount)")
            }

            // FIX #838: CRITICAL - Verify ALL witnesses are consistent BEFORE building multi-input TX
            // Each witness must have merkle_path.root(cmu) == witness.root()
            for (i, prepared) in preparedSpends.enumerated() {
                if let cmu = prepared.note.cmu, !cmu.isEmpty {
                    if !ZipherXFFI.witnessVerifyAnchor(prepared.witness, cmu: cmu) {
                        let witnessRootHex = ZipherXFFI.witnessGetRoot(prepared.witness)?.prefix(8).map { String(format: "%02x", $0) }.joined() ?? "nil"
                        print("❌ FIX #838: WITNESS \(i) CORRUPTED - stored root (\(witnessRootHex)...) != merkle_path.root(cmu)")
                        print("   TX would be rejected by network with 'joinsplit requirements not met'")
                        print("   💡 Run 'Settings → Repair Database' to rebuild witnesses")
                        throw TransactionError.witnessCorrupted
                    }
                }
            }
            print("✅ FIX #838: All \(preparedSpends.count) witnesses verified consistent")

            // FIX #1137: CRITICAL - Verify ALL stored CMUs match CMUs computed from note parts
            // The Rust FFI recomputes CMU from note parts - if stored CMU differs, anchor will be wrong
            for (i, prepared) in preparedSpends.enumerated() {
                if let cmu = prepared.note.cmu, !cmu.isEmpty {
                    let cmuVerifyResult = ZipherXFFI.verifyNoteCMU(
                        storedCMU: cmu,
                        diversifier: prepared.note.diversifier,
                        rcm: prepared.note.rcm,
                        value: prepared.note.value,
                        spendingKey: spendingKey
                    )

                    if cmuVerifyResult == 0 {
                        let storedCMUHex = cmu.prefix(16).map { String(format: "%02x", $0) }.joined()
                        print("❌ FIX #1137: CMU MISMATCH on spend \(i)!")
                        print("   Stored CMU: \(storedCMUHex)...")
                        print("   But CMU computed from (diversifier, value, rcm) is DIFFERENT!")
                        print("   TX would be rejected by network with 'joinsplit requirements not met'")
                        print("   💡 Run 'Settings → Repair Database → Full Resync' to fix note data")
                        throw TransactionError.cmuMismatch
                    }
                }
            }
            print("✅ FIX #1137: All \(preparedSpends.count) CMUs verified matching")

            // FIX #1329: Signal proof generation phase — triggers Groth16 countdown in UI
            onProgress("proof", "\(preparedSpends.count) spends", nil)

            // FIX #1329: Timing instrumentation — track parallel Groth16 proof generation
            let proofStartTime = Date()
            print("⏱️ FIX #1329: Starting parallel Groth16 proof generation (\(spends.count) spends)...")

            guard let result = ZipherXFFI.buildTransactionMultiEncrypted(
                encryptedSpendingKey: encryptedKey,
                encryptionKey: encryptionKey,
                toAddress: toAddressBytes,
                amount: amount,
                memo: memoData,
                spends: spends,
                chainHeight: chainHeight
            ) else {
                let proofElapsed = Date().timeIntervalSince(proofStartTime)
                // FIX #803: Log detailed error for anchor mismatch debugging
                print("❌ FIX #803: ANCHOR MISMATCH - FFI multi-input transaction build failed! [⏱️ \(String(format: "%.2f", proofElapsed))s]")
                print("   Spends: \(spends.count), Chain height: \(chainHeight)")
                print("   💡 One or more witness merkle paths don't compute to their anchors - witnesses are corrupted")
                print("   💡 Run 'Settings → Repair Database' to rebuild witnesses")
                throw TransactionError.proofGenerationFailed
            }

            let proofElapsed = Date().timeIntervalSince(proofStartTime)
            print("✅ Multi-input transaction built: \(result.txData.count) bytes [⏱️ Groth16: \(String(format: "%.2f", proofElapsed))s for \(spends.count) spends]")
            print("📝 Spent \(spends.count) notes")

            // FIX #1402 (NEW-004): Persist the change diversifier index used in this TX
            let changeDivIndex = RustBridge.shared.getLastChangeDiversifierIndex()
            if changeDivIndex >= 1_000_000_000 {
                if let fvk = try? RustBridge.shared.deriveFullViewingKey(from: SaplingSpendingKey(data: spendingKey)),
                   let (changeAddr, _) = try? RustBridge.shared.derivePaymentAddress(from: fvk, diversifierIndex: changeDivIndex) {
                    try? WalletDatabase.shared.insertDiversifiedAddress(
                        accountId: 1,
                        diversifierIndex: changeDivIndex,
                        address: changeAddr,
                        label: "change"
                    )
                    print("📝 FIX #1402 (NEW-004): Persisted change diversifier index \(changeDivIndex)")
                }
            }

            // Return transaction and first nullifier (for tracking)
            return (result.txData, result.nullifiers.first ?? Data())
            } else {
                // SINGLE-INPUT TRANSACTION
                // FIX #591: Check if witness needs updating before using it
                //
                // CRITICAL: Sapling anchors must be RECENT for the network to accept the transaction!
                // Full nodes reject transactions with anchors that are too old (typically >100 blocks)
                //
                // Previous bug (FIX #563): Used stored witness directly without checking age
                // This caused "8 peers accepted but TX NOT FOUND in mempool" because:
                //   - Witness anchor was from note height (could be 10,000+ blocks old)
                //   - Full nodes silently reject transactions with stale anchors
                //   - Peers "accept" the broadcast message but don't add to mempool
                //
                // Fix (FIX #591):
                //   - If witness is recent (<100 blocks old): Use stored witness (fast)
                //   - If witness is stale (>100 blocks old): Rebuild witness to current tree state

                let note = selectedNotes[0]
                let noteHeight = note.height
                let blocksOld = chainHeight > noteHeight ? chainHeight - noteHeight : 0

                // FIX #591: Maximum anchor age - full nodes typically reject anchors older than this
                // FIX #602: Increased from 100 to 10000 to reduce slow witness rebuilds
                // Zclassic full nodes accept anchors much older than 100 blocks
                let maxAnchorAge: UInt64 = 10000

                var witnessToUse: Data = Data()
                var anchorToUse: Data = Data()

                // FIX #1013: REMOVED FIX #986's broken logic
                // FIX #986 was WRONG - it compared witness anchor to CURRENT tree root
                // But Sapling accepts ANY VALID HISTORICAL ANCHOR within the exclusion period
                // The witness anchor doesn't need to match the current tree state!
                // This was causing 60+ second rebuilds every time a new block arrived
                var usedFastPath = false
                var anchorMismatchDetected = false  // FIX #1018: Track if anchor doesn't match header

                // FIX #1160: Check if WITNESS anchor is current, not if NOTE is recent
                // Problem: blocksOld uses NOTE HEIGHT, but FIX #569 updates witness to CURRENT tree state
                // Example: Note at 2,951,000, chain at 3,004,000 → blocksOld = 53,000 (OLD)
                //          But witness was updated by FIX #569 to height 3,004,000 (CURRENT)
                // Solution: If witness anchor matches current tree root, use FAST PATH regardless of note age
                var witnessIsUpdated = false
                if note.witness.count > 0 {
                    if let witnessAnchor = ZipherXFFI.witnessGetRoot(note.witness),
                       let currentTreeRoot = ZipherXFFI.treeRoot() {
                        // Compare witness anchor to current FFI tree root
                        if witnessAnchor == currentTreeRoot {
                            witnessIsUpdated = true
                            print("✅ FIX #1160: Witness anchor matches current tree root - INSTANT SEND!")
                        } else {
                            let witnessHex = witnessAnchor.prefix(8).map { String(format: "%02x", $0) }.joined()
                            let treeHex = currentTreeRoot.prefix(8).map { String(format: "%02x", $0) }.joined()
                            print("⚠️ FIX #1160: Witness anchor \(witnessHex)... ≠ tree root \(treeHex)...")
                        }
                    }
                }

                if (blocksOld <= maxAnchorAge || witnessIsUpdated) && note.witness.count > 0 {
                    // FAST PATH: Witness is recent, use stored witness directly
                    // FIX #1013: Trust the witness if it's recent - the anchor is a valid historical root
                    print("⚡ FIX #1013: Using STORED witness (only \(blocksOld) blocks old) - INSTANT!")
                    witnessToUse = note.witness

                    // FIX #884: PREFER database anchor over witness-extracted anchor!
                    // FIX #569 updates the database anchor to current tree root.
                    // But the witness blob may still have the OLD anchor embedded.
                    // Using witness-extracted anchor causes "joinsplit requirements not met" errors!
                    let witnessRoot = ZipherXFFI.witnessGetRoot(witnessToUse)
                    let dbAnchor = note.anchor
                    let hasValidDbAnchor = dbAnchor.count == 32 && !dbAnchor.allSatisfy { $0 == 0 }
                    let hasValidWitnessRoot = witnessRoot != nil && !witnessRoot!.allSatisfy { $0 == 0 }

                    // FIX #1144: DISABLED FIX #884's anchor comparison - it was WRONG!
                    // FIX #884 compared dbAnchor != witnessRoot and forced rebuild if they differed.
                    // But this is INCORRECT because:
                    //   1. FIX #569 updates DB anchor to CURRENT tree root
                    //   2. Witness blob has its anchor from when witness was CREATED
                    //   3. After new blocks arrive, these will ALWAYS differ!
                    //   4. BUT the witness-embedded anchor IS VALID - it matches the merkle path
                    //   5. Sapling accepts ANY historical anchor - no need to match current root!
                    //
                    // The witness is VALID if:
                    //   - FIX #827: merkle_path.root(cmu) == witness.root() (already verified in preRebuild)
                    //   - FIX #1013: Anchor is non-zero
                    //
                    // USE the witness-embedded anchor directly - it's the correct historical root!
                    if let witnessRoot = witnessRoot {
                        anchorToUse = witnessRoot
                        let rootHex = witnessRoot.prefix(8).map { String(format: "%02x", $0) }.joined()
                        print("✅ FIX #1013: Witness anchor: \(rootHex)... (valid historical root)")

                        // FIX #1013: Verify anchor is non-zero (basic sanity check)
                        let isZeroAnchor = witnessRoot.allSatisfy { $0 == 0 }
                        if isZeroAnchor {
                            print("❌ FIX #1013: Witness has zero anchor - must rebuild")
                            // Fall through to slow path
                        } else {
                            // FIX #1204b: HeaderStore sapling roots ARE authoritative (FIX #1204).
                            // But note: witness anchor = chain TIP root, not note HEIGHT root.
                            // FIX #890 (below) correctly disables header comparison for ALL heights
                            // because comparing witness root to header[noteHeight] is wrong.
                            // The real validations are FIX #827 (merkle path), #1013 (non-zero), #884 (DB match).
                            let boostFileEndHeight = UInt64(ZipherXConstants.effectiveTreeHeight)
                            if noteHeight > boostFileEndHeight {
                                // FIX #1204b: Trust witness anchor (non-zero, validated by FIX #827/#1013/#884)
                                usedFastPath = true
                                print("✅ FIX #1204b: Note height \(noteHeight) > boost file \(boostFileEndHeight) - trusting witness anchor (validated)")
                            } else {
                                // FIX #890: DISABLED FIX #1018's header comparison - it was WRONG!
                                // FIX #1018 compared witness anchor to header root at NOTE HEIGHT, but:
                                //   1. preRebuildWitnessesForInstantPayment() builds witnesses at CHAIN TIP
                                //   2. Witness anchor = chain tip root ≠ note height root
                                //   3. This caused EVERY send to trigger slow rebuild!
                                //
                                // Sapling accepts ANY historical anchor - it doesn't have to be at note height.
                                // The correct validations (already done above) are:
                                //   - FIX #827 (in preRebuildWitnesses): merkle_path.root(cmu) == witness.root()
                                //   - FIX #1013: Non-zero anchor (basic sanity)
                                //   - FIX #884: DB anchor matches witness root (no stale mismatch)
                                //
                                // Trust the witness anchor - it's a valid historical root!
                                usedFastPath = true
                                print("✅ FIX #890: Trusting witness anchor (non-zero historical root) - INSTANT SEND!")
                            }
                        }
                    } else {
                        print("❌ FIX #591: Failed to extract anchor from witness!")
                        throw TransactionError.proofGenerationFailed
                    }
                }

                if !usedFastPath && (blocksOld > maxAnchorAge || note.witness.count == 0 || anchorMismatchDetected) {
                    // SLOW PATH: Witness is stale or corrupted, must rebuild to current tree state
                    if anchorMismatchDetected {
                        // FIX #884: Database anchor differs from witness-embedded anchor
                        // This is the most common case after FIX #569 updates DB anchor but witness blob is stale
                        print("⚠️ FIX #884: Witness/anchor mismatch - REBUILDING with current tree state")
                    } else {
                        print("⚠️ FIX #591: Witness is \(blocksOld) blocks old (max \(maxAnchorAge)) - REBUILDING to current tree state")
                    }
                    print("📝 Note height: \(noteHeight), chain height: \(chainHeight)")

                    let cachedBoostHeight = await CommitmentTreeUpdater.shared.getCachedBoostHeight() ?? 0
                    let results = try await rebuildWitnessesForNotes(
                        notes: [note],
                        downloadedTreeHeight: cachedBoostHeight,
                        chainHeight: chainHeight
                    )

                    guard let firstResult = results.first else {
                        print("❌ FIX #591: Failed to rebuild witness")
                        throw TransactionError.proofGenerationFailed
                    }

                    witnessToUse = firstResult.witness
                    anchorToUse = firstResult.anchor

                    let anchorHex = anchorToUse.prefix(8).map { String(format: "%02x", $0) }.joined()
                    print("✅ FIX #591: Rebuilt witness with CURRENT anchor: \(anchorHex)...")
                    print("✅ FIX #591: This anchor is at chain tip \(chainHeight) - network will accept it")

                    // FIX #605 + FIX #885: Persist rebuilt witness to database so future sends don't need to rebuild
                    // FIX #885: note.nullifier is ALREADY HASHED (from database via VUL-009)
                    // So we use getNoteByHashedNullifier() to avoid double-hashing
                    let database = WalletDatabase.shared
                    if let noteInfo = try? database.getNoteByHashedNullifier(hashedNullifier: note.nullifier) {
                        do {
                            try database.updateNoteWitness(noteId: noteInfo.id, witness: witnessToUse)
                            try database.updateNoteAnchor(noteId: noteInfo.id, anchor: anchorToUse)
                            print("💾 FIX #885: Saved rebuilt witness (\(witnessToUse.count) bytes) and anchor to database for note ID \(noteInfo.id)")
                        } catch {
                            print("⚠️ FIX #885: Failed to save witness to database: \(error.localizedDescription)")
                            // Non-fatal - transaction will still work, just won't be cached
                        }
                    } else {
                        print("⚠️ FIX #885: Could not find note ID by hashed nullifier - witness not saved to database")
                    }
                }

                print("📝 Note height: \(noteHeight), witness size: \(witnessToUse.count) bytes")

                // VUL-002 FIX: Use encrypted key FFI for single-input transaction
                let (encryptedKey, encryptionKey) = try SecureKeyStorage.shared.getEncryptedKeyAndPassword()
                print("🔐 VUL-002: Using encrypted key FFI (key decrypted only in Rust)")

                // FIX #803: Log anchor and witness info BEFORE FFI call for debugging
                let anchorHex = anchorToUse.prefix(16).map { String(format: "%02x", $0) }.joined()
                print("🔍 FIX #803: Building TX with anchor: \(anchorHex)... (witness: \(witnessToUse.count) bytes)")

                // FIX #838: CRITICAL - Verify witness consistency BEFORE building TX
                // The Sapling library uses merkle_path.root(node) to compute the anchor, NOT witness.root()
                // If these differ, the TX will be rejected by the network with "joinsplit requirements not met"
                if let cmu = note.cmu, !cmu.isEmpty {
                    if !ZipherXFFI.witnessVerifyAnchor(witnessToUse, cmu: cmu) {
                        let witnessRootHex = ZipherXFFI.witnessGetRoot(witnessToUse)?.prefix(8).map { String(format: "%02x", $0) }.joined() ?? "nil"
                        print("❌ FIX #838: WITNESS CORRUPTED - stored root (\(witnessRootHex)...) != merkle_path.root(cmu)")
                        print("   The merkle path computes to a DIFFERENT anchor than witness.root()")
                        print("   TX would be rejected by network with 'joinsplit requirements not met'")
                        print("   💡 Run 'Settings → Repair Database' to rebuild witnesses")
                        throw TransactionError.witnessCorrupted
                    }
                    print("✅ FIX #838: Witness consistency verified (stored root == computed anchor)")
                } else {
                    print("⚠️ FIX #838: Cannot verify witness consistency - CMU not available")
                }

                // FIX #1137: CRITICAL - Verify stored CMU matches CMU computed from note parts
                if let cmu = note.cmu, !cmu.isEmpty {
                    let cmuVerifyResult = ZipherXFFI.verifyNoteCMU(
                        storedCMU: cmu,
                        diversifier: note.diversifier,
                        rcm: note.rcm,
                        value: note.value,
                        spendingKey: spendingKey
                    )

                    if cmuVerifyResult == 0 {
                        let storedCMUHex = cmu.prefix(16).map { String(format: "%02x", $0) }.joined()
                        print("❌ FIX #1137: CMU MISMATCH DETECTED!")
                        print("   Stored CMU: \(storedCMUHex)...")
                        print("   But CMU computed from (diversifier, value, rcm) is DIFFERENT!")
                        print("   TX would be rejected by network with 'joinsplit requirements not met'")
                        print("   💡 Run 'Settings → Repair Database → Full Resync' to fix note data")
                        throw TransactionError.cmuMismatch
                    } else if cmuVerifyResult == 1 {
                        print("✅ FIX #1137: CMU integrity verified (stored CMU == computed CMU)")
                    }
                }

                // FIX #995: Timing instrumentation - track Groth16 proof generation
                let proofStartTime = Date()
                print("⏱️ FIX #995: Starting Groth16 proof generation...")

                guard let rawTx = ZipherXFFI.buildTransactionEncrypted(
                    encryptedSpendingKey: encryptedKey,
                    encryptionKey: encryptionKey,
                    toAddress: toAddressBytes,
                    amount: amount,
                    memo: memoData,
                    anchor: anchorToUse,
                    witness: witnessToUse,
                    noteValue: note.value,
                    noteRcm: note.rcm,
                    noteDiversifier: note.diversifier,
                    chainHeight: chainHeight
                ) else {
                    // FIX #803: Log detailed error for anchor mismatch debugging
                    let proofElapsed = Date().timeIntervalSince(proofStartTime)
                    print("❌ FIX #803: ANCHOR MISMATCH - FFI transaction build failed! [⏱️ \(String(format: "%.2f", proofElapsed))s]")
                    print("   Anchor used: \(anchorHex)...")
                    print("   Witness size: \(witnessToUse.count) bytes")
                    print("   Note height: \(noteHeight), Chain height: \(chainHeight)")
                    print("   💡 The witness merkle path doesn't compute to the anchor - witness is corrupted")
                    print("   💡 Run 'Settings → Repair Database' to rebuild witnesses")
                    throw TransactionError.proofGenerationFailed
                }

                // FIX #995: Log Groth16 proof generation time
                let proofElapsed = Date().timeIntervalSince(proofStartTime)
                print("✅ Transaction built: \(rawTx.count) bytes [⏱️ Groth16: \(String(format: "%.2f", proofElapsed))s]")

                // FIX #1402 (NEW-004): Persist the change diversifier index used in this TX
                let changeDivIndex = RustBridge.shared.getLastChangeDiversifierIndex()
                if changeDivIndex >= 1_000_000_000 {
                    if let fvk = try? RustBridge.shared.deriveFullViewingKey(from: SaplingSpendingKey(data: spendingKey)),
                       let (changeAddr, _) = try? RustBridge.shared.derivePaymentAddress(from: fvk, diversifierIndex: changeDivIndex) {
                        try? WalletDatabase.shared.insertDiversifiedAddress(
                            accountId: 1,
                            diversifierIndex: changeDivIndex,
                            address: changeAddr,
                            label: "change"
                        )
                        print("📝 FIX #1402 (NEW-004): Persisted change diversifier index \(changeDivIndex)")
                    }
                }

                return (rawTx, note.nullifier)
            }  // End of else (single-input)

        // Should never reach here, but Swift requires a return
        fatalError("Unreachable code reached - transaction building failed")
    }  // End of buildShieldedTransaction function

    // MARK: - Note Management

    // FIX #600: Accept cached chain height to avoid multiple network calls
    private func getSpendableNotes(for address: String, spendingKey: Data, cachedChainHeight: UInt64? = nil) async throws -> [SpendableNote] {
        // Query the wallet database for unspent notes
        let database = WalletDatabase.shared
        // Get correct account ID (database row ID starts at 1)
        guard let account = try database.getAccount(index: 0) else {
            print("📝 No account found in database")
            return []
        }
        // FIX #1330: Include notes with NULL witnesses — rebuilt on-demand during TX build
        let dbNotes = try database.getAllUnspentNotes(accountId: account.accountId)

        print("📝 Database returned \(dbNotes.count) unspent notes")

        // FIX #600: Use cached chain height from caller to avoid network call
        var chainHeight: UInt64
        if let cached = cachedChainHeight, cached > 0 {
            chainHeight = cached
            print("⚡ FIX #600: getSpendableNotes using cached chain height: \(chainHeight)")
        } else {
            // Fallback: get current chain height for confirmation calculation
            chainHeight = await MainActor.run { NetworkManager.shared.chainHeight }

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
            print("📝 Note: value=\(dbNote.value.redactedAmount), height=\(dbNote.height), chainHeight=\(chainHeight), confirmations=\(confirmations), witness=\(dbNote.witness.count) bytes")
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
                cmu: dbNote.cmu, // Note commitment for witness rebuild
                witnessIndex: dbNote.witnessIndex // FIX #557 v45: Track witness index for fresh retrieval
            )

            spendableNotes.append(note)
        }

        print("📝 Found \(spendableNotes.count) spendable notes")
        return spendableNotes
    }

    private func selectNotes(_ notes: [SpendableNote], targetAmount: UInt64) throws -> ([SpendableNote], UInt64) {
        // PRIVACY: P-TX-001 — Randomized note selection to prevent UTXO fingerprinting
        var selected: [SpendableNote] = []
        var total: UInt64 = 0

        let shuffledNotes = notes.shuffled()
        let sortedNotes: [SpendableNote]
        if let exactFit = shuffledNotes.first(where: { $0.value >= targetAmount && $0.value <= targetAmount * 2 }) {
            sortedNotes = [exactFit] + shuffledNotes.filter { $0.position != exactFit.position }
        } else {
            sortedNotes = shuffledNotes.sorted { a, b in
                if Bool.random() && Bool.random() { return a.value < b.value }
                return a.value > b.value
            }
        }

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

    /// FIX #580 v2: Fast witness generation using in-memory CMU cache (~1ms vs 84s P2P rebuild)
    /// Returns nil if fast path fails (caller should fall back to slow P2P rebuild)
    private func buildWitnessFastPath(
        cmu: Data,
        noteHeight: UInt64
    ) async throws -> (witness: Data, anchor: Data)? {
        // Get CMU data from in-memory cache (already loaded ~32MB)
        guard let cachedData = await FastWalletCache.shared.getTreeData() else {
            print("⚠️ FIX #580 v2: FastWalletCache CMU data not available")
            return nil
        }

        // Find CMU position in cached data
        guard let position = ZipherXFFI.findCMUPosition(cmuData: cachedData, targetCMU: cmu),
              position != UInt64.max else {
            print("❌ FIX #580 v2: CMU not found in cached data")
            return nil
        }

        // Get witness from in-memory CMU data - INSTANT (~1ms)
        guard let witnessResult = ZipherXFFI.treeCreateWitnessForPosition(
            treeData: cachedData,
            position: position
        ) else {
            print("❌ FIX #580 v2: Fast witness generation failed")
            return nil
        }

        // Get anchor from tree root
        guard let anchor = ZipherXFFI.treeRoot() else {
            print("❌ FIX #580 v2: Failed to get tree root")
            return nil
        }

        print("⚡ FIX #580 v2: Witness generated in ~1ms (was 84s P2P rebuild!)")
        print("   Witness: \(witnessResult.witness.count) bytes")
        print("   Position: \(position)")
        print("   Anchor: \(anchor.prefix(8).map { String(format: "%02x", $0) }.joined()...)")

        return (witness: witnessResult.witness, anchor: anchor)
    }

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
        // FIX #580: FAST PATH - Try FastWalletCache first (<1ms vs 84s P2P rebuild)
        if await FastWalletCache.shared.getIsValid() {
            print("⚡ FIX #580: Using FAST PATH - in-memory tree witness generation (<1ms vs 84s P2P rebuild)")

            // Try fast path - return result if successful, otherwise fall through to slow path
            if let fastResult = try? await buildWitnessFastPath(cmu: cmu, noteHeight: noteHeight) {
                return fastResult
            }
            // Fall through to slow path if fast path failed
        }

        // SLOW PATH: P2P block fetching (84 seconds) - only used if cache not available
        print("⚠️ FIX #580: FAST PATH not available, using slow P2P rebuild (84 seconds)...")
        print("   This should only happen on first startup or after cache clear")

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
        let cachedCount = cachedData.prefix(8).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
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

        // 4. Fetch additional CMUs from blocks between downloadedTreeHeight+1 and targetHeight
        // FIX #115: Fetch to targetHeight (chain tip), not just noteHeight
        let startHeight = downloadedTreeHeight + 1
        print("📡 Fetching CMUs from blocks \(startHeight) to \(targetHeight)...")

        // FIX #1225: Batch fetch with error handling - fail fast if P2P fetch fails
        let allDeltaCMUs: [Data]
        do {
            allDeltaCMUs = try await fetchCMUsFromBlocks(startHeight: startHeight, endHeight: targetHeight)
            print("📊 Got \(allDeltaCMUs.count) CMUs from blocks \(startHeight) to \(targetHeight)")
        } catch TransactionError.deltaCMUsFetchFailed(let blockRange) {
            print("❌ FIX #1225: Cannot rebuild witness - failed to fetch \(blockRange) blocks of delta CMUs")
            return nil
        } catch {
            print("❌ Unexpected error fetching delta CMUs: \(error)")
            return nil
        }

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

        // FIX #1226: Verify anchor exists on blockchain before returning witness
        // Same defense as multi-note path — prevents stale witnesses from incomplete tree
        let singleAnchorOnChain = await HeaderStore.shared.containsSaplingRoot(anchor)
        if !singleAnchorOnChain {
            print("🚨 FIX #1226: Single-note witness anchor \(rootHex.prefix(16))... NOT FOUND in HeaderStore!")
            print("🚨 FIX #1226: Tree was built from incomplete delta CMUs — returning nil")
            return nil
        }
        print("✅ FIX #1226: Single-note witness anchor verified on blockchain")

        // FIX #1190: Update delta manifest tree root now that we've computed the anchor
        DeltaCMUManager.shared.updateManifestTreeRoot(anchor)

        // 7. CRITICAL: Save updated tree to database for future transactions
        // This avoids re-fetching CMUs from chain next time
        // FIX #1138: Save tree state WITH HEIGHT
        if let serializedTree = ZipherXFFI.treeSerialize() {
            try? WalletDatabase.shared.saveTreeState(serializedTree, height: targetHeight)
            print("💾 FIX #1138: Updated tree state saved at height \(targetHeight)")
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
        var targetHeight: UInt64
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

        // 2. Get boost CMU data — prefer FastWalletCache (in-memory) over file extraction
        // FIX #1313: FastWalletCache already has boost CMU data loaded (~32MB in RAM)
        let boostCMUData: Data
        if let cachedData = await FastWalletCache.shared.getTreeData() {
            boostCMUData = cachedData
            print("⚡ FIX #1313: Using boost CMU data from FastWalletCache (instant, ~\(cachedData.count / 1_000_000)MB)")
        } else {
            print("📦 Extracting CMUs from boost file...")
            boostCMUData = try await CommitmentTreeUpdater.shared.extractCMUsInLegacyFormat { progress in
                if Int(progress * 100) % 10 == 0 {
                    print("   Extracting boost CMUs: \(Int(progress * 100))%")
                }
            }
        }

        // Parse CMU count from boost data
        guard boostCMUData.count >= 8 else { throw TransactionError.proofGenerationFailed }
        let boostCMUCount = boostCMUData.prefix(8).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
        print("📊 Boost file has \(boostCMUCount) CMUs up to height \(downloadedTreeHeight)")

        // 3. Get delta CMUs — prefer LOCAL DeltaCMUManager over P2P fetch
        // FIX #1313: P2P fetching produces wrong tree root because:
        //   - P2P may return blocks out of order (even with FIX #1199 sorting)
        //   - P2P may silently miss blocks (incomplete delta, FIX #1185)
        //   - P2P-fetched CMUs differ from DeltaCMUManager CMUs used to build the global FFI tree
        // Using DeltaCMUManager ensures the batch tree matches the FFI tree root exactly.
        var deltaCMUs: [Data] = []
        if targetHeight > downloadedTreeHeight {
            // PRIORITY 1: Use local DeltaCMUManager (instant, matches FFI tree)
            if let localDeltaCMUs = DeltaCMUManager.shared.loadDeltaCMUs(), !localDeltaCMUs.isEmpty {
                deltaCMUs = localDeltaCMUs
                if let manifest = DeltaCMUManager.shared.getManifest() {
                    // Cap target height to what delta actually covers
                    targetHeight = min(targetHeight, manifest.endHeight)
                    print("⚡ FIX #1313: Using \(deltaCMUs.count) local delta CMUs (instant! covers up to height \(targetHeight))")
                } else {
                    print("⚡ FIX #1313: Using \(deltaCMUs.count) local delta CMUs (no manifest)")
                }
            } else {
                // PRIORITY 2: P2P fetch (only when no local delta exists)
                let startHeight = downloadedTreeHeight + 1
                print("📡 FIX #1313: No local delta, fetching CMUs via P2P from \(startHeight) to \(targetHeight)...")
                deltaCMUs = try await fetchCMUsFromBlocks(startHeight: startHeight, endHeight: targetHeight)
                let blockRange = targetHeight - startHeight + 1
                print("📊 Fetched \(deltaCMUs.count) delta CMUs from P2P (covering \(blockRange) blocks)")

                if deltaCMUs.isEmpty && blockRange > 1000 {
                    print("🚨 FIX #1226: Got 0 CMUs from \(blockRange) blocks — refusing stale data")
                    throw TransactionError.deltaCMUsFetchFailed(blockRange: blockRange)
                }
            }
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

        // 6. Get anchor FROM THE FIRST SUCCESSFUL WITNESS (NOT from global tree!)
        // CRITICAL: treeCreateWitnessesBatch builds its OWN local tree, NOT the global COMMITMENT_TREE.
        // So ZipherXFFI.treeRoot() returns the WRONG anchor - it returns the global tree's root.
        // We must extract the anchor from the witness data itself using witnessGetRoot().
        // FIX #1030: Find first SUCCESSFUL witness (not necessarily the first element)
        var anchor: Data? = nil
        for result in batchResults {
            if let (_, witness) = result {
                anchor = ZipherXFFI.witnessGetRoot(witness)
                if anchor != nil {
                    break
                }
            }
        }

        // FIX #1030: Only fail if NO witnesses succeeded at all
        guard let validAnchor = anchor else {
            print("❌ FIX #1030: ALL witnesses failed - no anchor available")
            throw TransactionError.proofGenerationFailed
        }
        let rootHex = validAnchor.map { String(format: "%02x", $0) }.joined()
        print("📝 Extracted anchor from witness (same for all): \(rootHex.prefix(16))...")

        // FIX #1226: Verify witness anchor EXISTS on blockchain before saving witnesses!
        // Even if witness creation succeeded internally (correct merkle path), the anchor
        // may not exist on the blockchain if the tree was built from incomplete delta CMUs.
        // This is the LAST DEFENSE against stale witnesses being saved to the database.
        // FIX #1224 checks at startup and pre-build, but this checks at CREATION TIME.
        let anchorOnChain = await HeaderStore.shared.containsSaplingRoot(validAnchor)
        if !anchorOnChain {
            // FIX #1279: NEVER bypass — phantom witness anchors produce phantom TXs
            print("🚨 FIX #1279: Witness anchor \(rootHex.prefix(16))... NOT FOUND in HeaderStore!")
            print("🚨 FIX #1279: Witnesses were created from incomplete/corrupted tree — REJECTING ALL")
            print("🚨 FIX #1279: This prevents phantom witnesses from being saved to database")
            // FIX #1574: Set exhausted flag so callers don't immediately retry in a tight loop.
            // Without this: FIX #1082 → FIX #1027 → rebuildWitnessesForNotes → reject → repeat (41s loop).
            // Cleared when gap-fill succeeds or Full Rescan completes.
            UserDefaults.standard.set(true, forKey: "TreeRepairExhausted")
            print("🛑 FIX #1574: Blocking witness rebuilds until tree root is repaired")
            throw TransactionError.anchorNotOnChain
        }
        print("✅ FIX #1226: Witness anchor verified in HeaderStore")

        // FIX #1190: Update delta manifest tree root now that we've computed the anchor
        DeltaCMUManager.shared.updateManifestTreeRoot(validAnchor)

        // 7. Build results with same anchor for all (all witnesses from same batch have same root)
        // FIX #1030: Don't throw on individual note failures - process what we can!
        // If some notes fail, we still save the successful ones. Failed notes will be
        // rebuilt on-demand when user tries to spend them, NOT by triggering a full rescan.
        var results: [(note: SpendableNote, witness: Data, anchor: Data)] = []
        var failedNotes: [(index: Int, height: UInt64)] = []
        for (index, result) in batchResults.enumerated() {
            let note = sortedNotes[index]
            if let (position, witness) = result {
                results.append((note: note, witness: witness, anchor: validAnchor))
                print("   ✅ Note \(index + 1): position \(position), witness \(witness.count) bytes")
            } else {
                // FIX #1030: Log but DON'T throw - continue with other notes
                failedNotes.append((index: index + 1, height: note.height))
                print("   ⚠️ Note \(index + 1): SKIPPED - witness creation failed at height \(note.height)")
            }
        }

        // FIX #1030: Log summary of failures (if any) but don't block other notes
        if !failedNotes.isEmpty {
            print("⚠️ FIX #1030: \(failedNotes.count)/\(sortedNotes.count) notes failed witness creation (will rebuild on-demand)")
            for failed in failedNotes {
                print("   - Note \(failed.index) at height \(failed.height)")
            }
        }

        // 8. FIX #593 + FIX #1073: Sync LOCAL tree to GLOBAL tree IF it's newer
        // FIX #1073: CRITICAL BUG FIX - DON'T overwrite if FFI tree has MORE CMUs!
        // Previous bug: FFI tree had 1046464 CMUs, combinedCMUData had 1046446
        // FIX #593 overwrote FFI tree → used stale root → "joinsplit requirements not met"
        let currentFFITreeSize = ZipherXFFI.treeSize()
        let combinedCMUCount = Int(totalCMUCount)

        if combinedCMUCount >= currentFFITreeSize {
            // Combined data is newer or same - safe to load
            if ZipherXFFI.treeLoadFromCMUs(data: combinedCMUData) {
                let newTreeSize = ZipherXFFI.treeSize()
                let newTreeRoot = ZipherXFFI.treeRoot()?.prefix(16).map { String(format: "%02x", $0) }.joined() ?? "unknown"
                print("✅ FIX #593: Loaded LOCAL tree into GLOBAL tree - now in sync!")
                print("✅ FIX #593: Global tree now has \(newTreeSize) CMUs, root: \(newTreeRoot)...")
            } else {
                print("⚠️ FIX #593: Failed to load LOCAL tree into GLOBAL tree - root mismatch possible!")
            }
        } else {
            // FIX #1073: FFI tree has MORE CMUs - DON'T overwrite!
            // The witness was built with stale data, but the FFI tree is correct
            // The witness anchor (from combinedCMUData) may be invalid!
            print("🚨 FIX #1073: FFI tree has \(currentFFITreeSize) CMUs > combined \(combinedCMUCount) CMUs")
            print("🚨 FIX #1073: NOT overwriting FFI tree - witness may have STALE anchor!")
            // Note: The witness created here uses the combinedCMUData tree (stale)
            // This is a serious issue - the caller should rebuild with current tree
        }

        // 9. Save updated tree state to database
        // FIX #1138: Save tree state WITH HEIGHT
        if let serializedTree = ZipherXFFI.treeSerialize() {
            try? WalletDatabase.shared.saveTreeState(serializedTree, height: targetHeight)
            print("💾 FIX #1138: Updated tree state saved at height \(targetHeight)")
        }

        print("✅ Rebuilt \(results.count) witnesses with SAME anchor using boost + delta")
        return results
    }

    /// Fetch CMUs from a range of blocks using P2P first, then InsightAPI fallback
    /// This batches requests to reduce log spam and uses P2P when Tor mode is enabled
    /// FIX #1225: Now throws when P2P fetch fails with empty CMUs (prevents stale witness creation)
    internal func fetchCMUsFromBlocks(startHeight: UInt64, endHeight: UInt64) async throws -> [Data] {
        var allCMUs: [Data] = []
        let networkManager = NetworkManager.shared
        let torEnabled = await TorManager.shared.mode == .enabled

        // PRIORITY 1: Check local delta bundle first (instant, no network!)
        // This enables instant witness generation for notes after the bundled tree
        // CRITICAL: Delta must FULLY cover the requested range to be used!
        // FIX #115: MUST validate delta against headers BEFORE using (corrupted delta = wrong anchor = rejected tx)
        let deltaManager = DeltaCMUManager.shared
        if let deltaManifest = deltaManager.getManifest() {
            // CRITICAL FIX #115: Validate delta bundle against headers BEFORE using
            // If validation fails (no header available, root mismatch), DO NOT use delta
            // FIX #1252: When delta is verified (immutable), skip re-validation — trust it.
            let deltaVerified = UserDefaults.standard.bool(forKey: "DeltaBundleVerified")
            let deltaValid: Bool
            if deltaVerified {
                deltaValid = true
            } else {
                deltaValid = await deltaManager.validateTreeRootAgainstHeaders()
            }
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

                            // FIX #995: CRITICAL - Fetch ONLY the remaining blocks, not the full range!
                            // BUG: P2P was fetching from startHeight (2988798) instead of remaining start (2997538)
                            // This caused tree to be built with incomplete CMUs → wrong anchor → TX rejected!
                            let p2pStartHeight = deltaManifest.endHeight + 1
                            let p2pBlockCount = Int(endHeight - p2pStartHeight + 1)
                            print("📦 FIX #995: P2P will fetch \(p2pBlockCount) remaining blocks from \(p2pStartHeight) to \(endHeight)")

                            // FIX #1062: Stop block listeners before P2P fetch (partial coverage path)
                            print("🛑 FIX #1062: Stopping block listeners before partial P2P fetch...")
                            let partialStopped = await PeerManager.shared.ensureAllBlockListenersStopped(maxRetries: 3, retryDelay: 1.0)
                            if !partialStopped {
                                print("⚠️ FIX #1062: Some block listeners still running - partial P2P fetch may fail")
                            }

                            // FIX #1228: Reconnect peers with dead connections after stopping block listeners.
                            // FIX #1184b kills NWConnections → peers have handshake=true but connection=nil.
                            let deadPeersTxPartial = await MainActor.run {
                                networkManager.peers.filter { $0.isHandshakeComplete && !$0.isConnectionReady }
                            }
                            if !deadPeersTxPartial.isEmpty {
                                print("🔄 FIX #1228: Reconnecting \(deadPeersTxPartial.count) peers with dead connections (TX partial P2P fetch)...")
                                var reconnectedTxPartial = Set<String>()  // FIX #1235
                                for peer in deadPeersTxPartial {
                                    if reconnectedTxPartial.contains(peer.host) { print("⏭️ FIX #1235: [\(peer.host)] Already reconnected - skipping"); continue }
                                    do {
                                        try await peer.ensureConnected()
                                        reconnectedTxPartial.insert(peer.host)  // FIX #1235
                                        print("✅ FIX #1228: [\(peer.host)] Reconnected for TX partial P2P fetch")
                                    } catch {
                                        print("⚠️ FIX #1228: [\(peer.host)] Reconnect failed: \(error.localizedDescription)")
                                    }
                                }
                            }

                            // FIX #877: Drain socket buffers after stopping block listeners
                            print("🚿 FIX #877: Draining socket buffers before partial P2P fetch...")
                            let partialConnectedPeers = await networkManager.peers.filter { $0.isConnectionReady }
                            await withTaskGroup(of: Void.self) { group in
                                for peer in partialConnectedPeers {
                                    group.addTask {
                                        await peer.drainSocketBuffer()
                                    }
                                }
                            }

                            // FIX #1066: Use NetworkManager.getBlocksDataP2P which paginates properly
                            // Previous code used peer.getFullBlocks directly which only got 160 blocks max
                            do {
                                let blocksData = try await networkManager.getBlocksDataP2P(
                                    from: p2pStartHeight,
                                    count: p2pBlockCount
                                )

                                // Extract CMUs from the returned blocks
                                // FIX #1067: Convert hex string CMUs to Data format
                                // FIX #1190: Also collect full delta outputs for local caching
                                var partialDeltaOutputs: [DeltaCMUManager.DeltaOutput] = []
                                for (height, _, _, transactions) in blocksData {
                                    var blockOutputIndex: UInt32 = 0
                                    for (_, outputs, _) in transactions {
                                        for output in outputs {
                                            if let cmuData = Data(hex: output.cmu) {
                                                allCMUs.append(cmuData)
                                                // FIX #1311: ALWAYS store delta entry when CMU is valid
                                                let epk = Data(hex: output.ephemeralKey).map { Data($0.reversed()) } ?? Data(count: 32)
                                                let ciphertext = Data(hex: output.encCiphertext) ?? Data(count: 580)
                                                let deltaOutput = DeltaCMUManager.DeltaOutput(
                                                    height: UInt32(height),
                                                    index: blockOutputIndex,
                                                    cmu: Data(cmuData.reversed()),
                                                    epk: epk,
                                                    ciphertext: ciphertext
                                                )
                                                partialDeltaOutputs.append(deltaOutput)
                                            }
                                            blockOutputIndex += 1
                                        }
                                    }
                                }

                                // FIX #1190: Append P2P remainder outputs to existing delta
                                if !partialDeltaOutputs.isEmpty {
                                    let existingRoot = DeltaCMUManager.shared.getDeltaTreeRoot() ?? Data(count: 32)
                                    DeltaCMUManager.shared.appendOutputs(partialDeltaOutputs, toHeight: endHeight, treeRoot: existingRoot)
                                    print("📦 FIX #1190: Appended \(partialDeltaOutputs.count) delta outputs from P2P remainder (tree root pending)")
                                } else if blocksData.count > 0 {
                                    let existingRoot = DeltaCMUManager.shared.getDeltaTreeRoot() ?? Data(count: 32)
                                    DeltaCMUManager.shared.appendOutputs([], toHeight: endHeight, treeRoot: existingRoot)
                                    print("📦 FIX #1190: Updated delta end height to \(endHeight) (no new outputs in P2P remainder)")
                                }

                                // FIX #995: Verify we got enough blocks
                                if blocksData.count < p2pBlockCount {
                                    let coverage = Double(blocksData.count) / Double(p2pBlockCount) * 100.0
                                    if coverage < 95.0 {
                                        print("⚠️ FIX #995: Only got \(blocksData.count)/\(p2pBlockCount) blocks (\(String(format: "%.1f", coverage))%)")
                                    }
                                }

                                print("✅ FIX #1066: Got \(blocksData.count) remaining blocks (\(allCMUs.count) total CMUs)")
                                // FIX #1062: Resume block listeners after successful partial P2P fetch
                                print("▶️ FIX #1062: Resuming block listeners after partial P2P success")
                                await PeerManager.shared.resumeAllBlockListeners()
                                return allCMUs
                            } catch {
                                print("⚠️ FIX #1066: P2P fetch failed: \(error.localizedDescription)")
                            }

                            // FIX #1226: CRITICAL — Do NOT return partial delta CMUs when P2P fails!
                            // Previous bug: Returned partial delta CMUs (covering up to deltaManifest.endHeight)
                            // but caller expected CMUs covering FULL range (startHeight to endHeight).
                            // Witness built from partial tree has STALE anchor → TX rejection or undetected spends.
                            // Must throw error so caller knows data is incomplete.
                            print("❌ FIX #1226: P2P failed for remaining \(p2pBlockCount) blocks — partial delta is INCOMPLETE")
                            print("❌ FIX #1226: Delta covers \(deltaManifest.startHeight)-\(deltaManifest.endHeight), but need up to \(endHeight)")
                            // FIX #1062: Resume block listeners after partial P2P attempts failed
                            print("▶️ FIX #1062: Resuming block listeners after partial P2P failed")
                            await PeerManager.shared.resumeAllBlockListeners()
                            throw TransactionError.deltaCMUsFetchFailed(blockRange: UInt64(p2pBlockCount))
                        }
                    }
                } else {
                    // GAP: Delta starts AFTER our requested range - cannot use delta!
                    print("📦 DeltaCMU: GAP detected! Delta starts at \(deltaManifest.startHeight) but we need \(startHeight). Using P2P...")
                }
            }
        }

        // PRIORITY 2: Try P2P (especially important for Tor mode)
        // FIX #1064: Wait for peers to connect before attempting P2P fetch
        // At startup, peers may not be connected yet - wait up to 30s
        var connectedPeers = await MainActor.run { networkManager.getAllConnectedPeers() }
        if connectedPeers.isEmpty {
            print("⏳ FIX #1064: No peers connected - waiting up to 30s for P2P network...")
            for i in 1...30 {
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
                connectedPeers = await MainActor.run { networkManager.getAllConnectedPeers() }
                if !connectedPeers.isEmpty {
                    print("✅ FIX #1064: \(connectedPeers.count) peer(s) connected after \(i)s - proceeding with P2P fetch")
                    break
                }
                if i % 10 == 0 {
                    print("⏳ FIX #1064: Still waiting for peers... (\(i)/30s)")
                }
            }
        }

        if !connectedPeers.isEmpty {
            let blockCount = Int(endHeight - startHeight + 1)
            print("📡 FIX #1065: Fetching delta CMUs via P2P (blocks \(startHeight)-\(endHeight), count=\(blockCount))...")

            // FIX #1062: CRITICAL - Stop block listeners BEFORE P2P fetch!
            print("🛑 FIX #1062: Stopping block listeners before P2P delta CMU fetch...")
            let allStopped = await PeerManager.shared.ensureAllBlockListenersStopped(maxRetries: 3, retryDelay: 1.0)
            if !allStopped {
                print("⚠️ FIX #1062: Some block listeners still running - P2P fetch may fail")
            } else {
                print("✅ FIX #1062: All block listeners stopped - P2P fetch safe to proceed")
            }

            // FIX #1228: Reconnect peers with dead connections after stopping block listeners.
            // FIX #1184b kills NWConnections → peers have handshake=true but connection=nil.
            let deadPeersTxFull = await MainActor.run {
                networkManager.peers.filter { $0.isHandshakeComplete && !$0.isConnectionReady }
            }
            if !deadPeersTxFull.isEmpty {
                print("🔄 FIX #1228: Reconnecting \(deadPeersTxFull.count) peers with dead connections (TX full P2P fetch)...")
                var reconnectedTxFull = Set<String>()  // FIX #1235
                for peer in deadPeersTxFull {
                    if reconnectedTxFull.contains(peer.host) { print("⏭️ FIX #1235: [\(peer.host)] Already reconnected - skipping"); continue }
                    do {
                        try await peer.ensureConnected()
                        reconnectedTxFull.insert(peer.host)  // FIX #1235
                        print("✅ FIX #1228: [\(peer.host)] Reconnected for TX full P2P fetch")
                    } catch {
                        print("⚠️ FIX #1228: [\(peer.host)] Reconnect failed: \(error.localizedDescription)")
                    }
                }
            }

            // FIX #877: Drain socket buffers after stopping block listeners
            // Prevents "INVALID MAGIC BYTES" from stale data in TCP buffers
            print("🚿 FIX #877: Draining socket buffers before P2P fetch...")
            let connectedPeers = await networkManager.peers.filter { $0.isConnectionReady }
            await withTaskGroup(of: Void.self) { group in
                for peer in connectedPeers {
                    group.addTask {
                        await peer.drainSocketBuffer()
                    }
                }
            }

            // FIX #1065: Use NetworkManager.getBlocksDataP2P which properly paginates
            // Previous bug: peer.getFullBlocks tried to get ALL blocks in one request
            // But P2P protocol limits to 160 blocks per request → only got 160/11070 (1.4%)
            // NetworkManager.getBlocksDataP2P handles pagination (500 blocks at a time)
            do {
                let blocksData = try await networkManager.getBlocksDataP2P(
                    from: startHeight,
                    count: blockCount
                )

                // Extract CMUs from the returned blocks
                // FIX #1067: Convert hex string CMUs to Data format
                // FIX #1190: Also collect full delta outputs for local caching
                var deltaOutputs: [DeltaCMUManager.DeltaOutput] = []
                for (height, _, _, transactions) in blocksData {
                    var blockOutputIndex: UInt32 = 0
                    for (_, outputs, _) in transactions {
                        for output in outputs {
                            if let cmuData = Data(hex: output.cmu) {
                                allCMUs.append(cmuData)
                                // FIX #1311: ALWAYS store delta entry when CMU is valid
                                let epk = Data(hex: output.ephemeralKey).map { Data($0.reversed()) } ?? Data(count: 32)
                                let ciphertext = Data(hex: output.encCiphertext) ?? Data(count: 580)
                                let deltaOutput = DeltaCMUManager.DeltaOutput(
                                    height: UInt32(height),
                                    index: blockOutputIndex,
                                    cmu: Data(cmuData.reversed()),
                                    epk: epk,
                                    ciphertext: ciphertext
                                )
                                deltaOutputs.append(deltaOutput)
                            }
                            blockOutputIndex += 1
                        }
                    }
                }

                // FIX #1190: Save delta outputs from P2P fetch (tree root updated by caller)
                if !deltaOutputs.isEmpty {
                    let existingRoot = DeltaCMUManager.shared.getDeltaTreeRoot() ?? Data(count: 32)
                    DeltaCMUManager.shared.appendOutputs(deltaOutputs, fromHeight: startHeight, toHeight: endHeight, treeRoot: existingRoot)
                    print("📦 FIX #1190: Saved \(deltaOutputs.count) delta outputs from P2P fetch (tree root pending caller update)")
                } else if blocksData.count > 0 {
                    // FIX #1190: Even if no shielded outputs, update delta end height
                    let existingRoot = DeltaCMUManager.shared.getDeltaTreeRoot() ?? Data(count: 32)
                    DeltaCMUManager.shared.appendOutputs([], fromHeight: startHeight, toHeight: endHeight, treeRoot: existingRoot)
                    print("📦 FIX #1190: Updated delta end height to \(endHeight) (no new shielded outputs in range)")
                }

                print("✅ FIX #1065: P2P fetch complete - got \(allCMUs.count) CMUs from \(blocksData.count) blocks")

                // FIX #995: Verify we got enough blocks
                if blocksData.count < blockCount {
                    let coverage = Double(blocksData.count) / Double(blockCount) * 100.0
                    if coverage < 95.0 {
                        print("⚠️ FIX #995: Only got \(blocksData.count)/\(blockCount) blocks (\(String(format: "%.1f", coverage))%) - may have incomplete CMUs")
                    }
                }

                // FIX #1062: Resume block listeners after successful P2P fetch
                print("▶️ FIX #1062: Resuming block listeners after successful P2P fetch")
                await PeerManager.shared.resumeAllBlockListeners()
            } catch {
                print("⚠️ FIX #1065: P2P fetch failed: \(error.localizedDescription)")
                // FIX #1062: Resume block listeners after P2P attempts failed
                print("▶️ FIX #1062: Resuming block listeners after P2P failed")
                await PeerManager.shared.resumeAllBlockListeners()
            }
        }

        // FIX #1064: REMOVED InsightAPI fallback - ZipherX is P2P ONLY!
        // InsightAPI is a centralized service that violates ZipherX's privacy design.
        // If P2P fails (e.g., no peers at startup), return empty and let caller handle retry.
        // The caller should wait for peers to connect and retry, not use centralized API.

        // FIX #1225: CRITICAL - Throw error when P2P fails with empty CMUs
        // Previous bug: Returned empty array → caller created witnesses with stale data (boost only)
        // → witnesses had wrong anchors → TX rejected or spends went undetected.
        // MUST fail fast when delta CMUs are required but unavailable.
        if allCMUs.isEmpty && endHeight > startHeight {
            print("❌ FIX #1225: P2P delta CMU fetch FAILED - no CMUs retrieved for \(endHeight - startHeight + 1) blocks")
            print("❌ FIX #1225: Cannot create witnesses with stale data - throwing error")
            throw TransactionError.deltaCMUsFetchFailed(blockRange: endHeight - startHeight + 1)
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
            // FIX #1218: Track received vs expected for incomplete detection
            var totalReceived: UInt64 = 0
            var consecutiveEmptyBatches = 0

            while currentStart <= endHeight {
                let batchEnd = min(currentStart + UInt64(batchSize) - 1, endHeight)
                let batchCount = Int(batchEnd - currentStart + 1)

                let blocks = try await NetworkManager.shared.getBlocksOnDemandP2P(from: currentStart, count: batchCount)

                // FIX #1218: Track which heights actually arrived
                var batchReceivedHeights = Set<UInt64>()
                for block in blocks {
                    batchReceivedHeights.insert(block.blockHeight)
                    for tx in block.transactions {
                        for output in tx.outputs {
                            // CMU from CompactBlock.CompactOutput is already in wire format (little-endian)
                            allCMUs.append(output.cmu)
                        }
                    }
                }
                totalReceived += UInt64(batchReceivedHeights.count)

                print("📦 P2P batch: \(currentStart)-\(batchEnd) → \(blocks.count) blocks (\(batchReceivedHeights.count)/\(batchCount) heights)")

                // FIX #1218: Strict height advancement — only advance to highest received + 1
                if batchReceivedHeights.isEmpty {
                    consecutiveEmptyBatches += 1
                    print("⚠️ FIX #1218: Empty batch \(currentStart)-\(batchEnd) (failure \(consecutiveEmptyBatches)/3)")
                    if consecutiveEmptyBatches >= 3 {
                        print("🛑 FIX #1218: 3 consecutive empty batches — aborting CMU fetch")
                        break
                    }
                    continue  // Retry same range
                } else {
                    consecutiveEmptyBatches = 0
                    let maxReceivedHeight = batchReceivedHeights.max()!
                    if batchReceivedHeights.count < batchCount / 2 {
                        // Less than 50% — advance only to what we received
                        print("⚠️ FIX #1218: Incomplete batch — advancing to \(maxReceivedHeight + 1) not \(batchEnd + 1)")
                        currentStart = maxReceivedHeight + 1
                    } else {
                        currentStart = batchEnd + 1
                    }
                }
            }

            print("✅ P2P on-demand fetch complete: \(allCMUs.count) CMUs from \(totalBlocks) blocks (received \(totalReceived) heights)")
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
    let witnessIndex: UInt64 // FIX #557 v45: Index in global FFI tree for retrieving fresh witnesses
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
    case witnessCorrupted  // FIX #838: Witness merkle path computes to different root
    case cmuMismatch  // FIX #1137: Stored CMU doesn't match CMU computed from note parts
    case anchorNotOnChain  // FIX #1224: Anchor not found in any blockchain header
    case deltaCMUsFetchFailed(blockRange: UInt64)  // FIX #1225: P2P fetch failed, cannot create witnesses with stale data
    case invalidAmount  // FIX M-014: Amount exceeds MAX_MONEY or would overflow UInt64 when adding fee

    var errorDescription: String? {
        switch self {
        case .invalidAddress:
            return "Invalid z-address"
        case .insufficientFunds:
            return "Insufficient funds"
        case .invalidAmount:
            return "Invalid amount: exceeds maximum supply or would overflow when adding fee"
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
        case .witnessCorrupted:
            return "Witness data corrupted. The merkle path computes to a different anchor. Go to Settings → 'Repair Database' to rebuild witnesses."
        case .cmuMismatch:
            return "Note data integrity error. The stored CMU doesn't match CMU computed from note parts. Go to Settings → 'Repair Database → Full Rescan' to fix."
        case .anchorNotOnChain:
            return "Anchor not found on blockchain. The commitment tree may be corrupted. Go to Settings → 'Repair Database → Full Rescan' to rebuild."
        case .deltaCMUsFetchFailed(let blockRange):
            return "Failed to fetch \(blockRange) blocks of commitment data from P2P network. Cannot create witnesses with stale data. Please wait for peers to connect and try again."
        }
    }
}
