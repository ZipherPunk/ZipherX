import Foundation
import Combine
import CryptoKit

/// Sync task status
enum SyncTaskStatus: Equatable {
    case pending
    case inProgress
    case completed
    case failed(String)
}

/// Individual sync task
struct SyncTask: Identifiable {
    let id: String
    let title: String
    var status: SyncTaskStatus
    var detail: String?
    var progress: Double? // 0.0 to 1.0 for progress bar
}

/// Main wallet manager for ZipherX
/// Handles wallet creation, key derivation, and balance tracking
final class WalletManager: ObservableObject {
    static let shared = WalletManager()

    // MARK: - Published Properties
    @Published private(set) var isWalletCreated: Bool = false
    @Published private(set) var shieldedBalance: UInt64 = 0 // in zatoshis
    @Published private(set) var pendingBalance: UInt64 = 0
    @Published private(set) var zAddress: String = ""
    @Published private(set) var syncProgress: Double = 0.0
    @Published private(set) var isSyncing: Bool = false
    @Published private(set) var isConnecting: Bool = false
    @Published private(set) var syncStatus: String = ""
    @Published private(set) var lastError: WalletError?
    @Published private(set) var syncTasks: [SyncTask] = []

    // MARK: - Private Properties
    private let secureStorage: SecureKeyStorage
    private let mnemonicGenerator: MnemonicGenerator
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Constants
    private let zclassicCoinType: UInt32 = 147 // ZCL coin type for BIP44

    private init() {
        self.secureStorage = SecureKeyStorage()
        self.mnemonicGenerator = MnemonicGenerator()
        loadWalletState()

        // Preload commitment tree in background if wallet exists
        if isWalletCreated {
            Task {
                await preloadCommitmentTree()
                // Pre-initialize prover for faster first transaction
                await preloadProver()
            }
        }
    }

    /// Pre-initialize the Groth16 prover for faster transactions
    /// This loads the 50MB+ Sapling params files once at startup
    private func preloadProver() async {
        print("⚡ Pre-initializing Groth16 prover...")

        // Check if params are ready
        let params = SaplingParams.shared
        guard params.areParamsReady else {
            print("⏳ Sapling params not ready yet, will initialize at send time")
            return
        }

        let spendPath = params.spendParamsPath.path
        let outputPath = params.outputParamsPath.path

        // Initialize prover in background
        if ZipherXFFI.initProver(spendParamsPath: spendPath, outputParamsPath: outputPath) {
            print("✅ Groth16 prover pre-initialized (faster first transaction!)")
        } else {
            print("⚠️ Failed to pre-initialize prover, will retry at send time")
        }
    }

    // MARK: - Tree Preloading

    /// Preload commitment tree at startup for faster transactions
    /// This loads from database (if saved) or bundled CMUs (first time)
    @Published private(set) var isTreeLoaded: Bool = false
    @Published private(set) var treeLoadProgress: Double = 0.0
    @Published private(set) var treeLoadStatus: String = ""

    // Expected values for bundled tree validation
    private let bundledTreeCMUCount: UInt64 = 1_041_891
    private let bundledTreeHeight: UInt64 = 2_926_122
    // Expected root (display format): 5cc45e5ed5008b68e0098fdc7ea52cc25caa4400b3bc62c6701bbfc581990945

    // Lock to prevent concurrent tree loading
    private var isTreeLoading = false
    private let treeLoadLock = NSLock()

    /// Public method to ensure tree is loaded - called from ContentView
    /// Handles case where wallet was just created/imported and tree wasn't preloaded in init()
    func ensureTreeLoaded() async {
        // If already loaded, nothing to do
        guard !isTreeLoaded else {
            print("🌳 Tree already loaded, skipping")
            return
        }

        // Call the private preload function
        await preloadCommitmentTree()
    }

    private func preloadCommitmentTree() async {
        // Prevent concurrent tree loading
        treeLoadLock.lock()
        if isTreeLoading || isTreeLoaded {
            treeLoadLock.unlock()
            print("🌳 Tree already loading or loaded, skipping duplicate load")
            // Wait for the other load to complete
            while !isTreeLoaded {
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            }
            return
        }
        isTreeLoading = true
        treeLoadLock.unlock()

        defer {
            treeLoadLock.lock()
            isTreeLoading = false
            treeLoadLock.unlock()
        }

        print("🌳 Preloading commitment tree...")

        await MainActor.run {
            self.treeLoadStatus = "Initializing secure vault..."
        }

        // Open database if needed
        do {
            let spendingKey = try secureStorage.retrieveSpendingKey()
            let dbKey = Data(SHA256.hash(data: spendingKey))
            try WalletDatabase.shared.open(encryptionKey: dbKey)
        } catch {
            print("⚠️ Failed to open database for tree preload: \(error)")
            return
        }

        // Try to load from database first (fast path)
        await MainActor.run {
            self.treeLoadStatus = "Restoring Merkle state..."
        }

        if let treeData = try? WalletDatabase.shared.getTreeState() {
            // Show brief loading state even for cached tree
            await MainActor.run {
                self.treeLoadProgress = 0.5
                self.treeLoadStatus = "Restoring Merkle state..."
            }

            if ZipherXFFI.treeDeserialize(data: treeData) {
                let treeSize = ZipherXFFI.treeSize()

                // VALIDATION: Check if tree size is reasonable
                // The tree should have bundledTreeCMUCount plus CMUs from blocks scanned after bundledTreeHeight
                // A typical block has 0-30 shielded outputs, so expect ~30 CMUs per block max
                let lastScanned = (try? WalletDatabase.shared.getLastScannedHeight()) ?? bundledTreeHeight
                let blocksAfterBundled = max(0, Int64(lastScanned) - Int64(bundledTreeHeight))
                let maxExpectedCMUs = bundledTreeCMUCount + UInt64(blocksAfterBundled) * 20 // realistic max ~20 per block

                if treeSize < bundledTreeCMUCount || treeSize > maxExpectedCMUs {
                    print("⚠️ Tree size \(treeSize) seems invalid (expected \(bundledTreeCMUCount)-\(maxExpectedCMUs))")
                    print("🔄 Clearing corrupted tree state, will reload from bundled CMUs...")
                    // Clear the corrupted state from database
                    try? WalletDatabase.shared.clearTreeState()
                    try? WalletDatabase.shared.updateLastScannedHeight(bundledTreeHeight, hash: Data(count: 32))
                    // Fall through to reload from bundled CMUs
                    // (treeLoadFromCMUs will replace the tree in FFI memory)
                } else {
                    print("✅ Commitment tree preloaded from database: \(treeSize) commitments")
                    await MainActor.run {
                        self.isTreeLoaded = true
                        self.treeLoadProgress = 1.0
                        self.treeLoadStatus = "Privacy state restored\n\(treeSize.formatted()) commitments ready"
                    }
                    return
                }
            }
        }

        // Load full commitment tree from CMUs (required for witness generation)
        // This takes ~53 seconds but ensures all spending operations are instant
        print("🌳 Loading bundled commitment tree (first time)...")
        await MainActor.run {
            self.treeLoadStatus = "Building cryptographic foundation..."
            self.treeLoadProgress = 0.0
        }

        if let bundledTreeURL = Bundle.main.url(forResource: "commitment_tree", withExtension: "bin"),
           let bundledData = try? Data(contentsOf: bundledTreeURL) {

            // Cypherpunk messages for tree building
            let treeLoadMessages = [
                "Constructing zero-knowledge tree...",
                "Assembling cryptographic proofs...",
                "Building Merkle commitments...",
                "Weaving the privacy lattice...",
                "Forging shielded infrastructure...",
                "Computing Pedersen hashes...",
                "Anchoring the privacy chain...",
                "Establishing trust anchors..."
            ]

            // Run the heavy FFI call on a background thread so UI updates can process
            let success = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    let result = ZipherXFFI.treeLoadFromCMUsWithProgress(data: bundledData) { current, total in
                        let progress = Double(current) / Double(total)
                        let currentFormatted = NumberFormatter.localizedString(from: NSNumber(value: current), number: .decimal)
                        let totalFormatted = NumberFormatter.localizedString(from: NSNumber(value: total), number: .decimal)

                        // Rotate through cypherpunk messages
                        let messageIndex = Int(current / 100000) % treeLoadMessages.count
                        let statusMessage = treeLoadMessages[messageIndex]

                        // Update UI on main thread
                        DispatchQueue.main.async {
                            self?.treeLoadProgress = progress
                            self?.treeLoadStatus = "\(statusMessage)\n\(currentFormatted) / \(totalFormatted) CMUs"
                        }
                    }
                    continuation.resume(returning: result)
                }
            }

