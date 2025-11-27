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

        // Load the commitment tree to update witnesses if needed
        if let treeData = try? database.getTreeState() {
            _ = ZipherXFFI.treeDeserialize(data: treeData)
            print("✅ Commitment tree loaded from database")
        } else {
            // Load bundled tree from app resources
            print("🌳 Loading bundled commitment tree...")
            if let bundledTreeURL = Bundle.main.url(forResource: "commitment_tree", withExtension: "bin"),
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

        // CRITICAL: Rebuild witness to match anchor
        // The stored witness may not match the anchor from the note's block height,
        // either because it was updated after discovery or because it's empty.
        // We need to rebuild it using the correct tree state.
        var witnessToUse = note.witness
        let needsRebuild = note.witness.count < 1028 || note.witness.allSatisfy { $0 == 0 }

        if needsRebuild {
            print("⚠️ Witness invalid (\(note.witness.count) bytes), needs rebuild")
        }

        let noteCMU = note.cmu

        if noteCMU == nil && needsRebuild {
            print("❌ Note CMU not stored - cannot rebuild witness")
            print("💡 Tip: Do a full rescan to populate CMU field")
            throw TransactionError.proofGenerationFailed
        }

        // For notes beyond bundled tree height, we MUST rebuild witness
        // using bundled CMUs + additional CMUs up to note height
        if noteHeight > bundledTreeHeight {
            print("📝 Note is beyond bundled tree height (\(bundledTreeHeight)), rebuilding witness...")

            guard let cmu = noteCMU else {
                print("❌ Cannot rebuild witness without CMU")
                throw TransactionError.proofGenerationFailed
            }

            // Rebuild witness using bundled tree + fetched CMUs
            if let result = try await rebuildWitnessForNote(
                cmu: cmu,
                noteHeight: noteHeight,
                bundledTreeHeight: bundledTreeHeight
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
        } else if needsRebuild, let cmu = noteCMU {
            // Note is within bundled tree range - use treeCreateWitnessForCMU
            print("📝 Note is within bundled tree range, creating witness from bundled CMUs...")

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
        }

        // Build transaction using FFI
        guard let rawTx = ZipherXFFI.buildTransaction(
            spendingKey: spendingKey,
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

        onProgress("tree", "Loading bundled tree...", 0.0)

        let bundledTreeHeight: UInt64 = 2923123

        // Load commitment tree with progress
        if let treeData = try? database.getTreeState() {
            _ = ZipherXFFI.treeDeserialize(data: treeData)
            onProgress("tree", "Tree loaded from cache", 1.0)
        } else {
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

        // Get anchor and rebuild witness
        let headerStore = HeaderStore.shared
        try? headerStore.open()

        let noteHeight = note.height
        var anchorFromHeader: Data

        if let noteHeader = try? headerStore.getHeader(at: noteHeight) {
            anchorFromHeader = noteHeader.hashFinalSaplingRoot
        } else {
            anchorFromHeader = Data(count: 32)
        }

        var witnessToUse = note.witness
        let needsRebuild = note.witness.count < 1028 || note.witness.allSatisfy { $0 == 0 }

        let noteCMU = note.cmu

        if noteHeight > bundledTreeHeight {
            guard let cmu = noteCMU else {
                throw TransactionError.proofGenerationFailed
            }

            if let result = try await rebuildWitnessForNote(
                cmu: cmu,
                noteHeight: noteHeight,
                bundledTreeHeight: bundledTreeHeight
            ) {
                witnessToUse = result.witness
                if anchorFromHeader.allSatisfy({ $0 == 0 }) {
                    anchorFromHeader = result.anchor
                }
            } else {
                throw TransactionError.proofGenerationFailed
            }
        } else if needsRebuild, let cmu = noteCMU {
            guard let bundledTreeURL = Bundle.main.url(forResource: "commitment_tree", withExtension: "bin"),
                  let bundledData = try? Data(contentsOf: bundledTreeURL) else {
                throw TransactionError.proofGenerationFailed
            }

            if let result = ZipherXFFI.treeCreateWitnessForCMU(cmuData: bundledData, targetCMU: cmu) {
                witnessToUse = result.witness
            } else {
                throw TransactionError.proofGenerationFailed
            }
        }

        onProgress("proof", nil, nil)

        // Build transaction
        guard let rawTx = ZipherXFFI.buildTransaction(
            spendingKey: spendingKey,
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

    /// Rebuild witness for a note that's beyond the bundled tree height
    /// This fetches CMUs from the chain and builds the tree up to the note's position
    /// Returns tuple of (witness, anchor) where anchor is the tree root at noteHeight
    private func rebuildWitnessForNote(
        cmu: Data,
        noteHeight: UInt64,
        bundledTreeHeight: UInt64
    ) async throws -> (witness: Data, anchor: Data)? {
        print("🔄 Rebuilding witness for note at height \(noteHeight)...")
        print("📝 Note CMU: \(cmu.map { String(format: "%02x", $0) }.joined().prefix(16))...")

        // 1. Load bundled CMU file
        guard let bundledTreeURL = Bundle.main.url(forResource: "commitment_tree", withExtension: "bin"),
              let bundledData = try? Data(contentsOf: bundledTreeURL) else {
            print("❌ Failed to load bundled commitment tree")
            return nil
        }

        // Parse bundled CMU count
        guard bundledData.count >= 8 else { return nil }
        let bundledCount = bundledData.prefix(8).withUnsafeBytes { $0.load(as: UInt64.self) }
        print("📊 Bundled tree has \(bundledCount) CMUs ending at height \(bundledTreeHeight)")

        // 2. Initialize fresh tree
        guard ZipherXFFI.treeInit() else {
            print("❌ Failed to initialize tree")
            return nil
        }

        // 3. Load bundled CMUs into tree
        print("🌳 Loading bundled CMUs into tree...")
        if !ZipherXFFI.treeLoadFromCMUs(data: bundledData) {
            print("❌ Failed to load bundled CMUs")
            return nil
        }

        let treeSize = ZipherXFFI.treeSize()
        print("✅ Tree now has \(treeSize) commitments")

        // 4. Fetch additional CMUs from blocks between bundledTreeHeight+1 and noteHeight
        let startHeight = bundledTreeHeight + 1
        print("📡 Fetching CMUs from blocks \(startHeight) to \(noteHeight)...")

        var additionalCMUs: [Data] = []
        var notePosition: UInt64? = nil

        for height in startHeight...noteHeight {
            // Fetch block data via NetworkManager
            do {
                let blockCMUs = try await fetchCMUsViaInsight(height: height)
                for blockCMU in blockCMUs {
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
                        print("✅ Found note CMU at position \(position) in block \(height)")

                        // Get witness data after finishing this block's CMUs
                        // (we need to continue to end of block)
                        additionalCMUs.append(blockCMU)
                    } else if notePosition != nil {
                        // After finding note, continue appending to update witness
                        _ = ZipherXFFI.treeAppend(cmu: blockCMU)
                        additionalCMUs.append(blockCMU)
                    } else {
                        // Before finding note, just append
                        let pos = ZipherXFFI.treeAppend(cmu: blockCMU)
                        if pos == UInt64.max {
                            print("⚠️ Failed to append CMU at height \(height)")
                        }
                        additionalCMUs.append(blockCMU)
                    }
                }
            } catch {
                print("⚠️ Failed to fetch CMUs from block \(height): \(error)")
                // Continue anyway - maybe note is in earlier block
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
