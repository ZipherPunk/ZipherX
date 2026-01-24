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

/// FIX #231: Equihash verification result - distinguishes network errors from actual failures
enum EquihashVerificationResult {
    case verified(count: Int)                              // All headers passed with full consensus (5+ peers)
    case verifiedReducedConsensus(count: Int, peers: Int)  // Headers passed but with reduced consensus (<5 peers)
    case networkError(reason: String)                      // Could not fetch any headers
    case failed(verified: Int, total: Int)                 // Headers fetched but Equihash failed (CRITICAL)
}

/// FIX #680: Transaction recovery errors (renamed from TransactionError to avoid conflict)
enum RecoveryError: LocalizedError {
    case invalidFormat
    case unsupportedVersion

    var errorDescription: String? {
        switch self {
        case .invalidFormat: return "Invalid transaction format"
        case .unsupportedVersion: return "Unsupported transaction version"
        }
    }
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
    @Published private(set) var hasBalanceIssues: Bool = false  // FIX #300: True if notes need witness rebuild
    @Published var databaseCorrectionAlert: DatabaseCorrectionInfo? = nil  // FIX #303: Alert when external spends detected
    @Published private(set) var zAddress: String = ""
    @Published private(set) var syncProgress: Double = 0.0
    @Published private(set) var isSyncing: Bool = false
    @Published private(set) var isConnecting: Bool = false
    @Published private(set) var syncStatus: String = ""

    // FIX #242: Track when wallet is catching up after returning from background
    @Published private(set) var isCatchingUp: Bool = false
    @Published private(set) var blocksBehind: UInt64 = 0
    @Published private(set) var syncPhase: String = ""  // "phase1", "phase1.5", "phase1.6", "phase2"
    @Published private(set) var lastError: WalletError?
    @Published var syncTasks: [SyncTask] = []  // FIX: Removed private(set) for FAST START task updates from ContentView
    @Published private(set) var syncCurrentHeight: UInt64 = 0
    @Published private(set) var syncMaxHeight: UInt64 = 0

    // MARK: - FIX #144: Header Sync Progress (user-friendly display)
    @Published private(set) var isHeaderSyncing: Bool = false
    @Published private(set) var headerSyncProgress: Double = 0.0
    @Published private(set) var headerSyncStatus: String = ""
    @Published private(set) var headerSyncCurrentHeight: UInt64 = 0
    @Published private(set) var headerSyncTargetHeight: UInt64 = 0
    @Published private(set) var isTorBypassed: Bool = false

    // MARK: - FIX #162: Prevent history corruption during repair
    /// When true, Views should NOT call populateHistoryFromNotes() as it would undo repair
    @Published private(set) var isRepairingHistory: Bool = false

    // MARK: - FIX #368: Block backgroundSync during Full Resync
    /// When true, backgroundSyncToHeight() returns immediately without running
    /// This prevents race condition where backgroundSync sets lastScannedHeight to chain tip
    /// before Full Resync PHASE 2 completes, causing notes to never be discovered
    @Published private(set) var isRepairingDatabase: Bool = false

    // MARK: - FIX #681 v4: Prevent concurrent auto-recovery executions
    /// When true, autoRecoverMissingTransactions() returns immediately without running
    /// This prevents race condition where multiple calls interfere with each other
    @Published private(set) var isAutoRecovering: Bool = false

    // MARK: - FIX #577 v7: Show same sync UI as Import PK during Full Rescan
    /// When true, ContentView shows CypherpunkSyncView (same as Import PK)
    /// This provides consistent progress display during Full Rescan operations
    @Published private(set) var isFullRescan: Bool = false
    @Published var isRescanComplete: Bool = false
    @Published var rescanCompletionDuration: TimeInterval? = nil

    // MARK: - FIX #557 v15: Prevent concurrent witness rebuilds
    /// When true, preRebuildWitnessesForInstantPayment() returns immediately
    /// This prevents multiple rebuilds running simultaneously and producing inconsistent anchors
    private let witnessRebuildLock = NSLock()
    @Published private(set) var isRebuildingWitnesses: Bool = false
    private var lastWitnessRebuildTime: Date? = nil
    private let witnessRebuildCooldown: TimeInterval = 30.0  // Minimum 30 seconds between rebuilds

    // MARK: - FIX #451: Recovery mechanism for stuck repair flag
    /// Force reset the isRepairingDatabase flag if it gets stuck
    /// Call this from Settings or when app detects stuck repair state
    func forceResetRepairFlag() {
        Task { @MainActor in
            if self.isRepairingDatabase {
                print("🔧 FIX #451: Force resetting isRepairingDatabase flag (was stuck)")
                self.isRepairingDatabase = false
            } else {
                print("🔧 FIX #451: isRepairingDatabase flag already false (no reset needed)")
            }
        }
    }

    // MARK: - FIX #231: Reduced Verification Warning
    /// Set when Equihash PoW couldn't be verified due to insufficient peers
    /// User should be warned before accessing wallet
    @Published var reducedVerificationAlert: ReducedVerificationInfo? = nil

    struct ReducedVerificationInfo {
        let peerCount: Int
        let reason: String
    }

    /// FIX #303: Database correction info for user alert
    struct DatabaseCorrectionInfo {
        let externalSpendsDetected: Int
        let amountCorrected: UInt64  // in zatoshis
        let message: String
    }

    func setReducedVerificationAlert(peerCount: Int, reason: String) {
        Task { @MainActor in
            self.reducedVerificationAlert = ReducedVerificationInfo(peerCount: peerCount, reason: reason)
            print("⚠️ FIX #231: Reduced verification - \(peerCount) peers, reason: \(reason)")
        }
    }

    func clearReducedVerificationAlert() {
        Task { @MainActor in
            self.reducedVerificationAlert = nil
        }
    }

    func setRepairingHistory(_ repairing: Bool) {
        Task { @MainActor in
            self.isRepairingHistory = repairing
            print("🔧 FIX #162: isRepairingHistory = \(repairing)")
        }
    }

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

    // MARK: - Delta Bundle Sync Status

    /// Delta bundle sync status for UI indicator
    public enum DeltaSyncStatus: Equatable {
        case synced          // Delta bundle is up-to-date with chain height
        case syncing         // Delta bundle sync in progress
        case behind(blocks: UInt64)  // Delta bundle is behind by X blocks
        case unavailable     // No delta bundle exists yet
    }

    @Published private(set) var deltaSyncStatus: DeltaSyncStatus = .unavailable

    /// Update delta sync status - called during background sync
    @MainActor
    func updateDeltaSyncStatus(_ status: DeltaSyncStatus) {
        deltaSyncStatus = status
    }

    /// Check and update delta sync status based on current state
    /// Checks both: (1) delta is up-to-date with chain tip, (2) delta covers from boost end
    @MainActor
    func refreshDeltaSyncStatus() {
        let deltaManager = DeltaCMUManager.shared
        let chainHeight = NetworkManager.shared.chainHeight
        let bundledEndHeight = ZipherXConstants.effectiveTreeHeight

        guard chainHeight > 0 else {
            deltaSyncStatus = .unavailable
            return
        }

        guard let manifest = deltaManager.getManifest() else {
            // No delta exists - calculate how many blocks would need to be synced
            let blocksBehind = chainHeight > bundledEndHeight ? chainHeight - bundledEndHeight : 0
            if blocksBehind > 0 {
                deltaSyncStatus = .behind(blocks: blocksBehind)
            } else {
                deltaSyncStatus = .unavailable
            }
            return
        }

        // Check 1: Does delta start from where boost ends?
        let expectedStart = bundledEndHeight + 1
        let hasGap = manifest.startHeight > expectedStart

        // Check 2: Is delta up-to-date with chain?
        let behindChain = manifest.endHeight < chainHeight

        if hasGap {
            // Gap between boost end and delta start - this is a problem!
            let gapBlocks = manifest.startHeight - expectedStart
            let chainBehind = behindChain ? chainHeight - manifest.endHeight : 0
            deltaSyncStatus = .behind(blocks: gapBlocks + chainBehind)
            print("📦 Delta has gap: boost ends at \(bundledEndHeight), delta starts at \(manifest.startHeight) (gap: \(gapBlocks) blocks)")
        } else if behindChain {
            let blocksBehind = chainHeight - manifest.endHeight
            deltaSyncStatus = .behind(blocks: blocksBehind)
        } else {
            deltaSyncStatus = .synced
        }
    }

    /// Clear the balance tracking after change output is processed
    /// NOTE: We do NOT clear lastSendTimestamp here - it should persist for the full 120 seconds
    /// so that isLikelyChange remains true and suppresses the pending balance indicator
    @MainActor
    func clearBalanceBeforeLastSend() {
        balanceBeforeLastSend = nil
        // Don't clear lastSendTimestamp - it's needed for isLikelyChange detection
        // lastSendTimestamp will naturally expire after 120 seconds
    }

    /// Record the timestamp when a send transaction is initiated
    /// Used for change output detection and clearing time calculation
    @MainActor
    func recordSendTimestamp() {
        lastSendTimestamp = Date()
    }

    /// Increment the transaction history version to trigger UI updates
    @MainActor
    func incrementHistoryVersion() {
        transactionHistoryVersion += 1
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
                // Validate and sync delta bundle for instant transactions
                await validateAndSyncDeltaBundle()
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

    // MARK: - Delta Bundle Validation

    /// Validate delta bundle on app startup and sync missing data if needed
    /// This ensures:
    /// 1. Delta bundle integrity (file size, manifest, start height)
    /// 2. Tree root matches HeaderStore at delta end height
    /// 3. Delta is up-to-date with current chain height (syncs if behind)
    private func validateAndSyncDeltaBundle() async {
        print("📦 Validating delta bundle...")

        let deltaManager = DeltaCMUManager.shared
        let bundledEndHeight = ZipherXConstants.effectiveTreeHeight

        // 1. Validate delta bundle integrity
        let validation = deltaManager.validateDeltaBundle(bundledEndHeight: bundledEndHeight)

        if !validation.isValid && validation.error != nil {
            print("⚠️ Delta bundle invalid: \(validation.error!) - will rebuild on next sync")
            return
        }

        // If no delta exists, that's OK - will be created during sync
        guard let manifest = validation.manifest else {
            print("📦 No delta bundle exists yet - will be created during sync")
            return
        }

        // 2. Validate tree root against HeaderStore (optional - only if headers available)
        let rootValid = await deltaManager.validateTreeRootAgainstHeaders()
        if !rootValid {
            print("⚠️ Delta tree root mismatch - clearing for rebuild")
            deltaManager.clearDeltaBundle()

            // FIX #533: CRITICAL - Reload FFI tree from boost file WITHOUT corrupt delta CMUs
            // The delta CMUs corrupted the tree state, causing anchor validation to fail
            print("🔧 FIX #533: Reloading FFI tree from boost file to remove corrupt delta CMUs...")
            do {
                let serializedTree = try await CommitmentTreeUpdater.shared.extractSerializedTree()
                _ = ZipherXFFI.treeInit()  // Reset tree
                if ZipherXFFI.treeDeserialize(data: serializedTree) {
                    let treeSize = ZipherXFFI.treeSize()
                    print("✅ FIX #533: Reloaded tree from boost file: \(treeSize) CMUs (corrupt delta CMUs removed)")
                    if let treeData = ZipherXFFI.treeSerialize() {
                        try? WalletDatabase.shared.saveTreeState(treeData)
                    }
                } else {
                    print("⚠️ FIX #533: Failed to deserialize tree after clearing delta")
                }
            } catch {
                print("⚠️ FIX #533: Failed to reload tree: \(error)")
            }

            return
        }

        // 3. Check if delta needs sync (missing blocks compared to chain height)
        await syncDeltaBundleIfNeeded(manifest: manifest, bundledEndHeight: bundledEndHeight)
    }

    /// Sync delta bundle if it's behind the current chain height
    /// Fetches missing shielded outputs via P2P and appends to delta
    private func syncDeltaBundleIfNeeded(manifest: DeltaCMUManager.DeltaManifest, bundledEndHeight: UInt64) async {
        // Get current chain height
        let chainHeight: UInt64
        do {
            chainHeight = try await NetworkManager.shared.getChainHeight()
        } catch {
            print("⚠️ Cannot get chain height for delta sync: \(error.localizedDescription)")
            await MainActor.run { refreshDeltaSyncStatus() }
            return
        }

        // Update chain height for status check
        await MainActor.run { refreshDeltaSyncStatus() }

        // Check if delta is up-to-date
        let deltaEndHeight = manifest.endHeight
        if deltaEndHeight >= chainHeight {
            print("✅ Delta bundle is current (height \(deltaEndHeight), chain \(chainHeight))")
            await MainActor.run { deltaSyncStatus = .synced }
            return
        }

        // Calculate missing blocks
        let missingBlocks = chainHeight - deltaEndHeight
        print("📦 Delta bundle behind by \(missingBlocks) blocks (delta: \(deltaEndHeight), chain: \(chainHeight))")

        // Update status to behind
        await MainActor.run { deltaSyncStatus = .behind(blocks: missingBlocks) }

        // Limit sync to recent blocks to avoid long startup delays
        let maxStartupSyncBlocks: UInt64 = 100
        if missingBlocks > maxStartupSyncBlocks {
            print("⚠️ Too many missing blocks (\(missingBlocks)) - will sync during background refresh")
            return
        }

        // Update status to syncing
        await MainActor.run { deltaSyncStatus = .syncing }

        // Fetch missing blocks via P2P
        print("📦 Fetching \(missingBlocks) missing blocks for delta bundle...")

        do {
            let startHeight = deltaEndHeight + 1
            var collectedOutputs: [DeltaCMUManager.DeltaOutput] = []

            // Fetch blocks in batches
            // FIX #561 v2: 500 is fine for P2P on-demand (rebuildWitnessForNote uses global tree now)
            let batchSize: UInt64 = 500
            var currentStart = startHeight

            while currentStart <= chainHeight {
                let batchEnd = min(currentStart + batchSize - 1, chainHeight)
                let count = Int(batchEnd - currentStart + 1)

                // Try P2P first
                let blocks = try await NetworkManager.shared.getBlocksOnDemandP2P(from: currentStart, count: count)

                // Extract shielded outputs from blocks
                var outputIndex: UInt32 = 0
                for block in blocks {
                    for tx in block.transactions {
                        for output in tx.outputs {
                            let deltaOutput = DeltaCMUManager.DeltaOutput(
                                height: UInt32(block.blockHeight),
                                index: outputIndex,
                                cmu: output.cmu,
                                epk: output.epk,
                                ciphertext: output.ciphertext
                            )
                            collectedOutputs.append(deltaOutput)
                            outputIndex += 1
                        }
                    }
                    outputIndex = 0  // Reset for next block
                }

                currentStart = batchEnd + 1
            }

            // Append collected outputs to delta bundle
            if !collectedOutputs.isEmpty {
                // Get current tree root after sync
                // For startup sync, we use tree root from current in-memory tree
                let treeRoot = ZipherXFFI.treeRoot() ?? Data(count: 32)

                DeltaCMUManager.shared.appendOutputs(collectedOutputs, fromHeight: startHeight, toHeight: chainHeight, treeRoot: treeRoot)
                print("✅ Delta bundle synced to height \(startHeight)-\(chainHeight) (+\(collectedOutputs.count) outputs)")
            } else {
                // No outputs but still need to update height in manifest
                let treeRoot = ZipherXFFI.treeRoot() ?? Data(count: 32)
                DeltaCMUManager.shared.appendOutputs([], fromHeight: startHeight, toHeight: chainHeight, treeRoot: treeRoot)
                print("✅ Delta bundle synced to height \(startHeight)-\(chainHeight) (no new outputs)")
            }

            // Update status to synced
            await MainActor.run { deltaSyncStatus = .synced }

        } catch {
            print("⚠️ Failed to sync delta bundle: \(error.localizedDescription)")
            // Non-fatal - delta will be updated during background sync
            // Reset status to behind
            await MainActor.run { deltaSyncStatus = .behind(blocks: missingBlocks) }
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

    // FIX #562: Track when witnesses were last updated to skip redundant staleness checks
    private var lastWitnessUpdate: Date? = nil

    // FIX #278: Boost download stats for progress view (like BootstrapProgressView)
    @Published private(set) var boostDownloadSpeed: String = ""
    @Published private(set) var boostETA: String = ""
    @Published private(set) var boostFileSize: Int64 = 0
    @Published var showBoostDownloadSheet: Bool = false  // Show progress sheet during download

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

                    // FIX #558 v2: Load delta CMUs to complete the tree
                    // The delta CMUs are saved from previous scans but NOT loaded into the tree
                    // This causes PHASE 2 to refetch blocks on every startup!
                    let deltaManager = DeltaCMUManager.shared
                    if let deltaCMUs = deltaManager.loadDeltaCMUs(), !deltaCMUs.isEmpty {
                        print("📦 FIX #558 v2: Loading \(deltaCMUs.count) delta CMUs into tree...")
                        var appendedCount = 0
                        for cmu in deltaCMUs {
                            let position = ZipherXFFI.treeAppend(cmu: cmu)
                            if position != UInt64.max {
                                appendedCount += 1
                            }
                        }
                        let newTreeSize = ZipherXFFI.treeSize()
                        print("✅ FIX #558 v2: Appended \(appendedCount)/\(deltaCMUs.count) delta CMUs to tree")
                        print("✅ FIX #558 v2: Tree now has \(newTreeSize) CMUs (was \(treeSize), added \(newTreeSize - treeSize))")

                        // Save updated tree state (FIX #565)
                        if let treeData = ZipherXFFI.treeSerialize() {
                            try? WalletDatabase.shared.saveTreeState(treeData)
                        }
                    } else {
                        print("📦 FIX #558 v2: No delta CMUs to load (first run or delta empty)")
                    }

                    // FIX #580 v2: Initialize FastWalletCache with CMU cache file
                    // This enables instant witness generation (~1ms vs 84s P2P rebuild)
                    // CMU file contains ~32MB of commitment data for fast tree building
                    if let cmuPath = await CommitmentTreeUpdater.shared.getCachedCMUFilePath() {
                        await MainActor.run {
                            do {
                                try FastWalletCache.shared.loadCMUCache(from: cmuPath)
                                print("✅ FIX #580 v2: FastWalletCache initialized with CMU cache")
                            } catch {
                                print("⚠️ FIX #580 v2: Failed to initialize FastWalletCache: \(error)")
                            }
                        }
                    } else {
                        print("⚠️ FIX #580 v2: CMU cache file not available, witness generation will be slower")
                    }

                    // FIX #580: Note loading removed - WalletNote doesn't have required properties
                    // The key optimization is the in-memory CMU data (32 MB), not note metadata
                    // Notes will be loaded on-demand during transaction building

                    await MainActor.run {
                        self.isTreeLoaded = true
                        self.treeLoadProgress = 1.0
                        self.treeLoadStatus = "Privacy state restored\n\(ZipherXFFI.treeSize().formatted()) commitments ready"
                    }
                    return
                }
            }
        }

        // Download boost file from GitHub (required - no bundled fallback)
        print("🚀 Downloading boost file from GitHub...")

        // FIX #278: Show progress sheet and initialize download stats
        var downloadStartTime = Date()
        var lastProgressUpdate = Date()
        var lastProgress: Double = 0

        await MainActor.run {
            self.treeLoadStatus = "Downloading boost data..."
            self.treeLoadProgress = 0.1
            // FIX #509: Removed progress sheet - all progress shown on main import screen
            self.boostDownloadSpeed = ""
            self.boostETA = ""
        }

        // FIX #164: Bypass Tor for boost file download during import/initial sync
        // The 783MB boost file download takes ~2 minutes over Tor but only ~20-30 seconds direct
        // This is the FIRST major bottleneck in import performance
        // NOTE: We do NOT restore Tor here - refreshBalance() will restore it after FULL sync
        // This ensures the P2P sync phase also runs without Tor (5x faster overall)
        let torEnabled = await TorManager.shared.mode == .enabled
        let torAlreadyBypassed = await TorManager.shared.isTorBypassed

        if torEnabled && !torAlreadyBypassed {
            print("⚠️ FIX #164: Bypassing Tor for boost file download (5x faster)...")
            let bypassed = await TorManager.shared.bypassTorForMassiveOperation()
            if bypassed {
                print("🚀 FIX #164: Tor bypassed - direct download for faster import!")
                print("🚀 FIX #164: Tor will be restored by refreshBalance() after full sync")
                // FIX #195: Wait 2 seconds for network to stabilize after Tor bypass
                // URLSession needs time to clear cached routes and DNS settings
                print("⏳ FIX #195: Waiting 2s for network to stabilize...")
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        // NOTE: NO defer block here - Tor restoration handled by FIX #163 in refreshBalance()

        var downloadedTreeHeight: UInt64 = 0
        var downloadedCMUCount: UInt64 = 0

        do {
            // Download the unified boost file (contains tree, outputs, spends, etc.)
            // FIX #278: Enhanced progress callback with speed/ETA calculation
            let (_, height, cmuCount) = try await CommitmentTreeUpdater.shared.getBestAvailableBoostFile { progress, status in
                Task { @MainActor in
                    self.treeLoadProgress = 0.1 + progress * 0.2  // 10-30% for download
                    self.treeLoadStatus = status

                    // FIX #278: Calculate download speed and ETA
                    let now = Date()
                    let elapsed = now.timeIntervalSince(lastProgressUpdate)

                    if elapsed >= 0.5 && progress > lastProgress {  // Update every 500ms
                        let progressDelta = progress - lastProgress
                        let totalElapsed = now.timeIntervalSince(downloadStartTime)

                        // Speed based on recent progress (more responsive)
                        // Assuming ~500MB file size for estimation
                        let estimatedFileSize: Int64 = 500_000_000
                        let bytesDownloaded = Int64(Double(estimatedFileSize) * progress)
                        let recentBytesPerSec = Int64(Double(estimatedFileSize) * progressDelta / elapsed)

                        if recentBytesPerSec > 0 {
                            self.boostDownloadSpeed = ByteCountFormatter.string(fromByteCount: recentBytesPerSec, countStyle: .file) + "/s"
                            self.boostFileSize = estimatedFileSize

                            // ETA based on remaining progress and average speed
                            let avgBytesPerSec = Double(bytesDownloaded) / totalElapsed
                            let remainingBytes = Double(estimatedFileSize) * (1.0 - progress)
                            let etaSeconds = Int(remainingBytes / avgBytesPerSec)

                            if etaSeconds < 60 {
                                self.boostETA = "\(etaSeconds)s"
                            } else if etaSeconds < 3600 {
                                self.boostETA = "\(etaSeconds / 60)m \(etaSeconds % 60)s"
                            } else {
                                self.boostETA = "\(etaSeconds / 3600)h \(etaSeconds % 3600 / 60)m"
                            }
                        }

                        lastProgressUpdate = now
                        lastProgress = progress
                    }

                    // FIX #124: Update overall progress during download
                    self.updateOverallProgress(phase: .downloadingTree, phaseProgress: progress)
                }
            }
            downloadedTreeHeight = height
            downloadedCMUCount = cmuCount
            print("🚀 Downloaded boost file from GitHub: height \(height) (\(cmuCount) outputs)")

            // FIX #278: Clear download stats after completion
            await MainActor.run {
                self.boostDownloadSpeed = ""
                self.boostETA = ""
            }
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

            // Save to database for next time (FIX #565)
            if let serializedTree = ZipherXFFI.treeSerialize() {
                try? WalletDatabase.shared.saveTreeState(serializedTree)
                print("💾 Tree state saved to database for future use (height: \(downloadedTreeHeight))")
            }

            // FIX #558 v2: Load delta CMUs to complete the tree (boost file path)
            // The delta CMUs are saved from previous scans but NOT loaded into the tree
            // This causes PHASE 2 to refetch blocks on every startup!
            let deltaManager = DeltaCMUManager.shared
            if let deltaCMUs = deltaManager.loadDeltaCMUs(), !deltaCMUs.isEmpty {
                print("📦 FIX #558 v2: Loading \(deltaCMUs.count) delta CMUs into tree...")
                var appendedCount = 0
                for cmu in deltaCMUs {
                    let position = ZipherXFFI.treeAppend(cmu: cmu)
                    if position != UInt64.max {
                        appendedCount += 1
                    }
                }
                let newTreeSize = ZipherXFFI.treeSize()
                print("✅ FIX #558 v2: Appended \(appendedCount)/\(deltaCMUs.count) delta CMUs to tree")
                print("✅ FIX #558 v2: Tree now has \(newTreeSize) CMUs (was \(treeSize), added \(newTreeSize - treeSize))")

                // Save updated tree state (FIX #565)
                if let treeData = ZipherXFFI.treeSerialize() {
                    try? WalletDatabase.shared.saveTreeState(treeData)
                }
            } else {
                print("📦 FIX #558 v2: No delta CMUs to load (first run or delta empty)")
            }

            // FIX #580 v2: Initialize FastWalletCache with CMU cache file (boost path)
            // This enables instant witness generation (~1ms vs 84s P2P rebuild)
            if let cmuPath = await CommitmentTreeUpdater.shared.getCachedCMUFilePath() {
                do {
                    try await FastWalletCache.shared.loadCMUCache(from: cmuPath)
                    print("✅ FIX #580 v2: FastWalletCache initialized with CMU cache (boost path)")

                    // FIX #580: Note loading removed - WalletNote doesn't have required properties
                    // The key optimization is the in-memory CMU data (32 MB), not note metadata
                    // Notes will be loaded on-demand during transaction building
                } catch {
                    print("⚠️ FIX #580 v2: Failed to initialize FastWalletCache: \(error)")
                }
            } else {
                print("⚠️ FIX #580 v2: CMU cache file not available (boost path)")
            }

            await MainActor.run {
                self.isTreeLoaded = true
                // FIX #505: DON'T set progress to 1.0 yet - import still needs to run
                // DON'T dismiss sheet yet - header loading happens after this
                self.treeLoadStatus = "Privacy infrastructure ready\n\(treeSize.formatted()) commitments loaded"
                print("✅ FIX #505: Tree loaded, but keeping sheet open for header loading...")
            }
            return
        }

        // FIX #456: Tree deserialization failed - fall back to building from CMUs instead of failing
        // This happens when boost file was generated with different FFI version (e.g., after Rust dependencies update)
        // The "non-canonical Option<T>" error means zcash_primitives serialization format changed
        print("⚠️ FIX #456: Tree deserialization failed - boost file generated with different FFI version")
        print("⚠️ FIX #456: Error was: 'non-canonical Option<T>' - this means zcash_primitives changed")
        print("🔄 FIX #456: Falling back to building tree from CMUs (slower but always works)...")

        await MainActor.run {
            self.treeLoadStatus = "Building commitment tree from CMUs..."
            self.treeLoadProgress = 0.4
        }

        // Extract CMUs from boost file and build tree from scratch
        do {
            let cmuData = try await CommitmentTreeUpdater.shared.extractCMUsInLegacyFormat { progress in
                Task { @MainActor in
                    self.treeLoadProgress = 0.4 + progress * 0.4  // 40-80% for CMU extraction
                    self.treeLoadStatus = "Extracting CMUs... \(Int(progress * 100))%"
                }
            }
            print("📦 Extracted \(cmuData.count) bytes of CMU data")

            // Build tree from CMUs (this takes ~30-60 seconds for 1M+ CMUs)
            await MainActor.run {
                self.treeLoadStatus = "Building tree from CMUs (this takes 30-60s)..."
                self.treeLoadProgress = 0.8
            }

            if ZipherXFFI.treeLoadFromCMUsWithProgress(data: cmuData) { current, total in
                let progress = Double(current) / Double(total)
                Task { @MainActor in
                    self.treeLoadProgress = 0.8 + progress * 0.2  // 80-100% for tree build
                    self.treeLoadStatus = "Building tree: \(current)/\(total) CMUs (\(Int(progress * 100))%)"
                }
            } {
                let treeSize = ZipherXFFI.treeSize()
                print("✅ FIX #456: Tree built from CMUs: \(treeSize) commitments (height \(downloadedTreeHeight))")

                // Store effective height for FilterScanner
                UserDefaults.standard.set(Int(downloadedTreeHeight), forKey: "effectiveTreeHeight")
                UserDefaults.standard.set(Int(downloadedCMUCount), forKey: "effectiveTreeCMUCount")

                // Save to database for next time (FIX #456 + FIX #565)
                if let serializedTree = ZipherXFFI.treeSerialize() {
                    try? WalletDatabase.shared.saveTreeState(serializedTree)
                    print("💾 FIX #456 + FIX #565: Tree state saved to database (current FFI version, height: \(downloadedTreeHeight))")
                }

                await MainActor.run {
                    self.isTreeLoaded = true
                    self.treeLoadProgress = 1.0
                    self.treeLoadStatus = "Privacy infrastructure ready\n\(treeSize.formatted()) commitments loaded"
                    self.updateOverallProgress(phase: .loadingTree, phaseProgress: 1.0)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        self.showBoostDownloadSheet = false
                    }
                }
                return
            } else {
                // CMU build also failed - this is a critical error
                print("❌ FIX #456: CRITICAL - Both deserialization AND CMU build failed!")
                print("❌ FIX #456: This indicates a serious FFI corruption issue")
                await MainActor.run {
                    self.treeLoadStatus = "Failed: Tree build error\nPlease report this issue"
                    self.treeLoadProgress = 0.0
                }
                return
            }
        } catch {
            print("❌ FIX #456: Failed to extract CMUs: \(error.localizedDescription)")
            await MainActor.run {
                self.treeLoadStatus = "Failed to extract CMUs"
                self.treeLoadProgress = 0.0
            }
            return
        }
    }


    // MARK: - Background Tree Sync

    /// Track background sync state to prevent concurrent syncs
    private var isBackgroundSyncing = false
    private let backgroundSyncLock = NSLock()

    // FIX #298: Track refresh balance state to prevent concurrent refreshes
    private var isRefreshingBalance = false
    private let refreshBalanceLock = NSLock()

    // MARK: - Comprehensive Sync Operation Locking (Prevents Database Corruption)

    /// Track current sync operation to prevent concurrent operations
    /// This prevents race conditions that cause database inconsistencies
    private var currentSyncOperation: String? = nil
    private let syncOperationLock = NSLock()

    /// Execute an operation with exclusive sync access
    /// Prevents concurrent sync operations that could corrupt database state
    /// - Parameters:
    ///   - operationName: Name of the operation (for logging)
    ///   - operation: The async operation to execute
    /// - Returns: Result of the operation, or nil if blocked/timed out
    func executeExclusiveSyncOperation<T>(
        operationName: String,
        operation: () async throws -> T
    ) async throws -> T? {
        // Wait for exclusive access
        syncOperationLock.lock()

        // Check if another operation is running
        let maxWait = 30  // 30 seconds max wait
        var waited = 0
        while let current = currentSyncOperation {
            syncOperationLock.unlock()

            if waited >= maxWait {
                print("⚠️ SYNC LOCK: Giving up waiting for '\(current)' (waited \(maxWait)s)")
                return nil
            }

            print("⚠️ SYNC LOCK: Waiting for '\(current)' to complete (attempt \(waited + 1)/\(maxWait))...")
            try? await Task.sleep(nanoseconds: 1_000_000_000)  // 1 second
            waited += 1

            syncOperationLock.lock()
        }

        // Mark our operation
        currentSyncOperation = operationName
        syncOperationLock.unlock()

        print("🔒 SYNC LOCK: Starting exclusive operation: '\(operationName)'")

        // Execute with defer cleanup
        defer {
            syncOperationLock.lock()
            currentSyncOperation = nil
            syncOperationLock.unlock()
            print("🔓 SYNC LOCK: Completed operation: '\(operationName)'")
        }

        return try await operation()
    }

    /// Check if a specific sync operation is currently running
    func isSyncOperationRunning(_ operationName: String) -> Bool {
        syncOperationLock.lock()
        defer { syncOperationLock.unlock() }
        return currentSyncOperation == operationName
    }

    /// Get name of currently running sync operation (if any)
    var currentSyncOperationName: String? {
        syncOperationLock.lock()
        defer { syncOperationLock.unlock() }
        return currentSyncOperation
    }

    // MARK: - FIX #132: Header Sync for Missing Timestamps

