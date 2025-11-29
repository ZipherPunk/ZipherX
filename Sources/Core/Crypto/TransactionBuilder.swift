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

    // MARK: - Singleton
    static let shared = TransactionBuilder()

    // MARK: - Constants
    private let TX_VERSION: Int32 = 4 // Sapling transaction version
    private let VERSION_GROUP_ID: UInt32 = 0x892F2085 // Sapling
    private let CONSENSUS_BRANCH_ID: UInt32 = 0x76b809bb // Sapling activation
    private let DEFAULT_FEE: UInt64 = 10000 // 0.0001 ZCL

    private var proverInitialized = false

    // MARK: - Prover Initialization

    /// Initialize the prover with Sapling parameters
    func initializeProver() throws {
        guard !proverInitialized else { return }

        let params = SaplingParams.shared
        guard params.areParamsReady else {
            throw TransactionError.proofGenerationFailed
        }

        let spendPath = params.spendParamsPath.path
        let outputPath = params.outputParamsPath.path

        guard ZipherXFFI.initProver(spendParamsPath: spendPath, outputParamsPath: outputPath) else {
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

        // Get current chain height
        let chainHeight = try await NetworkManager.shared.getChainHeight()
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

        // Check if witnesses need updating (tree has grown since witness was created)
        let bundledTreeHeight: UInt64 = 2923123

        // Check if tree is already loaded in memory (from startup preload)
        let currentTreeSize = ZipherXFFI.treeSize()
        if currentTreeSize > 0 {
            print("✅ Commitment tree already in memory: \(currentTreeSize) commitments")
        } else if let treeData = try? database.getTreeState() {
            // Load from database (fast)
            _ = ZipherXFFI.treeDeserialize(data: treeData)
            print("✅ Commitment tree loaded from database")
        } else {
            // Load bundled tree from app resources (slow, first time only)
            print("🌳 Loading bundled commitment tree...")
            if let bundledTreeURL = Bundle.main.url(forResource: "commitment_tree", withExtension: "bin"),
               let bundledData = try? Data(contentsOf: bundledTreeURL) {
                if ZipherXFFI.treeLoadFromCMUs(data: bundledData) {
                    let treeSize = ZipherXFFI.treeSize()
                    print("✅ Loaded bundled commitment tree with \(treeSize) commitments")

                    // CRITICAL: Save to database so we don't need to reload next time
                    // This saves ~50 seconds on subsequent transactions
                    if let serializedTree = ZipherXFFI.treeSerialize() {
                        try? database.saveTreeState(serializedTree)
                        print("💾 Tree state saved to database for future use")
                    }
                } else {
                    print("❌ Failed to load bundled tree")
                    throw TransactionError.proofGenerationFailed
                }
            } else {
                print("❌ Bundled tree file not found")
                throw TransactionError.proofGenerationFailed
            }
        }

        // Get spendable notes with FRESH witnesses
        let notes = try await getSpendableNotes(for: from, spendingKey: spendingKey)

        // Select notes to spend
        let (selectedNotes, _) = try selectNotes(notes, targetAmount: amount + DEFAULT_FEE)

        guard let note = selectedNotes.first else {
            throw TransactionError.insufficientFunds
        }

        // Prepare memo (512 bytes)
        var memoData = Data(repeating: 0, count: 512)
        if let memoText = memo {
            let memoBytes = memoText.utf8
            memoData.replaceSubrange(0..<min(memoBytes.count, 512), with: memoBytes)
        }

        // AUTO-REFRESH: Ensure witness is up-to-date with current tree state
        // If stored witness is stale, we automatically refresh it

        let noteHeight = note.height
        print("📝 Note received at height: \(noteHeight)")

        var witnessToUse = note.witness
        let needsRebuild = note.witness.count < 1028 || note.witness.allSatisfy { $0 == 0 }
        let noteCMU = note.cmu

        // Get current tree state
        guard let currentAnchor = ZipherXFFI.treeRoot() else {
            print("❌ Tree not loaded - cannot get anchor")
            throw TransactionError.proofGenerationFailed
        }
        var anchor = currentAnchor
        let anchorHex = anchor.prefix(16).map { String(format: "%02x", $0) }.joined()
        print("📝 Current tree: \(currentTreeSize) CMUs, root: \(anchorHex)...")

        if needsRebuild {
            print("⚠️ Witness invalid (\(note.witness.count) bytes), needs rebuild")

            guard let cmu = noteCMU else {
                print("❌ Note CMU not stored - cannot rebuild witness")
                print("💡 Tip: Do a full rescan to populate CMU field")
                throw TransactionError.proofGenerationFailed
            }

            if noteHeight <= bundledTreeHeight {
                // Note is within bundled tree range - use treeCreateWitnessForCMU
                print("📝 Note is within bundled tree range, creating witness...")

                guard let bundledTreeURL = Bundle.main.url(forResource: "commitment_tree", withExtension: "bin"),
                      let bundledData = try? Data(contentsOf: bundledTreeURL) else {
                    print("❌ Failed to load bundled commitment tree")
                    throw TransactionError.proofGenerationFailed
                }

                if let result = ZipherXFFI.treeCreateWitnessForCMU(cmuData: bundledData, targetCMU: cmu) {
                    print("✅ Created witness at position \(result.position)")
                    witnessToUse = result.witness
                } else {
                    print("❌ Failed to find note CMU in bundled tree")
                    throw TransactionError.proofGenerationFailed
                }
            } else {
                // Note is beyond bundled tree - rebuild from chain
                print("📝 Note is beyond bundled tree height (\(bundledTreeHeight)), rebuilding witness...")

                if let result = try await rebuildWitnessForNote(
                    cmu: cmu,
                    noteHeight: noteHeight,
                    bundledTreeHeight: bundledTreeHeight
                ) {
                    print("✅ Successfully rebuilt witness for note at height \(noteHeight)")
                    witnessToUse = result.witness
                    anchor = result.anchor
                    let anchorHex = anchor.prefix(16).map { String(format: "%02x", $0) }.joined()
                    print("📝 Using computed anchor: \(anchorHex)...")
                } else {
                    print("❌ Failed to rebuild witness")
                    throw TransactionError.proofGenerationFailed
                }
            }
        } else {
            // Witness exists - but might be stale! Auto-refresh if needed.
            // For notes beyond bundled tree, we need to ensure witness matches current tree.
            print("📝 Stored witness has \(note.witness.count) bytes")

            if noteHeight > bundledTreeHeight {
                // Note is beyond bundled tree - witness might be stale
                // Refresh it by loading into FFI and updating to current tree
                print("🔄 Auto-refreshing witness to match current tree state...")

                if let cmu = noteCMU,
                   let result = try await rebuildWitnessForNote(
                       cmu: cmu,
                       noteHeight: noteHeight,
                       bundledTreeHeight: bundledTreeHeight
                   ) {
                    print("✅ Witness refreshed to current tree state")
                    witnessToUse = result.witness
                    anchor = result.anchor

                    // Save updated witness to database for future use
                    try? database.updateNoteWitness(noteId: note.id, witness: witnessToUse)
                    print("💾 Saved refreshed witness to database")
                } else {
                    print("⚠️ CMU missing or refresh failed - using stored witness (may fail)")
                    witnessToUse = note.witness
                }
            } else {
                // Note within bundled range - witness should be stable
                print("✅ Using stored witness (within bundled range)")
            }
        }

        // Build transaction using FFI
        guard let rawTx = ZipherXFFI.buildTransaction(
            spendingKey: spendingKey,
            toAddress: toAddressBytes,
            amount: amount,
            memo: memoData,
            anchor: anchor,           // Use current tree root (witness is kept up-to-date)
            witness: witnessToUse,    // Stored witness matches current anchor
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

        guard let toAddressBytes = ZipherXFFI.decodeAddress(to) else {
            throw TransactionError.invalidAddress
        }

        onProgress("notes", nil, nil)

        // Get notes from database
        let database = WalletDatabase.shared
        guard let account = try database.getAccount(index: 0) else {
            throw TransactionError.proofGenerationFailed
        }

        let chainHeight = try await NetworkManager.shared.getChainHeight()
        var dbNotes = try database.getUnspentNotes(accountId: account.id)

        if dbNotes.isEmpty {
            let allNotes = try database.getAllUnspentNotes(accountId: account.id)
            if allNotes.isEmpty {
                throw TransactionError.insufficientFunds
            }
            throw TransactionError.proofGenerationFailed
        }

        let bundledTreeHeight: UInt64 = 2923123

        // Check if tree is already loaded in memory (from startup preload)
        let currentTreeSize = ZipherXFFI.treeSize()
        if currentTreeSize > 0 {
            onProgress("tree", "Tree ready (\(currentTreeSize.formatted()) CMUs)", 1.0)
        } else if let treeData = try? database.getTreeState() {
            onProgress("tree", "Loading from cache...", 0.5)
            _ = ZipherXFFI.treeDeserialize(data: treeData)
            onProgress("tree", "Tree loaded from cache", 1.0)
        } else {
            onProgress("tree", "Loading bundled tree...", 0.0)

            if let bundledTreeURL = Bundle.main.url(forResource: "commitment_tree", withExtension: "bin"),
               let bundledData = try? Data(contentsOf: bundledTreeURL) {

                // Count CMUs for progress display
                let cmuCount = bundledData.count >= 8 ?
                    bundledData.prefix(8).withUnsafeBytes { $0.load(as: UInt64.self) } : 0
                let totalCMUs = Int(cmuCount)

                // Use the new FFI function with real progress callback
                let success = ZipherXFFI.treeLoadFromCMUsWithProgress(data: bundledData) { current, total in
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

                onProgress("tree", "\(totalCMUs.formatted()) CMUs loaded", 1.0)
            } else {
                throw TransactionError.proofGenerationFailed
            }
        }

        // Get spendable notes
        let notes = try await getSpendableNotes(for: from, spendingKey: spendingKey)
        let (selectedNotes, _) = try selectNotes(notes, targetAmount: amount + DEFAULT_FEE)

        guard let note = selectedNotes.first else {
            throw TransactionError.insufficientFunds
        }

        // Prepare memo
        var memoData = Data(repeating: 0, count: 512)
        if let memoText = memo {
            let memoBytes = memoText.utf8
            memoData.replaceSubrange(0..<min(memoBytes.count, 512), with: memoBytes)
        }

        onProgress("witness", nil, nil)

        // Get note info
        let noteHeight = note.height
        print("📝 Note received at height: \(noteHeight)")

        var witnessToUse = note.witness
        let noteCMU = note.cmu

        // Use CURRENT tree root as anchor
        guard let currentAnchor = ZipherXFFI.treeRoot() else {
            print("❌ Tree not loaded - cannot get anchor")
            throw TransactionError.proofGenerationFailed
        }
        var anchor = currentAnchor
        let anchorHex = anchor.prefix(16).map { String(format: "%02x", $0) }.joined()
        print("📝 Current tree root (anchor): \(anchorHex)...")

        // Check if witness needs rebuild:
        // 1. Invalid witness (wrong size or all zeros)
        // 2. Stored anchor is missing or doesn't match current anchor (witness is stale)
        let witnessInvalid = note.witness.count < 1028 || note.witness.allSatisfy { $0 == 0 }
        let anchorMatches = !note.anchor.isEmpty && note.anchor == currentAnchor
        let needsRebuild = witnessInvalid || !anchorMatches

        if !anchorMatches && !note.anchor.isEmpty {
            let storedAnchorHex = note.anchor.prefix(16).map { String(format: "%02x", $0) }.joined()
            print("⚠️ Stored anchor (\(storedAnchorHex)...) doesn't match current (\(anchorHex)...) - rebuilding witness")
        } else if note.anchor.isEmpty && !witnessInvalid {
            print("⚠️ No stored anchor - rebuilding witness to verify")
        }

        if needsRebuild {
            if witnessInvalid {
                print("⚠️ Witness invalid (\(note.witness.count) bytes), needs rebuild")
            }
            onProgress("witness", "Updating witness...", 0.0)

            guard let cmu = noteCMU else {
                print("❌ Note CMU not stored - cannot rebuild witness")
                throw TransactionError.proofGenerationFailed
            }

            if noteHeight <= bundledTreeHeight {
                // Note within bundled range - use bundled tree for witness
                print("📝 Note is within bundled tree range, creating witness...")

                guard let bundledTreeURL = Bundle.main.url(forResource: "commitment_tree", withExtension: "bin"),
                      let bundledData = try? Data(contentsOf: bundledTreeURL) else {
                    throw TransactionError.proofGenerationFailed
                }

                if let result = ZipherXFFI.treeCreateWitnessForCMU(cmuData: bundledData, targetCMU: cmu) {
                    witnessToUse = result.witness
                    print("✅ Created witness at position \(result.position)")
                } else {
                    throw TransactionError.proofGenerationFailed
                }
            } else {
                // Note beyond bundled range - rebuild from chain
                print("📝 Note is beyond bundled tree height (\(bundledTreeHeight)), rebuilding witness...")

                if let result = try await rebuildWitnessForNote(
                    cmu: cmu,
                    noteHeight: noteHeight,
                    bundledTreeHeight: bundledTreeHeight,
                    onProgress: onProgress
                ) {
                    print("✅ Successfully rebuilt witness")
                    witnessToUse = result.witness
                    anchor = result.anchor
                    let anchorHex = anchor.prefix(16).map { String(format: "%02x", $0) }.joined()
                    print("📝 Using computed anchor: \(anchorHex)...")

                    // Save updated witness to database so next send is instant
                    try? WalletDatabase.shared.updateNoteWitness(noteId: note.id, witness: witnessToUse)
                    try? WalletDatabase.shared.updateNoteAnchor(noteId: note.id, anchor: anchor)
                    print("💾 Saved updated witness to database")
                } else {
                    throw TransactionError.proofGenerationFailed
                }
            }
        } else {
            // Witness is valid and anchor matches - use directly
            print("✅ Using stored witness (\(note.witness.count) bytes) - anchor matches")
            onProgress("witness", "Witness ready", 1.0)
        }

        onProgress("proof", nil, nil)

        // Build transaction
        guard let rawTx = ZipherXFFI.buildTransaction(
            spendingKey: spendingKey,
            toAddress: toAddressBytes,
            amount: amount,
            memo: memoData,
            anchor: anchor,           // Use current tree root (witness is kept up-to-date)
            witness: witnessToUse,    // Stored witness matches current anchor
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

            // Use STORED anchor (tree root when witness was last updated)
            // If stored anchor is nil/empty, use current tree root (will trigger rebuild)
            let noteAnchor = dbNote.anchor ?? Data()

            let note = SpendableNote(
                id: dbNote.id, // Database row ID for witness updates
                value: dbNote.value,
                anchor: noteAnchor, // Stored anchor - for comparison with current tree root
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

    private func isValidZAddress(_ address: String) -> Bool {
        // Zclassic Sapling addresses use Bech32 encoding with "zs1" prefix
        guard address.hasPrefix("zs1"), address.count == 78 else {
            return false
        }

        // Bech32 character set (no "1" in data part)
        let validChars = CharacterSet(charactersIn: "qpzry9x8gf2tvdw0s3jn54khce6mua7l")
        let addressData = String(address.dropFirst(3))
        return addressData.unicodeScalars.allSatisfy { validChars.contains($0) }
    }

    // MARK: - Witness Rebuild

    /// Rebuild witness for a note to match current tree state
    /// This fetches CMUs from chain and builds the tree to the note's position
    /// - Returns: Updated witness and anchor tuple, or nil if failed
    func rebuildWitnessForNote(
        cmu: Data,
        noteHeight: UInt64,
        bundledTreeHeight: UInt64,
        onProgress: ProgressCallback? = nil
    ) async throws -> (witness: Data, anchor: Data)? {
        print("🔄 Rebuilding witness for note at height \(noteHeight)...")
        print("📝 Note CMU: \(cmu.map { String(format: "%02x", $0) }.joined().prefix(16))...")

        // OPTIMIZATION: Check if tree is already loaded (from WalletManager startup)
        var treeSize = ZipherXFFI.treeSize()
        let expectedMinSize = UInt64(1_041_000) // Bundled tree has ~1.04M CMUs

        if treeSize >= expectedMinSize {
            // Tree already loaded! Skip expensive reload
            print("✅ Tree already loaded with \(treeSize) commitments - skipping reload!")
            onProgress?("witness", "Using cached tree...", 0.05)
        } else {
            // Tree not loaded - need to load bundled CMUs
            print("⚠️ Tree has only \(treeSize) CMUs, loading bundled tree...")
            onProgress?("witness", "Loading bundled tree...", 0.0)

            guard let bundledTreeURL = Bundle.main.url(forResource: "commitment_tree", withExtension: "bin"),
                  let bundledData = try? Data(contentsOf: bundledTreeURL) else {
                print("❌ Failed to load bundled commitment tree")
                return nil
            }

            // Parse bundled CMU count
            guard bundledData.count >= 8 else { return nil }
            let bundledCount = bundledData.prefix(8).withUnsafeBytes { $0.load(as: UInt64.self) }
            print("📊 Bundled tree has \(bundledCount) CMUs ending at height \(bundledTreeHeight)")

            // Initialize and load
            guard ZipherXFFI.treeInit() else {
                print("❌ Failed to initialize tree")
                return nil
            }

            if !ZipherXFFI.treeLoadFromCMUs(data: bundledData) {
                print("❌ Failed to load bundled CMUs")
                return nil
            }

            treeSize = ZipherXFFI.treeSize()
            print("✅ Tree now has \(treeSize) commitments")
        }

        // OPTIMIZATION: Check what height we've already scanned to avoid re-fetching
        // The tree already contains CMUs from bundled file AND from previous syncs
        let lastScannedHeight = (try? WalletDatabase.shared.getLastScannedHeight()) ?? bundledTreeHeight

        // Calculate actual start height - skip blocks already in tree
        let actualStartHeight: UInt64
        if noteHeight <= lastScannedHeight {
            // Note is WITHIN already-scanned range - tree already has all needed CMUs!
            // We just need to find the note's position and create witness
            print("✅ Note at height \(noteHeight) is within scanned range (up to \(lastScannedHeight))")
            print("✅ Tree already has all CMUs needed - no network fetch required!")
            actualStartHeight = noteHeight + 1 // Skip all fetching
        } else {
            // Only fetch blocks AFTER last scanned height
            actualStartHeight = max(bundledTreeHeight + 1, lastScannedHeight + 1)
            print("📊 Last scanned height: \(lastScannedHeight), will fetch from \(actualStartHeight)")
        }

        let startHeight = actualStartHeight
        let totalBlocks = noteHeight >= startHeight ? Int(noteHeight - startHeight + 1) : 0

        if totalBlocks > 0 {
            print("📡 Fetching CMUs from blocks \(startHeight) to \(noteHeight) (\(totalBlocks) blocks via P2P)...")
            onProgress?("witness", "Fetching \(totalBlocks) blocks...", 0.05)
        } else {
            print("✅ No additional blocks to fetch - using existing tree state")
            onProgress?("witness", "Using cached data...", 0.5)
        }

        var notePosition: UInt64? = nil
        var cmusProcessed = 0
        let networkManager = NetworkManager.shared

        // FAST PATH: If note is within already-scanned range, use bundled tree approach
        // This avoids any network fetching!
        if totalBlocks == 0 && noteHeight <= bundledTreeHeight {
            print("🚀 FAST PATH: Note within bundled range, using treeCreateWitnessForCMU...")
            onProgress?("witness", "Creating witness (fast)...", 0.7)

            guard let bundledTreeURL = Bundle.main.url(forResource: "commitment_tree", withExtension: "bin"),
                  let bundledData = try? Data(contentsOf: bundledTreeURL) else {
                print("❌ Failed to load bundled tree for witness creation")
                return nil
            }

            if let result = ZipherXFFI.treeCreateWitnessForCMU(cmuData: bundledData, targetCMU: cmu) {
                print("✅ Created witness at position \(result.position) via fast path")
                let currentRoot = ZipherXFFI.treeRoot() ?? Data()
                return (witness: result.witness, anchor: currentRoot)
            } else {
                print("❌ Failed to find note CMU in bundled tree")
                return nil
            }
        }

        // EDGE CASE: Note beyond bundled range but within scanned range
        // If we're here with totalBlocks == 0, the witness is corrupted and needs full rebuild.
        // We must REINITIALIZE the tree to avoid duplicate CMU corruption.
        if totalBlocks == 0 && noteHeight > bundledTreeHeight && noteHeight <= lastScannedHeight {
            print("⚠️ Note beyond bundled but within scanned range - witness needs full rebuild")
            print("📊 Reinitializing tree and scanning blocks \(bundledTreeHeight + 1) to \(noteHeight)")
            onProgress?("witness", "Rebuilding witness (corrupted)...", 0.1)

            // MUST reinitialize tree to avoid duplicate CMUs
            guard ZipherXFFI.treeInit() else {
                print("❌ Failed to reinitialize tree")
                return nil
            }

            // Reload bundled CMUs first
            guard let bundledTreeURL = Bundle.main.url(forResource: "commitment_tree", withExtension: "bin"),
                  let bundledData = try? Data(contentsOf: bundledTreeURL) else {
                print("❌ Failed to load bundled tree")
                return nil
            }

            if !ZipherXFFI.treeLoadFromCMUs(data: bundledData) {
                print("❌ Failed to reload bundled CMUs")
                return nil
            }
            print("✅ Tree reinitialized with bundled CMUs")
        }

        // Batch size for P2P requests (larger = faster but may timeout)
        let batchSize = 50
        // If we reinitialized the tree, we need to fetch from bundled+1
        // Otherwise use the calculated startHeight
        let loopStartHeight = (totalBlocks == 0 && noteHeight > bundledTreeHeight) ? (bundledTreeHeight + 1) : startHeight
        var currentHeight = loopStartHeight
        let effectiveEndHeight = noteHeight
        let effectiveTotalBlocks = noteHeight >= loopStartHeight ? Int(noteHeight - loopStartHeight + 1) : 0

        // Skip the loop entirely if no blocks to fetch
        guard effectiveTotalBlocks > 0 else {
            print("✅ No blocks to fetch - all CMUs already in tree")
            let currentRoot = ZipherXFFI.treeRoot() ?? Data()
            // We still need to find the note's position - but if we reach here,
            // we should have returned earlier via the fast path
            return nil
        }

        while currentHeight <= effectiveEndHeight {
            let remainingBlocks = Int(noteHeight - currentHeight + 1)
            let thisBatchSize = min(batchSize, remainingBlocks)

            // Report progress
            let blocksProcessed = Int(currentHeight) - Int(loopStartHeight)
            let progressPct = effectiveTotalBlocks > 0 ? Double(blocksProcessed) / Double(effectiveTotalBlocks) : 0.0
            let progressStr = String(format: "%.0f%%", progressPct * 100)
            print("📡 Fetching blocks \(currentHeight)-\(currentHeight + UInt64(thisBatchSize) - 1) (\(progressStr))")
            onProgress?("witness", "Fetching blocks... \(progressStr)", 0.05 + progressPct * 0.85)

            // Try P2P first, fall back to InsightAPI
            var blockCMUs: [(height: UInt64, cmus: [Data])] = []

            if networkManager.isConnected, let peer = networkManager.peers.first {
                do {
                    // Use P2P batch fetch
                    let blocks = try await peer.getFullBlocks(from: currentHeight, count: thisBatchSize)
                    for block in blocks {
                        var cmus: [Data] = []
                        for tx in block.transactions {
                            for output in tx.outputs {
                                // CMUs from P2P are in wire format (little-endian) - use directly
                                cmus.append(output.cmu)
                            }
                        }
                        blockCMUs.append((height: block.blockHeight, cmus: cmus))
                    }
                } catch {
                    print("⚠️ P2P batch fetch failed: \(error), falling back to InsightAPI")
                    // Fall through to InsightAPI fallback
                }
            }

            // Fallback to InsightAPI if P2P failed or not connected
            if blockCMUs.isEmpty {
                for height in currentHeight..<(currentHeight + UInt64(thisBatchSize)) {
                    if height > noteHeight { break }
                    do {
                        let cmus = try await fetchCMUsViaInsight(height: height)
                        blockCMUs.append((height: height, cmus: cmus))
                    } catch {
                        print("⚠️ InsightAPI fetch failed at height \(height): \(error)")
                    }
                }
            }

            // Process fetched CMUs
            for (height, cmus) in blockCMUs {
                for blockCMU in cmus {
                    cmusProcessed += 1

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

                        notePosition = position
                        print("✅ Found note CMU at position \(position) in block \(height)")
                    } else if notePosition != nil {
                        // After finding note, continue appending to update witness
                        _ = ZipherXFFI.treeAppend(cmu: blockCMU)
                    } else {
                        // Before finding note, just append
                        let pos = ZipherXFFI.treeAppend(cmu: blockCMU)
                        if pos == UInt64.max {
                            print("⚠️ Failed to append CMU at height \(height)")
                        }
                    }
                }
            }

            currentHeight += UInt64(thisBatchSize)
        }

        guard notePosition != nil else {
            print("❌ Note CMU not found in blocks \(startHeight)-\(noteHeight)")
            return nil
        }

        print("📊 Added \(cmusProcessed) CMUs from chain")
        print("📊 Final tree size: \(ZipherXFFI.treeSize())")
        onProgress?("witness", "Building witness...", 0.95)

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

        onProgress?("witness", nil, 1.0)
        return (witness: witness, anchor: anchor)
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
}

// MARK: - Supporting Types

struct SpendableNote {
    let id: Int64 // database row ID
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
        }
    }
}
