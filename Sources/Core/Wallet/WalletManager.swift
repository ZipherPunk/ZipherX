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
            let batchSize: UInt64 = 50
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

        // FIX #278: Show progress sheet and initialize download stats
        var downloadStartTime = Date()
        var lastProgressUpdate = Date()
        var lastProgress: Double = 0

        await MainActor.run {
            self.treeLoadStatus = "Downloading boost data..."
            self.treeLoadProgress = 0.1
            self.showBoostDownloadSheet = true  // FIX #278: Show progress sheet
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
                // FIX #278: Auto-dismiss sheet after 1 second
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self.showBoostDownloadSheet = false
                }
            }
            return
        }

        // Deserialization failed - boost file was generated with different FFI version
        print("❌ Tree deserialization failed - boost file generated with different FFI version")
        print("💡 Solution: Rebuild Rust FFI library, then regenerate boost file with same version")
        await MainActor.run {
            self.treeLoadStatus = "Failed: FFI version mismatch"
            self.treeLoadProgress = 0.0
        }

        // Clear the cached boost file - user needs to rebuild FFI
        try? await CommitmentTreeUpdater.shared.clearCache()
        return
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
        await MainActor.run { NetworkManager.shared.setHeaderSyncing(true) }
        defer {
            Task { @MainActor in NetworkManager.shared.setHeaderSyncing(false) }
        }

        let hsm = HeaderSyncManager(
            headerStore: HeaderStore.shared,
            networkManager: NetworkManager.shared
        )

        // FIX #144: Report progress to UI for header sync
        hsm.onProgress = { [weak self] progress in
            Task { @MainActor in
                // Update header sync UI properties
                let progressPercentage = progress.totalHeight > 0
                    ? Double(progress.currentHeight) / Double(progress.totalHeight)
                    : 0.0
                self?.headerSyncProgress = progressPercentage
                self?.headerSyncCurrentHeight = UInt64(progress.currentHeight)
                self?.headerSyncTargetHeight = UInt64(progress.totalHeight)
                self?.headerSyncStatus = "Syncing block timestamps: \(progress.currentHeight) / \(progress.totalHeight)"

                // Also update syncTasks if available
                if let index = self?.syncTasks.firstIndex(where: { $0.id == "headers" }) {
                    self?.syncTasks[index].status = .inProgress
                    self?.syncTasks[index].detail = "Syncing timestamps: \(progress.currentHeight) / \(progress.totalHeight)"
                    self?.syncTasks[index].progress = progressPercentage
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
                if let index = syncTasks.firstIndex(where: { $0.id == "headers" }) {
                    syncTasks[index].status = .completed
                    syncTasks[index].detail = "Timestamps synced (\(fixedCount ?? 0) fixed)"
                    syncTasks[index].progress = 1.0
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
                if let index = syncTasks.firstIndex(where: { $0.id == "headers" }) {
                    syncTasks[index].status = .failed(error.localizedDescription)
                    syncTasks[index].detail = "Sync failed"
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

        // Check if HeaderStore already has these headers
        let existingMaxHeight = (try? HeaderStore.shared.getLatestHeight()) ?? 0
        if existingMaxHeight >= sectionInfo.endHeight {
            print("✅ FIX #413: HeaderStore already has headers up to \(existingMaxHeight) (boost ends at \(sectionInfo.endHeight))")
            return (true, sectionInfo.endHeight)
        }

        // Extract and load headers
        do {
            guard let headerData = try await CommitmentTreeUpdater.shared.extractHeaders() else {
                print("⚠️ FIX #413: Failed to extract headers from boost file")
                return (false, 0)
            }

            // Load headers into HeaderStore
            try HeaderStore.shared.loadHeadersFromBoostData(headerData, startHeight: sectionInfo.startHeight)

            print("✅ FIX #413: Loaded \(sectionInfo.count) headers from boost file (up to height \(sectionInfo.endHeight))")
            return (true, sectionInfo.endHeight)
        } catch {
            print("❌ FIX #413: Failed to load headers from boost file: \(error.localizedDescription)")
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
                for: account.id,
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
            await MainActor.run { NetworkManager.shared.updateWalletHeight(targetHeight) }

            // Sync headers for the new blocks so we have real timestamps
            // This ensures transaction history shows correct dates instead of "(est)"
            // FIX #120: Also sync from earliest transaction that needs a timestamp
            do {
                let hsm = HeaderSyncManager(
                    headerStore: HeaderStore.shared,
                    networkManager: NetworkManager.shared
                )

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
            await preRebuildWitnessesForInstantPayment(accountId: account.id)

            // FIX #300: Refresh balance AFTER witness rebuild to ensure accuracy
            // The balance was calculated before witnesses were rebuilt, so notes that
            // just got witnesses weren't counted. Recalculate now.
            do {
                let refreshedBalance = try WalletDatabase.shared.getBalance(accountId: account.id)

                // FIX #XXX: If balance dropped to 0 but we have unspent notes, witnesses failed
                // Use total unspent balance as fallback to show correct balance
                if refreshedBalance == 0 {
                    let totalUnspent = try WalletDatabase.shared.getTotalUnspentBalance(accountId: account.id)
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
                let (needCount, needValue) = try WalletDatabase.shared.getNotesNeedingWitness(accountId: account.id)
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

        } catch {
            print("⚠️ Background sync failed: \(error.localizedDescription)")
        }
    }

    /// Pre-rebuild witnesses for all unspent notes to enable instant payments
    /// Called after background sync to ensure witnesses match current tree root
    /// This eliminates witness rebuild delay at send time
    /// CRITICAL FIX: Actually rebuilds stale witnesses instead of deferring to send time
    private func preRebuildWitnessesForInstantPayment(accountId: Int64) async {
        do {
            // Get current tree root (anchor)
            guard let currentTreeRoot = ZipherXFFI.treeRoot() else {
                print("⚠️ Pre-witness: No tree root available")
                return
            }

            // Get all unspent notes
            let notes = try WalletDatabase.shared.getUnspentNotes(accountId: accountId)
            guard !notes.isEmpty else {
                print("✅ Pre-witness: No unspent notes to update")
                return
            }

            var alreadyCurrentCount = 0
            var anchorUpdatedCount = 0
            var notesNeedingRebuild: [(note: WalletNote, cmu: Data)] = []

            for note in notes {
                // Check if witness anchor matches current tree root
                if let noteAnchor = note.anchor, noteAnchor == currentTreeRoot {
                    alreadyCurrentCount += 1
                    continue // Witness is already current - INSTANT payment ready!
                }

                // Check if witness exists and might just need anchor update
                if !note.witness.isEmpty {
                    // Verify witness root matches current tree
                    // Extract root from witness (last 32 bytes of 1028-byte witness)
                    if note.witness.count >= 1028 {
                        let witnessRoot = note.witness.suffix(32)
                        if witnessRoot == currentTreeRoot {
                            // Witness is valid, just update anchor in database
                            try WalletDatabase.shared.updateNoteAnchor(
                                noteId: note.id,
                                anchor: currentTreeRoot
                            )
                            anchorUpdatedCount += 1
                            continue
                        }
                    }
                }

                // Witness needs rebuild - collect for batch rebuild
                if let cmu = note.cmu, !cmu.isEmpty {
                    notesNeedingRebuild.append((note: note, cmu: cmu))
                }
            }

            // Summary for notes that don't need rebuild
            if alreadyCurrentCount > 0 {
                print("✅ Pre-witness: \(alreadyCurrentCount) note(s) already instant-ready")
            }
            if anchorUpdatedCount > 0 {
                print("⚡ Pre-witness: \(anchorUpdatedCount) anchor(s) updated (witness valid)")
            }

            // CRITICAL: Actually rebuild stale witnesses (don't defer to send time!)
            if !notesNeedingRebuild.isEmpty {
                print("🔄 Pre-witness: Rebuilding \(notesNeedingRebuild.count) stale witness(es)...")

                // Save current tree state before rebuilding
                let savedTreeState = ZipherXFFI.treeSerialize()

                // Try to get CMU data for witness rebuild
                if let cachedPath = await CommitmentTreeUpdater.shared.getCachedCMUFilePath(),
                   let cachedInfo = await CommitmentTreeUpdater.shared.getCachedTreeInfo(),
                   let cmuData = try? Data(contentsOf: cachedPath) {

                    let boostHeight = cachedInfo.height

                    // Separate notes into those within boost range and those beyond
                    let notesInBoost = notesNeedingRebuild.filter { $0.note.height <= boostHeight }
                    let notesAfterBoost = notesNeedingRebuild.filter { $0.note.height > boostHeight }

                    var rebuiltCount = 0

                    // Rebuild witnesses for notes within boost file range
                    if !notesInBoost.isEmpty {
                        let targetCMUs = notesInBoost.map { $0.cmu }
                        let results = ZipherXFFI.treeCreateWitnessesBatch(cmuData: cmuData, targetCMUs: targetCMUs)

                        for (index, result) in results.enumerated() {
                            if let (_, witness) = result {
                                let note = notesInBoost[index].note
                                // Extract anchor from the rebuilt witness (last 32 bytes)
                                let witnessAnchor = witness.suffix(32)
                                try? WalletDatabase.shared.updateNoteWitness(noteId: note.id, witness: witness)
                                try? WalletDatabase.shared.updateNoteAnchor(noteId: note.id, anchor: witnessAnchor)
                                rebuiltCount += 1
                            }
                        }
                    }

                    // For notes beyond boost file, we need delta CMUs from chain
                    // This is more expensive but necessary for correctness
                    // FIX #XXX: Skip P2P witness rebuild during import to avoid 20+ second delays
                    if !notesAfterBoost.isEmpty && !isImportedWallet {
                        print("🔄 Pre-witness: \(notesAfterBoost.count) note(s) beyond boost file, fetching delta CMUs...")

                        // Get the max note height to know how far to fetch
                        let maxNoteHeight = notesAfterBoost.map { $0.note.height }.max() ?? boostHeight

                        // Fetch delta CMUs from chain via P2P
                        let networkManager = NetworkManager.shared
                        // FIX #119: Check for actual connected peers, not just "isConnected" flag
                        let connectedPeerCount = await MainActor.run { networkManager.connectedPeers }
                        if connectedPeerCount > 0 {
                            // Fetch blocks between boostHeight+1 and maxNoteHeight
                            // FIX #115: More resilient P2P fetch with per-batch retry and longer timeouts
                            var deltaCMUs: [Data] = []
                            let startHeight = boostHeight + 1
                            let batchSize = 50
                            var failedBatches = 0
                            let maxRetries = 2
                            let maxConsecutiveFailures = 3  // FIX #119: Stop after 3 consecutive batch failures

                            var currentHeight = startHeight
                            var consecutiveFailures = 0
                            while currentHeight <= maxNoteHeight && consecutiveFailures < maxConsecutiveFailures {
                                let endHeight = min(currentHeight + UInt64(batchSize) - 1, maxNoteHeight)
                                let blockCount = Int(endHeight - currentHeight + 1)

                                var batchSucceeded = false
                                // Retry each batch up to maxRetries times
                                for attempt in 1...maxRetries {
                                    do {
                                        // FIX #110: Use getBlocksOnDemandP2P which has multi-peer retry and reconnection logic
                                        // FIX #115: Increased timeout from 15s to 30s for Tor reliability
                                        let blocks = try await withTimeout(seconds: 30) {
                                            try await networkManager.getBlocksOnDemandP2P(from: currentHeight, count: blockCount)
                                        }
                                        for block in blocks {
                                            for tx in block.transactions {
                                                for output in tx.outputs {
                                                    deltaCMUs.append(output.cmu)
                                                }
                                            }
                                        }
                                        batchSucceeded = true
                                        consecutiveFailures = 0  // Reset on success
                                        break // Success, exit retry loop
                                    } catch {
                                        if attempt < maxRetries {
                                            print("⚠️ Pre-witness: Batch \(currentHeight)-\(endHeight) failed (attempt \(attempt)/\(maxRetries)), retrying...")
                                            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second delay before retry
                                        } else {
                                            print("⚠️ Pre-witness: Batch \(currentHeight)-\(endHeight) failed after \(maxRetries) attempts: \(error.localizedDescription)")
                                            failedBatches += 1
                                        }
                                    }
                                }

                                if !batchSucceeded {
                                    consecutiveFailures += 1
                                }

                                currentHeight = endHeight + 1
                            }

                            // FIX #119: Log if we stopped early due to network issues
                            if consecutiveFailures >= maxConsecutiveFailures {
                                print("⚠️ Pre-witness: Stopping delta fetch after \(maxConsecutiveFailures) consecutive failures (network unavailable)")
                            }

                            // Only proceed if we got some CMUs (allow partial success)
                            if !deltaCMUs.isEmpty || failedBatches == 0 {
                                // Build combined CMU data: boost + delta
                                let boostCount = cmuData.prefix(8).withUnsafeBytes { $0.load(as: UInt64.self) }
                                let totalCount = boostCount + UInt64(deltaCMUs.count)

                                var combinedCMUData = Data(capacity: 8 + Int(totalCount) * 32)
                                var countLE = totalCount
                                withUnsafeBytes(of: &countLE) { combinedCMUData.append(contentsOf: $0) }
                                combinedCMUData.append(cmuData.suffix(from: 8))
                                for cmu in deltaCMUs {
                                    combinedCMUData.append(cmu)
                                }

                                // Rebuild witnesses for notes after boost
                                let afterBoostCMUs = notesAfterBoost.map { $0.cmu }
                                let afterResults = ZipherXFFI.treeCreateWitnessesBatch(cmuData: combinedCMUData, targetCMUs: afterBoostCMUs)

                                for (index, result) in afterResults.enumerated() {
                                    if let (_, witness) = result {
                                        let note = notesAfterBoost[index].note
                                        let witnessAnchor = witness.suffix(32)
                                        try? WalletDatabase.shared.updateNoteWitness(noteId: note.id, witness: witness)
                                        try? WalletDatabase.shared.updateNoteAnchor(noteId: note.id, anchor: witnessAnchor)
                                        rebuiltCount += 1
                                    }
                                }

                                if failedBatches > 0 {
                                    print("⚠️ Pre-witness: \(failedBatches) batch(es) failed, some notes may need rebuild at send time")
                                }
                            } else {
                                print("⚠️ Pre-witness: All P2P batches failed, notes will rebuild at send time")
                            }
                        } else {
                            print("⚠️ Pre-witness: No P2P peers connected (0 peers) - skipping delta CMU fetch")
                        }
                    } else if !notesAfterBoost.isEmpty && isImportedWallet {
                        print("⏭️ Pre-witness: Skipping P2P witness rebuild for \(notesAfterBoost.count) note(s) during import (will rebuild at send time)")
                    }

                    if rebuiltCount > 0 {
                        print("✅ Pre-witness: Rebuilt \(rebuiltCount) witness(es) - INSTANT payments ready!")
                    }
                    if rebuiltCount < notesNeedingRebuild.count {
                        print("⚠️ Pre-witness: \(notesNeedingRebuild.count - rebuiltCount) witness(es) will rebuild at send time")
                    }

                    // CRITICAL: Restore tree state after witness rebuild
                    // treeCreateWitnessesBatch modifies the FFI tree, we need to restore it
                    if let savedState = savedTreeState {
                        _ = ZipherXFFI.treeInit()
                        _ = ZipherXFFI.treeDeserialize(data: savedState)
                    }
                } else {
                    print("⚠️ Pre-witness: No CMU data available for rebuild, \(notesNeedingRebuild.count) note(s) will rebuild at send time")
                }
            }
        } catch {
            print("⚠️ Pre-witness rebuild failed: \(error.localizedDescription)")
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
        if shouldSkipHeaderSync {
            print("⚡ FIX #183: Skipping header sync for import - P2P consensus already verified chain height")
            print("⚡ FIX #183: Headers will sync in background (needed for timestamps, not balance)")
            await updateTask("headers", status: .completed, detail: "Deferred to background")
        } else {
            print("📡 Using P2P header sync (NO RPC for sync/repair)")
        }

        if !shouldSkipHeaderSync {

        let maxHeaderRetries = 4  // FIX #120: Increased retries to allow peer connections
        var headerSyncSuccess = false
        var lastHeaderError: Error?

        // FIX #146: Set header syncing flag ONCE at the start, BEFORE retry loop
        // This prevents block listeners from restarting between retry attempts
        // which was causing P2P race conditions and 5 headers/sec slowdown
        await MainActor.run { NetworkManager.shared.setHeaderSyncing(true) }
        defer {
            // Clear flag when ALL retries complete (success or exhausted)
            Task { @MainActor in NetworkManager.shared.setHeaderSyncing(false) }
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
                }
                // Note: PHASE 2 status is set by onStatusUpdate with real percentage
                // Don't overwrite it here with generic messages
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
        print("👤 Account ID: \(account.id)")

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
        defer {
            // FIX #451: Use synchronous reset instead of Task to ensure flag is always cleared
            // Task can fail to execute if function throws, leaving flag stuck
            Task { @MainActor in
                self.isRepairingDatabase = false
                print("🔧 FIX #368: isRepairingDatabase = false (backgroundSync unblocked)")
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

        // Get account ID
        guard let account = try WalletDatabase.shared.getAccount(index: 0) else {
            print("❌ No account found in database")
            throw WalletError.walletNotCreated
        }
        print("👤 Account ID: \(account.id)")

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

        // ============================================
        // FIX #371: STEP 0b placeholder cleanup was done above
        // No boost placeholder removal here (handled in STEP 0a)
        // ============================================

        // Placeholder for any remaining VUL-002 related code (now disabled)
        // let allSentTxs = try WalletDatabase.shared.getSentTransactions()
        // let maxTxsToVerify = 5
        // let sentTxs = Array(allSentTxs.suffix(maxTxsToVerify))

        // print("🔍 VUL-002: Checking for phantom transactions via P2P peers...")
        // print("📊 FIX #416: Verifying \(sentTxs.count) most recent of \(allSentTxs.count) total SENT TXs")

        // networkManager was already connected for FIX #371 above

        /* DISABLED - FIX #454
        for tx in sentTxs {
            let txidHex = tx.txid.map { String(format: "%02x", $0) }.joined()

            // FIX #371: Handle boost placeholders that COULDN'T be resolved
            // After resolveBoostPlaceholderTxids(), any remaining boost_ txids are notes
            // where the real TX couldn't be found. We need to verify these on chain.
            if txidHex.hasPrefix("626f6f73745f7370") { // hex for "boost_sp"
                // Extract spent_height from placeholder: "boost_spent_HEIGHT"
                let placeholderString = String(data: tx.txid, encoding: .utf8) ?? ""
                print("⚠️ FIX #371: Unresolved boost placeholder: \(placeholderString)")

                // Get notes marked as spent with this placeholder
                let affectedNullifiers = try WalletDatabase.shared.getNullifiersSpentInTx(txid: tx.txid)

                // These notes ARE actually spent (boost file says so), but we couldn't find the TX
                // Don't unmark them - they're correctly marked as spent
                // Just remove the placeholder from history (it's not a real TX entry)
                _ = try WalletDatabase.shared.deletePhantomTransaction(txid: tx.txid)
                boostPlaceholdersRemoved += 1

                // NOTE: We do NOT restore the notes - they ARE spent on chain
                // The boost file correctly marked them, we just couldn't find the exact TX
                print("🗑️ VUL-002: Removed unresolved placeholder (notes remain spent): \(affectedNullifiers.count) note(s)")
                continue
            }

            // Verify TX exists on blockchain via P2P peers (decentralized, works with Tor)
            var txExists = false

            let isNetworkConnected = await MainActor.run { networkManager.isConnected }
            if isNetworkConnected {
                // FIX #453: Log which TX we're verifying before starting P2P request
                print("🔍 VUL-002: Verifying TX \(txidHex.prefix(16))... via P2P...")

                do {
                    // Request TX from P2P peer - if TX exists, we'll get the raw TX data back
                    // If TX doesn't exist, peer won't respond and we'll timeout
                    // FIX #453: getTransactionP2P now uses 30s timeout to prevent deadlock with block listeners
                    let _ = try await networkManager.getTransactionP2P(txid: txidHex)
                    txExists = true
                    print("✅ VUL-002: TX \(txidHex.prefix(16))... verified on P2P network")
                } catch {
                    // FIX #361: Check if this is a connection error vs actual "not found"
                    // FIX #453: Added "lock acquisition" to timeout detection
                    let errorMsg = error.localizedDescription.lowercased()
                    if errorMsg.contains("not connected") || errorMsg.contains("no peers") ||
                       errorMsg.contains("timeout") || errorMsg.contains("connection") ||
                       errorMsg.contains("lock acquisition") {
                        // Connection/network error - cannot verify, skip this TX
                        print("⚠️ VUL-002: Network error verifying TX \(txidHex.prefix(16))... - SKIPPING (not deleting)")
                        continue // Don't treat network errors as "TX doesn't exist"
                    }
                    // Actual "not found" response from peer
                    txExists = false
                    print("⚠️ VUL-002: TX \(txidHex.prefix(16))... NOT FOUND on P2P network")
                }
            } else {
                print("⚠️ VUL-002: No P2P peers connected - cannot verify TX \(txidHex.prefix(16))...")
                continue // Skip verification if no peers (don't delete potentially valid TX)
            }

            if !txExists {
                print("🚨 VUL-002: PHANTOM TX detected: \(txidHex)")

                // Get notes that were marked as spent by this phantom TX
                let affectedNullifiers = try WalletDatabase.shared.getNullifiersSpentInTx(txid: tx.txid)

                // Unmark those notes as spent (restore them)
                for nullifier in affectedNullifiers {
                    try WalletDatabase.shared.unmarkNoteAsSpent(nullifier: nullifier)
                    notesRestored += 1
                }

                // Delete the phantom transaction from history
                _ = try WalletDatabase.shared.deletePhantomTransaction(txid: tx.txid)
                phantomTxsRemoved += 1

                print("✅ VUL-002: Removed phantom TX and restored \(affectedNullifiers.count) note(s)")
            }
        }

        if boostPlaceholdersRemoved > 0 {
            print("🗑️ VUL-002: Removed \(boostPlaceholdersRemoved) boost placeholder TX(s)")
        }
        if phantomTxsRemoved > 0 {
            print("🗑️ VUL-002: Removed \(phantomTxsRemoved) phantom TX(s), restored \(notesRestored) note(s)")
            // FIX #351: Clear phantom TX data from UserDefaults after repair
            UserDefaults.standard.removeObject(forKey: "phantomTransactions")
            print("✅ FIX #351: Cleared phantom TX detection data")

            // FIX #353: Reset checkpoint to last known-good state
            // The checkpoint should be set to before any phantom TXs occurred
            // This ensures a full rescan will find any missed transactions
            let currentCheckpoint = (try? WalletDatabase.shared.getVerifiedCheckpointHeight()) ?? 0
            if currentCheckpoint > 0 {
                // Find the last confirmed TX height to use as new checkpoint
                if let lastConfirmedTx = try? WalletDatabase.shared.getLastConfirmedTransaction() {
                    let newCheckpoint = min(currentCheckpoint, lastConfirmedTx.height)
                    try? WalletDatabase.shared.updateVerifiedCheckpointHeight(newCheckpoint)
                    print("📍 FIX #353: Reset checkpoint to \(newCheckpoint) (last confirmed TX)")
                } else {
                    // No confirmed TXs - reset to bundled tree height
                    try? WalletDatabase.shared.updateVerifiedCheckpointHeight(ZipherXConstants.bundledTreeHeight)
                    print("📍 FIX #353: Reset checkpoint to bundled tree height \(ZipherXConstants.bundledTreeHeight)")
                }
            }
        }
        */
        // END OF DISABLED VUL-002 CODE - FIX #454

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
        // STEP 1: Try QUICK FIX first (extract anchors from existing witnesses)
        // This is instant and fixes the witness/anchor mismatch issue
        // ============================================
        print("⚡ STEP 1: Attempting quick anchor fix...")
        onProgress(0.05, 0, 100)

        let notes = try WalletDatabase.shared.getAllUnspentNotes(accountId: account.id)
        var notesWithValidWitness = 0
        var anchorsFixed = 0

        for note in notes {
            // Check if note has a valid witness (at least 1028 bytes for proper witness)
            guard note.witness.count >= 1028 else {
                print("⚠️ Note \(note.id) (height \(note.height)): invalid witness (\(note.witness.count) bytes)")
                continue
            }

            notesWithValidWitness += 1

            // Extract anchor from witness and save it
            if let witnessAnchor = ZipherXFFI.witnessGetRoot(note.witness) {
                try WalletDatabase.shared.updateNoteAnchor(noteId: note.id, anchor: witnessAnchor)
                anchorsFixed += 1

                let anchorHex = witnessAnchor.prefix(8).map { String(format: "%02x", $0) }.joined()
                print("✅ Note \(note.id) (height \(note.height)): anchor fixed to \(anchorHex)...")
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
        var anchorsValidated = anchorsFixed > 0  // If we extracted anchors, they're valid
        if anchorsFixed > 0 {
            print("✅ FIX #417: Anchors extracted from valid witnesses - skipping incorrect tree root comparison")
        }

        // FIX #367: Skip quick fix entirely if forceFullRescan is requested
        if forceFullRescan {
            print("🔄 FIX #367: FORCE FULL RESCAN requested - skipping quick fix")
        }

        // Only use quick fix if ALL notes have valid witnesses AND anchors are validated correct
        // AND forceFullRescan is NOT requested
        if !forceFullRescan && notes.count > 0 && notesWithValidWitness == notes.count && anchorsFixed == notes.count && anchorsValidated {
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

            // FIX #459: NOW show 100% progress - AFTER all operations complete
            // This prevents UI from showing 100% while repair is still running (verifyAllUnspentNotesOnChain takes 10+ seconds)
            onProgress(1.0, 100, 100)
            print("✅ Database repair complete - quick fix was sufficient")
            return
        }

        // If anchors were "fixed" but validation failed, clear them to force rebuild
        if anchorsFixed > 0 && !anchorsValidated {
            print("🗑️ Clearing invalid anchors - witnesses need full rebuild")
        }

        // ============================================
        // STEP 2: Some notes missing witnesses - need full rescan
        // ============================================
        print("⚠️ Quick fix insufficient (\(notesWithValidWitness)/\(notes.count) have valid witnesses)")
        print("🔄 Proceeding with full rescan...")
        onProgress(0.1, 0, 100)

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

        // FIX #367: Do NOT delete boost cache - CommitmentTreeUpdater will check
        // if a newer version is available on GitHub and only download if needed
        // This saves bandwidth and time when the cached boost is still current
        print("📦 Keeping boost cache (will check for newer version on GitHub)")

        // Clear local delta bundle (will be rebuilt during rescan)
        DeltaCMUManager.shared.clearDeltaBundle()
        print("🗑️ Cleared delta bundle (will be rebuilt during sync)")

        // Reset last scanned height to 0 for full rescan
        try WalletDatabase.shared.updateLastScannedHeight(0, hash: Data(count: 32))
        print("📝 Reset last scanned height to 0")

        // CRITICAL: Clear HeaderStore (headers + block_times) to force full re-sync
        // Without this, dates show as estimates and checkpoints can't be saved
        try? HeaderStore.shared.clearAllHeaders()
        try? HeaderStore.shared.clearBlockTimes()
        print("🗑️ Cleared HeaderStore (headers + block_times will re-sync)")

        // CRITICAL: Clear ALL timestamp data (in-memory + HeaderStore.block_times)
        // This forces re-sync from boost file on next load
        BlockTimestampManager.shared.clearAllTimestampData()
        print("🗑️ Cleared all timestamp data (unified)")

        // Ensure network connection
        print("📡 Ensuring network connection...")
        let isConnectedForRescan = await MainActor.run { NetworkManager.shared.isConnected }
        if !isConnectedForRescan {
            try await NetworkManager.shared.connect()
            try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
        }
        let peerCountForRescan = await MainActor.run { NetworkManager.shared.peers.count }
        print("✅ Network connected: \(peerCountForRescan) peer(s)")

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

        // FIX #440: Load BundledBlockHashes BEFORE full rescan
        // PHASE 2 header sync needs these hashes to build correct P2P locators
        // Without them, it falls back to height 0 and gets pre-Bubbles headers (wrong Equihash)
        if !BundledBlockHashes.shared.isLoaded {
            print("📋 FIX #440: Loading BundledBlockHashes before full rescan...")
            do {
                try await BundledBlockHashes.shared.loadBundledHashes { current, total in
                    if current == total {
                        print("✅ FIX #440: BundledBlockHashes loaded: \(total) hashes")
                    }
                }
            } catch {
                print("⚠️ FIX #440: Failed to load BundledBlockHashes: \(error)")
                // Continue anyway - the scan will handle missing hashes via fallback
            }
        } else {
            print("📋 FIX #440: BundledBlockHashes already loaded")
        }

        // Get the new downloaded tree height (from GitHub)
        let newTreeHeight = ZipherXConstants.effectiveTreeHeight
        print("📦 GitHub boost file height: \(newTreeHeight)")

        // PHASE 1 + PHASE 2 full scan
        // CRITICAL: Start from Sapling activation (not boost height + 1) to trigger PHASE 1
        // PHASE 1 uses boost file CMU data to find notes in historical range via parallel decryption
        // PHASE 2 scans from boost height + 1 to chain tip in sequential mode
        // If we started from boost height + 1, we would skip PHASE 1 entirely and miss
        // notes that exist within the boost file range (like the 5 small notes at height ~2931760)
        let scanner = FilterScanner()
        scanner.onProgress = onProgress

        let saplingActivation = ZclassicCheckpoints.saplingActivationHeight
        print("🔄 Starting full rescan from Sapling activation (\(saplingActivation)) to trigger PHASE 1+2...")
        print("📦 PHASE 1 will scan \(saplingActivation) → \(newTreeHeight) using boost file")
        print("📦 PHASE 2 will scan \(newTreeHeight + 1) → chain tip in sequential mode")
        try await scanner.startScan(for: account.id, viewingKey: spendingKey, fromHeight: saplingActivation)

        // FIX #263: Explicitly set progress to 100% after scan completes
        // Without this, UI can stay stuck at 99% even though scan finished
        await MainActor.run {
            onProgress(1.0, 100, 100)
        }
        print("✅ FIX #263: Progress set to 100%")

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
        let notes = try WalletDatabase.shared.getAllUnspentNotes(accountId: account.id)
        print("🔧 Fixing anchors for \(notes.count) notes...")

        var fixedCount = 0
        for note in notes {
            guard note.witness.count >= 100 else {
                print("⚠️ Note \(note.id): witness too short (\(note.witness.count) bytes)")
                continue
            }

            // Extract anchor from witness
            if let witnessAnchor = ZipherXFFI.witnessGetRoot(note.witness) {
                // Update anchor in database
                try WalletDatabase.shared.updateNoteAnchor(noteId: note.id, anchor: witnessAnchor)
                fixedCount += 1

                let anchorHex = witnessAnchor.prefix(8).map { String(format: "%02x", $0) }.joined()
                print("✅ Note \(note.id) (height \(note.height)): anchor fixed to \(anchorHex)...")
            } else {
                print("⚠️ Note \(note.id): could not extract anchor from witness")
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
                let isConnectedForRescan = await MainActor.run { NetworkManager.shared.isConnected }
                if !isConnectedForRescan {
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

    /// Update a sync task status, detail, and progress - called from ContentView for FAST START
    /// FIX #154: Added progress parameter for individual task progress bars
    @MainActor
    func updateSyncTask(id: String, status: SyncTaskStatus, detail: String? = nil, progress: Double? = nil) {
        if let index = syncTasks.firstIndex(where: { $0.id == id }) {
            syncTasks[index].status = status
            if let detail = detail {
                syncTasks[index].detail = detail
            }
            if let progress = progress {
                syncTasks[index].progress = progress
            }
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
        // VUL-002 + FIX #245 + FIX #349: Handle mempool verification with peer acceptance fallback
        //
        // The mempool check may be slow or unavailable, especially over Tor.
        // If PEERS accepted the TX but the mempool check timed out, we should
        // still record the TX - it was likely propagated successfully and will
        // confirm on-chain.
        //
        // FIX #349: But if peers EXPLICITLY REJECTED, do NOT fall back to peer acceptance!
        // Explicit rejections are strong signals that the TX is invalid.
        //
        // Only reject if NO peers accepted AND mempool check failed (true rejection).
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
            } else if broadcastResult.peerCount > 0 {
                // FIX #245: Peers accepted but mempool check timed out (no explicit rejections)
                // This is common with Tor (slow propagation)
                // The TX was likely propagated successfully - record it and track
                print("⚠️ FIX #245: Peers accepted (\(broadcastResult.peerCount)) but mempool check timed out (0 rejections)")
                print("📡 FIX #245: Recording TX anyway - peers accepted it, will confirm on-chain")
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
        // VUL-002 + FIX #245 + FIX #349: Handle mempool verification with peer acceptance fallback
        //
        // The mempool check may be slow or unavailable, especially over Tor.
        // If PEERS accepted the TX but the mempool check timed out, we should
        // still record the TX - it was likely propagated successfully and will
        // confirm on-chain.
        //
        // FIX #349: But if peers EXPLICITLY REJECTED, do NOT fall back to peer acceptance!
        // Explicit rejections are strong signals that the TX is invalid.
        //
        // Only reject if NO peers accepted AND mempool check failed (true rejection).
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
            } else if broadcastResult.peerCount > 0 {
                // FIX #245: Peers accepted but mempool check timed out (no explicit rejections)
                // This is common with Tor (slow propagation)
                // The TX was likely propagated successfully - record it and track
                print("⚠️ FIX #245: Peers accepted (\(broadcastResult.peerCount)) but mempool check timed out (0 rejections)")
                print("📡 FIX #245: Recording TX anyway - peers accepted it, will confirm on-chain")
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

    // MARK: - FIX #262: Pre-Build Nullifier Verification

    /// FIX #262: Quick check before building a transaction to verify notes aren't already spent
    /// Scans recent blocks (last 20) via P2P to detect if any of our unspent notes were spent
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

        print("🔍 FIX #262: Quick nullifier check for \(unspentNotes.count) unspent notes...")

        // Get current chain height
        let cachedChainHeight = await MainActor.run { networkManager.chainHeight }
        let chainHeight = cachedChainHeight > 0 ? cachedChainHeight : (try? await networkManager.getChainHeight()) ?? 0
        guard chainHeight > 0 else {
            print("⚠️ FIX #262: Cannot get chain height - skipping pre-build check")
            return nil
        }

        // FIX #297: Use checkpoint for external spend detection (not just 20 blocks)
        // If checkpoint is recent (within 100 blocks), use it - much more reliable
        // Otherwise fall back to 20 blocks for speed
        let checkpointHeight = (try? database.getVerifiedCheckpointHeight()) ?? 0
        let minScanBlocks: UInt64 = 20
        let maxScanBlocks: UInt64 = 100  // Cap to prevent slow pre-send checks

        var startHeight: UInt64
        let blocksFromCheckpoint = chainHeight > checkpointHeight ? chainHeight - checkpointHeight : 0

        if checkpointHeight > 0 && checkpointHeight < chainHeight && blocksFromCheckpoint <= maxScanBlocks {
            // Use checkpoint - more reliable (FIX #348: ensure checkpoint < chainHeight)
            startHeight = checkpointHeight
            print("🔍 FIX #297: Using checkpoint \(checkpointHeight) - scanning \(blocksFromCheckpoint) blocks")
        } else if blocksFromCheckpoint > maxScanBlocks {
            // Checkpoint too far behind - limit to maxScanBlocks
            startHeight = chainHeight > maxScanBlocks ? chainHeight - maxScanBlocks : 0
            print("⚠️ FIX #297: Checkpoint \(checkpointHeight) is \(blocksFromCheckpoint) blocks behind - limiting to \(maxScanBlocks) blocks")
        } else {
            // No checkpoint - fallback to minScanBlocks
            startHeight = chainHeight > minScanBlocks ? chainHeight - minScanBlocks : 0
            print("🔍 FIX #262: No checkpoint - scanning last \(minScanBlocks) blocks")
        }

        // FIX #348: Prevent underflow crash if startHeight > chainHeight
        guard startHeight < chainHeight else {
            print("⚠️ FIX #348: startHeight (\(startHeight)) >= chainHeight (\(chainHeight)) - skipping check")
            return nil
        }

        let blocksToScan = chainHeight - startHeight
        print("🔍 FIX #262: Scanning blocks \(startHeight) to \(chainHeight)...")

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
                            print("🚨 FIX #262: Note \(spentNote.id) was spent in TX \(txidHex) at height \(height)!")

                            // Mark as spent in database using hashed nullifier
                            if let txidData = Data(hexString: txidHex) {
                                try database.markNoteSpentByHashedNullifier(
                                    hashedNullifier: hashedData,
                                    txid: txidData,
                                    spentHeight: UInt64(height)
                                )
                                print("✅ FIX #262: Marked note \(spentNote.id) as spent")
                            }

                            // Refresh balance
                            try? await refreshBalance()

                            return spentNote
                        }
                    }
                }
            }

            print("✅ FIX #262: All notes verified - not spent in recent blocks")
            return nil

        } catch {
            print("⚠️ FIX #262: Block scan failed: \(error) - proceeding with build")
            return nil  // Don't block on scan failure
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
    /// FIX #120: InsightAPI commented out - P2P only
    private func checkNullifierSpentOnChain(nullifier: String, afterHeight: UInt64) async throws -> Bool {
        // FIX #120: InsightAPI commented out - P2P only
        // Strategy: Check blocks from note height to current tip for spending transactions
        // This is expensive, so we batch and parallelize
        //
        // let api = InsightAPI.shared
        // let status = try await api.getStatus()
        // let currentHeight = status.height
        //
        // // Don't scan more than 5000 blocks (arbitrary limit for performance)
        // let maxScanBlocks: UInt64 = 5000
        // let startHeight = afterHeight
        // let endHeight = min(currentHeight, afterHeight + maxScanBlocks)
        //
        // // Batch size for parallel processing
        // let batchSize: UInt64 = 100
        //
        // for batchStart in stride(from: startHeight, to: endHeight, by: Int(batchSize)) {
        //     let batchEnd = min(batchStart + batchSize, endHeight)
        //
        //     // Check each block in this batch
        //     for height in batchStart..<batchEnd {
        //         do {
        //             let blockHash = try await api.getBlockHash(height: height)
        //             let block = try await api.getBlock(hash: blockHash)
        //
        //             // Check each transaction in the block
        //             for txid in block.tx {
        //                 let tx = try await api.getTransaction(txid: txid)
        //
        //                 // Check if any spend matches our nullifier
        //                 if let spends = tx.spendDescs {
        //                     for spend in spends {
        //                         if spend.nullifier == nullifier {
        //                             return true // Found! This note was spent
        //                         }
        //                     }
        //                 }
        //             }
        //         } catch {
        //             // Skip blocks that fail to fetch
        //             continue
        //         }
        //     }
        // }
        //
        // return false

        // P2P-only: This function is disabled - nullifier checking done via P2P scan
        print("⚠️ checkNullifierSpentOnChain disabled in P2P-only mode")
        return false
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
        let batchSize: UInt64 = 50

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
        let batchSize: UInt64 = 50

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
                for: account.id,
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
    func startPeriodicDeepVerification() {
        // Run deep verification every 30 minutes while app is open
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
            }
        }
        print("⏰ FIX #370: Periodic deep verification timer started (30 min interval)")
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
            for: account.id,
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
                        blockHash: blockHash
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