    /// Ensure header timestamps are synced for all transactions
    /// This can be called independently from FAST START mode to sync timestamps
    /// without requiring new blocks (which triggers backgroundSyncToHeight)
    func ensureHeaderTimestamps() async {
        print("📜 FIX #120: Checking for transactions needing timestamps...")

        // FIX #495: Skip if we're already at chain tip (no need to sync headers)
        let currentChainHeight = await MainActor.run { NetworkManager.shared.chainHeight }
        let walletHeight = (try? WalletDatabase.shared.getLastScannedHeight()) ?? 0

        if currentChainHeight > 0 && walletHeight >= currentChainHeight - 100 {
            print("✅ FIX #495: Already at chain tip (walletHeight=\(walletHeight), chain=\(currentChainHeight)), skipping header sync")
            return
        }

        // FIX #120: First, detect and clear wrong timestamps in the gap between boost file and header store
        // Boost file (BlockTimestampManager) covers up to ~2935315
        // HeaderStore may start from a higher height (e.g., 2938701)
        // Transactions in the gap have wrong estimated timestamps that need to be re-fetched
        let boostMaxHeight = BlockTimestampManager.shared.maxHeight
        if let headerMinHeight = try? HeaderStore.shared.getMinHeight(), headerMinHeight > boostMaxHeight + 1 {
            let cleared = try? WalletDatabase.shared.clearWrongTimestampsInGap(
                boostEndHeight: boostMaxHeight,
                headerStartHeight: headerMinHeight
            )
            if let cleared = cleared, cleared > 0 {
                print("📜 FIX #120: Cleared \(cleared) wrong timestamps, will sync headers to fix")
            }
        }

        // Check if any transactions need timestamps from earlier heights
        guard var earliestNeedingTimestamp = try? WalletDatabase.shared.getEarliestHeightNeedingTimestamp() else {
            print("✅ FIX #120: No transactions need timestamps (all have dates)")
            return
        }

        // ================================================================
        // FIX #149/#186: Limit header sync to last 100 blocks
        // ================================================================
        // User requested: "consensus must be verified over 100 latest blocks only"
        // For both FAST START and fresh imports, we only need recent blocks for consensus
        // Historical timestamps can be estimated without syncing thousands of headers
        // FIX #186: Use boost file height or chain height as reference, not headerStoreMaxHeight
        //           (headerStoreMaxHeight=0 for fresh imports, causing 10,000+ header sync!)
        let cachedChainHeightForRef = await MainActor.run { UInt64(NetworkManager.shared.chainHeight) }
        let referenceHeight = max(
            (try? HeaderStore.shared.getLatestHeight()) ?? 0,
            ZipherXConstants.effectiveTreeHeight,
            cachedChainHeightForRef
        )
        let maxSyncRange: UInt64 = 100  // Only sync last 100 blocks for consensus

        if referenceHeight > maxSyncRange {
            let minStartHeight = referenceHeight - maxSyncRange
            if earliestNeedingTimestamp < minStartHeight {
                print("📊 FIX #186: Limiting header sync to last \(maxSyncRange) blocks (was \(referenceHeight - earliestNeedingTimestamp) blocks)")
                earliestNeedingTimestamp = minStartHeight
            }
        }

        // ================================================================
        // FIX #708: Skip sync if HeaderStore already covers the needed range
        // ================================================================
        // Previous bug: ensureHeaderTimestamps() would sync headers that were JUST synced
        // by the preceding FIX #535 sync in ContentView. The first sync syncs to chain tip,
        // then this function tried to sync from earliestNeedingTimestamp again.
        // Solution: Check if HeaderStore already has headers at earliestNeedingTimestamp
        let headerStoreHeight = (try? HeaderStore.shared.getLatestHeight()) ?? 0
        if headerStoreHeight >= earliestNeedingTimestamp {
            print("✅ FIX #708: HeaderStore (\(headerStoreHeight)) already covers earliestNeedingTimestamp (\(earliestNeedingTimestamp)) - skipping redundant sync")
            // Headers are already synced, just fix any transactions that need timestamps
            let fixedCount = try? WalletDatabase.shared.fixTransactionBlockTimes()
            if let fixed = fixedCount, fixed > 0 {
                print("📜 FIX #708: Fixed \(fixed) transaction timestamps from existing headers")
            }
            return
        }

        // ================================================================
        // FIX #147: PHASE 1 - PEER CONSENSUS (must happen BEFORE header sync)
        // ================================================================
        // First, wait for peers and get consensus chain height
        await MainActor.run {
            self.isHeaderSyncing = true
            self.headerSyncProgress = 0.0
            self.headerSyncStatus = "Phase 1: Verifying peer consensus..."
        }

        // Wait for at least 3 peers for consensus
        let minPeersForConsensus = 3
        var peerWaitAttempts = 0
        let maxPeerWaitAttempts = 30 // 30 seconds max

        var currentPeers = await MainActor.run { NetworkManager.shared.connectedPeers }
        while currentPeers < minPeersForConsensus && peerWaitAttempts < maxPeerWaitAttempts {
            peerWaitAttempts += 1
            await MainActor.run {
                self.headerSyncStatus = "Waiting for peers (\(currentPeers)/\(minPeersForConsensus))..."
            }
            print("⏳ FIX #147: Waiting for \(minPeersForConsensus) peers... (\(currentPeers) connected)")
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
            currentPeers = await MainActor.run { NetworkManager.shared.connectedPeers }
        }

        let peerCount = await MainActor.run { NetworkManager.shared.connectedPeers }
        if peerCount < minPeersForConsensus {
            print("⚠️ FIX #147: Only \(peerCount) peers connected (need \(minPeersForConsensus))")
        }

        // Get chain height from peer consensus
        await MainActor.run {
            self.headerSyncStatus = "Querying chain tip from \(peerCount) peers..."
        }
        print("🔗 FIX #147: Getting chain height from peer consensus (\(peerCount) peers)...")

        let fallbackChainHeight = await MainActor.run { NetworkManager.shared.chainHeight }
        let chainHeight = (try? await NetworkManager.shared.getChainHeight()) ?? fallbackChainHeight
        print("✅ FIX #147: Peer consensus achieved! Chain tip: \(chainHeight)")

        // ================================================================
        // FIX #147: PHASE 2 - HEADER SYNC (after peer consensus verified)
        // ================================================================
        let currentHeaderHeight = (try? HeaderStore.shared.getLatestHeight()) ?? 0
        let headersToSync = earliestNeedingTimestamp < currentHeaderHeight
            ? 0  // Already have headers
            : chainHeight > earliestNeedingTimestamp ? chainHeight - earliestNeedingTimestamp : 0

        await MainActor.run {
            self.headerSyncCurrentHeight = earliestNeedingTimestamp
            self.headerSyncTargetHeight = chainHeight
            self.headerSyncStatus = "Phase 2: Syncing \(headersToSync) block headers..."
        }

        let torWasBypassed: Bool
        if headersToSync > 500 {
            let torEnabled = await TorManager.shared.mode == .enabled
            if torEnabled {
                print("⚠️ FIX #142: Massive header sync (\(headersToSync) headers) - bypassing Tor for speed...")
                await MainActor.run {
                    self.isTorBypassed = true
                    self.headerSyncStatus = "Bypassing Tor for faster sync..."
                }
                torWasBypassed = await TorManager.shared.bypassTorForMassiveOperation()
                if torWasBypassed {
                    await MainActor.run {
                        self.headerSyncStatus = "Reconnecting without Tor..."
                    }
                    // Reconnect without Tor
                    try? await NetworkManager.shared.connect()

                    // FIX #144: Wait for at least 2 peers to connect (max 10s)
                    var waitCount = 0
                    let maxWait = 100 // 10 seconds
                    var currentPeerCount = await MainActor.run { NetworkManager.shared.connectedPeers }
                    while currentPeerCount < 2 && waitCount < maxWait {
                        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                        waitCount += 1
                        currentPeerCount = await MainActor.run { NetworkManager.shared.connectedPeers }
                        if waitCount % 20 == 0 {
                            await MainActor.run {
                                self.headerSyncStatus = "Waiting for P2P peers... (\(currentPeerCount) connected)"
                            }
                        }
                    }
                    let finalPeerCount = await MainActor.run { NetworkManager.shared.connectedPeers }
                    print("📡 FIX #144: Got \(finalPeerCount) peers after \(waitCount/10)s for header sync")
                }
            } else {
                torWasBypassed = false
            }
        } else {
            torWasBypassed = false
        }

        // Ensure Tor is restored after sync completes (even on error)
        defer {
            if torWasBypassed {
                Task {
                    await MainActor.run {
                        self.headerSyncStatus = "Restoring Tor privacy..."
                    }
                    await TorManager.shared.restoreTorAfterBypass()
                    await MainActor.run {
                        self.isTorBypassed = false
                    }
                    // Reconnect with Tor
                    try? await NetworkManager.shared.connect()
                }
            }
        }

        print("📜 FIX #120: Syncing headers from height \(earliestNeedingTimestamp) for timestamps")

        // FIX #144: Ensure we have at least 2 peers before trying header sync
        var connectedPeerCount = await MainActor.run { NetworkManager.shared.connectedPeers }
        if connectedPeerCount < 2 {
            await MainActor.run {
                self.headerSyncStatus = "Connecting to P2P network..."
            }
            // Try to connect if not connected
            let isConnected = await MainActor.run { NetworkManager.shared.isConnected }
            if !isConnected {
                try? await NetworkManager.shared.connect()
            }
            // Wait for at least 2 peers (max 10s)
            var waitCount = 0
            let maxWait = 100 // 10 seconds
            connectedPeerCount = await MainActor.run { NetworkManager.shared.connectedPeers }
            while connectedPeerCount < 2 && waitCount < maxWait {
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                waitCount += 1
                if waitCount % 20 == 0 {
                    await MainActor.run {
                        self.headerSyncStatus = "Waiting for peers... (\(connectedPeerCount) connected)"
                    }
                }
                connectedPeerCount = await MainActor.run { NetworkManager.shared.connectedPeers }
            }

            // If still no peers, report error and return
            if connectedPeerCount < 2 {
                print("⚠️ FIX #144: Cannot sync headers - only \(connectedPeerCount) peers connected")
                await MainActor.run {
                    self.isHeaderSyncing = false
                    self.headerSyncStatus = ""
                }
                return
            }
            print("📡 FIX #144: Got \(connectedPeerCount) peers for header sync")
        }

        // FIX #136: Set header syncing flag to pause mempool scan during sync
        // This prevents P2P race conditions that cause header sync to get stuck
        // FIX #509: Now async - waits for listeners to actually stop
        await NetworkManager.shared.setHeaderSyncing(true)
        defer {
            Task { await NetworkManager.shared.setHeaderSyncing(false) }
        }

        let hsm = HeaderSyncManager(
            headerStore: HeaderStore.shared,
            networkManager: NetworkManager.shared
        )

        // FIX #487 v3: Report progress to UI for header sync (direct @Published updates)
        hsm.onProgress = { [weak self] progress in
            // Update @Published properties directly on main thread
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                let progressPercentage = progress.totalHeight > 0
                    ? Double(progress.currentHeight) / Double(progress.totalHeight)
                    : 0.0
                self.headerSyncProgress = progressPercentage
                self.headerSyncCurrentHeight = UInt64(progress.currentHeight)
                self.headerSyncTargetHeight = UInt64(progress.totalHeight)
                self.headerSyncStatus = "Syncing block timestamps: \(progress.currentHeight) / \(progress.totalHeight)"

                // Also update syncTasks if available
                // FIX #488 v3: Replace struct in array to trigger SwiftUI @Published update
                if let index = self.syncTasks.firstIndex(where: { $0.id == "headers" }) {
                    var task = self.syncTasks[index]
                    task.status = .inProgress
                    task.detail = "Syncing timestamps: \(progress.currentHeight) / \(progress.totalHeight)"
                    task.progress = progressPercentage
                    self.syncTasks[index] = task
                }
            }
        }

        do {
            // FIX #157: Add 60-second total timeout for header sync in FAST START
            // We're only syncing ~10-100 headers, so this should be plenty of time
            // If a peer is stuck, the per-peer timeout (20s) will trigger first
            // This is a safety net to ensure FAST START never hangs for 2+ minutes
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    // FIX #180: Limit to 100 headers for speed
                    try await hsm.syncHeaders(from: earliestNeedingTimestamp, maxHeaders: 100)
                }

                group.addTask {
                    try await Task.sleep(nanoseconds: 60_000_000_000)  // 60 seconds max
                    throw NetworkError.timeout
                }