            if success {
                let treeSize = ZipherXFFI.treeSize()
                print("✅ Bundled commitment tree loaded: \(treeSize) commitments")

                // Save to database for next time
                if let serializedTree = ZipherXFFI.treeSerialize() {
                    try? WalletDatabase.shared.saveTreeState(serializedTree)
                    print("💾 Tree state saved to database for future use")
                }

                await MainActor.run {
                    self.isTreeLoaded = true
                    self.treeLoadProgress = 1.0
                    self.treeLoadStatus = "Privacy infrastructure ready\n\(treeSize.formatted()) commitments loaded"
                }
            } else {
                print("❌ Failed to load bundled tree")
                await MainActor.run {
                    self.treeLoadStatus = "Cryptographic tree build failed"
                }
            }
        } else {
            print("❌ Bundled tree file not found")
            await MainActor.run {
                self.treeLoadStatus = "Privacy data not found"
            }
        }
    }

    // MARK: - Background Tree Sync

    /// Track background sync state to prevent concurrent syncs
    private var isBackgroundSyncing = false
    private let backgroundSyncLock = NSLock()

    /// Sync tree to current chain height in background
    /// Called automatically when new blocks arrive
    /// This is lightweight - just appends new CMUs and updates witnesses
    func backgroundSyncToHeight(_ targetHeight: UInt64) async {
        // Prevent concurrent syncs
        backgroundSyncLock.lock()
        if isBackgroundSyncing {
            backgroundSyncLock.unlock()
            return
        }
        isBackgroundSyncing = true
        backgroundSyncLock.unlock()

        defer {
            backgroundSyncLock.lock()
            isBackgroundSyncing = false
            backgroundSyncLock.unlock()
        }

        // Don't sync during initial sync or if tree not loaded
        guard isTreeLoaded && !isSyncing else {
            return
        }

        // Get current synced height
        let currentHeight = (try? WalletDatabase.shared.getLastScannedHeight()) ?? bundledTreeHeight
        guard targetHeight > currentHeight else {
            return // Already synced
        }

        let blocksToSync = targetHeight - currentHeight
        print("🔄 Background sync: \(blocksToSync) new block(s) (\(currentHeight + 1) → \(targetHeight))")

        do {
            // Get spending key for note detection
            let spendingKey = try secureStorage.retrieveSpendingKey()

            // Use FilterScanner for lightweight sync
            let scanner = FilterScanner()

            // Get account ID
            guard let account = try WalletDatabase.shared.getAccount(index: 0) else {
                print("⚠️ Background sync: No account found")
                return
            }

            // Scan just the new blocks
            try await scanner.startScan(
                for: account.id,
                viewingKey: spendingKey,
                fromHeight: currentHeight + 1
            )

            // Update wallet height
            try? WalletDatabase.shared.updateLastScannedHeight(targetHeight, hash: Data(count: 32))

            print("✅ Background sync complete: tree now at height \(targetHeight)")

            // Update balance with proper confirmation calculation
            let notes = try WalletDatabase.shared.getUnspentNotes(accountId: account.id)
            var confirmedBalance: UInt64 = 0
            var pendingBal: UInt64 = 0

            for note in notes {
                // Calculate confirmations: targetHeight - noteHeight + 1
                let confirmations = targetHeight > note.height ? Int(targetHeight - note.height + 1) : 0
                if confirmations >= 1 {
                    confirmedBalance += note.value
                } else {
                    pendingBal += note.value
                }
            }

            await MainActor.run {
                self.shieldedBalance = confirmedBalance
                self.pendingBalance = pendingBal
                print("💰 Background sync balance: \(confirmedBalance) zatoshis (\(pendingBal) pending)")
            }

        } catch {
            print("⚠️ Background sync failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Wallet Creation

    /// Create a new wallet with a fresh mnemonic
    /// - Returns: The 24-word mnemonic for backup
    func createNewWallet() throws -> [String] {
        // Generate 24-word mnemonic (256-bit entropy)
        let mnemonic = try mnemonicGenerator.generateMnemonic(wordCount: 24)

        // Derive seed from mnemonic
        let seed = try mnemonicGenerator.mnemonicToSeed(mnemonic: mnemonic)

        // Derive Sapling spending key using ZIP-32
        let spendingKey = try deriveSpendingKey(from: seed)

        // Store spending key in Secure Enclave
        try secureStorage.storeSpendingKey(spendingKey)

        // Derive z-address from spending key
        let address = try deriveZAddress(from: spendingKey)

        // Print address to console for debugging
        print("🔐 Generated z-address: \(address)")
        print("🔐 Address length: \(address.count) characters")

        // CRITICAL: Reset database state for new wallet
        // This ensures we scan from bundledTreeHeight, not from a previous wallet's lastScannedHeight
        print("🗑️ Resetting database state for new wallet...")
        try? resetDatabaseForNewWallet()

        // Update state
        DispatchQueue.main.async {
            self.zAddress = address
            self.isWalletCreated = true
            self.saveWalletState()
        }

        return mnemonic
    }

    /// Restore wallet from mnemonic
    func restoreWallet(from mnemonic: [String]) throws {
        // Validate mnemonic
        guard mnemonicGenerator.validateMnemonic(mnemonic) else {
            throw WalletError.invalidMnemonic
        }

        // Derive seed
        let seed = try mnemonicGenerator.mnemonicToSeed(mnemonic: mnemonic)

        // Derive spending key
        let spendingKey = try deriveSpendingKey(from: seed)

        // Store in Secure Enclave
        try secureStorage.storeSpendingKey(spendingKey)

        // Derive z-address
        let address = try deriveZAddress(from: spendingKey)

        // CRITICAL: Reset database state for restored wallet
        // This ensures we scan from the beginning to find all historical notes
        print("🗑️ Resetting database state for restored wallet...")
        try? resetDatabaseForNewWallet()

        // Update state
        DispatchQueue.main.async {
            self.zAddress = address
            self.isWalletCreated = true
            self.saveWalletState()
        }
    }

    /// Reset database state for a new or restored wallet
    /// Clears notes, tree state, scan history, and transaction history
    private func resetDatabaseForNewWallet() throws {
        // Open database with a temporary key to clear it
        // Note: Database will be re-opened with correct key during first sync
        print("🗑️ Clearing old wallet data from database...")

        // Clear tree state
        try? WalletDatabase.shared.clearTreeState()

        // Reset last scanned height to 0 (will be set to bundledTreeHeight during scan)
        try? WalletDatabase.shared.updateLastScannedHeight(0, hash: Data(count: 32))

        // Clear notes table
        try? WalletDatabase.shared.clearAllNotes()

        // Clear transaction history
        try? WalletDatabase.shared.clearTransactionHistory()

        // Clear accounts (will be recreated during sync)
        try? WalletDatabase.shared.clearAccounts()

        print("✅ Database reset complete for new wallet")
    }

    // MARK: - Balance

    /// Refresh shielded balance from network
    func refreshBalance() async throws {
        guard isWalletCreated else {
            throw WalletError.walletNotCreated
        }

        // Initialize sync tasks
        await MainActor.run {
            self.isSyncing = true
            self.syncProgress = 0.0
            self.syncStatus = "Initializing privacy shield..."
            self.syncTasks = [
                SyncTask(id: "params", title: "Fetch Sapling params", status: .pending),
                SyncTask(id: "keys", title: "Load wallet keys", status: .pending),
                SyncTask(id: "database", title: "Open database", status: .pending),
                SyncTask(id: "headers", title: "Sync block headers", status: .pending),
                SyncTask(id: "height", title: "Get chain height", status: .pending),
                SyncTask(id: "scan", title: "Scan blocks since checkpoint", status: .pending),
                SyncTask(id: "witnesses", title: "Sync Merkle witnesses", status: .pending),
                SyncTask(id: "balance", title: "Calculate balance", status: .pending)
            ]
        }

        defer {
            DispatchQueue.main.async {
                self.isSyncing = false
            }
        }

        // Task 0: Fetch Sapling parameters (if not already downloaded)
        await updateTask("params", status: .inProgress)
        do {
            let params = SaplingParams.shared
            if params.areParamsReady {
                await updateTask("params", status: .completed, detail: "Cached")
            } else {
                let sizeMB = params.totalDownloadSize / 1_000_000
                await updateTask("params", status: .inProgress, detail: "Downloading \(sizeMB)MB")
                try await params.ensureParams()
                await updateTask("params", status: .completed, detail: "Downloaded")
            }
        } catch {
            await updateTask("params", status: .failed(error.localizedDescription))
            throw error
        }

        // Task 1: Load keys
        await updateTask("keys", status: .inProgress)
        let spendingKey: Data
        do {
            spendingKey = try secureStorage.retrieveSpendingKey()
            let saplingKey = SaplingSpendingKey(data: spendingKey)
            _ = try RustBridge.shared.deriveFullViewingKey(from: saplingKey)
            await updateTask("keys", status: .completed)
        } catch {
            await updateTask("keys", status: .failed(error.localizedDescription))
            throw error
        }

        // Task 2: Open database
        await updateTask("database", status: .inProgress)
        do {
            let dbKey = Data(SHA256.hash(data: spendingKey))
            try WalletDatabase.shared.open(encryptionKey: dbKey)

            // Ensure account exists in database
            if try WalletDatabase.shared.getAccount(index: 0) == nil {
                // Derive viewing key for storage
                let saplingKey = SaplingSpendingKey(data: spendingKey)
                let fvk = try RustBridge.shared.deriveFullViewingKey(from: saplingKey)

                // Insert account with current address
                _ = try WalletDatabase.shared.insertAccount(
                    accountIndex: 0,
                    spendingKey: spendingKey,
                    viewingKey: fvk.data,
                    address: self.zAddress,
                    birthdayHeight: 559500 // Sapling activation for ZCL
                )
                print("👤 Created account in database")
            }

            await updateTask("database", status: .completed)
        } catch {
            await updateTask("database", status: .failed(error.localizedDescription))
            throw error
        }

        // Task 3: Sync block headers
        await updateTask("headers", status: .inProgress)
        do {
            print("📥 Opening header store...")
            try HeaderStore.shared.open()

            print("🔄 Starting header sync...")
            let headerSync = HeaderSyncManager(
                headerStore: HeaderStore.shared,
                networkManager: NetworkManager.shared
            )

            // Track progress
            headerSync.onProgress = { [weak self] progress in
                Task { @MainActor in
                    if let index = self?.syncTasks.firstIndex(where: { $0.id == "headers" }) {
                        self?.syncTasks[index].detail = "\(progress.currentHeight) / \(progress.totalHeight)"
                        // Calculate progress percentage (0.0 to 1.0)
                        let progressPercentage = progress.totalHeight > 0
                            ? Double(progress.currentHeight) / Double(progress.totalHeight)
                            : 0.0
                        self?.syncTasks[index].progress = progressPercentage
                    }
                }
            }

            // Get starting height for sync
            // We want headers from bundledTreeHeight + 1 onwards (tree includes up to bundledTreeHeight)
            // The getheaders protocol returns headers AFTER the locator hash
            // Checkpoint at bundledTreeHeight (2923123) will be used as locator
            let bundledTreeHeight: UInt64 = 2926122
            let startHeight: UInt64
            if let latestHeight = try HeaderStore.shared.getLatestHeight(), latestHeight >= bundledTreeHeight {
                // Resume from where we left off
                startHeight = latestHeight + 1
                print("📊 Resuming header sync from height \(startHeight)")
            } else {
                // Start from bundledTreeHeight + 1 (checkpoint at bundledTreeHeight used as locator)
                startHeight = bundledTreeHeight + 1
                print("📊 Starting header sync from height \(startHeight) (checkpoint at \(bundledTreeHeight))")
            }

            try await headerSync.syncHeaders(from: startHeight)

            let stats = try HeaderStore.shared.getStats()
            print("✅ Header sync complete! Stored \(stats.count) headers (latest: \(stats.latestHeight ?? 0))")

            await updateTask("headers", status: .completed)
        } catch {
            print("⚠️ Header sync failed: \(error.localizedDescription)")
            await updateTask("headers", status: .failed(error.localizedDescription))
            // Continue anyway - transactions will fail if headers aren't synced
            // but user can still see the error and try again
        }

        // Task 4: Get chain height
        await updateTask("height", status: .inProgress)

        // Task 4: Scan blockchain
        await updateTask("scan", status: .inProgress)
        let scanner = FilterScanner()

        // Bundled tree height for PHASE detection
        let bundledTreeHeight: UInt64 = 2926122

        scanner.onProgress = { [weak self] progress, currentHeight, maxHeight in
            Task { @MainActor in
                self?.syncProgress = progress
                if let index = self?.syncTasks.firstIndex(where: { $0.id == "scan" }) {
                    // Show context: scanning from checkpoint to current
                    let blocksToScan = maxHeight > bundledTreeHeight ? maxHeight - bundledTreeHeight : 0
                    let blocksScanned = currentHeight > bundledTreeHeight ? currentHeight - bundledTreeHeight : 0
                    self?.syncTasks[index].detail = "Block \(currentHeight.formatted()) / \(maxHeight.formatted())"
                    self?.syncTasks[index].progress = blocksToScan > 0 ? Double(blocksScanned) / Double(blocksToScan) : progress
                }

                // Update syncStatus with cypherpunk messages based on scan phase
                if currentHeight <= bundledTreeHeight {
                    // PHASE 1: Scanning within bundled tree range
                    let phase1Messages = [
                        "Hunting for your shielded notes...",
                        "Decrypting the shadows...",
                        "Scanning the privacy chain...",
                        "Detecting spent nullifiers...",
                        "Unveiling your hidden funds...",
                        "Cypherpunk reconnaissance...",
                        "Mining your transaction history...",
                        "Privacy audit in progress..."
                    ]
                    let messageIndex = Int(currentHeight / 50000) % phase1Messages.count
                    self?.syncStatus = phase1Messages[messageIndex]
                } else {
                    // PHASE 2: Sequential tree building
                    let phase2Messages = [
                        "Building commitment tree...",
                        "Extending the Merkle frontier...",
                        "Cryptographic tree expansion...",
                        "Securing new commitments...",
                        "Zero-knowledge sync active..."
                    ]
                    let blocksAfterBundled = currentHeight - bundledTreeHeight
                    let messageIndex = Int(blocksAfterBundled / 1000) % phase2Messages.count
                    self?.syncStatus = phase2Messages[messageIndex]
                }
            }
        }

        // Witness sync progress callback - update witnesses task with real progress
        scanner.onWitnessProgress = { [weak self] current, total, status in
            Task { @MainActor in
                if let index = self?.syncTasks.firstIndex(where: { $0.id == "witnesses" }) {
                    if total > 0 {
                        self?.syncTasks[index].status = .inProgress
                        self?.syncTasks[index].detail = status
                        self?.syncTasks[index].progress = Double(current) / Double(total)
                        self?.syncStatus = "Syncing Merkle witnesses..."
                    }
                    if current == total {
                        self?.syncTasks[index].status = .completed
                        self?.syncTasks[index].detail = total > 0 ? "\(total) witness(es) synced" : "No witnesses needed"
                        self?.syncTasks[index].progress = 1.0
                    }
                }
            }
        }

        // Get account ID for scanning (database row id starts at 1)
        let database = WalletDatabase.shared
        guard let account = try database.getAccount(index: 0) else {
            throw WalletError.walletNotCreated
        }

        do {
            // Pass spending key (169 bytes) so scanner can derive IVK properly
            // Witness sync now happens inside startScan with progress reported via onWitnessProgress
            await updateTask("witnesses", status: .inProgress, detail: "Waiting for scan...")
            try await scanner.startScan(for: account.id, viewingKey: spendingKey)
            await updateTask("height", status: .completed)
            await updateTask("scan", status: .completed)
            // Note: witnesses task is completed by the onWitnessProgress callback
        } catch {
            await updateTask("scan", status: .failed(error.localizedDescription))
            throw error
        }

        // Task 6: Calculate balance
        await updateTask("balance", status: .inProgress, detail: "Loading notes...")

        // Debug: List all notes in database to diagnose balance discrepancy
        try? database.debugListAllNotes(accountId: account.id)

        var unspentNotes = try database.getUnspentNotes(accountId: account.id)
        let totalNotes = unspentNotes.count

        // Update with note count
        await updateTaskWithProgress("balance", detail: "Processing \(totalNotes) notes...", progress: 0.1)

        // Get current chain height to calculate confirmations
        let chainHeight = scanner.currentChainHeight

        var totalBalance: UInt64 = 0
        var pendingBalance: UInt64 = 0

        for i in unspentNotes.indices {
            // Calculate confirmations: chainHeight - noteHeight + 1
            let confirmations = chainHeight > unspentNotes[i].height ? Int(chainHeight - unspentNotes[i].height + 1) : 0
            unspentNotes[i].confirmations = confirmations

            // Require only 1 confirmation for balance (10 is too slow for UX)
            if confirmations >= 1 {
                totalBalance += unspentNotes[i].value
            } else {
                pendingBalance += unspentNotes[i].value
            }

            // Update progress every few notes
            if totalNotes > 0 && (i + 1) % max(1, totalNotes / 10) == 0 {
                let progress = Double(i + 1) / Double(totalNotes)
                await updateTaskWithProgress("balance", detail: "Verifying note \(i + 1)/\(totalNotes)...", progress: 0.1 + progress * 0.8)
            }
        }

        // Final verification step
        await updateTaskWithProgress("balance", detail: "Finalizing balance...", progress: 0.95)

        // Brief pause to show the progress (balance calc is very fast)
        try? await Task.sleep(nanoseconds: 200_000_000) // 0.2 sec

        await updateTask("balance", status: .completed, detail: "\(unspentNotes.count) notes verified")
        print("✅ Balance task marked as completed")

        // Update UI
        DispatchQueue.main.async {
            self.shieldedBalance = totalBalance
            self.pendingBalance = pendingBalance
            self.syncProgress = 1.0
            print("💰 Balance updated: \(totalBalance) zatoshis (\(pendingBalance) pending)")
        }
    }

    /// Sync witnesses for notes beyond bundled tree to match current tree state
    /// This ensures witnesses are ready for spending without rebuild at transaction time
    private func syncWitnesses(accountId: Int64, bundledTreeHeight: UInt64) async throws {
        let database = WalletDatabase.shared

        // Get all unspent notes
        let notes = try database.getUnspentNotes(accountId: accountId)

        // Filter notes beyond bundled tree that might need witness update
        let notesNeedingSync = notes.filter { note in
            // Notes beyond bundled tree need witness sync
            note.height > bundledTreeHeight &&
            // Only if they have valid witness that might be stale
            note.witness.count >= 1028 &&
            // Must have CMU for rebuild
            note.cmu != nil && note.cmu!.count == 32
        }

        if notesNeedingSync.isEmpty {
            await MainActor.run {
                self.syncStatus = "All witnesses up to date"
                if let index = self.syncTasks.firstIndex(where: { $0.id == "witnesses" }) {
                    self.syncTasks[index].detail = "All current"
                    self.syncTasks[index].progress = 1.0
                }
            }
            print("✅ No witnesses need syncing")
            return
        }

        print("🔄 Syncing \(notesNeedingSync.count) witness(es) beyond bundled tree...")

        // Cypherpunk messages for witness sync
        let witnessMessages = [
            "Updating Merkle proofs...",
            "Synchronizing witness paths...",
            "Refreshing cryptographic anchors...",
            "Aligning zero-knowledge proofs...",
            "Calibrating witness roots..."
        ]

        for (index, note) in notesNeedingSync.enumerated() {
            let progress = Double(index + 1) / Double(notesNeedingSync.count)
            let messageIndex = index % witnessMessages.count

            await MainActor.run {
                self.syncStatus = witnessMessages[messageIndex]
                if let taskIndex = self.syncTasks.firstIndex(where: { $0.id == "witnesses" }) {
                    self.syncTasks[taskIndex].detail = "Note \(index + 1)/\(notesNeedingSync.count)"
                    self.syncTasks[taskIndex].progress = progress
                }
            }

            // Rebuild witness to current tree state
            guard let cmu = note.cmu else { continue }

            let builder = TransactionBuilder()
            if let result = try await builder.rebuildWitnessForNote(
                cmu: cmu,
                noteHeight: note.height,
                bundledTreeHeight: bundledTreeHeight
            ) {
                // Save updated witness to database
                try? database.updateNoteWitness(noteId: note.id, witness: result.witness)
                print("✅ Synced witness for note \(note.id) at height \(note.height)")
            } else {
                print("⚠️ Could not sync witness for note \(note.id)")
            }
        }

        await MainActor.run {
            self.syncStatus = "Witnesses synchronized"
            if let taskIndex = self.syncTasks.firstIndex(where: { $0.id == "witnesses" }) {
                self.syncTasks[taskIndex].detail = "\(notesNeedingSync.count) synced"
                self.syncTasks[taskIndex].progress = 1.0
            }
        }

        print("✅ Witness sync complete - \(notesNeedingSync.count) updated")
    }

    /// Rescan blockchain from checkpoint to find missing transactions
    func rescanBlockchain() async throws {
        guard isWalletCreated else {
            throw WalletError.walletNotCreated
        }

        // First open the database if needed
        let spendingKey = try secureStorage.retrieveSpendingKey()
        let dbKey = Data(SHA256.hash(data: spendingKey))
        try WalletDatabase.shared.open(encryptionKey: dbKey)

        // Reset scan state to force full rescan from checkpoint
        try WalletDatabase.shared.updateLastScannedHeight(0, hash: Data(count: 32))
        print("🔄 Reset scan state - will rescan from checkpoint")

        // Now do a normal refresh which will scan from checkpoint
        try await refreshBalance()
    }

    /// Perform a full blockchain rescan from a specific height
    /// This rebuilds the commitment tree and finds notes with proper witnesses
    /// - Parameters:
    ///   - fromHeight: Optional start height (defaults to loading bundled tree height)
    ///   - onProgress: Callback with (progress, currentHeight, maxHeight)
    func performFullRescan(fromHeight startHeight: UInt64? = nil, onProgress: @escaping (Double, UInt64, UInt64) -> Void) async throws {
        guard isWalletCreated else {
            throw WalletError.walletNotCreated
        }

        // Get spending key
        let spendingKey = try secureStorage.retrieveSpendingKey()
        // SECURITY: Key retrieved - not logged

        // Ensure database is open
        let dbKey = Data(SHA256.hash(data: spendingKey))
        try WalletDatabase.shared.open(encryptionKey: dbKey)
        print("📂 Database opened")

        // Get account ID
        guard let account = try WalletDatabase.shared.getAccount(index: 0) else {
            print("❌ No account found in database")
            throw WalletError.walletNotCreated
        }
        print("👤 Account ID: \(account.id)")

        // Ensure network connection before scanning
        print("📡 Ensuring network connection...")
        if !NetworkManager.shared.isConnected {
            try await NetworkManager.shared.connect()
            // Wait a moment for connection to stabilize
            try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
        }
        print("✅ Network connected: \(NetworkManager.shared.peers.count) peer(s)")

        // Clear existing notes but keep tree if we're starting from a specific height
        let bundledTreeHeight: UInt64 = 2926122  // Height where bundled tree ends

        // Wait for any existing scan to complete (with timeout)
        if FilterScanner.isScanInProgress {
            print("⏳ Another scan is in progress, waiting for it to complete...")
            var waitCount = 0
            let maxWait = 60 // Maximum 60 seconds wait
            while FilterScanner.isScanInProgress && waitCount < maxWait {
                try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
                waitCount += 1
                if waitCount % 5 == 0 {
                    print("⏳ Still waiting for scan to complete... (\(waitCount)s)")
                }
            }
            if FilterScanner.isScanInProgress {
                print("⚠️ Existing scan still running after \(maxWait)s, forcing new scan anyway")
            } else {
                print("✅ Previous scan completed, proceeding with new scan")
            }
        }

        if let startHeight = startHeight {
            // Check if the requested height is within the bundled tree range
            if startHeight <= bundledTreeHeight {
                // For heights within bundled tree: use quick scan (note detection only, no tree changes)
                // This preserves the correct bundled tree while finding notes
                // NOTE: We do NOT clear existing notes - just scan for additional ones
                print("🔍 Quick scan mode: height \(startHeight) is within bundled tree range (ends at \(bundledTreeHeight))")
                print("🔍 Will scan for notes WITHOUT modifying the commitment tree or existing notes")

                // Create scanner with progress callback
                let scanner = FilterScanner()
                scanner.onProgress = onProgress

                // Pass fromHeight to trigger quick scan mode (parallel, no CMU additions)
                try await scanner.startScan(for: account.id, viewingKey: spendingKey, fromHeight: startHeight)

                // Refresh balance after scan
                try await refreshBalance()
                print("✅ Quick scan complete from height \(startHeight)")
                return
            } else {
                // Height is beyond bundled tree - do sequential scan from bundled tree end
                print("⚠️ Full rescan from height \(startHeight) is beyond bundled tree (\(bundledTreeHeight))")
                print("🔄 Will continue sequential scan from bundled tree end")
                try WalletDatabase.shared.resetSyncState()
            }
        } else {
            // Reset all sync state (notes, nullifiers, tree)
            try WalletDatabase.shared.resetSyncState()
            print("🔄 Reset complete - starting full rescan from Sapling activation")
        }

        // Create scanner with progress callback
        let scanner = FilterScanner()
        scanner.onProgress = onProgress

        // Start scan (sequential mode for tree building)
        try await scanner.startScan(for: account.id, viewingKey: spendingKey)

        // Refresh balance after scan
        try await refreshBalance()
        print("✅ Full rescan complete")
    }

    /// Rebuild witnesses from bundled tree height
    /// This is needed when witnesses are invalid (e.g., after quick scan)
    /// Uses bundled CMUs and scans sequentially to build proper witnesses
    func rebuildWitnessesForSpending(onProgress: @escaping (Double, UInt64, UInt64) -> Void) async throws {
        guard isWalletCreated else {
            throw WalletError.walletNotCreated
        }

        // Get spending key
        let spendingKey = try secureStorage.retrieveSpendingKey()
        // SECURITY: Key retrieved - not logged

        // Ensure database is open
        let dbKey = Data(SHA256.hash(data: spendingKey))
        try WalletDatabase.shared.open(encryptionKey: dbKey)
        print("📂 Database opened")

        // Get account ID
        guard let account = try WalletDatabase.shared.getAccount(index: 0) else {
            print("❌ No account found in database")
            throw WalletError.walletNotCreated
        }
        print("👤 Account ID: \(account.id)")

        // FAST PATH: Try to rebuild witnesses using stored CMUs and bundled tree
        let notes = try WalletDatabase.shared.getAllUnspentNotes(accountId: account.id)
        print("📝 Found \(notes.count) notes to rebuild witnesses for")

        // Load bundled CMU data
        guard let bundledTreeURL = Bundle.main.url(forResource: "commitment_tree", withExtension: "bin"),
              let bundledData = try? Data(contentsOf: bundledTreeURL) else {
            print("❌ Bundled CMU file not found, falling back to full scan")
            try await rebuildWitnessesViaFullScan(account: account, spendingKey: spendingKey, onProgress: onProgress)
            return
        }

        print("📦 Loaded bundled CMU data: \(bundledData.count) bytes")

        // Check if all notes have CMU stored
        var notesWithCMU: [WalletNote] = []
        var notesWithoutCMU: [WalletNote] = []

        for note in notes {
            if let cmu = note.cmu, cmu.count == 32 {
                notesWithCMU.append(note)
            } else {
                notesWithoutCMU.append(note)
            }
        }

        print("📝 Notes with CMU: \(notesWithCMU.count), without CMU: \(notesWithoutCMU.count)")

        if notesWithoutCMU.isEmpty && !notesWithCMU.isEmpty {
            // All notes have CMU - check if any are beyond bundled range
            print("🚀 Checking notes for witness rebuild...")

            let bundledTreeHeight: UInt64 = 2926122 // Height where bundled tree ends

            // Check if ANY note is beyond bundled range
            let notesBeyondBundled = notesWithCMU.filter { $0.height > bundledTreeHeight }
            if !notesBeyondBundled.isEmpty {
                print("⚠️ Found \(notesBeyondBundled.count) notes beyond bundled range - need live scan")
                print("📡 Scanning from bundled height to chain tip...")

                // Load bundled tree first
                if ZipherXFFI.treeLoadFromCMUs(data: bundledData) {
                    let treeSize = ZipherXFFI.treeSize()
                    print("✅ Loaded bundled tree: \(treeSize) commitments")
                }

                // Ensure network connection
                if !NetworkManager.shared.isConnected {
                    try await NetworkManager.shared.connect()
                    try await Task.sleep(nanoseconds: 500_000_000)
                }

                // Scan from bundled tree height to find notes AND detect spent nullifiers
                let scanner = FilterScanner()
                scanner.onProgress = onProgress
                try await scanner.startScan(for: account.id, viewingKey: spendingKey, fromHeight: bundledTreeHeight + 1)

                // Refresh balance after scan (will detect spent notes)
                try await refreshBalance()
                print("✅ Live scan complete - witnesses built and spent notes detected")
                return
            }

            // All notes within bundled range - use fast path
            print("🚀 All notes within bundled range - using fast witness rebuild")

            for (index, note) in notesWithCMU.enumerated() {
                guard let cmu = note.cmu else { continue }

                // Report progress
                let progress = Double(index + 1) / Double(notesWithCMU.count)
                await MainActor.run {
                    onProgress(progress, UInt64(index + 1), UInt64(notesWithCMU.count))
                }

                // Use treeCreateWitnessForCMU for notes within bundled range
                if let result = ZipherXFFI.treeCreateWitnessForCMU(cmuData: bundledData, targetCMU: cmu) {
                    let (position, witness) = result
                    print("✅ Created witness for note \(note.id): position=\(position), witness=\(witness.count) bytes")

                    // Update witness in database
                    try WalletDatabase.shared.updateNoteWitness(noteId: note.id, witness: witness)
                } else {
                    print("⚠️ Failed to create witness for note \(note.id) - CMU not in bundled tree")
                }
            }

            // Load the bundled tree into memory for spending
            if ZipherXFFI.treeLoadFromCMUs(data: bundledData) {
                let treeSize = ZipherXFFI.treeSize()
                print("✅ Loaded bundled tree for spending: \(treeSize) commitments")
            }

            // Refresh balance after rebuild
            try await refreshBalance()
            print("✅ Fast witness rebuild complete - notes can now be spent")
        } else {
            // Some notes don't have CMU - fall back to full scan
            print("⚠️ Some notes missing CMU, falling back to full scan")
            try await rebuildWitnessesViaFullScan(account: account, spendingKey: spendingKey, onProgress: onProgress)
        }
    }

    /// Fall back to full scan for witness rebuild
    private func rebuildWitnessesViaFullScan(account: Account, spendingKey: Data, onProgress: @escaping (Double, UInt64, UInt64) -> Void) async throws {
        // Ensure network connection before scanning
        print("📡 Ensuring network connection...")
        if !NetworkManager.shared.isConnected {
            try await NetworkManager.shared.connect()
            // Wait a moment for connection to stabilize
            try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
        }
        print("✅ Network connected: \(NetworkManager.shared.peers.count) peer(s)")

        // Clear tree state and witnesses to force rebuild
        try WalletDatabase.shared.clearTreeStateForRebuild()
        print("🔄 Cleared tree state and witnesses")

        // Create scanner with progress callback
        let scanner = FilterScanner()
        scanner.onProgress = onProgress

        // CRITICAL: For rebuild, we need to scan from Sapling activation to find ALL notes
        // Don't let it use bundled tree height as start - that would skip notes within bundled range
        let saplingActivation: UInt64 = 476969
        print("🔄 Starting full rescan from Sapling activation (\(saplingActivation)) to rediscover all notes")

        try await scanner.startScan(for: account.id, viewingKey: spendingKey, fromHeight: saplingActivation)

        // Refresh balance after scan
        try await refreshBalance()
        print("✅ Witness rebuild complete - notes can now be spent")
    }

    /// Perform a quick scan for notes starting from a specific height
    /// Uses bundled tree - only scans for notes, doesn't rebuild tree
    func performQuickScan(fromHeight startHeight: UInt64, onProgress: @escaping (Double, UInt64, UInt64) -> Void) async throws {
        guard isWalletCreated else {
            throw WalletError.walletNotCreated
        }

        // Get spending key
        let spendingKey = try secureStorage.retrieveSpendingKey()
        // SECURITY: Key retrieved - not logged

        // Ensure database is open
        let dbKey = Data(SHA256.hash(data: spendingKey))
        try WalletDatabase.shared.open(encryptionKey: dbKey)
        print("📂 Database opened")

        // Get account ID
        guard let account = try WalletDatabase.shared.getAccount(index: 0) else {
            print("❌ No account found in database")
            throw WalletError.walletNotCreated
        }
        print("👤 Account ID: \(account.id)")

        // Ensure network connection before scanning
        print("📡 Ensuring network connection...")
        if !NetworkManager.shared.isConnected {
            try await NetworkManager.shared.connect()
            // Wait a moment for connection to stabilize
            try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
        }
        print("✅ Network connected: \(NetworkManager.shared.peers.count) peer(s)")

        // Tree initialization depends on scan start height
        // For full rescans (from Sapling activation), start with empty tree
        // For recent scans, load pre-built tree
        let saplingActivation: UInt64 = 476969
        let prebuiltTreeHeight: UInt64 = 2920561

        if startHeight <= saplingActivation + 1000 {
            // Full rescan - start with empty tree to build witnesses correctly
            _ = ZipherXFFI.treeInit()
            print("🌳 Initialized empty tree for full rescan from \(startHeight)")
        } else if startHeight >= prebuiltTreeHeight {
            // Recent scan - load pre-built tree
            if let bundledTreeURL = Bundle.main.url(forResource: "commitment_tree", withExtension: "bin"),
               let bundledData = try? Data(contentsOf: bundledTreeURL) {
                if ZipherXFFI.treeLoadFromCMUs(data: bundledData) {
                    let treeSize = ZipherXFFI.treeSize()
                    print("🌳 Loaded bundled commitment tree (CMU format) with \(treeSize) commitments")
                } else {
                    print("❌ Failed to load bundled tree from CMU format")
                    _ = ZipherXFFI.treeInit()
                }
            } else {
                _ = ZipherXFFI.treeInit()
                print("🌳 Initialized empty tree (no bundled tree found)")
            }
        } else {
            // Partial scan from middle - need empty tree to build correctly
            _ = ZipherXFFI.treeInit()
            print("🌳 Initialized empty tree for partial scan from \(startHeight)")
        }

        // Create scanner with progress callback
        let scanner = FilterScanner()
        scanner.onProgress = onProgress

        // Start scan from specified height
        try await scanner.startScan(for: account.id, viewingKey: spendingKey, fromHeight: startHeight)

        // Refresh balance after scan
        try await refreshBalance()
        print("✅ Quick scan complete")
    }

    /// Update a sync task status
    @MainActor
    private func updateTask(_ id: String, status: SyncTaskStatus, detail: String? = nil) {
        if let index = syncTasks.firstIndex(where: { $0.id == id }) {
            syncTasks[index].status = status
            if let detail = detail {
                syncTasks[index].detail = detail
            }

            // Update syncStatus with cypherpunk messages
            if case .inProgress = status {
                switch id {
                case "params":
                    self.syncStatus = "Loading cryptographic parameters..."
                case "keys":
                    self.syncStatus = "Unlocking your keys..."
                case "database":
                    self.syncStatus = "Opening secure vault..."
                case "headers":
                    self.syncStatus = "Syncing block headers..."
                case "height":
                    self.syncStatus = "Checking network state..."
                case "scan":
                    self.syncStatus = "Scanning for shielded notes..."
                case "balance":
                    self.syncStatus = "Calculating your sovereignty..."
                default:
                    self.syncStatus = "Processing..."
                }
            } else if case .completed = status {
                // Update progress based on completed tasks
                let completedCount = syncTasks.filter { if case .completed = $0.status { return true }; return false }.count
                self.syncProgress = Double(completedCount) / Double(syncTasks.count)
            }
        }
    }

    /// Update a sync task with progress (keeps inProgress status)
    @MainActor
    private func updateTaskWithProgress(_ id: String, detail: String, progress: Double) {
        if let index = syncTasks.firstIndex(where: { $0.id == id }) {
            syncTasks[index].detail = detail
            syncTasks[index].progress = progress
        }
    }

    // MARK: - Transactions

    /// Progress callback type for transaction building
    typealias SendProgressCallback = (_ step: String, _ detail: String?, _ progress: Double?) -> Void

    /// Send shielded ZCL with progress reporting
    /// - Parameters:
    ///   - toAddress: Destination z-address (must be shielded)
    ///   - amount: Amount in zatoshis
    ///   - memo: Optional encrypted memo
    ///   - onProgress: Callback for progress updates
    /// - Returns: Transaction ID
    func sendShieldedWithProgress(to toAddress: String, amount: UInt64, memo: String? = nil, onProgress: @escaping SendProgressCallback) async throws -> String {
        // Validate destination is a z-address (shielded only!)
        guard isValidZAddress(toAddress) else {
            throw WalletError.invalidAddress("ZipherX only supports z-addresses. t-addresses are not allowed.")
        }

        // Check balance
        let fee: UInt64 = 10_000
        let totalRequired = amount + fee
        let currentBalance = await MainActor.run { shieldedBalance }

        guard totalRequired <= currentBalance else {
            throw WalletError.insufficientFunds
        }

        // Get spending key from Secure Enclave
        let spendingKey = try secureStorage.retrieveSpendingKey()
        onProgress("prover", nil, nil)

        // Build shielded transaction with progress
        let txBuilder = TransactionBuilder()
        let (rawTx, spentNullifier) = try await txBuilder.buildShieldedTransactionWithProgress(
            from: zAddress,
            to: toAddress,
            amount: amount,
            memo: memo,
            spendingKey: spendingKey,
            onProgress: onProgress
        )

        onProgress("broadcast", "Preparing to broadcast...", 0.0)

        // Broadcast through multi-peer network with progress
        let networkManager = NetworkManager.shared
        let txId = try await networkManager.broadcastTransactionWithProgress(rawTx) { phase, detail, progress in
            // Forward broadcast progress to the UI
            onProgress("broadcast", detail, progress)
        }

        // Mark the spent note immediately
        guard let txidData = Data(hexString: txId) else {
            throw WalletError.transactionFailed("Invalid transaction ID format")
        }
        try WalletDatabase.shared.markNoteSpent(nullifier: spentNullifier, txid: txidData)

        // Record transaction in history
        let chainHeight = try await networkManager.getChainHeight()
        _ = try WalletDatabase.shared.insertTransactionHistory(
            txid: txidData,
            height: chainHeight,
            blockTime: UInt64(Date().timeIntervalSince1970),
            type: .sent,
            value: amount,
            fee: 10_000,
            toAddress: toAddress,
            fromDiversifier: nil,
            memo: memo
        )

        // Send notification for successful transaction
        NotificationManager.shared.notifySent(amount: amount, txid: txId, memo: memo)

        // Refresh balance
        try await refreshBalance()

        return txId
    }

    /// Send shielded ZCL to another z-address
    /// - Parameters:
    ///   - toAddress: Destination z-address (must be shielded)
    ///   - amount: Amount in zatoshis
    ///   - memo: Optional encrypted memo
    /// - Returns: Transaction ID
    func sendShielded(to toAddress: String, amount: UInt64, memo: String? = nil) async throws -> String {
        // Validate destination is a z-address (shielded only!)
        guard isValidZAddress(toAddress) else {
            throw WalletError.invalidAddress("ZipherX only supports z-addresses. t-addresses are not allowed.")
        }

        // Check balance (amount + fee)
        // Standard Zcash fee is 10,000 zatoshis (0.0001 ZCL)
        let fee: UInt64 = 10_000
        let totalRequired = amount + fee

        // Read balance on main thread to avoid stale value
        let currentBalance = await MainActor.run { shieldedBalance }
        print("📤 Send check: amount=\(amount), fee=\(fee), total=\(totalRequired), balance=\(currentBalance)")
        guard totalRequired <= currentBalance else {
            print("❌ Insufficient funds: need \(totalRequired) zatoshis (amount: \(amount) + fee: \(fee)), have \(currentBalance)")
            throw WalletError.insufficientFunds
        }
        print("✅ Balance check passed")

        // Get spending key from Secure Enclave
        let spendingKey = try secureStorage.retrieveSpendingKey()

        // Build shielded transaction
        let txBuilder = TransactionBuilder()
        let (rawTx, spentNullifier) = try await txBuilder.buildShieldedTransaction(
            from: zAddress,
            to: toAddress,
            amount: amount,
            memo: memo,
            spendingKey: spendingKey
        )

        // Broadcast through multi-peer network
        let networkManager = NetworkManager.shared
        let txId = try await networkManager.broadcastTransaction(rawTx)

        // CRITICAL: Mark the spent note immediately to prevent double-spending
        // Don't wait for blockchain confirmation - mark it now
        print("📝 Marking note as spent (nullifier: \(spentNullifier.map { String(format: "%02x", $0) }.joined().prefix(16))...)")
        // Convert txid hex string to Data
        guard let txidData = Data(hexString: txId) else {
            print("⚠️ Failed to convert txid to Data, skipping mark as spent")
            throw WalletError.transactionFailed("Invalid transaction ID format")
        }
        try WalletDatabase.shared.markNoteSpent(nullifier: spentNullifier, txid: txidData)
        print("✅ Note marked as spent in database")

        // Record transaction in history
        let chainHeight = try await networkManager.getChainHeight()
        _ = try WalletDatabase.shared.insertTransactionHistory(
            txid: txidData,
            height: chainHeight,
            blockTime: UInt64(Date().timeIntervalSince1970),
            type: .sent,
            value: amount,
            fee: 10_000,
            toAddress: toAddress,
            fromDiversifier: nil,
            memo: memo
        )
        print("📜 Transaction recorded in history")

        // Send notification for successful transaction
        NotificationManager.shared.notifySent(amount: amount, txid: txId, memo: memo)

        // Refresh balance
        try await refreshBalance()

        return txId
    }

    /// Recover funds from failed transactions
    /// Marks all notes that were marked spent but don't have confirmed txids as unspent
    func recoverFailedTransactions() async throws {
        print("Checking for unconfirmed spent notes...")

        let database = WalletDatabase.shared
        guard let account = try database.getAccount(index: 0) else {
            print("No account found")
            return
        }

        // Get all spent notes and check if their txids are confirmed
        let spentNotes = try database.getSpentNotes(accountId: account.id)
        print("Found \(spentNotes.count) spent notes to check")

        var recoveredCount = 0
        for note in spentNotes {
            // If the note has no spent_in_tx, it's from a failed broadcast
            if note.spentInTx == nil || note.spentInTx?.isEmpty == true {
                try database.markNoteUnspent(nullifier: note.nullifier)
                recoveredCount += 1
                print("Recovered note with nullifier: \(note.nullifier.map { String(format: "%02x", $0) }.joined().prefix(16))...")
            }
        }

        if recoveredCount > 0 {
            print("Recovered \(recoveredCount) notes from failed transactions")
            try await refreshBalance()
        } else {
            print("No notes needed recovery")
        }
    }

    /// Force recover ALL spent notes back to unspent
    /// Use this when a transaction was rejected by the network but the note was marked as spent
    func forceRecoverAllSpentNotes() async throws -> Int {
        print("Force recovering ALL spent notes...")

        let database = WalletDatabase.shared
        guard let account = try database.getAccount(index: 0) else {
            print("No account found")
            return 0
        }

        // Get all spent notes
        let spentNotes = try database.getSpentNotes(accountId: account.id)
        print("Found \(spentNotes.count) spent notes to recover")

        var recoveredCount = 0
        for note in spentNotes {
            try database.markNoteUnspent(nullifier: note.nullifier)
            recoveredCount += 1
            let nfHex = note.nullifier.map { String(format: "%02x", $0) }.joined().prefix(16)
            print("Recovered note: \(nfHex)...")
        }

        if recoveredCount > 0 {
            print("Force recovered \(recoveredCount) notes")
            try await refreshBalance()
        }

        return recoveredCount
    }

    // MARK: - Address Validation

    /// Check if address is a valid Zclassic z-address
    func isValidZAddress(_ address: String) -> Bool {
        // Use FFI validation for accurate Bech32 decoding
        guard address.hasPrefix("zs1") else {
            return false
        }

        // Use the FFI to validate and decode the address properly
        return ZipherXFFI.validateAddress(address)
    }

    /// Check if address is a t-address (transparent) - we reject these!
    func isTransparentAddress(_ address: String) -> Bool {
        // Zclassic t-addresses start with "t1" or "t3"
        return address.hasPrefix("t1") || address.hasPrefix("t3")
    }

    // MARK: - Key Derivation (ZIP-32)

    private func deriveSpendingKey(from seed: Data) throws -> Data {
        // ZIP-32 Sapling key derivation using real Rust FFI
        // Path: m/32'/147'/0' (purpose=32 for Sapling, coin=147 for ZCL)

        guard seed.count == 64 else {
            throw WalletError.invalidSeed
        }

        // Use ZipherXFFI for real ZIP-32 derivation (returns 96 bytes: ask+nsk+ovk)
        guard let spendingKey = ZipherXFFI.deriveSpendingKey(from: seed, account: 0) else {
            throw WalletError.invalidSeed
        }

        return spendingKey
    }

    private func deriveZAddress(from spendingKey: Data) throws -> String {
        // Use RustBridge to derive address via FFI
        let saplingSpendingKey = SaplingSpendingKey(data: spendingKey)
        let fvk = try RustBridge.shared.deriveFullViewingKey(from: saplingSpendingKey)
        let address = try RustBridge.shared.derivePaymentAddress(from: fvk)
        return address
    }

    // MARK: - Persistence

    /// Set connecting state (called from ContentView during network connection)
    @MainActor
    func setConnecting(_ connecting: Bool, status: String?) {
        isConnecting = connecting
        if let status = status {
            syncStatus = status
        }
    }

    private func loadWalletState() {
        let defaults = UserDefaults.standard
        isWalletCreated = defaults.bool(forKey: "wallet_created")
        zAddress = defaults.string(forKey: "z_address") ?? ""
    }

    private func saveWalletState() {
        let defaults = UserDefaults.standard
        defaults.set(isWalletCreated, forKey: "wallet_created")
        defaults.set(zAddress, forKey: "z_address")
    }

    /// Delete wallet and all associated data
    func deleteWallet() throws {
        try secureStorage.deleteSpendingKey()

        DispatchQueue.main.async {
            self.isWalletCreated = false
            self.zAddress = ""
            self.shieldedBalance = 0
            self.pendingBalance = 0

            let defaults = UserDefaults.standard
            defaults.removeObject(forKey: "wallet_created")
            defaults.removeObject(forKey: "z_address")
        }
    }

    // MARK: - Key Export

    /// Export spending key as Bech32 string for backup (secret-extended-key-main1...)
    /// WARNING: This exposes the private key - handle with extreme care!
    func exportSpendingKey() throws -> String {
        let spendingKey = try secureStorage.retrieveSpendingKey()
        guard let encoded = ZipherXFFI.encodeSpendingKey(spendingKey) else {
            throw WalletError.invalidSeed
        }
        return encoded
    }

    /// Import spending key from Bech32 string (secret-extended-key-main1...)
    /// Also accepts legacy hex format (338 chars)
    func importSpendingKey(_ keyString: String) throws {
        // Clean the input - remove whitespace and newlines
        let cleanKey = keyString.trimmingCharacters(in: .whitespacesAndNewlines)

        print("🔑 Importing key, length: \(cleanKey.count) chars")

        var spendingKey: Data

        // Check if it's Bech32 format (secret-extended-key-main1...)
        if cleanKey.hasPrefix("secret-extended-key-main") {
            guard let keyData = ZipherXFFI.decodeSpendingKey(cleanKey) else {
                // Key decode failed
                throw WalletError.invalidSeed
            }
            spendingKey = keyData
            // SECURITY: Key decoded - not logged
        }
        // Legacy hex format (338 chars)
        else if cleanKey.count == 338 {
            guard let keyData = Data(hexString: cleanKey) else {
                print("❌ Failed to parse hex string")
                throw WalletError.invalidSeed
            }
            spendingKey = keyData
            // SECURITY: Key decoded - not logged
        }
        else {
            print("❌ Invalid key format: expected Bech32 (secret-extended-key-main1...) or hex (338 chars)")
            throw WalletError.invalidSeed
        }

        // Store in secure storage
        try secureStorage.storeSpendingKey(spendingKey)

        // Derive z-address
        let address = try deriveZAddress(from: spendingKey)

        // Update state
        DispatchQueue.main.async {
            self.zAddress = address
            self.isWalletCreated = true
            self.saveWalletState()
        }

        print("✅ Key imported successfully")
    }
}

// MARK: - Wallet Errors
enum WalletError: LocalizedError {
    case walletNotCreated
    case invalidMnemonic
    case invalidSeed
    case invalidAddress(String)
    case insufficientFunds
    case transactionFailed(String)
    case networkError(String)
    case secureEnclaveError(String)

    var errorDescription: String? {
        switch self {
        case .walletNotCreated:
            return "Wallet has not been created yet"
        case .invalidMnemonic:
            return "Invalid mnemonic phrase"
        case .invalidSeed:
            return "Invalid seed data"
        case .invalidAddress(let message):
            return message
        case .insufficientFunds:
            return "Insufficient funds for this transaction"
        case .transactionFailed(let message):
            return "Transaction failed: \(message)"
        case .networkError(let message):
            return "Network error: \(message)"
        case .secureEnclaveError(let message):
            return "Secure Enclave error: \(message)"
        }
    }
}
