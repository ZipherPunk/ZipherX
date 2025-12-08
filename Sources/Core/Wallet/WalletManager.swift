import Foundation
import Combine
import CryptoKit
#if os(macOS)
import AppKit
#endif

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
    @Published private(set) var isImportedWallet: Bool = false  // True if wallet was imported (may have historical notes)
    @Published private(set) var isMnemonicBackupPending: Bool = false  // True when new wallet created, waiting for backup confirmation
    @Published var importScanStartHeight: UInt64? = nil  // Custom scan start height for imported wallets (nil = full scan)
    @Published private(set) var shieldedBalance: UInt64 = 0 // in zatoshis
    @Published private(set) var pendingBalance: UInt64 = 0
    @Published private(set) var zAddress: String = ""
    @Published private(set) var syncProgress: Double = 0.0
    @Published private(set) var isSyncing: Bool = false
    @Published private(set) var isConnecting: Bool = false
    @Published private(set) var syncStatus: String = ""
    @Published private(set) var syncPhase: String = ""  // "phase1", "phase1.5", "phase1.6", "phase2"
    @Published private(set) var lastError: WalletError?
    @Published private(set) var syncTasks: [SyncTask] = []
    @Published private(set) var syncCurrentHeight: UInt64 = 0
    @Published private(set) var syncMaxHeight: UInt64 = 0

    // MARK: - Monotonic Progress (never goes backward!)

    /// Overall progress that ONLY increases (0.0 → 1.0)
    /// This is what the UI should display for a smooth experience
    @Published private(set) var overallProgress: Double = 0.0

    /// Current phase for progress tracking
    private var currentProgressPhase: ProgressPhase = .idle

    /// Progress phase definitions with weight allocations (must sum to 1.0)
    enum ProgressPhase: Int, Comparable {
        case idle = 0
        case downloadingTree = 1      // 0-15% - Downloading CMU file from GitHub
        case loadingTree = 2          // 15-35% - Loading/parsing CMU data
        case connecting = 3           // 35-40% - Connecting to P2P network
        case syncingHeaders = 4       // 40-50% - Header sync
        case phase1Scanning = 5       // 50-70% - Parallel note decryption (Rayon)
        case phase15Witnesses = 6     // 70-80% - Computing Merkle witnesses
        case phase16SpentCheck = 7    // 80-85% - Spent note detection
        case phase2Sequential = 8     // 85-95% - Sequential tree building
        case finalizingBalance = 9    // 95-100% - Final balance calculation
        case complete = 10

        static func < (lhs: ProgressPhase, rhs: ProgressPhase) -> Bool {
            return lhs.rawValue < rhs.rawValue
        }

        /// Base progress (start of this phase)
        var baseProgress: Double {
            switch self {
            case .idle: return 0.0
            case .downloadingTree: return 0.0
            case .loadingTree: return 0.15
            case .connecting: return 0.35
            case .syncingHeaders: return 0.40
            case .phase1Scanning: return 0.50
            case .phase15Witnesses: return 0.70
            case .phase16SpentCheck: return 0.80
            case .phase2Sequential: return 0.85
            case .finalizingBalance: return 0.95
            case .complete: return 1.0
            }
        }

        /// Weight (size) of this phase
        var weight: Double {
            switch self {
            case .idle: return 0.0
            case .downloadingTree: return 0.15
            case .loadingTree: return 0.20
            case .connecting: return 0.05
            case .syncingHeaders: return 0.10
            case .phase1Scanning: return 0.20
            case .phase15Witnesses: return 0.10
            case .phase16SpentCheck: return 0.05
            case .phase2Sequential: return 0.10
            case .finalizingBalance: return 0.05
            case .complete: return 0.0
            }
        }
    }

    /// Update progress - ONLY allows forward movement
    /// - Parameters:
    ///   - phase: Current phase
    ///   - phaseProgress: Progress within this phase (0.0 to 1.0)
    @MainActor
    func updateOverallProgress(phase: ProgressPhase, phaseProgress: Double) {
        // Only allow moving to same or later phase
        guard phase >= currentProgressPhase else {
            print("⚠️ Progress: Ignoring backward phase change \(phase) < \(currentProgressPhase)")
            return
        }

        // Calculate new overall progress
        let clampedPhaseProgress = max(0.0, min(1.0, phaseProgress))
        let newProgress = phase.baseProgress + (phase.weight * clampedPhaseProgress)

        // ONLY update if progress increased
        if newProgress > overallProgress {
            currentProgressPhase = phase
            overallProgress = newProgress
            // print("📊 Progress: \(Int(newProgress * 100))% (phase: \(phase), sub: \(Int(clampedPhaseProgress * 100))%)")
        }
    }

    /// Reset progress for new sync (call at start of sync only)
    @MainActor
    func resetProgress() {
        overallProgress = 0.0
        currentProgressPhase = .idle
    }

    /// Complete progress (jump to 100%)
    @MainActor
    func completeProgress() {
        overallProgress = 1.0
        currentProgressPhase = .complete
    }
    @Published private(set) var transactionHistoryVersion: Int = 0  // Increments when tx history changes

    /// Timestamp of last sent transaction - used to suppress fireworks for change outputs
    @Published private(set) var lastSendTimestamp: Date? = nil

    /// Balance before the most recent send - used to detect change vs real incoming
    @Published private(set) var balanceBeforeLastSend: UInt64? = nil

    /// Timestamp when wallet was created/imported - used for accurate sync timing display
    /// This is set when user clicks Create/Import/Restore, not when app launches
    @Published private(set) var walletCreationTime: Date? = nil

    /// Clear the balance tracking after change output is processed
    /// NOTE: We do NOT clear lastSendTimestamp here - it should persist for the full 120 seconds
    /// so that isLikelyChange remains true and suppresses the pending balance indicator
    @MainActor
    func clearBalanceBeforeLastSend() {
        balanceBeforeLastSend = nil
        // Don't clear lastSendTimestamp - it's needed for isLikelyChange detection
        // lastSendTimestamp will naturally expire after 120 seconds
    }

    // MARK: - Private Properties
    private let secureStorage: SecureKeyStorage
    private let mnemonicGenerator: MnemonicGenerator
    private var cancellables = Set<AnyCancellable>()

    /// Currently active scanner instance (used for stopSync)
    private var currentScanner: FilterScanner?

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
                // Load bundled block hashes for fast P2P fetching (historical scans)
                await preloadBlockHashes()
            }
        }
    }

    /// Pre-load bundled block hashes for fast P2P block fetching
    /// Enables P2P fetching even for blocks not in HeaderStore (historical scans)
    private func preloadBlockHashes() async {
        do {
            try await BundledBlockHashes.shared.loadBundledHashes { current, total in
                // Progress callback (optional logging)
                if current == total {
                    print("✅ Block hashes loaded: \(total) hashes")
                }
            }
        } catch {
            print("⚠️ Failed to load bundled block hashes: \(error)")
            // Non-fatal - will fall back to InsightAPI for historical blocks
        }
    }

    /// Pre-initialize the Groth16 prover for faster transactions
    /// This loads the 50MB+ Sapling params files once at startup
    /// Uses bytes-based loading to avoid macOS Hardened Runtime file access restrictions
    private func preloadProver() async {
        print("⚡ Pre-initializing Groth16 prover...")

        // Check if params are ready
        let params = SaplingParams.shared
        guard params.areParamsReady else {
            print("⏳ Sapling params not ready yet, will initialize at send time")
            return
        }

        // Load param files in Swift (which has full file access)
        // Then pass bytes to Rust (avoids Hardened Runtime file access restrictions)
        let spendPath = params.spendParamsPath
        let outputPath = params.outputParamsPath

        guard let spendData = try? Data(contentsOf: spendPath) else {
            print("⚠️ Failed to read spend params file, will retry at send time")
            return
        }
        guard let outputData = try? Data(contentsOf: outputPath) else {
            print("⚠️ Failed to read output params file, will retry at send time")
            return
        }

        print("📂 Loaded params: spend=\(spendData.count) bytes, output=\(outputData.count) bytes")

        // Initialize prover using bytes (avoids Rust file access issues)
        if ZipherXFFI.initProverFromBytes(spendData: spendData, outputData: outputData) {
            print("✅ Groth16 prover pre-initialized (faster first transaction!)")
        } else {
            print("⚠️ Failed to pre-initialize prover, will retry at send time")
        }
    }

    // MARK: - Tree Preloading

    /// Preload commitment tree at startup for faster transactions
    /// This loads from database (if saved) or downloads from GitHub (first time)
    @Published private(set) var isTreeLoaded: Bool = false
    @Published private(set) var treeLoadProgress: Double = 0.0
    @Published private(set) var treeLoadStatus: String = ""

    // Tree height/count now come from GitHub via ZipherXConstants.effectiveTreeHeight/effectiveTreeCMUCount

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
            // Reset monotonic progress at the start of sync
            self.resetProgress()
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
                // Use effectiveTreeCMUCount (from UserDefaults) which may be from a downloaded tree
                // that's newer than what we had. This prevents false corruption detection.
                let effectiveHeight = ZipherXConstants.effectiveTreeHeight
                let effectiveCMUCount = ZipherXConstants.effectiveTreeCMUCount

                let lastScanned = (try? WalletDatabase.shared.getLastScannedHeight()) ?? effectiveHeight
                let blocksAfterEffective = max(0, Int64(lastScanned) - Int64(effectiveHeight))
                let maxExpectedCMUs = effectiveCMUCount + UInt64(blocksAfterEffective) * 20 // realistic max ~20 per block

                if treeSize < effectiveCMUCount || treeSize > maxExpectedCMUs {
                    print("⚠️ Tree size \(treeSize) seems invalid (expected \(effectiveCMUCount)-\(maxExpectedCMUs))")
                    print("🔄 Clearing corrupted tree state, will reload from GitHub...")
                    // Clear the corrupted state from database
                    try? WalletDatabase.shared.clearTreeState()
                    try? WalletDatabase.shared.updateLastScannedHeight(effectiveHeight, hash: Data(count: 32))
                    // Fall through to reload from GitHub
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

        // Download boost file from GitHub (required - no bundled fallback)
        print("🚀 Downloading boost file from GitHub...")
        await MainActor.run {
            self.treeLoadStatus = "Downloading boost data..."
            self.treeLoadProgress = 0.1
        }

        var downloadedTreeHeight: UInt64 = 0
        var downloadedCMUCount: UInt64 = 0

        do {
            // Download the unified boost file (contains tree, outputs, spends, etc.)
            let (_, height, cmuCount) = try await CommitmentTreeUpdater.shared.getBestAvailableBoostFile { progress, status in
                Task { @MainActor in
                    self.treeLoadProgress = 0.1 + progress * 0.2  // 10-30% for download
                    self.treeLoadStatus = status
                }
            }
            downloadedTreeHeight = height
            downloadedCMUCount = cmuCount
            print("🚀 Downloaded boost file from GitHub: height \(height) (\(cmuCount) outputs)")
        } catch {
            print("❌ GitHub boost file download failed: \(error.localizedDescription)")
            await MainActor.run {
                self.treeLoadStatus = "Failed to download boost data"
            }
            return
        }

        // Extract and load the serialized tree from the boost file
        print("🌳 Extracting commitment tree...")
        await MainActor.run {
            self.treeLoadStatus = "Restoring privacy infrastructure..."
            self.treeLoadProgress = 0.3
            self.updateOverallProgress(phase: .loadingTree, phaseProgress: 0.1)
        }

        let serializedData: Data
        do {
            serializedData = try await CommitmentTreeUpdater.shared.extractSerializedTree()
            print("🌲 Extracted serialized tree: \(serializedData.count) bytes")
        } catch {
            print("❌ Failed to extract tree from boost file: \(error.localizedDescription)")
            await MainActor.run {
                self.treeLoadStatus = "Failed to extract commitment tree"
            }
            return
        }

        print("🌲 Deserializing commitment tree...")
        if ZipherXFFI.treeDeserialize(data: serializedData) {
            let treeSize = ZipherXFFI.treeSize()
            print("✅ Commitment tree loaded instantly: \(treeSize) commitments (height \(downloadedTreeHeight))")

            // Store effective height for FilterScanner
            UserDefaults.standard.set(Int(downloadedTreeHeight), forKey: "effectiveTreeHeight")
            UserDefaults.standard.set(Int(downloadedCMUCount), forKey: "effectiveTreeCMUCount")

            // Save to database for next time
            if let serializedTree = ZipherXFFI.treeSerialize() {
                try? WalletDatabase.shared.saveTreeState(serializedTree)
                print("💾 Tree state saved to database for future use")
            }

            await MainActor.run {
                self.isTreeLoaded = true
                self.treeLoadProgress = 1.0
                self.treeLoadStatus = "Privacy infrastructure ready\n\(treeSize.formatted()) commitments loaded"
                self.updateOverallProgress(phase: .loadingTree, phaseProgress: 1.0)
            }
            return
        }

        // Deserialization failed - this is unexpected with the new format
        print("❌ Tree deserialization failed - boost file may be corrupted")
        await MainActor.run {
            self.treeLoadStatus = "Failed to load commitment tree"
            self.treeLoadProgress = 0.0
        }

        // Clear the corrupted boost file and try again next time
        try? await CommitmentTreeUpdater.shared.clearCache()
        return
    }

    // MARK: - Removed CMU Rebuild Logic
    // The new unified boost file always includes a pre-serialized tree,
    // so we no longer need to rebuild from individual CMUs.
    // If the tree section is corrupted, we clear the cache and re-download.


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
        let currentHeight = (try? WalletDatabase.shared.getLastScannedHeight()) ?? ZipherXConstants.effectiveTreeHeight
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
                // Note at same height as target = 1 confirmation (it's in a block)
                let confirmations = targetHeight >= note.height ? Int(targetHeight - note.height + 1) : 0
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

            // Update wallet height in NetworkManager for UI display
            NetworkManager.shared.updateWalletHeight(targetHeight)

            // Sync headers for the new blocks so we have real timestamps
            // This ensures transaction history shows correct dates instead of "(est)"
            do {
                let hsm = HeaderSyncManager(
                    headerStore: HeaderStore.shared,
                    networkManager: NetworkManager.shared
                )
                try await hsm.syncHeaders(from: currentHeight + 1)

                // Fix any transactions that have estimated timestamps
                try? WalletDatabase.shared.fixTransactionBlockTimes()
                print("📜 Fixed transaction timestamps after background sync")
            } catch {
                // Header sync failed but block scan succeeded - not critical
                print("⚠️ Background header sync failed: \(error.localizedDescription)")
            }

        } catch {
            print("⚠️ Background sync failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Wallet Creation

    /// Create a new wallet with a fresh mnemonic
    /// - Returns: The 24-word mnemonic for backup
    func createNewWallet() throws -> [String] {
        // NOTE: walletCreationTime is set in confirmMnemonicBackup() when user clicks "I'VE SAVED MY SEED PHRASE"
        // This ensures sync timing starts from user confirmation, not from wallet generation

        // Generate 24-word mnemonic (256-bit entropy)
        let mnemonic = try mnemonicGenerator.generateMnemonic(wordCount: 24)

        // Derive seed from mnemonic
        let seed = try mnemonicGenerator.mnemonicToSeed(mnemonic: mnemonic)

        // Derive Sapling spending key using ZIP-32
        let spendingKey = try deriveSpendingKey(from: seed)

        // Store spending key in Secure Enclave
        try secureStorage.storeSpendingKey(spendingKey)

        // VUL-014: Record key creation date for rotation policy
        secureStorage.recordKeyCreationDate()

        // Derive z-address from spending key
        let address = try deriveZAddress(from: spendingKey)

        // Print address to console for debugging
        print("🔐 Generated z-address: \(address)")
        print("🔐 Address length: \(address.count) characters")

        // CRITICAL: Reset database state for new wallet
        // This ensures we scan from downloadedTreeHeight, not from a previous wallet's lastScannedHeight
        print("🗑️ Resetting database state for new wallet...")
        try? resetDatabaseForNewWallet()

        // Update state - new wallet (not imported, no historical notes possible)
        // NOTE: We set isMnemonicBackupPending = true instead of isWalletCreated = true
        // This allows the mnemonic backup sheet to be shown BEFORE switching to main view
        // isWalletCreated will be set to true when user confirms backup via confirmMnemonicBackup()
        DispatchQueue.main.async {
            self.zAddress = address
            self.isMnemonicBackupPending = true  // Flag that backup sheet should be shown
            self.isImportedWallet = false  // New wallet - fast startup OK
            // Don't save wallet state yet - wait for backup confirmation
        }

        return mnemonic
    }

    /// Called when user confirms they have saved their seed phrase
    /// This completes the wallet creation process
    func confirmMnemonicBackup() {
        DispatchQueue.main.async {
            // Record creation time NOW - when user clicks "I'VE SAVED MY SEED PHRASE"
            // This is the true start of sync timing
            self.walletCreationTime = Date()
            print("⏱️ Wallet creation time set at: \(self.walletCreationTime!) (user confirmed backup)")

            self.isMnemonicBackupPending = false
            self.isWalletCreated = true
            self.saveWalletState()
            print("✅ Mnemonic backup confirmed, wallet creation complete")
        }
    }

    /// Restore wallet from mnemonic
    func restoreWallet(from mnemonic: [String]) throws {
        // Use print() for crash debugging - debugLog() might be causing issues
        print("🔑 RESTORE [1]: Starting restore with \(mnemonic.count) words")

        // Record creation time - use async to avoid deadlock if called from main thread
        if Thread.isMainThread {
            self.walletCreationTime = Date()
        } else {
            DispatchQueue.main.sync {
                self.walletCreationTime = Date()
            }
        }
        print("🔑 RESTORE [2]: walletCreationTime set")

        print("🔑 RESTORE [3]: About to validate mnemonic...")

        // Validate mnemonic - wrap in do/catch to see any errors
        let isValid: Bool
        do {
            isValid = mnemonicGenerator.validateMnemonic(mnemonic)
            print("🔑 RESTORE [4]: validateMnemonic returned \(isValid)")
        } catch {
            print("❌ RESTORE: validateMnemonic threw: \(error)")
            throw error
        }

        guard isValid else {
            print("❌ RESTORE [5]: Mnemonic validation returned false")
            throw WalletError.invalidMnemonic
        }
        print("✅ RESTORE [6]: Mnemonic validated successfully")

        // Derive seed
        print("🔑 RESTORE [7]: Deriving seed from mnemonic...")
        let seed = try mnemonicGenerator.mnemonicToSeed(mnemonic: mnemonic)
        print("✅ RESTORE [8]: Seed derived (\(seed.count) bytes)")

        // Derive spending key
        let spendingKey = try deriveSpendingKey(from: seed)

        // Store in Secure Enclave
        try secureStorage.storeSpendingKey(spendingKey)

        // VUL-014: Record key creation date for rotation policy
        // For imported keys, this marks the import date (not original creation)
        secureStorage.recordKeyCreationDate()

        // Derive z-address
        let address = try deriveZAddress(from: spendingKey)

        // CRITICAL: Delete and recreate database for restored wallet
        // This ensures NO old data persists (old lastScannedHeight, notes, etc.)
        print("🗑️ Deleting old database for restored wallet...")

        do {
            try WalletDatabase.shared.deleteDatabase()
            print("✅ Old database deleted")
        } catch {
            print("⚠️ Failed to delete database: \(error)")
        }

        // Open fresh database with new key
        let dbKey = Data(SHA256.hash(data: spendingKey))
        do {
            try WalletDatabase.shared.open(encryptionKey: dbKey)
            print("✅ Fresh database created with new key")
        } catch {
            print("⚠️ Failed to open database: \(error)")
        }

        // Reset tree state in FFI memory as well
        isTreeLoaded = false
        treeLoadProgress = 0.0
        treeLoadStatus = ""

        // Update state - restored wallet (may have historical notes)
        DispatchQueue.main.async {
            self.zAddress = address
            self.isWalletCreated = true
            self.isImportedWallet = true  // Restored wallet - scan for historical notes
            self.saveWalletState()
        }
    }

    /// Reset database state for a new or restored wallet
    /// Clears notes, tree state, scan history, and transaction history
    private func resetDatabaseForNewWallet() throws {
        print("🗑️ Clearing old wallet data from database...")

        // Check if database is open - if not, skip clearing (nothing to clear)
        guard WalletDatabase.shared.isOpen else {
            print("⚠️ Database not open yet - skipping reset (will be fresh on first open)")
            return
        }

        // Clear tree state
        try? WalletDatabase.shared.clearTreeState()

        // Reset last scanned height to 0 (will be set to downloadedTreeHeight during scan)
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

        // Suppress notifications during initial sync for imported wallets
        // to avoid notification spam from historical transactions
        let wasImported = isImportedWallet
        if wasImported {
            NotificationManager.shared.isInitialSyncInProgress = true
            print("🔕 Notifications suppressed during initial import sync")
        }

        // Initialize sync tasks
        await MainActor.run {
            self.isSyncing = true
            self.syncProgress = 0.0
            self.syncStatus = "Initializing privacy shield..."
            // Move to connecting phase (tree loading should already be done)
            self.updateOverallProgress(phase: .connecting, phaseProgress: 0.0)
            self.syncTasks = [
                SyncTask(id: "params", title: "Load zk-SNARK circuits", status: .pending),
                SyncTask(id: "keys", title: "Derive spending keys", status: .pending),
                SyncTask(id: "database", title: "Unlock encrypted vault", status: .pending),
                SyncTask(id: "download_outputs", title: "Download shielded outputs", status: .pending),
                SyncTask(id: "download_timestamps", title: "Download block timestamps", status: .pending),
                SyncTask(id: "headers", title: "Verify peer consensus (3/3)", status: .pending),
                SyncTask(id: "height", title: "Query chain tip from peers", status: .pending),
                SyncTask(id: "scan", title: "Decrypt shielded notes", status: .pending),
                SyncTask(id: "witnesses", title: "Build Merkle witnesses", status: .pending),
                SyncTask(id: "balance", title: "Tally unspent notes", status: .pending)
            ]
        }

        defer {
            DispatchQueue.main.async {
                self.isSyncing = false
            }
            // Always re-enable notifications on exit (success or failure)
            if wasImported {
                NotificationManager.shared.isInitialSyncInProgress = false
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

        // SECURITY CHECK: Validate lastScannedHeight against trusted chain height
        // Malicious P2P peers may have caused fake heights to be stored
        let effectiveTreeHeight = ZipherXConstants.effectiveTreeHeight
        do {
            let lastScanned = try WalletDatabase.shared.getLastScannedHeight()
            if lastScanned > effectiveTreeHeight {
                // Query InsightAPI for trusted chain height
                let status = try await InsightAPI.shared.getStatus()
                let trustedHeight = status.height
                let maxAheadTolerance: UInt64 = 10

                if lastScanned > trustedHeight + maxAheadTolerance {
                    print("🚨 [SECURITY] Detected FAKE lastScannedHeight: \(lastScanned)")
                    print("🚨 [SECURITY] Trusted chain height is: \(trustedHeight)")
                    print("🧹 Resetting to downloaded tree height...")

                    // Reset to safe state
                    try WalletDatabase.shared.updateLastScannedHeight(effectiveTreeHeight, hash: Data(count: 32))
                    try? HeaderStore.shared.open()
                    try? HeaderStore.shared.clearAllHeaders()

                    print("✅ Fake sync state cleared - will rescan from trusted height")
                }
            }
        } catch {
            print("⚠️ Could not validate lastScannedHeight: \(error)")
            // Continue anyway - HeaderSyncManager will also validate
        }

        // Task 3: Sync block headers (with retry logic for peer timing issues)
        // NOTE: Header sync is optional for balance display - if it fails, we continue anyway
        // Headers are only needed for transaction building (anchor verification)
        await updateTask("headers", status: .inProgress)

        let maxHeaderRetries = 2  // Reduced from 3 to fail faster
        var headerSyncSuccess = false
        var lastHeaderError: Error?

        for attempt in 1...maxHeaderRetries {
            do {
                if attempt > 1 {
                    print("🔄 Header sync retry attempt \(attempt)/\(maxHeaderRetries)...")
                    await updateTask("headers", status: .inProgress, detail: "Retry \(attempt)/\(maxHeaderRetries)")
                    // Wait briefly for peers to recover - reduced from 2 seconds
                    try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
                }

                print("📥 Opening header store...")
                try HeaderStore.shared.open()

                // CRITICAL: Check for corrupted header timestamps
                // Bug: Headers were being assigned wrong heights (from genesis instead of downloaded tree)
                // This caused timestamps to show 2016 instead of 2025
                // Detection: If a header at recent height has timestamp < 2024, it's corrupted
                let corruptedTimestampThreshold: UInt32 = 1704067200 // Jan 1, 2024 UTC
                if let latestHeight = try? HeaderStore.shared.getLatestHeight(),
                   latestHeight >= effectiveTreeHeight,
                   let sampleHeader = try? HeaderStore.shared.getHeader(at: effectiveTreeHeight + 100),
                   sampleHeader.time < corruptedTimestampThreshold {
                    print("🚨 [CRITICAL] Detected corrupted header timestamps (showing 2016 dates)")
                    print("🧹 Clearing all headers to trigger fresh sync with correct data...")
                    try HeaderStore.shared.clearAllHeaders()
                    print("✅ Corrupted headers cleared")
                }

                // CRITICAL: Ensure block hashes are loaded BEFORE header sync
                // Without block hashes, P2P getheaders will use zero locator hash,
                // causing peers to return genesis headers with wrong Equihash params (200,9 instead of 192,7)
                print("📦 Ensuring block hashes are loaded for header sync locator...")
                if !BundledBlockHashes.shared.isLoaded {
                    do {
                        try await BundledBlockHashes.shared.loadBundledHashes()
                        print("✅ Block hashes ready for header sync")
                    } catch {
                        print("⚠️ Block hashes failed to load: \(error) - header sync may get wrong Equihash params")
                    }
                } else {
                    print("✅ Block hashes already loaded")
                }

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

                            // Update monotonic progress for header sync phase
                            self?.updateOverallProgress(phase: .syncingHeaders, phaseProgress: progressPercentage)
                        }
                    }
                }

                // Get starting height for sync
                // We want headers from downloadedTreeHeight + 1 onwards (tree includes up to downloadedTreeHeight)
                // The getheaders protocol returns headers AFTER the locator hash
                // VUL-018: Use shared constant for downloaded tree height
                let downloadedTreeHeight = ZipherXConstants.effectiveTreeHeight
                let startHeight: UInt64
                if let latestHeight = try HeaderStore.shared.getLatestHeight(), latestHeight >= downloadedTreeHeight {
                    // Resume from where we left off
                    startHeight = latestHeight + 1
                    print("📊 Resuming header sync from height \(startHeight)")
                } else {
                    // Start from downloadedTreeHeight + 1 (checkpoint at downloadedTreeHeight used as locator)
                    startHeight = downloadedTreeHeight + 1
                    print("📊 Starting header sync from height \(startHeight) (checkpoint at \(downloadedTreeHeight))")
                }

                try await headerSync.syncHeaders(from: startHeight)

                let stats = try HeaderStore.shared.getStats()
                print("✅ Header sync complete! Stored \(stats.count) headers (latest: \(stats.latestHeight ?? 0))")

                // Fix any transaction timestamps that were estimated instead of real block times
                try? WalletDatabase.shared.fixTransactionBlockTimes()

                await updateTask("headers", status: .completed)
                headerSyncSuccess = true
                break // Success - exit retry loop

            } catch {
                lastHeaderError = error
                print("⚠️ Header sync attempt \(attempt) failed: \(error.localizedDescription)")

                if attempt == maxHeaderRetries {
                    // Final attempt failed - mark as failed
                    await updateTask("headers", status: .failed(error.localizedDescription))
                }
            }
        }

        if !headerSyncSuccess {
            print("⚠️ Header sync failed after \(maxHeaderRetries) attempts: \(lastHeaderError?.localizedDescription ?? "unknown")")
            // Continue anyway - transactions will fail if headers aren't synced
            // but user can still see the error and try again
        }

        // Task 4: Get chain height
        await updateTask("height", status: .inProgress)

        // Task 4: Scan blockchain
        await updateTask("scan", status: .inProgress)
        let scanner = FilterScanner()
        self.currentScanner = scanner  // Store reference for stopSync()

        // VUL-018: Use shared constant for downloaded tree height
        let downloadedTreeHeight = ZipherXConstants.effectiveTreeHeight

        // Status update callback - handles phase transitions and messages
        scanner.onStatusUpdate = { [weak self] phase, status in
            Task { @MainActor in
                self?.syncPhase = phase
                self?.syncStatus = status

                // Update task detail and monotonic progress based on phase
                if let index = self?.syncTasks.firstIndex(where: { $0.id == "scan" }) {
                    switch phase {
                    case "phase1":
                        self?.syncTasks[index].detail = "Parallel note decryption"
                        self?.updateOverallProgress(phase: .phase1Scanning, phaseProgress: 0.0)
                    case "phase1.5":
                        self?.syncTasks[index].detail = "Computing Merkle witnesses"
                        self?.updateOverallProgress(phase: .phase15Witnesses, phaseProgress: 0.0)
                    case "phase1.6":
                        self?.syncTasks[index].detail = "Detecting spent notes"
                        self?.updateOverallProgress(phase: .phase16SpentCheck, phaseProgress: 0.0)
                    case "phase2":
                        self?.syncTasks[index].detail = "Sequential tree building"
                        self?.updateOverallProgress(phase: .phase2Sequential, phaseProgress: 0.0)
                    default:
                        break
                    }
                }
            }
        }

        scanner.onProgress = { [weak self] progress, currentHeight, maxHeight in
            Task { @MainActor in
                self?.syncProgress = progress
                self?.syncCurrentHeight = currentHeight
                self?.syncMaxHeight = maxHeight

                // Update monotonic progress based on current phase
                let phase = self?.syncPhase ?? ""
                switch phase {
                case "phase1":
                    self?.updateOverallProgress(phase: .phase1Scanning, phaseProgress: progress)
                case "phase1.5":
                    self?.updateOverallProgress(phase: .phase15Witnesses, phaseProgress: progress)
                case "phase1.6":
                    self?.updateOverallProgress(phase: .phase16SpentCheck, phaseProgress: progress)
                case "phase2":
                    self?.updateOverallProgress(phase: .phase2Sequential, phaseProgress: progress)
                default:
                    // For early sync phases, use syncingHeaders
                    self?.updateOverallProgress(phase: .syncingHeaders, phaseProgress: progress)
                }

                if let index = self?.syncTasks.firstIndex(where: { $0.id == "scan" }) {
                    // Show context: scanning from checkpoint to current with estimated date
                    // Estimate date for current block height
                    let estimatedDate = self?.estimateDateForBlock(height: currentHeight) ?? ""
                    let dateString = estimatedDate.isEmpty ? "" : " (\(estimatedDate))"

                    // Include phase in the detail if available
                    let phasePrefix: String
                    switch self?.syncPhase {
                    case "phase1": phasePrefix = "⚡ "
                    case "phase1.5": phasePrefix = "🌲 "
                    case "phase1.6": phasePrefix = "🔍 "
                    case "phase2": phasePrefix = "📦 "
                    default: phasePrefix = ""
                    }

                    self?.syncTasks[index].detail = "\(phasePrefix)Block \(currentHeight.formatted())\(dateString)"
                    self?.syncTasks[index].progress = progress
                }

                // Update syncStatus with cypherpunk messages based on scan phase
                // Only update if no specific status was set by onStatusUpdate
                if self?.syncPhase == "phase1" {
                    // PHASE 1: Parallel note discovery
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
                } else if self?.syncPhase == "phase2" {
                    // PHASE 2: Sequential tree building
                    let phase2Messages = [
                        "Building commitment tree...",
                        "Extending the Merkle frontier...",
                        "Cryptographic tree expansion...",
                        "Securing new commitments...",
                        "Zero-knowledge sync active..."
                    ]
                    let blocksAfterDownloaded = currentHeight > downloadedTreeHeight ? currentHeight - downloadedTreeHeight : 0
                    let messageIndex = Int(blocksAfterDownloaded / 1000) % phase2Messages.count
                    self?.syncStatus = phase2Messages[messageIndex]
                }
                // Note: phase1.5 and phase1.6 status is set by onStatusUpdate
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
        // IMPORTANT: Use multiple sources to avoid 0 chain height bug
        // Priority: scanner > NetworkManager > lastScannedHeight
        var chainHeight = scanner.currentChainHeight
        if chainHeight == 0 {
            chainHeight = UInt64(NetworkManager.shared.chainHeight)
        }
        if chainHeight == 0 {
            // Fallback to last scanned height from database
            chainHeight = (try? WalletDatabase.shared.getLastScannedHeight()) ?? 0
        }
        print("📊 Balance calculation using chainHeight: \(chainHeight)")

        var totalBalance: UInt64 = 0
        var pendingBalance: UInt64 = 0

        for i in unspentNotes.indices {
            // Calculate confirmations: chainHeight - noteHeight + 1
            // Note at same height as chain tip = 1 confirmation (it's in a block)
            // Note above chain tip = 0 confirmations (shouldn't happen but be safe)
            let confirmations = chainHeight >= unspentNotes[i].height ? Int(chainHeight - unspentNotes[i].height + 1) : 0
            unspentNotes[i].confirmations = confirmations

            // Require only 1 confirmation for balance (note must be in a block)
            // Once mined, immediately show in balance (no pending message needed)
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

        // Update monotonic progress - entering finalization phase
        await MainActor.run {
            self.updateOverallProgress(phase: .finalizingBalance, phaseProgress: 0.5)
        }

        // Update transaction confirmations based on current chain height
        if chainHeight > 0 {
            try? database.updateAllConfirmations(chainHeight: chainHeight)
        }

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

        // Update wallet height in NetworkManager for UI display
        let lastScannedHeight = (try? database.getLastScannedHeight()) ?? 0
        NetworkManager.shared.updateWalletHeight(lastScannedHeight)

        // CRITICAL FIX: Clear isImportedWallet after first successful sync
        // This prevents the app from doing a full historical scan on every startup
        // The flag should only be true during the FIRST sync after importing a wallet
        if isImportedWallet {
            print("✅ First import sync complete - clearing isImportedWallet flag for fast future startups")
            DispatchQueue.main.async {
                self.isImportedWallet = false
                UserDefaults.standard.set(false, forKey: "wallet_imported")
                UserDefaults.standard.synchronize()
            }
        }

        // Complete monotonic progress - we're done!
        await MainActor.run {
            self.completeProgress()
        }

        print("✅ Sync complete: balance task finished")
    }

    /// Sync witnesses for notes beyond downloaded tree to match current tree state
    /// This ensures witnesses are ready for spending without rebuild at transaction time
    private func syncWitnesses(accountId: Int64, downloadedTreeHeight: UInt64) async throws {
        let database = WalletDatabase.shared

        // Get all unspent notes
        let notes = try database.getUnspentNotes(accountId: accountId)

        // Filter notes beyond downloaded tree that might need witness update
        let notesNeedingSync = notes.filter { note in
            // Notes beyond downloaded tree need witness sync
            note.height > downloadedTreeHeight &&
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

        print("🔄 Syncing \(notesNeedingSync.count) witness(es) beyond downloaded tree...")

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
                downloadedTreeHeight: downloadedTreeHeight
            ) {
                // Save updated witness to database
                try? database.updateNoteWitness(noteId: note.id, witness: result.witness)
                // Extract anchor from witness and save it - ensures INSTANT mode works
                if let anchor = ZipherXFFI.witnessGetRoot(result.witness) {
                    try? database.updateNoteAnchor(noteId: note.id, anchor: anchor)
                }
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
    ///   - fromHeight: Optional start height (defaults to loading downloaded tree height)
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

        // Download reliable peers from GitHub (for faster initial connection)
        let _ = await NetworkManager.shared.downloadReliablePeersFromGitHub()

        // Ensure network connection before scanning
        print("📡 Ensuring network connection...")
        if !NetworkManager.shared.isConnected {
            try await NetworkManager.shared.connect()
            // Wait a moment for connection to stabilize
            try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
        }
        print("✅ Network connected: \(NetworkManager.shared.peers.count) peer(s)")

        // VUL-018: Use shared constant for downloaded tree height
        let downloadedTreeHeight = ZipherXConstants.effectiveTreeHeight

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
            // Check if the requested height is within the downloaded tree range
            if startHeight <= downloadedTreeHeight {
                // For heights within downloaded tree: use quick scan (note detection only, no tree changes)
                // This preserves the correct downloaded tree while finding notes
                // NOTE: We do NOT clear existing notes - just scan for additional ones
                print("🔍 Quick scan mode: height \(startHeight) is within downloaded tree range (ends at \(downloadedTreeHeight))")
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
                // Height is beyond downloaded tree - do sequential scan from downloaded tree end
                print("⚠️ Full rescan from height \(startHeight) is beyond downloaded tree (\(downloadedTreeHeight))")
                print("🔄 Will continue sequential scan from downloaded tree end")
                try WalletDatabase.shared.resetSyncState()
            }
        } else {
            // Reset all sync state (notes, nullifiers, tree)
            try WalletDatabase.shared.resetSyncState()
            // Also clear header store to remove any stale/fake P2P headers
            try? HeaderStore.shared.clearAllHeaders()
            print("🔄 Reset complete (including headers) - starting full rescan from Sapling activation")
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

    /// Repair database with full resync
    /// This deletes ALL notes and transaction history, then does a complete rescan
    /// to rebuild everything with correct nullifiers and positions
    /// - Parameter onProgress: Callback with (progress, currentHeight, maxHeight)
    func repairNotesAfterDownloadedTree(onProgress: @escaping (Double, UInt64, UInt64) -> Void) async throws {
        guard isWalletCreated else {
            throw WalletError.walletNotCreated
        }

        // VUL-018: Use shared constant for downloaded tree height
        let downloadedTreeHeight = ZipherXConstants.effectiveTreeHeight

        // Get spending key
        let spendingKey = try secureStorage.retrieveSpendingKey()
        // SECURITY: Key retrieved - not logged

        // Ensure database is open
        let dbKey = Data(SHA256.hash(data: spendingKey))
        try WalletDatabase.shared.open(encryptionKey: dbKey)
        print("📂 Database opened for repair")

        // Get account ID
        guard let account = try WalletDatabase.shared.getAccount(index: 0) else {
            print("❌ No account found in database")
            throw WalletError.walletNotCreated
        }
        print("👤 Account ID: \(account.id)")

        // FULL RESYNC: Delete ALL notes (not just after tree height)
        // This ensures all corrupted data is removed
        print("🗑️ Deleting ALL notes for full resync...")
        try WalletDatabase.shared.deleteAllNotes()
        print("🗑️ All notes deleted")

        // Clear ALL transaction history
        try WalletDatabase.shared.clearTransactionHistory()
        print("🗑️ Cleared transaction history")

        // Clear tree state so it gets rebuilt from downloaded CMUs
        try WalletDatabase.shared.clearTreeState()
        print("🌳 Cleared tree state")

        // Also delete cached boost file to force re-download from GitHub
        let boostCacheDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ZipherX")
            .appendingPathComponent("BoostCache")
        if FileManager.default.fileExists(atPath: boostCacheDir.path) {
            try? FileManager.default.removeItem(at: boostCacheDir)
            print("🗑️ Cleared boost cache (will re-download from GitHub)")
        }

        // Reset last scanned height to 0 for full rescan
        try WalletDatabase.shared.updateLastScannedHeight(0, hash: Data(count: 32))
        print("📝 Reset last scanned height to 0")

        // Ensure network connection
        print("📡 Ensuring network connection...")
        if !NetworkManager.shared.isConnected {
            try await NetworkManager.shared.connect()
            try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
        }
        print("✅ Network connected: \(NetworkManager.shared.peers.count) peer(s)")

        // Wait for any existing scan to complete
        if FilterScanner.isScanInProgress {
            print("⏳ Waiting for existing scan to complete...")
            var waitCount = 0
            while FilterScanner.isScanInProgress && waitCount < 60 {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                waitCount += 1
            }
        }

        // Clear the in-memory tree and reload from downloaded CMUs
        // CRITICAL: Reset isTreeLoaded flag so preloadCommitmentTree() actually reloads
        // Without this, preloadCommitmentTree() returns immediately because isTreeLoaded is true
        await MainActor.run {
            self.isTreeLoaded = false
            self.treeLoadProgress = 0.0
            self.treeLoadStatus = ""
        }
        // Also clear the FFI tree to ensure fresh start
        _ = ZipherXFFI.treeInit()
        print("🌳 Reloading commitment tree from GitHub...")
        await preloadCommitmentTree()

        // Get the new downloaded tree height (from GitHub)
        let newTreeHeight = ZipherXConstants.effectiveTreeHeight
        print("📦 GitHub boost file height: \(newTreeHeight)")

        // Scan from boost height + 1 to current chain tip
        // This uses sequential mode which properly calculates positions
        let scanner = FilterScanner()
        scanner.onProgress = onProgress

        print("🔄 Starting full rescan from height \(newTreeHeight + 1)...")
        try await scanner.startScan(for: account.id, viewingKey: spendingKey, fromHeight: newTreeHeight + 1)

        // Refresh balance
        try await refreshBalance()
        print("✅ Database repair complete - full resync finished")
    }

    /// Rebuild witnesses from downloaded tree height
    /// This is needed when witnesses are invalid (e.g., after quick scan)
    /// Uses downloaded CMUs and scans sequentially to build proper witnesses
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

        // FAST PATH: Try to rebuild witnesses using stored CMUs and downloaded tree
        let notes = try WalletDatabase.shared.getAllUnspentNotes(accountId: account.id)
        print("📝 Found \(notes.count) notes to rebuild witnesses for")

        // Load CMU data from GitHub cache
        guard let cmuFilePath = await CommitmentTreeUpdater.shared.getCachedCMUFilePath(),
              let downloadedData = try? Data(contentsOf: cmuFilePath) else {
            print("❌ CMU file not found in GitHub cache, falling back to full scan")
            try await rebuildWitnessesViaFullScan(account: account, spendingKey: spendingKey, onProgress: onProgress)
            return
        }

        print("📦 Loaded CMU data from GitHub cache: \(downloadedData.count) bytes")

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
            // All notes have CMU - check if any are beyond downloaded range
            print("🚀 Checking notes for witness rebuild...")

            // VUL-018: Use shared constant for downloaded tree height
            let downloadedTreeHeight = ZipherXConstants.effectiveTreeHeight

            // Check if ANY note is beyond downloaded range
            let notesBeyondDownloaded = notesWithCMU.filter { $0.height > downloadedTreeHeight }
            if !notesBeyondDownloaded.isEmpty {
                print("⚠️ Found \(notesBeyondDownloaded.count) notes beyond downloaded range - need live scan")
                print("📡 Scanning from downloaded height to chain tip...")

                // Load downloaded tree first
                if ZipherXFFI.treeLoadFromCMUs(data: downloadedData) {
                    let treeSize = ZipherXFFI.treeSize()
                    print("✅ Loaded downloaded tree: \(treeSize) commitments")
                }

                // Ensure network connection
                if !NetworkManager.shared.isConnected {
                    try await NetworkManager.shared.connect()
                    try await Task.sleep(nanoseconds: 500_000_000)
                }

                // Scan from downloaded tree height to find notes AND detect spent nullifiers
                let scanner = FilterScanner()
                scanner.onProgress = onProgress
                try await scanner.startScan(for: account.id, viewingKey: spendingKey, fromHeight: downloadedTreeHeight + 1)

                // Refresh balance after scan (will detect spent notes)
                try await refreshBalance()
                print("✅ Live scan complete - witnesses built and spent notes detected")
                return
            }

            // All notes within downloaded range - use fast path
            print("🚀 All notes within downloaded range - using fast witness rebuild")

            for (index, note) in notesWithCMU.enumerated() {
                guard let cmu = note.cmu else { continue }

                // Report progress
                let progress = Double(index + 1) / Double(notesWithCMU.count)
                await MainActor.run {
                    onProgress(progress, UInt64(index + 1), UInt64(notesWithCMU.count))
                }

                // Use treeCreateWitnessForCMU for notes within downloaded range
                if let result = ZipherXFFI.treeCreateWitnessForCMU(cmuData: downloadedData, targetCMU: cmu) {
                    let (position, witness) = result
                    print("✅ Created witness for note \(note.id): position=\(position), witness=\(witness.count) bytes")

                    // Update witness in database
                    try WalletDatabase.shared.updateNoteWitness(noteId: note.id, witness: witness)
                    // Extract anchor from witness and save it - ensures INSTANT mode works
                    if let anchor = ZipherXFFI.witnessGetRoot(witness) {
                        try WalletDatabase.shared.updateNoteAnchor(noteId: note.id, anchor: anchor)
                    }
                } else {
                    print("⚠️ Failed to create witness for note \(note.id) - CMU not in downloaded tree")
                }
            }

            // Load the downloaded tree into memory for spending
            if ZipherXFFI.treeLoadFromCMUs(data: downloadedData) {
                let treeSize = ZipherXFFI.treeSize()
                print("✅ Loaded downloaded tree for spending: \(treeSize) commitments")
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
        // Don't let it use downloaded tree height as start - that would skip notes within downloaded range
        let saplingActivation: UInt64 = 476969
        print("🔄 Starting full rescan from Sapling activation (\(saplingActivation)) to rediscover all notes")

        try await scanner.startScan(for: account.id, viewingKey: spendingKey, fromHeight: saplingActivation)

        // Refresh balance after scan
        try await refreshBalance()
        print("✅ Witness rebuild complete - notes can now be spent")
    }

    /// Perform a quick scan for notes starting from a specific height
    /// Uses downloaded tree - only scans for notes, doesn't rebuild tree
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
            // Recent scan - load pre-built tree from GitHub cache
            if let cmuFilePath = await CommitmentTreeUpdater.shared.getCachedCMUFilePath(),
               let downloadedData = try? Data(contentsOf: cmuFilePath) {
                if ZipherXFFI.treeLoadFromCMUs(data: downloadedData) {
                    let treeSize = ZipherXFFI.treeSize()
                    print("🌳 Loaded downloaded commitment tree (CMU format) with \(treeSize) commitments")
                } else {
                    print("❌ Failed to load downloaded tree from CMU format")
                    _ = ZipherXFFI.treeInit()
                }
            } else {
                _ = ZipherXFFI.treeInit()
                print("🌳 Initialized empty tree (no downloaded tree found)")
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
                    self.syncStatus = "Loading zk-SNARK proving circuits..."
                case "keys":
                    self.syncStatus = "Deriving keys from seed entropy..."
                case "database":
                    self.syncStatus = "Unlocking encrypted vault..."
                case "download_outputs":
                    self.syncStatus = "Downloading shielded outputs from GitHub..."
                case "download_timestamps":
                    self.syncStatus = "Downloading block timestamps from GitHub..."
                case "headers":
                    self.syncStatus = "Reaching consensus with 3 peers..."
                case "height":
                    self.syncStatus = "Querying decentralized chain tip..."
                case "scan":
                    self.syncStatus = "Trial-decrypting shielded outputs..."
                case "witnesses":
                    self.syncStatus = "Computing Merkle authentication paths..."
                case "balance":
                    self.syncStatus = "Tallying your sovereign wealth..."
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

    // MARK: - Public Task Update Methods (for FilterScanner)

    /// Update download task status - called from FilterScanner
    @MainActor
    func updateDownloadTask(_ taskId: String, status: SyncTaskStatus, detail: String? = nil) {
        updateTask(taskId, status: status, detail: detail)
    }

    /// Update download task progress - called from FilterScanner
    @MainActor
    func updateDownloadTaskProgress(_ taskId: String, detail: String, progress: Double) {
        // First set to in progress if not already
        if let index = syncTasks.firstIndex(where: { $0.id == taskId }) {
            if case .pending = syncTasks[index].status {
                syncTasks[index].status = .inProgress
            }
        }
        updateTaskWithProgress(taskId, detail: detail, progress: progress)
    }

    /// Get the real date for a given block height
    /// Uses BlockTimestampManager for actual blockchain timestamps (downloaded from GitHub)
    /// Falls back to estimate only if no real timestamp available
    private func estimateDateForBlock(height: UInt64) -> String {
        guard height > 0 else { return "" }

        // FIRST: Try to get real timestamp from BlockTimestampManager
        if let realDate = BlockTimestampManager.shared.getFormattedDate(at: height) {
            return realDate
        }

        // FALLBACK: Estimate only if real timestamp not available
        // This should be rare since we download timestamps from GitHub
        let referenceHeight: UInt64 = 2932265
        let referenceTimestamp: TimeInterval = 1764867600 // Dec 4, 2025 17:00 UTC
        let blockTimeInterval: TimeInterval = 150 // 2.5 minutes

        let heightDiff = Int64(height) - Int64(referenceHeight)
        let estimatedTimestamp = referenceTimestamp + (Double(heightDiff) * blockTimeInterval)
        let date = Date(timeIntervalSince1970: estimatedTimestamp)

        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy"
        return formatter.string(from: date)
    }

    /// Convert a date to estimated block height
    /// Uses reference point: block 2932265 = Dec 4, 2025 17:00 UTC
    /// Zclassic block time: 2.5 minutes (150 seconds)
    /// - Parameter date: The date to convert
    /// - Returns: Estimated block height (clamped to Sapling activation minimum and current chain height)
    static func blockHeightForDate(_ date: Date) -> UInt64 {
        let referenceHeight: UInt64 = 2932265
        let referenceTimestamp: TimeInterval = 1764867600 // Dec 4, 2025 17:00 UTC (correct 2025 timestamp)
        let blockTimeInterval: TimeInterval = 150 // 2.5 minutes

        let targetTimestamp = date.timeIntervalSince1970
        let timeDiff = targetTimestamp - referenceTimestamp
        let blockDiff = Int64(timeDiff / blockTimeInterval)

        let estimatedHeight = Int64(referenceHeight) + blockDiff

        // Clamp to Sapling activation as minimum and current chain height as maximum
        let saplingActivation: UInt64 = 476_969
        let maxHeight = referenceHeight // Can't scan future blocks
        let clampedHeight = UInt64(max(Int64(saplingActivation), min(estimatedHeight, Int64(maxHeight))))
        return clampedHeight
    }

    /// Sapling activation date: November 6, 2016
    static let saplingActivationDate: Date = {
        var components = DateComponents()
        components.year = 2016
        components.month = 11
        components.day = 6
        return Calendar.current.date(from: components) ?? Date.distantPast
    }()

    /// Get estimated scan duration based on start height
    /// - Parameter startHeight: Block height to start scanning from
    /// - Returns: Estimated duration string (e.g., "~55 minutes")
    static func estimatedScanDuration(from startHeight: UInt64) -> String {
        let effectiveTreeHeight = ZipherXConstants.effectiveTreeHeight
        let blocksToScan = effectiveTreeHeight > startHeight ? effectiveTreeHeight - startHeight : 0

        // Estimate: ~750 blocks/second for parallel scanning
        let estimatedSeconds = Double(blocksToScan) / 750.0
        let estimatedMinutes = Int(ceil(estimatedSeconds / 60.0))

        if estimatedMinutes < 1 {
            return "< 1 minute"
        } else if estimatedMinutes == 1 {
            return "~1 minute"
        } else if estimatedMinutes < 60 {
            return "~\(estimatedMinutes) minutes"
        } else {
            let hours = estimatedMinutes / 60
            let mins = estimatedMinutes % 60
            if mins == 0 {
                return "~\(hours) hour\(hours > 1 ? "s" : "")"
            } else {
                return "~\(hours)h \(mins)m"
            }
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

        // Record balance BEFORE send - used to detect change vs real incoming
        // Also set lastSendTimestamp EARLY so clearingTime calculation works
        // (setMempoolVerified() uses lastSendTimestamp to calculate clearing duration)
        await MainActor.run {
            self.balanceBeforeLastSend = currentBalance
            self.lastSendTimestamp = Date()
        }

        // SECURITY: Get spending key wrapped in SecureData for automatic memory cleanup
        // The key is zeroed as soon as the transaction is built (VUL-002 mitigation)
        let secureKey = try secureStorage.retrieveSpendingKeySecure()
        onProgress("prover", nil, nil)

        // Build shielded transaction with progress
        let txBuilder = TransactionBuilder()
        let (rawTx, spentNullifier) = try await txBuilder.buildShieldedTransactionWithProgress(
            from: zAddress,
            to: toAddress,
            amount: amount,
            memo: memo,
            spendingKey: secureKey.data,
            onProgress: onProgress
        )

        // SECURITY: Zero the spending key memory immediately after use
        secureKey.zero()

        onProgress("broadcast", "Preparing to broadcast...", 0.0)

        // Broadcast through multi-peer network with progress
        // Pass amount for instant UI feedback when first peer accepts
        let networkManager = NetworkManager.shared
        let txId = try await networkManager.broadcastTransactionWithProgress(rawTx, amount: amount) { phase, detail, progress in
            // Forward broadcast progress to the UI
            // Use actual phase ("peers", "verify", "api") so UI can show txid immediately on first peer accept
            onProgress(phase, detail, progress)
        }

        // Track as pending outgoing (cypherpunk mempool status)
        // Include fee (10000 zatoshis) so effectiveDisplayBalance is accurate
        // IMPORTANT: await to ensure mempoolOutgoing is set before UI updates
        let pendingFee: UInt64 = 10_000
        await networkManager.trackPendingOutgoing(txid: txId, amount: amount + pendingFee)

        // Show "Saving transaction..." while we record to database
        onProgress("broadcast", "Saving transaction (txid: \(txId.prefix(16))...)...", 0.95)

        // Note: lastSendTimestamp is set BEFORE broadcast starts (line 1627)
        // so that setMempoolVerified() can calculate accurate clearing time

        // CRITICAL: Record transaction IMMEDIATELY after broadcast success
        // This ensures the sent tx is in history even if subsequent operations fail
        guard let txidData = Data(hexString: txId) else {
            throw WalletError.transactionFailed("Invalid transaction ID format")
        }

        // Get chain height for recording (use cached if network fails)
        let chainHeight: UInt64
        do {
            chainHeight = try await networkManager.getChainHeight()
        } catch {
            // Fallback to cached chain height if network is unreliable
            chainHeight = networkManager.chainHeight > 0 ? networkManager.chainHeight : 0
            print("⚠️ Using cached chain height for tx recording: \(chainHeight)")
        }

        // Mark the spent note
        // NOTE: spentNullifier from WalletNote is already hashed (stored as SHA256 in database)
        try WalletDatabase.shared.markNoteSpentByHashedNullifier(hashedNullifier: spentNullifier, txid: txidData, spentHeight: chainHeight)
        print("✅ Note marked as spent in database")

        // CRITICAL: Record transaction in history - MUST succeed before showing success
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
        print("📜 Transaction recorded in history: \(txId.prefix(16))...")

        // VERIFY the transaction was actually saved using direct query (not filtered getTransactionHistory)
        let txWasSaved = try WalletDatabase.shared.transactionExists(txid: txidData, type: .sent)
        guard txWasSaved else {
            print("❌ CRITICAL: Transaction was NOT saved to database!")
            throw WalletError.transactionFailed("Failed to save transaction to database")
        }
        print("✅ Verified transaction exists in database")

        // Notify UI that transaction history changed
        await MainActor.run {
            self.transactionHistoryVersion += 1
        }

        // Send notification for successful transaction
        NotificationManager.shared.notifySent(amount: amount, txid: txId, memo: memo)

        // Signal completion with txid visible in progress message
        onProgress("broadcast", "Transaction complete!", 1.0)

        // Refresh balance in background (don't block success screen)
        Task {
            try? await refreshBalance()
        }

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

        // Record balance BEFORE send - used to detect change vs real incoming
        // Also set lastSendTimestamp EARLY so clearingTime calculation works
        await MainActor.run {
            self.balanceBeforeLastSend = currentBalance
            self.lastSendTimestamp = Date()
        }

        // SECURITY: Get spending key wrapped in SecureData for automatic memory cleanup
        // The key is zeroed as soon as the transaction is built (VUL-002 mitigation)
        let secureKey = try secureStorage.retrieveSpendingKeySecure()

        // Build shielded transaction
        let txBuilder = TransactionBuilder()
        let (rawTx, spentNullifier) = try await txBuilder.buildShieldedTransaction(
            from: zAddress,
            to: toAddress,
            amount: amount,
            memo: memo,
            spendingKey: secureKey.data
        )

        // SECURITY: Zero the spending key memory immediately after use
        secureKey.zero()

        // Broadcast through multi-peer network
        let networkManager = NetworkManager.shared
        let txId = try await networkManager.broadcastTransaction(rawTx)

        // Track as pending outgoing (cypherpunk mempool status)
        // Include fee (10000 zatoshis) so effectiveDisplayBalance is accurate
        // IMPORTANT: await to ensure mempoolOutgoing is set before UI updates
        let pendingFee: UInt64 = 10_000
        await networkManager.trackPendingOutgoing(txid: txId, amount: amount + pendingFee)

        // Note: lastSendTimestamp is set BEFORE broadcast starts (line 1759)
        // so that setMempoolVerified() can calculate accurate clearing time

        // CRITICAL: Record transaction IMMEDIATELY after broadcast success
        guard let txidData = Data(hexString: txId) else {
            throw WalletError.transactionFailed("Invalid transaction ID format")
        }

        // Get chain height for recording (use cached if network fails)
        let chainHeight: UInt64
        do {
            chainHeight = try await networkManager.getChainHeight()
        } catch {
            chainHeight = networkManager.chainHeight > 0 ? networkManager.chainHeight : 0
            print("⚠️ Using cached chain height for tx recording: \(chainHeight)")
        }

        // Mark the spent note
        // SECURITY: Never log nullifiers
        // NOTE: spentNullifier from WalletNote is already hashed (stored as SHA256 in database)
        try WalletDatabase.shared.markNoteSpentByHashedNullifier(hashedNullifier: spentNullifier, txid: txidData, spentHeight: chainHeight)
        print("✅ Note marked as spent in database at height \(chainHeight)")

        // CRITICAL: Record transaction in history - MUST succeed before showing success
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
        print("📜 Transaction recorded in history: \(txId.prefix(16))...")

        // VERIFY the transaction was actually saved using direct query (not filtered getTransactionHistory)
        let txWasSaved = try WalletDatabase.shared.transactionExists(txid: txidData, type: .sent)
        guard txWasSaved else {
            print("❌ CRITICAL: Transaction was NOT saved to database!")
            throw WalletError.transactionFailed("Failed to save transaction to database")
        }
        print("✅ Verified transaction exists in database")

        // Notify UI that transaction history changed
        await MainActor.run {
            self.transactionHistoryVersion += 1
        }

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
                // SECURITY: Log recovery action without exposing nullifier
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
        let storedWalletCreated = defaults.bool(forKey: "wallet_created")
        isImportedWallet = defaults.bool(forKey: "wallet_imported")
        zAddress = defaults.string(forKey: "z_address") ?? ""

        // CRITICAL: Verify that the Secure Enclave key actually exists
        // UserDefaults can persist across app reinstalls, but Keychain might not
        // If UserDefaults says wallet exists but key is missing, reset to show welcome screen
        if storedWalletCreated {
            if secureStorage.hasSpendingKey() {
                isWalletCreated = true
                print("✅ Wallet state loaded: key exists")
            } else {
                // Key is missing - reset wallet state to show welcome screen
                print("⚠️ UserDefaults has wallet_created=true but Secure Enclave key is missing")
                print("🔄 Resetting wallet state to show welcome screen...")
                isWalletCreated = false
                isImportedWallet = false
                zAddress = ""
                // Clear the stale UserDefaults
                defaults.removeObject(forKey: "wallet_created")
                defaults.removeObject(forKey: "wallet_imported")
                defaults.removeObject(forKey: "z_address")
                defaults.synchronize()
                return
            }
        } else {
            isWalletCreated = false
        }

        // Load balance from database on startup (async)
        if isWalletCreated {
            Task {
                await loadBalanceFromDatabase()
            }
        }
    }

    /// Load balance from database using last scanned height for confirmations
    /// This provides instant balance display on app restart
    private func loadBalanceFromDatabase() async {
        do {
            // Open database if needed
            let spendingKey = try secureStorage.retrieveSpendingKey()
            let dbKey = Data(SHA256.hash(data: spendingKey))
            try WalletDatabase.shared.open(encryptionKey: dbKey)

            // Get account
            guard let account = try WalletDatabase.shared.getAccount(index: 0) else {
                return
            }

            // Get last scanned height as chain height (best estimate before network)
            let lastScanned = try WalletDatabase.shared.getLastScannedHeight()
            guard lastScanned > 0 else { return }

            // Get notes and calculate balance
            let notes = try WalletDatabase.shared.getUnspentNotes(accountId: account.id)
            var confirmedBalance: UInt64 = 0
            var pendingBal: UInt64 = 0

            for note in notes {
                // Use lastScanned as chainHeight - notes are confirmed if they're in the DB
                let confirmations = lastScanned >= note.height ? Int(lastScanned - note.height + 1) : 0
                if confirmations >= 1 {
                    confirmedBalance += note.value
                } else {
                    pendingBal += note.value
                }
            }

            await MainActor.run {
                self.shieldedBalance = confirmedBalance
                self.pendingBalance = pendingBal
                print("💰 Loaded balance from database: \(confirmedBalance) zatoshis (\(pendingBal) pending)")
            }
        } catch {
            print("⚠️ Failed to load balance from database: \(error.localizedDescription)")
        }
    }

    private func saveWalletState() {
        let defaults = UserDefaults.standard
        defaults.set(isWalletCreated, forKey: "wallet_created")
        defaults.set(isImportedWallet, forKey: "wallet_imported")
        defaults.set(zAddress, forKey: "z_address")
    }

    /// Stop any ongoing sync operation
    /// Called when user clicks STOP button during initial sync
    func stopSync() {
        print("🛑 STOP SYNC: User requested sync cancellation")

        // Stop the current scanner if active
        currentScanner?.stopScan()
        currentScanner = nil

        // Reset sync state
        DispatchQueue.main.async {
            self.isSyncing = false
            self.isConnecting = false
            self.syncProgress = 0.0
            self.syncStatus = "Sync stopped by user"
            self.syncTasks = []
        }

        print("✅ STOP SYNC: Sync cancelled. Wallet may have incomplete data.")
    }

    /// Delete wallet and all associated data, then terminate the app
    /// CRITICAL: This permanently deletes everything!
    func deleteWallet() throws {
        print("🗑️ DELETE WALLET: Starting complete wallet deletion...")

        // 1. Wait for any ongoing scan to complete (with timeout)
        // FilterScanner doesn't have a shared instance, so we just wait for the flag
        if FilterScanner.isScanInProgress {
            print("🗑️ Waiting for scan to finish...")
            var waitCount = 0
            while FilterScanner.isScanInProgress && waitCount < 30 {
                Thread.sleep(forTimeInterval: 0.5)
                waitCount += 1
            }
        }
        print("🗑️ Scan check complete")

        // 2. Delete spending key from keychain
        do {
            try secureStorage.deleteSpendingKey()
            // VUL-014: Clear key creation date when deleting wallet
            secureStorage.clearKeyCreationDate()
            print("🗑️ Deleted spending key and creation date")
        } catch {
            print("⚠️ Failed to delete spending key: \(error) (continuing anyway)")
        }

        // 3. Delete wallet database (notes, transactions, tree state, accounts)
        do {
            try WalletDatabase.shared.deleteDatabase()
            print("🗑️ Deleted wallet database")
        } catch {
            print("⚠️ Failed to delete wallet database: \(error)")
        }

        // 4. Delete header store
        do {
            try HeaderStore.shared.deleteDatabase()
            print("🗑️ Deleted header store")
        } catch {
            print("⚠️ Failed to delete header store: \(error)")
        }

        // 5. Clear all UserDefaults
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "wallet_created")
        defaults.removeObject(forKey: "z_address")
        defaults.removeObject(forKey: "last_scanned_height")
        defaults.removeObject(forKey: "debugLoggingEnabled")
        defaults.removeObject(forKey: "useP2POnly")
        defaults.removeObject(forKey: "persisted_peer_addresses")
        defaults.synchronize()
        print("🗑️ Cleared UserDefaults")

        // 6. Clear in-memory state
        DispatchQueue.main.async {
            self.isWalletCreated = false
            self.zAddress = ""
            self.shieldedBalance = 0
            self.pendingBalance = 0
            self.isTreeLoaded = false
            self.transactionHistoryVersion = 0
            self.syncTasks = []
        }

        // 7. Reset FFI tree state (reinitialize to empty)
        _ = ZipherXFFI.treeInit()
        print("🗑️ Reset FFI tree state")

        // 8. Delete cache files (TreeCache, block_hashes, block_timestamps)
        let fileManager = FileManager.default

        // Delete TreeCache folder
        let treeCacheURL = AppDirectories.treeCache
        if fileManager.fileExists(atPath: treeCacheURL.path) {
            try? fileManager.removeItem(at: treeCacheURL)
            print("🗑️ Deleted TreeCache folder")
        }

        // Delete block_hashes.bin
        let blockHashesURL = AppDirectories.blockHashes
        if fileManager.fileExists(atPath: blockHashesURL.path) {
            try? fileManager.removeItem(at: blockHashesURL)
            print("🗑️ Deleted block_hashes.bin")
        }

        // Delete block_timestamps_cache.bin
        let timestampsURL = AppDirectories.blockTimestamps
        if fileManager.fileExists(atPath: timestampsURL.path) {
            try? fileManager.removeItem(at: timestampsURL)
            print("🗑️ Deleted block_timestamps_cache.bin")
        }

        // 9. Delete boost files (downloaded CMU/commitment tree data)
        CommitmentTreeUpdater.shared.deleteAllBoostFiles()

        #if os(macOS)
        // Delete macOS encrypted key file
        let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let zipherxFolder = appSupportURL.appendingPathComponent("ZipherX")
        let encKeyFile = zipherxFolder.appendingPathComponent("com_zipherx_spendingkey.enc")
        if fileManager.fileExists(atPath: encKeyFile.path) {
            try? fileManager.removeItem(at: encKeyFile)
            print("🗑️ Deleted macOS encrypted key file")
        }
        #endif

        print("✅ DELETE WALLET: Complete! App should be restarted.")

        // 9. Force quit the app after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            print("🛑 Terminating app...")
            #if os(iOS)
            // On iOS, we can't force quit, but we show a message
            // The user needs to restart manually
            #else
            // On macOS, terminate the app
            NSApplication.shared.terminate(nil)
            #endif
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
        // Record creation time for accurate sync timing display
        DispatchQueue.main.async {
            self.walletCreationTime = Date()
            print("⏱️ Wallet import started at: \(self.walletCreationTime!)")
        }

        // Clean the input - remove whitespace and newlines
        let cleanKey = keyString.trimmingCharacters(in: .whitespacesAndNewlines)

        print("🔑 Importing key, length: \(cleanKey.count) chars")

        var spendingKey: Data

        // Check if it's Bech32 format (secret-extended-key-main1...)
        if cleanKey.hasPrefix("secret-extended-key-main") {
            print("🔑 Detected Bech32 format, decoding...")
            guard let keyData = ZipherXFFI.decodeSpendingKey(cleanKey) else {
                print("❌ Failed to decode Bech32 spending key")
                throw WalletError.invalidAddress("Failed to decode Bech32 key. Please check it's a valid secret-extended-key-main1... format.")
            }
            spendingKey = keyData
            print("✓ Bech32 key decoded, \(keyData.count) bytes")
        }
        // Legacy hex format (338 chars)
        else if cleanKey.count == 338 {
            print("🔑 Detected hex format, parsing...")
            guard let keyData = Data(hexString: cleanKey) else {
                print("❌ Failed to parse hex string")
                throw WalletError.invalidAddress("Failed to parse hex key. Please ensure it contains only valid hex characters (0-9, a-f).")
            }
            spendingKey = keyData
            print("✓ Hex key parsed, \(keyData.count) bytes")
        }
        else {
            print("❌ Invalid key format: got \(cleanKey.count) chars, expected Bech32 (secret-extended-key-main1...) or hex (338 chars)")
            throw WalletError.invalidAddress("Invalid key format. Expected: Bech32 key (secret-extended-key-main1...) or 338-character hex key. Got \(cleanKey.count) characters.")
        }

        // Verify key size
        guard spendingKey.count == 169 else {
            print("❌ Invalid spending key size: \(spendingKey.count) bytes, expected 169")
            throw WalletError.invalidAddress("Invalid key size: \(spendingKey.count) bytes, expected 169 bytes.")
        }

        // Store in secure storage
        print("🔑 Storing key in secure storage...")
        do {
            try secureStorage.storeSpendingKey(spendingKey)
            // VUL-014: Record key creation date for rotation policy
            secureStorage.recordKeyCreationDate()
            print("✓ Key stored successfully")
        } catch {
            print("❌ Failed to store key: \(error.localizedDescription)")
            throw WalletError.secureEnclaveError("Failed to store key: \(error.localizedDescription)")
        }

        // Derive z-address
        print("🔑 Deriving z-address...")
        let address: String
        do {
            address = try deriveZAddress(from: spendingKey)
            print("✓ Address derived: \(address.prefix(20))...")
        } catch {
            print("❌ Failed to derive address: \(error.localizedDescription)")
            // Clean up stored key since we couldn't complete the import
            try? secureStorage.deleteSpendingKey()
            throw WalletError.invalidAddress("Failed to derive z-address from key: \(error.localizedDescription)")
        }

        // CRITICAL: Delete and recreate database for imported wallet
        // This ensures NO old data persists (old lastScannedHeight, notes, etc.)
        print("🗑️ Deleting old database for imported wallet...")

        do {
            try WalletDatabase.shared.deleteDatabase()
            print("✅ Old database deleted")
        } catch {
            print("⚠️ Failed to delete database: \(error)")
        }

        // Open fresh database with new key
        let dbKey = Data(SHA256.hash(data: spendingKey))
        do {
            try WalletDatabase.shared.open(encryptionKey: dbKey)
            print("✅ Fresh database created with new key")
        } catch {
            print("⚠️ Failed to open database: \(error)")
        }

        // Reset tree state in FFI memory as well
        isTreeLoaded = false
        treeLoadProgress = 0.0
        treeLoadStatus = ""

        // Update state - mark as imported wallet (may have historical notes)
        DispatchQueue.main.async {
            self.zAddress = address
            self.isWalletCreated = true
            self.isImportedWallet = true  // Important: triggers historical note scanning
            self.saveWalletState()
        }

        print("✅ Key imported successfully (will scan for historical notes)")
    }

    // MARK: - Post-Scan Nullifier Verification

    /// Verify nullifier spend status for all unspent notes
    /// This is a fallback check that queries the blockchain for each note's nullifier
    /// Called after scan to catch any spent notes that were missed during normal scan
    func verifyNullifierSpendStatus() async throws {
        print("🔍 Starting post-scan nullifier verification...")

        let database = WalletDatabase.shared
        let unspentNotes = try database.getAllUnspentNotes(accountId: 1)

        guard !unspentNotes.isEmpty else {
            print("✅ No unspent notes to verify")
            return
        }

        print("🔍 Checking \(unspentNotes.count) unspent note(s) for spend status...")

        var spentCount = 0

        for note in unspentNotes {
            // Convert nullifier to hex for API lookup
            // Notes store nullifier in wire format (little-endian)
            // API expects display format (big-endian)
            let nullifierDisplay = note.nullifier.reversedBytes().hexString

            // Search for this nullifier in spending transactions
            // We need to check transactions that contain this nullifier in vShieldedSpend
            let isSpent = try await checkNullifierSpentOnChain(nullifier: nullifierDisplay, afterHeight: note.height)

            if isSpent {
                print("💸 Found spent note: \(note.value) zatoshis (nullifier found on chain)")
                // NOTE: note.nullifier from WalletNote is already hashed (stored as SHA256 in database)
                try database.markNoteSpentByHashedNullifier(hashedNullifier: note.nullifier, spentHeight: 0) // Height unknown
                spentCount += 1
            }
        }

        if spentCount > 0 {
            print("✅ Marked \(spentCount) note(s) as spent via nullifier verification")
        } else {
            print("✅ All unspent notes verified - none are spent on chain")
        }
    }

    /// Check if a nullifier has been spent on the blockchain
    /// Scans transactions from the note's height to current tip
    private func checkNullifierSpentOnChain(nullifier: String, afterHeight: UInt64) async throws -> Bool {
        // Strategy: Check blocks from note height to current tip for spending transactions
        // This is expensive, so we batch and parallelize

        let api = InsightAPI.shared
        let status = try await api.getStatus()
        let currentHeight = status.height

        // Don't scan more than 5000 blocks (arbitrary limit for performance)
        let maxScanBlocks: UInt64 = 5000
        let startHeight = afterHeight
        let endHeight = min(currentHeight, afterHeight + maxScanBlocks)

        // Batch size for parallel processing
        let batchSize: UInt64 = 100

        for batchStart in stride(from: startHeight, to: endHeight, by: Int(batchSize)) {
            let batchEnd = min(batchStart + batchSize, endHeight)

            // Check each block in this batch
            for height in batchStart..<batchEnd {
                do {
                    let blockHash = try await api.getBlockHash(height: height)
                    let block = try await api.getBlock(hash: blockHash)

                    // Check each transaction in the block
                    for txid in block.tx {
                        let tx = try await api.getTransaction(txid: txid)

                        // Check if any spend matches our nullifier
                        if let spends = tx.spendDescs {
                            for spend in spends {
                                if spend.nullifier == nullifier {
                                    return true // Found! This note was spent
                                }
                            }
                        }
                    }
                } catch {
                    // Skip blocks that fail to fetch
                    continue
                }
            }
        }

        return false
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
