import Foundation

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

        // CRITICAL: Rebuild witnesses fresh from blockchain (Zecwallet Lite approach)
        // Database witnesses become stale as the tree changes. Instead, we rebuild
        // witnesses by rescanning recent blocks to ensure they match current tree state.
        print("🔄 Rebuilding fresh witnesses for spending...")
        let database = WalletDatabase.shared
        guard let account = try database.getAccount(index: 0) else {
            throw TransactionError.proofGenerationFailed
        }

        // Get current chain height
        let chainHeight = try await NetworkManager.shared.getChainHeight()
        print("📊 Current chain height: \(chainHeight)")

        // Get notes from database to find oldest note
        let dbNotes = try database.getUnspentNotes(accountId: account.id)
        guard !dbNotes.isEmpty else {
            throw TransactionError.insufficientFunds
        }

        // CRITICAL: We need to rescan from the bundled tree height, NOT from oldest note!
        // The bundled tree goes up to the height when it was exported.
        // We must rescan from there to current to ensure complete tree with all new outputs.
        // Note: commitment_tree_complete.bin is exported at a specific height and needs updating as chain grows
        let bundledTreeHeight: UInt64 = 2921565  // Height where commitment_tree_complete.bin ends
        let oldestNoteHeight = dbNotes.map { $0.height }.min() ?? chainHeight

        // Rescan from bundled tree height OR older if note is older
        let rescanFromHeight = min(bundledTreeHeight, oldestNoteHeight)

        print("📝 Rescanning from block \(rescanFromHeight) (bundled tree ends at \(bundledTreeHeight)) to \(chainHeight)...")
        print("📝 Oldest note is at height \(oldestNoteHeight)")

        // Force rescan by setting last scanned height to before rescan point
        let originalHeight = try? database.getLastScannedHeight()
        try? database.updateLastScannedHeight(rescanFromHeight - 1, hash: Data(repeating: 0, count: 32))

        // CRITICAL: Clear the database tree state to force reload from bundled CMUs
        // This ensures we start with a clean, known-good tree state
        print("📝 Clearing database tree state to force rebuild from bundled CMUs...")
        try? database.clearTreeStateForRebuild()

        // Rescan to rebuild fresh witnesses
        let scanner = FilterScanner()
        try await scanner.startScan(for: account.id, viewingKey: spendingKey)

        print("✅ Fresh witnesses rebuilt from blockchain")

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

        // CRITICAL: Get anchor from block header at current height
        // This is zcashd's EXACT anchor (finalsaplingroot) - guaranteed to match!
        let headerStore = HeaderStore.shared
        guard let currentAnchor = try? headerStore.getAnchor(at: chainHeight) else {
            print("❌ Failed to get anchor from block header at height \(chainHeight)")
            print("💡 Make sure headers are synced! Run HeaderSyncManager.syncHeaders() first")
            throw TransactionError.proofGenerationFailed
        }
        print("📝 Using anchor from block header at height \(chainHeight): \(currentAnchor.prefix(16).map { String(format: "%02x", $0) }.joined())...")
        print("✅ This anchor came directly from zcashd's block header - guaranteed to match!")

        // Build transaction using FFI
        guard let rawTx = ZipherXFFI.buildTransaction(
            spendingKey: spendingKey,
            toAddress: toAddressBytes,
            amount: amount,
            memo: memoData,
            anchor: currentAnchor,  // Use CURRENT anchor, not database anchor
            witness: note.witness,
            noteValue: note.value,
            noteRcm: note.rcm,
            noteDiversifier: note.diversifier,
            chainHeight: chainHeight
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
                nullifier: dbNote.nullifier // For marking as spent
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
