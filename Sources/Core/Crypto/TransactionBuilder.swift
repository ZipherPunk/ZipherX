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
        let bundledTreeHeight: UInt64 = 2922769

        // Load the commitment tree to update witnesses if needed
        if let treeData = try? database.getTreeState() {
            _ = ZipherXFFI.treeDeserialize(data: treeData)
            print("✅ Commitment tree loaded from database")
        } else {
            // Load bundled tree from app resources
            print("🌳 Loading bundled commitment tree...")
            if let bundledTreeURL = Bundle.main.url(forResource: "commitment_tree_v2", withExtension: "bin"),
               let bundledData = try? Data(contentsOf: bundledTreeURL) {
                if ZipherXFFI.treeLoadFromCMUs(data: bundledData) {
                    let treeSize = ZipherXFFI.treeSize()
                    print("✅ Loaded bundled commitment tree with \(treeSize) commitments")
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

        // CRITICAL: Get anchor from block header
        // The anchor MUST match the tree state at the height where our witness is valid
        let headerStore = HeaderStore.shared

        // Ensure HeaderStore is open
        try? headerStore.open()

        // ALWAYS sync headers to current chain height before building transaction
        // This ensures we have the correct anchor for our witness
        let headerSync = HeaderSyncManager(
            headerStore: headerStore,
            networkManager: NetworkManager.shared
        )

        var latestSyncedHeight = (try? headerStore.getLatestHeight()) ?? 0
        print("📊 Current headers at height: \(latestSyncedHeight), Chain tip: \(chainHeight)")

        // ALWAYS sync headers to current chain height before building transaction
        if latestSyncedHeight < chainHeight {
            print("🔄 Headers behind chain tip (\(latestSyncedHeight) < \(chainHeight)), syncing...")

            // Sync from where we left off (or recent blocks if starting fresh)
            let startHeight = latestSyncedHeight > 0 ? latestSyncedHeight + 1 : (chainHeight > 5000 ? chainHeight - 5000 : 0)

            do {
                try await headerSync.syncHeaders(from: startHeight)
                latestSyncedHeight = (try? headerStore.getLatestHeight()) ?? 0
                print("✅ Headers synced to height \(latestSyncedHeight)")
            } catch {
                print("⚠️ Header sync failed: \(error)")
                print("⚠️ Will use existing headers at height \(latestSyncedHeight)")
            }
        }

        guard latestSyncedHeight > 0 else {
            print("❌ No headers available!")
            throw TransactionError.proofGenerationFailed
        }

        print("📊 Chain tip: \(chainHeight), Latest synced header: \(latestSyncedHeight)")

        // Use the latest synced height (may be slightly behind chain tip)
        let anchorHeight = latestSyncedHeight

        guard let headerAnchor = try? headerStore.getAnchor(at: anchorHeight) else {
            print("❌ Failed to get anchor from block header at height \(anchorHeight)")
            print("💡 Make sure headers are synced! Run HeaderSyncManager.syncHeaders() first")
            throw TransactionError.proofGenerationFailed
        }

        // Get our local tree root for comparison
        let localTreeRoot = ZipherXFFI.treeRoot()
        let localRootHex = localTreeRoot?.prefix(16).map { String(format: "%02x", $0) }.joined() ?? "nil"
        let headerAnchorHex = headerAnchor.prefix(16).map { String(format: "%02x", $0) }.joined()

        print("📝 Header anchor at height \(anchorHeight): \(headerAnchorHex)...")
        print("📝 Local tree root (from our tree):         \(localRootHex)...")

        // CRITICAL: The witness was built from OUR tree, so we MUST use OUR tree root as anchor
        // Using header anchor with our witness will always fail because they don't match
        guard let localRoot = localTreeRoot else {
            print("❌ Failed to get local tree root")
            throw TransactionError.proofGenerationFailed
        }

        // Check if our tree root matches zcashd's
        if localRoot == headerAnchor {
            print("✅ LOCAL TREE ROOT MATCHES HEADER ANCHOR!")
        } else {
            print("⚠️ Tree root mismatch detected:")
            print("   Our tree:    \(localRootHex)...")
            print("   zcashd at \(anchorHeight): \(headerAnchorHex)...")
            print("💡 Using our local tree root - zcashd must accept it as a valid historical anchor")
        }

        // Use OUR tree root as anchor (witness must match anchor!)
        let currentAnchor = localRoot
        print("📝 Using LOCAL tree root as anchor: \(localRootHex)...")

        // Build transaction using FFI
        guard let rawTx = ZipherXFFI.buildTransaction(
            spendingKey: spendingKey,
            toAddress: toAddressBytes,
            amount: amount,
            memo: memoData,
            anchor: currentAnchor,  // Use anchor from latest synced header
            witness: note.witness,
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