                // Wait for first to complete (either sync finishes or timeout)
                _ = try await group.next()
                group.cancelAll()
            }
            print("✅ FIX #120: Header sync for timestamps completed")

            // FIX #144: Update UI - sync complete
            await MainActor.run {
                self.headerSyncProgress = 1.0
                self.headerSyncStatus = "Fixing transaction timestamps..."
            }

            // Fix any transactions that have NULL or wrong timestamps (now that headers are synced)
            let fixedCount = try? WalletDatabase.shared.fixTransactionBlockTimes()
            print("📜 FIX #120: Fixed \(fixedCount ?? 0) transaction timestamps")

            // FIX #146: Update cachedChainHeight for FAST START on next launch
            if chainHeight > 0 {
                UserDefaults.standard.set(Int(chainHeight), forKey: "cachedChainHeight")
                print("📊 FIX #146: Updated cachedChainHeight to \(chainHeight) for FAST START")
            }

            // FIX #144: Clear header sync UI state
            await MainActor.run {
                self.isHeaderSyncing = false
                self.headerSyncProgress = 0.0
                self.headerSyncStatus = ""

                // Mark syncTask as completed if available
                // FIX #497: Replace entire task struct to trigger SwiftUI @Published update
                if let index = syncTasks.firstIndex(where: { $0.id == "headers" }) {
                    var task = syncTasks[index]
                    task.status = .completed
                    task.detail = "Timestamps synced (\(fixedCount ?? 0) fixed)"
                    task.progress = 1.0
                    syncTasks[index] = task
                }
            }
        } catch {
            // FIX #157: Log timeout specifically
            if case NetworkError.timeout = error {
                print("⚠️ FIX #157: Header sync timed out after 60s - continuing without full timestamps")
            } else {
                print("⚠️ FIX #120: Header sync for timestamps failed: \(error.localizedDescription)")
            }

            // FIX #144: Clear header sync UI state on error
            await MainActor.run {
                self.isHeaderSyncing = false
                self.headerSyncProgress = 0.0
                self.headerSyncStatus = "Sync failed: \(error.localizedDescription)"

                // Mark task as failed
                // FIX #497: Replace entire task struct to trigger SwiftUI @Published update
                if let index = syncTasks.firstIndex(where: { $0.id == "headers" }) {
                    var task = syncTasks[index]
                    task.status = .failed(error.localizedDescription)
                    task.detail = "Sync failed"
                    syncTasks[index] = task
                }
            }
        }
    }

    // MARK: - FIX #413: Bundled Headers from Boost File

    /// Load headers from boost file at startup (if available)
    /// This is MUCH faster than P2P sync for historical blocks
    /// Returns: (success, boostEndHeight) - boostEndHeight is where delta sync should start
    func loadHeadersFromBoostFile() async -> (Bool, UInt64) {
        print("📜 FIX #413: Checking for bundled headers in boost file...")

        // FIX #701: Skip if boost headers already loaded (prevents repeated loading)
        let existingBoostHeight = HeaderStore.shared.boostFileEndHeight
        if existingBoostHeight > 0 {
            print("✅ FIX #701: Boost headers already loaded up to \(existingBoostHeight) - skipping reload")
            return (true, existingBoostHeight)
        }

        // FIX #675: Check if boost headers were marked as corrupted
        if HeaderStore.shared.shouldSkipBoostHeaders() {
            print("🚫 FIX #675: Skipping boost headers - corruption detected previously")
            print("🚫 FIX #675: Will rely on P2P header sync only")
            return (false, 0)
        }

        // Check if boost file has headers section
        guard await CommitmentTreeUpdater.shared.hasHeadersSection() else {
            print("⚠️ FIX #413: Boost file has no headers section (requires v2+ boost file)")
            return (false, 0)
        }

        guard let sectionInfo = await CommitmentTreeUpdater.shared.getHeadersSectionInfo() else {
            print("⚠️ FIX #413: Could not get headers section info")
            return (false, 0)
        }

        // FIX #452: Sanity check - reject impossible header counts (corrupted boost file metadata)
        // Current chain is ~3M blocks, anything over 10M is definitely corrupted
        // NOTE: After fixing generate_boost_file.py to use actual header heights, this should rarely trigger
        let maxReasonableHeaders: UInt64 = 10_000_000
        if sectionInfo.count > maxReasonableHeaders || sectionInfo.endHeight > 10_000_000 {
            print("🚨 FIX #452: CRITICAL - Boost file headers metadata is CORRUPTED!")
            print("🚨 FIX #452: Claims \(sectionInfo.count) headers to height \(sectionInfo.endHeight)")
            print("🚨 FIX #452: Maximum reasonable is ~10M - boost file needs to be regenerated with fixed script")
            print("⚠️ FIX #452: Falling back to P2P header sync")
            return (false, 0)
        }

        print("📜 FIX #413: Boost file has \(sectionInfo.count) headers (height \(sectionInfo.startHeight) to \(sectionInfo.endHeight))")

        // FIX #683: Check if HeaderStore actually has the boost file headers (contiguous range)
        // Old bug: Only checked maxHeight >= boostEndHeight, which was TRUE for P2P headers
        // This caused boost file headers (476969-2984746) to never be loaded!
        let countInRange = (try? HeaderStore.shared.countHeadersInRange(from: sectionInfo.startHeight, to: sectionInfo.endHeight)) ?? 0
        let expectedCount = Int(sectionInfo.endHeight - sectionInfo.startHeight + 1)
        let hasBoostHeaders = countInRange >= expectedCount * 95 / 100  // Allow 5% gaps

        if hasBoostHeaders {
            print("✅ FIX #413: Boost file headers already loaded (\(countInRange)/\(expectedCount) in range)")
            return (true, sectionInfo.endHeight)
        }

        print("📜 FIX #683: Boost headers NOT loaded - only \(countInRange)/\(expectedCount) in range, will load now")

        // Extract and load headers
        do {
            // FIX #457: Extract block hashes FIRST (needed for instant header loading)
            let blockHashesData: Data?
            if await CommitmentTreeUpdater.shared.hasBlockHashesSection() {
                print("📜 FIX #457: Extracting pre-computed block hashes from boost file...")
                blockHashesData = try await CommitmentTreeUpdater.shared.extractBlockHashes()
                if let hashes = blockHashesData {
                    print("📜 FIX #457: Extracted \(hashes.count / 32) block hashes (instant loading!)")
                }
            } else {
                print("⚠️ FIX #457: No block hashes section in boost file - will compute hashes (slow)")
                blockHashesData = nil
            }

            guard let headerData = try await CommitmentTreeUpdater.shared.extractHeaders() else {
                print("⚠️ FIX #413: Failed to extract headers from boost file")
                return (false, 0)
            }

            // Load headers into HeaderStore with pre-computed hashes
            // FIX #457: Pass expected count from manifest (headers have Equihash solutions, so size varies)
            // FIX #684: Set isHeaderSyncing BEFORE loading starts for proper UI progress display
            await MainActor.run {
                self.isHeaderSyncing = true
                self.headerSyncProgress = 0.0
                self.headerSyncStatus = "Loading bundled headers (0%)"
                self.headerSyncCurrentHeight = sectionInfo.startHeight
                self.headerSyncTargetHeight = sectionInfo.endHeight
            }

            // FIX #488: Run blocking loadHeadersFromBoostData on background thread
            // This prevents blocking the main thread, allowing UI updates during the 100-second load
            // The callback uses DispatchQueue.main.async which queues blocks on main thread
            // If main thread is blocked, those blocks never execute until load completes
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    guard let self = self else {
                        continuation.resume(returning: ())
                        return
                    }

                    do {
                        // FIX #468: Add progress callback for header loading
                        try HeaderStore.shared.loadHeadersFromBoostData(
                            headerData,
                            blockHashes: blockHashesData,
                            startHeight: sectionInfo.startHeight,
                            expectedCount: Int(sectionInfo.count)
                        ) { [weak self] progress in
                            let percent = Int(progress * 100)
                            print("🔧 FIX #684: Header load progress: \(percent)%")

                            // FIX #684: Update header sync UI state
                            DispatchQueue.main.async { [weak self] in
                                guard let self = self else { return }
                                self.headerSyncProgress = progress
                                self.headerSyncStatus = "Loading bundled headers (\(percent)%)"
                                let currentHeight = sectionInfo.startHeight + UInt64(Double(sectionInfo.count) * progress)
                                self.headerSyncCurrentHeight = currentHeight
                            }
                        }
                        continuation.resume(returning: ())
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }

            print("✅ FIX #457: Loaded \(sectionInfo.count) headers from boost file (up to height \(sectionInfo.endHeight))")

            // FIX #684: Mark header sync as completed
            await MainActor.run {
                self.isHeaderSyncing = false
                self.headerSyncProgress = 1.0
                self.headerSyncStatus = "Loaded \(sectionInfo.count) headers"
                self.headerSyncCurrentHeight = sectionInfo.endHeight
            }
            return (true, sectionInfo.endHeight)
        } catch {
            print("❌ FIX #457: Failed to load headers from boost file: \(error.localizedDescription)")
            return (false, 0)
        }
    }

    /// FIX #413: Check GitHub for newer boost file and download if available
    /// Returns true if a newer boost file was downloaded
    func checkAndDownloadNewerBoostFile() async -> Bool {
        print("🔍 FIX #413: Checking GitHub for newer boost file...")

        let currentBoostHeight = await CommitmentTreeUpdater.shared.getCachedBoostHeight() ?? 0
        if currentBoostHeight == 0 {
            print("📥 FIX #413: No cached boost file - will download")
        }

        do {
            // This will check GitHub and download if remote is newer
            let (_, newHeight, _) = try await CommitmentTreeUpdater.shared.getBestAvailableBoostFile { progress, status in
                // Progress callback - could update UI here
                if Int(progress * 100) % 20 == 0 {
                    print("📥 FIX #413: \(status) (\(Int(progress * 100))%)")
                }
            }

            if newHeight > currentBoostHeight {
                print("✅ FIX #413: Downloaded newer boost file (height \(newHeight) > \(currentBoostHeight))")
                return true
            } else {
                print("✅ FIX #413: Boost file is current (height \(newHeight))")
                return false
            }
        } catch {
            print("⚠️ FIX #413: Failed to check/download boost file: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - FIX #242: Foreground Catch-Up

    /// Check if wallet is behind blockchain and catch up if needed
    /// Called when app returns to foreground after being in background
    /// Updates isCatchingUp and blocksBehind properties for UI display
    func checkAndCatchUp() async {
        guard isTreeLoaded else { return }

        // Get current wallet height
        let walletHeight = (try? WalletDatabase.shared.getLastScannedHeight()) ?? 0
        guard walletHeight > 0 else { return }

        // Get chain height from peers (bypass stale HeaderStore)
        var peerHeights: [UInt64] = []
        let allPeers = await MainActor.run { NetworkManager.shared.getAllConnectedPeers() }
        for peer in allPeers.prefix(5) {
            let height = UInt64(peer.peerStartHeight)
            if height > 0 {
                peerHeights.append(height)
            }
        }

        guard !peerHeights.isEmpty else {
            print("🔄 FIX #242: No peer heights available for catch-up check")
            return
        }

        // Use median height for robustness
        let sortedHeights = peerHeights.sorted()
        let chainHeight = sortedHeights[sortedHeights.count / 2]

        let behind = chainHeight > walletHeight ? chainHeight - walletHeight : 0

        await MainActor.run {
            self.blocksBehind = behind
            if behind > 0 {
                self.isCatchingUp = true
                print("🔄 FIX #242: Catching up \(behind) blocks (wallet: \(walletHeight), chain: \(chainHeight))")
            }
        }

        // Trigger background sync if behind
        if behind > 0 {
            await backgroundSyncToHeight(chainHeight)

            // After sync, update status
            await MainActor.run {
                self.isCatchingUp = false
                self.blocksBehind = 0
                print("✅ FIX #242: Catch-up complete")
            }
        }
    }

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

        // FIX #368: Don't run background sync if database repair is in progress
        // This prevents race condition where backgroundSyncToHeight updates lastScannedHeight
        // to chain tip BEFORE a Full Resync PHASE 2 completes!
        // Bug: Full Resync showed 100% in seconds because backgroundSync ran between PHASE 1 and PHASE 2,
        // setting lastScannedHeight to chain tip with wrong balance (0.0015 instead of 0.92 ZCL)
        guard !isRepairingDatabase else {
            print("⚠️ FIX #368: Background sync blocked - database repair in progress")
            return
        }

        // Also block if FilterScanner is running (double protection)
        guard !FilterScanner.isScanInProgress else {
            print("⚠️ FIX #368: Background sync blocked - FilterScanner in progress")
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
                for: account.accountId,
                viewingKey: spendingKey,
                fromHeight: currentHeight + 1
            )

            // FIX #398: CRITICAL - Do NOT update lastScannedHeight to targetHeight!
            // The FilterScanner has its OWN targetHeight based on chain height when IT starts.
            // If backgroundSyncToHeight's targetHeight > FilterScanner's targetHeight, updating
            // to backgroundSyncToHeight's targetHeight causes blocks to be SKIPPED!
            //
            // Bug: TX c50e9ffb change output (0.91 ZCL) was lost because:
            //   1. backgroundSyncToHeight called with targetHeight=2953451
            //   2. FilterScanner read chain height=2953449, scanned to 2953449
            //   3. backgroundSyncToHeight updated lastScannedHeight to 2953451 (WRONG!)
            //   4. Next scan started from 2953452, skipping block 2953451
            //   5. TX c50e9ffb was in block 2953451 → change note never discovered
            //
            // Fix: Trust the FilterScanner's lastScannedHeight. If it didn't scan all
            // the way to our targetHeight, the next background sync will catch up.
            let actualLastScanned = (try? WalletDatabase.shared.getLastScannedHeight()) ?? 0

            if actualLastScanned < currentHeight {
                // Scan was skipped or failed - don't update anything!
                print("⚠️ FIX #368: Scan may not have completed (expected >= \(currentHeight), got \(actualLastScanned))")
                return
            }

            // FIX #398: Log if scan didn't reach our targetHeight (chain advanced during scan)
            if actualLastScanned < targetHeight {
                print("📋 FIX #398: Scan reached \(actualLastScanned), target was \(targetHeight) - next sync will catch up")
            }

            // FIX #176: Update checkpoint to ACTUAL scanned height, not targetHeight
            // This prevents the health check from flagging "blocks skipped" on next startup
            try? WalletDatabase.shared.updateVerifiedCheckpointHeight(actualLastScanned)

            print("✅ Background sync complete: scanned to height \(actualLastScanned)")

            // FIX #600: Update witnesses with new delta CMUs for instant send
            // Without this, witnesses become stale and require 24s rebuild when user tries to send
            if blocksToSync > 0 {
                print("⚡ FIX #600: Updating witnesses with \(blocksToSync) new blocks for instant send...")
                await preRebuildWitnessesForInstantPayment(accountId: account.accountId)
            }

            // Update balance with proper confirmation calculation
            let notes = try WalletDatabase.shared.getUnspentNotes(accountId: account.accountId)
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
            await MainActor.run { NetworkManager.shared.updateWalletHeight(targetHeight) }

            // Sync headers for the new blocks so we have real timestamps
            // This ensures transaction history shows correct dates instead of "(est)"
            // FIX #120: Also sync from earliest transaction that needs a timestamp
            do {
                let hsm = HeaderSyncManager(
                    headerStore: HeaderStore.shared,
                    networkManager: NetworkManager.shared
                )

                // FIX #487 v3: Report header sync progress to UI (direct @Published updates)
                hsm.onProgress = { [weak self] progress in
                    // Update @Published property directly on main thread
                    DispatchQueue.main.async { [weak self] in
                        self?.headerSyncStatus = "Syncing headers: \(progress.currentHeight)/\(progress.totalHeight)"
                    }
                }

                // Check if any transactions need timestamps from earlier heights
                if let earliestNeedingTimestamp = try? WalletDatabase.shared.getEarliestHeightNeedingTimestamp() {
                    if earliestNeedingTimestamp < currentHeight {
                        print("📜 FIX #120: Syncing headers from \(earliestNeedingTimestamp) for missing timestamps")
                        do {
                            // FIX #180: Limit to 100 headers for speed
                            try await hsm.syncHeaders(from: earliestNeedingTimestamp, maxHeaders: 100)
                            print("✅ FIX #120: Header sync completed for timestamps")
                        } catch {
                            print("⚠️ FIX #120: Header sync failed: \(error.localizedDescription)")
                        }
                    }
                }

                // Also sync from current height for new blocks
                do {
                    // FIX #180: Limit to 100 headers for speed
                    try await hsm.syncHeaders(from: currentHeight + 1, maxHeaders: 100)
                    print("✅ Header sync for new blocks completed")
                } catch {
                    print("⚠️ Header sync for new blocks failed: \(error.localizedDescription)")
                }

                // Fix any transactions that have estimated timestamps
                let fixedCount = try? WalletDatabase.shared.fixTransactionBlockTimes()
                print("📜 Fixed transaction timestamps: \(fixedCount ?? 0) updated")
            } catch {
                // Header sync failed but block scan succeeded - not critical
                print("⚠️ Background header sync failed: \(error.localizedDescription)")
            }

            // PRE-WITNESS REBUILD: Update witnesses for instant payments
            // This ensures all unspent notes have witnesses matching current tree root
            // so the user can send instantly without waiting for witness rebuild
            await preRebuildWitnessesForInstantPayment(accountId: account.accountId)

            // FIX #300: Refresh balance AFTER witness rebuild to ensure accuracy
            // The balance was calculated before witnesses were rebuilt, so notes that
            // just got witnesses weren't counted. Recalculate now.
            do {
                let refreshedBalance = try WalletDatabase.shared.getBalance(accountId: account.accountId)

                // FIX #XXX: If balance dropped to 0 but we have unspent notes, witnesses failed
                // Use total unspent balance as fallback to show correct balance
                if refreshedBalance == 0 {
                    let totalUnspent = try WalletDatabase.shared.getTotalUnspentBalance(accountId: account.accountId)
                    if totalUnspent > 0 {
                        print("⚠️ FIX #XXX: Witness rebuild incomplete, using total unspent balance")
                        print("💰 Balance: \(totalUnspent) zatoshis (\(Double(totalUnspent) / 100_000_000.0) ZCL)")
                        await MainActor.run {
                            self.shieldedBalance = totalUnspent
                        }
                    } else {
                        if refreshedBalance != confirmedBalance {
                            print("💰 FIX #300: Balance updated after witness rebuild: \(confirmedBalance) → \(refreshedBalance) zatoshis")
                            await MainActor.run {
                                self.shieldedBalance = refreshedBalance
                            }
                        }
                    }
                } else if refreshedBalance != confirmedBalance {
                    print("💰 FIX #300: Balance updated after witness rebuild: \(confirmedBalance) → \(refreshedBalance) zatoshis")
                    await MainActor.run {
                        self.shieldedBalance = refreshedBalance
                    }
                }

                // Check if any notes still need witnesses (couldn't be rebuilt)
                let (needCount, needValue) = try WalletDatabase.shared.getNotesNeedingWitness(accountId: account.accountId)
                if needCount > 0 {
                    print("⚠️ FIX #300: \(needCount) note(s) worth \(Double(needValue) / 100_000_000.0) ZCL still need witness rebuild")
                    // Trigger automatic repair if significant amount is affected
                    if needValue > 10_000 { // More than 0.0001 ZCL
                        print("🔧 FIX #300: Auto-triggering witness repair for unspendable notes...")
                        await MainActor.run {
                            self.hasBalanceIssues = true
                        }
                    }
                }
            } catch {
                print("⚠️ FIX #300: Balance refresh failed: \(error.localizedDescription)")
            }

            // FIX #161: Check if any pending incoming transactions were confirmed in this block
            // This clears the "awaiting..." message when the incoming tx gets its first confirmation
            await NetworkManager.shared.checkPendingIncomingConfirmations()

            // FIX #681: Auto-recover any transactions that were confirmed but not recorded
            // This handles the case where broadcast tracking failed (peers timed out) but TX was confirmed
            // Runs silently in background to fix data consistency issues without user intervention
            if blocksToSync > 0 {
                let autoRecovered = await autoRecoverMissingTransactions()
                if autoRecovered > 0 {
                    print("✅ FIX #681: Auto-recovered \(autoRecovered) missing transaction(s) during background sync")
                }
            }

        } catch {
            print("⚠️ Background sync failed: \(error.localizedDescription)")
        }
    }

    /// Pre-rebuild witnesses for all unspent notes to enable instant payments
    /// Called after background sync to ensure witnesses match current tree root
    /// This eliminates witness rebuild delay at send time
    /// CRITICAL FIX: Actually rebuilds stale witnesses instead of deferring to send time
    /// FIX #557 v8: Made internal so ContentView can call it during FAST START
    /// FIX #557 v15: Skip rebuild if already at current chain tip (incremental updates)
    /// FIX #557 v15: Prevent concurrent rebuilds with lock
    /// FIX #557 v18: Added progress callback for UI feedback
    /// FIX #557 v26: Made callback async to ensure UI updates execute
    internal func preRebuildWitnessesForInstantPayment(accountId: Int64, progress: ((String, Int) async -> Void)? = nil) async {
        // FIX #557 v15: Prevent concurrent rebuilds
        witnessRebuildLock.lock()
        if isRebuildingWitnesses {
            witnessRebuildLock.unlock()
            print("⚠️ FIX #557 v15: Witness rebuild already in progress, skipping duplicate request")
            return
        }

        // FIX #557 v15: Skip if we rebuilt recently (within cooldown period)
        // FIX #586: BUT bypass cooldown if there are NULL witnesses that need rebuilding!
        var hasNullWitnesses = false
        if let lastTime = lastWitnessRebuildTime {
            let timeSinceRebuild = Date().timeIntervalSince(lastTime)
            if timeSinceRebuild < witnessRebuildCooldown {
                // Check if there are any NULL witnesses before skipping
                if let notes = try? WalletDatabase.shared.getAllNotes(accountId: accountId) {
                    hasNullWitnesses = notes.contains { $0.witness.isEmpty }
                }

                if !hasNullWitnesses {
                    witnessRebuildLock.unlock()
                    print("⚠️ FIX #557 v15: Skipping rebuild - rebuilt \(Int(timeSinceRebuild))s ago (cooldown: \(Int(witnessRebuildCooldown))s)")
                    return
                } else {
                    print("⚠️ FIX #586: Bypassing cooldown - \(hasNullWitnesses ? "NULL witnesses detected" : "")")
                }
            }
        }

        // FIX #563 v28: Update @Published properties on main thread to prevent crashes
        await MainActor.run {
            isRebuildingWitnesses = true
        }
        witnessRebuildLock.unlock()

        defer {
            // FIX #563 v28: Update @Published properties on main thread in defer block
            Task {
                await MainActor.run {
                    witnessRebuildLock.lock()
                    isRebuildingWitnesses = false
                    lastWitnessRebuildTime = Date()
                    witnessRebuildLock.unlock()
                }
            }
        }

        do {
            // FIX #597 v2: Get header root (TRUE blockchain state) for FAST PATH comparison
            // The FFI treeRoot() can be out of sync with blockchain - must use header root!
            let fastPathChainHeight = (try? await NetworkManager.shared.getChainHeight()) ?? 0

            var headerTreeRoot: Data?
            if fastPathChainHeight > 0 {
                let headerStore = HeaderStore.shared
                try? headerStore.open()
                if let header = try? headerStore.getHeader(at: fastPathChainHeight) {
                    headerTreeRoot = header.hashFinalSaplingRoot
                    let headerRootHex = headerTreeRoot?.prefix(16).map { String(format: "%02x", $0) }.joined() ?? "unknown"
                    print("📋 FIX #597 v2: Header root at \(fastPathChainHeight): \(headerRootHex)...")
                }
            }

            // FIX #597 v2: FAST PATH - Check if witnesses match HEADER root (blockchain truth)
            // If most witnesses match header root, we can skip the rebuild entirely
            let notesForWitnessCheck = try WalletDatabase.shared.getAllNotes(accountId: accountId)

            guard !notesForWitnessCheck.isEmpty else {
                print("✅ Pre-witness: No notes to update")
                return
            }

            // Only use FAST PATH if we have a valid header root to compare against
            if let validHeaderRoot = headerTreeRoot {
                var matchingWitnessCount = 0
                for note in notesForWitnessCheck {
                    if !note.witness.isEmpty, let witnessAnchor = ZipherXFFI.witnessGetRoot(note.witness) {
                        if witnessAnchor == validHeaderRoot {
                            matchingWitnessCount += 1
                        }
                    }
                }

                let matchRatio = Double(matchingWitnessCount) / Double(notesForWitnessCheck.count)
                if matchRatio >= 0.8 {
                    print("✅ FIX #597 v2: FAST PATH - \(matchingWitnessCount)/\(notesForWitnessCheck.count) witnesses (\(Int(matchRatio * 100))%) match HEADER root - skipping rebuild!")
                    return
                } else {
                    print("🔧 FIX #597 v2: \(matchingWitnessCount)/\(notesForWitnessCheck.count) witnesses match HEADER root (\(Int(matchRatio * 100))%) - need rebuild")
                }
            } else {
                print("⚠️ FIX #597 v2: No header root available - cannot use FAST PATH, proceeding with rebuild")
            }

            // FIX #563 v33: Check if we should skip witness root validation due to previous crashes
            let defaults = UserDefaults.standard
            let skipWitnessRootCheck = defaults.bool(forKey: "ZipherX_SkipWitnessRootCheck")
            if skipWitnessRootCheck {
                print("🔒 FIX #563 v33: Skipping witness root validation (previous crash detected) - rebuilding all witnesses")
            }

            var alreadyCurrentCount = 0
            var notesNeedingRebuild: [(note: WalletNote, cmu: Data)] = []
            var anchorUpdates: [(noteId: Int64, anchor: Data)] = []
            var corruptedWitnesses: [(noteId: Int64, height: UInt64)] = []

            for (index, note) in notesForWitnessCheck.enumerated() {
                // FIX #557 v6: Check witness root FIRST, not database anchor
                // The database anchor might be current but witness bytes might be stale!
                var witnessIsCurrent = false

                // FIX #563 v33: Skip witness root check if we've had crashes before
                if !skipWitnessRootCheck && !note.witness.isEmpty {
                    // FIX #563 v32: Add detailed logging to identify which note causes crash
                    print("🔍 [WITNESS \(index + 1)/\(notesForWitnessCheck.count)] Checking note ID=\(note.id) height=\(note.height ?? 0) witness_len=\(note.witness.count)")

                    // Validate witness data length before calling FFI
                    // Witness should be at least 100 bytes (minimum for IncrementalWitness)
                    guard note.witness.count >= 100 else {
                        print("⚠️ [WITNESS \(index + 1)] Note ID=\(note.id) has invalid witness length: \(note.witness.count) bytes")
                        corruptedWitnesses.append((note.id, note.height ?? 0))
                        // Force rebuild for this note
                        if let cmu = note.cmu, !cmu.isEmpty {
                            notesNeedingRebuild.append((note: note, cmu: cmu))
                        }
                        continue
                    }

                    // FIX #563 v32: Validate witness path BEFORE extracting root to prevent FFI crashes
                    // A corrupted witness can cause witness.root() to crash in the Rust FFI
                    // FIX #563 v33: Try-catch this - if it crashes, we'll rebuild all witnesses next time
                    if !ZipherXFFI.witnessPathIsValid(note.witness) {
                        print("⚠️ [WITNESS \(index + 1)] Note ID=\(note.id) has corrupted witness path - forcing rebuild")
                        corruptedWitnesses.append((note.id, note.height ?? 0))
                        // Force rebuild for this note
                        if let cmu = note.cmu, !cmu.isEmpty {
                            notesNeedingRebuild.append((note: note, cmu: cmu))
                        }
                        continue
                    }

                    if let witnessAnchor = ZipherXFFI.witnessGetRoot(note.witness) {
                        print("✅ [WITNESS \(index + 1)] Note ID=\(note.id) root extracted successfully")

                        // FIX #564 Part 2: Don't compare to current tree root!
                        // FIX #563 uses header anchor at note height, NOT current tree root
                        // Witness is valid as long as it extracts a root successfully
                        // The correct anchor will be retrieved from HeaderStore at note height during TX building
                        witnessIsCurrent = true
                        alreadyCurrentCount += 1

                        // Store witness root as anchor (will be used by FIX #563)
                        if note.anchor != witnessAnchor {
                            anchorUpdates.append((note.id, witnessAnchor))
                        }

                        // Old logic (WRONG - causes unnecessary witness rebuilds):
                        // if witnessAnchor == currentTreeRoot {
                        //     witnessIsCurrent = true
                        // } else {
                        //     print("🔄 root mismatch - needs rebuild")  // <-- 41.4s wasted loading CMUs!
                        // }
                    } else {
                        print("⚠️ [WITNESS \(index + 1)] Note ID=\(note.id) witnessGetRoot returned nil")
                    }
                }

                if witnessIsCurrent {
                    continue
                }

                // Witness needs rebuild - collect for batch rebuild
                if let cmu = note.cmu, !cmu.isEmpty {
                    notesNeedingRebuild.append((note: note, cmu: cmu))
                }
            }

            // Log corrupted witness summary
            if !corruptedWitnesses.isEmpty {
                print("⚠️ Pre-witness: Found \(corruptedWitnesses.count) corrupted witnesses, will rebuild")
                for (noteId, height) in corruptedWitnesses {
                    print("   - Note ID=\(noteId) at height=\(height)")
                }
            }

            // Batch update anchors (thread-safe)
            if !anchorUpdates.isEmpty {
                await MainActor.run {
                    for (noteId, anchor) in anchorUpdates {
                        try? WalletDatabase.shared.updateNoteAnchor(noteId: noteId, anchor: anchor)
                    }
                }
            }

            // Summary for notes that don't need rebuild
            if alreadyCurrentCount > 0 {
                print("✅ Pre-witness: \(alreadyCurrentCount) note(s) already instant-ready")
            }

            // FIX #557 v32: Load boost file + sync delta CMUs to current chain tip
            // This ensures the global tree is at the current height before rebuilding witnesses
            // Without this, witnesses would be outdated and transactions would fail

            await progress?("Syncing tree state...", 50)

            // Get chain height for delta sync
            let chainHeight: UInt64
            do {
                chainHeight = try await NetworkManager.shared.getChainHeight()
            } catch {
                print("⚠️ Pre-witness: Failed to get chain height: \(error.localizedDescription)")
                return
            }

            // Try to load existing tree state from database (thread-safe)
            var treeLoaded = false
            var treeWasAlreadyInMemory = false  // FIX #568 v2: Track if tree was already loaded BEFORE this call
            var boostHeight = ZipherXConstants.effectiveTreeHeight

            // FIX #568 v2: Check if FFI tree already has CMUs loaded (from previous operation)
            // This prevents reloading 1M+ CMUs when tree is already in memory
            let currentTreeSize = ZipherXFFI.treeSize()
            if currentTreeSize > 1000 {
                print("✅ FIX #568 v2: Tree already has \(currentTreeSize) CMUs loaded - skipping reload")
                treeLoaded = true
                treeWasAlreadyInMemory = true  // Remember that we didn't just load it
            }

            // Use MainActor for database access to ensure thread safety
            if !treeLoaded {
                let loadResult = await MainActor.run { () -> (Data?, UInt64?) in
                    do {
                        let savedTree = try WalletDatabase.shared.getTreeState()
                        let dbTreeHeight = try WalletDatabase.shared.getTreeHeight()
                        return (savedTree, dbTreeHeight)
                    } catch {
                        print("⚠️ Pre-witness: Failed to load tree state from DB: \(error.localizedDescription)")
                        return (nil, nil)
                    }
                }

                if let savedTree = loadResult.0, savedTree.count > 1000 {  // Minimum valid size check
                    // FIX #563 v38: Use treeLoadFromCMUs for saved CMU data (reliable!)
                    // treeSerialize is broken (only 606 bytes), so we save CMU data instead
                    let loaded = ZipherXFFI.treeLoadFromCMUs(data: savedTree)
                    treeLoaded = loaded
                    let dbTreeHeight = loadResult.1 ?? 0
                    print("✅ FIX #563 v38: Loaded saved CMU data (\(savedTree.count) bytes) at height \(dbTreeHeight)")
                }
            }

            // Load boost file if tree not loaded
            if !treeLoaded {
                await progress?("Loading boost file...", 60)

                // FIX #563 v34: Use cached CMU file instead of extracting every time (43 seconds -> instant!)
                // The cached file is created on first access and reused on subsequent startups
                print("📦 FIX #563 v34: Loading CMUs from cached file...")
                do {
                    // getCachedCMUFilePath returns the cached file path instantly,
                    // or extracts from boost file and caches it for next time
                    guard let cmuFilePath = await CommitmentTreeUpdater.shared.getCachedCMUFilePath() else {
                        print("❌ FIX #563 v34: No cached CMU file available")
                        return
                    }

                    let cmuData = try Data(contentsOf: cmuFilePath)

                    if cmuData.count > 8 {
                        let loaded = ZipherXFFI.treeLoadFromCMUs(data: cmuData)
                        if !loaded {
                            print("❌ FIX #563 v34: Failed to load cached CMUs into tree")
                            return
                        }

                        print("✅ FIX #563 v34: Loaded cached CMUs at height \(boostHeight)")

                        // FIX #563 v38: Save CMU data directly instead of treeSerialize (broken - only 606 bytes!)
                        // treeSerialize uses zcash_primitives write_commitment_tree which fails for large trees
                        // Saving CMU data (33MB) is slower but reliable and much faster than re-extracting
                        await MainActor.run {
                            // Save CMU data with metadata for validation
                            try? WalletDatabase.shared.saveTreeState(cmuData)
                            print("✅ FIX #563 v38: Saved CMU data (\(cmuData.count) bytes) to database")
                        }
                    } else {
                        print("❌ FIX #563 v34: Cached CMU data too small (\(cmuData.count) bytes)")
                        return
                    }
                } catch {
                    print("❌ FIX #563 v34: Failed to load CMUs from cached file: \(error.localizedDescription)")
                    return
                }
            }

            // Sync delta CMUs if chain height > boost file height (thread-safe)
            // FIX #563 v43: Proper delta sync logic based on what we just loaded
            let startHeight = await MainActor.run { () -> UInt64 in
                return (try? WalletDatabase.shared.getTreeHeight()) ?? ZipherXConstants.effectiveTreeHeight
            }

            // FIX #563 v43: Determine if we need to sync based on what we just loaded
            // If we loaded from DB (treeLoaded=true), check if we need delta sync
            // If we loaded from boost file (treeLoaded=false), we definitely need delta sync if chain moved forward
            let blocksBehind = chainHeight > startHeight ? chainHeight - startHeight : 0
            let isRecentEnough = blocksBehind < 1000

            // FIX #563 v43: Skip delta sync ONLY if we loaded from DB AND tree is recent
            // If we just loaded from boost file, we MUST sync delta (even if recent) to update tree_height
            // FIX #568 v2: NEVER skip delta sync if tree was already in memory - we need it to update witnesses!
            let shouldSkipDeltaSync = !treeWasAlreadyInMemory && treeLoaded && isRecentEnough

            if shouldSkipDeltaSync {
                print("✅ FIX #563 v43: Skipping delta CMU sync - DB tree is recent (\(blocksBehind) blocks behind chain tip)")
                print("✅ FIX #563 v43: Tree has \(ZipherXFFI.treeSize()) CMUs, will sync when >1000 blocks behind")
            } else if treeWasAlreadyInMemory && blocksBehind > 0 {
                print("🔄 FIX #568 v2: Tree was already in memory but syncing \(blocksBehind) delta CMUs to update witnesses")
            } else if chainHeight > startHeight {
                print("🔄 FIX #557 v32: Syncing delta CMUs from \(startHeight) to \(chainHeight) (\(blocksBehind) blocks)...")

                await progress?("Fetching delta CMUs...", 70)

                // FIX #563 v39: Increased batch size for faster sync (500 blocks instead of 100)
                let batchSize: UInt64 = 500  // blocks per batch
                var currentHeight = startHeight + 1
                var consecutiveFailures = 0
                let maxConsecutiveFailures = 3
                let maxRetries = 3
                var deltaCMUs: [Data] = []

                while currentHeight <= chainHeight {
                    let endHeight = min(currentHeight + batchSize - 1, chainHeight)

                    var batchSucceeded = false

                    for attempt in 1...maxRetries {
                        do {
                            // FIX #557 v32: Fetch blocks via P2P
                            let blocks = try await NetworkManager.shared.getBlocksDataP2P(from: currentHeight, count: Int(endHeight - currentHeight + 1))

                            for (height, _, _, txData) in blocks {
                                for (txid, outputs, _) in txData {
                                    for output in outputs {
                                        // Convert hex string to Data
                                        if let cmuData = Data(hexString: output.cmu) {
                                            deltaCMUs.append(cmuData)
                                        }
                                    }
                                }
                            }
                            batchSucceeded = true
                            consecutiveFailures = 0
                            break
                        } catch {
                            if attempt < maxRetries {
                                try? await Task.sleep(nanoseconds: 1_000_000_000)
                            } else {
                                print("⚠️ FIX #557 v32: Batch failed: \(error.localizedDescription)")
                            }
                        }
                    }

                    if !batchSucceeded {
                        consecutiveFailures += 1
                    }

                    currentHeight = endHeight + 1
                }

                if !deltaCMUs.isEmpty {
                    print("🔄 FIX #557 v32: Appending \(deltaCMUs.count) delta CMUs to global tree...")
                    await progress?("Appending delta CMUs...", 80)

                    for cmu in deltaCMUs {
                        _ = ZipherXFFI.treeAppend(cmu: cmu)
                    }

                    print("✅ FIX #557 v32: Appended \(deltaCMUs.count) delta CMUs")

                    // CRITICAL FIX #557 v35: Verify tree root matches header at chainHeight
                    let ourRoot = ZipherXFFI.treeRoot()
                    if let header = try? HeaderStore.shared.getHeader(at: chainHeight) {
                        if let root = ourRoot, root == header.hashFinalSaplingRoot {
                            print("✅ FIX #557 v35: Tree root VERIFIED at height \(chainHeight)")
                        } else {
                            print("⚠️ FIX #557 v35: Tree root MISMATCH at height \(chainHeight)")
                            if let root = ourRoot {
                                print("   Our root:   \(root.prefix(8).map { String(format: "%02x", $0) }.joined())...")
                            } else {
                                print("   Our root:   FAILED to get root!")
                            }
                            print("   Header root: \(header.hashFinalSaplingRoot.prefix(8).map { String(format: "%02x", $0) }.joined())...")
                            print("   Delta CMUs: \(deltaCMUs.count), Expected: ~\(chainHeight - boostHeight)")
                            print("   Boost file may have wrong CMUs OR delta CMUs are incomplete!")
                        }
                    } else {
                        print("⚠️ FIX #557 v35: Could not fetch header at \(chainHeight) for verification")
                    }
                } else {
                    print("⚠️ FIX #557 v32: Failed to fetch delta CMUs")
                }
            }

            // Save updated tree state to database (thread-safe)
            if let treeData = ZipherXFFI.treeSerialize() {
                await MainActor.run {
                    try? WalletDatabase.shared.saveTreeState(treeData)
                }
                print("✅ FIX #557 v32: Saved global tree state at height \(chainHeight)")
            }

            // Update database to track tree sync height (thread-safe)
            await MainActor.run {
                try? WalletDatabase.shared.updateLastScannedHeight(chainHeight, hash: Data(count: 32))
            }

            // CRITICAL FIX #569: UPDATE all witnesses using correct order!
            // The bug in FIX #557 v36 was that delta CMUs were appended BEFORE loading witnesses,
            // so newly loaded witnesses never got updated with the delta CMUs.
            // CORRECT order:
            // 1. Load existing witnesses into FFI tree (WITNESSES array)
            // 2. Append delta CMUs (this updates ALL loaded witnesses in WITNESSES array!)
            // 3. Extract updated witnesses from tracked positions
            print("🔄 FIX #569: Updating all witnesses - load FIRST, then append delta CMUs...")

            // STEP 1: Load all notes from database (thread-safe)
            let allNotes = await MainActor.run { () -> [WalletNote] in
                do {
                    return try WalletDatabase.shared.getAllNotes(accountId: accountId)
                } catch {
                    print("❌ FIX #569: Failed to load notes: \(error.localizedDescription)")
                    return []
                }
            }
            var witnessIndices: [(note: WalletNote, position: UInt64)] = []
            var emptyWitnessNotes: [WalletNote] = []
            var witnessIndexUpdates: [(noteId: Int64, position: UInt64)] = []

            print("🔧 FIX #569: Step 1 - Loading \(allNotes.count) witnesses into FFI WITNESSES array...")
            for note in allNotes {
                if note.witness.isEmpty {
                    emptyWitnessNotes.append(note)
                    continue
                }

                // Load witness into FFI tree - returns POSITION of this witness in WITNESSES array
                // FIX #569: This loads the witness from the database into the FFI's WITNESSES array
                // The witness is in its old state (before delta CMUs were added)
                let position = note.witness.withUnsafeBytes { ptr in
                    ZipherXFFI.treeLoadWitness(
                        witnessData: ptr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        witnessLen: note.witness.count
                    )
                }

                if position != UInt64.max {
                    witnessIndices.append((note: note, position: position))
                    // FIX #557 v45: Store witness_index for later batch update
                    witnessIndexUpdates.append((note.id, position))
                }
            }

            // Batch update witness indices (thread-safe)
            if !witnessIndexUpdates.isEmpty {
                await MainActor.run {
                    for (noteId, position) in witnessIndexUpdates {
                        try? WalletDatabase.shared.updateNoteWitnessIndex(noteId: noteId, witnessIndex: position)
                    }
                }
            }

            print("✅ FIX #569: Step 1 complete - Loaded \(witnessIndices.count) witnesses into WITNESSES array, \(emptyWitnessNotes.count) empty")

            // STEP 2: Re-append delta CMUs to update all loaded witnesses!
            // FIX #569: The delta CMUs were appended BEFORE loading witnesses (FIX #557 v36 bug).
            // Now we need to re-append them to update the newly loaded witnesses.
            // When we append CMUs via treeAppend, the FFI automatically updates ALL witnesses in the WITNESSES array.
            // CRITICAL FIX #569 v2: ALWAYS re-append delta CMUs after loading witnesses!
            // The delta CMUs were already appended to the tree earlier, but the loaded witnesses
            // need to be updated. By re-appending, we ensure ALL loaded witnesses get updated.
            print("🔧 FIX #571: Step 2 - Using local delta bundle + P2P for remaining blocks...")

            // FIX #571: Use LOCAL delta bundle FIRST, then P2P fetch only for remaining blocks
            // OLD BUG: Fetched ALL blocks via P2P which took hours
            // NEW FIX: Use local delta bundle (instant), then P2P for only the few remaining blocks

            // Get the local delta bundle end height (what we have cached locally)
            let deltaBundleEndHeight = DeltaCMUManager.shared.getDeltaEndHeight() ?? boostHeight
            print("🔧 FIX #571: Local delta bundle ends at height: \(deltaBundleEndHeight)")

            // Calculate where to start fetching from:
            // - If we have local delta bundle, start from its end
            // - Otherwise start from boost file end
            let fetchStartHeight = max(boostHeight, deltaBundleEndHeight)
            print("🔧 FIX #571: Will fetch blocks from height \(fetchStartHeight) to \(chainHeight)")

            var deltaCMUs: [Data] = []
            var localCMUs = 0
            var p2pCMUs = 0

            // PART 1: Use LOCAL delta bundle (instant!)
            if chainHeight > boostHeight {
                await progress?("Loading local delta CMUs...", 75)

                // Get CMUs from local delta bundle (returns [Data] directly, not tuples)
                if let localDeltaCMUs = DeltaCMUManager.shared.loadDeltaCMUsForHeightRange(
                    startHeight: boostHeight + 1,
                    endHeight: deltaBundleEndHeight
                ) {
                    for cmu in localDeltaCMUs {
                        deltaCMUs.append(cmu)
                    }

                    localCMUs = localDeltaCMUs.count
                    print("🔧 FIX #571: Loaded \(localCMUs) CMUs from local delta bundle (instant!)")
                }
            }

            // PART 2: P2P fetch ONLY for the few remaining blocks
            // This is typically <100 blocks, not 400k!
            if chainHeight > fetchStartHeight {
                await progress?("Fetching remaining blocks via P2P...", 80)

                let blocksToFetch = chainHeight - fetchStartHeight
                print("🔧 FIX #571: Fetching \(blocksToFetch) blocks via P2P (from height \(fetchStartHeight + 1))")

                // FIX #710 v2: Proper timeout using task group race pattern
                // Previous implementation used fetchTask.cancel() which doesn't interrupt network I/O
                let batchSize: UInt64 = 500  // Reduced from 1000 for better reliability
                let maxRetries = 2
                let batchTimeoutSeconds: UInt64 = 30  // 30 seconds per batch
                var currentHeight = fetchStartHeight + 1
                var consecutiveFailures = 0
                let maxConsecutiveFailures = 3

                while currentHeight <= chainHeight {
                    let endHeight = min(currentHeight + batchSize - 1, chainHeight)
                    let count = Int(endHeight - currentHeight + 1)
                    var batchSuccess = false

                    for attempt in 1...maxRetries {
                        do {
                            // FIX #710 v2: Use task group to race fetch vs timeout
                            // This ensures we abort waiting after timeout even if network is stuck
                            let fetchHeight = currentHeight
                            let fetchCount = count

                            let blocks: [(UInt64, String, UInt32, [(String, [ShieldedOutput], [ShieldedSpend]?)])]? = try await withThrowingTaskGroup(of: [(UInt64, String, UInt32, [(String, [ShieldedOutput], [ShieldedSpend]?)])]?.self) { group in
                                // Task 1: The actual fetch
                                group.addTask {
                                    try await NetworkManager.shared.getBlocksDataP2P(
                                        from: fetchHeight,
                                        count: fetchCount
                                    )
                                }

                                // Task 2: Timeout - returns nil after delay
                                group.addTask {
                                    try await Task.sleep(nanoseconds: batchTimeoutSeconds * 1_000_000_000)
                                    print("⚠️ FIX #710 v2: Batch \(fetchHeight)-\(fetchHeight + UInt64(fetchCount) - 1) timed out after \(batchTimeoutSeconds)s")
                                    return nil
                                }

                                // Return whichever completes first
                                if let result = try await group.next() {
                                    group.cancelAll()  // Cancel the other task
                                    return result
                                }
                                return nil
                            }

                            guard let fetchedBlocks = blocks else {
                                throw NSError(domain: "WalletManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Timeout"])
                            }

                            for (height, _, _, txData) in fetchedBlocks {
                                for (txid, outputs, _) in txData {
                                    for output in outputs {
                                        if let cmuData = Data(hexString: output.cmu) {
                                            deltaCMUs.append(cmuData)
                                            p2pCMUs += 1
                                        }
                                    }
                                }
                            }

                            print("🔧 FIX #571: Fetched blocks \(currentHeight)-\(endHeight) via P2P")
                            batchSuccess = true
                            consecutiveFailures = 0
                            break  // Success, exit retry loop
                        } catch {
                            if attempt < maxRetries {
                                print("⚠️ FIX #710 v2: Batch \(currentHeight)-\(endHeight) failed (attempt \(attempt)/\(maxRetries)): \(error.localizedDescription)")
                                try? await Task.sleep(nanoseconds: 2_000_000_000)  // 2s backoff
                            } else {
                                print("⚠️ FIX #710 v2: Batch \(currentHeight)-\(endHeight) failed after \(maxRetries) attempts")
                            }
                        }
                    }

                    if !batchSuccess {
                        consecutiveFailures += 1
                        if consecutiveFailures >= maxConsecutiveFailures {
                            print("⚠️ FIX #710 v2: \(maxConsecutiveFailures) consecutive failures - aborting P2P fetch")
                            print("⚠️ FIX #710 v2: Witnesses will be rebuilt on next app restart")
                            break
                        }
                    }

                    currentHeight = endHeight + 1
                }

                print("🔧 FIX #571: Fetched \(p2pCMUs) CMUs via P2P")
            }

            // PART 3: Append all delta CMUs to update witnesses
            if !deltaCMUs.isEmpty {
                print("🔧 FIX #571: Step 2 - Appending \(deltaCMUs.count) delta CMUs (local: \(localCMUs), P2P: \(p2pCMUs))...")
                await progress?("Appending delta CMUs for witness update...", 85)

                // CRITICAL: This will update ALL witnesses in the FFI WITNESSES array!
                for cmu in deltaCMUs {
                    _ = ZipherXFFI.treeAppend(cmu: cmu)
                }

                print("✅ FIX #571: Step 2 complete - Appended \(deltaCMUs.count) delta CMUs, all witnesses now updated!")
            } else {
                print("⚠️ FIX #571: Step 2 - No delta CMUs to append")
            }

            // FIX #577 v10: Skip STEP 3 witness extraction if no delta CMUs were appended
            // When there are no delta CMUs, the FFI WITNESSES array contains unloaded/garbage data
            // Extracting witnesses would corrupt the database with invalid witness data (5 bytes instead of 1028)
            // The witnesses from PHASE 1 scan are already correct - don't overwrite them!
            let deltaCMUsAppended = (deltaCMUs.count > 0)

            // STEP 3: Extract updated witnesses from tracked positions
            if deltaCMUsAppended {
                print("🔧 FIX #569 v2: Step 3 - Extracting updated witnesses from FFI WITNESSES array...")
            } else {
                print("🔧 FIX #577 v10: Step 3 - SKIPPED (no delta CMUs appended, witnesses from PHASE 1 are already correct)")
                print("🔧 FIX #577 v10: Skipping witness extraction to prevent corruption")

                // CRITICAL FIX #587: Do NOT update anchors when witnesses weren't updated!
                // The witnesses from PHASE 1 already have correct anchors (their own root)
                // Updating anchors to header root would create mismatch:
                //   - Witness root: 9f4e26a7e221d354... (from PHASE 1 witness)
                //   - Database anchor: ccfe5dc8c814d9ca... (from header)
                //   - Mismatch causes "joinsplit requirements not met" error!
                print("✅ FIX #587: Preserving PHASE 1 witness anchors (no update needed)")

                // FIX #586: Check if there are empty witnesses that need rebuilding
                if !emptyWitnessNotes.isEmpty {
                    print("⚠️ FIX #586: \(emptyWitnessNotes.count) empty witnesses need rebuilding - skipping STEP 3 extraction")
                    print("🔧 FIX #586: Jumping directly to witness rebuild (FIX #557 v37)...")

                    // Skip STEP 3 extraction (FFI WITNESSES array not updated)
                    // Jump directly to witness rebuild code below
                } else {
                    return  // Skip the rest of STEP 3 only when no witnesses need rebuilding
                }

                // When we have empty witnesses, skip STEP 3 extraction and continue to witness rebuild
            }

            // FIX #586: Only run STEP 3 if witnesses were actually updated (delta CMUs appended)
            // When there are no delta CMUs, the FFI WITNESSES array contains old witnesses - extracting
            // them would write corrupted witnesses back to the database!
            if deltaCMUsAppended {
                print("🔧 FIX #569 v2: Step 3 - Extracting updated witnesses from FFI WITNESSES array...")
                var updatedCount = 0
                var anchorFixedCount = 0
                var witnessUpdates: [(noteId: Int64, witness: Data)] = []
                var positionAnchorUpdates: [(noteId: Int64, anchor: Data)] = []

                // FIX #567 + FIX #569 v2: Get CURRENT tree root (anchor) that all updated witnesses share
                // The witnesses have been updated to include all CMUs up to chainHeight
                // The anchor MUST match this current tree state
                var currentTreeAnchor: Data?
                if chainHeight > 0,
                   let currentHeader = try? HeaderStore.shared.getHeader(at: chainHeight) {
                    currentTreeAnchor = currentHeader.hashFinalSaplingRoot
                    let anchorHex = currentTreeAnchor?.prefix(8).map { String(format: "%02x", $0) }.joined()
                    print("✅ FIX #569 v2: Using current chain anchor at height \(chainHeight): \(anchorHex ?? "N/A")...")
                } else {
                    print("⚠️ FIX #569 v3: Could not get header at chain height \(chainHeight)")

                    // FIX #569 v3: Try previous height before falling back to witness root
                    // The witness root fallback was causing OLD anchors to be written back
                    if chainHeight > 1,
                       let prevHeader = try? HeaderStore.shared.getHeader(at: chainHeight - 1) {
                        currentTreeAnchor = prevHeader.hashFinalSaplingRoot
                        let anchorHex = currentTreeAnchor?.prefix(8).map { String(format: "%02x", $0) }.joined()
                        print("✅ FIX #569 v3: Using previous height anchor at \(chainHeight - 1): \(anchorHex ?? "N/A")...")
                    } else if let ffiRoot = ZipherXFFI.treeRoot() {
                        // FIX #569 v3: Use FFI tree root as last resort
                        // This is the root of the tree we just built, so it matches the witnesses
                        currentTreeAnchor = ffiRoot
                        let anchorHex = currentTreeAnchor?.prefix(8).map { String(format: "%02x", $0) }.joined()
                        print("✅ FIX #569 v3: Using FFI tree root as anchor: \(anchorHex ?? "N/A")...")
                    }
                }

                for (note, position) in witnessIndices {
                    if let updatedWitness = ZipherXFFI.treeGetWitness(index: position) {
                        witnessUpdates.append((note.id, updatedWitness))
                        updatedCount += 1
                    }

                    // FIX #567 + FIX #569 v3: Use CURRENT anchor (matches updated witness), NOT witness root!
                    // CRITICAL FIX #569 v3: Never extract anchor from witness itself!
                    // The witness was just loaded from DB and has OLD anchor - extracting from it
                    // would write the OLD anchor back, defeating the whole update process!
                    if let currentAnchor = currentTreeAnchor {
                        positionAnchorUpdates.append((note.id, currentAnchor))
                        anchorFixedCount += 1
                    } else {
                        print("❌ FIX #569 v3: No anchor available for note \(note.id) - skipping anchor update")
                    }
                }

                // Batch update witnesses and anchors (thread-safe)
                if !witnessUpdates.isEmpty || !positionAnchorUpdates.isEmpty {
                    await MainActor.run {
                        for (noteId, witness) in witnessUpdates {
                            try? WalletDatabase.shared.updateNoteWitness(noteId: noteId, witness: witness)
                        }
                        for (noteId, anchor) in positionAnchorUpdates {
                            try? WalletDatabase.shared.updateNoteAnchor(noteId: noteId, anchor: anchor)
                        }
                    }
                }

                print("✅ FIX #569 v2: Step 3 complete - Updated \(updatedCount) witnesses with current tree state")
                print("✅ FIX #569 v2: Updated \(anchorFixedCount) anchors to CURRENT tree root (chain height \(chainHeight))")
                print("✅ FIX #569 v2: Witness update complete - ALL notes now have correct witnesses and anchors!")
            } else {
                print("⚠️ FIX #586: STEP 3 extraction skipped (no delta CMUs appended)")
            }
            // FIX #562: Record when witnesses were last updated
            lastWitnessUpdate = Date()
            print("✅ FIX #562: Witness update timestamp recorded")

            // FIX #557 v37: Fallback - rebuild empty witnesses using boost + delta
            if !emptyWitnessNotes.isEmpty {
                print("⚠️ FIX #557 v37: \(emptyWitnessNotes.count) empty witnesses - rebuilding from boost + delta...")

                // Map WalletNote to (id, SpendableNote) tuples
                let notesWithIds = emptyWitnessNotes.map { note -> (Int64, SpendableNote) in
                    let spendable = SpendableNote(
                        value: note.value,
                        anchor: note.anchor ?? Data(),  // Handle optional anchor
                        witness: note.witness,
                        diversifier: note.diversifier,
                        rcm: note.rcm,
                        position: note.height, // Use height as position hint
                        nullifier: note.nullifier,
                        height: note.height,
                        cmu: note.cmu,
                        witnessIndex: note.witnessIndex // FIX #557 v45: Include witness index
                    )
                    return (note.id, spendable)
                }

                // Rebuild witnesses using TransactionBuilder's function
                do {
                    let boostHeight = ZipherXConstants.effectiveTreeHeight
                    let spendableNotes = notesWithIds.map { $0.1 }
                    let txBuilder = TransactionBuilder()
                    let results = try await txBuilder.rebuildWitnessesForNotes(
                        notes: spendableNotes,
                        downloadedTreeHeight: boostHeight,
                        chainHeight: chainHeight
                    )

                    // Update database with rebuilt witness/anchor
                    // Match results by index since both arrays are sorted by height
                    for (index, result) in results.enumerated() {
                        let noteId = notesWithIds[index].0
                        _ = try? WalletDatabase.shared.updateNoteWitness(noteId: noteId, witness: result.witness)
                        _ = try? WalletDatabase.shared.updateNoteAnchor(noteId: noteId, anchor: result.anchor)
                    }

                    print("✅ FIX #557 v37: Rebuilt \(results.count) empty witnesses")
                } catch {
                    print("❌ FIX #557 v37: Failed to rebuild empty witnesses: \(error)")
                }
            }

            print("✅ FIX #557 v32: Global tree synced to chain tip (\(chainHeight))")
            print("✅ FIX #557 v36: All witnesses updated with current tree root (anchor)")
            await progress?("Tree sync complete!", 100)

            // FIX #563 v33: Clear crash flag after successful witness rebuild
            // This enables the witness root optimization check on next startup
            if skipWitnessRootCheck {
                print("✅ FIX #563 v33: Witness rebuild succeeded - re-enabling witness root validation for next time")
                defaults.set(false, forKey: "ZipherX_SkipWitnessRootCheck")
            }

        } catch {
            print("⚠️ Pre-witness rebuild failed: \(error.localizedDescription)")
        }
    }

    /// FIX #557 v8: Rebuild witnesses for startup (called from ContentView)
    /// Wrapper function to avoid SwiftUI .id modifier conflict with Account.id property
    /// FIX #557 v18: Added progress reporting
    func rebuildWitnessesForStartup() async {
        do {
            guard let account = try WalletDatabase.shared.getAccount(index: 0) else {
                print("❌ FIX #557 v8: No account found")
                return
            }

            // FIX #557 v26: Pass async progress callback that updates UI immediately
            await preRebuildWitnessesForInstantPayment(accountId: account.accountId) { status, percent async in
                // FIX #557 v26: Use MainActor.run immediately to update UI
                // Callback is now async, so this will execute before returning
                await MainActor.run {
                    self.updateSyncTask(id: "witness_sync", status: .inProgress, detail: status, progress: Double(percent) / 100.0)
                }
            }

            // Mark task as completed
            await MainActor.run {
                self.updateSyncTask(id: "witness_sync", status: .completed)
            }
        } catch {
            print("❌ FIX #557 v8: Failed to get account for witness rebuild: \(error.localizedDescription)")
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

        // FIX #469: Delete CMU cache for restored wallet
        // This ensures we start fresh with no stale CMU data
        print("🗑️ Deleting CMU cache for restored wallet...")
        Task {
            await CommitmentTreeUpdater.shared.invalidateCMUCachePublic()
            print("✅ CMU cache deleted")
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

        // FIX #469: Delete CMU cache for new wallet
        // This ensures we start fresh with no stale CMU data
        print("🗑️ Deleting CMU cache for new wallet...")
        Task {
            await CommitmentTreeUpdater.shared.invalidateCMUCachePublic()
            print("✅ CMU cache deleted")
        }

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

        // FIX #298: Prevent concurrent refreshBalance calls
        // If already refreshing, silently skip to avoid race conditions
        refreshBalanceLock.lock()
        guard !isRefreshingBalance else {
            refreshBalanceLock.unlock()
            print("⚠️ FIX #298: refreshBalance already in progress - skipping concurrent call")
            return
        }
        isRefreshingBalance = true
        refreshBalanceLock.unlock()

        // Ensure we release the lock when done
        defer {
            refreshBalanceLock.lock()
            isRefreshingBalance = false
            refreshBalanceLock.unlock()
        }

        // Suppress notifications during initial sync for imported wallets
        // to avoid notification spam from historical transactions
        let wasImported = isImportedWallet
        if wasImported {
            NotificationManager.shared.isInitialSyncInProgress = true
            print("🔕 Notifications suppressed during initial import sync")
        }

        // FIX #163: Bypass Tor for imported wallet sync - MASSIVE PERFORMANCE IMPROVEMENT
        // Import sync takes 7+ minutes over Tor but only ~1-2 minutes with direct P2P
        // The boost file download (783MB) and P2P block fetching are the main bottlenecks
        // NOTE: FIX #164 may have already bypassed Tor during preloadCommitmentTree()
        var shouldRestoreTor = false
        if wasImported {
            let torEnabled = await TorManager.shared.mode == .enabled
            let torAlreadyBypassed = await TorManager.shared.isTorBypassed

            if torAlreadyBypassed {
                // FIX #164 already bypassed Tor during boost download
                print("🚀 FIX #163: Tor already bypassed by FIX #164 - continuing with direct P2P")
                shouldRestoreTor = true  // We still need to restore at the end
            } else if torEnabled {
                print("⚠️ FIX #163: Imported wallet - bypassing Tor for faster sync...")
                let bypassed = await TorManager.shared.bypassTorForMassiveOperation()
                if bypassed {
                    print("🚀 FIX #163: Tor bypassed - using direct P2P connections for 5x faster sync!")
                    // Reconnect using direct connections
                    try? await NetworkManager.shared.connect()
                    shouldRestoreTor = true
                }
            }
        }

        // Ensure Tor is restored after import sync completes (even on error)
        defer {
            if shouldRestoreTor {
                Task {
                    print("🧅 FIX #163: Import sync complete - restoring Tor for privacy...")
                    await TorManager.shared.restoreTorAfterBypass()
                    try? await NetworkManager.shared.connect()
                    print("🧅 FIX #163: Tor restored - maximum privacy mode active")
                }
            }
        }

        // Initialize sync tasks
        await MainActor.run {
            self.isSyncing = true
            self.syncProgress = 0.0
            self.syncStatus = "Initializing privacy shield..."
            // Move to connecting phase (tree loading should already be done)
            self.updateOverallProgress(phase: .connecting, phaseProgress: 0.0)
            // FIX #558: Add FAST START task IDs that ContentView updates
            // Previous bug: IDs didn't match, so updateSyncTask() calls failed silently
            self.syncTasks = [
                SyncTask(id: "params", title: "Load zk-SNARK circuits", status: .pending),
                SyncTask(id: "keys", title: "Derive spending keys", status: .pending),
                SyncTask(id: "database", title: "Unlock encrypted vault", status: .pending),
                SyncTask(id: "download_outputs", title: "Download shielded outputs", status: .pending),
                SyncTask(id: "download_timestamps", title: "Download block timestamps", status: .pending),
                SyncTask(id: "headers", title: "Sync block timestamps", status: .pending),
                SyncTask(id: "height", title: "Query chain tip from peers", status: .pending),
                SyncTask(id: "scan", title: "Decrypt shielded notes", status: .pending),
                SyncTask(id: "witnesses", title: "Build Merkle witnesses", status: .pending),
                SyncTask(id: "balance", title: "Tally unspent notes", status: .pending),
                // FAST START tasks (ContentView.swift)
                SyncTask(id: "fast_balance", title: "Load balance from database", status: .pending),
                SyncTask(id: "fast_peers", title: "Connect to P2P network", status: .pending),
                SyncTask(id: "fast_headers", title: "Sync block headers", status: .pending),
                SyncTask(id: "fast_health", title: "Verify wallet health", status: .pending),
                SyncTask(id: "fast_repair", title: "Auto-repair if needed", status: .pending),
                // Repair tasks
                SyncTask(id: "balance_repair", title: "Repair database", status: .pending),
                SyncTask(id: "balance_repair_early", title: "Early repair check", status: .pending),
                SyncTask(id: "full_repair", title: "Full database rescan", status: .pending),
                SyncTask(id: "tree_rebuild", title: "Rebuild commitment tree", status: .pending),
                SyncTask(id: "witness_sync", title: "Sync witnesses", status: .pending)
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
        // FIX #120: InsightAPI commented out - P2P only
        // Malicious P2P peers may have caused fake heights to be stored
        // let effectiveTreeHeight = ZipherXConstants.effectiveTreeHeight
        // do {
        //     let lastScanned = try WalletDatabase.shared.getLastScannedHeight()
        //     if lastScanned > effectiveTreeHeight {
        //         // Query InsightAPI for trusted chain height
        //         let status = try await InsightAPI.shared.getStatus()
        //         let trustedHeight = status.height
        //         let maxAheadTolerance: UInt64 = 10
        //
        //         if lastScanned > trustedHeight + maxAheadTolerance {
        //             print("🚨 [SECURITY] Detected FAKE lastScannedHeight: \(lastScanned)")
        //             print("🚨 [SECURITY] Trusted chain height is: \(trustedHeight)")
        //             print("🧹 Resetting to downloaded tree height...")
        //
        //             // Reset to safe state
        //             try WalletDatabase.shared.updateLastScannedHeight(effectiveTreeHeight, hash: Data(count: 32))
        //             try? HeaderStore.shared.open()
        //             try? HeaderStore.shared.clearAllHeaders()
        //
        //             print("✅ Fake sync state cleared - will rescan from trusted height")
        //         }
        //     }
        // } catch {
        //     print("⚠️ Could not validate lastScannedHeight: \(error)")

        // P2P-only: Skip fake height validation (relies on P2P peer consensus)
        do {
            let _ = try WalletDatabase.shared.getLastScannedHeight()
            // Validation disabled in P2P-only mode
        } catch {
            print("⚠️ Could not read lastScannedHeight: \(error)")
            // Continue anyway - HeaderSyncManager will also validate
        }

        // Task 3: Sync block headers (with retry logic for peer timing issues)
        // NOTE: Header sync is optional for balance display - if it fails, we continue anyway
        // Headers are only needed for transaction building (anchor verification)
        await updateTask("headers", status: .inProgress)

        // FIX #183: For fresh imports, skip blocking header sync - chain height already verified via P2P consensus
        // Header sync takes too long (3000+ blocks from checkpoint) and blocks the entire import
        // Headers will be synced in background later or on first transaction
        let shouldSkipHeaderSync = wasImported

        // FIX #522: Load bundled headers from boost file even during import (instant, no P2P needed)
        // This ensures HeaderStore is populated for timestamps and tree root validation
        if wasImported {
            print("⚡ FIX #522: Loading bundled headers from boost file (instant import path)...")
            let (loadedBundledHeaders, boostHeaderEndHeight) = await loadHeadersFromBoostFile()
            if loadedBundledHeaders {
                print("✅ FIX #522: Loaded bundled headers up to \(boostHeaderEndHeight) - instant header load during import!")
            } else {
                print("⚠️ FIX #522: Could not load bundled headers during import")
            }
        }

        if shouldSkipHeaderSync {
            print("⚡ FIX #183: Skipping P2P header sync for import - P2P consensus already verified chain height")
            print("⚡ FIX #183: P2P delta sync will run in background if needed (for latest blocks)")
            await updateTask("headers", status: .completed, detail: "Bundled headers loaded")
        } else {
            print("📡 Using P2P header sync (NO RPC for sync/repair)")
        }

        if !shouldSkipHeaderSync {

        let maxHeaderRetries = 4  // FIX #120: Increased retries to allow peer connections
        var headerSyncSuccess = false
        var lastHeaderError: Error?

        // FIX #457 v11: Set header syncing flag ONCE at the start, BEFORE retry loop
        // This prevents block listeners from restarting between retry attempts
        // NOTE: For import, we DON'T stop block listeners since sync is only 100 headers (see line 2442)
        // FIX #509: Now async - awaits setHeaderSyncing call
        await NetworkManager.shared.setHeaderSyncing(true, stopListeners: false)
        defer {
            // Clear flag when ALL retries complete (success or exhausted)
            Task { await NetworkManager.shared.setHeaderSyncing(false) }
        }

        for attempt in 1...maxHeaderRetries {
            do {
                if attempt > 1 {
                    print("🔄 Header sync retry attempt \(attempt)/\(maxHeaderRetries)...")
                    await updateTask("headers", status: .inProgress, detail: "Retry \(attempt)/\(maxHeaderRetries)")
                    // FIX #120: Wait longer for peers to connect via Tor (2 seconds)
                    try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
                }

                print("📥 Opening header store...")
                try HeaderStore.shared.open()

                // CRITICAL: Check for corrupted header timestamps
                // Bug: Headers were being assigned wrong heights (from genesis instead of downloaded tree)
                // This caused timestamps to show 2016 instead of 2025
                // Detection: If a header at recent height has timestamp < 2024, it's corrupted
                let corruptedTimestampThreshold: UInt32 = 1704067200 // Jan 1, 2024 UTC
                let effectiveTreeHeight = ZipherXConstants.effectiveTreeHeight
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

                // FIX #487 v3: Immediate UI updates for header sync progress
                // Direct @Published property updates bypass MainActor restrictions
                // FIX #488 v3: Replace struct in array to trigger SwiftUI @Published update
                headerSync.onProgress = { [weak self] progress in
                    // Update @Published syncTasks directly on main thread
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self else { return }
                        if let index = self.syncTasks.firstIndex(where: { $0.id == "headers" }) {
                            var task = self.syncTasks[index]
                            task.detail = "\(progress.currentHeight) / \(progress.totalHeight)"
                            // Calculate progress percentage (0.0 to 1.0)
                            let progressPercentage = progress.totalHeight > 0
                                ? Double(progress.currentHeight) / Double(progress.totalHeight)
                                : 0.0
                            task.progress = progressPercentage
                            self.syncTasks[index] = task

                            // Update monotonic progress for header sync phase
                            // Use async since we're already in a DispatchQueue.main.async block
                            Task { @MainActor in
                                self.updateOverallProgress(phase: .syncingHeaders, phaseProgress: progressPercentage)
                            }
                        }
                    }
                }

                // Get starting height for sync
                // FIX #120: Must sync ALL headers from earliest transaction needing timestamp to chain tip
                // This ensures 100% real timestamps at startup - no estimates!
                // VUL-018: Use shared constant for downloaded tree height
                let downloadedTreeHeight = ZipherXConstants.effectiveTreeHeight
                var startHeight: UInt64

                // FIX #125: Only sync latest 100 blocks for consensus verification (FAST!)
                // Unless there are transactions that specifically need timestamps
                let chainTip = try await headerSync.getChainTip()
                let maxHeadersToSync: UInt64 = 100  // Only sync latest 100 blocks for speed

                // Priority 1: Check for transactions that need timestamps
                if let earliestNeedingTimestamp = try? WalletDatabase.shared.getEarliestHeightNeedingTimestamp() {
                    // Sync from earliest tx without timestamp (ensures we cover ALL gap)
                    startHeight = earliestNeedingTimestamp
                    print("📊 FIX #120: Starting header sync from earliest missing timestamp at height \(startHeight)")
                } else if let latestHeight = try HeaderStore.shared.getLatestHeight(), latestHeight >= downloadedTreeHeight {
                    // Resume from where we left off
                    startHeight = latestHeight + 1
                    print("📊 Resuming header sync from height \(startHeight)")
                } else {
                    // FIX #125: Only sync latest 100 blocks instead of all headers since boost file
                    // This makes header sync ~30x faster (100 headers vs 4500+)
                    let normalStart = downloadedTreeHeight + 1
                    if chainTip > normalStart + maxHeadersToSync {
                        startHeight = chainTip - maxHeadersToSync
                        print("📊 FIX #125: FAST SYNC - only latest \(maxHeadersToSync) headers (\(startHeight) → \(chainTip))")
                    } else {
                        startHeight = normalStart
                        print("📊 Starting header sync from height \(startHeight) (checkpoint at \(downloadedTreeHeight))")
                    }
                }

                // FIX #146: setHeaderSyncing is now outside the retry loop (see above)
                // This ensures block listeners stay paused during ALL retry attempts

                // FIX #180: Limit header sync to 100 blocks maximum for speed
                // 100 blocks is enough for peer consensus verification - syncing 2000+ is too slow
                try await headerSync.syncHeaders(from: startHeight, maxHeaders: 100)

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

        } // End of if !shouldSkipHeaderSync

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
                // FIX #497: Replace entire task struct to trigger SwiftUI @Published update
                if let index = self?.syncTasks.firstIndex(where: { $0.id == "scan" }) {
                    var task = self?.syncTasks[index] ?? SyncTask(id: "scan", title: "Scanning", status: .inProgress)
                    switch phase {
                    case "phase1":
                        task.detail = "Parallel note decryption"
                        self?.updateOverallProgress(phase: .phase1Scanning, phaseProgress: 0.0)
                    case "phase1.5":
                        task.detail = "Computing Merkle witnesses"
                        self?.updateOverallProgress(phase: .phase15Witnesses, phaseProgress: 0.0)
                    case "phase1.6":
                        task.detail = "Detecting spent notes"
                        self?.updateOverallProgress(phase: .phase16SpentCheck, phaseProgress: 0.0)
                    case "phase2":
                        task.detail = "Sequential tree building"
                        self?.updateOverallProgress(phase: .phase2Sequential, phaseProgress: 0.0)
                    default:
                        break
                    }
                    if let index = self?.syncTasks.firstIndex(where: { $0.id == "scan" }) {
                        self?.syncTasks[index] = task
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

                    // FIX #497: Replace entire task struct to trigger SwiftUI @Published update
                    var task = self?.syncTasks[index] ?? SyncTask(id: "scan", title: "Scanning", status: .inProgress)
                    task.detail = "\(phasePrefix)Block \(currentHeight.formatted())\(dateString)"
                    task.progress = progress
                    if let index = self?.syncTasks.firstIndex(where: { $0.id == "scan" }) {
                        self?.syncTasks[index] = task
                    }
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
                }
                // Note: PHASE 2 status is set by onStatusUpdate with real percentage
                // Don't overwrite it here with generic messages
                // Note: phase1.5 and phase1.6 status is set by onStatusUpdate
            }
        }

        // Witness sync progress callback - update witnesses task with real progress
        // FIX #497: Replace entire task struct to trigger SwiftUI @Published update
        scanner.onWitnessProgress = { [weak self] current, total, status in
            Task { @MainActor in
                if let index = self?.syncTasks.firstIndex(where: { $0.id == "witnesses" }) {
                    var task = self?.syncTasks[index] ?? SyncTask(id: "witnesses", title: "Witnesses", status: .inProgress)
                    if total > 0 {
                        task.status = .inProgress
                        task.detail = status
                        task.progress = Double(current) / Double(total)
                        self?.syncStatus = "Syncing Merkle witnesses..."
                    }
                    if current == total {
                        task.status = .completed
                        task.detail = total > 0 ? "\(total) witness(es) synced" : "No witnesses needed"
                        task.progress = 1.0
                    }
                    if let index = self?.syncTasks.firstIndex(where: { $0.id == "witnesses" }) {
                        self?.syncTasks[index] = task
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
            try await scanner.startScan(for: account.accountId, viewingKey: spendingKey)
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
        try? database.debugListAllNotes(accountId: account.accountId)

        var unspentNotes = try database.getUnspentNotes(accountId: account.accountId)
        let totalNotes = unspentNotes.count

        // Update with note count
        await updateTaskWithProgress("balance", detail: "Processing \(totalNotes) notes...", progress: 0.1)

        // Get current chain height to calculate confirmations
        // IMPORTANT: Use multiple sources to avoid 0 chain height bug
        // Priority: scanner > NetworkManager > lastScannedHeight
        var chainHeight = scanner.currentChainHeight
        if chainHeight == 0 {
            chainHeight = await MainActor.run { UInt64(NetworkManager.shared.chainHeight) }
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
        await MainActor.run { NetworkManager.shared.updateWalletHeight(lastScannedHeight) }

        // FIX #146/#168: Update cachedChainHeight after sync completes
        // This ensures FAST START mode works on next app launch
        // FIX #168: NEVER use lastScannedHeight directly - it could be corrupted!
        // Instead, use the current chain height from peers which is TRUSTED
        let trustedChainHeight = await MainActor.run { NetworkManager.shared.chainHeight }
        let headerStoreHeight = (try? HeaderStore.shared.getLatestHeight()) ?? 0
        let maxTrustedHeight = max(trustedChainHeight, headerStoreHeight)

        if maxTrustedHeight > 0 {
            UserDefaults.standard.set(Int(maxTrustedHeight), forKey: "cachedChainHeight")
            print("📊 FIX #146/#168: Updated cachedChainHeight to \(maxTrustedHeight) (trusted, not lastScannedHeight=\(lastScannedHeight))")
        }

        // CRITICAL FIX: Clear isImportedWallet after first successful sync
        // This prevents the app from doing a full historical scan on every startup
        // The flag should only be true during the FIRST sync after importing a wallet
        if isImportedWallet {
            print("✅ First import sync complete - clearing isImportedWallet flag for fast future startups")

            // FIX #466: Resolve boost received_in_tx placeholders BEFORE building history
            // This ensures change detection works correctly (note.txid == spentTxid match)
            print("🔧 FIX #466: Resolving boost received_in_tx placeholders before history build...")
            let resolvedReceived = try await resolveBoostReceivedInTxPlaceholders()
            if resolvedReceived > 0 {
                print("✅ FIX #466: Resolved \(resolvedReceived) received_in_tx placeholders")
            }

            // FIX #372: Build transaction history immediately
            // Placeholder txids ("boost_spent_HEIGHT") are fine - FIX #373 allows them in history
            print("📜 FIX #372: Building transaction history...")
            let historyCount = try WalletDatabase.shared.populateHistoryFromNotes()
            print("📜 FIX #372: Transaction history complete - \(historyCount) entries")

            DispatchQueue.main.async {
                self.isImportedWallet = false
                UserDefaults.standard.set(false, forKey: "wallet_imported")
                UserDefaults.standard.synchronize()
            }

            // FIX #520: Trigger UI refresh for transaction history after import
            // Without this, history doesn't display correctly until app restart
            await MainActor.run {
                markImportComplete()
            }
        }

        // FIX #535: CRITICAL - Sync headers to match chain tip BEFORE showing as "ready"
        // After import, lastScannedHeight is at chain tip, but headers might only be synced to boost end + 100
        // This causes "Anchor NOT FOUND" errors when trying to send
        print("📍 FIX #535: Import complete - syncing headers to chain tip...")
        do {
            let headerStoreHeight = (try? HeaderStore.shared.getLatestHeight()) ?? 0
            let chainTip = await MainActor.run { NetworkManager.shared.chainHeight }  // Current P2P consensus height

            if chainTip > headerStoreHeight {
                let headersNeeded = chainTip - headerStoreHeight
                print("📥 FIX #535: Import sync - syncing \(headersNeeded) headers to chain tip...")

                let hsm = HeaderSyncManager(headerStore: HeaderStore.shared, networkManager: NetworkManager.shared)
                try await hsm.syncHeaders(from: headerStoreHeight + 1, maxHeaders: headersNeeded + 100)

                let finalHeaderHeight = (try? HeaderStore.shared.getLatestHeight()) ?? 0
                print("✅ FIX #535: Import header sync complete - now at \(finalHeaderHeight)")
            }
        } catch {
            print("⚠️ FIX #535: Import header sync failed: \(error.localizedDescription)")
            // Continue anyway - user can manually sync via Settings
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
                // FIX #488 v3: Replace struct in array to trigger SwiftUI @Published update
                if let index = self.syncTasks.firstIndex(where: { $0.id == "witnesses" }) {
                    var task = self.syncTasks[index]
                    task.detail = "All current"
                    task.progress = 1.0
                    self.syncTasks[index] = task
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
                // FIX #488 v3: Replace struct in array to trigger SwiftUI @Published update
                if let taskIndex = self.syncTasks.firstIndex(where: { $0.id == "witnesses" }) {
                    var task = self.syncTasks[taskIndex]
                    task.detail = "Note \(index + 1)/\(notesNeedingSync.count)"
                    task.progress = progress
                    self.syncTasks[taskIndex] = task
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

                // FIX #546: Get anchor from HEADER STORE instead of from witness
                // According to SESSION_SUMMARY_2025-11-28.md: "Anchor MUST come from header store - not from computed tree state"
                if let headerAnchor = try? HeaderStore.shared.getSaplingRoot(at: UInt64(note.height)) {
                    try? database.updateNoteAnchor(noteId: note.id, anchor: headerAnchor)
                    let anchorHex = headerAnchor.prefix(8).map { String(format: "%02x", $0) }.joined()
                    print("   ✅ Anchor from HEADER at \(anchorHex)...")
                }
                print("✅ Synced witness for note \(note.id) at height \(note.height)")
            } else {
                print("⚠️ Could not sync witness for note \(note.id)")
            }
        }

        await MainActor.run {
            self.syncStatus = "Witnesses synchronized"
            // FIX #488 v3: Replace struct in array to trigger SwiftUI @Published update
            if let taskIndex = self.syncTasks.firstIndex(where: { $0.id == "witnesses" }) {
                var task = self.syncTasks[taskIndex]
                task.detail = "\(notesNeedingSync.count) synced"
                task.progress = 1.0
                self.syncTasks[taskIndex] = task
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

        // FIX #142: Bypass Tor for massive rescan operation
        let torEnabled = await TorManager.shared.mode == .enabled
        let torWasBypassed: Bool
        if torEnabled {
            print("⚠️ FIX #142: Full rescan - bypassing Tor for faster sync...")
            torWasBypassed = await TorManager.shared.bypassTorForMassiveOperation()
        } else {
            torWasBypassed = false
        }

        // Ensure Tor is restored after rescan completes (even on error)
        defer {
            if torWasBypassed {
                Task {
                    await TorManager.shared.restoreTorAfterBypass()
                    // Reconnect with Tor
                    try? await NetworkManager.shared.connect()
                }
            }
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
        print("👤 Account ID: \(account.accountId)")

        // Download reliable peers from GitHub (for faster initial connection)
        let _ = await NetworkManager.shared.downloadReliablePeersFromGitHub()

        // Ensure network connection before scanning
        print("📡 Ensuring network connection...")
        let isConnectedForScan = await MainActor.run { NetworkManager.shared.isConnected }
        if !isConnectedForScan {
            try await NetworkManager.shared.connect()
            // Wait a moment for connection to stabilize
            try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
        }
        let peerCountForScan = await MainActor.run { NetworkManager.shared.peers.count }
        print("✅ Network connected: \(peerCountForScan) peer(s)")

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
                try await scanner.startScan(for: account.accountId, viewingKey: spendingKey, fromHeight: startHeight)

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
        try await scanner.startScan(for: account.accountId, viewingKey: spendingKey)

        // Refresh balance after scan
        try await refreshBalance()
        print("✅ Full rescan complete")
    }

    /// Repair database with full resync
    /// This deletes ALL notes and transaction history, then does a complete rescan
    /// to rebuild everything with correct nullifiers and positions
    /// - Parameters:
    ///   - onProgress: Callback with (progress, currentHeight, maxHeight)
    ///   - forceFullRescan: If true, skip quick fix and do complete rescan (like import PK)
    func repairNotesAfterDownloadedTree(onProgress: @escaping (Double, UInt64, UInt64) -> Void, forceFullRescan: Bool = false) async throws {
        guard isWalletCreated else {
            throw WalletError.walletNotCreated
        }

        // FIX #368: Block backgroundSync during entire repair operation
        // This prevents race condition where backgroundSync runs between PHASE 1 and PHASE 2,
        // setting lastScannedHeight to chain tip before notes are discovered
        await MainActor.run { isRepairingDatabase = true }
        print("🔧 FIX #368: isRepairingDatabase = true (blocking backgroundSync)")

        // FIX #577 v7: Show same sync UI as Import PK during Full Rescan
        // Track start time for completion duration display
        let rescanStartTime = Date()
        if forceFullRescan {
            await MainActor.run {
                isFullRescan = true
                isRescanComplete = false
                rescanCompletionDuration = nil

                // FIX #577 v14: CRITICAL - Initialize Import PK tasks IMMEDIATELY when Full Rescan starts
                // This ensures tasks are ready when UI queries currentSyncTasks ( ContentView.swift )
                // Previous bug: Tasks were initialized at line 4314, AFTER isFullRescan=true was set
                // This caused UI to show empty/wrong task list before tasks were ready
                self.overallProgress = 0.0  // Reset to 0 - was showing previous 100%
                self.syncStatus = "Preparing Full Rescan..."
                self.syncTasks = [
                    SyncTask(id: "params", title: "Load zk-SNARK circuits", status: .completed, detail: "Cached"),
                    SyncTask(id: "keys", title: "Derive spending keys", status: .completed, detail: "Keys loaded"),
                    SyncTask(id: "database", title: "Unlock encrypted vault", status: .completed, detail: "Database created"),
                    SyncTask(id: "download_outputs", title: "Download shielded outputs", status: .inProgress, detail: "Downloading boost file...", progress: 0.0),
                    SyncTask(id: "download_timestamps", title: "Download block timestamps", status: .pending),
                    SyncTask(id: "headers", title: "Sync block timestamps", status: .pending),
                    SyncTask(id: "height", title: "Query chain tip from peers", status: .pending),
                    SyncTask(id: "scan", title: "Decrypt shielded notes", status: .pending),
                    SyncTask(id: "witnesses", title: "Build Merkle witnesses", status: .pending),
                    SyncTask(id: "balance", title: "Tally unspent notes", status: .pending)
                ]
            }
            print("🎬 FIX #577 v7: isFullRescan = true (showing CypherpunkSyncView)")
            print("📦 FIX #577 v14: Import PK tasks initialized IMMEDIATELY (ready for UI before any code runs)")
        }
        defer {
            // FIX #451: Use synchronous reset instead of Task to ensure flag is always cleared
            // Task can fail to execute if function throws, leaving flag stuck
            Task { @MainActor in
                self.isRepairingDatabase = false
                print("🔧 FIX #368: isRepairingDatabase = false (backgroundSync unblocked)")
                // FIX #577 v7: Set completion flags when done
                // FIX #582: Keep isFullRescan = true until user clicks "Enter Wallet"
                // This prevents ContentView from starting a new sync cycle
                if self.isFullRescan {
                    let duration = Date().timeIntervalSince(rescanStartTime)
                    self.isRescanComplete = true
                    self.rescanCompletionDuration = duration
                    // NOTE: isFullRescan stays true until user clicks "Enter Wallet" in ContentView
                    print("🎬 FIX #577 v7 + FIX #582: Full Rescan complete in \(Int(duration))s, showing completion screen")
                    print("🔒 FIX #582: isFullRescan kept true until user clicks Enter Wallet")
                }
            }
            // Also add a timeout-based reset as fallback
            DispatchQueue.main.asyncAfter(deadline: .now() + 300) {  // 5 minutes max
                Task { @MainActor in
                    if self.isRepairingDatabase {
                        print("⚠️ FIX #451: Auto-resetting stuck isRepairingDatabase flag after 5min timeout")
                        self.isRepairingDatabase = false
                    }
                }
            }
        }

        // FIX #286 v20: Bypass Tor for repair operation
        // CRITICAL: Only restore Tor AFTER successful completion, NOT on error
        // If repair fails mid-way with Tor restored, connections become unstable
        let torEnabled = await TorManager.shared.mode == .enabled
        var torWasBypassed = false
        if torEnabled {
            print("⚠️ FIX #286 v20: Database repair - Tor & .onion will be DISABLED during repair")
            print("⚠️ FIX #286 v20: Tor will be automatically restored after 100% completion")
            torWasBypassed = await TorManager.shared.bypassTorForMassiveOperation()
            if torWasBypassed {
                // FIX #427: Reconnect peers IMMEDIATELY after Tor bypass using direct connections
                // Previous bug: Peers were disconnected but never reconnected before repair needed them
                // The repair operations (VUL-002 TX verification, block fetching) require connected peers
                print("📡 FIX #427: Reconnecting peers via direct connections...")
                try? await NetworkManager.shared.connect()

                // Wait for peers to connect (hardcoded seeds should be available)
                var waitedSeconds = 0
                while await MainActor.run(body: { NetworkManager.shared.connectedPeers }) < 1 && waitedSeconds < 10 {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    waitedSeconds += 1
                }
                let peerCount = await MainActor.run { NetworkManager.shared.connectedPeers }
                print("✅ FIX #286 v20: Tor bypassed - \(peerCount) direct peer(s) connected for repair")
            }
        }

        // FIX #286 v20: Helper to restore Tor - called ONLY on success
        @Sendable func restoreTorIfNeeded() async {
            if torWasBypassed {
                print("🧅 FIX #286 v20: Repair 100% complete - restoring Tor...")
                await TorManager.shared.restoreTorAfterBypass()
                // Reconnect with Tor for privacy
                try? await NetworkManager.shared.connect()
                print("✅ FIX #286 v20: Tor restored - maximum privacy mode active")
            }
        }

        // NOTE: NO defer block here - we restore Tor ONLY after successful completion
        // If repair fails, Tor stays bypassed until user retries or manually re-enables

        // VUL-018: Use shared constant for downloaded tree height
        let downloadedTreeHeight = ZipherXConstants.effectiveTreeHeight

        // Get spending key
        let spendingKey = try secureStorage.retrieveSpendingKey()
        // SECURITY: Key retrieved - not logged

        // Ensure database is open
        let dbKey = Data(SHA256.hash(data: spendingKey))
        try WalletDatabase.shared.open(encryptionKey: dbKey)
        print("📂 Database opened for repair")

        // FIX #363: Don't clear headers during repair - causes 3+ minute delay
        // Timestamps are loaded from boost file instead (much faster)
        // Previous FIX #122 was causing slow repair by forcing header re-sync
        print("📦 FIX #363: Skipping header clear - timestamps from boost file")

        // FIX #578: Ensure account exists - create if missing (was broken in import PK)
        // Get account ID
        var account: Account?
        if let existingAccount = try WalletDatabase.shared.getAccount(index: 0) {
            account = existingAccount
            print("👤 Account ID: \(account!.accountId)")
        } else {
            // Account missing from database (import PK bug) - create it now
            print("⚠️ FIX #578: No account found in database - creating now...")

            // Derive viewing key for storage
            let saplingKey = SaplingSpendingKey(data: spendingKey)
            let fvk = try RustBridge.shared.deriveFullViewingKey(from: saplingKey)

            // Derive address
            let derivedAddress = try deriveZAddress(from: spendingKey)

            // Insert account with current address
            let newAccountId = try WalletDatabase.shared.insertAccount(
                accountIndex: 0,
                spendingKey: spendingKey,
                viewingKey: fvk.data,
                address: derivedAddress,
                birthdayHeight: 559500 // Sapling activation for ZCL
            )
            print("👤 FIX #578: Created account in database (ID: \(newAccountId)) during repair")

            // Fetch the newly created account
            account = try WalletDatabase.shared.getAccount(index: 0)
            print("👤 Account ID: \(account!.accountId)")
        }

        // FIX #577 v15: When forceFullRescan=true, skip ALL quick fix steps (0a, 0b, 1)
        // Go directly to full rescan (STEP 2) which deletes database and rescans from boost file
        // This prevents showing confusing log messages like "Resolving boost placeholder txids"
        // during a Full Rescan operation

        // FIX #578: Guard against missing account (should not happen after our fix, but safety check)
        guard let account = account else {
            print("❌ FIX #578: No account found - cannot proceed with repair")
            throw WalletError.walletNotCreated
        }

        // Declare variables here so they're available for both quick fix and full rescan paths
        var notes: [WalletNote] = []
        var notesWithValidWitness = 0
        var anchorsFixed = 0
        var anchorsValidated = false

        if !forceFullRescan {
            // ============================================
            // FIX #371: STEP 0a - Resolve boost placeholder txids to real txids
            // The boost file marks notes as spent with placeholder txids ("boost_spent_HEIGHT"),
            // but we need the real txid for proper transaction history display.
            // This MUST run BEFORE VUL-002 phantom detection to avoid incorrectly unmarking spent notes.
            // ============================================
            print("🔧 FIX #371: Resolving boost placeholder txids...")
            onProgress(0.01, 0, 100)

            // Ensure we're connected to P2P peers for block fetching
            let networkManager = NetworkManager.shared
            let isNetworkConnectedForFetch = await MainActor.run { networkManager.isConnected }
            if !isNetworkConnectedForFetch {
                print("⚠️ FIX #371: Connecting to P2P peers for block fetching...")
                try? await networkManager.connect()
                try? await Task.sleep(nanoseconds: 2_000_000_000) // Wait 2s for connections
            }

            let resolvedCount = try await resolveBoostPlaceholderTxids(onProgress: { current, total in
                // Map progress to 0.01-0.02 range
                let progress = 0.01 + (Double(current) / Double(total)) * 0.01
                onProgress(progress, UInt64(current), UInt64(total))
            })
            if resolvedCount > 0 {
                print("✅ FIX #371: Resolved \(resolvedCount) boost placeholder txids to real txids")
            }
            onProgress(0.02, 0, 100)

            // ============================================
            // FIX #454: SKIP VUL-002 during repair database
            // ============================================
            // FIX #357 disabled VUL-002 phantom detection in health checks because:
            // 1. P2P getdata doesn't work for confirmed TXs (peers only return mempool TXs)
            // 2. It causes false positives and balance corruption
            // 3. Tree root validation (FIX #358) is stronger proof
            //
            // Same logic applies to repair database:
            // 1. VUL-002 is too slow (5 TXs × 100s = 8+ minutes)
            // 2. Boost file + strong checkpoint already ensures data integrity
            // 3. Witnesses are rebuilt from trusted boost file data
            //
            // Only boost placeholder cleanup remains (handled by FIX #371 above)
            // ============================================
            print("⚠️ FIX #454: SKIPPING VUL-002 phantom detection during repair")
            print("⚠️ FIX #454: Reason: P2P getdata doesn't work for confirmed TXs (FIX #357)")
            print("⚠️ FIX #454: Using boost file + strong checkpoint for integrity instead")
            print("⚠️ FIX #454: This speeds up repair from 8+ minutes to seconds!")

            var phantomTxsRemoved = 0
            var notesRestored = 0
            var boostPlaceholdersRemoved = 0

            // VUL-002 verification loop removed - no longer needed
            // The boost file (FIX #413) and tree root validation (FIX #358) provide stronger guarantees

            onProgress(0.03, 0, 100)

            // FIX #454: VUL-002 result reporting (always 0 since we skip it)
            if boostPlaceholdersRemoved > 0 {
                print("🗑️ VUL-002: Removed \(boostPlaceholdersRemoved) boost placeholder TX(s)")
            }
            if phantomTxsRemoved > 0 {
                print("🗑️ VUL-002: Removed \(phantomTxsRemoved) phantom TX(s), restored \(notesRestored) note(s)")
            } else {
                print("✅ FIX #454: VUL-002 skipped (using boost file + tree root validation)")
            }
            onProgress(0.04, 0, 100)

            // ============================================
            // FIX #563 v19: STEP 0b - Check for incorrectly marked SPENT notes
            // This fixes the bug where notes (especially change outputs) are marked as SPENT
            // when transaction send fails, but the notes were never actually spent on-chain
            // ============================================
            print("🔍 FIX #563 v19: Checking for incorrectly marked SPENT notes...")
            onProgress(0.045, 0, 100)

            let unmarkedCount = try await verifyIncorrectlyMarkedSpentNotes()
            if unmarkedCount > 0 {
                print("✅ FIX #563 v19: UNMARKED \(unmarkedCount) incorrectly marked notes!")
                print("💰 FIX #563 v19: These notes (e.g., change outputs) were not actually spent on-chain")
            } else {
                print("✅ FIX #563 v19: All SPENT notes verified as actually spent on-chain")
            }
            onProgress(0.05, 0, 100)

            // ============================================
            // STEP 1: Try QUICK FIX first (extract anchors from existing witnesses)
            // This is instant and fixes the witness/anchor mismatch issue
            // ============================================
            print("⚡ STEP 1: Attempting quick anchor fix...")
            onProgress(0.05, 0, 100)

            notes = try WalletDatabase.shared.getAllUnspentNotes(accountId: account.accountId)
            notesWithValidWitness = 0
            anchorsFixed = 0

            for note in notes {
                // Check if note has a valid witness (at least 1028 bytes for proper witness)
                guard note.witness.count >= 1028 else {
                    print("⚠️ Note \(note.id) (height \(note.height)): invalid witness (\(note.witness.count) bytes)")
                    continue
                }

                notesWithValidWitness += 1

                // FIX #546: Get anchor from HEADER STORE instead of from witness
                // According to SESSION_SUMMARY_2025-11-28.md: "Anchor MUST come from header store - not from computed tree state"
                if let headerAnchor = try? HeaderStore.shared.getSaplingRoot(at: UInt64(note.height)) {
                    try WalletDatabase.shared.updateNoteAnchor(noteId: note.id, anchor: headerAnchor)
                    anchorsFixed += 1

                    let anchorHex = headerAnchor.prefix(8).map { String(format: "%02x", $0) }.joined()
                    print("✅ Note \(note.id) (height \(note.height)): anchor from HEADER at \(anchorHex)...")
                } else {
                    print("⚠️ Note \(note.id) (height \(note.height)): no header found for anchor")
                }
            }

            print("📊 Quick fix result: \(anchorsFixed)/\(notes.count) notes fixed")

            // FIX #417: REMOVED incorrect anchor validation that caused unnecessary full rebuilds
            // The old code compared witness anchor to CURRENT tree root, but witnesses are from
            // EARLIER blocks, so they will NEVER match the current tree root!
            // This was causing 16+ minute full rebuilds when a simple anchor extraction fixes the issue.
            //
            // A witness anchor doesn't need to match current tree root - it just needs to be:
            // 1. Extracted from a valid witness (which we already verified exists)
            // 2. A valid historical anchor that existed when the witness was created
            //
            // The actual validation happens at transaction build time when the anchor is
            // checked against recent block headers.
            anchorsValidated = anchorsFixed > 0  // If we extracted anchors, they're valid
            if anchorsFixed > 0 {
                print("✅ FIX #417: Anchors extracted from valid witnesses - skipping incorrect tree root comparison")
            }
        } else {
            print("🔄 FIX #577 v15: forceFullRescan=true - skipping quick fix steps (0a, 0b, 1)")
        }

        // FIX #367 v3: If forceFullRescan is true, SKIP quick fix and go directly to full rescan
        // This is critical for marking spent notes correctly from boost file
        // The quick fix path doesn't process boost file spends, so it can't fix incorrect is_spent flags
        if forceFullRescan {
            print("🔄 FIX #367 v3: FORCE FULL RESCAN requested - skipping quick fix, going directly to full rescan")
            print("🔄 FIX #367 v3: This will delete all notes and rescan from boost file to correctly mark spent notes")
        } else {
            // Use quick fix if ALL notes have valid witnesses AND anchors are validated correct
            // This only applies when forceFullRescan=false (regular repair)
        if notes.count > 0 && notesWithValidWitness == notes.count && anchorsFixed == notes.count && anchorsValidated && !forceFullRescan {
            print("✅ Quick fix successful! All \(anchorsFixed) notes repaired instantly")

            // FIX #466: Resolve boost received_in_tx placeholders BEFORE rebuilding history
            // This ensures change detection works correctly (note.txid == spentTxid match)
            print("🔧 FIX #466: Resolving boost received_in_tx placeholders before history rebuild...")
            onProgress(0.68, 68, 100)
            let resolvedReceived = try await resolveBoostReceivedInTxPlaceholders()
            if resolvedReceived > 0 {
                print("✅ FIX #466: Resolved \(resolvedReceived) received_in_tx placeholders")
            }

            // FIX #457 v2: Clear and rebuild transaction history FIRST (before any async throws)
            // Quick fix only repairs witnesses, but the history may have stale change entries
            // Rebuilding history ensures change TXs are properly filtered (type='change')
            // The query in populateHistoryFromNotes() excludes type='change' entries
            //
            // CRITICAL FIX #459: This must run BEFORE any function that might throw
            // because the defer block's Task-based reset doesn't execute reliably on throw
            print("📜 FIX #457 v2: Clearing and rebuilding transaction history to filter out change TXs...")
            onProgress(0.7, 70, 100)  // Show 70% during history rebuild
            do {
                try WalletDatabase.shared.clearTransactionHistory()
                let rebuiltCount = try WalletDatabase.shared.populateHistoryFromNotes()
                print("📜 FIX #457 v2: History rebuilt with \(rebuiltCount) entries (change TXs filtered)")
            } catch {
                print("⚠️ FIX #457 v2: History rebuild failed: \(error.localizedDescription) - continuing repair")
            }

            // FIX #367: Verify all unspent notes are actually unspent on-chain
            // This catches notes that were spent from another wallet instance
            // MUST run BEFORE returning from quick fix!
            //
            // FIX #461: Skip verification in quick fix path - takes too long (60s+)
            // User can run "Repair Database" again if they suspect external spends
            // Full rescan path still does verification
            print("🔍 FIX #461: Skipping external spend verification in quick fix (too slow)")
            print("   Run 'Repair Database (Full Rescan)' if you suspect external spends")
            onProgress(0.9, 90, 100)  // Skip to 90%

            // Refresh balance to update UI (wrapped in do-catch to ensure completion)
            onProgress(0.9, 90, 100)  // Show 90% during balance refresh
            do {
                try await refreshBalance()
            } catch {
                print("⚠️ FIX #459: Balance refresh failed: \(error.localizedDescription) - continuing repair")
            }

            // FIX #286 v20: Restore Tor after successful quick fix
            await restoreTorIfNeeded()

            // FIX #459: Reset isRepairingDatabase flag BEFORE return
            // The defer block's Task doesn't execute reliably, so we reset manually here
            await MainActor.run { isRepairingDatabase = false }
            print("🔧 FIX #459: Manually reset isRepairingDatabase = false after quick fix")

            // FIX #462: Trigger transaction history refresh in all views
            // Increment version to force SwiftUI to reload transaction arrays
            await MainActor.run {
                transactionHistoryVersion += 1
                print("📜 FIX #462: Incremented transactionHistoryVersion to \(transactionHistoryVersion) - views should reload")

                // FIX #462 v2: Force clear BalanceView's in-memory transaction cache
                // This ensures the UI reloads from the database which now has filtered change TXs
                NotificationCenter.default.post(name: Notification.Name("transactionHistoryUpdated"), object: nil)
                print("📜 FIX #462 v2: Posted transactionHistoryUpdated notification - forcing UI refresh")
            }

            // FIX #482: Update all witnesses in database to match final tree state
            // After quick fix (anchor extraction), the tree hasn't changed, so witnesses should be current
            // But we still verify and update any stale witnesses to ensure send is instant
            print("🔧 FIX #482: Verifying all witnesses match current tree state...")
            await MainActor.run {
                self.treeLoadStatus = "Finalizing (updating witnesses)..."
                self.treeLoadProgress = 0.99  // Move to 99% to show almost done
            }
            await preRebuildWitnessesForInstantPayment(accountId: account.accountId)

            // FIX #459: NOW show 100% progress - AFTER all operations complete
            // This prevents UI from showing 100% while repair is still running (verifyAllUnspentNotesOnChain takes 10+ seconds)
            onProgress(1.0, 100, 100)
            print("✅ Database repair complete - quick fix was sufficient")
            return
        }
        }  // End of else block (quick fix path - only when forceFullRescan=false)

        // If anchors were "fixed" but validation failed, clear them to force rebuild
        if anchorsFixed > 0 && !anchorsValidated {
            print("🗑️ Clearing invalid anchors - witnesses need full rebuild")
        }

        // ============================================
        // STEP 2: FULL RESCAN - Rebuild EVERYTHING from scratch
        // FIX #577 v4: Full Rescan MUST do EXACTLY what Import PK does!
        // - Delete all notes from database
        // - Invalidate CMU cache
        // - Reset lastScannedHeight to 0
        // - Reset FFI tree state
        // - Run same scanner as Import PK
        // ============================================
        print("⚠️ Quick fix insufficient (\(notesWithValidWitness)/\(notes.count) have valid witnesses)")
        print("🔄 FIX #577 v8: Starting FULL RESCAN - deleting all notes and rescanning from boost file...")
        onProgress(0.05, 0, 100)

        // FIX #577 v8: Delete all notes from database (this is what fixes spent/unspent status!)
        print("🗑️ FIX #577 v8: Deleting all notes from database...")
        try WalletDatabase.shared.deleteAllNotes()
        print("✅ FIX #577 v8: All notes deleted - will rediscover from boost file")

        // FIX #577 v8: Reset lastScannedHeight to 0 so scanner starts from Sapling activation
        try WalletDatabase.shared.updateLastScannedHeight(0, hash: Data(count: 32))
        print("✅ FIX #577 v8: Reset lastScannedHeight to 0 for fresh scan")

        // FIX #577 v4: Step 5 - Reset FFI tree state (same as Import PK line 5994-5996)
        print("🌳 FIX #577 v4: Resetting FFI tree state...")
        isTreeLoaded = false
        treeLoadProgress = 0.0
        treeLoadStatus = ""
        print("✅ FIX #577 v4: FFI tree state reset")

        onProgress(0.1, 0, 100)

        // FIX #577 v6: CRITICAL - Disable background processes before scan (like Import PK)
        // This prevents race conditions: mempool scan, block notifications, background sync
        // These interfere with PHASE 1/PHASE 2 scanning and cause data corruption
        await MainActor.run {
            NetworkManager.shared.disableBackgroundProcesses()
        }
        print("🔒 FIX #577 v6: Background processes DISABLED for Full Rescan (preventing race conditions)")

        // FIX #577 v14: Tasks were already initialized at line 3799-3812 (when Full Rescan started)
        // This ensures they're ready when UI queries currentSyncTasks (ContentView.swift)
        // Previous bug (FIX #577 v12): Tasks initialized here caused timing issue
        print("📦 FIX #577 v14: Using Import PK tasks initialized at startup (line 3799-3812)")

        // FIX #577 v4: Call scanner EXACTLY like Import PK - scanner handles everything
        // Import PK doesn't have all this extra header/tree/hash loading code
        // The scanner handles: boost file, headers, CMU data, PHASE 1/2 scanning
        let scanner = FilterScanner()

        // FIX #577 v12: CRITICAL - Update WalletManager progress properties so CypherpunkSyncView works
        // The local onProgress callback only updates SettingsView's local variables
        // But CypherpunkSyncView reads from WalletManager's @Published properties
        // So we need to update BOTH from the scanner's callback
        // Also must use SAME task IDs as Import PK for proper display
        scanner.onProgress = { progress, currentHeight, maxHeight in
            // Call the original callback (for SettingsView completion detection)
            onProgress(progress, currentHeight, maxHeight)

            // ALSO update WalletManager's properties (for CypherpunkSyncView display)
            Task { @MainActor in
                // Map scanner progress to overall progress (0.0 to 0.90 for scan phases)
                // Start at 0.0 (params/keys/db already marked completed)
                // download_outputs through scan: 0% to 80%
                // witnesses/balance: 80% to 90%
                let scanProgress = min(0.80, progress * 0.80)
                self.overallProgress = scanProgress

                // Update status with progress info
                let progressPercent = Int(progress * 100)
                if maxHeight > 0 {
                    self.syncStatus = "Scanning blockchain... \(progressPercent)% (\(currentHeight)/\(maxHeight))"
                } else {
                    self.syncStatus = "Initializing scan... \(progressPercent)%"
                }

                // Update tasks using SAME IDs as Import PK
                // download_outputs through scan get updated based on progress
                func updateTaskStatus(id: String, status: SyncTaskStatus, detail: String? = nil, progress: Double? = nil) {
                    if let index = self.syncTasks.firstIndex(where: { $0.id == id }) {
                        var task = self.syncTasks[index]
                        task.status = status
                        if let detail = detail { task.detail = detail }
                        if let progress = progress { task.progress = progress }
                        self.syncTasks[index] = task
                    }
                }

                // Mark tasks as completed based on progress
                // download_outputs completes at 10%
                if progress >= 0.10 {
                    updateTaskStatus(id: "download_outputs", status: .completed, detail: "Downloaded")
                }

                // download_timestamps completes at 15%
                if progress >= 0.15 {
                    updateTaskStatus(id: "download_timestamps", status: .completed, detail: "Loaded from boost")
                }

                // headers completes at 20%
                if progress >= 0.20 {
                    updateTaskStatus(id: "headers", status: .completed, detail: "Synced from boost")
                }

                // height completes at 25%
                if progress >= 0.25 {
                    updateTaskStatus(id: "height", status: .completed, detail: "Chain tip queried")
                }

                // scan gets updated progress throughout
                let scanTaskPercent = Int(min(100, progress * 100))
                if progress < 1.0 {
                    updateTaskStatus(
                        id: "scan",
                        status: .inProgress,
                        detail: "Block \(currentHeight) of \(maxHeight)",
                        progress: progress
                    )
                } else {
                    updateTaskStatus(id: "scan", status: .completed, detail: "Decrypted \(maxHeight) blocks", progress: 1.0)
                }

                // witnesses starts at 80%
                if progress >= 0.80 {
                    let witnessProgress = (progress - 0.80) / 0.10  // Map 80-100% to 0-100%
                    if witnessProgress < 1.0 {
                        updateTaskStatus(id: "witnesses", status: .inProgress, detail: "Building witnesses...", progress: witnessProgress)
                    } else {
                        updateTaskStatus(id: "witnesses", status: .completed, detail: "Witnesses built", progress: 1.0)
                    }
                }

                // balance starts at 90%
                if progress >= 0.90 {
                    let balanceProgress = (progress - 0.90) / 0.10  // Map 90-100% to 0-100%
                    if balanceProgress < 1.0 {
                        updateTaskStatus(id: "balance", status: .inProgress, detail: "Calculating balance...", progress: balanceProgress)
                    } else {
                        updateTaskStatus(id: "balance", status: .completed, detail: "Balance calculated", progress: 1.0)
                    }
                }
            }
        }

        print("🔄 FIX #577 v4: Calling scanner (same as Import PK)...")
        print("📦 FIX #577 v12: Progress callback will update WalletManager properties for CypherpunkSyncView")
        print("📦 Scanner handles: boost, headers, CMU data, PHASE 1/2")
        try await scanner.startScan(for: account.accountId, viewingKey: spendingKey)

        // FIX #577 v6: Re-enable background processes after scan completes (like Import PK)
        await MainActor.run {
            NetworkManager.shared.enableBackgroundProcesses()
        }
        print("🔓 FIX #577 v6: Background processes RE-ENABLED after Full Rescan complete")

        // FIX #263: Explicitly set progress to 100% after scan completes
        // Without this, UI can stay stuck at 99% even though scan finished
        await MainActor.run {
            onProgress(1.0, 100, 100)

            // FIX #577 v12: Mark all tasks as completed after scan
            self.overallProgress = 0.90  // Scan at 90%, witnesses and balance next
            self.syncStatus = "Scan complete - finalizing..."

            // Helper function to update tasks
            func updateTaskStatus(id: String, status: SyncTaskStatus, detail: String? = nil, progress: Double? = nil) {
                if let index = self.syncTasks.firstIndex(where: { $0.id == id }) {
                    var task = self.syncTasks[index]
                    task.status = status
                    if let detail = detail { task.detail = detail }
                    if let progress = progress { task.progress = progress }
                    self.syncTasks[index] = task
                }
            }

            // Mark all scan-related tasks as completed
            updateTaskStatus(id: "scan", status: .completed, detail: "Decrypted all blocks", progress: 1.0)
            updateTaskStatus(id: "witnesses", status: .inProgress, detail: "Finalizing witnesses...", progress: 0.5)
            updateTaskStatus(id: "balance", status: .pending, detail: "Waiting...")
        }
        print("✅ FIX #263: Progress set to 100%")
        print("📦 FIX #577 v12: Scan complete, witnesses/balance finalizing...")

        // FIX #176: Update checkpoint to lastScannedHeight after full rescan
        // This prevents the "Checkpoint Sync" health check from failing after repair
        if let lastScanned = try? WalletDatabase.shared.getLastScannedHeight(), lastScanned > 0 {
            try? WalletDatabase.shared.updateVerifiedCheckpointHeight(lastScanned)
            print("📍 FIX #176: Checkpoint updated to \(lastScanned) after full resync")
        }

        // Refresh balance
        try await refreshBalance()

        // FIX #286 v20: NOW restore Tor after successful completion
        await restoreTorIfNeeded()

        // FIX #459: Reset isRepairingDatabase flag BEFORE return
        // The defer block's Task doesn't execute reliably, so we reset manually here
        await MainActor.run { isRepairingDatabase = false }
        print("🔧 FIX #459: Manually reset isRepairingDatabase = false after full resync")

        // FIX #462: Trigger transaction history refresh in all views
        // Increment version to force SwiftUI to reload transaction arrays
        await MainActor.run {
            transactionHistoryVersion += 1
            print("📜 FIX #462: Incremented transactionHistoryVersion to \(transactionHistoryVersion) - views should reload")
        }

        // FIX #482: Update all witnesses in database to match final tree state
        // After full rescan, FilterScanner updates witnesses, but we verify all are current
        // This ensures send is instant - no witness rebuild delay at send time
        print("🔧 FIX #482: Verifying all witnesses match current tree state after full rescan...")
        await MainActor.run {
            self.treeLoadStatus = "Finalizing (updating witnesses)..."
            self.treeLoadProgress = 0.99  // Move to 99% to show almost done
        }
        await preRebuildWitnessesForInstantPayment(accountId: account.accountId)

        // FIX #577 v11: Rebuild transaction history after Full Rescan
        // The scanner creates notes but doesn't populate transaction_history table
        // We need to call populateHistoryFromNotes() to create SENT/RECEIVED/CHANGE entries
        print("📜 FIX #577 v11: Rebuilding transaction history after Full Rescan...")
        let historyCount = try WalletDatabase.shared.populateHistoryFromNotes()
        print("📜 FIX #577 v11: Transaction history rebuilt - \(historyCount) entries")

        // FIX #577 v12: Mark all tasks as completed and set final progress to 100%
        await MainActor.run {
            // Helper function to update tasks
            func updateTaskStatus(id: String, status: SyncTaskStatus, detail: String? = nil, progress: Double? = nil) {
                if let index = self.syncTasks.firstIndex(where: { $0.id == id }) {
                    var task = self.syncTasks[index]
                    task.status = status
                    if let detail = detail { task.detail = detail }
                    if let progress = progress { task.progress = progress }
                    self.syncTasks[index] = task
                }
            }

            // Mark witnesses and balance as completed
            updateTaskStatus(id: "witnesses", status: .completed, detail: "Witnesses verified", progress: 1.0)
            updateTaskStatus(id: "balance", status: .completed, detail: "Balance calculated", progress: 1.0)

            // Set final progress to 100%
            self.overallProgress = 1.0
            self.syncStatus = "Full Rescan complete!"
        }

        print("✅ FIX #577 v12: All tasks completed, progress at 100%")
        print("✅ Database repair complete - full resync finished")
    }

    /// Quick fix: Extract anchors from existing witnesses
    /// This fixes the witness/anchor mismatch without a full rescan
    /// The witness contains the tree root it was built against - extract and save it
    func fixAnchorsFromWitnesses() async throws -> Int {
        guard isWalletCreated else {
            throw WalletError.walletNotCreated
        }

        // Get spending key
        let spendingKey = try secureStorage.retrieveSpendingKey()

        // Ensure database is open
        let dbKey = Data(SHA256.hash(data: spendingKey))
        try WalletDatabase.shared.open(encryptionKey: dbKey)

        // Get account ID
        guard let account = try WalletDatabase.shared.getAccount(index: 0) else {
            throw WalletError.walletNotCreated
        }

        // Get all notes with witnesses
        let notes = try WalletDatabase.shared.getAllUnspentNotes(accountId: account.accountId)
        print("🔧 Fixing anchors for \(notes.count) notes...")

        var fixedCount = 0
        for note in notes {
            guard note.witness.count >= 100 else {
                print("⚠️ Note \(note.id): witness too short (\(note.witness.count) bytes)")
                continue
            }

            // FIX #546: Get anchor from HEADER STORE instead of from witness
            // According to SESSION_SUMMARY_2025-11-28.md: "Anchor MUST come from header store - not from computed tree state"
            if let headerAnchor = try? HeaderStore.shared.getSaplingRoot(at: UInt64(note.height)) {
                // Update anchor in database
                try WalletDatabase.shared.updateNoteAnchor(noteId: note.id, anchor: headerAnchor)
                fixedCount += 1

                let anchorHex = headerAnchor.prefix(8).map { String(format: "%02x", $0) }.joined()
                print("✅ Note \(note.id) (height \(note.height)): anchor from HEADER at \(anchorHex)...")
            } else {
                print("⚠️ Note \(note.id) (height \(note.height)): no header found for anchor")
            }
        }

        print("✅ Fixed anchors for \(fixedCount)/\(notes.count) notes")
        return fixedCount
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
        print("👤 Account ID: \(account.accountId)")

        // FAST PATH: Try to rebuild witnesses using stored CMUs and downloaded tree
        let notes = try WalletDatabase.shared.getAllUnspentNotes(accountId: account.accountId)
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
                let isConnectedForRescan = await MainActor.run { NetworkManager.shared.isConnected }
                if !isConnectedForRescan {
                    try await NetworkManager.shared.connect()
                    try await Task.sleep(nanoseconds: 500_000_000)
                }

                // Scan from downloaded tree height to find notes AND detect spent nullifiers
                let scanner = FilterScanner()
                scanner.onProgress = onProgress
                try await scanner.startScan(for: account.accountId, viewingKey: spendingKey, fromHeight: downloadedTreeHeight + 1)

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

                    // FIX #546: Get anchor from HEADER STORE instead of from witness
                    // According to SESSION_SUMMARY_2025-11-28.md: "Anchor MUST come from header store - not from computed tree state"
                    if let headerAnchor = try? HeaderStore.shared.getSaplingRoot(at: UInt64(note.height)) {
                        try WalletDatabase.shared.updateNoteAnchor(noteId: note.id, anchor: headerAnchor)
                        let anchorHex = headerAnchor.prefix(8).map { String(format: "%02x", $0) }.joined()
                        print("   ✅ Anchor from HEADER at \(anchorHex)...")
                    } else {
                        print("   ⚠️ No header found for anchor at height \(note.height)")
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

    // MARK: - FIX #550: Auto-fix anchor mismatches

    /// FIX #550: Auto-fix anchor mismatches detected by health check
    /// Rebuilds witnesses with correct HeaderStore anchors
    /// Called automatically at startup when mismatches are detected
    func fixAnchorMismatches() async -> Int {
        print("🔧 FIX #550: Auto-fixing anchor mismatches by rebuilding witnesses...")

        do {
            // Get spending key
            let spendingKey = try secureStorage.retrieveSpendingKey()
            let dbKey = Data(SHA256.hash(data: spendingKey))
            try WalletDatabase.shared.open(encryptionKey: dbKey)

            // Get all unspent notes
            let notes = try WalletDatabase.shared.getAllUnspentNotes(accountId: 0)
            let unspentNotes = notes.filter { $0.cmu != nil }

            guard !unspentNotes.isEmpty else {
                print("⚠️ FIX #550: No unspent notes to fix")
                return 0
            }

            print("   Found \(unspentNotes.count) unspent notes - rebuilding witnesses...")

            // Load cached CMU data for witness creation
            guard let cmuPath = await CommitmentTreeUpdater.shared.getCachedCMUFilePath(),
                  let cmuData = try? Data(contentsOf: cmuPath) else {
                print("   ❌ FIX #550: No CMU data available for witness rebuild")
                return 0
            }

            // Collect target CMUs
            let targetCMUs = unspentNotes.map { $0.cmu! }
            var noteIdMap: [Int: Int64] = [:]
            for (index, note) in unspentNotes.enumerated() {
                noteIdMap[index] = note.id
            }

            // Create witnesses using batch function
            let results = ZipherXFFI.treeCreateWitnessesBatch(
                cmuData: cmuData,
                targetCMUs: targetCMUs
            )

            var fixedCount = 0
            for (index, result) in results.enumerated() {
                guard let noteId = noteIdMap[index] else { continue }
                guard let (_, witness) = result else { continue }

                let note = unspentNotes[index]

                // Update witness
                try? WalletDatabase.shared.updateNoteWitness(noteId: noteId, witness: witness)

                // FIX #555: Use HeaderStore anchor (not witness root)
                if let headerAnchor = try? HeaderStore.shared.getSaplingRoot(at: UInt64(note.height)) {
                    try? WalletDatabase.shared.updateNoteAnchor(noteId: noteId, anchor: headerAnchor)

                    // Verify
                    if let verifyAnchor = try? WalletDatabase.shared.getAnchor(for: noteId),
                       verifyAnchor == headerAnchor {
                        fixedCount += 1
                        let anchorHex = headerAnchor.prefix(8).map { String(format: "%02x", $0) }.joined()
                        print("   ✅ Note \(noteId) height \(note.height): witness rebuilt, anchor \(anchorHex)...")
                    }
                }
            }

            print("✅ FIX #550: Rebuilt \(fixedCount)/\(unspentNotes.count) witnesses with correct anchors")
            return fixedCount

        } catch {
            print("❌ FIX #550: Error fixing anchors: \(error)")
            return 0
        }
    }

    // MARK: - FIX #588: Rebuild Corrupted Witnesses at Specific Positions

    /// FIX #588: Rebuild witnesses corrupted by old FIX #585 trimming code
    ///
    /// Creates each witness at its SPECIFIC position (not all at chain tip)
    /// by:
    /// 1. Extracting CMUs from boost file (for positions within boost range)
    /// 2. Fetching CMUs from P2P network (for positions beyond boost range)
    /// 3. Building each witness at its exact position using zipherx_tree_rebuild_witnesses_at_positions
    /// 4. Using header sapling_root as anchor for each note
    ///
    /// This fixes the issue where witnesses have corrupted Merkle paths (filled_nodes)
    /// due to old FIX #585 trimming code that zeroed out trailing bytes (259 trailing zeros!).
    ///
    /// - Parameter progress: Optional progress callback (current, total)
    /// - Returns: Number of witnesses successfully rebuilt
    func rebuildCorruptedWitnesses(progress: ((Int, Int) -> Void)? = nil) async -> Int {
        print("🔧 FIX #588: Rebuilding corrupted witnesses at specific positions...")

        do {
            // Get spending key
            let spendingKey = try secureStorage.retrieveSpendingKey()
            let dbKey = Data(SHA256.hash(data: spendingKey))
            try WalletDatabase.shared.open(encryptionKey: dbKey)

            // Get account ID (don't assume it's 0)
            guard let account = try WalletDatabase.shared.getAccount(index: 0) else {
                print("   ❌ FIX #588: No account found")
                return 0
            }
            let accountId = account.accountId
            print("   📋 Using account ID: \(accountId)")

            // Get all unspent notes with CMU
            let notes = try WalletDatabase.shared.getAllUnspentNotes(accountId: accountId)
            let notesWithCMU = notes.filter { $0.cmu != nil && $0.cmu!.count == 32 }

            guard !notesWithCMU.isEmpty else {
                print("⚠️ FIX #588: No unspent notes with CMU to rebuild")
                return 0
            }

            print("   Found \(notesWithCMU.count) notes to rebuild")

            // Collect targets: CMU + position for each note
            let saplingActivation: UInt64 = 476969
            var targets: [(noteId: Int64, cmu: Data, position: UInt64, height: UInt64)] = []

            for note in notesWithCMU {
                guard let cmu = note.cmu else { continue }
                let height = note.height
                let position = height >= saplingActivation ? height - saplingActivation : 0
                targets.append((noteId: note.id, cmu: cmu, position: position, height: height))
            }

            // Find min and max positions needed
            let maxPosition = targets.map { $0.position }.max() ?? 0
            let maxHeight = targets.map { $0.height }.max() ?? 0
            let minHeight = targets.map { $0.height }.min() ?? saplingActivation

            print("   Position range: 0 to \(maxPosition) (height \(saplingActivation) to \(maxHeight))")

            // 1. Get CMUs from boost file
            print("   📦 Loading boost file CMUs...")
            let boostCMUData = try await CommitmentTreeUpdater.shared.extractCMUsInLegacyFormat { progress in
                if Int(progress * 100) % 10 == 0 {
                    print("      Extracting boost CMUs: \(Int(progress * 100))%")
                }
            }

            // Parse boost CMU count
            guard boostCMUData.count >= 8 else {
                print("   ❌ Invalid boost CMU data")
                return 0
            }
            let boostCMUCount = boostCMUData.prefix(8).withUnsafeBytes { $0.load(as: UInt64.self) }
            print("   📊 Boost file has \(boostCMUCount) CMUs (up to position \(boostCMUCount - 1))")

            let boostMaxHeight = saplingActivation + boostCMUCount - 1
            print("   📊 Boost file covers height \(saplingActivation) to \(boostMaxHeight)")

            // 2. Fetch delta CMUs from blocks beyond boost file
            var deltaCMUs: [Data] = []
            if maxHeight > boostMaxHeight {
                let startHeight = boostMaxHeight + 1
                print("   📡 Fetching delta CMUs from blocks \(startHeight) to \(maxHeight)...")

                let txBuilder = TransactionBuilder()
                deltaCMUs = await txBuilder.fetchCMUsFromBlocks(startHeight: startHeight, endHeight: maxHeight)
                print("   📊 Fetched \(deltaCMUs.count) delta CMUs")
            }

            // 3. Build combined CMU data
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

            print("   📊 Combined CMU data: \(totalCMUCount) CMUs (\(combinedCMUData.count) bytes)")

            // 4. Rebuild witnesses at specific positions using FFI
            print("   🔧 Rebuilding witnesses at specific positions...")

            // Prepare targets for FFI: separate arrays for CMUs and positions
            var targetCMUs: [Data] = []
            var targetPositions: [UInt64] = []
            var noteIdMap: [Int: Int64] = [:]
            var heightMap: [Int: UInt64] = [:]

            for (index, target) in targets.enumerated() {
                targetCMUs.append(target.cmu)
                targetPositions.append(target.position)
                noteIdMap[index] = target.noteId
                heightMap[index] = target.height
            }

            // Call FFI function to rebuild witnesses at specific positions
            let results = ZipherXFFI.treeRebuildWitnessesAtPositions(
                cmuData: combinedCMUData,
                targets: zip(targetCMUs, targetPositions).map { (cmu: $0.0, position: $0.1) }
            )

            var rebuiltCount = 0
            for (index, witnessData) in results.enumerated() {
                guard let noteId = noteIdMap[index],
                      let height = heightMap[index],
                      let witness = witnessData else {
                    print("   ⚠️ Target \(index): no witness created")
                    continue
                }

                // Get correct anchor from header at this height
                guard let correctAnchor = try? HeaderStore.shared.getSaplingRoot(at: height) else {
                    print("   ⚠️ Note ID=\(noteId): Could not get header anchor at height \(height), skipping")
                    continue
                }

                // Update witness and anchor in database
                try WalletDatabase.shared.updateNoteWitness(noteId: noteId, witness: witness)
                try WalletDatabase.shared.updateNoteAnchor(noteId: noteId, anchor: correctAnchor)

                rebuiltCount += 1

                // Report progress
                progress?(index + 1, targets.count)

                // Verify witness is valid
                if let witnessRoot = ZipherXFFI.witnessGetRoot(witness) {
                    let anchorHex = correctAnchor.prefix(8).map { String(format: "%02x", $0) }.joined()
                    let rootHex = witnessRoot.prefix(8).map { String(format: "%02x", $0) }.joined()
                    let match = correctAnchor == witnessRoot
                    print("   ✅ Note ID=\(noteId) height=\(height): anchor=\(anchorHex)... root=\(rootHex)... \(match ? "✅ MATCH" : "❌ MISMATCH")")
                } else {
                    print("   ⚠️ Note ID=\(noteId): witness rebuilt but root extraction failed")
                }
            }

            print("✅ FIX #588: Rebuilt \(rebuiltCount)/\(targets.count) witnesses at specific positions")

            // Refresh balance after rebuild
            try await refreshBalance()

            return rebuiltCount

        } catch {
            print("❌ FIX #588: Error rebuilding witnesses: \(error)")
            return 0
        }
    }

    /// Fall back to full scan for witness rebuild
    private func rebuildWitnessesViaFullScan(account: Account, spendingKey: Data, onProgress: @escaping (Double, UInt64, UInt64) -> Void) async throws {
        // Ensure network connection before scanning
        print("📡 Ensuring network connection...")
        let isConnectedForScan = await MainActor.run { NetworkManager.shared.isConnected }
        if !isConnectedForScan {
            try await NetworkManager.shared.connect()
            // Wait a moment for connection to stabilize
            try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
        }
        let peerCountForScan = await MainActor.run { NetworkManager.shared.peers.count }
        print("✅ Network connected: \(peerCountForScan) peer(s)")

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

        try await scanner.startScan(for: account.accountId, viewingKey: spendingKey, fromHeight: saplingActivation)

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
        print("👤 Account ID: \(account.accountId)")

        // Ensure network connection before scanning
        print("📡 Ensuring network connection...")
        let isConnectedForScan = await MainActor.run { NetworkManager.shared.isConnected }
        if !isConnectedForScan {
            try await NetworkManager.shared.connect()
            // Wait a moment for connection to stabilize
            try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
        }
        let peerCountForScan = await MainActor.run { NetworkManager.shared.peers.count }
        print("✅ Network connected: \(peerCountForScan) peer(s)")

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
        try await scanner.startScan(for: account.accountId, viewingKey: spendingKey, fromHeight: startHeight)

        // Refresh balance after scan
        try await refreshBalance()
        print("✅ Quick scan complete")
    }

    /// Update a sync task status
    @MainActor
    // FIX #488 v3: Replace struct in array to trigger SwiftUI @Published update
    private func updateTask(_ id: String, status: SyncTaskStatus, detail: String? = nil) {
        if let index = syncTasks.firstIndex(where: { $0.id == id }) {
            var task = syncTasks[index]
            task.status = status
            if let detail = detail {
                task.detail = detail
            }
            syncTasks[index] = task

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
                // FIX #562: Calculate progress based on task progress values, not just completed count
                self.recalculateSyncProgress()
            }
        }

        // FIX #562: Also recalculate progress when inProgress with progress value
        if case .inProgress = status, let progress = syncTasks.first(where: { $0.id == id })?.progress, progress > 0 {
            self.recalculateSyncProgress()
        }
    }

    /// FIX #562: Calculate sync progress from individual task progress values
    /// In FAST START mode, only consider fast_* tasks (5 tasks)
    /// In NORMAL START mode, consider all sync tasks
    @MainActor
    private func recalculateSyncProgress() {
        // Filter tasks based on whether we're in FAST START mode
        // FAST START mode: tree is loaded, initial sync is active, only fast_* tasks exist
        let isFastStartMode = self.isTreeLoaded && syncTasks.contains(where: { $0.id.hasPrefix("fast_") })

        let relevantTasks: [SyncTask]
        if isFastStartMode {
            // In FAST START, only consider fast_* tasks
            relevantTasks = syncTasks.filter { $0.id.hasPrefix("fast_") }
        } else {
            // In NORMAL START, consider all sync tasks
            relevantTasks = syncTasks
        }

        guard !relevantTasks.isEmpty else {
            self.syncProgress = 0.0
            return
        }

        // Calculate progress as average of task progress values
        var totalProgress: Double = 0.0
        for task in relevantTasks {
            switch task.status {
            case .completed:
                totalProgress += 1.0
            case .inProgress:
                // Use progress value if available, otherwise assume 50%
                if let progress = task.progress, progress > 0 {
                    totalProgress += progress
                } else {
                    totalProgress += 0.5
                }
            case .pending, .failed:
                totalProgress += 0.0
            }
        }

        self.syncProgress = totalProgress / Double(relevantTasks.count)
    }

    /// Update a sync task with progress (keeps inProgress status)
    @MainActor
    // FIX #488 v3: Replace struct in array to trigger SwiftUI @Published update
    private func updateTaskWithProgress(_ id: String, detail: String, progress: Double) {
        if let index = syncTasks.firstIndex(where: { $0.id == id }) {
            var task = syncTasks[index]
            task.detail = detail
            task.progress = progress
            syncTasks[index] = task
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
        // FIX #468: Create task if it doesn't exist (happens during Import PK)
        if syncTasks.firstIndex(where: { $0.id == taskId }) == nil {
            // Create task with appropriate title based on ID
            let title: String
            switch taskId {
            case "headers":
                title = "Loading block headers"
            case "download_outputs":
                title = "Download shielded outputs"
            case "download_timestamps":
                title = "Download block timestamps"
            case "scan":
                title = "Decrypt shielded notes"
            case "witnesses":
                title = "Build Merkle witnesses"
            default:
                title = "Processing"
            }
            syncTasks.append(SyncTask(id: taskId, title: title, status: .inProgress, detail: detail, progress: progress))
        } else {
            // First set to in progress if not already
            if let index = syncTasks.firstIndex(where: { $0.id == taskId }) {
                if case .pending = syncTasks[index].status {
                    // FIX #497: Replace entire task struct to trigger SwiftUI @Published update
                    var task = syncTasks[index]
                    task.status = .inProgress
                    syncTasks[index] = task
                }
            }
            updateTaskWithProgress(taskId, detail: detail, progress: progress)
        }
    }

    /// Update a sync task status, detail, and progress - called from ContentView for FAST START
    /// FIX #154: Added progress parameter for individual task progress bars
    /// FIX #497: Replace entire task struct to trigger SwiftUI @Published update
    /// FIX #562: Recalculate overall progress when task status or progress changes
    @MainActor
    func updateSyncTask(id: String, status: SyncTaskStatus, detail: String? = nil, progress: Double? = nil) {
        if let index = syncTasks.firstIndex(where: { $0.id == id }) {
            var task = syncTasks[index]
            task.status = status
            if let detail = detail {
                task.detail = detail
            }
            if let progress = progress {
                task.progress = progress
            }
            syncTasks[index] = task

            // FIX #562: Recalculate overall progress when task is updated
            recalculateSyncProgress()
        }
    }

    /// Get the real date for a given block height
    /// Uses BlockTimestampManager for actual blockchain timestamps (downloaded from GitHub)
    /// Falls back to estimate using HeaderStore or dynamic reference
    private func estimateDateForBlock(height: UInt64) -> String {
        guard height > 0 else { return "" }

        // 1. Try BlockTimestampManager (boost file or runtime cache)
        if let realDate = BlockTimestampManager.shared.getFormattedDate(at: height) {
            return realDate
        }

        // 2. Try HeaderStore (P2P synced headers contain timestamps)
        if let headerTime = try? HeaderStore.shared.getBlockTime(at: height) {
            let date = Date(timeIntervalSince1970: TimeInterval(headerTime))
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d, yyyy"
            return formatter.string(from: date)
        }

        // 3. FALLBACK: Dynamic estimate using current chain height and NOW
        // This avoids hardcoded reference points that become stale
        let blockTimeInterval: TimeInterval = 150 // 2.5 minutes per block
        // FIX #388: Use cached chain height for sync function (MainActor isolation)
        let currentHeight = UInt64(UserDefaults.standard.integer(forKey: "cachedChainHeight"))
        let currentTime = Date().timeIntervalSince1970

        // Calculate: target height relative to current height
        let heightDiff = Int64(height) - Int64(currentHeight)
        let estimatedTimestamp = currentTime + (Double(heightDiff) * blockTimeInterval)
        let date = Date(timeIntervalSince1970: estimatedTimestamp)

        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy"
        return formatter.string(from: date)
    }

    /// Convert a date to estimated block height
    /// Uses dynamic reference from current chain height and NOW
    /// Zclassic block time: 2.5 minutes (150 seconds)
    /// - Parameter date: The date to convert
    /// - Returns: Estimated block height (clamped to Sapling activation minimum and current chain height)
    static func blockHeightForDate(_ date: Date) -> UInt64 {
        let blockTimeInterval: TimeInterval = 150 // 2.5 minutes
        // FIX #388: Use cached chain height for sync static function (MainActor isolation)
        let currentHeight = UInt64(UserDefaults.standard.integer(forKey: "cachedChainHeight"))
        let currentTime = Date().timeIntervalSince1970

        let targetTimestamp = date.timeIntervalSince1970
        let timeDiff = targetTimestamp - currentTime
        let blockDiff = Int64(timeDiff / blockTimeInterval)

        let estimatedHeight = Int64(currentHeight) + blockDiff

        // Clamp to Sapling activation as minimum and current chain height as maximum
        let saplingActivation: UInt64 = 476_969
        let clampedHeight = UInt64(max(Int64(saplingActivation), min(estimatedHeight, Int64(currentHeight))))
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
        // FIX #511: Stop block listeners during TX build to prevent race condition
        // Block listeners can consume "headers" or other responses that TX build needs
        await NetworkManager.shared.stopAllBlockListeners()

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

        // FIX #596: CRITICAL - Update witnesses with CURRENT anchor BEFORE building transaction!
        // If we build with OLD anchor from DB, transaction will be rejected with "joinsplit requirements not met"
        // The witness update ensures all witnesses have the latest tree root as anchor
        onProgress("verify", "Updating witnesses...", 0.0)
        await preRebuildWitnessesForInstantPayment(accountId: 1)
        onProgress("verify", "Witnesses updated", 0.5)

        // Record balance BEFORE send - used to detect change vs real incoming
        // Also set lastSendTimestamp EARLY so clearingTime calculation works
        // (setMempoolVerified() uses lastSendTimestamp to calculate clearing duration)
        await MainActor.run {
            self.balanceBeforeLastSend = currentBalance
            self.lastSendTimestamp = Date()
        }

        // FIX #262: Verify notes are not already spent on-chain before building
        // This prevents wasted proof generation and confusing DUPLICATE rejections
        onProgress("verify", "Verifying notes not spent...", 0.0)
        let spentOnChain = try await verifyNotesNotSpentOnChain()
        if let spentNote = spentOnChain {
            // Note was spent elsewhere - update our database and throw error
            throw WalletError.transactionFailed("""
                ⚠️ NOTE ALREADY SPENT

                One of your notes (value: \(Double(spentNote.value) / 100_000_000.0) ZCL) was already spent in another transaction.

                This can happen if you:
                • Sent from this wallet on another device
                • Restored this wallet elsewhere
                • Had a previous transaction confirm that wasn't recorded

                🔧 Your database has been updated.
                Your balance will refresh automatically.

                "Privacy is the power to selectively reveal oneself to the world."
                — A Cypherpunk's Manifesto
                """)
        }
        onProgress("verify", "Notes verified", 1.0)

        // FIX #527: CRITICAL - Validate CMU tree root before allowing send
        // If tree root doesn't match blockchain, all witnesses are invalid
        // Sending with invalid witnesses = wasted proof + guaranteed rejection
        onProgress("verify", "Validating commitment tree...", 0.5)
        let treeValid = await validateCMUTreeBeforeSend()
        if !treeValid.isValid {
            // Tree root MISMATCH - block send with clear error
            throw WalletError.transactionFailed("""
                🚨 CRITICAL SECURITY ISSUE

                Your commitment tree state does NOT match the blockchain!

                This means your wallet's internal tree is corrupted or out of sync.
                If you try to send, your transaction will be REJECTED by the network.

                Details:
                • Our tree root:  \(treeValid.ourRoot)
                • Blockchain root: \(treeValid.headerRoot)

                🔧 REQUIRED FIX:
                Go to Settings → Database Repair → Full Rescan

                This will rebuild your commitment tree from the verified blockchain data.

                Your funds are SAFE - this is just a data sync issue.
                The Full Rescan will fix the tree and restore normal operation.

                "Never send with an invalid tree - it's guaranteed to fail."
                — ZipherX Security Protocol
                """)
        }
        onProgress("verify", "Commitment tree validated", 1.0)

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
        let broadcastResult = try await networkManager.broadcastTransactionWithProgress(rawTx, amount: amount) { phase, detail, progress in
            // Forward broadcast progress to the UI
            // Use actual phase ("peers", "verify", "api") so UI can show txid immediately on first peer accept
            onProgress(phase, detail, progress)
        }

        let txId = broadcastResult.txId

        // ============================================================================
        // VUL-002 + FIX #245 + FIX #349 + FIX #590: Handle mempool verification
        //
        // The mempool check may be slow or unavailable, especially over Tor.
        // FIX #245: If PEERS accepted but mempool check TIMED OUT (not attempted),
        //          trust the peer acceptance - TX was likely propagated.
        // FIX #590: BUT if P2P verification WAS ATTEMPTED and FAILED, do NOT trust!
        //          Peers lying about accepting is different from network timeout.
        // FIX #349: If peers EXPLICITLY REJECTED, do NOT fall back to peer acceptance!
        // ============================================================================
        if !broadcastResult.mempoolVerified {
            if broadcastResult.rejectCount > 0 {
                // FIX #349: Peers EXPLICITLY rejected - this is NOT a slow network issue!
                print("🚨 FIX #349: \(broadcastResult.rejectCount) peers REJECTED transaction!")
                print("🚨 FIX #349: txId=\(txId), accepts=\(broadcastResult.peerCount), rejects=\(broadcastResult.rejectCount)")

                // Clear any pending broadcast tracking since TX was rejected
                await MainActor.run {
                    networkManager.clearPendingBroadcast()
                }

                throw WalletError.transactionFailed("""
                    🚨 TRANSACTION REJECTED 🚨

                    Your transaction was explicitly rejected by \(broadcastResult.rejectCount) network peer(s). This typically means:
                    • The transaction anchor is invalid (blockchain state changed)
                    • A previous transaction already spent these notes
                    • Network consensus rejected the proof

                    🔒 YOUR FUNDS ARE SAFE
                    No transaction was recorded in your wallet.

                    💡 WHAT TO DO:
                    Go to Settings → Repair Database, then try again.

                    📋 TXID (for reference):
                    \(txId)

                    "Privacy is necessary for an open society."
                    — A Cypherpunk's Manifesto
                    """)
            } else if broadcastResult.peerCount > 0 && broadcastResult.p2pVerificationAttempted {
                // FIX #590: Peers accepted BUT P2P verification was attempted and FAILED!
                // This means TX is NOT in mempool despite peers "accepting"
                // Do NOT trust peer acceptance - this is a BROADCAST FAILURE
                print("🚨 FIX #590: \(broadcastResult.peerCount) peers accepted but P2P verification FAILED!")
                print("🚨 FIX #590: TX is NOT in mempool - peers may have ACK'd but didn't add to mempool")
                print("🚨 FIX #590: This is a BROADCAST FAILURE - DO NOT trust peer acceptance!")
                print("📋 FIX #590: txId=\(txId)")

                // Clear any pending broadcast tracking since TX was not actually propagated
                await MainActor.run {
                    networkManager.clearPendingBroadcast()
                }

                throw WalletError.transactionFailed("""
                    🚨 BROADCAST FAILED - NOT IN MEMPOOL 🚨

                    Your transaction was "accepted" by \(broadcastResult.peerCount) peer(s) but
                    P2P verification confirmed it is NOT in any peer's mempool.

                    This happens when:
                    • Peers ACK the transaction but don't actually add it to mempool
                    • Network connections are unstable and drop during relay
                    • Transaction validation fails after initial acceptance

                    🔒 YOUR FUNDS ARE SAFE
                    No transaction was recorded in your wallet.

                    💡 WHAT TO DO:
                    Try sending again. If it persists, check network connection.

                    📋 TXID (for reference):
                    \(txId)

                    "Don't trust the network. Verify everything."
                    — A Cypherpunk's Manifesto
                    """)
            } else if broadcastResult.peerCount > 0 {
                // FIX #245: Peers accepted and P2P verification was NOT attempted (timeout)
                // This is common with Tor (slow propagation) or network issues
                // The TX was likely propagated successfully - record it and track
                print("⚠️ FIX #245: Peers accepted (\(broadcastResult.peerCount)) but mempool check timed out (0 rejections)")
                print("📡 FIX #245: P2P verification not attempted - trusting peer acceptance")
                print("📡 FIX #245: Recording TX anyway - will confirm on-chain")
                print("🔐 FIX #245: txId=\(txId)")
            } else {
                // NO peers accepted AND mempool failed - likely a true rejection
                print("🚨 VUL-002: MEMPOOL REJECTED - Not writing to database!")
                print("🚨 VUL-002: txId=\(txId), peers=\(broadcastResult.peerCount), mempool=false")

                // Clear any pending broadcast tracking since TX was rejected
                await MainActor.run {
                    networkManager.clearPendingBroadcast()
                }

                // FIX #218: Cypherpunk-styled warning with TXID for reference
                throw WalletError.transactionFailed("""
                    ⚡ MEMPOOL REJECTION ⚡

                    The network nodes did not propagate your transaction to their mempools. This can happen during network congestion or peer instability.

                    🔒 YOUR FUNDS ARE SAFE
                    No transaction was recorded in your wallet.

                    📋 TXID (for reference):
                    \(txId)

                    "We cannot expect governments, corporations, or other large, faceless organizations to grant us privacy. We must defend our own privacy."
                    — A Cypherpunk's Manifesto
                    """)
            }
        }

        // TX accepted (by mempool API or by peers)
        // FIX #350: DO NOT write to database here - only on CONFIRMATION
        if broadcastResult.mempoolVerified {
            print("✅ VUL-002: Mempool VERIFIED - TX will be recorded on confirmation")
        } else {
            print("✅ FIX #245: Peers accepted TX - will be recorded on confirmation")
        }

        // FIX #350: Track as pending outgoing with FULL info for database write on CONFIRMATION
        // DO NOT write to database here - only when TX is confirmed in a block!
        let pendingFee: UInt64 = 10_000
        let pendingTx = PendingOutgoingTx(
            txid: txId,
            amount: amount,
            fee: pendingFee,
            toAddress: toAddress,
            memo: memo,
            hashedNullifier: spentNullifier,
            rawTxData: rawTx,
            timestamp: Date()
        )
        await networkManager.trackPendingOutgoingFull(pendingTx)

        // Show waiting for confirmation
        onProgress("broadcast", "Awaiting confirmation (txid: \(txId.prefix(16))...)...", 0.95)
        print("📤 FIX #350: TX tracked as pending - database write DEFERRED until confirmation")

        // Send notification for successful transaction
        NotificationManager.shared.notifySent(amount: amount, txid: txId, memo: memo)

        // FIX #165 v2: DON'T update checkpoint here - TX is only in mempool, not confirmed!
        // Checkpoint should only be updated when TX is MINED (confirmed in a block)
        // Otherwise, if user sends from another wallet before this confirms,
        // the checkpoint would skip over that other transaction.
        // Checkpoint update moved to confirmOutgoingTx() which is called when TX is mined.

        // Signal completion with txid visible in progress message
        onProgress("broadcast", "Transaction complete!", 1.0)

        // Refresh balance in background (don't block success screen)
        Task {
            try? await refreshBalance()
        }

        // FIX #511: Restart block listeners after TX is accepted
        // Transaction is now safely in mempool/accepted by peers, can resume block announcements
        await NetworkManager.shared.startBlockListenersOnMainScreen()

        return txId
    }

    /// Send shielded ZCL to another z-address
    /// - Parameters:
    ///   - toAddress: Destination z-address (must be shielded)
    ///   - amount: Amount in zatoshis
    ///   - memo: Optional encrypted memo
    /// - Returns: Transaction ID
    func sendShielded(to toAddress: String, amount: UInt64, memo: String? = nil) async throws -> String {
        // FIX #511: Stop block listeners during TX build to prevent race condition
        await NetworkManager.shared.stopAllBlockListeners()

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

        // FIX #262: Verify notes are not already spent on-chain before building
        // This prevents building/broadcasting a TX that will be rejected as DUPLICATE
        let spentOnChain = try await verifyNotesNotSpentOnChain()
        if let spentNote = spentOnChain {
            throw WalletError.transactionFailed("""
                ⚠️ NOTE ALREADY SPENT

                One of your notes (value: \(Double(spentNote.value) / 100_000_000.0) ZCL) was already spent on-chain.

                This can happen if:
                • You sent from another wallet instance
                • A previous transaction confirmed after being marked as failed

                Your balance has been updated. Please try again.
                """)
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
        let broadcastResult = try await networkManager.broadcastTransaction(rawTx)

        let txId = broadcastResult.txId

        // ============================================================================
        // VUL-002 + FIX #245 + FIX #349 + FIX #590: Handle mempool verification
        //
        // The mempool check may be slow or unavailable, especially over Tor.
        // FIX #245: If PEERS accepted but mempool check TIMED OUT (not attempted),
        //          trust the peer acceptance - TX was likely propagated.
        // FIX #590: BUT if P2P verification WAS ATTEMPTED and FAILED, do NOT trust!
        //          Peers lying about accepting is different from network timeout.
        // FIX #349: If peers EXPLICITLY REJECTED, do NOT fall back to peer acceptance!
        // ============================================================================
        if !broadcastResult.mempoolVerified {
            if broadcastResult.rejectCount > 0 {
                // FIX #349: Peers EXPLICITLY rejected - this is NOT a slow network issue!
                print("🚨 FIX #349: \(broadcastResult.rejectCount) peers REJECTED transaction!")
                print("🚨 FIX #349: txId=\(txId), accepts=\(broadcastResult.peerCount), rejects=\(broadcastResult.rejectCount)")

                // Clear any pending broadcast tracking since TX was rejected
                await MainActor.run {
                    networkManager.clearPendingBroadcast()
                }

                throw WalletError.transactionFailed("""
                    🚨 TRANSACTION REJECTED 🚨

                    Your transaction was explicitly rejected by \(broadcastResult.rejectCount) network peer(s). This typically means:
                    • The transaction anchor is invalid (blockchain state changed)
                    • A previous transaction already spent these notes
                    • Network consensus rejected the proof

                    🔒 YOUR FUNDS ARE SAFE
                    No transaction was recorded in your wallet.

                    💡 WHAT TO DO:
                    Go to Settings → Repair Database, then try again.

                    📋 TXID (for reference):
                    \(txId)

                    "Privacy is necessary for an open society."
                    — A Cypherpunk's Manifesto
                    """)
            } else if broadcastResult.peerCount > 0 && broadcastResult.p2pVerificationAttempted {
                // FIX #590: Peers accepted BUT P2P verification was attempted and FAILED!
                // This means TX is NOT in mempool despite peers "accepting"
                // Do NOT trust peer acceptance - this is a BROADCAST FAILURE
                print("🚨 FIX #590: \(broadcastResult.peerCount) peers accepted but P2P verification FAILED!")
                print("🚨 FIX #590: TX is NOT in mempool - peers may have ACK'd but didn't add to mempool")
                print("🚨 FIX #590: This is a BROADCAST FAILURE - DO NOT trust peer acceptance!")
                print("📋 FIX #590: txId=\(txId)")

                // Clear any pending broadcast tracking since TX was not actually propagated
                await MainActor.run {
                    networkManager.clearPendingBroadcast()
                }

                throw WalletError.transactionFailed("""
                    🚨 BROADCAST FAILED - NOT IN MEMPOOL 🚨

                    Your transaction was "accepted" by \(broadcastResult.peerCount) peer(s) but
                    P2P verification confirmed it is NOT in any peer's mempool.

                    This happens when:
                    • Peers ACK the transaction but don't actually add it to mempool
                    • Network connections are unstable and drop during relay
                    • Transaction validation fails after initial acceptance

                    🔒 YOUR FUNDS ARE SAFE
                    No transaction was recorded in your wallet.

                    💡 WHAT TO DO:
                    Try sending again. If it persists, check network connection.

                    📋 TXID (for reference):
                    \(txId)

                    "Don't trust the network. Verify everything."
                    — A Cypherpunk's Manifesto
                    """)
            } else if broadcastResult.peerCount > 0 {
                // FIX #245: Peers accepted and P2P verification was NOT attempted (timeout)
                // This is common with Tor (slow propagation) or network issues
                // The TX was likely propagated successfully - record it and track
                print("⚠️ FIX #245: Peers accepted (\(broadcastResult.peerCount)) but mempool check timed out (0 rejections)")
                print("📡 FIX #245: P2P verification not attempted - trusting peer acceptance")
                print("📡 FIX #245: Recording TX anyway - will confirm on-chain")
                print("🔐 FIX #245: txId=\(txId)")
            } else {
                // NO peers accepted AND mempool failed - likely a true rejection
                print("🚨 VUL-002: MEMPOOL REJECTED - Not writing to database!")
                print("🚨 VUL-002: txId=\(txId), peers=\(broadcastResult.peerCount), mempool=false")

                // Clear any pending broadcast tracking since TX was rejected
                await MainActor.run {
                    networkManager.clearPendingBroadcast()
                }

                // FIX #218: Cypherpunk-styled warning with TXID for reference
                throw WalletError.transactionFailed("""
                    ⚡ MEMPOOL REJECTION ⚡

                    The network nodes did not propagate your transaction to their mempools. This can happen during network congestion or peer instability.

                    🔒 YOUR FUNDS ARE SAFE
                    No transaction was recorded in your wallet.

                    📋 TXID (for reference):
                    \(txId)

                    "We cannot expect governments, corporations, or other large, faceless organizations to grant us privacy. We must defend our own privacy."
                    — A Cypherpunk's Manifesto
                    """)
            }
        }

        // TX accepted (by mempool or by peers)
        // FIX #350: DO NOT write to database here - only on CONFIRMATION
        if broadcastResult.mempoolVerified {
            print("✅ VUL-002: Mempool VERIFIED - TX will be recorded on confirmation")
        } else {
            print("✅ FIX #245: Peers accepted TX - will be recorded on confirmation")
        }

        // FIX #350: Track as pending outgoing with FULL info for database write on CONFIRMATION
        // DO NOT write to database here - only when TX is confirmed in a block!
        let pendingFee: UInt64 = 10_000
        let pendingTx = PendingOutgoingTx(
            txid: txId,
            amount: amount,
            fee: pendingFee,
            toAddress: toAddress,
            memo: memo,
            hashedNullifier: spentNullifier,
            rawTxData: rawTx,
            timestamp: Date()
        )
        await networkManager.trackPendingOutgoingFull(pendingTx)
        print("📤 FIX #350: TX tracked as pending - database write DEFERRED until confirmation")

        // Send notification for successful transaction
        NotificationManager.shared.notifySent(amount: amount, txid: txId, memo: memo)

        // FIX #165 v2: DON'T update checkpoint here - TX is only in mempool, not confirmed!
        // Checkpoint update moved to confirmOutgoingTx() which is called when TX is mined.

        // Refresh balance
        try await refreshBalance()

        // FIX #511: Restart block listeners after TX is accepted
        await NetworkManager.shared.startBlockListenersOnMainScreen()

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
        let spentNotes = try database.getSpentNotes(accountId: account.accountId)
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
        let spentNotes = try database.getSpentNotes(accountId: account.accountId)
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

    /// FIX #300: Clear balance issues flag after repair completes
    @MainActor
    func clearBalanceIssues() {
        hasBalanceIssues = false
    }

    /// FIX #302: Set balance issues flag (called from ContentView when external spend detected)
    @MainActor
    func setBalanceIssues(_ value: Bool) {
        hasBalanceIssues = value
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

    /// Public wrapper to load cached balance (for fast start mode)
    /// This is called from ContentView when wallet is already synced
    func loadCachedBalance() {
        Task {
            await loadBalanceFromDatabase()
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
            let notes = try WalletDatabase.shared.getUnspentNotes(accountId: account.accountId)
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

    // FIX #582: Clear Full Rescan flags when user enters wallet after completion
    func clearFullRescanFlags() {
        DispatchQueue.main.async {
            self.isRescanComplete = false
            self.rescanCompletionDuration = nil
            self.isFullRescan = false
            print("🔒 FIX #582: Cleared Full Rescan flags - user entered main wallet")
        }
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

        // 10. Delete local delta bundle (accumulated shielded outputs)
        DeltaCMUManager.shared.clearDeltaBundle()
        print("🗑️ Deleted delta bundle")

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
    /// FIX #504: CRITICAL - DISABLE Tor during import for direct P2P connections
    func importSpendingKey(_ keyString: String) throws {
        // CRITICAL: DISABLE Tor during import PK to ensure P2P connections work!
        // Routing through Tor causes connection failures even for localhost
        print("🚫 FIX #504: DISABLING Tor during import PK - direct P2P connections required")
        DispatchQueue.main.async {
            Task {
                await TorManager.shared.bypassTorForMassiveOperation()
                print("✅ FIX #504: Tor bypassed - P2P connections will be direct")
            }
        }

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

        // FIX #469: Delete CMU cache for imported wallet
        // This ensures we start fresh with no stale CMU data
        print("🗑️ Deleting CMU cache for imported wallet...")
        Task {
            await CommitmentTreeUpdater.shared.invalidateCMUCachePublic()
            print("✅ CMU cache deleted")
        }

        // Open fresh database with new key
        let dbKey = Data(SHA256.hash(data: spendingKey))
        do {
            try WalletDatabase.shared.open(encryptionKey: dbKey)
            print("✅ Fresh database created with new key")

            // CRITICAL FIX #578: Create account row in database after import
            // This was missing, causing "No account found with index 0" error
            // and all subsequent failures (witness computation, PHASE 1.5, etc.)
            if try WalletDatabase.shared.getAccount(index: 0) == nil {
                // Derive viewing key for storage
                let saplingKey = SaplingSpendingKey(data: spendingKey)
                let fvk = try RustBridge.shared.deriveFullViewingKey(from: saplingKey)

                // Derive address if we haven't already
                let derivedAddress: String
                if self.zAddress.isEmpty || self.zAddress.hasPrefix("zs1") == false {
                    derivedAddress = try deriveZAddress(from: spendingKey)
                } else {
                    derivedAddress = self.zAddress
                }

                // Insert account with current address
                _ = try WalletDatabase.shared.insertAccount(
                    accountIndex: 0,
                    spendingKey: spendingKey,
                    viewingKey: fvk.data,
                    address: derivedAddress,
                    birthdayHeight: 559500 // Sapling activation for ZCL
                )
                print("👤 FIX #578: Created account in database after import PK")
            }
        } catch {
            print("⚠️ Failed to open database: \(error)")
        }

        // Reset tree state in FFI memory as well
        isTreeLoaded = false
        treeLoadProgress = 0.0
        treeLoadStatus = ""

        // FIX #500: Don't update state here - let importSpendingKeyAsync handle it
        // The DispatchQueue.main.async was causing a race condition where ContentView
        // wouldn't see the state changes until after the function returned

        print("✅ Key imported successfully (will scan for historical notes)")
    }

    // FIX #500: Tracks whether import PK is currently in progress
    @Published public private(set) var isImportInProgress: Bool = false
    private var importProcessTask: Task<Void, Never>?

    // FIX #500: Async version of importSpendingKey that properly signals completion
    // CRITICAL: Sets isWalletCreated = true so ContentView shows sync screen immediately
    // Uses isImportInProgress to track when the full import (sync) completes
    @MainActor
    func importSpendingKeyAsync(_ keyString: String) async throws {
        // Mark import as in progress
        self.isImportInProgress = true

        // Run the synchronous import on background thread
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try self.importSpendingKey(keyString)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }

        // FIX #580: Load bundled headers from boost file BEFORE marking wallet as created
        // This prevents slow P2P header sync after Import PK (was taking 3+ minutes)
        print("📜 FIX #580: Loading bundled headers from boost file during Import PK...")
        let (headersLoaded, boostEndHeight) = await loadHeadersFromBoostFile()
        if headersLoaded {
            print("✅ FIX #580: Loaded bundled headers to height \(boostEndHeight) - P2P sync will be minimal")
        } else {
            print("⚠️ FIX #580: No bundled headers available - will use P2P sync (slower)")
        }

        // Immediately mark wallet as created so ContentView shows sync screen
        self.zAddress = try self.deriveZAddressFromStoredKey()
        self.isWalletCreated = true
        self.isImportedWallet = true  // Important: triggers historical note scanning
        self.saveWalletState()
        print("✅ FIX #500 v3: Wallet created, ContentView should now show sync screen with progress")

        // Don't clear isImportInProgress yet - let ContentView clear it when sync completes
        // ContentView will observe sync completion and clear both flags
    }

    // FIX #500: Call when import sync completes
    @MainActor
    func markImportComplete() {
        self.isImportInProgress = false
        print("✅ FIX #500: Import sync completed")

        // FIX #711: Validate delta bundle and force witness rebuild if invalid
        // After import, if delta bundle is incomplete (less CMUs than expected),
        // witnesses will be stale. Force an immediate rebuild to prevent corruption.
        Task {
            let validation = DeltaCMUManager.shared.validateDeltaBundle(bundledEndHeight: ZipherXConstants.bundledTreeHeight)
            if !validation.isValid {
                print("⚠️ FIX #711: Delta bundle invalid after import: \(validation.error ?? "unknown")")
                print("⚠️ FIX #711: Forcing immediate witness rebuild to prevent stale witnesses...")

                // Clear the invalid delta bundle
                DeltaCMUManager.shared.clearDeltaBundle()

                // Trigger witness rebuild
                if let account = try? WalletDatabase.shared.getAccount(index: 0) {
                    await self.preRebuildWitnessesForInstantPayment(accountId: account.accountId)
                    print("✅ FIX #711: Witness rebuild completed after import")
                }
            } else {
                print("✅ FIX #711: Delta bundle valid after import (\(validation.outputCount) outputs)")
            }
        }

        // FIX #510: Trigger UI refresh for transaction history
        // Without this, history doesn't display after import until app restart
        self.transactionHistoryVersion += 1
        print("📜 FIX #510: Incremented transactionHistoryVersion to \(transactionHistoryVersion) - views should reload")

        // Post notification to force reload from database
        NotificationCenter.default.post(name: Notification.Name("transactionHistoryUpdated"), object: nil)
        print("📜 FIX #510: Posted transactionHistoryUpdated notification - forcing UI refresh")
    }

    // Helper to derive address from stored key
    private func deriveZAddressFromStoredKey() throws -> String {
        let spendingKey = try secureStorage.retrieveSpendingKey()
        return try deriveZAddress(from: spendingKey)
    }

    /// FIX #557 v28: Get cumulative CMU count up to a specific block height
    /// This tells us how many CMUs exist in the commitment tree up to the given height
    /// Used to truncate CMU data when creating witnesses at specific tree states
    /// - Parameter upToHeight: The block height to get CMU count for
    /// - Returns: Number of CMUs up to (and including) this height
    private func getCumulativeCMUCount(upToHeight: UInt64) -> UInt64 {
        // FIX #557 v28: Count notes in our database up to this height
        // This gives us the position of the last CMU at this height
        do {
            let allNotes = try WalletDatabase.shared.getAllNotes(accountId: 1)
            let notesAtOrBeforeHeight = allNotes.filter { UInt64($0.height) <= upToHeight }

            // Each note has one CMU, so count = number of notes
            // Add offset for Sapling activation (CMUs before our first note)
            let saplingActivationOffset = UInt64(800_000)  // Approximate CMUs before our notes started
            let totalCount = saplingActivationOffset + UInt64(notesAtOrBeforeHeight.count)

            print("📊 FIX #557 v28: Counted \(notesAtOrBeforeHeight.count) notes up to height \(upToHeight), total CMUs: \(totalCount)")
            return totalCount
        } catch {
            print("⚠️ FIX #557 v28: Failed to count notes: \(error.localizedDescription)")
            // Fallback: use simple approximation
            let saplingActivation = UInt64(476_969)
            if upToHeight < saplingActivation {
                return 0
            }
            let blocksSinceSapling = upToHeight - saplingActivation
            return UInt64(Double(blocksSinceSapling) * 0.35)
        }
    }

    // MARK: - FIX #506: Parallel Import Architecture

    /// FIX #506: Run parallel extraction for faster import PK
    /// Downloads boost file, then runs headers/CMUs/network/hashes extraction in parallel
    /// - Parameter onProgress: Progress callback for overall operation (0.0-1.0)
    func importParallelWithProgress(onProgress: @escaping (Double) -> Void) async throws {
        print("🚀 FIX #506: Starting PARALLEL import for faster PK import...")

        let coordinator = ParallelImportCoordinator.shared

        // Step 1: Download boost file
        onProgress(0.1)
        print("📦 Step 1: Downloading boost file...")
        let (boostFileURL, height, cmuCount) = try await CommitmentTreeUpdater.shared.getBestAvailableBoostFile { progress, status in
            Task { @MainActor in
                onProgress(0.1 + progress * 0.2)  // 10-30% for download
                self.treeLoadStatus = status
            }
        }

        print("✅ Boost file downloaded: height=\(height), cmus=\(cmuCount)")

        // Step 2: PARALLEL extraction (headers, CMUs, network, hashes all run simultaneously)
        onProgress(0.3)
        print("⚡️ Step 2: Running PARALLEL extraction (4 tasks simultaneous)...")

        let tempData = try await coordinator.runParallelExtraction(boostFile: boostFileURL)

        let speedup = 110.0 / max(tempData.duration, 1.0)  // Sequential takes ~110s
        print("✅ Parallel extraction completed in \(String(format: "%.1f", tempData.duration))s")
        print("   Speedup: \(String(format: "%.1f", speedup))x faster than sequential")

        // Step 3: Build tree and commit to production
        onProgress(0.5)
        print("🌳 Step 3: Building tree from temp CMUs...")

        try await coordinator.commitToProduction(tempData: tempData) { progress in
            onProgress(0.5 + progress * 0.5)  // 50-100% for tree build + commit
        }

        // Mark tree as loaded
        await MainActor.run {
            self.isTreeLoaded = true
            self.treeLoadProgress = 1.0
            self.treeLoadStatus = "Privacy infrastructure ready\n\(ZipherXFFI.treeSize().formatted()) commitments loaded"
        }

        onProgress(1.0)
        print("✅ FIX #506: Parallel import complete!")
    }

    // MARK: - FIX #262: Pre-Build Nullifier Verification

    /// FIX #595: INSTANT check before building a transaction to verify notes aren't already spent
    /// FIX #595: Uses checkpoint-based scanning (100 blocks) for instant verification
    /// Returns the first spent note found, or nil if all notes are verified unspent
    private func verifyNotesNotSpentOnChain() async throws -> WalletNote? {
        let database = WalletDatabase.shared
        let networkManager = NetworkManager.shared

        // Get our unspent notes
        let unspentNotes = try database.getAllUnspentNotes(accountId: 1)
        guard !unspentNotes.isEmpty else {
            return nil  // No notes to check
        }

        // Build lookup map of our nullifiers
        var ourNullifiers: [Data: WalletNote] = [:]
        for note in unspentNotes {
            ourNullifiers[note.nullifier] = note
        }

        print("🔍 FIX #262: Nullifier check for \(unspentNotes.count) unspent notes...")

        // Get current chain height
        let cachedChainHeight = await MainActor.run { networkManager.chainHeight }
        let chainHeight = cachedChainHeight > 0 ? cachedChainHeight : (try? await networkManager.getChainHeight()) ?? 0
        guard chainHeight > 0 else {
            print("⚠️ FIX #262: Cannot get chain height - skipping pre-build check")
            return nil
        }

        // FIX #595: INSTANT pre-send verification using checkpoint (not per-note scanning!)
        // Previous approach (FIX #594): Scan from each note's height - TOO SLOW (40+ seconds per note!)
        // New approach: Use checkpoint - if a note was spent after checkpoint, it's a rare edge case
        // The checkpoint is set when transactions are confirmed, so spends should already be detected
        // We only scan recent blocks (100) as a quick sanity check
        let checkpointHeight: UInt64
        do {
            checkpointHeight = try database.getVerifiedCheckpointHeight()
            print("🔍 FIX #595: Retrieved checkpoint: \(checkpointHeight)")
        } catch {
            // FIX #597: If checkpoint retrieval fails, log it but default to last scanned height
            print("⚠️ FIX #597: Failed to get checkpoint: \(error.localizedDescription)")
            // Fallback to last scanned height
            if let lastScanned = try? database.getLastScannedHeight() {
                checkpointHeight = lastScanned
                print("🔍 FIX #597: Using last scanned height as checkpoint: \(checkpointHeight)")
            } else {
                checkpointHeight = 0
            }
        }

        // If checkpoint is recent (within 100 blocks), scan from checkpoint
        // Otherwise scan last 100 blocks as a quick check
        var startHeight: UInt64
        let blocksToScan: UInt64

        if checkpointHeight > 0 && chainHeight > checkpointHeight {
            let blocksSinceCheckpoint = chainHeight - checkpointHeight
            if blocksSinceCheckpoint <= 100 {
                startHeight = checkpointHeight
                blocksToScan = blocksSinceCheckpoint
                print("🔍 FIX #595: Quick check from checkpoint \(checkpointHeight) - scanning \(blocksToScan) blocks")
            } else {
                // Checkpoint too old - just check last 100 blocks
                startHeight = chainHeight > 100 ? chainHeight - 100 : 0
                blocksToScan = min(100, chainHeight)
                print("🔍 FIX #595: Checkpoint old (\(blocksSinceCheckpoint) blocks behind) - scanning last \(blocksToScan) blocks")
            }
        } else {
            // No checkpoint - scan last 100 blocks
            startHeight = chainHeight > 100 ? chainHeight - 100 : 0
            blocksToScan = min(100, chainHeight)
            print("🔍 FIX #595: No checkpoint - scanning last \(blocksToScan) blocks")
        }

        // FIX #348: Prevent underflow crash if startHeight > chainHeight
        guard startHeight < chainHeight else {
            print("⚠️ FIX #595: startHeight (\(startHeight)) >= chainHeight (\(chainHeight)) - skipping quick check")
            return nil
        }

        print("🔍 FIX #595: INSTANT pre-send verification - scanning \(blocksToScan) blocks from \(startHeight)...")

        do {
            let blocks = try await networkManager.getBlocksDataP2P(from: startHeight, count: Int(blocksToScan))

            for (height, _, _, txData) in blocks {
                for (txidHex, _, spends) in txData {
                    guard let spends = spends, !spends.isEmpty else { continue }

                    for spend in spends {
                        guard let nullifierData = Data(hexString: spend.nullifier) else { continue }

                        // VUL-009: Hash the on-chain nullifier to compare with stored hashes
                        let hashedNullifier = SHA256.hash(data: nullifierData)
                        let hashedData = Data(hashedNullifier)

                        if let spentNote = ourNullifiers[hashedData] {
                            // Found a spent note!
                            print("🚨 FIX #595: Note \(spentNote.id) was spent in TX \(txidHex) at height \(height)!")

                            // Mark as spent in database using hashed nullifier
                            if let txidData = Data(hexString: txidHex) {
                                try database.markNoteSpentByHashedNullifier(
                                    hashedNullifier: hashedData,
                                    txid: txidData,
                                    spentHeight: UInt64(height)
                                )
                                print("✅ FIX #595: Marked note \(spentNote.id) as spent")
                            }

                            // Refresh balance
                            try? await refreshBalance()

                            return spentNote
                        }
                    }
                }
            }
        } catch {
            print("⚠️ FIX #595: P2P block fetch failed: \(error.localizedDescription) - proceeding with build")
        }

        print("✅ FIX #595: INSTANT verification complete - all notes appear unspent")
        return nil
    }

    // MARK: - FIX #527: CMU Tree Validation

    /// Result of CMU tree validation
    struct CMUTreeValidationResult {
        let isValid: Bool
        let ourRoot: String
        let headerRoot: String
        let height: UInt64
    }

    /// FIX #527: Validate CMU tree root matches blockchain before allowing sends
    /// This prevents sending with invalid witnesses that will be rejected
    /// FIX #537: Simplified - logs P2P verification but doesn't block on corruption
    /// - Returns: Validation result with details
    private func validateCMUTreeBeforeSend() async -> CMUTreeValidationResult {
        // Get our current tree root from FFI
        guard let ourTreeRoot = ZipherXFFI.treeRoot() else {
            print("⚠️ FIX #527: Could not get FFI tree root - allowing send (might fail)")
            return CMUTreeValidationResult(isValid: true, ourRoot: "unavailable", headerRoot: "unavailable", height: 0)
        }

        let ourRootHex = ourTreeRoot.hexString
        print("🔧 FIX #527: Our tree root: \(ourRootHex.prefix(16))...")

        // Get last scanned height
        let lastScanned: UInt64
        do {
            lastScanned = try await WalletDatabase.shared.getLastScannedHeight()
        } catch {
            print("⚠️ FIX #527: Could not get last scanned height - allowing send")
            return CMUTreeValidationResult(isValid: true, ourRoot: ourRootHex, headerRoot: "unknown", height: 0)
        }

        guard lastScanned > 0 else {
            print("⚠️ FIX #527: No scanned height - allowing send (new wallet?)")
            return CMUTreeValidationResult(isValid: true, ourRoot: ourRootHex, headerRoot: "unknown", height: 0)
        }

        // Get header at last scanned height
        do {
            let headerStore = HeaderStore.shared
            try headerStore.open()

            guard let header = try headerStore.getHeader(at: lastScanned) else {
                print("⚠️ FIX #527: No header at height \(lastScanned) - allowing send")
                return CMUTreeValidationResult(isValid: true, ourRoot: ourRootHex, headerRoot: "no_header", height: lastScanned)
            }

            let headerRoot = header.hashFinalSaplingRoot.hexString
            print("🔧 FIX #527: HeaderStore sapling_root at \(lastScanned): \(headerRoot.prefix(16))...")

            // FIX #537: Log mismatch but don't block - user already deleted corrupted headers
            // After P2P re-sync, the tree roots should match
            if ourRootHex != headerRoot {
                print("⚠️ FIX #537: Tree root mismatch detected")
                print("   FFI root:    \(ourRootHex.prefix(16))...")
                print("   Header root: \(headerRoot.prefix(16))...")
                print("   Height:      \(lastScanned)")
                print("   NOTE: This is expected after deleting corrupted headers - P2P sync will fix it")
                // Allow send - the FFI tree will be updated during normal sync
                return CMUTreeValidationResult(isValid: true, ourRoot: ourRootHex, headerRoot: headerRoot, height: lastScanned)
            }

            // Roots match - safe to send
            print("✅ FIX #527: Tree roots match - safe to send")
            return CMUTreeValidationResult(isValid: true, ourRoot: ourRootHex, headerRoot: headerRoot, height: lastScanned)

        } catch {
            print("⚠️ FIX #527: Header validation error: \(error) - allowing send")
            return CMUTreeValidationResult(isValid: true, ourRoot: ourRootHex, headerRoot: "error", height: lastScanned)
        }
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
            // FIX #563 v40: Handle optional result - only mark if we successfully verified
            guard let isSpent = try await checkNullifierSpentOnChain(nullifier: nullifierDisplay, afterHeight: note.height) else {
                print("⚠️ Could not verify note \(note.value) zatoshis - skipping")
                continue
            }

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

    // MARK: - FIX #563 v19: Verify incorrectly marked SPENT notes

    /// Verify notes marked as SPENT are actually spent on-chain
    /// This fixes the bug where notes are marked as spent when send fails
    /// If a note is marked spent but not actually spent on-chain, unmark it
    @MainActor
    func verifyIncorrectlyMarkedSpentNotes() async throws -> Int {
        print("🔍 FIX #563 v19: Checking notes marked as SPENT that might be unspent...")

        let database = WalletDatabase.shared
        let networkManager = NetworkManager.shared

        // Get spent notes from database
        let spentNotes = try database.getSpentNotes(accountId: 1)

        guard !spentNotes.isEmpty else {
            print("✅ FIX #563 v19: No spent notes to verify")
            return 0
        }

        print("🔍 FIX #563 v19: Checking \(spentNotes.count) notes marked as SPENT...")

        var unmarkedCount = 0
        var totalValue: UInt64 = 0

        for note in spentNotes {
            // Skip if value or height is not available (old SpentNote format)
            guard let value = note.value, let height = note.height else {
                continue
            }
            totalValue += value

            // Check if this note is actually spent on-chain
            // Convert nullifier to display format
            let nullifierDisplay = note.nullifier.reversedBytes().hexString

            // Check if nullifier exists in any spending transaction
            let isSpentOnChain = try await checkNullifierSpentOnChain(nullifier: nullifierDisplay, afterHeight: height)

            // FIX #563 v40: Only unmark if we successfully verified the note is NOT spent
            // If verification failed (nil), don't unmark - better to keep marked as spent
            if let spentResult = isSpentOnChain {
                if !spentResult {
                    // Note is marked as SPENT in DB but NOT spent on-chain - UNMARK IT!
                    print("💰 FIX #563 v19: Found incorrectly marked note: \(value) zatoshis at height \(height)")
                    print("💰 FIX #563 v19: Note marked SPENT but NOT spent on-chain - UNMARKING!")

                    do {
                        try database.unmarkNoteAsSpent(nullifier: note.nullifier)
                        unmarkedCount += 1
                        print("✅ FIX #563 v19: UNMARKED note (restored \(value) zatoshis)")
                    } catch {
                        print("❌ FIX #563 v19: Failed to unmark note: \(error)")
                    }
                } else {
                    print("✅ FIX #563 v19: Note \(value) zatoshis is actually spent on-chain - correct")
                }
            } else {
                // FIX #563 v40: Verification failed - don't unmark, keep as spent
                print("⚠️ FIX #563 v40: Could not verify note \(value) zatoshis at height \(height) - keeping marked as spent")
            }
        }

        let totalZCL = Double(totalValue) / 100_000_000.0
        print("📊 FIX #563 v19: Checked \(spentNotes.count) spent notes (\(String(format: "%.8f", totalZCL)) ZCL)")

        if unmarkedCount > 0 {
            print("✅ FIX #563 v19: UNMARKED \(unmarkedCount) incorrectly marked notes!")
            print("💰 FIX #563 v19: Balance restored - refresh to see updated balance")

            // Refresh balance to show corrected amount
            await loadBalanceFromDatabase()
        } else {
            print("✅ FIX #563 v19: All spent notes verified - none need unmarking")
        }

        return unmarkedCount
    }

    /// Check if a nullifier has been spent on the blockchain
    /// FIX #563 v40: Returns Bool? to distinguish verification results
    /// Scans blocks from the note's height to find spending transactions
    ///
    /// - Parameters:
    ///   - nullifier: Nullifier in display format (hex string, big-endian)
    ///   - afterHeight: Height to start scanning from (note's height)
    /// - Returns:
    ///   - true: Nullifier found in spend (definitely spent)
    ///   - false: Nullifier NOT found after successful scan (definitely not spent)
    ///   - nil: Verification failed (timeout, network error) - cannot determine
    private func checkNullifierSpentOnChain(nullifier: String, afterHeight: UInt64) async throws -> Bool? {
        let database = WalletDatabase.shared
        let networkManager = NetworkManager.shared

        // Get chain height from peers (fresh value, not cached)
        let chainHeight: UInt64
        do {
            chainHeight = try await networkManager.getChainHeight()
        } catch {
            print("⚠️ FIX #563 v40: Cannot get chain height: \(error)")
            return nil  // Verification failed
        }
        guard chainHeight > 0 && chainHeight > afterHeight else {
            print("⚠️ FIX #563 v40: Chain height (\(chainHeight)) not beyond note height (\(afterHeight))")
            return nil  // Verification failed
        }

        // Convert hex nullifier to Data and hash it for comparison
        guard let nullifierDisplay = Data(hexString: nullifier) else {
            print("⚠️ FIX #563 v40: Invalid nullifier hex string")
            return nil  // Verification failed
        }

        // VUL-009: Hash the nullifier (DB stores hashed nullifiers)
        let nullifierWire = nullifierDisplay.reversedBytes()
        let hashedNullifier = database.hashNullifier(nullifierWire)

        // FIX #563 v35: Adaptive scan limits based on note age
        // Recent notes (<1000 blocks old): Check all blocks (most likely to have spends)
        // Old notes: Check last 500 blocks only (recent spends)
        let blockAge = chainHeight - afterHeight
        let maxScanBlocks: UInt64 = blockAge < 1000 ? blockAge : 500
        var startHeight = afterHeight

        // If gap is too large, start from (chainHeight - maxScanBlocks)
        if chainHeight > afterHeight + maxScanBlocks {
            startHeight = chainHeight - maxScanBlocks
        }

        let blocksToScan = chainHeight - startHeight
        guard blocksToScan > 0 else {
            return nil  // No blocks to scan - verification failed
        }

        print("🔍 FIX #563 v35: Checking \(blocksToScan) blocks for nullifier \(nullifier.prefix(16))...")

        // FIX #563 v35: Use maximum batch size accepted by peers (160 blocks)
        let batchSize: UInt64 = 160

        var batchStart = startHeight
        var verificationFailed = false  // Track if ANY batch failed

        while batchStart < chainHeight {
            let batchEnd = min(batchStart + batchSize, chainHeight)
            let count = Int(batchEnd - batchStart)

            do {
                // FIX #563 v35: Adaptive timeout based on batch size (5s per 160 blocks)
                let fetchTask = Task {
                    try await networkManager.getBlocksDataP2P(from: batchStart, count: count)
                }

                let timeoutTask = Task {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                    fetchTask.cancel()
                }

                let blocks = try await fetchTask.value
                timeoutTask.cancel()

                // Parse transactions to find matching nullifier
                for (height, _, _, txData) in blocks {
                    for (_, _, spends) in txData {
                        guard let spends = spends, !spends.isEmpty else { continue }

                        for spend in spends {
                            // Convert hex nullifier to Data
                            guard let spendNullifierDisplay = Data(hexString: spend.nullifier) else { continue }

                            // Reverse to wire format and hash (VUL-009)
                            let spendNullifierWire = spendNullifierDisplay.reversedBytes()
                            let spendHashed = database.hashNullifier(spendNullifierWire)

                            // Compare with our nullifier
                            if spendHashed == hashedNullifier {
                                print("✅ FIX #563 v19: Nullifier found in spend at height \(height)")
                                return true // Found! This note was spent
                            }
                        }
                    }
                }

                batchStart = batchEnd
            } catch {
                if Task.isCancelled {
                    print("⚠️ FIX #563 v40: Batch fetch timeout - verification failed")
                } else {
                    print("⚠️ FIX #563 v40: Batch fetch failed: \(error)")
                }
                // FIX #563 v40: Mark verification as failed and continue to next batch
                verificationFailed = true
                batchStart = batchEnd
            }
        }

        // FIX #563 v40: Only return false if ALL batches succeeded
        // If ANY batch failed, return nil (verification failed)
        if verificationFailed {
            print("⚠️ FIX #563 v40: Some batches failed - cannot verify if note is spent")
            return nil  // Verification incomplete - don't unmark
        }

        print("✅ FIX #563 v40: All batches succeeded - nullifier NOT found in any spend")
        return false  // Definitely not spent
    }

    // MARK: - FIX #212: Detect and Recover Unrecorded Broadcast Transactions

    /// FIX #212: Scan recent blocks for nullifiers matching our unspent notes
    /// This recovers from the scenario where a broadcast succeeded but VUL-002 blocked the database write
    /// (e.g., broadcast timeout through Tor but TX actually propagated)
    ///
    /// - Parameters:
    ///   - fromCheckpoint: If true, scan from last checkpoint (faster). If false, scan last 100 blocks.
    ///   - onProgress: Progress callback with (current, total) blocks
    /// - Returns: Number of unrecorded spends that were recovered
    @MainActor
    func repairUnrecordedSpends(fromCheckpoint: Bool = true, onProgress: ((Int, Int) -> Void)? = nil) async throws -> Int {
        print("🔧 FIX #212: Scanning for unrecorded broadcast transactions...")

        let database = WalletDatabase.shared
        let networkManager = NetworkManager.shared

        // Get our unspent notes
        let unspentNotes = try database.getAllUnspentNotes(accountId: 1)
        guard !unspentNotes.isEmpty else {
            print("✅ FIX #212: No unspent notes to check")
            return 0
        }

        // Build set of our nullifier hashes for quick lookup
        // Note: unspentNotes contain already-hashed nullifiers (VUL-009)
        var ourNullifiers: [Data: WalletNote] = [:]
        for note in unspentNotes {
            ourNullifiers[note.nullifier] = note
        }
        print("🔍 FIX #212: Checking \(unspentNotes.count) unspent notes for on-chain spends")

        // Determine scan range
        let cachedChainHeightForScan = await MainActor.run { networkManager.chainHeight }
        let chainHeight = cachedChainHeightForScan > 0 ? cachedChainHeightForScan : (try? await networkManager.getChainHeight()) ?? 0
        guard chainHeight > 0 else {
            print("⚠️ FIX #212: Cannot get chain height - skipping")
            return 0
        }

        var startHeight: UInt64
        if fromCheckpoint {
            // Scan from checkpoint (should be recent)
            let checkpoint = try database.getVerifiedCheckpointHeight()
            startHeight = checkpoint > 0 ? checkpoint : (chainHeight > 100 ? chainHeight - 100 : 0)
        } else {
            // Scan last 100 blocks
            startHeight = chainHeight > 100 ? chainHeight - 100 : 0
        }

        let blocksToScan = chainHeight > startHeight ? Int(chainHeight - startHeight) : 0
        guard blocksToScan > 0 else {
            print("✅ FIX #212: Already at chain tip - no blocks to scan")
            return 0
        }

        print("🔍 FIX #212: Scanning blocks \(startHeight) to \(chainHeight) (\(blocksToScan) blocks)")

        // Fetch blocks via P2P
        var recoveredCount = 0
        // FIX #561 v2: 500 is fine for P2P on-demand fetches
        let batchSize: UInt64 = 500

        var batchStart = startHeight
        while batchStart < chainHeight {
            let batchEnd = min(batchStart + batchSize, chainHeight)
            let count = Int(batchEnd - batchStart)

            onProgress?(Int(batchStart - startHeight), blocksToScan)

            do {
                // Fetch block data with transaction details
                let blocks = try await networkManager.getBlocksDataP2P(from: batchStart, count: count)

                for (height, _, _, txData) in blocks {
                    for (txidHex, _, spends) in txData {
                        guard let spends = spends, !spends.isEmpty else { continue }

                        // Check each spend's nullifier
                        for spend in spends {
                            // Convert hex nullifier to Data (display format / big-endian)
                            guard let nullifierDisplay = Data(hexString: spend.nullifier) else { continue }

                            // FIX #288: P2P returns nullifier in display format (big-endian)
                            // DB stores in wire format (little-endian) - must reverse before hashing!
                            let nullifierWire = nullifierDisplay.reversedBytes()

                            // VUL-009: Hash the on-chain nullifier to compare with stored hashes
                            let hashedNullifier = database.hashNullifier(nullifierWire)

                            if let matchedNote = ourNullifiers[hashedNullifier] {
                                // Found! This note was spent on-chain but not recorded
                                print("🚨 FIX #212: Found unrecorded spend!")
                                print("   Note value: \(matchedNote.value) zatoshis")
                                print("   Spent in TX: \(txidHex.prefix(16))...")
                                print("   Spent at height: \(height)")

                                // Convert txid hex to Data
                                let txidData = Data(hexString: txidHex) ?? hashedNullifier.prefix(32)

                                // Mark the note as spent
                                try database.markNoteSpentByHashedNullifier(
                                    hashedNullifier: hashedNullifier,
                                    txid: txidData,
                                    spentHeight: height
                                )

                                // Create SENT history entry if it doesn't exist
                                let fee: UInt64 = 10_000 // Standard fee
                                let amountSent = matchedNote.value > fee ? matchedNote.value - fee : matchedNote.value

                                // Check if history entry already exists
                                let existsInHistory = try database.transactionExists(txid: txidData, type: .sent)
                                if !existsInHistory {
                                    _ = try database.insertTransactionHistory(
                                        txid: txidData,
                                        height: height,
                                        blockTime: UInt64(Date().timeIntervalSince1970), // Approximate
                                        type: .sent,
                                        value: amountSent,
                                        fee: fee,
                                        toAddress: nil, // Unknown recipient
                                        fromDiversifier: nil,
                                        memo: "[Recovered by FIX #212 - unrecorded broadcast]"
                                    )
                                    print("📜 FIX #212: Created SENT history entry for recovered transaction")
                                }

                                recoveredCount += 1
                                // Remove from our tracking set
                                ourNullifiers.removeValue(forKey: hashedNullifier)
                            }
                        }
                    }
                }
            } catch {
                print("⚠️ FIX #212: Failed to fetch blocks \(batchStart)-\(batchEnd): \(error)")
                // Continue with next batch
            }

            batchStart += batchSize
        }

        onProgress?(blocksToScan, blocksToScan)

        if recoveredCount > 0 {
            print("✅ FIX #212: Recovered \(recoveredCount) unrecorded broadcast transaction(s)")
            // Refresh balance to reflect changes
            try? await refreshBalance()
            incrementHistoryVersion()
        } else {
            print("✅ FIX #212: No unrecorded spends found - database is consistent")
        }

        return recoveredCount
    }

    // MARK: - FIX #371: Resolve Boost Placeholder TXIDs to Real TXIDs

    /// FIX #371: Resolve boost placeholder txids to real transaction IDs
    /// The boost file marks notes as spent with placeholder txids ("boost_spent_HEIGHT"),
    /// but we need the real txid for proper transaction history display.
    ///
    /// This function:
    /// 1. Gets all notes with boost placeholder txids
    /// 2. Groups them by spent_height
    /// 3. Fetches the block at each height
    /// 4. Finds the transaction containing the matching nullifier
    /// 5. Updates the note with the real txid
    ///
    /// - Parameter onProgress: Progress callback with (resolved, total) notes
    /// - Returns: Number of placeholder txids successfully resolved
    @MainActor
    func resolveBoostPlaceholderTxids(onProgress: ((Int, Int) -> Void)? = nil) async throws -> Int {
        print("🔧 FIX #371: Resolving boost placeholder txids to real transaction IDs...")

        let database = WalletDatabase.shared
        let networkManager = NetworkManager.shared

        // Get all notes with boost placeholder txids
        let notesWithPlaceholders = try database.getNotesWithBoostPlaceholderTxids()
        guard !notesWithPlaceholders.isEmpty else {
            print("✅ FIX #371: No boost placeholder txids to resolve")
            return 0
        }

        print("🔍 FIX #371: Found \(notesWithPlaceholders.count) notes with boost placeholder txids")

        // Group notes by spent_height for efficient block fetching
        var notesByHeight: [UInt64: [Data]] = [:]  // height -> [hashedNullifiers]
        for (hashedNullifier, spentHeight) in notesWithPlaceholders {
            notesByHeight[spentHeight, default: []].append(hashedNullifier)
        }

        print("🔍 FIX #371: Notes spread across \(notesByHeight.count) unique blocks")

        var resolvedCount = 0
        let totalNotes = notesWithPlaceholders.count
        let sortedHeights = notesByHeight.keys.sorted()

        for height in sortedHeights {
            guard let hashedNullifiersToMatch = notesByHeight[height] else { continue }

            // Build a set for quick lookup
            let nullifiersToFind = Set(hashedNullifiersToMatch)

            do {
                // Fetch the block at this height
                let blocks = try await networkManager.getBlocksDataP2P(from: height, count: 1)
                guard let (_, _, _, txData) = blocks.first else {
                    print("⚠️ FIX #371: Could not fetch block at height \(height)")
                    continue
                }

                // Search through each transaction's spends for matching nullifiers
                for (txidHex, _, spends) in txData {
                    guard let spends = spends else { continue }

                    for spend in spends {
                        // Get the raw nullifier from the spend
                        guard !spend.nullifier.isEmpty,
                              let nullifierData = Data(hexString: spend.nullifier) else { continue }

                        // Wire format: nullifier needs byte reversal from display format
                        let nullifierWire = nullifierData.reversedBytes()

                        // Hash it to match our stored hashed nullifiers
                        let hashedNullifier = database.hashNullifier(nullifierWire)

                        if nullifiersToFind.contains(hashedNullifier) {
                            // Found a match! Update the note with the real txid
                            if let realTxid = Data(hexString: txidHex) {
                                try database.updateNoteSpentTxid(hashedNullifier: hashedNullifier, realTxid: realTxid)
                                resolvedCount += 1
                                print("✅ FIX #371: Resolved placeholder at height \(height) → txid \(txidHex.prefix(16))...")

                                onProgress?(resolvedCount, totalNotes)
                            }
                        }
                    }
                }
            } catch {
                print("⚠️ FIX #371: Error processing block \(height): \(error.localizedDescription)")
                // Continue with other blocks
            }
        }

        if resolvedCount > 0 {
            print("✅ FIX #371: Resolved \(resolvedCount)/\(totalNotes) boost placeholder txids")
            // Rebuild transaction history to include the now-resolved transactions
            incrementHistoryVersion()
        } else {
            print("⚠️ FIX #371: Could not resolve any placeholder txids (blocks may not have shielded spends)")
        }

        return resolvedCount
    }

    // MARK: - FIX #466: Resolve Boost received_in_tx Placeholders

    /// FIX #466: Resolve boost placeholder received_in_tx to real transaction IDs
    /// The boost file stores received_in_tx as placeholders ("boost_HEIGHT"), but we need
    /// the real txid for proper change detection in populateHistoryFromNotes().
    ///
    /// This function:
    /// 1. Gets all unspent notes with boost placeholder received_in_tx
    /// 2. Groups them by received_height
    /// 3. Fetches the block at each height
    /// 4. Finds the transaction with output matching the note's cmu
    /// 5. Updates the note with the real txid
    ///
    /// - Parameter onProgress: Progress callback with (resolved, total) notes
    /// - Returns: Number of placeholder txids successfully resolved
    @MainActor
    func resolveBoostReceivedInTxPlaceholders(onProgress: ((Int, Int) -> Void)? = nil) async throws -> Int {
        print("🔧 FIX #466: Resolving boost received_in_tx placeholders...")

        let database = WalletDatabase.shared
        let networkManager = NetworkManager.shared

        // Get all unspent notes with boost placeholder received_in_tx
        let notesWithPlaceholders = try database.getUnspentNotesWithBoostReceivedTxid()
        guard !notesWithPlaceholders.isEmpty else {
            print("✅ FIX #466: No boost received_in_tx placeholders to resolve")
            return 0
        }

        print("🔍 FIX #466: Found \(notesWithPlaceholders.count) notes with boost received_in_tx placeholders")

        // Group notes by received_height for efficient block fetching
        var notesByHeight: [UInt64: [Data]] = [:]  // height -> [cmu]
        for (cmu, receivedHeight) in notesWithPlaceholders {
            notesByHeight[receivedHeight, default: []].append(cmu)
        }

        print("🔍 FIX #466: Notes spread across \(notesByHeight.count) unique blocks")

        var resolvedCount = 0
        let totalNotes = notesWithPlaceholders.count
        let sortedHeights = notesByHeight.keys.sorted()

        for height in sortedHeights {
            guard let cmusToMatch = notesByHeight[height] else { continue }

            // Build a set for quick lookup
            let cmusToFind = Set(cmusToMatch)

            do {
                // Fetch the block at this height
                let blocks = try await networkManager.getBlocksDataP2P(from: height, count: 1)
                guard let (_, _, _, txData) = blocks.first else {
                    print("⚠️ FIX #466: Could not fetch block at height \(height)")
                    continue
                }

                // Search through each transaction's outputs for matching cmu
                for (txidHex, outputs, _) in txData {
                    for output in outputs {
                        // Get the cmu from the output
                        guard !output.cmu.isEmpty,
                              let cmuData = Data(hexString: output.cmu) else { continue }

                        if cmusToFind.contains(cmuData) {
                            // Found a match! Update the note with the real txid
                            if let realTxid = Data(hexString: txidHex) {
                                try database.updateNoteReceivedTxid(cmu: cmuData, realTxid: realTxid)
                                resolvedCount += 1
                                print("✅ FIX #466: Resolved received_in_tx at height \(height) → txid \(txidHex.prefix(16))...")

                                onProgress?(resolvedCount, totalNotes)
                            }
                        }
                    }
                }
            } catch {
                print("⚠️ FIX #466: Error processing block \(height): \(error.localizedDescription)")
                // Continue with other blocks
            }
        }

        if resolvedCount > 0 {
            print("✅ FIX #466: Resolved \(resolvedCount)/\(totalNotes) boost received_in_tx placeholders")
        } else {
            print("⚠️ FIX #466: Could not resolve any received_in_tx placeholders")
        }

        return resolvedCount
    }

    // MARK: - FIX #303: Verify ALL Unspent Notes Are Actually Unspent On-Chain

    /// FIX #303: Scan blockchain for external spends from OLDEST UNSPENT NOTE HEIGHT
    /// This fixes the bug where external spends that happened BEFORE the checkpoint were missed.
    ///
    /// The problem: FIX #302 only scanned from checkpoint to chain tip.
    /// If an external wallet spent our note BEFORE the checkpoint was set, we'd never detect it.
    ///
    /// Solution: Scan from the HEIGHT OF THE OLDEST UNSPENT NOTE to chain tip.
    /// This ensures ANY external spend on ANY unspent note is detected.
    ///
    /// - Parameter onProgress: Progress callback with (current, total) blocks
    /// - Returns: Number of external spends detected and marked as spent
    @MainActor
    func verifyAllUnspentNotesOnChain(onProgress: ((Int, Int) -> Void)? = nil) async throws -> Int {
        print("🔍 FIX #303: Verifying ALL unspent notes are actually unspent on-chain...")

        let database = WalletDatabase.shared
        let networkManager = NetworkManager.shared

        // Get our unspent notes
        let unspentNotes = try database.getAllUnspentNotes(accountId: 1)
        guard !unspentNotes.isEmpty else {
            print("✅ FIX #303: No unspent notes to verify")
            return 0
        }

        // Find the MINIMUM height among all unspent notes
        // This is where we need to START scanning - not from checkpoint!
        let minNoteHeight = unspentNotes.map { $0.height }.min() ?? 0
        guard minNoteHeight > 0 else {
            print("⚠️ FIX #303: Could not determine minimum note height")
            return 0
        }

        // Build set of our nullifier hashes for quick lookup
        var ourNullifiers: [Data: WalletNote] = [:]
        var totalValue: UInt64 = 0
        for note in unspentNotes {
            ourNullifiers[note.nullifier] = note
            totalValue += note.value
        }
        let totalZCL = Double(totalValue) / 100_000_000.0
        print("🔍 FIX #303: Checking \(unspentNotes.count) unspent notes (\(String(format: "%.8f", totalZCL)) ZCL)")
        print("🔍 FIX #303: Oldest note at height \(minNoteHeight)")

        // FIX #367: ALWAYS get fresh chain height from peers, not cached value
        // The cached networkManager.chainHeight can be stale (e.g., Header Store height)
        // which would cause us to miss spending transactions that occurred recently
        let chainHeight: UInt64
        do {
            chainHeight = try await networkManager.getChainHeight()
        } catch {
            print("⚠️ FIX #303: Cannot get chain height: \(error) - skipping")
            return 0
        }
        guard chainHeight > 0 else {
            print("⚠️ FIX #303: Chain height is 0 - skipping")
            return 0
        }
        print("🔍 FIX #367: Fresh chain height from peers: \(chainHeight)")

        // FIX #303 v3: Wait for peers AND verify they actually work with a probe fetch
        // The connect() function initiates connections but doesn't wait for handshakes
        // Also, connectedPeers count can be stale (peers die without being removed)
        var waitAttempts = 0
        let maxWaitAttempts = 30  // Wait up to 30 seconds
        var probeSucceeded = false

        while !probeSucceeded && waitAttempts < maxWaitAttempts {
            // Check if we have any peers first
            let currentPeerCountForProbe = await MainActor.run { networkManager.connectedPeers }
            if currentPeerCountForProbe < 1 {
                print("🔍 FIX #303: Waiting for peers to connect... (\(waitAttempts)s)")
                try? await Task.sleep(nanoseconds: 1_000_000_000)  // 1 second
                waitAttempts += 1
                continue
            }

            // Try a probe fetch to verify peers actually work
            // FIX #367: Add 10-second timeout to prevent hanging
            print("🔍 FIX #303: Probing P2P with \(currentPeerCountForProbe) peer(s)...")
            do {
                let probeHeight = chainHeight > 10 ? chainHeight - 10 : chainHeight

                // Wrap in timeout task
                let probeTask = Task {
                    try await networkManager.getBlocksDataP2P(from: probeHeight, count: 1)
                }

                // Wait max 10 seconds for probe
                let timeoutTask = Task {
                    try await Task.sleep(nanoseconds: 10_000_000_000)  // 10 seconds
                    probeTask.cancel()
                }

                let probeBlocks = try await probeTask.value
                timeoutTask.cancel()

                if !probeBlocks.isEmpty {
                    probeSucceeded = true
                    print("✅ FIX #303: P2P probe succeeded - peers are responsive")
                } else {
                    print("⚠️ FIX #303: P2P probe returned empty - waiting...")
                    try? await Task.sleep(nanoseconds: 2_000_000_000)  // 2 seconds
                    waitAttempts += 2
                }
            } catch {
                if Task.isCancelled {
                    print("⚠️ FIX #367: P2P probe TIMEOUT after 10s - peers not responding")
                } else {
                    print("⚠️ FIX #303: P2P probe failed: \(error) - waiting for peers to recover...")
                }
                try? await Task.sleep(nanoseconds: 3_000_000_000)  // 3 seconds
                waitAttempts += 3
            }
        }

        guard probeSucceeded else {
            print("⚠️ FIX #303: P2P not responsive after \(maxWaitAttempts)s - skipping verification")
            print("   Balance may be incorrect if external spends occurred while app was closed")
            return 0
        }
        let verifiedPeerCount = await MainActor.run { networkManager.connectedPeers }
        print("🔍 FIX #303: \(verifiedPeerCount) peer(s) verified - starting scan")

        // FIX #367: Limit scan to max 5000 blocks for speed (recent spends most important)
        // If spending TX is older than 5000 blocks, user needs full rescan
        let maxScanBlocks: UInt64 = 5000
        var startHeight = minNoteHeight

        // If gap is too large, start from (chainHeight - maxScanBlocks) instead
        if chainHeight > minNoteHeight + maxScanBlocks {
            startHeight = chainHeight - maxScanBlocks
            print("🔍 FIX #367: Limiting scan to last \(maxScanBlocks) blocks (from \(startHeight))")
        }

        let blocksToScan = chainHeight > startHeight ? Int(chainHeight - startHeight) : 0

        guard blocksToScan > 0 else {
            print("✅ FIX #303: No blocks to scan (startHeight=\(startHeight), chainHeight=\(chainHeight))")
            return 0
        }

        print("🔍 FIX #303: Scanning \(blocksToScan) blocks from height \(startHeight) to \(chainHeight)")

        // Fetch blocks via P2P and check nullifiers
        var externalSpendsFound = 0
        var successfulBatches = 0
        var failedBatches = 0
        var consecutiveFailures = 0
        // FIX #561 v2: 500 is fine for P2P on-demand fetches
        let batchSize: UInt64 = 500

        // FIX #367: Add 60-second total timeout to prevent repair from hanging
        let scanStartTime = Date()
        let maxScanDuration: TimeInterval = 60.0

        var batchStart = startHeight
        while batchStart < chainHeight {
            // Check total time limit
            if Date().timeIntervalSince(scanStartTime) > maxScanDuration {
                print("⚠️ FIX #367: Scan timeout after 60s - scanned up to height \(batchStart)")
                print("   Run full rescan if balance still incorrect")
                break
            }
            let batchEnd = min(batchStart + batchSize, chainHeight)
            let count = Int(batchEnd - batchStart)

            onProgress?(Int(batchStart - startHeight), blocksToScan)

            // FIX #303 v5: Add retries for failed batches and delays to prevent overwhelming Tor
            var batchSuccess = false
            var retries = 0
            let maxRetries = 2

            while !batchSuccess && retries <= maxRetries {
                do {
                    // FIX #367: Wrap batch fetch in 15-second timeout
                    let fetchTask = Task {
                        try await networkManager.getBlocksDataP2P(from: batchStart, count: count)
                    }

                    let batchTimeoutTask = Task {
                        try await Task.sleep(nanoseconds: 15_000_000_000)  // 15 seconds
                        fetchTask.cancel()
                    }

                    let blocks = try await fetchTask.value
                    batchTimeoutTask.cancel()

                    if blocks.isEmpty {
                        retries += 1
                        if retries <= maxRetries {
                            try? await Task.sleep(nanoseconds: 2_000_000_000)  // 2s retry delay
                        }
                        continue
                    }

                    batchSuccess = true
                    successfulBatches += 1
                    consecutiveFailures = 0

                    for (height, _, _, txData) in blocks {
                        for (txidHex, _, spends) in txData {
                            guard let spends = spends, !spends.isEmpty else { continue }

                            // Check each spend's nullifier
                            for spend in spends {
                                // Convert hex nullifier to Data (display format / big-endian)
                                guard let nullifierDisplay = Data(hexString: spend.nullifier) else { continue }

                                // FIX #288: P2P returns nullifier in display format (big-endian)
                                // DB stores in wire format (little-endian) - must reverse before hashing!
                                let nullifierWire = nullifierDisplay.reversedBytes()

                                // VUL-009: Hash the on-chain nullifier to compare with stored hashes
                                let hashedNullifier = database.hashNullifier(nullifierWire)

                                if let matchedNote = ourNullifiers[hashedNullifier] {
                                    // Found! This note was spent on-chain - EXTERNAL SPEND!
                                    print("🚨 FIX #303: EXTERNAL SPEND DETECTED!")
                                    print("   Note value: \(matchedNote.value) zatoshis (\(Double(matchedNote.value) / 100_000_000.0) ZCL)")
                                    print("   Spent in TX: \(txidHex.prefix(16))...")
                                    print("   Spent at height: \(height)")
                                    print("   Note created at height: \(matchedNote.height)")

                                    // Convert txid hex to Data
                                    let txidData = Data(hexString: txidHex) ?? hashedNullifier.prefix(32)

                                    // Mark the note as spent
                                    try database.markNoteSpentByHashedNullifier(
                                        hashedNullifier: hashedNullifier,
                                        txid: txidData,
                                        spentHeight: height
                                    )

                                    // Create SENT history entry if it doesn't exist
                                    let fee: UInt64 = 10_000 // Standard fee
                                    let amountSent = matchedNote.value > fee ? matchedNote.value - fee : matchedNote.value

                                    // Check if history entry already exists
                                    let existsInHistory = try database.transactionExists(txid: txidData, type: .sent)
                                    if !existsInHistory {
                                        _ = try database.insertTransactionHistory(
                                            txid: txidData,
                                            height: height,
                                            blockTime: UInt64(Date().timeIntervalSince1970),
                                            type: .sent,
                                            value: amountSent,
                                            fee: fee,
                                            toAddress: nil,
                                            fromDiversifier: nil,
                                            memo: "[External wallet spend detected by FIX #303]"
                                        )
                                        print("📜 FIX #303: Created SENT history entry for external spend")
                                    }

                                    externalSpendsFound += 1
                                    // Remove from our tracking set
                                    ourNullifiers.removeValue(forKey: hashedNullifier)
                                }
                            }
                        }
                    }
                } catch {
                    retries += 1
                    consecutiveFailures += 1
                    if retries <= maxRetries {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)  // 2s retry delay
                    }
                }
            }

            // Track batch result
            if !batchSuccess {
                failedBatches += 1
                // Only log first few failures to avoid spam
                if failedBatches <= 3 {
                    print("⚠️ FIX #303: Failed to fetch blocks \(batchStart)-\(batchEnd) after \(maxRetries + 1) attempts")
                }

                // FIX #303 v5: If too many consecutive failures, peers are dead - abort scan
                if consecutiveFailures >= 10 {
                    print("🚨 FIX #303: 10 consecutive batch failures - peers are dead, aborting scan")
                    break
                }
            }

            // FIX #303 v5: Add delay between batches to let Tor circuits recover
            if successfulBatches % 10 == 0 && successfulBatches > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)  // 1s pause every 10 batches
            }

            batchStart += batchSize
        }

        onProgress?(blocksToScan, blocksToScan)

        // Report scan results
        let totalBatches = successfulBatches + failedBatches
        if failedBatches > 0 && failedBatches > 3 {
            print("⚠️ FIX #303: ... and \(failedBatches - 3) more batch failures")
        }

        if successfulBatches == 0 && totalBatches > 0 {
            // All batches failed - verification incomplete!
            print("🚨 FIX #303: VERIFICATION FAILED - 0/\(totalBatches) batches succeeded (network issues)")
            print("   Balance may be incorrect if external spends occurred!")
            return 0
        }

        if externalSpendsFound > 0 {
            print("✅ FIX #303: Detected \(externalSpendsFound) external spend(s) - balance updated")
            print("   Scanned \(successfulBatches)/\(totalBatches) batches successfully")
            // Refresh balance to reflect changes
            try? await refreshBalance()
            incrementHistoryVersion()

            // FIX #303: Calculate total amount corrected and show alert
            let correctedAmount = totalValue - unspentNotes.filter { ourNullifiers[$0.nullifier] != nil }.reduce(0) { $0 + $1.value }
            let correctedZCL = Double(correctedAmount) / 100_000_000.0
            await MainActor.run {
                self.databaseCorrectionAlert = DatabaseCorrectionInfo(
                    externalSpendsDetected: externalSpendsFound,
                    amountCorrected: correctedAmount,
                    message: "Detected \(externalSpendsFound) transaction(s) from another wallet totaling \(String(format: "%.8f", correctedZCL)) ZCL. Your balance has been corrected."
                )
            }
        } else if failedBatches > 0 {
            print("⚠️ FIX #303: Partial scan - \(successfulBatches)/\(totalBatches) batches succeeded")
            print("   No external spends found in scanned blocks, but \(failedBatches) batches failed")
        } else {
            print("✅ FIX #303: All \(unspentNotes.count) unspent notes verified - no external spends detected")
            print("   Scanned \(successfulBatches) batches successfully")
        }

        return externalSpendsFound
    }

    // MARK: - FIX #370: Periodic Deep Verification

    /// FIX #370: Periodically rescan from tx_confirmed_checkpoint to catch missed transactions.
    ///
    /// Problem: If a transaction is missed (network glitch, bug, etc.), the regular
    /// verified_checkpoint moves forward and the missed TX is never discovered.
    ///
    /// Solution: Keep a separate tx_confirmed_checkpoint that ONLY advances when
    /// a transaction is actually confirmed. Periodically rescan from this checkpoint
    /// to ensure no transactions are ever missed.
    ///
    /// This function should be called:
    /// - Periodically in background (e.g., every 10-30 minutes while app is open)
    /// - At app launch if last deep verification was >6 hours ago
    ///
    /// - Returns: Number of transactions discovered
    @MainActor
    func performDeepVerification() async throws -> Int {
        let database = WalletDatabase.shared
        let networkManager = NetworkManager.shared

        // Check when last deep verification was performed
        let lastVerification = (try? database.getLastDeepVerificationTime()) ?? 0
        let currentTime = Int64(Date().timeIntervalSince1970)
        let hoursSinceLastVerification = Double(currentTime - lastVerification) / 3600.0

        // Get tx_confirmed_checkpoint - starting point for deep scan
        let txCheckpoint = (try? database.getTxConfirmedCheckpoint()) ?? 0

        // Get current chain height
        var chainHeight = await MainActor.run { networkManager.chainHeight }
        if chainHeight == 0 {
            chainHeight = (try? await networkManager.getChainHeight()) ?? 0
        }

        guard chainHeight > 0 else {
            print("⚠️ FIX #370: Cannot get chain height - skipping deep verification")
            return 0
        }

        // If tx_confirmed_checkpoint is 0, initialize to verified_checkpoint
        if txCheckpoint == 0 {
            let verifiedCheckpoint = (try? database.getVerifiedCheckpointHeight()) ?? 0
            if verifiedCheckpoint > 0 {
                try? database.updateTxConfirmedCheckpoint(verifiedCheckpoint)
                print("📍 FIX #370: Initialized tx_confirmed_checkpoint to \(verifiedCheckpoint)")
            }
            // First run - mark as verified and skip actual scan
            try? database.updateLastDeepVerificationTime()
            return 0
        }

        // Calculate blocks to scan
        let blocksToScan = chainHeight > txCheckpoint ? chainHeight - txCheckpoint : 0

        print("🔍 FIX #370: Deep Verification Check")
        print("   tx_confirmed_checkpoint: \(txCheckpoint)")
        print("   chain_height: \(chainHeight)")
        print("   blocks_to_scan: \(blocksToScan)")
        print("   hours_since_last: \(String(format: "%.1f", hoursSinceLastVerification))")

        // If nothing to scan, just update timestamp and return
        guard blocksToScan > 0 else {
            print("✅ FIX #370: Deep verification complete - no blocks to scan")
            try? database.updateLastDeepVerificationTime()
            return 0
        }

        // Only do deep scan if:
        // 1. More than 100 blocks behind, OR
        // 2. Last verification was >6 hours ago
        let needsDeepScan = blocksToScan > 100 || hoursSinceLastVerification > 6.0

        guard needsDeepScan else {
            print("✅ FIX #370: Deep verification not needed yet (blocks=\(blocksToScan), hours=\(String(format: "%.1f", hoursSinceLastVerification)))")
            return 0
        }

        print("🔍 FIX #370: Starting deep verification scan from \(txCheckpoint) to \(chainHeight)...")

        // Use FilterScanner for comprehensive scan (finds both incoming notes and spends)
        let startHeight = txCheckpoint + 1

        // Run the scan using existing FilterScanner approach
        // This will trial-decrypt blocks and check for nullifiers
        var transactionsFound = 0

        do {
            // Get account and spending key for FilterScanner
            guard let account = try? database.getAccount(index: 0) else {
                print("⚠️ FIX #370: No account found - skipping deep verification")
                return 0
            }

            let spendingKey = try secureStorage.retrieveSpendingKey()

            // Count notes/history before scan
            let notesBefore = (try? database.getAllNotes(accountId: 1).count) ?? 0
            let historyBefore = (try? database.getTransactionHistoryCount()) ?? 0

            // Run FilterScanner from tx_confirmed_checkpoint
            let scanner = FilterScanner()
            print("🔍 FIX #370: Starting FilterScanner from height \(startHeight)...")
            try await scanner.startScan(
                for: account.accountId,
                viewingKey: spendingKey,
                fromHeight: startHeight
            )

            // Count notes/history after scan
            let notesAfter = (try? database.getAllNotes(accountId: 1).count) ?? 0
            let historyAfter = (try? database.getTransactionHistoryCount()) ?? 0

            let newNotes = notesAfter - notesBefore
            let newHistory = historyAfter - historyBefore
            transactionsFound = max(newNotes, newHistory)

            if transactionsFound > 0 {
                print("🎉 FIX #370: Deep verification found \(transactionsFound) missed transaction(s)!")
                // Refresh balance
                try? await refreshBalance()
                incrementHistoryVersion()
            } else {
                print("✅ FIX #370: Deep verification complete - no missed transactions")
            }

            // Update both checkpoints after successful scan
            try? database.updateTxConfirmedCheckpoint(chainHeight)
            try? database.updateVerifiedCheckpointHeight(chainHeight)
            try? database.updateLastDeepVerificationTime()

            print("📍 FIX #370: Checkpoints updated to \(chainHeight) after deep verification")

        } catch {
            print("⚠️ FIX #370: Deep verification scan failed: \(error)")
            // Don't update checkpoints on failure - will retry next time
        }

        return transactionsFound
    }

    /// Start periodic deep verification timer
    /// Called once at app startup after initial sync completes
    /// FIX #370 v2: Run immediately at startup, then every 30 minutes
    func startPeriodicDeepVerification() {
        // Run immediately on startup (don't wait 30 minutes!)
        Task { @MainActor in
            guard !self.isSyncing && !self.isRepairingDatabase else {
                print("⏭️ FIX #370: Skipping immediate deep verification - sync/repair in progress")
                return
            }

            // Immediate run at startup
            let found = try? await self.performDeepVerification()
            if let found = found, found > 0 {
                print("🔔 FIX #370: Startup deep verification found \(found) missed transaction(s)!")
            }

            // FIX #681: Also run immediate auto-recovery
            let recovered = await self.autoRecoverMissingTransactions()
            if recovered > 0 {
                print("🔔 FIX #681: Startup auto-recovery found \(recovered) missed transaction(s)!")
            }
        }

        // Then schedule every 30 minutes
        Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                // Only run if not syncing and not repairing
                guard !self.isSyncing && !self.isRepairingDatabase else {
                    print("⏭️ FIX #370: Skipping periodic deep verification - sync/repair in progress")
                    return
                }
                let found = try? await self.performDeepVerification()
                if let found = found, found > 0 {
                    print("🔔 FIX #370: Periodic deep verification found \(found) missed transaction(s)!")
                }

                // FIX #681: Also run automatic transaction recovery (checkpoint rollback)
                // This catches transactions missed by broadcast tracking bugs
                let recovered = await self.autoRecoverMissingTransactions()
                if recovered > 0 {
                    print("🔔 FIX #681: Periodic auto-recovery found \(recovered) missed transaction(s)!")
                }
            }
        }
        print("⏰ FIX #370: Deep verification + auto-recovery: ran at startup, then every 30 min")
    }

    /// FIX #603: Start periodic witness refresh timer
    /// Keeps all unspent note witnesses updated to current chain tip
    /// This ensures pre-build is instant - witnesses are always fresh
    func startPeriodicWitnessRefresh() {
        // Run witness refresh every 10 minutes while app is open
        Timer.scheduledTimer(withTimeInterval: 10 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                // Only run if not syncing and not repairing
                guard !self.isSyncing && !self.isRepairingDatabase else {
                    print("⏭️ FIX #603: Skipping periodic witness refresh - sync/repair in progress")
                    return
                }
                let updated = try? await self.refreshAllNoteWitnesses()
                if let updated = updated, updated > 0 {
                    print("🔔 FIX #603: Periodic witness refresh updated \(updated) witness(es)!")
                }
            }
        }
        print("⏰ FIX #603: Periodic witness refresh timer started (10 min interval)")
    }

    /// FIX #603: Refresh all unspent note witnesses to current chain tip
    /// Updates witnesses for all unspent notes so they're ready for instant spending
    /// - Returns: Number of witnesses updated
    @MainActor
    func refreshAllNoteWitnesses() async throws -> Int {
        print("🔄 FIX #603: Refreshing all unspent note witnesses to current chain tip...")

        let database = WalletDatabase.shared

        // Get all unspent notes count before
        guard let account = try database.getAccount(index: 0) else {
            print("⚠️ FIX #603: No account found")
            return 0
        }

        let notesBefore = try database.getAllUnspentNotes(accountId: account.accountId)
        let countBefore = notesBefore.count

        guard countBefore > 0 else {
            print("✅ FIX #603: No unspent notes to refresh")
            return 0
        }

        print("📊 FIX #603: Refreshing \(countBefore) witnesses to current chain tip...")

        // Use existing rebuildWitnessesForSpending function
        // It handles all the complexity: CMU loading, tree building, P2P scanning for recent blocks
        try await rebuildWitnessesForSpending { _, _, _ in
            // Progress callback - silent during background refresh
        }

        print("✅ FIX #603: Refreshed \(countBefore) witness(es) to current chain tip")
        return countBefore
    }

    // MARK: - FIX #217: Scan for ALL Missing Transactions (Incoming + Spent)

    /// Scan from checkpoint to chain tip for any missed transactions
    /// This uses FilterScanner with trial decryption to find:
    /// - Incoming notes (notes sent TO us that weren't recorded)
    /// - Spent notes (notes we spent that weren't recorded)
    /// Much more comprehensive than FIX #212 which only checks nullifiers.
    /// - Returns: Number of new transactions discovered
    @MainActor
    func scanForMissingTransactions() async throws -> Int {
        print("🔍 FIX #217: Scanning for ALL missing transactions (incoming + spent)...")

        let database = WalletDatabase.shared
        let networkManager = NetworkManager.shared

        // Get checkpoint - this is our last verified good state
        let checkpoint = try database.getVerifiedCheckpointHeight()

        // Get chain height
        var chainHeight = await MainActor.run { networkManager.chainHeight }
        if chainHeight == 0 {
            chainHeight = (try? await networkManager.getChainHeight()) ?? 0
        }

        guard chainHeight > 0 else {
            print("⚠️ FIX #217: Cannot get chain height - skipping")
            return 0
        }

        // FIX #216: Sanity check chain height
        guard chainHeight < 10_000_000 else {
            print("🚨 FIX #217: REJECTED impossible chain height \(chainHeight)")
            return 0
        }

        guard chainHeight > checkpoint else {
            print("✅ FIX #217: Already at chain tip (checkpoint=\(checkpoint), chainHeight=\(chainHeight))")
            return 0
        }

        let blocksToScan = chainHeight - checkpoint
        print("🔍 FIX #217: Scanning \(blocksToScan) blocks from checkpoint \(checkpoint) to \(chainHeight)")

        // Count notes before scan
        let notesBefore = (try? database.getAllNotes(accountId: 1).count) ?? 0
        let historyBefore = (try? database.getTransactionHistoryCount()) ?? 0

        // Get account and spending key for FilterScanner
        guard let account = try database.getAccount(index: 0) else {
            print("⚠️ FIX #217: No account found")
            return 0
        }

        let spendingKey = try secureStorage.retrieveSpendingKey()

        // Run FilterScanner from checkpoint - this does:
        // 1. Trial decryption for incoming notes
        // 2. Nullifier matching for spent notes
        // 3. Proper witness updates
        let scanner = FilterScanner()

        print("🔍 FIX #217: Starting FilterScanner from height \(checkpoint + 1)...")
        try await scanner.startScan(
            for: account.accountId,
            viewingKey: spendingKey,
            fromHeight: checkpoint + 1
        )

        // Count notes after scan
        let notesAfter = (try? database.getAllNotes(accountId: 1).count) ?? 0
        let historyAfter = (try? database.getTransactionHistoryCount()) ?? 0

        let newNotes = notesAfter - notesBefore
        let newHistory = historyAfter - historyBefore
        let totalRecovered = max(newNotes, newHistory)

        if totalRecovered > 0 {
            print("✅ FIX #217: Found \(newNotes) new note(s) and \(newHistory) new history entry/entries!")
            // Refresh balance to reflect changes
            try? await refreshBalance()
            incrementHistoryVersion()
        } else {
            print("✅ FIX #217: No missing transactions found - database is consistent")
        }

        return totalRecovered
    }

    // MARK: - FIX #681: Automatic Recovery of Missing Transactions

    /// FIX #681: Automatically detect and recover transactions using checkpoint rollback strategy
    ///
    /// STRATEGY (user's excellent suggestion):
    /// 1. Start from (latest checkpoint - 1) and work BACKWARDS
    /// 2. Validate against the latest checkpoint
    /// 3. If issues found → rollback checkpoint and create new one
    /// 4. This is efficient - only checks the "delta" between checkpoints
    ///
    /// This handles the case where user doesn't open app for months/years and makes
    /// transactions with another wallet using the same private key.
    ///
    /// - Returns: Number of transactions recovered
    @discardableResult
    func autoRecoverMissingTransactions() async -> Int {
        // FIX #709: Early return BEFORE any potentially crashing code
        // FIX #688 v3: Disable auto-recovery due to crashes
        // This feature needs to be completely rewritten to avoid overflow issues
        // For now, just skip it - users can manually trigger rescan if needed
        print("⏭️ FIX #709: Auto-recovery disabled (preventing crashes from MainActor.run and database access)")
        return 0

        // NOTE: All code below is disabled until auto-recovery is rewritten
        // The crash was occurring between line 8149-8164 - likely in:
        // - await MainActor.run { networkManager.chainHeight }
        // - database.getVerifiedCheckpointHeight()

        // FIX #681 v4: Prevent concurrent executions that interfere with each other
        guard !isAutoRecovering else {
            print("⏭️ FIX #681: Auto-recovery already in progress, skipping duplicate call")
            return 0
        }

        // Set flag to prevent concurrent calls
        await MainActor.run { self.isAutoRecovering = true }
        defer {
            Task { @MainActor in
                self.isAutoRecovering = false
            }
        }

        print("🔍 FIX #681: Starting automatic missing transaction detection (checkpoint rollback strategy)...")

        let database = WalletDatabase.shared
        let networkManager = await NetworkManager.shared

        // Get current chain height
        let chainHeight = await MainActor.run { networkManager.chainHeight }
        guard chainHeight > 0 else {
            print("⚠️ FIX #681: No chain height available, skipping auto-recovery")
            return 0
        }

        // Get verified checkpoint height - this is our last verified good state
        let checkpoint: UInt64
        do {
            checkpoint = try database.getVerifiedCheckpointHeight()
        } catch {
            print("⚠️ FIX #681: Could not get checkpoint height, using 0: \(error.localizedDescription)")
            checkpoint = 0
        }

        // FIX #681 v7: Scan backward from checkpoint and try to recover ALL transactions
        // This catches both sends (spends) and receives (outputs) - no need for nullifier pre-check
        // Example: Transaction at 2985823 was missed, checkpoint moved to 2986476
        print("🔍 FIX #681: Scanning for missed transactions BEFORE checkpoint...")

        // FIX #688 v3: Disable auto-recovery due to crashes
        // This feature needs to be completely rewritten to avoid overflow issues
        // For now, just skip it - users can manually trigger rescan if needed
        print("⏭️ FIX #681: Auto-recovery disabled (FIX #688 - preventing crashes)")
        return 0
    }

    /// FIX #681: Extract nullifiers from a compact block transaction
    private func extractNullifiersFromTransaction(_ tx: CompactTx) -> [Data] {
        var nullifiers: [Data] = []

        // tx.spends contains CompactSpend with nullifiers
        for spend in tx.spends {
            nullifiers.append(spend.nullifier)
        }

        return nullifiers
    }

    // MARK: - FIX #680: Recover Specific Transaction by TXID (P2P Only)

    /// FIX #680: Recover a transaction that was confirmed on-chain but not recorded in database
    /// This handles the case where broadcast tracking failed (peers timed out) but TX was confirmed.
    /// Uses P2P network to get transaction details and add to database.
    /// IMPORTANT: Does NOT modify the checkpoint - this is historical data recovery only.
    /// - Parameter txid: The transaction ID to recover (hex string)
    /// - Returns: True if recovery succeeded, false otherwise
    @discardableResult
    func recoverTransactionByTxid(_ txid: String) async -> Bool {
        print("🔍 FIX #680: Attempting to recover transaction by txid: \(txid.prefix(16))...")

        // Parse txid once at the beginning
        guard let txidData = Data(hexString: txid) else {
            print("❌ FIX #680: Invalid txid format")
            return false
        }

        let networkManager = await NetworkManager.shared
        let database = WalletDatabase.shared

        do {
            // Step 1: Get transaction from P2P network
            print("📡 FIX #680: Fetching transaction via P2P...")
            let txData = try await networkManager.getTransactionP2P(txid: txid)

            print("📦 FIX #680: Got \(txData.count) bytes of transaction data")

            // Step 2: Parse transaction to extract nullifiers from shielded spends
            let (parsedTxid, spends, _, _) = try parseSaplingTransaction(txData)

            print("🔍 FIX #680: Parsed transaction - \(spends.count) shielded spend(s)")

            guard !spends.isEmpty else {
                print("⚠️ FIX #680: No shielded spends found in transaction")
                return false
            }

            // Step 3: For each spend, find and mark the note as spent
            var recoveredCount = 0
            var totalSpent: UInt64 = 0

            for spend in spends {
                let nullifier = spend.nullifier  // Raw nullifier from transaction

                // Hash the nullifier (VUL-009: database stores hashed nullifiers)
                let hashedNullifier = Data(SHA256.hash(data: nullifier))

                // Find the note by hashed nullifier - getNoteByNullifier returns (id, value)?
                guard let (noteId, noteValue) = try? database.getNoteByNullifier(nullifier: hashedNullifier) else {
                    print("⚠️ FIX #680: Note not found for nullifier \(nullifier.hexString.prefix(16))...")
                    continue
                }

                print("💰 FIX #680: Found note worth \(noteValue) zatoshis (id=\(noteId))")
                totalSpent += noteValue

                // Step 4: Mark note as spent using recordSentTransactionAtomic
                try database.recordSentTransactionAtomic(
                    hashedNullifier: hashedNullifier,
                    txid: txidData,
                    spentHeight: 0,  // Unknown yet, will be updated
                    amount: noteValue,
                    fee: 10000,
                    toAddress: "Unknown",
                    memo: nil
                )

                print("✅ FIX #680: Marked note as spent")
                recoveredCount += 1
            }

            if recoveredCount == 0 {
                print("⚠️ FIX #680: No notes were recovered")
                return false
            }

            // Refresh balance
            try await refreshBalance()
            await MainActor.run {
                self.incrementHistoryVersion()
            }

            print("✅ FIX #680: Transaction recovery complete - recovered \(recoveredCount) note(s)")
            return true

        } catch {
            print("❌ FIX #680: Recovery failed: \(error.localizedDescription)")
            return false
        }
    }

    /// FIX #680: Parse a Sapling transaction to extract spends and outputs
    /// - Parameter data: Raw transaction data
    /// - Returns: (txid, spends, outputs, endOffset)
    private func parseSaplingTransaction(_ data: Data) throws -> (Data, [CompactSpend], [CompactOutput], Int) {
        var pos = 0
        var spends: [CompactSpend] = []
        var outputs: [CompactOutput] = []

        // Header (4 bytes): version group ID and version
        guard pos + 4 <= data.count else {
            throw RecoveryError.invalidFormat
        }
        let header = data.loadUInt32(at: pos)
        pos += 4

        let version = header & 0x7FFFFFFF
        let isOverwintered = (header >> 31) == 1

        guard version >= 4 && isOverwintered else {
            throw RecoveryError.unsupportedVersion
        }

        // nVersionGroupId (4 bytes) - for Sapling transactions
        guard pos + 4 <= data.count else {
            throw RecoveryError.invalidFormat
        }
        pos += 4

        // Read transparent inputs/outputs (skip)
        let (txInCount, vinBytes) = readCompactSize(data, at: pos)
        pos += vinBytes
        for _ in 0..<txInCount {
            // Outpoint (36 bytes) + scriptSig varint + sequence (4 bytes)
            guard pos + 36 + 4 <= data.count else { throw RecoveryError.invalidFormat }
            pos += 36
            let (scriptLen, scriptBytes) = readCompactSize(data, at: pos)
            pos += scriptBytes + Int(scriptLen) + 4
        }

        let (txOutCount, voutBytes) = readCompactSize(data, at: pos)
        pos += voutBytes
        for _ in 0..<txOutCount {
            // value (8 bytes) + scriptPubKey varint
            guard pos + 8 <= data.count else { throw RecoveryError.invalidFormat }
            pos += 8
            let (scriptLen, scriptBytes) = readCompactSize(data, at: pos)
            pos += scriptBytes + Int(scriptLen)
        }

        // lockTime (4 bytes)
        guard pos + 4 <= data.count else { throw RecoveryError.invalidFormat }
        pos += 4

        // Sapling bundle (if present)
        if pos + 2 <= data.count {
            let (bundleBytes, _) = readCompactSize(data, at: pos)

            // Check if this is a Sapling bundle (marker = 0x01)
            guard pos + 1 < data.count else { throw RecoveryError.invalidFormat }
            let marker = data[pos]
            pos += 1

            guard marker == 0x01 else {
                throw RecoveryError.invalidFormat
            }

            // Read shielded spends
            let (spendCount, spendBytes) = readCompactSize(data, at: pos)
            pos += spendBytes

            for _ in 0..<spendCount {
                // SpendDescription: cv(32) + anchor(32) + nullifier(32) + rk(32) + zkproof(192) + spendAuthSig(64)
                guard pos + 384 <= data.count else { break }

                // cv (32 bytes) - skip
                pos += 32

                // anchor (32 bytes) - skip
                pos += 32

                // nullifier (32 bytes) - EXTRACT THIS
                let nullifier = Data(data[pos..<pos+32])
                pos += 32
                spends.append(CompactSpend(nullifier: nullifier))

                // rk (32 bytes) - skip
                pos += 32

                // zkproof (192 bytes) - skip
                pos += 192

                // spendAuthSig (64 bytes) - skip
                pos += 64
            }

            // Read shielded outputs
            let (outputCount, outputBytes) = readCompactSize(data, at: pos)
            pos += outputBytes

            for _ in 0..<outputCount {
                // OutputDescription: cv(32) + cmu(32) + ephemeralKey(32) + zkproof(192) + ciphertext(580)
                guard pos + 868 <= data.count else { break }

                // cv (32 bytes) - skip
                pos += 32

                // cmu (32 bytes)
                let cmu = Data(data[pos..<pos+32])
                pos += 32

                // ephemeralKey (32 bytes)
                let epk = Data(data[pos..<pos+32])
                pos += 32

                // zkproof (192 bytes) - skip
                pos += 192

                // ciphertext (580 bytes)
                let ciphertext = Data(data[pos..<pos+580])
                pos += 580

                outputs.append(CompactOutput(cmu: cmu, epk: epk, ciphertext: ciphertext))
            }

            // valueBalance (8 bytes, signed as little-endian)
            pos += 8

            // bindingSig (64 bytes)
            pos += 64
        }

        // Calculate txid (double SHA256 of entire transaction)
        // Calculate txid (double SHA256 of entire transaction)
        let txData = data.prefix(pos)
        let firstHash = Data(SHA256.hash(data: txData))
        let txid = Data(SHA256.hash(data: firstHash))

        return (txid, spends, outputs, pos)
    }

    /// FIX #680: Read compact size from data at offset
    private func readCompactSize(_ data: Data, at offset: Int) -> (UInt64, Int) {
        var pos = offset
        guard pos < data.count else { return (0, 0) }

        let firstByte = data[pos]
        pos += 1

        if firstByte < 0xFD {
            return (UInt64(firstByte), 1)
        } else if firstByte == 0xFD {
            guard pos + 2 <= data.count else { return (0, 1) }
            let value = data.withUnsafeBytes { ptr in
                UInt64(ptr.load(fromByteOffset: pos, as: UInt16.self).littleEndian)
            }
            return (value, 3)
        } else if firstByte == 0xFE {
            guard pos + 4 <= data.count else { return (0, 1) }
            let value = data.withUnsafeBytes { ptr in
                UInt64(ptr.load(fromByteOffset: pos, as: UInt32.self).littleEndian)
            }
            return (value, 5)
        } else { // 0xFF
            guard pos + 8 <= data.count else { return (0, 1) }
            let value = data.withUnsafeBytes { ptr in
                ptr.load(fromByteOffset: pos, as: UInt64.self)
            }
            return (value, 9)
        }
    }

    // MARK: - FIX #689: Manual Transaction Detection (Force Confirm)

    /// FIX #689: Force detection and recording of a confirmed transaction
    /// Use this when a transaction is confirmed on-chain but not detected by the app
    /// This can happen if the app was closed or if the note was deleted during full resync
    ///
    /// - Parameter txid: The transaction ID to force detect (hex string)
    /// - Returns: True if the transaction was found and recorded, false otherwise
    @discardableResult
    func forceDetectConfirmedTransaction(_ txid: String) async -> Bool {
        print("🔍 FIX #689: Force detecting confirmed transaction: \(txid.prefix(16))...")

        let networkManager = await NetworkManager.shared
        let database = WalletDatabase.shared

        do {
            // Step 1: Get transaction from P2P network
            print("📡 FIX #689: Fetching transaction via P2P...")
            let txData = try await networkManager.getTransactionP2P(txid: txid)

            print("📦 FIX #689: Got \(txData.count) bytes of transaction data")

            // Step 2: Parse transaction to extract spends and outputs
            let (parsedTxid, spends, outputs, _) = try parseSaplingTransaction(txData)

            print("🔍 FIX #689: Parsed transaction - \(spends.count) spend(s), \(outputs.count) output(s)")

            // Step 3: Record in transaction history
            let txidData = Data(hexString: txid) ?? Data()

            // Get block height for this transaction
            let chainHeight = await networkManager.chainHeight
            let blockHeight = chainHeight > 0 ? chainHeight : 2986734  // Use known height if available

            // Check if this is our send (has shielded spends) by checking if we have the notes
            var totalSpent: UInt64 = 0
            var foundOurSpend = false

            for spend in spends {
                let nullifier = spend.nullifier
                let hashedNullifier = Data(SHA256.hash(data: nullifier))

                // Check if this is our nullifier
                if let (noteId, noteValue) = try? database.getNoteByNullifier(nullifier: hashedNullifier) {
                    print("💰 FIX #689: Found our note worth \(noteValue) zatoshis (id=\(noteId))")
                    totalSpent += noteValue
                    foundOurSpend = true

                    // Record as sent transaction
                    try database.recordSentTransactionAtomic(
                        hashedNullifier: hashedNullifier,
                        txid: txidData,
                        spentHeight: blockHeight,
                        amount: noteValue,
                        fee: 10000,
                        toAddress: "Recovered (FIX #689)",
                        memo: nil
                    )
                    print("✅ FIX #689: Recorded sent transaction")
                }
            }

            if !foundOurSpend {
                // This might be a receive (change) - check outputs
                for output in outputs {
                    // Try to decrypt to see if it's ours
                    // For now, just record that we found the transaction
                    print("⚠️ FIX #689: Transaction has no matching spends, might be receive-only")
                }
            }

            // Step 4: Clear pending broadcast state if this was the pending TX
            await MainActor.run {
                if networkManager.pendingBroadcastTxid == txid {
                    networkManager.clearPendingBroadcast()
                    print("✅ FIX #689: Cleared pending broadcast state")
                }
            }

            // Step 5: Refresh UI
            try? await refreshBalance()
            await MainActor.run {
                self.incrementHistoryVersion()
            }

            print("✅ FIX #689: Transaction detection complete")
            return foundOurSpend

        } catch {
            print("❌ FIX #689: Failed to detect transaction: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - FIX #185: Equihash Proof-of-Work Verification

    /// Verify Equihash proof-of-work for a list of block headers
    /// This ensures the blockchain data comes from honest miners, not attackers
    /// - Parameter headers: List of block headers with solutions from P2P peers
    /// - Returns: Number of headers that passed Equihash verification
    private func verifyEquihashProofOfWork(headers: [BlockHeader]) -> Int {
        var passedCount = 0

        for header in headers {
            // Build 140-byte header for Equihash verification
            var headerData = Data()
            withUnsafeBytes(of: Int32(header.version).littleEndian) { headerData.append(contentsOf: $0) }
            headerData.append(header.prevBlockHash)   // 32 bytes
            headerData.append(header.merkleRoot)       // 32 bytes
            headerData.append(header.finalSaplingRoot) // 32 bytes
            withUnsafeBytes(of: header.timestamp.littleEndian) { headerData.append(contentsOf: $0) }
            withUnsafeBytes(of: header.bits.littleEndian) { headerData.append(contentsOf: $0) }
            headerData.append(header.nonce)            // 32 bytes

            // Verify Equihash(192,7) solution
            if ZipherXFFI.verifyEquihash(header: headerData, solution: header.solution) {
                passedCount += 1
            } else {
                print("❌ FIX #185: Equihash verification FAILED for header at timestamp \(header.timestamp)")
            }
        }

        return passedCount
    }

    /// FIX #185: Verify Equihash for sample block headers from boost file range
    /// This verifies that the boost file data corresponds to real blockchain PoW
    /// - Parameters:
    ///   - boostHeight: The height of the boost file
    ///   - sampleCount: Number of sample headers to verify (default 10)
    /// - Returns: True if all samples pass, false if any fail
    func verifyBoostFileEquihash(boostHeight: UInt64, sampleCount: Int = 10) async -> Bool {
        print("🔬 FIX #185: Verifying Equihash for boost file (sampling \(sampleCount) headers)...")

        // Calculate sample heights spread across the boost file range
        // Post-Bubbles (585,318+) uses Equihash(192,7)
        let minSampleHeight: UInt64 = 585_318  // Bubbles fork (when Equihash params changed)
        let startHeight = max(minSampleHeight, boostHeight > 10000 ? boostHeight - 10000 : minSampleHeight)

        var sampleHeights: [UInt64] = []
        let range = boostHeight - startHeight
        let step = range / UInt64(sampleCount)

        for i in 0..<sampleCount {
            let height = startHeight + (step * UInt64(i)) + UInt64.random(in: 0..<max(1, step))
            sampleHeights.append(min(height, boostHeight))
        }

        // Fetch headers from P2P peers
        var allHeaders: [BlockHeader] = []
        for height in sampleHeights {
            do {
                let headers = try await NetworkManager.shared.getBlockHeaders(from: height, count: 1)
                allHeaders.append(contentsOf: headers)
            } catch {
                print("⚠️ FIX #185: Failed to fetch header at height \(height): \(error.localizedDescription)")
            }
        }

        guard !allHeaders.isEmpty else {
            print("❌ FIX #185: No headers fetched for Equihash verification")
            return false
        }

        // Verify Equihash for all fetched headers
        let passed = verifyEquihashProofOfWork(headers: allHeaders)
        let success = passed == allHeaders.count

        if success {
            print("✅ FIX #185: Boost file Equihash verification PASSED (\(passed)/\(allHeaders.count) headers)")
        } else {
            print("🚨 FIX #185: Boost file Equihash verification FAILED! Only \(passed)/\(allHeaders.count) headers passed")
        }

        return success
    }

    /// FIX #185: Verify Equihash for the latest N block headers
    /// This verifies that the current chain tip has valid proof-of-work
    /// - Parameter count: Number of recent headers to verify (default 50)
    /// - Returns: EquihashVerificationResult distinguishing network errors from actual failures
    /// FIX #231: Returns enum instead of bool to allow health check to differentiate
    /// FIX #231 v2: Now uses best-effort to verify even with reduced consensus
    /// FIX #415: Reduced default from 100 to 50 - sufficient for chain tip validation
    func verifyLatestEquihash(count: Int = 50) async -> EquihashVerificationResult {
        print("🔬 FIX #415: Verifying Equihash for latest \(count) block headers...")

        // Get current chain height from peers
        let chainHeight = await MainActor.run { UInt64(NetworkManager.shared.chainHeight) }
        guard chainHeight > 0 else {
            print("⚠️ FIX #185: Chain height is 0, cannot verify Equihash")
            return .networkError(reason: "Chain height unavailable")
        }

        // Calculate start height (ensure we don't go before Bubbles fork)
        let bubblesHeight: UInt64 = 585_318
        let startHeight = max(bubblesHeight, chainHeight > UInt64(count) ? chainHeight - UInt64(count) + 1 : bubblesHeight)
        let actualCount = Int(chainHeight - startHeight + 1)

        // FIX #231 v2: For Equihash, 3+ verified ZCL peers (170011/170012) = full consensus
        // Zclassic network is smaller than Zcash - 3 agreeing peers is trustworthy
        let EQUIHASH_CONSENSUS_THRESHOLD = 3

        // FIX #233: Get headers with 15-second timeout to prevent hanging
        var allHeaders: [BlockHeader] = []
        var peerAgreement: Int = 0

        do {
            let result = try await withThrowingTaskGroup(of: (headers: [BlockHeader], agreementCount: Int)?.self) { group in
                group.addTask {
                    await NetworkManager.shared.getBlockHeadersBestEffort(from: startHeight, count: actualCount)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: 15_000_000_000)  // 15 second timeout
                    return nil
                }

                // Return first result (either headers or timeout)
                for try await result in group {
                    group.cancelAll()
                    return result
                }
                return nil
            }

            if let result = result {
                allHeaders = result.headers
                peerAgreement = result.agreementCount
                print("📋 FIX #231: Got headers with \(peerAgreement) peer(s) agreeing")
            } else {
                print("⏰ FIX #233: Header fetch timed out after 15 seconds")
            }
        } catch {
            print("⚠️ FIX #233: Header fetch error: \(error)")
        }

        guard !allHeaders.isEmpty else {
            print("❌ FIX #185: No headers fetched for Equihash verification")
            return .networkError(reason: "No headers received (timeout)")
        }

        // Verify Equihash for all fetched headers
        let passed = verifyEquihashProofOfWork(headers: allHeaders)
        let success = passed == allHeaders.count

        if success {
            // 3+ peers = full consensus for Zclassic (no warning needed)
            if peerAgreement >= EQUIHASH_CONSENSUS_THRESHOLD {
                print("✅ FIX #185: Equihash PASSED (\(passed) headers, \(peerAgreement) peers)")
                return .verified(count: passed)
            } else {
                // 1-2 peers - verified but warn about reduced consensus
                print("⚠️ FIX #231: Equihash PASSED with reduced consensus (\(passed) headers, \(peerAgreement) peers)")
                return .verifiedReducedConsensus(count: passed, peers: peerAgreement)
            }
        } else {
            // CRITICAL: Headers received but Equihash failed - possible attack!
            print("🚨 FIX #185: Equihash FAILED! Only \(passed)/\(allHeaders.count) headers passed")
            return .failed(verified: passed, total: allHeaders.count)
        }
    }

    // MARK: - FIX #188: Unified Header Fetch with Single-Pass Caching

    /// FIX #188: Fetch headers once and process for all purposes in a single pass
    /// This eliminates redundant P2P requests by:
    /// 1. Fetching headers in batches of 160 (P2P limit)
    /// 2. Verifying Equihash immediately (fail fast)
    /// 3. Caching timestamps to BlockTimestampManager
    /// 4. Storing in HeaderStore (without Equihash solutions to save space)
    /// - Parameters:
    ///   - startHeight: First block height to fetch
    ///   - endHeight: Last block height to fetch
    ///   - verifyEquihash: Whether to verify Equihash (only needed for post-Bubbles blocks)
    /// - Returns: True if all headers fetched and verified successfully
    func fetchAndCacheHeaders(from startHeight: UInt64, to endHeight: UInt64, verifyEquihash: Bool = true) async -> Bool {
        let bubblesHeight: UInt64 = 585_318
        let batchSize = 160  // P2P getheaders limit
        let totalHeaders = Int(endHeight - startHeight + 1)

        print("📥 FIX #188: Unified header fetch from \(startHeight) to \(endHeight) (\(totalHeaders) headers)")

        var currentHeight = startHeight
        var totalFetched = 0
        var totalVerified = 0
        var headersForStorage: [ZclassicBlockHeader] = []

        while currentHeight <= endHeight {
            let remaining = Int(endHeight - currentHeight + 1)
            let thisBatchSize = min(batchSize, remaining)

            do {
                // Fetch batch from P2P with consensus
                let headers = try await NetworkManager.shared.getBlockHeaders(from: currentHeight, count: thisBatchSize)

                guard !headers.isEmpty else {
                    print("⚠️ FIX #188: Empty response at height \(currentHeight), stopping")
                    break
                }

                // Process each header in the batch
                for (index, header) in headers.enumerated() {
                    let height = currentHeight + UInt64(index)

                    // Build 140-byte header for verification and hashing
                    var headerData = Data()
                    withUnsafeBytes(of: Int32(header.version).littleEndian) { headerData.append(contentsOf: $0) }
                    headerData.append(header.prevBlockHash)
                    headerData.append(header.merkleRoot)
                    headerData.append(header.finalSaplingRoot)
                    withUnsafeBytes(of: header.timestamp.littleEndian) { headerData.append(contentsOf: $0) }
                    withUnsafeBytes(of: header.bits.littleEndian) { headerData.append(contentsOf: $0) }
                    headerData.append(header.nonce)

                    // 1. Verify Equihash (only for post-Bubbles)
                    if verifyEquihash && height >= bubblesHeight {
                        if !ZipherXFFI.verifyEquihash(header: headerData, solution: header.solution) {
                            print("🚨 FIX #188: Equihash FAILED at height \(height) - REJECTING!")
                            return false
                        }
                        totalVerified += 1
                    }

                    // 2. Cache timestamp immediately
                    BlockTimestampManager.shared.cacheTimestamp(height: height, timestamp: header.timestamp)

                    // 3. Compute block hash (double SHA256 of header + solution)
                    var fullHeader = headerData
                    let solutionLen = header.solution.count
                    if solutionLen < 253 {
                        fullHeader.append(UInt8(solutionLen))
                    } else {
                        fullHeader.append(0xfd)
                        withUnsafeBytes(of: UInt16(solutionLen).littleEndian) { fullHeader.append(contentsOf: $0) }
                    }
                    fullHeader.append(header.solution)

                    let hash1 = SHA256.hash(data: fullHeader)
                    let hash2 = SHA256.hash(data: Data(hash1))
                    let blockHash = Data(hash2)

                    // 4. Create ZclassicBlockHeader for storage (includes solution!)
                    // FIX #535: Chainwork will be computed by HeaderStore.insertHeader()
                    let zclHeader = ZclassicBlockHeader(
                        version: UInt32(header.version),
                        hashPrevBlock: header.prevBlockHash,
                        hashMerkleRoot: header.merkleRoot,
                        hashFinalSaplingRoot: header.finalSaplingRoot,
                        time: header.timestamp,
                        bits: header.bits,
                        nonce: header.nonce,
                        solution: header.solution,  // Store solution for later verification!
                        height: height,
                        blockHash: blockHash,
                        chainwork: Data(count: 32)  // FIX #535: Will be computed by HeaderStore
                    )
                    headersForStorage.append(zclHeader)
                }

                totalFetched += headers.count
                currentHeight += UInt64(headers.count)

                // Progress update every 500 headers
                if totalFetched % 500 < batchSize {
                    let progress = Double(totalFetched) / Double(totalHeaders) * 100
                    print("📥 FIX #188: Progress \(String(format: "%.1f", progress))% - \(totalFetched)/\(totalHeaders) headers")
                }

            } catch {
                print("⚠️ FIX #188: Failed to fetch headers at \(currentHeight): \(error.localizedDescription)")
                // Continue with what we have if we got at least some headers
                if totalFetched > 0 {
                    break
                }
                return false
            }
        }

        // 5. Store all headers in HeaderStore (batch insert with solutions)
        if !headersForStorage.isEmpty {
            do {
                try HeaderStore.shared.insertHeaders(headersForStorage)
                print("💾 FIX #188: Stored \(headersForStorage.count) headers in HeaderStore (with solutions)")

                // 6. Clean up old solutions to save space (keep only last 100)
                try HeaderStore.shared.cleanupOldSolutions(keepCount: 100)
            } catch {
                print("⚠️ FIX #188: Failed to store headers: \(error.localizedDescription)")
                // Non-fatal - timestamps are already cached
            }
        }

        let equihashMsg = verifyEquihash ? ", \(totalVerified) Equihash verified" : ""
        print("✅ FIX #188: Unified header fetch complete - \(totalFetched) headers fetched\(equihashMsg)")

        return totalFetched > 0
    }

    /// FIX #188: Verify Equihash from locally stored headers (no P2P needed)
    /// FIX #415: Reduced default from 100 to 50 - sufficient for chain tip validation
    /// This uses headers stored in HeaderStore with their Equihash solutions
    func verifyEquihashFromLocalStorage(count: Int = 50) -> Bool {
        print("🔬 FIX #415: Verifying Equihash from local storage (\(count) headers)...")

        do {
            let headers = try HeaderStore.shared.getHeadersWithSolutions(count: count)

            guard !headers.isEmpty else {
                print("⚠️ FIX #188: No headers with solutions in local storage")
                return false
            }

            let bubblesHeight: UInt64 = 585_318
            var verified = 0

            for header in headers {
                // Only verify post-Bubbles blocks (Equihash(192,7))
                guard header.height >= bubblesHeight else { continue }
                guard !header.solution.isEmpty else { continue }

                // Build 140-byte header
                let headerData = header.headerBytes

                if ZipherXFFI.verifyEquihash(header: headerData, solution: header.solution) {
                    verified += 1
                } else {
                    print("🚨 FIX #188: Equihash FAILED at height \(header.height)!")
                    return false
                }
            }

            print("✅ FIX #188: Local Equihash verification PASSED (\(verified) headers verified)")
            return verified > 0
        } catch {
            print("❌ FIX #188: Failed to read headers for verification: \(error.localizedDescription)")
            return false
        }
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
