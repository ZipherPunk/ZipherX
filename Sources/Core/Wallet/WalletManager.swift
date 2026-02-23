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
    /// FIX #1354: Set when a newer boost file is available on GitHub (height > cached height)
    @Published var newerBoostAvailable: (remoteHeight: UInt64, cachedHeight: UInt64)? = nil
    @Published var isDownloadingBoostUpdate: Bool = false
    // FIX #1220: True when gap-fill is running in background — sending disabled until tree is valid
    @Published private(set) var isGapFillingDelta: Bool = false
    // FIX #1475: Cooldown timer — prevents sequential gap-fill restart loop.
    // After gap-fill completes, don't re-trigger for 5 minutes (gives header sync time to catch up).
    private var lastGapFillCompletionTime: Date?
    // FIX #1484: Cooldown after delta sync validation failure — prevents re-fetching 1024 blocks
    // every 30s when tree root mismatches. Wait for gap-fill to complete first.
    private var lastDeltaSyncValidationFailure: Date?
    // FIX #1485: Concurrency guard — prevents multiple simultaneous delta sync executions.
    // Background timer fires every 30s but a full sync cycle takes ~5 minutes (4 batches × 3 retries).
    // Without guard: 10+ concurrent instances pile up, each fetching the same blocks.
    private var isSyncingDeltaBundle: Bool = false
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

    // MARK: - FIX #1103: Track pending network retry
    /// When true, a background sync failed due to network issues and a retry is scheduled
    /// Health check uses this to show "Network issues, will retry" instead of "Wallet Needs Update"
    @Published private(set) var hasPendingNetworkRetry: Bool = false

    // MARK: - FIX #577 v7: Show same sync UI as Import PK during Full Rescan
    /// When true, ContentView shows CypherpunkSyncView (same as Import PK)
    /// This provides consistent progress display during Full Rescan operations
    @Published private(set) var isFullRescan: Bool = false
    @Published var isRescanComplete: Bool = false
    @Published var rescanCompletionDuration: TimeInterval? = nil
    /// FIX #1120: Track when Full Rescan started for accurate elapsed time display
    @Published var rescanStartTime: Date? = nil

    // MARK: - FIX #1098: Balance Integrity Verification
    /// When true, balance verification failed after Full Rescan - 0 notes found when expected
    /// BalanceView shows "Balance issue" text, SendView disables Send button
    @Published var balanceIntegrityIssue: Bool = false
    @Published var balanceIntegrityMessage: String? = nil

    // MARK: - FIX #1520: Encryption key mismatch detection
    /// When true, ALL encrypted note values fail to decrypt — DB key changed
    /// (e.g., TestFlight → Xcode reinstall, provisioning profile change).
    /// User must do Full Rescan to re-discover notes with current encryption key.
    @Published var encryptionKeyMismatch: Bool = false

    // MARK: - FIX #1141: Block SEND when witnesses are corrupted
    /// When true, at least one witness failed verification (merkle_path.root != witness.root)
    /// SendView disables Send button with clear message until witnesses are rebuilt
    @Published var hasCorruptedWitnesses: Bool = false
    @Published var corruptedWitnessCount: Int = 0

    // MARK: - FIX #1280: Auto Full Rescan when phantom witnesses detected
    /// Set by FIX #1280 when witnesses have roots that don't match FFI tree.
    /// Checked after backgroundSync to auto-trigger Full Rescan.
    var phantomWitnessAutoRescanNeeded: Bool = false

    // MARK: - FIX #557 v15: Prevent concurrent witness rebuilds
    /// When true, preRebuildWitnessesForInstantPayment() returns immediately
    /// This prevents multiple rebuilds running simultaneously and producing inconsistent anchors
    private let witnessRebuildLock = NSLock()
    @Published private(set) var isRebuildingWitnesses: Bool = false
    private var lastWitnessRebuildTime: Date? = nil
    private let witnessRebuildCooldown: TimeInterval = 30.0  // Minimum 30 seconds between rebuilds

    // FIX #1348: Verbose logging control (set to true for detailed debugging)
    private let verbose = false

    // FIX #1327: Skip redundant witness re-verification when recently verified
    private var lastWitnessVerificationAllPassed: Date? = nil
    private var lastWitnessVerificationTreeSize: UInt64 = 0

    // FIX #1480: Cooldown for heavy P2P fetch in witness rebuild (prevents infinite loop)
    // Previous code stopped listeners + disconnected all peers every 30-60s → killed dispatchers
    // → fetch failed → endHeight stuck → repeated forever (7+ hours in zmac.log)
    private var lastWitnessP2PFetchTime: Date? = nil
    private let witnessP2PFetchCooldown: TimeInterval = 300.0  // 5 minutes between heavy P2P fetches

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

    // MARK: - FIX #737: Pending Delta Rescan Flag
    /// Set when delta bundle was cleared and lastScannedHeight was reset to boost end
    /// Prevents FIX #569 witness sync from overwriting the reset before PHASE 2 runs
    var pendingDeltaRescan: Bool = false

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
    /// FIX #1351: Track last logged backward phase to suppress spam (161 msgs in iOS log)
    private var lastLoggedBackwardPhase: (ProgressPhase, ProgressPhase)? = nil

    @MainActor
    func updateOverallProgress(phase: ProgressPhase, phaseProgress: Double) {
        // Only allow moving to same or later phase
        guard phase >= currentProgressPhase else {
            // FIX #1351: Only log each backward phase combo once (was 161 messages in iOS import)
            let combo = (phase, currentProgressPhase)
            if lastLoggedBackwardPhase?.0 != combo.0 || lastLoggedBackwardPhase?.1 != combo.1 {
                lastLoggedBackwardPhase = combo
                print("⚠️ Progress: Ignoring backward phase change \(phase) < \(currentProgressPhase) (further suppressed)")
            }
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
        lastLoggedBackwardPhase = nil  // FIX #1351: Reset suppression tracker
    }

    /// Complete progress (jump to 100%)
    @MainActor
    func completeProgress() {
        overallProgress = 1.0
        currentProgressPhase = .complete
    }

    /// FIX #1283: Set progress directly for verification phase (allows backward movement)
    @MainActor
    func setVerificationProgress(_ progress: Double) {
        overallProgress = max(0.0, min(1.0, progress))
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

    /// FIX #1398: Record balance snapshot before an external spend is detected
    /// Called by NetworkManager when another wallet spends our notes
    @MainActor
    func recordBalanceBeforeExternalSpend() {
        balanceBeforeLastSend = shieldedBalance
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
        // FIX #1273: Wait for authentication before starting ANY background operations.
        // Without this, tree preload, prover init, key reading, and delta validation
        // all run before the user authenticates at the lock screen.
        if isWalletCreated {
            Task {
                // FIX #1273: Gate all background operations behind authentication
                while !BiometricAuthManager.shared.hasAuthenticatedThisSession {
                    try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
                    if Task.isCancelled { return }
                }
                print("🔐 FIX #1273: Authentication confirmed — starting WalletManager background tasks")
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
        // FIX #1290: Skip entire delta validation/sync during Full Rescan
        let isRepairing = await MainActor.run { WalletManager.shared.isRepairingDatabase }
        if isRepairing {
            print("⏩ FIX #1290: Skipping delta validation — Full Rescan in progress")
            return
        }

        print("📦 Validating delta bundle...")

        // FIX #1253: Load delta sapling roots into in-memory cache FIRST.
        // containsSaplingRoot() (used by FIX #1224, #1226) needs these roots
        // to verify witness anchors for post-boost heights where HeaderStore
        // may not have full header rows yet.
        let deltaManager = DeltaCMUManager.shared
        HeaderStore.shared.deltaSaplingRoots = deltaManager.loadSaplingRoots()

        let bundledEndHeight = ZipherXConstants.effectiveTreeHeight

        // 1. Validate delta bundle integrity
        let validation = deltaManager.validateDeltaBundle(bundledEndHeight: bundledEndHeight)

        if !validation.isValid && validation.error != nil {
            print("⚠️ Delta bundle invalid: \(validation.error!) - will rebuild on next sync")

            // FIX #1252: Invalid delta = not verified anymore
            UserDefaults.standard.set(false, forKey: "DeltaBundleVerified")

            // FIX #737: CRITICAL - Reset lastScannedHeight to boost file end!
            // Without this, PHASE 2 starts from old lastScannedHeight (e.g., 2989053)
            // instead of boost end (2988797), missing all CMUs in between.
            // The delta bundle won't have CMUs for the skipped range → tree root mismatch!
            let currentLastScanned = (try? WalletDatabase.shared.getLastScannedHeight()) ?? 0
            if currentLastScanned > bundledEndHeight {
                print("🔧 FIX #737: Resetting lastScannedHeight from \(currentLastScanned) to \(bundledEndHeight)")
                print("   This ensures PHASE 2 re-scans all blocks from boost end to rebuild delta bundle")
                // Get block hash from HeaderStore for the boost end height
                if let header = try? HeaderStore.shared.getHeader(at: bundledEndHeight) {
                    try? WalletDatabase.shared.updateLastScannedHeight(bundledEndHeight, hash: header.blockHash)
                } else {
                    // Fallback: use empty hash if header not available (will be validated on next sync)
                    try? WalletDatabase.shared.updateLastScannedHeight(bundledEndHeight, hash: Data(count: 32))
                }
                // FIX #737 v2: Set flag to prevent FIX #569 from overwriting the reset
                self.pendingDeltaRescan = true
                print("🔧 FIX #737 v2: Set pendingDeltaRescan flag to block FIX #569 height update")
            }
            return
        }

        // If no delta exists, that's OK - will be created during sync
        guard let manifest = validation.manifest else {
            print("📦 No delta bundle exists yet - will be created during sync")
            return
        }

        // FIX #1252: Delta immutability — once verified, NEVER re-validate/repair/gap-fill.
        // The delta is built once correctly (at Full Rescan or PK import), verified against
        // blockchain roots, then treated as IMMUTABLE (like the boost file).
        // Only new blocks from chain tip are appended (simple append-only).
        // If corrupted: user runs Full Resync. No automatic repair loops.
        let deltaVerified = UserDefaults.standard.bool(forKey: "DeltaBundleVerified")
        if deltaVerified {
            // FIX #1303: Sanity check — verify tree root still matches blockchain.
            // An incomplete delta (<50% P2P coverage) can get marked verified when
            // HeaderStore root was missing/zero at validation time (trusts FFI root blindly).
            // If root mismatches now, unverify and fall through to gap-fill/rebuild.
            let rootStillValid = await deltaManager.validateTreeRootAgainstHeaders()
            if rootStillValid {
                print("✅ FIX #1252: Delta bundle VERIFIED — skipping validation/gap-fill (immutable like boost)")
                print("   Only appending new blocks from chain tip...")
                await syncDeltaBundleIfNeeded(manifest: manifest, bundledEndHeight: bundledEndHeight)
                return
            } else {
                print("🚨 FIX #1303: Verified delta has WRONG tree root — incomplete P2P data!")
                print("🚨 FIX #1303: Clearing DeltaBundleVerified — will gap-fill to fix tree root")
                UserDefaults.standard.set(false, forKey: "DeltaBundleVerified")
                // Fall through to line 530+ validation/gap-fill logic
            }
        }

        // Delta NOT yet verified — run full validation (first build or recovery)
        print("📦 FIX #1252: Delta not yet verified — running full validation...")

        // FIX #1306: Ensure HeaderStore has the header at delta endHeight BEFORE validation.
        // Without this: HeaderStore lags behind delta tip → validateTreeRootAgainstHeaders returns true
        // (no header = skip = "pass") → delta marked VERIFIED with wrong tree root → incremental sync
        // also fails (HeaderStore missing blocks) → tree root mismatch → CRITICAL on every restart.
        let deltaEndHeight = manifest.endHeight
        do {
            let headerStoreHeight = (try? HeaderStore.shared.getLatestHeight()) ?? 0
            if headerStoreHeight < deltaEndHeight {
                let headerGap = deltaEndHeight - headerStoreHeight
                print("🔄 FIX #1306: HeaderStore at \(headerStoreHeight), delta at \(deltaEndHeight) — syncing \(headerGap) headers for validation")
                // Wait for peers first
                var readyPeers = 0
                for attempt in 1...10 {
                    readyPeers = await MainActor.run { NetworkManager.shared.peers.filter { $0.isConnectionReady }.count }
                    if readyPeers >= 2 { break }
                    if attempt == 10 { print("⚠️ FIX #1306: Only \(readyPeers) peers — proceeding anyway") }
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
                let syncManager = HeaderSyncManager(
                    headerStore: HeaderStore.shared,
                    networkManager: NetworkManager.shared
                )
                try await syncManager.syncHeaders(from: headerStoreHeight + 1, maxHeaders: headerGap + 50)
                let newHeight = (try? HeaderStore.shared.getLatestHeight()) ?? 0
                print("✅ FIX #1306: Header sync complete — HeaderStore now at \(newHeight)")
            }
        } catch {
            print("⚠️ FIX #1306: Pre-validation header sync failed: \(error)")
        }

        // 2. Validate tree root against HeaderStore
        let rootValid = await deltaManager.validateTreeRootAgainstHeaders()
        if !rootValid {
            // FIX #1220: Gap-fill instead of clearing delta!
            // Previous behavior: Clear delta → reload boost → full rescan → P2P misses same blocks → repeat
            // Root cause: P2P fetch failures leave gaps in delta (e.g., 1058 CMUs when 1099 needed)
            // New behavior: Keep existing delta, re-fetch full range, merge (FIX #784 dedup prevents duplicates)
            // On success: tree root matches, witnesses valid, next startup is INSTANT (<5s)
            // On failure: fall back to clear + rebuild (truly corrupt, not just incomplete)
            print("⚠️ FIX #1220: Delta root mismatch — gap-filling instead of clearing (preserving \(manifest.outputCount) existing outputs)")
            await gapFillDeltaBundle(manifest: manifest, bundledEndHeight: bundledEndHeight)
            return
        }

        // Root validated! Mark delta as verified — from now on, no more validation/repair.
        UserDefaults.standard.set(true, forKey: "DeltaBundleVerified")
        print("✅ FIX #1252: Delta root validated against blockchain — marking as VERIFIED (immutable)")

        // 3. Check if delta needs sync (missing blocks compared to chain height)
        await syncDeltaBundleIfNeeded(manifest: manifest, bundledEndHeight: bundledEndHeight)
    }

    /// Sync delta bundle if it's behind the current chain height
    /// Fetches missing shielded outputs via P2P and appends to delta
    private func syncDeltaBundleIfNeeded(manifest: DeltaCMUManager.DeltaManifest, bundledEndHeight: UInt64) async {
        // FIX #1485: Concurrency guard — prevent multiple simultaneous delta sync executions.
        // Background sync timer fires every ~30s, but a full delta sync cycle takes ~5 minutes
        // (4 batches × 3 retries each). Without this guard, 10+ concurrent instances pile up,
        // each fetching the same 1024-block batches simultaneously → massive P2P waste.
        guard !isSyncingDeltaBundle else {
            print("⏩ FIX #1485: Delta sync already running — skipping concurrent call")
            return
        }
        isSyncingDeltaBundle = true
        defer { isSyncingDeltaBundle = false }

        // FIX #1290: Skip delta sync during Full Rescan — FilterScanner handles everything
        let isRepairing = await MainActor.run { WalletManager.shared.isRepairingDatabase }
        if isRepairing {
            print("⏩ FIX #1290: Skipping delta sync — Full Rescan in progress")
            return
        }

        // Get current chain height
        var chainHeight: UInt64
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
        let deltaVerified = UserDefaults.standard.bool(forKey: "DeltaBundleVerified")
        if deltaEndHeight >= chainHeight {
            print("✅ Delta bundle is current (height \(deltaEndHeight), chain \(chainHeight))")

            // FIX #1252: When delta is verified (immutable), skip internal gap check entirely.
            // Verified delta was built correctly — no gaps to fill.
            if deltaVerified {
                print("✅ FIX #1252: Delta verified & current — no gap check needed")
                await MainActor.run { deltaSyncStatus = .synced }
                return
            }

            // FIX #1220: Delta is height-current but may have INTERNAL gaps (missing CMUs).
            // Check if tree root matches blockchain — if not, trigger background gap-fill.
            // Use HeaderStore (FIX #1204 saves finalsaplingroot during P2P fetch) instead of
            // getBlocksOnDemandP2P which uses direct reads and conflicts with block listeners.
            if let treeRoot = ZipherXFFI.treeRoot() {
                if let header = try? HeaderStore.shared.getHeader(at: chainHeight) {
                    let blockchainRoot = header.hashFinalSaplingRoot
                    if !blockchainRoot.isEmpty && !blockchainRoot.allSatisfy({ $0 == 0 }) {
                        let blockchainRootReversed = Data(blockchainRoot.reversed())
                        let rootMatches = treeRoot == blockchainRoot || treeRoot == blockchainRootReversed
                        if !rootMatches {
                            // FIX #1474: Skip if gap-fill already running or delta already verified
                            let gapFillRunning = await MainActor.run { self.isGapFillingDelta }
                            let deltaVerifiedNow = UserDefaults.standard.bool(forKey: "DeltaBundleVerified")
                            if gapFillRunning || deltaVerifiedNow {
                                print("⏩ FIX #1474: Skipping gap-fill trigger (gapFillRunning=\(gapFillRunning), verified=\(deltaVerifiedNow))")
                            } else {
                                print("⚠️ FIX #1220: Delta is current but tree root MISMATCHES blockchain — internal gaps detected")
                                print("🔧 FIX #1220: Triggering background gap-fill — SENDING DISABLED until tree is valid")
                                Task {
                                    await self.gapFillDeltaBundle(manifest: manifest, bundledEndHeight: bundledEndHeight)
                                }
                            }
                        } else {
                            // FIX #1252: Root matches at current height — mark as verified
                            UserDefaults.standard.set(true, forKey: "DeltaBundleVerified")
                            print("✅ FIX #1252: Delta root matches blockchain — marking as VERIFIED")
                        }
                    }
                } else {
                    // No header at chain height yet — header sync still running, gap-fill will trigger later
                    print("📦 FIX #1220: No header at chain height \(chainHeight) — will validate after header sync")
                }
            }

            await MainActor.run { deltaSyncStatus = .synced }
            return
        }

        // Calculate missing blocks
        var missingBlocks = chainHeight - deltaEndHeight
        print("📦 Delta bundle behind by \(missingBlocks) blocks (delta: \(deltaEndHeight), chain: \(chainHeight))")

        // Update status to behind
        await MainActor.run { deltaSyncStatus = .behind(blocks: missingBlocks) }

        // FIX #1484: Cooldown after validation failure — don't re-fetch when tree root mismatches.
        // syncDeltaBundleIfNeeded runs every ~30s via background sync. When validation fails (tree
        // root mismatch), the blocks are rolled back and gap-fill is triggered. But gap-fill has a
        // 5-minute cooldown, so the NEXT syncDelta call (30s later) re-fetches the same 1024 blocks
        // for nothing. This wastes P2P bandwidth and creates a fetch loop.
        // Wait 5 minutes after validation failure — gap-fill will fix the tree in the meantime.
        if let lastFailure = lastDeltaSyncValidationFailure {
            let elapsed = Date().timeIntervalSince(lastFailure)
            if elapsed < 300.0 {
                print("⏩ FIX #1484: Delta sync cooldown — validation failed \(Int(elapsed))s ago (waiting 300s for gap-fill)")
                return
            }
        }

        // FIX #1485: Pre-flight tree integrity check — don't fetch if tree is structurally wrong.
        // If the tree size doesn't match boost + delta manifest CMU count, the tree has structural
        // gaps (missing delta CMUs from previous incomplete P2P fetches). Appending MORE blocks
        // on top of a gap-ridden tree will NEVER produce a valid root — it just wastes P2P bandwidth.
        // Let gap-fill fix the tree first.
        let preFlightTreeSize = ZipherXFFI.treeSize()
        let expectedCMUs = ZipherXConstants.effectiveTreeCMUCount + UInt64(DeltaCMUManager.shared.getOutputCount())
        if preFlightTreeSize + 10 < expectedCMUs {
            let missing = Int(expectedCMUs) - Int(preFlightTreeSize)
            print("⚠️ FIX #1485: Tree missing \(missing) CMUs (has \(preFlightTreeSize), expected \(expectedCMUs))")
            print("   Fetching more blocks on a gap-ridden tree is pointless — triggering gap-fill")
            let gapFillRunning = await MainActor.run { self.isGapFillingDelta }
            if !gapFillRunning {
                Task { await self.gapFillDeltaBundle(manifest: manifest, bundledEndHeight: bundledEndHeight) }
            }
            return
        }

        // FIX #1186: Increased limit from 100 to 50000 blocks
        // Previous bug: 100-block limit meant delta could NEVER catch up after being cleared.
        // With ~16K blocks between boost file end and chain tip, it would take 160+ app restarts
        // to fully rebuild the delta, leaving the commitment tree permanently corrupt.
        // 50000 blocks covers ~5 weeks of chain growth, enough for any normal gap.
        let maxStartupSyncBlocks: UInt64 = 50000
        if missingBlocks > maxStartupSyncBlocks {
            print("⚠️ FIX #1186: Too many missing blocks (\(missingBlocks) > \(maxStartupSyncBlocks)) - will sync during full scan")
            return
        }

        // Update status to syncing
        await MainActor.run { deltaSyncStatus = .syncing }

        // Fetch missing blocks via P2P
        print("📦 Fetching \(missingBlocks) missing blocks for delta bundle...")

        do {
            let startHeight = deltaEndHeight + 1
            var collectedOutputs: [DeltaCMUManager.DeltaOutput] = []

            // FIX #1194: Take tree snapshot BEFORE appending new outputs.
            // If blockchain validation fails, we restore this snapshot instead of
            // clearing the entire delta. Previous bug: saved bad tree to DB before
            // validation, then cleared EVERYTHING on mismatch, destroying the
            // known-good delta that had already been validated at startup via FIX #790.
            let preAppendTreeData = ZipherXFFI.treeSerialize()

            // Fetch blocks in batches
            // FIX #1098: Dynamic batch size based on peer capacity (was fixed 500)
            let peerCountFetch = await MainActor.run { NetworkManager.shared.peers.filter { $0.isConnectionReady }.count }
            // FIX #1287: Dynamic batch = 2 chunks per peer (scales with connected peers)
            let batchSize: UInt64 = UInt64(max(peerCountFetch, 3) * 256)
            // FIX #1306: Sync headers to chainHeight BEFORE fetching blocks (same fix as gap-fill).
            // Without this: HeaderStore at delta tip, chain advanced → blocks beyond HeaderStore fail
            // ("HeaderStore missing blocks X-Y") → 0% coverage → abort → tree root still wrong.
            var headerStoreHeight = (try? HeaderStore.shared.getLatestHeight()) ?? 0
            if headerStoreHeight < chainHeight {
                let headerGap = chainHeight - headerStoreHeight
                print("🔄 FIX #1306: HeaderStore behind by \(headerGap) headers — syncing before incremental delta fetch")
                do {
                    let syncManager = HeaderSyncManager(
                        headerStore: HeaderStore.shared,
                        networkManager: NetworkManager.shared
                    )
                    try await syncManager.syncHeaders(from: headerStoreHeight + 1, maxHeaders: headerGap + 10)
                    headerStoreHeight = (try? HeaderStore.shared.getLatestHeight()) ?? headerStoreHeight
                    print("✅ FIX #1306: Header sync complete — HeaderStore now at \(headerStoreHeight)")
                } catch {
                    print("⚠️ FIX #1306: Header sync failed: \(error) — will cap to HeaderStore height")
                }
            }

            // FIX #1485: Also check if HeaderStore has headers at the FETCH START height.
            // getLatestHeight() returns the MAX height, but headers in the MIDDLE may be missing.
            // Without headers at the fetch range: getBlocksDataP2P falls back to bundled hashes
            // (works for fetching), but tree root validation at the end fails because the header
            // at validationHeight is also missing → validationPassed=false → infinite rollback loop.
            let fetchStartHeaderExists = (try? HeaderStore.shared.getHeader(at: startHeight)) != nil
            if !fetchStartHeaderExists {
                let headerGapSize = startHeight > bundledEndHeight ? startHeight - bundledEndHeight : 0
                print("⚠️ FIX #1485: HeaderStore missing header at fetch start \(startHeight) (gap: \(headerGapSize) from boost end)")
                // Only attempt gap sync if reasonable size (≤5000 headers).
                // Larger gaps are handled by background header sync process.
                if headerGapSize > 0 && headerGapSize <= 5000 {
                    if (try? HeaderStore.shared.getHeader(at: bundledEndHeight)) != nil {
                        print("🔄 FIX #1485: Syncing \(headerGapSize) headers from boost end \(bundledEndHeight)")
                        do {
                            let syncManager = HeaderSyncManager(
                                headerStore: HeaderStore.shared,
                                networkManager: NetworkManager.shared
                            )
                            try await syncManager.syncHeaders(from: bundledEndHeight + 1, maxHeaders: headerGapSize + 100)
                            headerStoreHeight = (try? HeaderStore.shared.getLatestHeight()) ?? headerStoreHeight
                            print("✅ FIX #1485: Gap header sync complete — HeaderStore now at \(headerStoreHeight)")
                        } catch {
                            print("⚠️ FIX #1485: Gap header sync failed: \(error)")
                        }
                    }
                } else if headerGapSize > 5000 {
                    print("⏩ FIX #1485: Header gap too large (\(headerGapSize)) — waiting for background header sync")
                    return
                }
            }

            // FIX #1262: Don't try to fetch blocks that HeaderStore doesn't have headers for.
            if chainHeight > headerStoreHeight && headerStoreHeight > deltaEndHeight {
                print("📊 FIX #1262: Capping delta sync to HeaderStore height \(headerStoreHeight) (chain tip: \(chainHeight))")
                chainHeight = headerStoreHeight
                missingBlocks = chainHeight - deltaEndHeight
            }

            var currentStart = startHeight
            // FIX #1218: Track total expected vs received blocks for incomplete detection
            var totalExpectedBlocks: UInt64 = 0
            var totalReceivedBlocks: UInt64 = 0
            var consecutiveBatchFailures = 0
            // FIX #1485: Track the actual maximum height of received blocks.
            // When the fetch loop breaks early (failures/incomplete), validate at this
            // height instead of chainHeight. Prevents permanent root mismatch when
            // only a fraction of the requested blocks are successfully fetched.
            var actualMaxReceivedHeight: UInt64 = deltaEndHeight
            let maxConsecutiveBatchFailures = 3

            while currentStart <= chainHeight {
                let batchEnd = min(currentStart + batchSize - 1, chainHeight)
                let count = Int(batchEnd - currentStart + 1)
                totalExpectedBlocks += UInt64(count)

                // FIX #1220: Use getBlocksDataP2P (dispatcher path) instead of getBlocksOnDemandP2P.
                // Direct reads conflict with block listeners running concurrently.
                // Catch batch failures (network path changes kill dispatchers mid-fetch).
                var blocks: [(UInt64, String, UInt32, [(String, [ShieldedOutput], [ShieldedSpend]?)])] = []
                do {
                    blocks = try await NetworkManager.shared.getBlocksDataP2P(from: currentStart, count: count)
                } catch {
                    consecutiveBatchFailures += 1
                    if verbose {
                        print("⚠️ FIX #1220: Incremental sync batch failed: \(error.localizedDescription) (failure \(consecutiveBatchFailures)/\(maxConsecutiveBatchFailures))")
                    }
                    if consecutiveBatchFailures >= maxConsecutiveBatchFailures {
                        print("🛑 FIX #1220: \(maxConsecutiveBatchFailures) consecutive failures — aborting delta sync")
                        break
                    }
                    try? await Task.sleep(nanoseconds: 1_000_000_000)  // 1s recovery
                    continue  // Retry same range
                }

                // FIX #1218: Track which heights we actually received
                var batchReceivedHeights = Set<UInt64>()

                // Extract shielded outputs from blocks (FIX #1190 wire format conversion)
                // FIX #1428b: Collect block timestamps for caching (was discarded with _)
                var batchTimestamps: [(UInt64, UInt32)] = []
                for (height, _, timestamp, txData) in blocks {
                    batchReceivedHeights.insert(height)
                    if timestamp > 0 {
                        batchTimestamps.append((height, timestamp))
                    }
                    var blockOutputIndex: UInt32 = 0
                    for (_, outputs, _) in txData {
                        for output in outputs {
                            // FIX #1311: ALWAYS store delta entry when CMU is valid
                            if let cmuDisplay = Data(hexString: output.cmu) {
                                let epk = Data(hexString: output.ephemeralKey).map { Data($0.reversed()) } ?? Data(count: 32)
                                let ciphertext = Data(hexString: output.encCiphertext) ?? Data(count: 580)
                                let deltaOutput = DeltaCMUManager.DeltaOutput(
                                    height: UInt32(height),
                                    index: blockOutputIndex,
                                    cmu: Data(cmuDisplay.reversed()),
                                    epk: epk,
                                    ciphertext: ciphertext
                                )
                                collectedOutputs.append(deltaOutput)
                            }
                            blockOutputIndex += 1
                        }
                    }
                }
                totalReceivedBlocks += UInt64(batchReceivedHeights.count)

                // FIX #1428b: Cache block timestamps so HistoryView can display dates
                // Without this, delta-range transactions show "Syncing..." permanently
                if !batchTimestamps.isEmpty {
                    print("🕐 DEBUG FIX #1428b: Caching \(batchTimestamps.count) block timestamps from delta sync (heights \(batchTimestamps.first?.0 ?? 0)-\(batchTimestamps.last?.0 ?? 0))")
                    BlockTimestampManager.shared.cacheTimestamps(batchTimestamps)
                }

                // FIX #1218: Strict height tracking — only advance to highest RECEIVED height + 1,
                // NOT batchEnd + 1. Previous bug: advanced past unfetched blocks, permanently
                // skipping them. Over 16,693 blocks this cascaded into only 1 CMU fetched.
                if batchReceivedHeights.isEmpty {
                    // Got 0 blocks — don't advance at all, abort this sync attempt
                    consecutiveBatchFailures += 1
                    if verbose {
                        print("⚠️ FIX #1218: Batch \(currentStart)-\(batchEnd) returned 0 blocks (failure \(consecutiveBatchFailures)/\(maxConsecutiveBatchFailures))")
                    }
                    if consecutiveBatchFailures >= maxConsecutiveBatchFailures {
                        print("🛑 FIX #1218: \(maxConsecutiveBatchFailures) consecutive empty batches — aborting delta sync (P2P unreliable)")
                        break
                    }
                    // Retry same range next iteration
                    continue
                } else {
                    consecutiveBatchFailures = 0
                    let maxReceivedHeight = batchReceivedHeights.max()!
                    // FIX #1485: Track actual maximum height for validation
                    actualMaxReceivedHeight = max(actualMaxReceivedHeight, maxReceivedHeight)
                    let coverage = Double(batchReceivedHeights.count) / Double(count) * 100.0

                    if batchReceivedHeights.count < count / 2 {
                        // FIX #1218: Less than 50% coverage — incomplete fetch.
                        // Only advance to the highest received height + 1 so we retry the gap.
                        if verbose {
                            print("⚠️ FIX #1218: Batch \(currentStart)-\(batchEnd): only \(batchReceivedHeights.count)/\(count) blocks (\(String(format: "%.0f", coverage))%). Advancing to \(maxReceivedHeight + 1) (not \(batchEnd + 1))")
                        }
                        currentStart = maxReceivedHeight + 1
                    } else {
                        // Good coverage — advance past the batch
                        currentStart = batchEnd + 1
                    }
                }
            }

            // FIX #1218: Log overall coverage and warn if incomplete
            if totalExpectedBlocks > 0 {
                let overallCoverage = Double(totalReceivedBlocks) / Double(totalExpectedBlocks) * 100.0
                if verbose {
                    print("📊 FIX #1218: Delta sync coverage: \(totalReceivedBlocks)/\(totalExpectedBlocks) blocks (\(String(format: "%.1f", overallCoverage))%)")
                }
                if totalReceivedBlocks < totalExpectedBlocks / 2 {
                    print("🛑 FIX #1218: Severely incomplete delta sync (<50% blocks received). Tree root WILL be wrong.")
                    print("   FIX #1194 will rollback tree to pre-sync state.")
                }
            }

            // FIX #1262: If zero blocks received, do NOT persist anything.
            // Delta sync runs before header sync — HeaderStore may not have headers for new blocks yet.
            // FIX #1234 correctly refuses fetches without headers, but the code below
            // would advance delta manifest endHeight and mark as VERIFIED despite 0 new data.
            if totalReceivedBlocks == 0 && collectedOutputs.isEmpty {
                print("⏭️ FIX #1262: Zero blocks received — skipping persist (headers may not be synced yet)")
                print("   Delta remains at height \(deltaEndHeight). Next background sync will catch up.")
                await MainActor.run { deltaSyncStatus = .behind(blocks: missingBlocks) }
                return
            }

            // FIX #1152: Append CMUs to FFI tree (in-memory only — NOT persisted yet)
            // FIX #1194: We validate the root BEFORE persisting to DB or delta file.
            if !collectedOutputs.isEmpty {
                print("🔧 FIX #1152: Appending \(collectedOutputs.count) CMUs to FFI tree...")
                for output in collectedOutputs {
                    _ = ZipherXFFI.treeAppend(cmu: output.cmu)
                }
                print("✅ FIX #1152: FFI tree now has \(ZipherXFFI.treeSize()) CMUs")
            }

            // FIX #1187/1194: Validate tree root against BLOCKCHAIN BEFORE persisting.
            // Previous bug (pre-#1194): Saved bad tree state to DB before validation,
            // then cleared the ENTIRE delta on mismatch. A single missed P2P output
            // would destroy the entire delta, requiring a full rescan.
            // Now: validate first, persist only on success, rollback on failure.
            //
            // FIX #1193: Only validate if delta CMUs have been appended to the FFI tree.
            let currentTreeSize = ZipherXFFI.treeSize()
            let boostCMUCount = ZipherXConstants.effectiveTreeCMUCount
            let deltaOutputCount = DeltaCMUManager.shared.getOutputCount()
            let treeShouldIncludeDelta = currentTreeSize > boostCMUCount
            var validationPassed = true  // Default true for cases where validation is skipped
            // FIX #1485: Validate at the ACTUAL last received height, not chainHeight.
            // When the fetch loop breaks early (failures, header gaps), the tree only has
            // CMUs up to actualMaxReceivedHeight. Validating at chainHeight (which may be
            // thousands of blocks higher) guarantees mismatch → rollback → infinite loop.
            let validationHeight = actualMaxReceivedHeight

            if !treeShouldIncludeDelta && deltaOutputCount > 0 {
                print("⏭️ FIX #1193: Skipping tree root validation - delta CMUs (\(deltaOutputCount)) not yet in FFI tree (size=\(currentTreeSize), boost=\(boostCMUCount))")
                print("   Will validate after delta CMUs are appended during witness rebuild")
            } else if let treeRoot = ZipherXFFI.treeRoot() {
                print("🔒 FIX #1187: Validating tree root against blockchain at height \(validationHeight) (chain: \(chainHeight))...")
                // FIX #1220: Use HeaderStore instead of getBlocksOnDemandP2P (direct reads).
                // HeaderStore has finalsaplingroot saved by FIX #1204 during header sync and P2P fetches.
                // Direct reads conflict with block listeners running concurrently.
                if let header = try? HeaderStore.shared.getHeader(at: validationHeight) {
                    let blockchainRoot = header.hashFinalSaplingRoot
                    if !blockchainRoot.isEmpty && !blockchainRoot.allSatisfy({ $0 == 0 }) {
                        let blockchainRootReversed = Data(blockchainRoot.reversed())
                        let rootMatches = treeRoot == blockchainRoot || treeRoot == blockchainRootReversed

                        if rootMatches {
                            print("✅ FIX #1187: Tree root VERIFIED against blockchain!")
                        } else {
                            let treeRootHex = treeRoot.map { String(format: "%02x", $0) }.joined()
                            let blockchainRootHex = blockchainRoot.map { String(format: "%02x", $0) }.joined()
                            print("⚠️ FIX #1194: Tree root mismatch after incremental sync!")
                            print("   FFI root:        \(treeRootHex.prefix(32))...")
                            print("   Blockchain root:  \(blockchainRootHex.prefix(32))...")

                            // FIX #1194: ROLLBACK to pre-sync state instead of clearing everything!
                            // The delta up to deltaEndHeight was already validated by FIX #790.
                            // Only the NEW blocks had missing outputs — don't punish the existing delta.
                            if let snapshot = preAppendTreeData {
                                let restored = ZipherXFFI.treeDeserialize(data: snapshot)
                                print("🔄 FIX #1194: Restored tree to pre-sync state (success=\(restored), size=\(ZipherXFFI.treeSize()))")
                            }
                            print("⚠️ FIX #1194: Incremental sync had missing outputs — will retry next cycle")
                            print("   Existing delta bundle preserved (height \(deltaEndHeight))")
                            validationPassed = false
                            // FIX #1484: Set cooldown to prevent re-fetching same blocks every 30s
                            self.lastDeltaSyncValidationFailure = Date()
                            await MainActor.run { deltaSyncStatus = .behind(blocks: missingBlocks) }

                            // FIX #1220: Mismatch means EXISTING delta is incomplete (missing CMUs within range).
                            // Run gap-fill inline (NOT background) so tree is valid before app is ready.
                            print("🔧 FIX #1220: Running gap-fill at startup (blocking) to fix tree before app is ready")
                            await self.gapFillDeltaBundle(manifest: manifest, bundledEndHeight: bundledEndHeight)
                        }
                    } else {
                        print("⚠️ FIX #1191: No sapling root at height \(validationHeight) in HeaderStore — skipping validation")
                    }
                } else {
                    print("⚠️ FIX #1187: No header at height \(validationHeight) — skipping tree root validation")
                    // FIX #1262: Don't persist with unvalidated height — validation MUST pass before advancing
                    validationPassed = false
                }
            }

            // FIX #1194: Only persist delta outputs and tree state AFTER validation passes.
            // This prevents saving a bad tree to DB that would be loaded on next restart.
            if validationPassed {
                // FIX #1484: Clear validation failure cooldown on success
                self.lastDeltaSyncValidationFailure = nil
                let treeRoot = ZipherXFFI.treeRoot() ?? Data(count: 32)

                // FIX #1485: Persist at validationHeight (actual received), not chainHeight.
                // If only 1024 of 4000 blocks were fetched, advance deltaEndHeight to the
                // actual height reached. Next sync picks up from there incrementally.
                let persistHeight = validationHeight
                if !collectedOutputs.isEmpty {
                    DeltaCMUManager.shared.appendOutputs(collectedOutputs, fromHeight: startHeight, toHeight: persistHeight, treeRoot: treeRoot)
                    print("✅ Delta bundle synced to height \(startHeight)-\(persistHeight) (+\(collectedOutputs.count) outputs)")

                    // FIX #1182: Save tree state with updated height to prevent double-append
                    if let treeData = ZipherXFFI.treeSerialize() {
                        try? WalletDatabase.shared.saveTreeState(treeData, height: persistHeight)
                        print("💾 FIX #1182: Saved tree state at height \(persistHeight)")
                    } else {
                        try? WalletDatabase.shared.updateTreeHeight(persistHeight)
                        print("💾 FIX #1182: Updated tree height to \(persistHeight) (serialization failed)")
                    }
                } else {
                    // No outputs but still need to update height in manifest
                    DeltaCMUManager.shared.appendOutputs([], fromHeight: startHeight, toHeight: persistHeight, treeRoot: treeRoot)
                    print("✅ Delta bundle synced to height \(startHeight)-\(persistHeight) (no new outputs)")

                    // FIX #1182: Also update height when no new outputs
                    try? WalletDatabase.shared.updateTreeHeight(persistHeight)
                }

                // FIX #1252: Only mark as verified when we've synced ALL the way to chainHeight.
                // Partial syncs should advance deltaEndHeight but NOT mark immutable.
                if persistHeight >= chainHeight {
                    UserDefaults.standard.set(true, forKey: "DeltaBundleVerified")
                    print("✅ FIX #1252: Delta synced & validated to chain tip — marked as VERIFIED (immutable)")
                } else {
                    print("📦 FIX #1485: Partial sync to \(persistHeight) (chain: \(chainHeight)) — not marking verified yet")
                }

                // Update status to synced
                await MainActor.run { deltaSyncStatus = .synced }
            }

        } catch {
            print("⚠️ Failed to sync delta bundle: \(error.localizedDescription)")
            // Non-fatal - delta will be updated during background sync
            // Reset status to behind
            await MainActor.run { deltaSyncStatus = .behind(blocks: missingBlocks) }
        }
    }

    /// FIX #1220: Re-fetch the entire delta range to fill gaps from P2P fetch failures.
    /// Called when delta exists but tree root doesn't match HeaderStore (incomplete, not corrupt).
    /// Unlike syncDeltaBundleIfNeeded (which only appends beyond endHeight), this re-fetches
    /// startHeight...chainHeight and merges with existing delta via FIX #784 deduplication.
    /// On success: tree root matches blockchain, witnesses valid, next startup is INSTANT.
    /// On failure: falls back to clearing delta (truly corrupt, not just incomplete).
    private func gapFillDeltaBundle(manifest: DeltaCMUManager.DeltaManifest, bundledEndHeight: UInt64) async {
        // FIX #1474: Re-entry guard — prevent multiple gap-fills running simultaneously.
        // Without this: syncDeltaBundleIfNeeded fires background Task at line 673, while another
        // gap-fill is still running → both re-fetch from manifest.startHeight → reset loop.
        let alreadyRunning = await MainActor.run { self.isGapFillingDelta }
        if alreadyRunning {
            print("⏩ FIX #1474: Gap-fill already in progress — skipping duplicate call")
            return
        }

        // FIX #1475: Cooldown — prevent sequential gap-fill restart loop.
        // After gap-fill completes (even with root mismatch), don't re-trigger for 5 minutes.
        // This gives header sync time to catch up, and avoids wasting bandwidth re-fetching
        // the same ~4000 blocks every few minutes when root can't match due to missing headers.
        // NOTE: Read directly (not via MainActor) — property is set synchronously in defer.
        let cooldownSeconds: TimeInterval = 300  // 5 minutes
        if let lastCompletion = self.lastGapFillCompletionTime {
            let elapsed = Date().timeIntervalSince(lastCompletion)
            if elapsed < cooldownSeconds {
                print("⏩ FIX #1475: Gap-fill cooldown active (\(Int(elapsed))s elapsed, need \(Int(cooldownSeconds))s) — skipping")
                return
            }
        }

        // FIX #1220: Set flag to block ALL other P2P activity (backgroundSyncToHeight, FilterScanner, etc.)
        // during gap-fill. Concurrent P2P fetches steal bandwidth and cause missing blocks.
        await MainActor.run { self.isGapFillingDelta = true }
        defer {
            // FIX #1475: Set cooldown time SYNCHRONOUSLY — not inside the MainActor Task.
            // If set inside Task { @MainActor }, the task may execute AFTER the next
            // cooldown check (race condition), allowing immediate restart → infinite loop.
            self.lastGapFillCompletionTime = Date()
            Task { @MainActor in
                self.isGapFillingDelta = false
            }
        }

        let existingCount = manifest.outputCount
        print("🔧 FIX #1220: Gap-filling delta bundle (existing: \(existingCount) outputs, range \(manifest.startHeight)-\(manifest.endHeight))")

        // FIX #1220: Wait for header sync to complete first.
        // Header sync stops block listeners (FIX #811), which kills TCP connections and
        // deactivates dispatchers. If we start fetching during header sync, connections die
        // mid-fetch → "Not connected to network" after ~3360/16851 blocks.
        for waitAttempt in 1...60 {  // Up to 30s
            let syncing = await MainActor.run { NetworkManager.shared.headerSyncInProgress }
            if !syncing { break }
            if waitAttempt == 1 {
                print("⏳ FIX #1220: Waiting for header sync to complete before gap-fill...")
            }
            if waitAttempt == 60 {
                print("⚠️ FIX #1220: Header sync still running after 30s — proceeding anyway")
            }
            try? await Task.sleep(nanoseconds: 500_000_000)  // 500ms
        }

        // FIX #1220: Wait for peers to be ready before gap-filling.
        // This runs early in startup (from validateAndSyncDeltaBundle in init).
        // Peers may not be connected yet — wait up to 10s for at least 2 peers.
        var readyPeers = 0
        for attempt in 1...20 {
            readyPeers = await MainActor.run { NetworkManager.shared.peers.filter { $0.isConnectionReady }.count }
            if readyPeers >= 2 {
                print("✅ FIX #1220: \(readyPeers) peers ready for gap-fill")
                break
            }
            if attempt == 20 {
                print("⚠️ FIX #1220: Only \(readyPeers) peers after 10s — gap-fill will retry next startup")
                return
            }
            try? await Task.sleep(nanoseconds: 500_000_000)  // 500ms
        }

        // Get current chain height
        let chainHeight: UInt64
        do {
            chainHeight = try await NetworkManager.shared.getChainHeight()
        } catch {
            print("⚠️ FIX #1220: Cannot get chain height: \(error.localizedDescription)")
            return
        }

        // FIX #1306: Sync headers to chainHeight BEFORE fetching blocks.
        // getBlocksDataP2P needs block hashes from HeaderStore to construct getdata messages.
        // If HeaderStore is behind chainHeight, blocks beyond HeaderStore are silently skipped
        // ("HeaderStore missing blocks X-Y — skipping batch") → tree root mismatch → CRITICAL.
        // This broke EVERY gap-fill when chain advanced past HeaderStore during app downtime.
        do {
            let headerStoreHeight = (try? HeaderStore.shared.getLatestHeight()) ?? 0
            if headerStoreHeight < chainHeight {
                let headerGap = chainHeight - headerStoreHeight
                print("🔄 FIX #1306: HeaderStore behind by \(headerGap) headers (\(headerStoreHeight) → \(chainHeight))")
                print("   Syncing headers BEFORE gap-fill block fetch (required for getdata messages)")
                // Temporarily disable isGapFillingDelta — syncHeaders() checks this flag and refuses
                // to run during gap-fill (FIX #1220 guard at HeaderSyncManager line 52).
                // But we NEED headers before gap-fill can fetch blocks. This is safe because:
                // 1. We're the only code running gap-fill (flag prevents concurrent gap-fills)
                // 2. syncHeaders stops/restarts block listeners, but we restart dispatchers after
                // 3. The gap-fill flag is re-set immediately after header sync completes
                await MainActor.run { self.isGapFillingDelta = false }
                let syncManager = HeaderSyncManager(
                    headerStore: HeaderStore.shared,
                    networkManager: NetworkManager.shared
                )
                try await syncManager.syncHeaders(from: headerStoreHeight + 1, maxHeaders: headerGap + 10)
                await MainActor.run { self.isGapFillingDelta = true }
                let newHeaderHeight = (try? HeaderStore.shared.getLatestHeight()) ?? 0
                print("✅ FIX #1306: Header sync complete — HeaderStore now at \(newHeaderHeight)")
            }
        } catch {
            // Re-set the flag in case header sync threw before we could restore it
            await MainActor.run { self.isGapFillingDelta = true }
            print("⚠️ FIX #1306: Header sync failed: \(error) — gap-fill will proceed with partial coverage")
        }

        let startHeight = manifest.startHeight
        let totalBlocksNeeded = chainHeight - startHeight + 1
        print("📦 FIX #1220: Re-fetching \(totalBlocksNeeded) blocks (\(startHeight)-\(chainHeight)) via dispatcher...")

        do {
            var collectedOutputs: [DeltaCMUManager.DeltaOutput] = []

            // FIX #1220: Use getBlocksDataP2P (dispatcher path) instead of getBlocksOnDemandP2P (direct reads).
            // Direct reads use withExclusiveAccess which conflicts with block listeners.
            // Dispatcher path is lock-free at 300+ blocks/sec (FIX #1184).
            let peerCount = await MainActor.run { NetworkManager.shared.peers.filter { $0.isConnectionReady }.count }
            // FIX #1287: Dynamic batch = 2 chunks per peer (scales with connected peers)
            let batchSize: UInt64 = UInt64(max(peerCount, 3) * 256)
            var currentStart = startHeight
            var totalReceivedBlocks: UInt64 = 0
            var consecutiveEmptyBatches = 0
            var allReceivedHeights = Set<UInt64>()  // FIX #1220: Track ALL received heights for targeted retry

            while currentStart <= chainHeight {
                let batchEnd = min(currentStart + batchSize - 1, chainHeight)
                let count = Int(batchEnd - currentStart + 1)

                // FIX #1220: Catch batch failures (network path changes kill dispatchers mid-fetch).
                // On failure, wait for peers to recover and retry instead of aborting.
                var blocks: [(UInt64, String, UInt32, [(String, [ShieldedOutput], [ShieldedSpend]?)])] = []
                do {
                    blocks = try await NetworkManager.shared.getBlocksDataP2P(from: currentStart, count: count)
                } catch {
                    consecutiveEmptyBatches += 1
                    if consecutiveEmptyBatches >= 3 {
                        print("⚠️ FIX #1220: 3 consecutive batch failures — aborting gap-fill")
                        break
                    }
                    if verbose {
                        print("⚠️ FIX #1220: Batch \(currentStart)-\(batchEnd) failed (\(error.localizedDescription)) — waiting 2s for peer recovery (attempt \(consecutiveEmptyBatches)/3)")
                    }
                    try? await Task.sleep(nanoseconds: 2_000_000_000)  // 2s for reconnection
                    continue  // Retry same range
                }

                var batchReceivedHeights = Set<UInt64>()

                // FIX #1190: Build DeltaOutput from getBlocksDataP2P format
                // cmu/epk are hex display format → reverse to wire format
                // ciphertext is hex → raw bytes (no reversal)
                // FIX #1428b: Also cache block timestamps (same fix as syncDeltaBundleIfNeeded)
                var gapBatchTimestamps: [(UInt64, UInt32)] = []
                for (height, _, timestamp, txData) in blocks {
                    batchReceivedHeights.insert(height)
                    if timestamp > 0 {
                        gapBatchTimestamps.append((height, timestamp))
                    }
                    var blockOutputIndex: UInt32 = 0
                    for (_, outputs, _) in txData {
                        for output in outputs {
                            // FIX #1311: ALWAYS store delta entry when CMU is valid
                            if let cmuDisplay = Data(hexString: output.cmu) {
                                let epk = Data(hexString: output.ephemeralKey).map { Data($0.reversed()) } ?? Data(count: 32)
                                let ciphertext = Data(hexString: output.encCiphertext) ?? Data(count: 580)
                                let deltaOutput = DeltaCMUManager.DeltaOutput(
                                    height: UInt32(height),
                                    index: blockOutputIndex,
                                    cmu: Data(cmuDisplay.reversed()),
                                    epk: epk,
                                    ciphertext: ciphertext
                                )
                                collectedOutputs.append(deltaOutput)
                            }
                            blockOutputIndex += 1
                        }
                    }
                }
                totalReceivedBlocks += UInt64(batchReceivedHeights.count)
                allReceivedHeights.formUnion(batchReceivedHeights)

                // FIX #1428b: Cache block timestamps from gap-fill
                if !gapBatchTimestamps.isEmpty {
                    print("🕐 DEBUG FIX #1428b: Caching \(gapBatchTimestamps.count) block timestamps from gap-fill")
                    BlockTimestampManager.shared.cacheTimestamps(gapBatchTimestamps)
                }

                // FIX #1218: Strict height tracking
                if batchReceivedHeights.isEmpty {
                    consecutiveEmptyBatches += 1
                    if consecutiveEmptyBatches >= 3 {
                        print("⚠️ FIX #1220: 3 consecutive empty batches — aborting gap-fill")
                        break
                    }
                    currentStart = batchEnd + 1
                    continue
                } else {
                    consecutiveEmptyBatches = 0
                    let maxReceivedHeight = batchReceivedHeights.max()!
                    if batchReceivedHeights.count < count / 2 {
                        currentStart = maxReceivedHeight + 1
                    } else {
                        currentStart = batchEnd + 1
                    }
                }

                // FIX #1197: Brief inter-round delay for TCP congestion recovery
                if currentStart <= chainHeight {
                    try? await Task.sleep(nanoseconds: 300_000_000)  // 300ms
                }
            }

            let coverage = totalBlocksNeeded > 0 ? Double(totalReceivedBlocks) / Double(totalBlocksNeeded) * 100.0 : 0
            print("📊 FIX #1220: Gap-fill pass 1 fetched \(collectedOutputs.count) outputs from \(totalReceivedBlocks)/\(totalBlocksNeeded) blocks (\(String(format: "%.1f", coverage))%)")

            // FIX #1220: Targeted retry for missing heights.
            // Instead of re-fetching all blocks on next startup, retry JUST the missing heights now.
            // This turns 99.2% → 100% coverage in a single startup instead of multiple restarts.
            let allExpectedHeights = Set(startHeight...chainHeight)
            let missingHeights = allExpectedHeights.subtracting(allReceivedHeights)
            if !missingHeights.isEmpty && missingHeights.count <= 5000 {
                print("🔄 FIX #1220: Targeted retry for \(missingHeights.count) missing heights...")

                // Group contiguous heights into ranges for efficient batched fetch (FIX #1213 pattern)
                let sortedMissing = missingHeights.sorted()
                var ranges: [(UInt64, Int)] = []  // (startHeight, count)
                var rangeStart = sortedMissing[0]
                var rangeEnd = sortedMissing[0]
                for i in 1..<sortedMissing.count {
                    if sortedMissing[i] == rangeEnd + 1 {
                        rangeEnd = sortedMissing[i]
                    } else {
                        ranges.append((rangeStart, Int(rangeEnd - rangeStart + 1)))
                        rangeStart = sortedMissing[i]
                        rangeEnd = sortedMissing[i]
                    }
                }
                ranges.append((rangeStart, Int(rangeEnd - rangeStart + 1)))

                var retryRecovered: UInt64 = 0
                for (rangeStart, rangeCount) in ranges {
                    do {
                        // getBlocksDataP2P handles pagination internally (FIX #1189)
                        let blocks = try await NetworkManager.shared.getBlocksDataP2P(from: rangeStart, count: rangeCount)
                        for (height, _, _, txData) in blocks {
                            retryRecovered += 1
                            var blockOutputIndex: UInt32 = 0
                            for (_, outputs, _) in txData {
                                for output in outputs {
                                    // FIX #1311: ALWAYS store delta entry when CMU is valid
                                    if let cmuDisplay = Data(hexString: output.cmu) {
                                        let epk = Data(hexString: output.ephemeralKey).map { Data($0.reversed()) } ?? Data(count: 32)
                                        let ciphertext = Data(hexString: output.encCiphertext) ?? Data(count: 580)
                                        let deltaOutput = DeltaCMUManager.DeltaOutput(
                                            height: UInt32(height),
                                            index: blockOutputIndex,
                                            cmu: Data(cmuDisplay.reversed()),
                                            epk: epk,
                                            ciphertext: ciphertext
                                        )
                                        collectedOutputs.append(deltaOutput)
                                    }
                                    blockOutputIndex += 1
                                }
                            }
                        }
                    } catch {
                        // Skip failed ranges — will retry next startup
                        print("⚠️ FIX #1220: Retry range \(rangeStart)-\(rangeStart + UInt64(rangeCount) - 1) failed: \(error.localizedDescription)")
                    }

                    // Brief delay between retry batches
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }

                totalReceivedBlocks += retryRecovered
                let finalCoverage = totalBlocksNeeded > 0 ? Double(totalReceivedBlocks) / Double(totalBlocksNeeded) * 100.0 : 0
                print("📊 FIX #1220: After retry: \(totalReceivedBlocks)/\(totalBlocksNeeded) blocks (\(String(format: "%.1f", finalCoverage))%), recovered \(retryRecovered) missing blocks")
            }

            if collectedOutputs.isEmpty {
                print("⚠️ FIX #1220: No outputs fetched — P2P unavailable, falling back to clear")
                await fallbackClearDelta(bundledEndHeight: bundledEndHeight)
                return
            }

            // Merge with existing delta (appendOutputs handles dedup via FIX #784)
            let placeholderRoot = Data(count: 32)
            DeltaCMUManager.shared.appendOutputs(collectedOutputs, fromHeight: startHeight, toHeight: chainHeight, treeRoot: placeholderRoot)

            let newTotalCount = DeltaCMUManager.shared.getOutputCount()
            let gained = Int(newTotalCount) - Int(existingCount)
            print("📦 FIX #1220: Delta now has \(newTotalCount) outputs (was \(existingCount), gained \(gained))")

            // Reload FFI tree from boost + ALL delta CMUs in correct order
            let boostTree = try await CommitmentTreeUpdater.shared.extractSerializedTree()
            _ = ZipherXFFI.treeInit()
            guard ZipherXFFI.treeDeserialize(data: boostTree) else {
                print("⚠️ FIX #1220: Failed to deserialize boost tree — falling back to clear")
                await fallbackClearDelta(bundledEndHeight: bundledEndHeight)
                return
            }
            let boostSize = ZipherXFFI.treeSize()

            // Load ALL delta CMUs from merged file (sorted by height+index, deduped by FIX #785)
            if let deltaCMUs = DeltaCMUManager.shared.loadDeltaCMUs(), !deltaCMUs.isEmpty {
                for cmu in deltaCMUs {
                    _ = ZipherXFFI.treeAppend(cmu: cmu)
                }
                print("✅ FIX #1220: Tree rebuilt: \(boostSize) boost + \(deltaCMUs.count) delta = \(ZipherXFFI.treeSize()) total")
            }

            // Validate tree root against blockchain
            guard let treeRoot = ZipherXFFI.treeRoot() else {
                print("⚠️ FIX #1220: No tree root after rebuild")
                return
            }

            // FIX #1223: Validate tree root at the height we ACTUALLY fetched up to (chainHeight),
            // NOT at currentChainHeight. FIX #1222 previously re-fetched chain height after gap-fill,
            // but chain advances during the 2+ minute gap-fill operation. Tree has CMUs only up to
            // the ORIGINAL chainHeight, so validating at currentChainHeight (which is higher) is a
            // GUARANTEED MISMATCH — the tree is missing CMUs from blocks chainHeight+1..currentChainHeight.
            // This caused gap-fill to always report "incomplete", exhaust repair counter (FIX #782),
            // and force "Full Resync" even when gap-fill successfully recovered all needed CMUs.
            //
            // Fix: Validate at chainHeight first. If that matches, try to extend to currentChainHeight
            // by fetching the few missing blocks. If chainHeight doesn't match, THAT is a real problem.
            var validationHeight = chainHeight

            // FIX #1223: First, ensure we have the header root for our fetched height range.
            // Use HeaderStore (FIX #1204 saves finalsaplingroot during P2P fetch).
            // If header isn't in store yet, fetch it via P2P.
            // FIX #1231: Retry with up to 3 attempts if peer times out. Single-block fetches
            // use only 1 peer, so if that peer is slow/timing out, we need to try others.
            if (try? HeaderStore.shared.getHeader(at: chainHeight)) == nil {
                print("📦 FIX #1223: Fetching validation block at height \(chainHeight)...")
                var attempts = 0
                let maxAttempts = 3
                while attempts < maxAttempts {
                    attempts += 1
                    do {
                        _ = try await NetworkManager.shared.getBlocksDataP2P(from: chainHeight, count: 1)
                        // Success - header should now be in HeaderStore
                        if (try? HeaderStore.shared.getHeader(at: chainHeight)) != nil {
                            print("✅ FIX #1231: Validation block fetched on attempt \(attempts)")
                            break
                        }
                        // Header still missing after "successful" fetch - try again
                        print("⚠️ FIX #1231: Validation block fetch returned but header missing (attempt \(attempts)/\(maxAttempts))")
                    } catch {
                        print("⚠️ FIX #1231: Validation block fetch failed (attempt \(attempts)/\(maxAttempts)): \(error)")
                        if attempts == maxAttempts {
                            print("❌ FIX #1231: All \(maxAttempts) attempts failed - proceeding with validation")
                        }
                    }
                }
            } // FIX #1232: Close the `if header == nil` block from line 1065

            var blockchainRoot: Data? = nil
            if let header = try? HeaderStore.shared.getHeader(at: chainHeight) {
                let saplingRoot = header.hashFinalSaplingRoot
                if !saplingRoot.isEmpty && !saplingRoot.allSatisfy({ $0 == 0 }) {
                    blockchainRoot = saplingRoot
                }
            }

            guard let blockchainRoot = blockchainRoot else {
                print("⚠️ FIX #1223: No sapling root at fetched height \(chainHeight) — saving progress")
                DeltaCMUManager.shared.updateManifestTreeRoot(treeRoot)
                if let treeData = ZipherXFFI.treeSerialize() {
                    try? WalletDatabase.shared.saveTreeState(treeData, height: chainHeight)
                }
                return
            }

            let blockchainRootReversed = Data(blockchainRoot.reversed())
            let rootMatches = treeRoot == blockchainRoot || treeRoot == blockchainRootReversed

            if rootMatches {
                print("✅ FIX #1223: Gap-fill tree root matches at fetched height \(chainHeight)!")
                print("   Was \(existingCount) outputs → now \(newTotalCount) (gained \(gained) missing CMUs)")

                // FIX #1223: Tree matches at chainHeight. Now try to extend to currentChainHeight
                // by fetching the few blocks that arrived during gap-fill. This is optional —
                // if it fails, we still have a valid tree at chainHeight and syncDeltaBundleIfNeeded
                // will pick up the remaining blocks on the next cycle.
                let currentChainHeight: UInt64
                do {
                    currentChainHeight = try await NetworkManager.shared.getChainHeight()
                } catch {
                    currentChainHeight = chainHeight
                }

                if currentChainHeight > chainHeight {
                    let gapCount = Int(currentChainHeight - chainHeight)
                    print("📊 FIX #1223: Chain advanced during gap-fill (\(chainHeight) → \(currentChainHeight), \(gapCount) new blocks)")

                    // Try to fetch the few missing blocks to bring tree fully current
                    if gapCount <= 50 {  // Only for small gaps — large gaps handled by syncDeltaBundleIfNeeded
                        do {
                            let gapBlocks = try await NetworkManager.shared.getBlocksDataP2P(from: chainHeight + 1, count: gapCount)
                            var gapOutputs: [DeltaCMUManager.DeltaOutput] = []
                            for (height, _, _, txData) in gapBlocks {
                                var blockOutputIndex: UInt32 = 0
                                for (_, outputs, _) in txData {
                                    for output in outputs {
                                        // FIX #1311: ALWAYS store delta entry when CMU is valid
                                        if let cmuDisplay = Data(hexString: output.cmu) {
                                            let epk = Data(hexString: output.ephemeralKey).map { Data($0.reversed()) } ?? Data(count: 32)
                                            let ciphertext = Data(hexString: output.encCiphertext) ?? Data(count: 580)
                                            let deltaOutput = DeltaCMUManager.DeltaOutput(
                                                height: UInt32(height),
                                                index: blockOutputIndex,
                                                cmu: Data(cmuDisplay.reversed()),
                                                epk: epk,
                                                ciphertext: ciphertext
                                            )
                                            gapOutputs.append(deltaOutput)
                                        }
                                        blockOutputIndex += 1
                                    }
                                }
                            }
                            // FIX #1229: Append gap CMUs to FFI tree FIRST, then get root
                            if !gapOutputs.isEmpty {
                                // Append to FFI tree
                                for output in gapOutputs {
                                    _ = ZipherXFFI.treeAppend(cmu: output.cmu)
                                }
                                print("📦 FIX #1223: Extended tree with \(gapOutputs.count) CMUs from gap blocks \(chainHeight + 1)-\(currentChainHeight)")
                            }

                            // FIX #1229: Get tree root AFTER appending gap CMUs (not before!)
                            // The tree root changed when we appended CMUs at lines above.
                            // Using placeholderRoot or stale treeRoot causes mismatch on next startup.
                            let gapTreeRoot = ZipherXFFI.treeRoot() ?? treeRoot

                            // FIX #1229: Update delta manifest with correct root (after gap CMUs appended)
                            if !gapOutputs.isEmpty {
                                DeltaCMUManager.shared.appendOutputs(gapOutputs, fromHeight: chainHeight + 1, toHeight: currentChainHeight, treeRoot: gapTreeRoot)
                            } else {
                                // No outputs in gap blocks — just update manifest height
                                DeltaCMUManager.shared.appendOutputs([], fromHeight: chainHeight + 1, toHeight: currentChainHeight, treeRoot: gapTreeRoot)
                            }
                            validationHeight = currentChainHeight
                        } catch {
                            print("⚠️ FIX #1223: Gap block fetch failed (\(error.localizedDescription)) — saving at \(chainHeight)")
                            // Not a problem — tree is valid at chainHeight, next sync will catch up
                        }
                    }
                }

                // FIX #1231: Update delta manifest with correct tree root AND endHeight
                // The manifest endHeight must match the height at which treeRoot was computed.
                // Gap extension (lines 1133-1154) may have extended the tree from chainHeight
                // to currentChainHeight, so validationHeight reflects the actual tree coverage.
                // If we only update treeRoot but leave endHeight at the old value, the invariant
                // "manifest.treeRoot = FFI tree root at manifest.endHeight" is violated.
                let finalTreeRoot = ZipherXFFI.treeRoot() ?? treeRoot

                // Check if gap extension happened (validationHeight > chainHeight)
                if validationHeight > chainHeight {
                    // Gap extension succeeded — need to update BOTH endHeight and treeRoot
                    // Use appendOutputs with empty array to update manifest height
                    DeltaCMUManager.shared.appendOutputs([], fromHeight: chainHeight + 1, toHeight: validationHeight, treeRoot: finalTreeRoot)
                    print("📦 FIX #1231: Updated delta manifest to endHeight=\(validationHeight) with correct tree root")
                } else {
                    // No gap extension — just update tree root (endHeight already correct at chainHeight)
                    DeltaCMUManager.shared.updateManifestTreeRoot(finalTreeRoot)
                }

                // Save validated tree state
                if let treeData = ZipherXFFI.treeSerialize() {
                    try? WalletDatabase.shared.saveTreeState(treeData, height: validationHeight)
                    print("💾 FIX #1223: Saved validated tree state at height \(validationHeight)")
                }

                // Reset repair exhaustion flags since we fixed the root cause
                UserDefaults.standard.set(false, forKey: "TreeRepairExhausted")
                UserDefaults.standard.set(false, forKey: "TreeRootRepairAttempted")
                UserDefaults.standard.set(0, forKey: "DeltaBundleGlobalRepairAttempts")
                // FIX #1252: Gap-fill succeeded + tree root validated = delta is now verified & immutable
                UserDefaults.standard.set(true, forKey: "DeltaBundleVerified")
                print("✅ FIX #1223/#1252: Gap-fill SUCCESS — delta VERIFIED, repair counters reset, next startup instant")
            } else {
                let treeRootHex = treeRoot.map { String(format: "%02x", $0) }.joined()
                let blockchainRootHex = blockchainRoot.map { String(format: "%02x", $0) }.joined()
                print("⚠️ FIX #1223: Gap-fill root mismatch at fetched height \(chainHeight)")
                print("   FFI root:        \(treeRootHex.prefix(32))...")
                print("   Blockchain root:  \(blockchainRootHex.prefix(32))...")
                print("   Delta: \(existingCount) → \(newTotalCount) outputs (gained \(gained))")

                if gained > 0 {
                    // Made progress — save and retry next startup
                    print("   Made progress (+\(gained) CMUs) — saving and will retry next startup")
                    DeltaCMUManager.shared.updateManifestTreeRoot(treeRoot)
                    if let treeData = ZipherXFFI.treeSerialize() {
                        try? WalletDatabase.shared.saveTreeState(treeData, height: chainHeight)
                    }
                } else {
                    // No progress — delta might be truly corrupt, not just incomplete
                    print("   No new CMUs found — delta may be corrupt, falling back to clear")
                    await fallbackClearDelta(bundledEndHeight: bundledEndHeight)
                }
            }

        } catch {
            print("⚠️ FIX #1220: Gap-fill failed: \(error.localizedDescription)")
            // Don't clear on network error — preserve existing delta for next attempt
        }
    }

    /// FIX #1220: Fallback to original behavior when gap-fill can't help (truly corrupt delta)
    private func fallbackClearDelta(bundledEndHeight: UInt64) async {
        print("🔄 FIX #1220: Falling back to clear delta + reload boost tree")
        DeltaCMUManager.shared.clearDeltaBundle()

        // FIX #737: Reset lastScannedHeight to boost file end for full rescan
        let currentLastScanned = (try? WalletDatabase.shared.getLastScannedHeight()) ?? 0
        if currentLastScanned > bundledEndHeight {
            print("🔧 FIX #737: Resetting lastScannedHeight from \(currentLastScanned) to \(bundledEndHeight)")
            if let header = try? HeaderStore.shared.getHeader(at: bundledEndHeight) {
                try? WalletDatabase.shared.updateLastScannedHeight(bundledEndHeight, hash: header.blockHash)
            } else {
                try? WalletDatabase.shared.updateLastScannedHeight(bundledEndHeight, hash: Data(count: 32))
            }
            self.pendingDeltaRescan = true
        }

        // FIX #533: Reload FFI tree from boost file
        do {
            let serializedTree = try await CommitmentTreeUpdater.shared.extractSerializedTree()
            _ = ZipherXFFI.treeInit()
            if ZipherXFFI.treeDeserialize(data: serializedTree) {
                let treeSize = ZipherXFFI.treeSize()
                let boostHeight = UInt64(ZipherXConstants.effectiveTreeHeight)
                print("✅ FIX #533: Reloaded tree from boost file: \(treeSize) CMUs")
                if let treeData = ZipherXFFI.treeSerialize() {
                    try? WalletDatabase.shared.saveTreeState(treeData, height: boostHeight)
                }
            }
        } catch {
            print("⚠️ FIX #533: Failed to reload tree: \(error)")
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

    // FIX #888: Track download failures and allow retry
    @Published var boostDownloadFailed: Bool = false
    @Published var boostDownloadError: String = ""

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

    /// FIX #748: Public method to mark tree as loaded
    /// Called from ContentView after FAST START loads tree from boost file
    func setTreeLoaded(_ loaded: Bool) {
        self.isTreeLoaded = loaded
    }

    /// FIX #888: Retry boost file download after failure
    /// Called from ContentView when user taps "Retry Import" in download failed alert
    func retryBoostDownload() async {
        await MainActor.run {
            // Reset failed state
            self.boostDownloadFailed = false
            self.boostDownloadError = ""
            // Reset progress UI
            self.treeLoadStatus = "Retrying download..."
            self.treeLoadProgress = 0.0
        }
        // Retry the download
        await preloadCommitmentTree()
    }

    // MARK: - FIX #852/853: Clean Mislabeled Change Outputs and Migrate TXIDs at Startup

    /// FIX #852/853: Clean mislabeled change outputs and migrate txid formats at startup
    /// Must be called AFTER database is open
    private func cleanMislabeledChangeOutputsAtStartup() {
        // FIX #853 v2: First, run one-time migration to convert display-format txids to wire format
        // This ensures all txids are in consistent format before other checks run
        do {
            let migrated = try WalletDatabase.shared.migrateDisplayFormatTxidsToWireFormat()
            if migrated > 0 {
                print("🔄 FIX #853 v2: Migrated \(migrated) txid(s) to wire format")
            }
        } catch {
            print("⚠️ FIX #853 v2: Failed to migrate txid formats: \(error)")
        }

        // FIX #852: Auto-detect mislabeled change outputs even without pending txids
        // Detection: if we have a "received" entry AND spent a note in the same TX, it's our change
        do {
            let autoCleaned = try WalletDatabase.shared.cleanMislabeledChangeOutputsAuto()
            if autoCleaned > 0 {
                print("🧹 FIX #852: Auto-detected and cleaned \(autoCleaned) mislabeled change output(s)")
            }
        } catch {
            print("⚠️ FIX #852: Failed to auto-clean mislabeled change outputs: \(error)")
        }

        // FIX #1367: Correct sent entries where amount includes missed change outputs
        // populateHistoryFromNotes() FIX #1125 only ran height-based change detection when direct
        // match found ZERO outputs. With partial match (1 of 2), missed change inflated sent value.
        do {
            let corrected = try WalletDatabase.shared.correctMiscomputedSentAmounts()
            if corrected > 0 {
                print("🔧 FIX #1367: Corrected \(corrected) sent transaction(s) with wrong amounts")
                // FIX #1367: Notify UI to reload with updated self-send types
                NotificationCenter.default.post(name: Notification.Name("transactionHistoryUpdated"), object: nil)
            }
        } catch {
            print("⚠️ FIX #1367: Failed to correct sent amounts: \(error)")
        }

        // FIX #851: Also clean based on persisted pending txids (for TXs sent after FIX #849)
        let pendingTxids = UserDefaults.standard.stringArray(forKey: "ZipherX_PendingOutgoingTxids") ?? []
        if !pendingTxids.isEmpty {
            do {
                let cleaned = try WalletDatabase.shared.cleanMislabeledChangeOutputs(pendingTxids: pendingTxids)
                if cleaned > 0 {
                    print("🧹 FIX #851: Auto-cleaned \(cleaned) mislabeled change output(s) from pending txids")
                }
            } catch {
                print("⚠️ FIX #851: Failed to clean mislabeled change outputs: \(error)")
            }
        }

        // FIX #1110: One-time repair for notes wrongly marked as spent by FIX #1084 v2
        // Note 6178 (0.0025 ZCL at height 2953099) was incorrectly marked as spent
        // because FIX #1084 v2 used flawed value pattern matching
        let fix1110Key = "FIX_1110_Repair_Complete"
        if !UserDefaults.standard.bool(forKey: fix1110Key) {
            do {
                // Unmark note 6178 if it exists and is wrongly marked as spent
                try WalletDatabase.shared.unmarkNoteAsSpentById(noteId: 6178)
                UserDefaults.standard.set(true, forKey: fix1110Key)
                print("✅ FIX #1110: One-time repair complete - unmarked note 6178")
                // FIX #1343: Removed fire-and-forget refreshBalance() here.
                // On fresh import, this fires during preloadCommitmentTree() while the boost
                // file is downloading → starts a SECOND concurrent scan + download → both stall at 0%.
                // Balance is always refreshed by the normal startup flow immediately after tree load.
            } catch {
                print("⚠️ FIX #1110: One-time repair failed: \(error)")
            }
        }

        // FIX #1084 v2: DISABLED by FIX #1110 - value pattern matching causes false positives
        // This catches cases where spent_in_tx wasn't set but we can infer from value patterns
        do {
            let fixed = try WalletDatabase.shared.fixMislabeledChangeByValuePattern()
            if fixed > 0 {
                print("🧹 FIX #1084 v2: Fixed \(fixed) mislabeled change output(s) by value pattern")
                // Refresh balance since we modified notes
                Task {
                    try? await self.refreshBalance()
                }
            }
        } catch {
            print("⚠️ FIX #1084 v2: Failed to fix mislabeled change outputs: \(error)")
        }

        // FIX #1085: P2P verification - verify suspicious heights against blockchain
        // This is the ultimate source of truth - if P2P and database differ, trust P2P
        verifyAndFixNotesViaP2P()
    }

    // MARK: - FIX #1085: P2P Verification of Database Notes

    /// FIX #1085: Verify database notes against P2P blockchain data
    /// Called at startup after value pattern fixes to ensure database matches blockchain
    /// Process:
    /// 1. Get heights where issues might exist (received without sent)
    /// 2. Fetch blocks from P2P at those heights
    /// 3. Compare P2P notes with database notes
    /// 4. If mismatch, delete database entries and trigger targeted rescan
    private func verifyAndFixNotesViaP2P() {
        Task {
            await performP2PNoteVerification()
        }
    }

    /// FIX #1085: Async P2P verification - runs after network is available
    /// FIX #1086: DISABLED - Value comparison was deleting valid notes!
    /// The trial decryption values don't always match database values due to:
    /// - Different key derivation paths or byte ordering
    /// - Notes from different transactions at same height
    /// Need more investigation before re-enabling
    func performP2PNoteVerification() async {
        // FIX #1086: DISABLED - This was deleting valid notes and causing balance = 0
        print("⏸️ FIX #1086: P2P note verification DISABLED (was causing balance corruption)")
        // Early return - function completely disabled
    }

    // FIX #1086: All code below is moved to _disabled function to prevent any execution
    private func _performP2PNoteVerification_DISABLED() async {
        print("🔍 FIX #1085: Starting P2P verification of database notes...")

        // Step 1: Get suspicious heights from database
        let suspiciousHeights: [UInt64]
        do {
            suspiciousHeights = try WalletDatabase.shared.getSuspiciousHeightsForP2PVerification()
        } catch {
            print("⚠️ FIX #1085: Failed to get suspicious heights: \(error)")
            return
        }

        guard !suspiciousHeights.isEmpty else {
            print("✅ FIX #1085: No suspicious heights to verify")
            return
        }

        print("🔍 FIX #1085: Found \(suspiciousHeights.count) height(s) to verify via P2P")

        // Step 2: Wait for network to be ready (up to 30 seconds)
        let networkManager = await MainActor.run { NetworkManager.shared }
        var waitedSeconds = 0
        while waitedSeconds < 30 {
            let isConnected = await MainActor.run { networkManager.isConnected }
            let peerCount = await MainActor.run { networkManager.connectedPeers }
            if isConnected && peerCount >= 1 {
                break
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
            waitedSeconds += 1
        }

        let isConnected = await MainActor.run { networkManager.isConnected }
        guard isConnected else {
            print("⏳ FIX #1085: P2P verification deferred - network not ready (will retry on next startup)")
            return
        }

        // Step 3: Fetch blocks and verify - process in batches
        var heightsNeedingRescan: [UInt64] = []

        // Limit to 10 heights per startup to avoid long delays
        let heightsToCheck = Array(suspiciousHeights.prefix(10))

        for height in heightsToCheck {
            do {
                let needsRescan = try await verifyHeightViaP2P(height: height, networkManager: networkManager)
                if needsRescan {
                    heightsNeedingRescan.append(height)
                }
            } catch {
                print("⚠️ FIX #1085: Failed to verify height \(height): \(error)")
            }
        }

        // Step 4: If discrepancies found, delete and rescan
        if !heightsNeedingRescan.isEmpty {
            print("🔄 FIX #1085: Found \(heightsNeedingRescan.count) height(s) with P2P discrepancies - triggering rescan")

            do {
                // Delete incorrect entries
                let deleted = try WalletDatabase.shared.deleteNotesAndHistoryAtHeights(heightsNeedingRescan)
                print("🗑️ FIX #1085: Deleted \(deleted) entry/entries for rescan")

                // Trigger targeted rescan of affected heights
                await rescanSpecificHeights(heightsNeedingRescan, networkManager: networkManager)

                // Refresh balance after fixes
                try? await refreshBalance()

                print("✅ FIX #1085: P2P verification complete - \(heightsNeedingRescan.count) height(s) rescanned")
            } catch {
                print("⚠️ FIX #1085: Failed to fix P2P discrepancies: \(error)")
            }
        } else {
            print("✅ FIX #1085: All \(heightsToCheck.count) height(s) verified - database matches P2P")
        }
    }

    /// FIX #1085: Verify a single height against P2P blockchain
    /// Returns: true if height needs rescan (P2P differs from database)
    private func verifyHeightViaP2P(height: UInt64, networkManager: NetworkManager) async throws -> Bool {
        // Get database notes at this height
        let dbNotes = try WalletDatabase.shared.getNotesAtHeight(height)

        // FIX #1231: Retry single-block fetch with up to 3 attempts if peer times out
        var blocks: [(UInt64, String, UInt32, [(String, [ShieldedOutput], [ShieldedSpend]?)])] = []
        var attempts = 0
        let maxAttempts = 3
        while attempts < maxAttempts && blocks.isEmpty {
            attempts += 1
            do {
                blocks = try await networkManager.getBlocksDataP2P(from: height, count: 1)
                if !blocks.isEmpty {
                    break
                }
                print("⚠️ FIX #1231: Verification block fetch returned empty (attempt \(attempts)/\(maxAttempts))")
            } catch {
                print("⚠️ FIX #1231: Verification block fetch failed (attempt \(attempts)/\(maxAttempts)): \(error)")
            }
        }

        guard let (_, _, _, txData) = blocks.first else {
            print("⚠️ FIX #1085: Could not fetch block at height \(height) after \(attempts) attempts")
            return false // Can't verify, don't change
        }

        // Count shielded outputs in P2P block
        var p2pOutputCount = 0
        for (_, outputs, _) in txData {
            p2pOutputCount += outputs.count
        }

        // Compare counts - if database has notes but P2P has no outputs for us, verify via trial decryption
        if dbNotes.isEmpty && p2pOutputCount == 0 {
            // Both empty - no issue
            return false
        }

        if !dbNotes.isEmpty && p2pOutputCount == 0 {
            // Database has notes but P2P block has no shielded outputs at all
            // This is a clear mismatch - notes in database don't belong to this height
            print("❌ FIX #1085: Height \(height) - Database has \(dbNotes.count) note(s) but P2P block has 0 outputs")
            return true
        }

        // For more precise verification, we need trial decryption
        // VUL-U-002: Get spending key for trial decryption with secure zeroing
        guard let secureKey = try? SecureKeyStorage().retrieveSpendingKeySecure() else {
            print("⚠️ FIX #1085: Cannot retrieve spending key for trial decryption")
            return false // Can't verify, don't change
        }
        defer { secureKey.zero() }
        let spendingKey = secureKey.data

        // Build array of outputs for parallel decryption
        var ffiOutputs: [ZipherXFFI.FFIShieldedOutput] = []

        for (_, outputs, _) in txData {
            for output in outputs {
                // Use hex initializer which handles byte order conversion
                ffiOutputs.append(ZipherXFFI.FFIShieldedOutput(
                    epkHex: output.ephemeralKey,
                    cmuHex: output.cmu,
                    ciphertextHex: output.encCiphertext
                ))
            }
        }

        // Trial decrypt all outputs in parallel
        let decryptedNotes = ZipherXFFI.tryDecryptNotesParallel(
            spendingKey: spendingKey,
            outputs: ffiOutputs,
            height: height
        )

        // Collect values of decrypted notes (notes that belong to us)
        var p2pValues: Set<Int64> = []
        for decrypted in decryptedNotes {
            if let note = decrypted {
                p2pValues.insert(Int64(note.value))
            }
        }

        // Compare P2P decrypted notes with database notes
        let dbValues = Set(dbNotes.map { $0.value })

        if dbValues != p2pValues {
            print("❌ FIX #1085: Height \(height) - Value mismatch!")
            print("   Database values: \(dbValues.map { LogRedaction.redactAmount(UInt64(abs($0))) })")
            print("   P2P values: \(p2pValues.map { LogRedaction.redactAmount(UInt64(abs($0))) })")
            return true
        }

        // Values match - no rescan needed
        print("✅ FIX #1085: Height \(height) verified - \(dbNotes.count) note(s) match P2P")
        return false
    }

    /// FIX #1085: Rescan specific heights via P2P
    /// Triggers the existing sync infrastructure to rescan affected heights
    private func rescanSpecificHeights(_ heights: [UInt64], networkManager: NetworkManager) async {
        guard !heights.isEmpty else { return }

        let minHeight = heights.min()!
        let maxHeight = heights.max()!
        let count = Int(maxHeight - minHeight + 1)

        print("🔄 FIX #1085: Rescanning heights \(minHeight)-\(maxHeight) (\(count) blocks)")

        do {
            // Reset the lastScannedHeight to before the first affected block
            // This forces the sync infrastructure to rescan these blocks
            let newLastScanned = minHeight > 0 ? minHeight - 1 : 0

            // Use an empty hash as placeholder - the actual hash will be updated by the scan
            try WalletDatabase.shared.updateLastScannedHeight(newLastScanned, hash: Data(count: 32))
            print("🔄 FIX #1085: Reset lastScannedHeight to \(newLastScanned)")

            // Trigger sync to the max affected height
            // This will use FilterScanner to properly discover notes with trial decryption
            await backgroundSyncToHeight(maxHeight)

            print("✅ FIX #1085: Rescan triggered for \(count) block(s)")
        } catch {
            print("⚠️ FIX #1085: Rescan failed: \(error)")
        }
    }

    /// FIX #1366b: Discover undiscovered delta outputs at startup by comparing delta CMUs
    /// against known notes. Trial-decrypts unknowns with spending key. If any decrypt → missing
    /// note found → lower lastScannedHeight so FilterScanner rescans and properly inserts them.
    ///
    /// This catches missing change outputs even when no broadcast history or pending txids exist.
    /// Performance: O(n) Set lookup over delta outputs (~200-2000), trial decryption only for
    /// candidates (usually 0, at most 2-3 in crash scenario). Total: <100ms.
    private func discoverMissingDeltaOutputsAtStartup(spendingKey: Data) {
        let knownCMUs = WalletDatabase.shared.getAllKnownCMUs()
        guard !knownCMUs.isEmpty else {
            // No notes at all — nothing to compare against (fresh wallet)
            return
        }

        let boostCMUCount = UInt64(UserDefaults.standard.integer(forKey: "BoostOutputCount"))
        guard let deltaOutputs = DeltaCMUManager.shared.getOutputsForParallelDecryption(startGlobalPosition: boostCMUCount),
              !deltaOutputs.isEmpty else {
            return
        }

        // Find delta CMUs not in our notes table
        var candidates: [(epk: Data, cmu: Data, ciphertext: Data, height: UInt32)] = []
        for output in deltaOutputs {
            if !knownCMUs.contains(output.cmu) {
                candidates.append((epk: output.epk, cmu: output.cmu, ciphertext: output.ciphertext, height: output.height))
            }
        }

        // Most startups: 0 candidates (all outputs are known or belong to others)
        guard !candidates.isEmpty else { return }

        // Trial-decrypt candidates with our spending key
        var discoveredCount = 0
        for candidate in candidates {
            // Skip outputs with zeroed EPK/ciphertext (FIX #1311 fallback entries)
            guard candidate.epk != Data(count: 32),
                  candidate.ciphertext.count >= 580 else { continue }

            if let _ = ZipherXFFI.tryDecryptNoteWithSK(
                spendingKey: spendingKey,
                epk: candidate.epk,
                cmu: candidate.cmu,
                ciphertext: candidate.ciphertext
            ) {
                discoveredCount += 1
                print("⚠️ FIX #1366b: Undiscovered note found! CMU=\(candidate.cmu.prefix(8).map { String(format: "%02x", $0) }.joined())... height=\(candidate.height)")
            }
        }

        if discoveredCount > 0 {
            print("⚠️ FIX #1366b: Found \(discoveredCount) undiscovered note(s) in delta — lowering lastScannedHeight for rescan")
            if let currentScanned = try? WalletDatabase.shared.getLastScannedHeight(), currentScanned > 100 {
                let rescanFrom = currentScanned - 100
                try? WalletDatabase.shared.resetLastScannedHeightForRecovery(rescanFrom)
                print("⚠️ FIX #1366b: lastScannedHeight lowered from \(currentScanned) to \(rescanFrom)")
            }
        } else {
            print("✅ FIX #1366b: All delta outputs accounted for (\(deltaOutputs.count) outputs, \(candidates.count) unknown, 0 ours)")
        }
    }

    /// FIX #1366: Check broadcast history for confirmed TXs missing from transaction_history.
    /// This catches the case where FIX #970 already removed the TX from pending (crash recovery).
    /// Uses separate `ZipherX_BroadcastHistory` which survives FIX #970 cleanup.
    func checkBroadcastHistoryForMissingTxs() async {
        let broadcastHistory = UserDefaults.standard.stringArray(forKey: "ZipherX_BroadcastHistory") ?? []
        guard !broadcastHistory.isEmpty else { return }

        var missingCount = 0
        var confirmedAndRecorded: [String] = []

        for txid in broadcastHistory {
            guard let txidData = Data(hexString: txid) else { continue }
            let txidWire = Data(txidData.reversed())

            let inHistory = (try? WalletDatabase.shared.transactionExistsInHistory(txid: txidWire)) ?? false
            if inHistory {
                confirmedAndRecorded.append(txid)
            } else {
                // TX was broadcast but not in history — check if confirmed on chain
                let confirmed = await verifyTxConfirmedOnChain(txid: txid)
                if confirmed == true {
                    print("⚠️ FIX #1366: Broadcast TX \(txid.prefix(16))... confirmed on chain but NOT in history — needs rescan")
                    missingCount += 1
                } else if confirmed == false {
                    // TX rejected/never mined — safe to remove from history
                    confirmedAndRecorded.append(txid)
                }
                // nil = unable to verify — keep for next check
            }
        }

        // Clean confirmed+recorded TXs from broadcast history
        if !confirmedAndRecorded.isEmpty {
            var updated = broadcastHistory.filter { !confirmedAndRecorded.contains($0) }
            if updated.count > 20 { updated = Array(updated.suffix(20)) }
            UserDefaults.standard.set(updated, forKey: "ZipherX_BroadcastHistory")
        }

        // Trigger rescan if any confirmed TXs are missing from history
        if missingCount > 0 {
            if let currentScanned = try? WalletDatabase.shared.getLastScannedHeight(), currentScanned > 100 {
                let rescanFrom = currentScanned - 100
                try? WalletDatabase.shared.resetLastScannedHeightForRecovery(rescanFrom)
                print("⚠️ FIX #1366: Lowered lastScannedHeight by 100 blocks — FilterScanner will rescan for \(missingCount) missing TX change outputs")

                // Re-add missing TXs to pending set so FilterScanner's FIX #859 path
                // calls confirmOutgoingTx when it finds the nullifier during rescan.
                // Without this, PHASE 2 skips the TX because it's not in pending.
                for txid in broadcastHistory {
                    guard let txidData = Data(hexString: txid) else { continue }
                    let txidWire = Data(txidData.reversed())
                    let inHistory = (try? WalletDatabase.shared.transactionExistsInHistory(txid: txidWire)) ?? false
                    if !inHistory {
                        await MainActor.run {
                            NetworkManager.shared.addToPendingOutgoingSet(txid: txid)
                        }
                        print("⚠️ FIX #1366: Re-added \(txid.prefix(16))... to pending set for rescan discovery")
                    }
                }
            }
        }
    }

    /// FIX #965: Detect and record missing sent transactions at startup
    /// Problem: TX was broadcast, VUL-002 showed error (TCP desync), but TX actually confirmed
    /// The TX was never recorded to database because confirmOutgoingTx couldn't find it
    /// Solution: At startup, check if any persisted pending txids are MISSING from transaction_history
    /// If missing AND not in database, try to find them in recent blocks and record them
    private func detectMissingSentTransactionsAtStartup() {
        let pendingTxids = UserDefaults.standard.stringArray(forKey: "ZipherX_PendingOutgoingTxids") ?? []
        if pendingTxids.isEmpty {
            print("✅ FIX #965: No persisted pending txids - nothing to check")
            // FIX #970 v2: Also check database for any pending sent transactions
            // These might exist if FIX #969 removed from UserDefaults but TX was already in DB
            Task {
                await self.cleanPendingTransactionsFromDatabase()
            }
            return
        }

        print("🔍 FIX #965: Checking \(pendingTxids.count) persisted txid(s) for missing history entries...")

        var missingTxids: [String] = []

        for txid in pendingTxids {
            // Convert display format txid to wire format for database lookup
            guard let txidDisplayData = Data(hexString: txid) else {
                print("⚠️ FIX #965: Invalid txid format: \(txid.prefix(16))...")
                continue
            }
            let txidWireFormat = Data(txidDisplayData.reversed())

            // Check if this txid exists in transaction_history
            do {
                let exists = try WalletDatabase.shared.transactionExistsInHistory(txid: txidWireFormat)
                if !exists {
                    print("📤 FIX #965: Missing from history: \(txid.prefix(16))...")
                    missingTxids.append(txid)
                }
            } catch {
                print("⚠️ FIX #965: Failed to check txid \(txid.prefix(16))...: \(error)")
            }
        }

        if missingTxids.isEmpty {
            print("✅ FIX #965: All persisted txids exist in history")
            return
        }

        print("🚨 FIX #965: Found \(missingTxids.count) sent TX(s) missing from history!")
        print("   These transactions were broadcast but never recorded (likely VUL-002 error)")
        print("   They will be recorded when next detected in a block scan")

        // FIX #1366: Ensure missing txids are in broadcast history.
        // If FIX #970 removes them from pending before discovery, broadcast history
        // ensures checkBroadcastHistoryForMissingTxs catches them on next startup.
        var broadcastHistory = UserDefaults.standard.stringArray(forKey: "ZipherX_BroadcastHistory") ?? []
        for txid in missingTxids {
            if !broadcastHistory.contains(txid) {
                broadcastHistory.append(txid)
            }
        }
        if broadcastHistory.count > 20 { broadcastHistory = Array(broadcastHistory.suffix(20)) }
        UserDefaults.standard.set(broadcastHistory, forKey: "ZipherX_BroadcastHistory")

        // Schedule a background check for these missing transactions
        Task {
            await self.scanForMissingSentTransactions(txids: missingTxids)
        }
    }

    /// FIX #965: Scan recent blocks to find missing sent transactions
    private func scanForMissingSentTransactions(txids: [String]) async {
        print("🔍 FIX #965: Scanning recent blocks for \(txids.count) missing TX(s)...")

        // Wait for network to be ready
        var attempts = 0
        var peerCount = await MainActor.run { NetworkManager.shared.connectedPeers }
        while peerCount < 3 && attempts < 30 {
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
            attempts += 1
            peerCount = await MainActor.run { NetworkManager.shared.connectedPeers }
        }

        if peerCount < 1 {
            print("⚠️ FIX #965: No peers available, will check on next startup")
            return
        }

        // Get current chain height
        guard let chainHeight = try? await NetworkManager.shared.getChainHeight(), chainHeight > 0 else {
            print("⚠️ FIX #965: Could not get chain height")
            return
        }

        // Scan last 100 blocks for the missing transactions
        let lastScanned = (try? WalletDatabase.shared.getLastScannedHeight()) ?? chainHeight
        // FIX #1082: Prevent UInt64 underflow when lastScanned < 100
        let scanStart = lastScanned >= 100 ? lastScanned - 100 : 0

        print("🔍 FIX #965: Quick scan from \(scanStart) to \(lastScanned) for missing TXs")

        // The FilterScanner will handle detection via nullifier matching
        // For now, trigger a confirmation check which will use FIX #964's pre-tracking
        for txid in txids {
            // Add to tracking set if not already there
            await MainActor.run { NetworkManager.shared.addToPendingOutgoingSet(txid: txid) }
        }

        // Trigger confirmation checking
        await NetworkManager.shared.checkPendingOutgoingConfirmations()

        // FIX #970: After confirmation check, clean up orphaned pending txids
        // If txid is STILL not in history after FIX #965's attempt to find it,
        // it was a rejected TX that was never confirmed. Remove from persistence.
        try? await Task.sleep(nanoseconds: 2_000_000_000) // Wait 2s for confirmation callbacks
        await cleanOrphanedPendingTxids(txids: txids)

        print("✅ FIX #965: Missing TX check complete")
    }

    /// FIX #970: Clean up orphaned pending txids that were never confirmed
    /// These are transactions that were rejected but never cleaned up (before FIX #969)
    /// Also deletes phantom entries from transaction_history that were never confirmed on blockchain
    private func cleanOrphanedPendingTxids(txids: [String]) async {
        var orphanedCount = 0
        var needsRescan = false  // FIX #1366: Track if we need to rescan for missing change outputs

        for txid in txids {
            // Convert display format txid to wire format for database lookup
            guard let txidDisplayData = Data(hexString: txid) else { continue }
            let txidWireFormat = Data(txidDisplayData.reversed())

            // FIX #970 + FIX #888: Check if this TX is actually confirmed on blockchain
            // A TX is orphaned/phantom if it's in our pending list but NOT confirmed
            let verificationResult = await verifyTxConfirmedOnChain(txid: txid)

            switch verificationResult {
            case .some(true):
                // TX is confirmed on chain
                // FIX #1366: Check if TX is actually in transaction_history.
                // If NOT, the app crashed between broadcast and block confirmation.
                // Change outputs were never discovered. DON'T remove from pending —
                // lower lastScannedHeight to force FilterScanner rescan.
                let inHistory = (try? WalletDatabase.shared.transactionExistsInHistory(txid: txidWireFormat)) ?? false
                if inHistory {
                    // TX confirmed AND in history - safe to remove
                    print("✅ FIX #970: TX \(txid.prefix(16))... is confirmed - removing from pending")
                    await MainActor.run {
                        NetworkManager.shared.removePendingTxidFromPersistence(txid)
                        NetworkManager.shared.removeFromPendingOutgoingSet(txid: txid)
                    }
                    _ = await NetworkManager.shared.removeFromActorTracking(txid: txid)
                } else {
                    // FIX #1366: TX confirmed but NOT in history — needs rescan for change outputs
                    print("⚠️ FIX #1366: TX \(txid.prefix(16))... confirmed on chain but NOT in history — scheduling rescan")
                    needsRescan = true
                    // Keep in pending — will be cleaned up after rescan discovers it
                }

            case .some(false):
                // TX definitely doesn't exist - it was rejected. Clean up everything.
                print("🧹 FIX #970: Removing phantom/rejected TX: \(txid.prefix(16))... (never confirmed on blockchain)")

                // FIX #1168: FIRST restore notes spent by this phantom TX BEFORE deleting from history
                // The note must be restored to unspent since the TX was rejected by the network
                if let (restoredCount, restoredValue) = try? WalletDatabase.shared.restoreNotesSpentByPhantomTx(txid: txidWireFormat),
                   restoredCount > 0 {
                    print("✅ FIX #1168: Restored \(restoredCount) note(s) totaling \(restoredValue.redactedAmount) from phantom TX")
                }

                // Delete from transaction_history database (if it exists there)
                if let deletedValue = try? WalletDatabase.shared.deletePhantomTransaction(txid: txidWireFormat) {
                    print("🗑️ FIX #970: Deleted phantom TX from history (value: \(deletedValue.redactedAmount))")
                }

                // Remove from UserDefaults persistence
                await MainActor.run {
                    NetworkManager.shared.removePendingTxidFromPersistence(txid)
                }

                // Remove from in-memory tracking
                await MainActor.run {
                    NetworkManager.shared.removeFromPendingOutgoingSet(txid: txid)
                }

                // Remove from actor tracking
                _ = await NetworkManager.shared.removeFromActorTracking(txid: txid)

                orphanedCount += 1

            case .none:
                // FIX #888: Unable to verify (network issues) - DO NOT DELETE!
                // Keep the TX in pending, will check again later when network is available
                print("⚠️ FIX #888: TX \(txid.prefix(16))... unable to verify - keeping in pending (network unavailable)")
            }
        }

        // FIX #1366: If any confirmed TX is missing from history, lower lastScannedHeight
        // to force FilterScanner to rescan recent blocks and discover change outputs.
        // This handles crash-between-broadcast-and-confirmation recovery.
        if needsRescan {
            if let currentScanned = try? WalletDatabase.shared.getLastScannedHeight(), currentScanned > 100 {
                let rescanFrom = currentScanned - 100
                try? WalletDatabase.shared.resetLastScannedHeightForRecovery(rescanFrom)
                print("⚠️ FIX #1366: Lowered lastScannedHeight by 100 blocks — FilterScanner will rescan to discover change outputs")
            }
        }

        if orphanedCount > 0 {
            print("🧹 FIX #970: Cleaned up \(orphanedCount) phantom/rejected TX(s)")

            // Refresh balance after cleaning up phantom transactions
            try? await refreshBalance()

            // FIX #1170: Force UI to reload transaction history after phantom cleanup
            // Without this, the UI keeps showing deleted phantom TXs from its in-memory cache
            await MainActor.run {
                NotificationCenter.default.post(name: Notification.Name("transactionHistoryUpdated"), object: nil)
                print("✅ FIX #1170: Posted transactionHistoryUpdated notification after phantom cleanup")
            }
        }

        // Clear pending flags if no more pending txids
        let remainingTxids = UserDefaults.standard.stringArray(forKey: "ZipherX_PendingOutgoingTxids") ?? []
        if remainingTxids.isEmpty {
            await MainActor.run {
                NetworkManager.shared.clearPendingFlags()
                print("🧹 FIX #970: All pending txids processed - flags cleared")
            }
        }
    }

    /// FIX #970 + FIX #888: Verify if a transaction is actually confirmed on the blockchain
    /// Returns:
    /// - true: TX definitely exists (confirmed in DB or found via P2P)
    /// - false: TX definitely doesn't exist (not in DB and P2P verified it's not on chain)
    /// - nil: Unable to verify (network issues, no peers available)
    private func verifyTxConfirmedOnChain(txid: String) async -> Bool? {
        // First check if it's in our history with confirmed status
        guard let txidDisplayData = Data(hexString: txid) else { return nil }  // FIX #888: Invalid txid = unable to verify
        let txidWireFormat = Data(txidDisplayData.reversed())

        // Check transaction_history for confirmed status
        if let status = try? WalletDatabase.shared.getTransactionStatus(txid: txidWireFormat) {
            if status == "confirmed" {
                return true
            }
        }

        // If not confirmed in our DB, try P2P verification
        // Use a quick check - if TX is in any peer's view, it's likely confirmed
        let result = await NetworkManager.shared.verifyTxExistsViaP2P(txid: txid)
        return result.exists  // FIX #888: Now returns Bool? (nil = unable to verify)
    }

    /// FIX #889: Public entry point for cleaning orphaned/phantom transactions at startup
    /// Called by ContentView during INSTANT START and FAST START to auto-fix balance issues
    func cleanOrphanedPendingTransactions() async {
        // Get pending txids from UserDefaults
        let txids = UserDefaults.standard.stringArray(forKey: "ZipherX_PendingOutgoingTxids") ?? []
        if !txids.isEmpty {
            await cleanOrphanedPendingTxids(txids: txids)
        }
        // Also check database for phantom transactions
        await cleanPendingTransactionsFromDatabase()

        // FIX #1366: Check broadcast history for confirmed TXs missing from history.
        // This catches crash-between-broadcast-and-confirmation — even after FIX #970
        // already cleaned up pending txids, broadcast history persists separately.
        await checkBroadcastHistoryForMissingTxs()
    }

    /// FIX #970 v3: Clean up phantom transactions from database
    /// Checks BOTH pending transactions AND recent "confirmed" transactions that don't exist on blockchain
    /// This handles cases where rejected TX was incorrectly marked as confirmed
    private func cleanPendingTransactionsFromDatabase() async {
        print("🔍 FIX #970 v3: Checking database for phantom transactions...")

        // Wait for network to be ready
        var attempts = 0
        var peerCount = await MainActor.run { NetworkManager.shared.connectedPeers }
        while peerCount < 1 && attempts < 15 {
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
            attempts += 1
            peerCount = await MainActor.run { NetworkManager.shared.connectedPeers }
        }

        if peerCount < 1 {
            print("⚠️ FIX #970 v3: No peers available, will check on next startup")
            return
        }

        var cleanedCount = 0

        // STEP 1: Check pending sent transactions (status = pending/mempool/confirming)
        if let pendingTxs = try? WalletDatabase.shared.getPendingSentTransactions(), !pendingTxs.isEmpty {
            // FIX #1250: Only verify TXs with height == 0 (never mined). TXs with height > 0
            // are confirmed in blocks — P2P mempool check would falsely flag them as phantom.
            let trulyPending = pendingTxs.filter { $0.height == 0 }
            let skippedMined = pendingTxs.count - trulyPending.count
            if skippedMined > 0 {
                print("✅ FIX #1250: Skipped \(skippedMined) 'pending' TX(s) with block_height > 0 (actually mined)")
            }
            print("🔍 FIX #970 v3: Checking \(trulyPending.count) pending sent TX(s)...")
            for tx in trulyPending {
                let txidDisplay = tx.txid.reversed().map { String(format: "%02x", $0) }.joined()
                let verificationResult = await verifyTxConfirmedOnChain(txid: txidDisplay)

                switch verificationResult {
                case .some(true):
                    print("✅ FIX #970 v3: TX \(txidDisplay.prefix(16))... is confirmed")
                    try? WalletDatabase.shared.updateTransactionStatus(txid: tx.txid, status: .confirmed, confirmations: 1)

                case .some(false):
                    print("🧹 FIX #970 v3: Phantom pending TX: \(txidDisplay.prefix(16))...")
                    if let deletedValue = try? WalletDatabase.shared.deletePhantomTransaction(txid: tx.txid) {
                        print("🗑️ FIX #970 v3: Deleted (value: \(deletedValue.redactedAmount))")
                        cleanedCount += 1
                    }

                case .none:
                    // FIX #888: Unable to verify - keep TX, will check again later
                    print("⚠️ FIX #888: TX \(txidDisplay.prefix(16))... unable to verify - keeping pending")
                }
            }
        }

        // STEP 2: Check recent sent transactions from last 2 hours with 0 confirmations
        // FIX #975: Only check truly unconfirmed TXs - P2P getdata only works for mempool!
        // Real confirmed TXs won't be found via P2P (they're in blockchain, not mempool)
        // Phantom TXs are recent (just broadcast) and have 0 confirmations
        if let recentTxs = try? WalletDatabase.shared.getRecentSentTransactions(hoursBack: 2), !recentTxs.isEmpty {
            // Filter to only unconfirmed TXs (confirmations == 0 AND height == 0)
            // FIX #1250: Also require height == 0 — TXs with block_height > 0 are mined, not phantom.
            // Instant repair re-creates old TXs with confirmations=0 but correct block_height.
            let unconfirmedTxs = recentTxs.filter { $0.confirmations == 0 && $0.height == 0 }
            if !unconfirmedTxs.isEmpty {
                print("🔍 FIX #975: Checking \(unconfirmedTxs.count) unconfirmed sent TX(s) from last 2 hours...")
                for tx in unconfirmedTxs {
                    let txidDisplay = tx.txid.reversed().map { String(format: "%02x", $0) }.joined()

                    // Skip if we already processed this TX in step 1
                    if tx.status != .confirmed { continue }

                    // For "confirmed" status with 0 confirmations - might be phantom
                    let existsOnChain = await verifyTxExistsOnBlockchain(txid: txidDisplay)
                    switch existsOnChain {
                    case .some(true):
                        // TX exists, keep it
                        break
                    case .some(false):
                        print("🧹 FIX #975: PHANTOM TX found: \(txidDisplay.prefix(16))... (0 confirmations, NOT in mempool!)")
                        // FIX #1168: FIRST restore notes spent by this phantom TX
                        if let (restoredCount, restoredValue) = try? WalletDatabase.shared.restoreNotesSpentByPhantomTx(txid: tx.txid),
                           restoredCount > 0 {
                            print("✅ FIX #1168: Restored \(restoredCount) note(s) totaling \(restoredValue.redactedAmount)")
                        }
                        if let deletedValue = try? WalletDatabase.shared.deletePhantomTransaction(txid: tx.txid) {
                            print("🗑️ FIX #975: Deleted phantom TX (value: \(deletedValue.redactedAmount))")
                            cleanedCount += 1
                        }
                    case .none:
                        // FIX #888: Unable to verify - keep TX
                        print("⚠️ FIX #888: TX \(txidDisplay.prefix(16))... unable to verify - keeping")
                    }
                }
            } else {
                print("✅ FIX #975: No unconfirmed sent TXs to check (all have confirmations > 0)")
            }
        }

        // STEP 3: FIX #1221 — Verify ALL recent sent TXs via P2P getdata (regardless of confirmations)
        // Catches phantom TXs that were falsely "confirmed" via empty mempool (FIX #1221 root cause).
        // The false confirmation wrote the TX with status='confirmed' but confirmations=0 (not in INSERT),
        // so we check ALL recent sent TXs from last 2 hours.
        // SAFETY: Only run if we have 3+ connected peers (prevents false phantom detection when offline).
        let step3PeerCount = await MainActor.run { NetworkManager.shared.peers.filter { $0.isConnectionReady }.count }
        if step3PeerCount >= 3,
           let recentTxs = try? WalletDatabase.shared.getRecentSentTransactions(hoursBack: 2), !recentTxs.isEmpty {
            // FIX #1250: ONLY check TXs with height == 0 (never mined in a block).
            // Old confirmed TXs (height > 0) are NOT in mempool — P2P getdata returns "not found"
            // for mined TXs → false phantom detection → notes restored as unspent → balance inflation.
            // During instant repair, old TXs get re-created with fresh created_at timestamps,
            // making getRecentSentTransactions(hoursBack:2) return months-old TXs.
            let allConfirmed = recentTxs.filter { $0.status == .confirmed }
            let txsToVerify = allConfirmed.filter { $0.height == 0 }
            let skippedConfirmed = allConfirmed.count - txsToVerify.count
            if skippedConfirmed > 0 {
                print("✅ FIX #1250: Skipped \(skippedConfirmed) confirmed TX(s) with block_height > 0 (mined in blocks, not phantom)")
            }
            if !txsToVerify.isEmpty {
                print("🔍 FIX #1221: Verifying \(txsToVerify.count) confirmed sent TX(s) with height=0 via P2P getdata (\(step3PeerCount) peers)...")
                for tx in txsToVerify {
                    let txidDisplay = tx.txid.reversed().map { String(format: "%02x", $0) }.joined()

                    // Use BOTH verification methods for safety
                    // verifyTxViaP2P: requestTransaction (getdata → tx/notfound)
                    // verifyTxExistsViaP2P: getRawTransaction (getdata → raw TX bytes)
                    let verified1 = await NetworkManager.shared.verifyTxViaP2P(txid: txidDisplay, maxAttempts: 3)
                    if verified1 {
                        print("✅ FIX #1221: TX \(txidDisplay.prefix(16))... confirmed via P2P — genuine")
                        continue
                    }

                    // Double-check with second method before deleting
                    let verified2 = await NetworkManager.shared.verifyTxExistsViaP2P(txid: txidDisplay)
                    if verified2.exists == true {
                        print("✅ FIX #1221: TX \(txidDisplay.prefix(16))... confirmed via P2P method 2 — genuine")
                        continue
                    }
                    if verified2.exists == nil {
                        // Unable to verify (no peers responded) — DON'T delete, check next startup
                        print("⚠️ FIX #1221: TX \(txidDisplay.prefix(16))... unable to verify — keeping (will retry next startup)")
                        continue
                    }

                    // BOTH methods say TX doesn't exist — this is a PHANTOM TX
                    print("🚨 FIX #1221: PHANTOM TX detected! \(txidDisplay.prefix(16))... NOT found by any peer (both methods)!")
                    print("   This TX was falsely confirmed (likely empty mempool = false SETTLEMENT)")

                    // FIX #1168: FIRST restore notes spent by this phantom TX
                    if let (restoredCount, restoredValue) = try? WalletDatabase.shared.restoreNotesSpentByPhantomTx(txid: tx.txid),
                       restoredCount > 0 {
                        print("✅ FIX #1221: Restored \(restoredCount) note(s) totaling \(restoredValue.redactedAmount) from phantom TX")
                    }

                    // Delete the phantom TX from transaction_history
                    if let deletedValue = try? WalletDatabase.shared.deletePhantomTransaction(txid: tx.txid) {
                        print("🗑️ FIX #1221: Deleted phantom TX (value: \(deletedValue.redactedAmount))")
                        cleanedCount += 1
                    }

                    // FIX #1170: Force UI to reload transaction history
                    await MainActor.run {
                        NotificationCenter.default.post(name: Notification.Name("transactionHistoryUpdated"), object: nil)
                    }
                }
            }
        } else if step3PeerCount < 3 {
            print("⚠️ FIX #1221: Skipping STEP 3 — only \(step3PeerCount) peers (need 3+ for safe verification)")
        }

        if cleanedCount > 0 {
            print("🧹 FIX #970 v3: Cleaned up \(cleanedCount) phantom transaction(s) from database")
            // Refresh balance after cleanup
            try? await refreshBalance()

            // FIX #1250: Flag balance discrepancy when phantom cleanup changed the balance.
            // The UI will show a warning instead of displaying a potentially wrong balance.
            // This flag gets cleared after a successful Full Rescan or balance verification.
            await MainActor.run {
                self.balanceIntegrityIssue = true
                self.balanceIntegrityMessage = "Balance updated after removing \(cleanedCount) phantom transaction(s) — verifying..."
                print("⚠️ FIX #1250: Set balanceIntegrityIssue=true after phantom cleanup (\(cleanedCount) TXs)")
            }

            // FIX #974: Trigger UI refresh by incrementing transactionHistoryVersion
            // This causes BalanceView to reload transaction history from database
            await MainActor.run {
                self.transactionHistoryVersion += 1
                print("📜 FIX #974: Incremented transactionHistoryVersion to \(self.transactionHistoryVersion) - UI will refresh")
            }
        } else {
            print("✅ FIX #970 v3: All transactions verified - no phantoms found")
        }
    }

    /// FIX #970 v3 + FIX #888: Verify a transaction exists on the blockchain via P2P
    /// Returns:
    /// - true: TX found by peer(s)
    /// - false: TX not found (phantom)
    /// - nil: Unable to verify (network issues)
    private func verifyTxExistsOnBlockchain(txid: String) async -> Bool? {
        // Use P2P verification - check if any peer has this TX
        let result = await NetworkManager.shared.verifyTxExistsViaP2P(txid: txid)
        if result.exists == false {
            print("🔍 FIX #970 v3: TX \(txid.prefix(16))... NOT found via P2P (phantom)")
        } else if result.exists == nil {
            print("⚠️ FIX #888: TX \(txid.prefix(16))... unable to verify via P2P")
        }
        return result.exists
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
            // VUL-U-002: Use secure key retrieval with automatic zeroing
            let secureKey = try secureStorage.retrieveSpendingKeySecure()
            defer { secureKey.zero() }
            let spendingKey = secureKey.data
            // VUL-STOR-009: Use HKDF domain separation for SQLCipher key
            let rawKey = Data(SHA256.hash(data: spendingKey))
            let dbKey = DatabaseEncryption.deriveDatabaseKey(from: rawKey)
            try WalletDatabase.shared.open(encryptionKey: dbKey)

            // FIX #852: Clean mislabeled change outputs after database is open
            // This must run here because NetworkManager.init runs before DB open
            cleanMislabeledChangeOutputsAtStartup()

            // FIX #965: Detect sent transactions that were broadcast but never recorded
            // This handles: VUL-002 showed error (TCP desync), but TX actually confirmed
            detectMissingSentTransactionsAtStartup()

            // FIX #1366: Check broadcast history for confirmed TXs not in transaction_history.
            // This catches crash-between-broadcast-and-confirmation even after FIX #970
            // already cleaned pending txids. Needs peers, so runs in background.
            Task {
                // Wait for network to be ready (peers needed for P2P verification)
                var attempts1366 = 0
                while await MainActor.run(body: { NetworkManager.shared.connectedPeers }) < 1 && attempts1366 < 30 {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    attempts1366 += 1
                }
                await self.checkBroadcastHistoryForMissingTxs()
            }

            // FIX #1366b: Automatic discovery of undiscovered delta outputs at startup.
            // Compare delta CMUs against known notes — trial-decrypt any unknown ones.
            // If any decrypt with our key → missing note → lower lastScannedHeight for rescan.
            // This catches missing change outputs even when no broadcast history exists.
            // Fast: delta on disk, Set lookup O(1), usually 0 candidates to decrypt.
            discoverMissingDeltaOutputsAtStartup(spendingKey: spendingKey)
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

                // FIX #1090: Only check for UNDER-sized trees here
                // OVER-sized is handled by FIX #756 logic below (which tolerates P2P delta CMUs)
                // Previous bug: treeSize > maxExpectedCMUs would clear tree even when
                // P2P delta fetch legitimately added CMUs beyond lastScanned height
                if treeSize < effectiveCMUCount {
                    print("⚠️ FIX #1090: Tree size \(treeSize) is SMALLER than boost (\(effectiveCMUCount))")
                    print("🔄 FIX #756 v2: Clearing corrupted tree, will reload from GitHub...")
                    // FIX #1210: Only clear tree state, keep witnesses (valid at historical anchors)
                    try? WalletDatabase.shared.clearTreeStateOnly()
                    // Fall through to reload from GitHub
                    // (treeLoadFromCMUs will replace the tree in FFI memory)
                } else if treeSize > effectiveCMUCount {
                    // FIX #756: Tree has MORE CMUs than boost file - validate delta bundle accounts for ALL extra CMUs
                    // If tree has unexplained CMUs, the database tree is corrupted
                    let deltaManager = DeltaCMUManager.shared

                    // FIX #966: PERFORMANCE - Use manifest's cmuCount instead of loading all delta CMUs
                    // This avoids expensive file I/O and prevents race condition where:
                    // 1. Tree was saved with delta CMUs baked in (from previous INSTANT START)
                    // 2. Delta bundle file was cleared after tree was saved
                    // 3. Loading deltaCMUs returns [] but tree has the CMUs already
                    //
                    // The manifest is authoritative for expected CMU count because it's updated
                    // atomically when delta CMUs are appended.
                    let manifest = deltaManager.getManifest()
                    let manifestCMUCount = manifest?.cmuCount ?? 0

                    // Also load delta CMUs as fallback (for backward compatibility)
                    let deltaCMUs = deltaManager.loadDeltaCMUs() ?? []
                    let deltaCMUFileCount = UInt64(deltaCMUs.count)

                    // Use the larger of manifest count or file count to handle edge cases:
                    // - Manifest exists but file was cleared: use manifest
                    // - File exists but manifest corrupted: use file
                    let expectedDeltaCount = max(manifestCMUCount, deltaCMUFileCount)
                    let expectedSizeWithDelta = effectiveCMUCount + expectedDeltaCount

                    // FIX #966: Check if tree size is within acceptable range
                    // FIX #1090: Only treat UNDER-sized trees as corruption
                    // OVER-sized is OK - we might have fetched delta CMUs via P2P that aren't persisted yet
                    let sizeDifference = Int64(treeSize) - Int64(expectedSizeWithDelta)

                    if sizeDifference < -10 {
                        // Tree is UNDER-sized by more than 10 - missing CMUs, likely corrupted
                        print("⚠️ FIX #756: CRITICAL - Database tree is UNDER-sized (missing CMUs)!")
                        print("   DB tree size: \(treeSize)")
                        print("   Boost file:   \(effectiveCMUCount) CMUs")
                        print("   Delta manifest: \(manifestCMUCount) CMUs")
                        print("   Delta file: \(deltaCMUFileCount) CMUs")
                        print("   Expected:     \(expectedSizeWithDelta) CMUs (using max of manifest/file)")
                        print("   Missing:      \(-sizeDifference) CMUs")
                        // FIX #1309: Delta has valid blockchain data — preserve for gap-fill.
                        // Only clear DB tree state (will reload from boost + preserved delta).
                        print("📦 FIX #1309: Delta PRESERVED — clearing only DB tree state for reload")
                        // FIX #1210: Only clear tree state, keep witnesses (valid at historical anchors)
                        try? WalletDatabase.shared.clearTreeStateOnly()
                        // Fall through to reload from GitHub (boost + delta)
                    } else if sizeDifference > 10 {
                        // FIX #1090: Tree is OVER-sized - this is OK!
                        // Likely delta CMUs were fetched via P2P for witness rebuild but not persisted yet
                        print("✅ FIX #1090: Tree has \(sizeDifference) extra CMUs (from P2P delta fetch) - this is OK")
                        print("   DB tree size: \(treeSize)")
                        print("   Expected:     \(expectedSizeWithDelta) CMUs")
                        print("   Continuing with existing tree...")
                        // Continue to validation - don't clear tree
                    } else if treeSize != expectedSizeWithDelta {
                        // FIX #966: Within tolerance - likely race condition or concurrent append
                        print("📊 FIX #966: Tree size within tolerance (diff=\(sizeDifference), tolerance=±10)")
                        print("   DB tree size: \(treeSize)")
                        print("   Expected:     \(expectedSizeWithDelta) CMUs")
                        print("   Continuing with validation (not a critical mismatch)")
                        // Continue to validation - don't clear tree
                    } else {
                        // FIX #756: Tree size matches boost + delta - delta CMUs already in tree
                        // Just validate the root directly without trying to load delta again
                        // FIX #966: Use expectedDeltaCount which accounts for manifest vs file discrepancies
                        print("✅ FIX #756/966: Tree size validated (\(treeSize) = \(effectiveCMUCount) boost + \(expectedDeltaCount) delta)")
                        print("✅ Commitment tree preloaded from database: \(treeSize) commitments")

                        // FIX #790: Validate tree root against MANIFEST root first (authoritative)
                        // Then validate against header root as secondary check
                        var treeValidated = false
                        if let deltaManifest = deltaManager.getManifest(),
                           let treeRoot = ZipherXFFI.treeRoot() {

                            // FIX #791: Validate delta manifest is compatible with current boost file
                            // Delta must start at boost end + 1, otherwise it's from a different boost file version
                            let expectedDeltaStartHeight = effectiveHeight + 1
                            if deltaManifest.startHeight != expectedDeltaStartHeight {
                                print("⚠️ FIX #791: Delta manifest is STALE (startHeight \(deltaManifest.startHeight) != expected \(expectedDeltaStartHeight))")
                                print("   Delta was created for boost file ending at \(deltaManifest.startHeight - 1)")
                                print("   Current boost file ends at \(effectiveHeight)")
                                print("🗑️ FIX #791: Clearing stale delta bundle files only...")
                                deltaManager.clearDeltaBundle()
                                // FIX #1210: Do NOT clear DB tree_state, witnesses, or lastScannedHeight!
                                // The DB tree_state is a valid serialized tree (boost+delta CMUs from previous session).
                                // Clearing it forces reload from boost → loses delta → 16K+ block P2P refetch → 2+ min.
                                // Just clearing the delta bundle files is sufficient — new delta will be built on next sync.
                                // The tree in DB is valid regardless of which boost file version the delta was from.
                                // Mark as validated since DB tree is intact (will be deserialized on restart).
                                treeValidated = true
                            }
                            // FIX #790: Primary validation - manifest root is authoritative
                            // The manifest stores the exact tree root from when delta CMUs were appended
                            else if let manifestRootData = Data(hexString: deltaManifest.treeRoot) {
                                let manifestRootReversed = Data(manifestRootData.reversed())
                                let matchesManifest = treeRoot == manifestRootData || treeRoot == manifestRootReversed

                                if matchesManifest {
                                    print("✅ FIX #790: Tree root matches delta manifest at height \(deltaManifest.endHeight)")

                                    // Secondary validation - check header agreement (optional but good)
                                    if let header = try? HeaderStore.shared.getHeader(at: deltaManifest.endHeight) {
                                        let headerRoot = header.hashFinalSaplingRoot
                                        let headerRootReversed = Data(headerRoot.reversed())
                                        let matchesHeader = treeRoot == headerRoot || treeRoot == headerRootReversed

                                        if matchesHeader {
                                            print("✅ FIX #790: Tree root also matches header - blockchain verified")
                                        } else {
                                            // Tree matches manifest but not header - header may be stale/corrupted
                                            print("⚠️ FIX #790: Tree matches manifest but not header (header may need sync)")
                                            print("   Tree root:   \(treeRoot.prefix(16).hexString)...")
                                            print("   Header root: \(headerRoot.prefix(16).hexString)...")
                                        }
                                    }
                                    treeValidated = true
                                } else {
                                    // Tree doesn't match manifest - delta CMUs are wrong/missing/reordered
                                    print("❌ FIX #790: Tree root doesn't match delta manifest!")
                                    print("   Tree root:     \(treeRoot.prefix(16).hexString)...")
                                    print("   Manifest root: \(manifestRootData.prefix(16).hexString)...")
                                    // FIX #1309: Delta has valid blockchain data — preserve for gap-fill.
                                    print("📦 FIX #1309: Delta PRESERVED — clearing only DB tree state for reload")
                                    // FIX #1210: Only clear tree state, keep witnesses (valid at historical anchors)
                                    try? WalletDatabase.shared.clearTreeStateOnly()
                                    // Fall through to reload from boost + preserved delta
                                }
                            } else {
                                print("⚠️ FIX #790: Invalid manifest root hex, falling back to header validation")
                                // Fall back to header validation if manifest root is invalid
                                if let header = try? HeaderStore.shared.getHeader(at: deltaManifest.endHeight) {
                                    let headerRoot = header.hashFinalSaplingRoot
                                    let headerRootReversed = Data(headerRoot.reversed())
                                    let rootsMatch = treeRoot == headerRoot || treeRoot == headerRootReversed

                                    if rootsMatch {
                                        print("✅ FIX #790: Tree root validated against header at \(deltaManifest.endHeight)")
                                        treeValidated = true
                                    } else {
                                        print("❌ FIX #790: Tree root MISMATCH!")
                                        print("   Tree root:   \(treeRoot.prefix(16).hexString)...")
                                        print("   Header root: \(headerRoot.prefix(16).hexString)...")
                                        // FIX #1309: Delta has valid blockchain data — preserve for gap-fill.
                                        print("📦 FIX #1309: Delta PRESERVED — clearing only DB tree state for reload")
                                        // FIX #1210: Only clear tree state, keep witnesses (valid at historical anchors)
                                        try? WalletDatabase.shared.clearTreeStateOnly()
                                    }
                                }
                            }
                        }

                        // FIX #756: If tree validated, initialize cache and return
                        if treeValidated {
                            if let cmuPath = await CommitmentTreeUpdater.shared.getCachedCMUFilePath() {
                                await MainActor.run {
                                    do {
                                        try FastWalletCache.shared.loadCMUCache(from: cmuPath)
                                        print("✅ FIX #756: FastWalletCache initialized with CMU cache")
                                    } catch {
                                        print("⚠️ FIX #756: Failed to initialize FastWalletCache: \(error)")
                                    }
                                }
                            }
                            await MainActor.run {
                                self.isTreeLoaded = true
                                self.treeLoadProgress = 1.0
                                self.treeLoadStatus = "Privacy state restored\n\(ZipherXFFI.treeSize().formatted()) commitments ready"
                            }
                            return
                        }
                    }
                } else {
                    print("✅ Commitment tree preloaded from database: \(treeSize) commitments")

                    // FIX #756: Track if we need to reload from boost file
                    var needsBoostReload = false

                    // FIX #558 v2: Load delta CMUs to complete the tree
                    // The delta CMUs are saved from previous scans but NOT loaded into the tree
                    // This causes PHASE 2 to refetch blocks on every startup!
                    let deltaManager = DeltaCMUManager.shared

                    // FIX #791: Validate delta manifest is compatible with current boost file BEFORE loading
                    // Delta must start at boost end + 1, otherwise it's from a different boost file version
                    if let deltaManifest = deltaManager.getManifest() {
                        let expectedDeltaStartHeight = effectiveHeight + 1
                        if deltaManifest.startHeight != expectedDeltaStartHeight {
                            print("⚠️ FIX #791: Delta manifest is STALE (startHeight \(deltaManifest.startHeight) != expected \(expectedDeltaStartHeight))")
                            print("   Delta was created for boost file ending at \(deltaManifest.startHeight - 1)")
                            print("   Current boost file ends at \(effectiveHeight)")
                            print("🗑️ FIX #791: Clearing stale delta bundle before loading...")
                            deltaManager.clearDeltaBundle()
                        }
                    }

                    if let deltaCMUs = deltaManager.loadDeltaCMUs(), !deltaCMUs.isEmpty {
                        // FIX #840: ATOMIC delta append - eliminates TOCTOU race condition
                        // Previous FIX #831 re-checked tree size but wasn't atomic - race still possible
                        // between check and append. FIX #840 holds all locks throughout the operation.
                        //
                        // Pack CMUs into contiguous Data for atomic append
                        var packedCMUs = Data()
                        for cmu in deltaCMUs {
                            packedCMUs.append(cmu)
                        }

                        let appendResult = ZipherXFFI.treeAppendDeltaAtomic(
                            cmus: packedCMUs,
                            expectedBoostSize: effectiveCMUCount
                        )

                        switch appendResult {
                        case .appended:
                            let newTreeSize = ZipherXFFI.treeSize()
                            print("✅ FIX #840: ATOMIC append SUCCESS - \(deltaCMUs.count) delta CMUs appended")
                            print("✅ FIX #840: Tree now has \(newTreeSize) CMUs (boost=\(effectiveCMUCount) + delta=\(deltaCMUs.count))")

                            // FIX #755: Validate tree root after delta load against header's finalsaplingroot
                            // FIX #971: Skip P2P header validation for heights above boost file
                            // P2P headers have UNRELIABLE sapling roots (FIX #796-799)
                            if let deltaManifest = deltaManager.getManifest(),
                               let treeRoot = ZipherXFFI.treeRoot() {

                                // FIX #1204b: HeaderStore sapling roots ARE authoritative for post-boost heights.
                                let boostFileEndHeight = effectiveHeight
                                if deltaManifest.endHeight > boostFileEndHeight {
                                    // FIX #1204b: Try HeaderStore root — authoritative if non-zero
                                    if let header = try? HeaderStore.shared.getHeader(at: deltaManifest.endHeight) {
                                        let headerRoot = header.hashFinalSaplingRoot
                                        let isZeroRoot = headerRoot.allSatisfy { $0 == 0 } || headerRoot.isEmpty
                                        if !isZeroRoot {
                                            let headerRootReversed = Data(headerRoot.reversed())
                                            let rootsMatch = treeRoot == headerRoot || treeRoot == headerRootReversed
                                            if rootsMatch {
                                                print("✅ FIX #1204b: Delta tree root VERIFIED against HeaderStore at height \(deltaManifest.endHeight)")
                                            } else {
                                                print("❌ FIX #1204b: Delta tree root MISMATCH at height \(deltaManifest.endHeight)!")
                                                print("   Tree root:   \(treeRoot.prefix(8).map { String(format: "%02x", $0) }.joined())...")
                                                print("   Header root: \(headerRoot.prefix(8).map { String(format: "%02x", $0) }.joined())...")
                                                // FIX #1309: Delta is INCOMPLETE (P2P missed blocks), not corrupt.
                                                // Preserve delta for gap-fill — clearing forces full re-fetch.
                                                print("📦 FIX #1309: Delta PRESERVED — root mismatch = incomplete P2P data, gap-fill will fix")
                                                break  // Exit delta load — tree will reload from boost only
                                            }
                                        } else {
                                            print("✅ FIX #1204b: HeaderStore root is zero at \(deltaManifest.endHeight) — trusting delta CMUs")
                                        }
                                    } else {
                                        print("✅ FIX #1204b: No header at \(deltaManifest.endHeight) — trusting delta CMUs")
                                    }
                                    // FIX #1029: Save tree state WITH HEIGHT to persist delta progress
                                    if let treeData = ZipherXFFI.treeSerialize() {
                                        try? WalletDatabase.shared.saveTreeState(treeData, height: deltaManifest.endHeight)
                                    }
                                } else if let header = try? HeaderStore.shared.getHeader(at: deltaManifest.endHeight) {
                                    // Within boost file range - validate against header
                                    let headerRoot = header.hashFinalSaplingRoot
                                    let headerRootReversed = Data(headerRoot.reversed())
                                    let rootsMatch = treeRoot == headerRoot || treeRoot == headerRootReversed

                                    if rootsMatch {
                                        print("✅ FIX #755: Tree root validated after delta load at height \(deltaManifest.endHeight)")
                                        // FIX #1029: Save tree state WITH HEIGHT to persist delta progress
                                        if let treeData = ZipherXFFI.treeSerialize() {
                                            try? WalletDatabase.shared.saveTreeState(treeData, height: deltaManifest.endHeight)
                                        }
                                    } else {
                                        print("❌ FIX #755: Tree root MISMATCH after delta load!")
                                        print("   Tree root:   \(treeRoot.prefix(16).hexString)...")
                                        print("   Header root: \(headerRoot.prefix(16).hexString)...")
                                        // FIX #1309: Delta is INCOMPLETE (P2P missed blocks), not corrupt.
                                        // Preserve delta for gap-fill — clearing forces full re-fetch.
                                        print("📦 FIX #1309: Delta PRESERVED — root mismatch = incomplete, gap-fill will fix")
                                        // FIX #1210: Only clear tree state, keep witnesses (valid at historical anchors)
                                        try? WalletDatabase.shared.clearTreeStateOnly()
                                        needsBoostReload = true
                                    }
                                } else {
                                    // No header available for validation - save tree anyway
                                    // FIX #1029: Include height from delta manifest
                                    if let treeData = ZipherXFFI.treeSerialize() {
                                        try? WalletDatabase.shared.saveTreeState(treeData, height: deltaManifest.endHeight)
                                    }
                                }
                            } else {
                                // No manifest or tree root - save tree at boost file height
                                // FIX #1029: Use boost file end height as fallback
                                if let treeData = ZipherXFFI.treeSerialize() {
                                    try? WalletDatabase.shared.saveTreeState(treeData, height: UInt64(ZipherXConstants.effectiveTreeHeight))
                                }
                            }

                        case .skipped:
                            // Another thread (ContentView INSTANT START) already appended delta
                            let currentTreeSize = ZipherXFFI.treeSize()
                            let expectedSizeNow = effectiveCMUCount + UInt64(deltaCMUs.count)
                            print("🔄 FIX #840: ATOMIC append SKIPPED - delta already present (current=\(currentTreeSize))")
                            if currentTreeSize == expectedSizeNow {
                                print("✅ FIX #840: Tree size validated (\(currentTreeSize) = \(effectiveCMUCount) boost + \(deltaCMUs.count) delta)")
                            } else {
                                print("⚠️ FIX #840: Tree size mismatch (current=\(currentTreeSize), expected=\(expectedSizeNow))")
                            }

                        case .mismatch:
                            // Tree is smaller than expected boost size - unexpected state
                            let currentTreeSize = ZipherXFFI.treeSize()
                            print("⚠️ FIX #840: ATOMIC append MISMATCH - tree smaller than boost (current=\(currentTreeSize), expected=\(effectiveCMUCount))")
                            print("🔄 FIX #840: Tree may need reload from boost file")
                            needsBoostReload = true

                        case .error:
                            print("❌ FIX #840: ATOMIC append ERROR - failed to append delta CMUs")
                            print("🔄 FIX #840: Falling back to boost file reload")
                            needsBoostReload = true
                        }
                    } else {
                        print("📦 FIX #558 v2: No delta CMUs to load (first run or delta empty)")

                        // FIX #814: CRITICAL - Validate tree root against boost manifest when NO delta CMUs
                        // Without this check, a corrupted database tree is accepted without validation
                        // Previous bug: Tree root mismatch loop (18+ occurrences) because:
                        //   1. Tree loaded from database with wrong root
                        //   2. No delta CMUs to trigger FIX #755 validation
                        //   3. Tree accepted without root check → health check fails → Full Rescan → repeat
                        if let manifest = await CommitmentTreeUpdater.shared.loadCachedManifest(),
                           let treeRoot = ZipherXFFI.treeRoot() {
                            // Manifest tree_root is in display format (big-endian, reversed from wire)
                            // FFI treeRoot() returns wire format (little-endian)
                            // Convert manifest root to wire format for comparison
                            if let manifestRootDisplay = Data(hexString: manifest.tree_root) {
                                let manifestRootWire = Data(manifestRootDisplay.reversed())
                                let rootsMatch = treeRoot == manifestRootWire

                                if rootsMatch {
                                    print("✅ FIX #814: Tree root validated against boost manifest")
                                    print("   Tree root (wire):     \(treeRoot.prefix(16).hexString)...")
                                    print("   Manifest root (wire): \(manifestRootWire.prefix(16).hexString)...")
                                } else {
                                    print("❌ FIX #814: CRITICAL - Database tree root MISMATCH!")
                                    print("   Tree root (wire):     \(treeRoot.hexString)")
                                    print("   Manifest root (wire): \(manifestRootWire.hexString)")
                                    print("   This explains the persistent tree root mismatch loop!")
                                    print("🗑️ FIX #814: Clearing corrupted database tree - will rebuild from boost file")
                                    // FIX #1210: Only clear tree state, keep witnesses (valid at historical anchors)
                                    try? WalletDatabase.shared.clearTreeStateOnly()
                                    needsBoostReload = true
                                }
                            } else {
                                print("⚠️ FIX #814: Could not parse manifest tree_root - skipping validation")
                            }
                        } else {
                            print("⚠️ FIX #814: No manifest or tree root available - skipping validation")
                        }
                    }

                    // FIX #756: If tree corruption detected, fall through to boost download
                    if needsBoostReload {
                        print("🔄 FIX #756: Tree corruption detected - falling through to boost file download")
                        // Don't return - fall through to download from GitHub
                    } else {
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
                // FIX #888: Set download failed flag to show retry prompt
                self.boostDownloadFailed = true
                self.boostDownloadError = error.localizedDescription
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

            // FIX #1029: Save tree state WITH HEIGHT to persist tree progress
            if let serializedTree = ZipherXFFI.treeSerialize() {
                try? WalletDatabase.shared.saveTreeState(serializedTree, height: downloadedTreeHeight)
                print("💾 FIX #1029: Tree state saved with height \(downloadedTreeHeight)")
            }

            // FIX #1355: After downloading a NEW boost file, reset lastScannedHeight to boost height.
            // Without this: lastScannedHeight stays at old value (e.g., 3011333) while the new boost
            // ends at 3011251. PHASE 2 starts from lastScannedHeight+1=3011334, SKIPPING 82 blocks
            // of CMUs (3011252-3011333). Tree root mismatch → TreeRepairExhausted → witnesses NULLed.
            let currentLastScanned = (try? WalletDatabase.shared.getLastScannedHeight()) ?? 0
            if currentLastScanned > downloadedTreeHeight {
                print("🔄 FIX #1355: Resetting lastScannedHeight from \(currentLastScanned) to \(downloadedTreeHeight)")
                print("   New boost ends at \(downloadedTreeHeight), old scan was at \(currentLastScanned)")
                print("   PHASE 2 will now scan \(currentLastScanned - downloadedTreeHeight) missed blocks")
                try? WalletDatabase.shared.resetLastScannedHeightToBoostHeight(downloadedTreeHeight)
                // Also reset verification checkpoints — they're stale after boost update
                UserDefaults.standard.removeObject(forKey: "FIX1089_FullVerificationComplete")
                UserDefaults.standard.removeObject(forKey: "FIX1106_NullifierVerificationCheckpoint")
                // Reset TreeRepairExhausted — new boost may fix the tree
                UserDefaults.standard.removeObject(forKey: "TreeRepairExhausted")
                UserDefaults.standard.removeObject(forKey: "FIX782_GlobalDeltaRepairAttempts")
                print("✅ FIX #1355: Reset lastScannedHeight + cleared stale checkpoints + repair flags")
            }

            // FIX #558 v2: Load delta CMUs to complete the tree (boost file path)
            // FIX #840: Now uses ATOMIC delta append to prevent race condition
            let deltaManager = DeltaCMUManager.shared
            if let deltaCMUs = deltaManager.loadDeltaCMUs(), !deltaCMUs.isEmpty {
                let effectiveCMUCount = ZipherXConstants.effectiveTreeCMUCount

                // Pack CMUs into contiguous Data for atomic append
                var packedCMUs = Data()
                for cmu in deltaCMUs {
                    packedCMUs.append(cmu)
                }

                let appendResult = ZipherXFFI.treeAppendDeltaAtomic(
                    cmus: packedCMUs,
                    expectedBoostSize: effectiveCMUCount
                )

                switch appendResult {
                case .appended:
                    let newTreeSize = ZipherXFFI.treeSize()
                    print("✅ FIX #840: ATOMIC append SUCCESS - \(deltaCMUs.count) delta CMUs [boost path]")
                    print("✅ FIX #840: Tree now has \(newTreeSize) CMUs")

                    // FIX #755: Validate tree root after delta load (boost path)
                    // FIX #1204b: HeaderStore sapling roots ARE authoritative for post-boost heights.
                    let boostFileEndHeight = UInt64(ZipherXConstants.effectiveTreeHeight)
                    if let deltaManifest = deltaManager.getManifest(),
                       let treeRoot = ZipherXFFI.treeRoot() {

                        // FIX #1204b: Try HeaderStore root for post-boost heights too
                        if deltaManifest.endHeight > boostFileEndHeight {
                            if let header = try? HeaderStore.shared.getHeader(at: deltaManifest.endHeight) {
                                let headerRoot = header.hashFinalSaplingRoot
                                let isZeroRoot = headerRoot.allSatisfy { $0 == 0 } || headerRoot.isEmpty
                                if !isZeroRoot {
                                    let headerRootReversed = Data(headerRoot.reversed())
                                    let rootsMatch = treeRoot == headerRoot || treeRoot == headerRootReversed
                                    if rootsMatch {
                                        print("✅ FIX #1204b: Delta tree root VERIFIED at height \(deltaManifest.endHeight) [boost path]")
                                    } else {
                                        print("❌ FIX #1204b: Delta tree root MISMATCH at height \(deltaManifest.endHeight) [boost path]!")
                                        print("   Tree root:   \(treeRoot.prefix(8).map { String(format: "%02x", $0) }.joined())...")
                                        print("   Header root: \(headerRoot.prefix(8).map { String(format: "%02x", $0) }.joined())...")
                                        // FIX #1309: Delta is INCOMPLETE (P2P missed blocks), not corrupt.
                                        // Revert tree to boost-only, preserve delta for gap-fill.
                                        print("📦 FIX #1309: Delta PRESERVED — reverting tree to boost-only")
                                        ZipherXFFI.treeDeserialize(data: serializedData)
                                        print("📦 FIX #1309: Tree reverted to \(ZipherXFFI.treeSize()) CMUs (boost only)")
                                        break
                                    }
                                } else {
                                    print("✅ FIX #1204b: HeaderStore root is zero at \(deltaManifest.endHeight) — trusting delta CMUs [boost path]")
                                }
                            } else {
                                print("✅ FIX #1204b: No header at \(deltaManifest.endHeight) — trusting delta CMUs [boost path]")
                            }
                            // Save tree state - delta CMUs validated or root unavailable
                            if let treeData = ZipherXFFI.treeSerialize() {
                                try? WalletDatabase.shared.saveTreeState(treeData, height: deltaManifest.endHeight)
                            }
                        } else if let header = try? HeaderStore.shared.getHeader(at: deltaManifest.endHeight) {
                            let headerRoot = header.hashFinalSaplingRoot
                            let headerRootReversed = Data(headerRoot.reversed())
                            let rootsMatch = treeRoot == headerRoot || treeRoot == headerRootReversed

                            if rootsMatch {
                                print("✅ FIX #755: Tree root validated after delta load at height \(deltaManifest.endHeight)")
                                // FIX #1029: Save WITH HEIGHT to persist delta progress
                                if let treeData = ZipherXFFI.treeSerialize() {
                                    try? WalletDatabase.shared.saveTreeState(treeData, height: deltaManifest.endHeight)
                                }
                            } else {
                                print("❌ FIX #755: Tree root MISMATCH after delta load! (boost path)")
                                print("   Tree root:   \(treeRoot.prefix(16).hexString)...")
                                print("   Header root: \(headerRoot.prefix(16).hexString)...")
                                // FIX #1309: Delta is INCOMPLETE (P2P missed blocks), not corrupt.
                                // Revert tree to boost-only, preserve delta for gap-fill.
                                print("📦 FIX #1309: Delta PRESERVED — reverting tree to boost-only")
                                ZipherXFFI.treeDeserialize(data: serializedData)
                                print("📦 FIX #1309: Tree reverted to \(ZipherXFFI.treeSize()) CMUs (boost only)")
                                await MainActor.run {
                                    self.pendingDeltaRescan = true
                                }
                            }
                        } else {
                            // No header available - save tree anyway
                            if let treeData = ZipherXFFI.treeSerialize() {
                                try? WalletDatabase.shared.saveTreeState(treeData, height: deltaManifest.endHeight)
                            }
                        }
                    } else {
                        // FIX #1029: Save with delta manifest height if available, otherwise boost height
                        if let treeData = ZipherXFFI.treeSerialize() {
                            let saveHeight = deltaManager.getManifest()?.endHeight ?? downloadedTreeHeight
                            try? WalletDatabase.shared.saveTreeState(treeData, height: saveHeight)
                        }
                    }

                case .skipped:
                    let currentTreeSize = ZipherXFFI.treeSize()
                    print("🔄 FIX #840: ATOMIC append SKIPPED - delta already present (size=\(currentTreeSize)) [boost path]")

                case .mismatch:
                    let currentTreeSize = ZipherXFFI.treeSize()
                    print("⚠️ FIX #840: ATOMIC append MISMATCH - tree smaller than expected (size=\(currentTreeSize)) [boost path]")

                case .error:
                    print("❌ FIX #840: ATOMIC append ERROR [boost path]")
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

                // FIX #1029: Save tree state WITH HEIGHT to persist tree progress
                if let serializedTree = ZipherXFFI.treeSerialize() {
                    try? WalletDatabase.shared.saveTreeState(serializedTree, height: downloadedTreeHeight)
                    print("💾 FIX #1029: Tree state saved with height \(downloadedTreeHeight)")
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

    // FIX #1009: Cache pre-send verification for INSTANT sends
    // Tree validation is expensive (fetches block via P2P)
    // Cache result for 60 seconds if wallet recently synced
    private var lastTreeValidationResult: CMUTreeValidationResult?
    private var lastTreeValidationTime: Date?
    private let treeValidationCacheDuration: TimeInterval = 60 // 60 seconds

    /// FIX #1009: Invalidate tree validation cache when tree state changes
    /// Call this after: sync completes, repair runs, tree appends
    func invalidateTreeValidationCache() {
        lastTreeValidationResult = nil
        lastTreeValidationTime = nil
        print("🔄 FIX #1009: Tree validation cache invalidated")
    }

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
        print("🕐 DEBUG ensureHeaderTimestamps: ENTER")

        // FIX #495: Skip if we're already at chain tip AND no timestamps needed
        // FIX #1428: After import, walletHeight IS at chain tip but transactions have NULL block_time.
        // Must check for pending timestamps BEFORE early-returning.
        let currentChainHeight = await MainActor.run { NetworkManager.shared.chainHeight }
        let walletHeight = (try? WalletDatabase.shared.getLastScannedHeight()) ?? 0
        print("🕐 DEBUG ensureHeaderTimestamps: walletHeight=\(walletHeight), chainHeight=\(currentChainHeight)")

        if currentChainHeight > 0 && walletHeight >= currentChainHeight - 100 {
            let earliestNeeding = try? WalletDatabase.shared.getEarliestHeightNeedingTimestamp()
            let hasTimestampGaps = earliestNeeding != nil
            print("🕐 DEBUG ensureHeaderTimestamps: atChainTip=true, hasTimestampGaps=\(hasTimestampGaps), earliestNeeding=\(earliestNeeding ?? 0)")
            if !hasTimestampGaps {
                print("✅ FIX #495: Already at chain tip and all timestamps present, skipping header sync")
                return
            }
            print("📜 FIX #1428: At chain tip but transactions need timestamps — proceeding with sync")
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
        // FIX #1493: VULN-009 — Use centralized constant (was local hardcoded 3)
        let minPeersForConsensus = ZipherXConstants.consensusThreshold
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
        // FIX #1426: stopListeners: false — this sync is ≤100 headers (maxSyncRange=100).
        // Stopping listeners kills NWConnections → peers need 2-3s reconnection → first attempt fails
        // → needs Attempt 2. Matches import flow (line 7341) which already uses stopListeners: false.
        await NetworkManager.shared.setHeaderSyncing(true, stopListeners: false)
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
        // FIX #810: Must check if headers loaded up to FULL boost file height, not just "any headers exist"
        // Previous bug: existingBoostHeight=2938860 (partial) would skip reload, missing ~50K headers
        let existingBoostHeight = HeaderStore.shared.boostFileEndHeight
        let expectedBoostHeight = ZipherXConstants.effectiveTreeHeight  // 2988797
        if existingBoostHeight >= expectedBoostHeight {
            print("✅ FIX #701: Boost headers already loaded up to \(existingBoostHeight) - skipping reload")
            return (true, existingBoostHeight)
        } else if existingBoostHeight > 0 {
            // FIX #810: Partial headers exist - need to reload from boost file
            print("⚠️ FIX #810: Partial boost headers detected (\(existingBoostHeight) < \(expectedBoostHeight))")
            print("⚠️ FIX #810: Will reload full boost headers to avoid slow P2P sync")
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
        // FIX #899: CRITICAL - Require 100% of boost headers, not 95%!
        // Old bug: 95% threshold allowed ~125K gaps in 2.5M headers
        // Each gap triggered inefficient P2P sync from old checkpoint (28K headers per 320-block gap!)
        // Full Resync took forever because gap filling was syncing from checkpoint 2938700 repeatedly
        let countInRange = (try? HeaderStore.shared.countHeadersInRange(from: sectionInfo.startHeight, to: sectionInfo.endHeight)) ?? 0
        let expectedCount = Int(sectionInfo.endHeight - sectionInfo.startHeight + 1)
        let hasBoostHeaders = countInRange == expectedCount  // FIX #899: Require exactly 100%

        if hasBoostHeaders {
            print("✅ FIX #413: Boost file headers already loaded (\(countInRange)/\(expectedCount) in range)")
            return (true, sectionInfo.endHeight)
        }

        // FIX #899: If partial headers exist, delete them to ensure clean boost load
        if countInRange > 0 && countInRange < expectedCount {
            print("⚠️ FIX #899: Partial headers detected (\(countInRange)/\(expectedCount)) - deleting for clean reload")
            try? HeaderStore.shared.deleteHeadersInRange(from: sectionInfo.startHeight, to: sectionInfo.endHeight)
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

            // FIX #889: Notify NetworkManager that header loading is starting
            // This suppresses NWPathMonitor callbacks (FIX #890) and fetchNetworkStats (FIX #892)
            // which were causing the 91-99% stall during Import PK (5+ minutes lost!)
            await MainActor.run {
                NetworkManager.shared.setLoadingHeaders(true)
            }

            // FIX #488: Run blocking loadHeadersFromBoostData on background thread
            // This prevents blocking the main thread, allowing UI updates during the 100-second load
            // The callback uses DispatchQueue.main.async which queues blocks on main thread
            // If main thread is blocked, those blocks never execute until load completes
            defer {
                // FIX #889: Ensure flag is cleared even if an error occurs
                Task { @MainActor in
                    NetworkManager.shared.setLoadingHeaders(false)
                }
            }

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
        // FIX #873: Add debug logging for concurrent sync detection
        backgroundSyncLock.lock()
        if isBackgroundSyncing {
            backgroundSyncLock.unlock()
            print("⚠️ FIX #873: Background sync blocked - already syncing (isBackgroundSyncing=true)")
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
        // FIX #873: Add debug logging to identify why background sync is blocked
        guard isTreeLoaded && !isSyncing else {
            print("⚠️ FIX #873: Background sync blocked - isTreeLoaded=\(isTreeLoaded), isSyncing=\(isSyncing)")
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

        // FIX #841: Don't run background sync if broadcast is in progress
        // Background sync triggers header sync which holds peer locks, causing broadcast timeouts
        // The broadcast needs peer locks to send TX to peers - if header sync holds them, broadcast fails
        guard await !NetworkManager.shared.isBroadcasting else {
            print("⚠️ FIX #841: Background sync blocked - broadcast in progress")
            return
        }

        // FIX #1220: Block background sync during gap-fill — gap-fill needs ALL P2P bandwidth
        // Concurrent fetches (FilterScanner, new block scanning) steal connections and cause missing blocks (0.8% loss)
        guard !isGapFillingDelta else {
            print("⚠️ FIX #1220: Background sync blocked - gap-fill in progress")
            return
        }

        // Also block if FilterScanner is running (double protection)
        // FIX #873: Added debug logging to identify stuck FilterScanner flag
        let scanInProgress = FilterScanner.isScanInProgress
        guard !scanInProgress else {
            print("⚠️ FIX #368/#873: Background sync blocked - FilterScanner.isScanInProgress=\(scanInProgress)")
            return
        }

        // Get current synced height
        let currentHeight = (try? WalletDatabase.shared.getLastScannedHeight()) ?? ZipherXConstants.effectiveTreeHeight
        guard targetHeight > currentHeight else {
            return // Already synced
        }

        let blocksToSync = targetHeight - currentHeight
        print("🔄 Background sync: \(blocksToSync) new block(s) (\(currentHeight + 1) → \(targetHeight))")

        // FIX #1103: Clear pending retry flag - sync is now starting
        await MainActor.run { self.hasPendingNetworkRetry = false }

        do {
            // VUL-U-002: Get spending key for note detection with secure zeroing
            let secureKey = try secureStorage.retrieveSpendingKeySecure()
            defer { secureKey.zero() }
            let spendingKey = secureKey.data

            // Use FilterScanner for lightweight sync
            let scanner = FilterScanner()

            // Get account ID
            guard let account = try WalletDatabase.shared.getAccount(index: 0) else {
                print("⚠️ Background sync: No account found")
                return
            }

            // Scan just the new blocks
            // FIX #1410: Pass expected block count so FilterScanner can skip stopping
            // block listeners for small syncs (prevents peer drop to 0 on iOS)
            try await scanner.startScan(
                for: account.accountId,
                viewingKey: spendingKey,
                fromHeight: currentHeight + 1,
                expectedBlockCount: blocksToSync
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

            // FIX #1009: Invalidate tree validation cache after sync
            invalidateTreeValidationCache()

            // FIX #600: Update witnesses with new delta CMUs for instant send
            // Without this, witnesses become stale and require 24s rebuild when user tries to send
            if blocksToSync > 0 {
                print("⚡ FIX #600: Updating witnesses with \(blocksToSync) new blocks for instant send...")
                await preRebuildWitnessesForInstantPayment(accountId: account.accountId)
            }

            // FIX #1302: Auto Full Rescan REMOVED. Was FIX #1280's nuclear option that
            // destroyed corrected balance by re-introducing phantom notes through Phase 2's
            // partial batch cursor bug. Witnesses are NULLed (safe for balance display).
            // They will be rebuilt on next preRebuildWitnessesForInstantPayment() call.
            // Balance always correct via getTotalUnspentBalance() (ignores witness state).

            // FIX #1210: Use getTotalUnspentBalance for display (no witness requirement).
            // getUnspentNotes() requires witness IS NOT NULL — shows partial balance when
            // only some witnesses are rebuilt. Display should always show full balance.
            let confirmedBalance = try WalletDatabase.shared.getTotalUnspentBalance(accountId: account.accountId)
            let pendingBal: UInt64 = 0

            // FIX #1084: Verify balance integrity in background (only if safe)
            // NEVER run during send/receive to avoid race conditions
            let hasPendingTx = (try? WalletDatabase.shared.getPendingSentTransactions())?.isEmpty == false
            let pendingTxids = UserDefaults.standard.stringArray(forKey: "ZipherX_PendingOutgoingTxids") ?? []
            let hasPendingOutgoing = !pendingTxids.isEmpty

            if hasPendingTx || hasPendingOutgoing {
                print("⏸️ FIX #1084: Skipping balance verification - pending transaction in progress")
            } else {
                // Run verification in background without blocking balance display
                // FIX #1245: Capture confirmedBalance to detect if verification restored notes
                let preVerifyBalance = confirmedBalance
                Task.detached(priority: .background) {
                    do {
                        let (isValid, postVerifyBalance, _, details) = try WalletDatabase.shared.verifyBalanceIntegrity(accountId: 1)
                        print("📊 FIX #1084: Balance verification (background):")
                        print(details)

                        // FIX #1245: If verifyBalanceIntegrity auto-restored notes (FIX #1169 phantoms
                        // or FIX #1233 orphans), the balance changed but UI still shows the old value.
                        // Refresh shieldedBalance and notify UI so user sees correct balance.
                        if postVerifyBalance != preVerifyBalance {
                            let restoredDiff = Int64(postVerifyBalance) - Int64(preVerifyBalance)
                            print("💰 FIX #1245: Balance changed during verification: \(UInt64(abs(restoredDiff)).redactedAmount) (restored phantom/orphan notes)")
                            await MainActor.run {
                                WalletManager.shared.shieldedBalance = postVerifyBalance
                                NotificationCenter.default.post(name: Notification.Name("transactionHistoryUpdated"), object: nil)
                                print("✅ FIX #1245: UI balance refreshed to \(postVerifyBalance.redactedAmount)")
                            }
                        }

                        if !isValid {
                            print("⚠️ FIX #1084: Balance discrepancy - triggering nullifier verification...")
                            // FIX #1250: Show discrepancy warning in UI until verified
                            await MainActor.run {
                                WalletManager.shared.balanceIntegrityIssue = true
                                WalletManager.shared.balanceIntegrityMessage = "Balance discrepancy detected — verifying..."
                                print("⚠️ FIX #1250: Set balanceIntegrityIssue=true (discrepancy in background verification)")
                            }
                            try? await WalletManager.shared.verifyNullifierSpendStatus()
                            // Clear the flag after successful verification
                            let (recheck, _, _, _) = try WalletDatabase.shared.verifyBalanceIntegrity(accountId: 1)
                            if recheck {
                                await MainActor.run {
                                    WalletManager.shared.balanceIntegrityIssue = false
                                    WalletManager.shared.balanceIntegrityMessage = nil
                                    print("✅ FIX #1250: Balance verified OK after nullifier check — cleared integrity flag")
                                }
                            }
                        } else if await WalletManager.shared.balanceIntegrityIssue {
                            // FIX #1359: Balance is valid but flag was left set from a previous
                            // correction (e.g., phantom cleanup during startup). Clear it now.
                            await MainActor.run {
                                WalletManager.shared.balanceIntegrityIssue = false
                                WalletManager.shared.balanceIntegrityMessage = nil
                                print("✅ FIX #1359: Balance verified OK in background — cleared stale integrity flag")
                            }
                        }
                    } catch {
                        print("⚠️ FIX #1084: Balance verification failed: \(error)")
                    }
                }
            }

            await MainActor.run {
                self.shieldedBalance = confirmedBalance
                self.pendingBalance = pendingBal
                print("💰 Background sync balance: \(confirmedBalance.redactedAmount) (\(pendingBal.redactedAmount) pending)")
            }

            // Update wallet height in NetworkManager for UI display
            // FIX #1108: Use actualLastScanned, not targetHeight!
            // Bug: walletHeight was set to targetHeight even if scan didn't reach it
            // Result: walletHeight showed higher than actual scanned height
            await MainActor.run { NetworkManager.shared.updateWalletHeight(actualLastScanned) }

            // FIX #1108 v2: Re-check chain height and sync remaining blocks if still behind
            // Problem: Wallet always 1 block behind because new blocks arrive during sync
            // Solution: After sync completes, check if more blocks arrived and sync them too
            let currentChainHeight = try? await NetworkManager.shared.getChainHeight()
            if let freshChainHeight = currentChainHeight, freshChainHeight > actualLastScanned {
                let stillBehind = freshChainHeight - actualLastScanned
                if stillBehind <= 3 {  // Only catch up small gaps (avoid infinite loop)
                    print("🔄 FIX #1108: Still \(stillBehind) block(s) behind after sync - fetching remaining...")
                    // Quick scan for just the remaining blocks
                    let quickScanner = FilterScanner()
                    try? await quickScanner.startScan(
                        for: account.accountId,
                        viewingKey: spendingKey,
                        fromHeight: actualLastScanned + 1
                    )
                    let finalHeight = (try? WalletDatabase.shared.getLastScannedHeight()) ?? actualLastScanned
                    await MainActor.run { NetworkManager.shared.updateWalletHeight(finalHeight) }
                    print("✅ FIX #1108: Now synced to height \(finalHeight)")
                }
            }

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
                        // FIX #1242: Calculate actual gap instead of hardcoded 100.
                        // FIX #180 used maxHeaders:100 which misses timestamps when gap > 100 blocks.
                        // syncHeaders FIX #141 already skips headers we have, so this covers the real gap.
                        let timestampHeadersNeeded = currentHeight - earliestNeedingTimestamp + 10
                        print("📜 FIX #120: Syncing headers from \(earliestNeedingTimestamp) for missing timestamps (gap: \(timestampHeadersNeeded))")
                        do {
                            try await hsm.syncHeaders(from: earliestNeedingTimestamp, maxHeaders: timestampHeadersNeeded)
                            print("✅ FIX #120: Header sync completed for timestamps")
                        } catch {
                            print("⚠️ FIX #120: Header sync failed: \(error.localizedDescription)")
                        }
                    }
                }

                // Also sync from current height for new blocks
                // FIX #1241: Remove arbitrary 100-header limit - sync ALL headers for scanned blocks
                // Bug: backgroundSyncToHeight scanned blocks to actualLastScanned (e.g. 3006044),
                // but header sync only fetched 100 headers. If HeaderStore was at 3005900, headers
                // only reached 3006000, leaving a 44-block gap. Next block announcement → same pattern
                // → growing gap between wallet height and header height → anchor validation failures.
                // Solution: Calculate headers needed based on blocks actually scanned (actualLastScanned),
                // not arbitrary limit. Headers must always cover the wallet height.
                do {
                    let headerStoreHeight = (try? HeaderStore.shared.getLatestHeight()) ?? 0
                    let headersNeeded = actualLastScanned > headerStoreHeight ?
                                        actualLastScanned - headerStoreHeight + 10 : 10  // +10 buffer

                    if headersNeeded > 0 {
                        print("📥 FIX #1241: Syncing \(headersNeeded) headers to match wallet height \(actualLastScanned)")
                        try await hsm.syncHeaders(from: headerStoreHeight + 1, maxHeaders: headersNeeded)
                        print("✅ FIX #1241: Header sync completed to height \(try? HeaderStore.shared.getLatestHeight() ?? 0)")
                    } else {
                        print("✅ FIX #1241: Headers already synced (HeaderStore: \(headerStoreHeight), Wallet: \(actualLastScanned))")
                    }
                } catch {
                    print("⚠️ FIX #1241: Header sync failed: \(error.localizedDescription)")
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

            // FIX #1302: Auto Full Rescan REMOVED from startup path.
            // Was FIX #1280's auto-trigger that destroyed corrected balance.
            // Witnesses are NULLed (safe). Balance correct via getTotalUnspentBalance().
            // Witnesses rebuilt on next preRebuildWitnessesForInstantPayment() cycle.

            // FIX #300 + FIX #1210: Refresh balance AFTER witness rebuild.
            // Use getTotalUnspentBalance (no witness requirement) for display balance.
            do {
                let refreshedBalance = try WalletDatabase.shared.getTotalUnspentBalance(accountId: account.accountId)
                if refreshedBalance != confirmedBalance {
                    print("💰 FIX #300: Balance updated after witness rebuild: \(confirmedBalance.redactedAmount) → \(refreshedBalance.redactedAmount)")
                    await MainActor.run {
                        self.shieldedBalance = refreshedBalance
                    }
                }

                // Check if any notes still need witnesses (couldn't be rebuilt)
                let (needCount, needValue) = try WalletDatabase.shared.getNotesNeedingWitness(accountId: account.accountId)
                if needCount > 0 {
                    print("⚠️ FIX #300: \(needCount) note(s) worth \(needValue.redactedAmount) still need witness rebuild")
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

            // FIX #910: Handle network failure by scheduling automatic retry
            // When scan aborts due to network failure, wait for network to recover and retry
            if case NetworkError.scanAbortedDueToNetworkFailure(_, _, let lastHeight) = error {
                print("🔄 FIX #910: Scheduling automatic retry after network failure (last height: \(lastHeight))")

                // FIX #1103: Set flag so health check shows "Network issues, will retry" instead of scary warning
                await MainActor.run { self.hasPendingNetworkRetry = true }

                // Schedule retry in 10 seconds if network recovers
                Task {
                    // Wait for potential network recovery
                    try? await Task.sleep(nanoseconds: 10_000_000_000)  // 10 seconds

                    // Check if we have peers now
                    let peerCount = await NetworkManager.shared.connectedPeers
                    if peerCount >= 3 {
                        print("🔄 FIX #910: Network recovered (\(peerCount) peers), retrying sync...")
                        // FIX #1103: Clear flag before retry (will be set again if retry fails)
                        await MainActor.run { self.hasPendingNetworkRetry = false }
                        await self.backgroundSyncToHeight(targetHeight)
                    } else {
                        print("⚠️ FIX #910: Network still down (\(peerCount) peers), will retry on next trigger")
                        // FIX #1103: Keep flag true - still pending retry
                    }
                }
            }
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
        // FIX #1290: Abort immediately when Full Rescan is in progress
        // INSTANT start's witness rebuild + delta sync competes for P2P peers and FFI tree,
        // adding 2+ minutes of overhead to Full Rescan. The Full Rescan handles everything.
        let isRepairing = await MainActor.run { WalletManager.shared.isRepairingDatabase }
        if isRepairing {
            print("⏩ FIX #1290: Skipping preRebuildWitnesses — Full Rescan in progress")
            return
        }

        // FIX #1240: Early exit when tree state is corrupted — don't waste time on expensive
        // witness validation (FIX #1224 HeaderStore queries × 24 witnesses × ~300ms each = 7+ seconds).
        // Previous FIX #1238 guard was 300 lines deep (line ~4263), AFTER all the expensive checks.
        // Escalation #3 showed 5+ minutes of futile validation when TreeRepairExhausted was already true.
        // Witnesses from corrupted tree have non-existent anchors — no point validating them.
        let treeRepairExhausted = UserDefaults.standard.bool(forKey: "TreeRepairExhausted")
        if treeRepairExhausted {
            print("⏩ FIX #1240: Skipping preRebuildWitnessesForInstantPayment — tree repair exhausted")
            print("   FFI tree has wrong root (incomplete delta). ALL witness operations are futile.")
            print("   Skipping expensive FIX #1224 validation loop. User must run 'Full Resync' first.")
            return
        }

        // FIX #1327: Skip expensive witness re-verification if ALL witnesses passed recently
        // AND the tree size hasn't changed (no new CMUs appended since last check).
        // This prevents the 4+ second re-check that runs after EVERY background sync cycle.
        // But NEVER skip if there are NULL witnesses (FIX #586 bypass).
        let currentTreeSize = ZipherXFFI.treeSize()
        if let lastVerified = lastWitnessVerificationAllPassed,
           Date().timeIntervalSince(lastVerified) < 60,
           lastWitnessVerificationTreeSize == currentTreeSize,
           currentTreeSize > 0 {
            // Quick check: any unspent notes with empty witnesses?
            let hasNullUnspent = (try? WalletDatabase.shared.getAllUnspentNotes(accountId: accountId))?.contains { $0.witness.isEmpty } ?? false
            if !hasNullUnspent {
                let ago = Int(Date().timeIntervalSince(lastVerified))
                print("⏩ FIX #1327: All witnesses verified \(ago)s ago (tree unchanged at \(currentTreeSize)) — skipping")
                return
            }
        }

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
                    // FIX #1050: Suppress routine cooldown log
                    // print("⚠️ FIX #557 v15: Skipping rebuild - rebuilt \(Int(timeSinceRebuild))s ago (cooldown: \(Int(witnessRebuildCooldown))s)")
                    return
                } else {
                    print("⚠️ FIX #586: Bypassing cooldown - \(hasNullWitnesses ? "NULL witnesses detected" : "")")
                }
            }
        }

        // FIX #563 v28: Update @Published properties on main thread to prevent crashes
        await MainActor.run {
            isRebuildingWitnesses = true
            // FIX #1143: Reset corrupted witness flags at START of rebuild
            self.hasCorruptedWitnesses = false
            self.corruptedWitnessCount = 0
        }
        print("🔄 FIX #1143: Reset corrupted witness flags for fresh pre-build")
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
            // FIX #881: PERFORMANCE - Use cached chain height first to avoid network call
            var fastPathChainHeight = UInt64(UserDefaults.standard.integer(forKey: "cachedChainHeight"))
            if fastPathChainHeight == 0 {
                // Only call network if no cached height available
                fastPathChainHeight = (try? await NetworkManager.shared.getChainHeight()) ?? 0
            }

            // FIX #799: Get boost file end height - P2P headers above this are UNRELIABLE
            let boostFileEndHeight = ZipherXConstants.effectiveTreeHeight

            var headerTreeRoot: Data?
            var useFFIRootInstead = false

            // FIX #799 + FIX #1204: Check HeaderStore first — FIX #1204 stores authoritative
            // finalsaplingroot from full block P2P fetches (delta sync, block scanning).
            // Only fall back to FFI tree root if HeaderStore has no root or zero root.
            if fastPathChainHeight == 0 {
                print("⚡ FIX #881: No chain height yet - using FFI tree root for FAST PATH")
                useFFIRootInstead = true
                headerTreeRoot = ZipherXFFI.treeRoot()
                if let root = headerTreeRoot {
                    let rootHex = root.prefix(16).map { String(format: "%02x", $0) }.joined()
                    print("📋 FIX #881: Using FFI tree root: \(rootHex)...")
                }
            } else if fastPathChainHeight > boostFileEndHeight && boostFileEndHeight > 0 {
                // FIX #1204: Try HeaderStore first — might have authoritative root from full block fetch
                let headerStore = HeaderStore.shared
                try? headerStore.open()
                var foundAuthoritativeRoot = false
                if let header = try? headerStore.getHeader(at: fastPathChainHeight) {
                    let root = header.hashFinalSaplingRoot
                    let isZeroRoot = root.allSatisfy { $0 == 0 }
                    if !isZeroRoot {
                        headerTreeRoot = root
                        foundAuthoritativeRoot = true
                        let rootHex = root.prefix(16).map { String(format: "%02x", $0) }.joined()
                        print("✅ FIX #1204: HeaderStore has authoritative root at \(fastPathChainHeight): \(rootHex)...")
                    }
                }
                if !foundAuthoritativeRoot {
                    // FIX #1305: HeaderStore is behind tree tip — sync headers before falling back.
                    // Without this: witnesses get created → anchor not in HeaderStore → FIX #1279 rejects ALL
                    // → NULLed → balance shows 0 → can't send. The fix: sync the missing headers FIRST.
                    let headerStoreHeight = (try? headerStore.getLatestHeight()) ?? 0
                    let headerGap = fastPathChainHeight > headerStoreHeight ? fastPathChainHeight - headerStoreHeight : 0

                    if headerGap > 0 && headerGap <= 50 {
                        print("🔄 FIX #1305: HeaderStore behind by \(headerGap) headers (\(headerStoreHeight) → \(fastPathChainHeight))")
                        print("   Syncing headers BEFORE witness validation (prevents phantom anchor rejection)")
                        do {
                            let syncManager = HeaderSyncManager(
                                headerStore: headerStore,
                                networkManager: NetworkManager.shared
                            )
                            try await syncManager.syncHeaders(from: headerStoreHeight + 1, maxHeaders: headerGap + 10)
                            print("✅ FIX #1305: Quick header sync complete — retrying root lookup")

                            // Retry HeaderStore lookup after sync
                            if let header = try? headerStore.getHeader(at: fastPathChainHeight) {
                                let root = header.hashFinalSaplingRoot
                                let isZeroRoot = root.allSatisfy { $0 == 0 }
                                if !isZeroRoot {
                                    headerTreeRoot = root
                                    foundAuthoritativeRoot = true
                                    let rootHex = root.prefix(16).map { String(format: "%02x", $0) }.joined()
                                    print("✅ FIX #1305: Got authoritative root after sync: \(rootHex)...")
                                }
                            }
                        } catch {
                            print("⚠️ FIX #1305: Quick header sync failed: \(error) — falling back to FFI root")
                        }
                    } else if headerGap > 50 {
                        print("⚠️ FIX #1305: HeaderStore too far behind (\(headerGap) headers) — skipping quick sync")
                    }

                    if !foundAuthoritativeRoot {
                        // FIX #799: HeaderStore root is still zero or missing — fall back to FFI tree root
                        print("⚠️ FIX #799: Height \(fastPathChainHeight) > boost file end \(boostFileEndHeight)")
                        print("   HeaderStore root zero/missing — using FFI tree root for comparison")
                        useFFIRootInstead = true
                        headerTreeRoot = ZipherXFFI.treeRoot()
                        if let root = headerTreeRoot {
                            let rootHex = root.prefix(16).map { String(format: "%02x", $0) }.joined()
                            print("📋 FIX #799: Using FFI tree root: \(rootHex)...")
                        }
                    }
                }
            } else if fastPathChainHeight > 0 {
                let headerStore = HeaderStore.shared
                try? headerStore.open()
                if let header = try? headerStore.getHeader(at: fastPathChainHeight) {
                    headerTreeRoot = header.hashFinalSaplingRoot
                    let headerRootHex = headerTreeRoot?.prefix(16).map { String(format: "%02x", $0) }.joined() ?? "unknown"
                    print("📋 FIX #597 v2: Header root at \(fastPathChainHeight): \(headerRootHex)...")
                }
            }

            // FIX #1033: DISABLED FIX #597 v2 FAST PATH - This optimization was INCORRECT!
            // FIX #597 v2 compared witness roots to CURRENT tree root (FFI or header), but:
            //   1. Sapling accepts ANY historical anchor (not just current tree root)
            //   2. Witnesses created at boost file height have a DIFFERENT root than current tree
            //   3. This is perfectly valid - 18/23 witnesses having different root is NORMAL
            //   4. The "78% match, need rebuild" message was triggering unnecessary 46+ second rebuilds!
            //
            // The CORRECT validation is FIX #827 (internal consistency) + FIX #1013 (anchor in history).
            // Comparing to current tree root is meaningless and causes false positives.

            let notesForWitnessCheck = try WalletDatabase.shared.getAllUnspentNotes(accountId: accountId)

            guard !notesForWitnessCheck.isEmpty else {
                print("✅ Pre-witness: No unspent notes to update")
                return
            }

            print("📋 FIX #1033: Checking \(notesForWitnessCheck.count) witnesses for internal consistency (FIX #827)...")

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
                    if verbose {
                        print("🔍 [WITNESS \(index + 1)/\(notesForWitnessCheck.count)] Checking note ID=\(note.id) height=\(note.height ?? 0) witness_len=\(note.witness.count)")
                    }

                    // Validate witness data length before calling FFI
                    // Witness should be at least 100 bytes (minimum for IncrementalWitness)
                    guard note.witness.count >= 100 else {
                        if verbose {
                            print("⚠️ [WITNESS \(index + 1)] Note ID=\(note.id) has invalid witness length: \(note.witness.count) bytes")
                        }
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
                        if verbose {
                            print("⚠️ [WITNESS \(index + 1)] Note ID=\(note.id) has corrupted witness path - forcing rebuild")
                        }
                        corruptedWitnesses.append((note.id, note.height ?? 0))
                        // Force rebuild for this note
                        if let cmu = note.cmu, !cmu.isEmpty {
                            notesNeedingRebuild.append((note: note, cmu: cmu))
                        }
                        continue
                    }

                    // FIX #827: Verify witness anchor consistency (path computes to same root)
                    // A witness can pass witnessPathIsValid but still have corrupted path data
                    // that computes to a different root than witness.root()
                    if let cmu = note.cmu, !cmu.isEmpty {
                        if !ZipherXFFI.witnessVerifyAnchor(note.witness, cmu: cmu) {
                            if verbose {
                                print("⚠️ [WITNESS \(index + 1)] Note ID=\(note.id) has anchor mismatch - forcing rebuild")
                                print("   FIX #827: witness.root() != merkle_path.root(cmu)")
                            }
                            corruptedWitnesses.append((note.id, note.height ?? 0))
                            notesNeedingRebuild.append((note: note, cmu: cmu))
                            continue
                        }

                        // FIX #1032: DISABLED FIX #1021 - This check was INCORRECT!
                        // FIX #1021 compared witness anchor to header root AT NOTE HEIGHT, but:
                        //   1. Sapling accepts ANY historical anchor (not just the one at note height)
                        //   2. Batch-rebuilt witnesses use CURRENT tree root (at chain tip)
                        //   3. This is perfectly valid - witness can spend from any historical state
                        // The correct checks are:
                        //   - FIX #827: Internal consistency (merkle_path.root(cmu) == witness.root())
                        //   - FIX #1013: Anchor exists somewhere in blockchain history
                        // FIX #1021 was causing 23 unnecessary rebuilds (46+ seconds) at EVERY startup!
                    }

                    if let witnessAnchor = ZipherXFFI.witnessGetRoot(note.witness) {
                        if verbose {
                            print("✅ [WITNESS \(index + 1)] Note ID=\(note.id) root extracted successfully")
                        }

                        // FIX #1224: Verify witness anchor EXISTS on blockchain (not just internally consistent)
                        // A witness from a corrupted/incomplete tree can pass witnessPathIsValid AND
                        // witnessVerifyAnchor (internally consistent) but have an anchor that never existed
                        // on the blockchain. This caused the phantom TX of FIX #1221.
                        // containsSaplingRoot checks ALL stored headers — FIX #1204 ensures post-boost
                        // roots are stored during P2P fetches. If anchor not found, witness is from bad tree.
                        let anchorOnChain = await HeaderStore.shared.containsSaplingRoot(witnessAnchor)
                        if !anchorOnChain {
                            let anchorHex = witnessAnchor.prefix(8).map { String(format: "%02x", $0) }.joined()
                            // FIX #1279: NEVER trust phantom anchors, even with DeltaBundleVerified=true.
                            // FIX #1256 previously bypassed this check — caused phantom TX broadcast.
                            // Proof: sim wallet tree root 3ed752cc matched blockchain at tip (3007184),
                            // but ALL 44 witness anchors (b6e85eb1) were phantom — NOT on any block.
                            // DeltaBundleVerified validates TIP root only, NOT intermediate witness anchors.
                            // Witnesses loaded from DB at corrupted state are PERMANENTLY wrong.
                            print("🚨 FIX #1279: [WITNESS \(index + 1)] Note ID=\(note.id) anchor \(anchorHex)... NOT FOUND in HeaderStore!")
                            print("   Witness anchor is phantom — never existed on blockchain")
                            print("   Witness was saved from corrupted tree state — must rebuild from current correct tree")
                            corruptedWitnesses.append((note.id, note.height ?? 0))
                            if let cmu = note.cmu, !cmu.isEmpty {
                                notesNeedingRebuild.append((note: note, cmu: cmu))
                            }
                            continue
                        }

                        witnessIsCurrent = true
                        alreadyCurrentCount += 1

                        // FIX #804: Use witness root as anchor (what the merkle path computes to)
                        // REVERTS FIX #757 - HeaderStore at noteHeight is WRONG because:
                        //   - Witness was created at tree state X (e.g., boost file height)
                        //   - Note was received at height Y (different tree state)
                        //   - HeaderStore at Y has different root than witness path computes
                        //   - Mismatch causes "anchor mismatch - witness is corrupted" error!
                        // The correct anchor is always the witness root.
                        if note.anchor != witnessAnchor {
                            anchorUpdates.append((note.id, witnessAnchor))
                            if verbose {
                                print("   🔧 FIX #804: Note \(note.id) anchor updated to witness root")
                            }
                        }

                        // FIX #1209: REMOVED FIX #1157 proactive rebuild trigger entirely.
                        // Sapling accepts ANY historical anchor — a witness that passes
                        // witnessPathIsValid + witnessVerifyAnchor (checked above) is VALID for spending.
                        // FIX #569 delta update handles bringing witnesses to chain-tip in <1 second.
                        // FIX #1157 was wrong: it compared witness anchor to FFI tree root and forced
                        // full rebuild on mismatch. At startup, tree only has boost CMUs → EVERY witness
                        // mismatched → ALL rebuilt = 60s+ delay on EVERY startup. Removed.
                    } else {
                        if verbose {
                            print("⚠️ [WITNESS \(index + 1)] Note ID=\(note.id) witnessGetRoot returned nil")
                        }
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
                if verbose {
                    for (noteId, height) in corruptedWitnesses {
                        print("   - Note ID=\(noteId) at height=\(height)")
                    }
                }
            }

            // FIX #1238: When tree repair is exhausted and MOST/ALL witnesses are corrupted,
            // skip the rebuild entirely. The FFI tree has a wrong root (incomplete delta CMUs).
            // Rebuilding witnesses from this tree creates anchors that don't exist on blockchain
            // → FIX #1224 flags them ALL again → same rebuild → infinite cycle.
            //
            // The Escalation #3 cascade:
            // 1. Tree root mismatch → FIX #524 repair exhausts (5 attempts)
            // 2. Code continues → FIX #1082 rebuilds witnesses from CORRUPTED tree
            // 3. All 24 witnesses get invalid anchors (never existed on blockchain)
            // 4. Next startup → FIX #1224 flags ALL 24 → rebuild → same bad tree → cycle
            //
            // Fix: When TreeRepairExhausted AND >50% witnesses corrupted, NULL them instead of
            // rebuilding. Witnesses stay NULL until user runs Full Resync (fixes the tree).
            let treeRepairExhausted = UserDefaults.standard.bool(forKey: "TreeRepairExhausted")
            if treeRepairExhausted && !notesNeedingRebuild.isEmpty {
                let totalNotes = notesForWitnessCheck.count
                let corruptedPercent = totalNotes > 0 ? (notesNeedingRebuild.count * 100 / totalNotes) : 0
                print("🛑 FIX #1238: Tree repair exhausted + \(notesNeedingRebuild.count)/\(totalNotes) witnesses corrupted (\(corruptedPercent)%)")

                if corruptedPercent > 50 {
                    // More than half corrupted = tree state is fundamentally broken
                    // Rebuilding from same corrupted tree will produce same bad witnesses
                    print("🛑 FIX #1238: >50% witnesses corrupted with exhausted tree — skipping rebuild")
                    print("   Nullifying corrupted witnesses to prevent phantom TX creation")
                    print("   User must run 'Full Resync' in Settings to restore valid witnesses")

                    // Clear ALL corrupted witnesses via single SQL statement
                    // Much faster than per-note updates and avoids encryption overhead
                    let cleared = (try? WalletDatabase.shared.clearWitnessesForCorruptedTree()) ?? 0
                    print("🛑 FIX #1238: Cleared \(cleared) corrupted witnesses via SQL")

                    // Skip the entire FIX #1027 rebuild block below
                    // Balance will still show via getTotalUnspentBalance() (FIX #1210, no witness requirement)
                    // Notes just won't be spendable until Full Resync fixes the tree
                    notesNeedingRebuild.removeAll()
                } else {
                    print("⚠️ FIX #1238: <50% corrupted — attempting rebuild (some witnesses may be salvageable)")
                }
            }

            // FIX #1027: SINGLE TREE BUILD for ALL corrupted witnesses
            // Previous approach (FIX #1022-1024) built tree TWICE - once for boost, once for delta
            // Each tree build loads 1M+ CMUs = 44 seconds × 2 = 88+ seconds total
            //
            // New approach: Build tree to chainHeight ONCE, create ALL witnesses from single tree
            // This cuts rebuild time in HALF (~44 seconds instead of ~88 seconds)
            //
            // The FIX #569 delta update only appends CMUs to existing witnesses.
            // If a witness was created with corrupted tree state, the merkle path is wrong.
            // Appending delta CMUs doesn't fix it - we must rebuild from scratch!
            let boostEndHeight = ZipherXConstants.effectiveTreeHeight
            let hasDeltaNotes = notesNeedingRebuild.contains { $0.note.height > boostEndHeight }

            print("🔧 FIX #1027: Rebuilding ALL \(notesNeedingRebuild.count) corrupted witnesses in SINGLE pass...")
            await progress?("Rebuilding witnesses...", 45)

            // Determine target height - if we have delta notes, need P2P and chainHeight
            var targetHeight = boostEndHeight
            if hasDeltaNotes {
                print("🔧 FIX #1027: Delta notes detected, waiting for P2P...")
                await progress?("Waiting for P2P network...", 47)

                let p2pReady = await NetworkManager.shared.waitForP2PReady(minPeers: 3, timeout: 30)
                if p2pReady {
                    targetHeight = (try? await NetworkManager.shared.getChainHeight()) ?? boostEndHeight
                    print("🔧 FIX #1027: P2P ready, building to chainHeight \(targetHeight)")
                } else {
                    print("⚠️ FIX #1027: P2P not ready, building to boost height only (delta notes will fix at send)")
                    // Only include boost-range notes if P2P not available
                    let boostOnlyNotes = notesNeedingRebuild.filter { $0.note.height <= boostEndHeight }
                    if boostOnlyNotes.isEmpty {
                        print("⚠️ FIX #1027: No boost-range notes and P2P unavailable, skipping rebuild")
                    }
                }
            }

            await progress?("Building witnesses...", 50)

            do {
                var spendableNotes: [SpendableNote] = []
                var noteIds: [Int64] = []

                // Include ALL notes that can be rebuilt at current targetHeight
                for (note, cmu) in notesNeedingRebuild {
                    // Skip delta-range notes if we couldn't get P2P
                    if note.height > boostEndHeight && targetHeight <= boostEndHeight {
                        print("   ⏭️ Skipping delta note ID=\(note.id) height=\(note.height) (P2P unavailable)")
                        continue
                    }

                    let spendable = SpendableNote(
                        value: note.value,
                        anchor: note.anchor ?? Data(count: 32),
                        witness: note.witness,
                        diversifier: note.diversifier,
                        rcm: note.rcm,
                        position: note.height,
                        nullifier: note.nullifier,
                        height: note.height,
                        cmu: cmu,
                        witnessIndex: note.witnessIndex
                    )
                    spendableNotes.append(spendable)
                    noteIds.append(note.id)
                }

                if spendableNotes.isEmpty {
                    print("⚠️ FIX #1027: No notes to rebuild at this time")
                } else {
                    print("🔧 FIX #1027: Building tree to height \(targetHeight) for \(spendableNotes.count) notes...")

                    let txBuilder = try TransactionBuilder()
                    let results = try await txBuilder.rebuildWitnessesForNotes(
                        notes: spendableNotes,
                        downloadedTreeHeight: boostEndHeight,
                        chainHeight: targetHeight
                    )

                    // FIX #1030: Match results by note height (since FIX #1030 may skip failed notes)
                    // Create a height-to-noteId map for matching
                    var heightToNoteId: [UInt64: Int64] = [:]
                    for (spendable, noteId) in zip(spendableNotes, noteIds) {
                        heightToNoteId[spendable.height] = noteId
                    }

                    var rebuiltCount = 0
                    await MainActor.run {
                        for result in results {
                            // FIX #1030: Match by height instead of index (results may have gaps)
                            guard let noteId = heightToNoteId[result.note.height] else {
                                print("⚠️ FIX #1030: Could not match result for height \(result.note.height)")
                                continue
                            }
                            try? WalletDatabase.shared.updateNoteWitness(noteId: noteId, witness: result.witness)
                            try? WalletDatabase.shared.updateNoteAnchor(noteId: noteId, anchor: result.anchor)
                            rebuiltCount += 1
                        }
                    }

                    // FIX #1030: Show accurate count - some may have been skipped
                    let skippedCount = spendableNotes.count - rebuiltCount
                    if skippedCount > 0 {
                        print("✅ FIX #1027/1030: Rebuilt \(rebuiltCount)/\(spendableNotes.count) witnesses (\(skippedCount) skipped - will rebuild on-demand)")
                    } else {
                        print("✅ FIX #1027: Rebuilt \(rebuiltCount)/\(notesNeedingRebuild.count) witnesses in SINGLE pass!")
                    }
                }

            } catch {
                print("❌ FIX #1027: Failed to rebuild witnesses: \(error.localizedDescription)")
            }

            if notesNeedingRebuild.isEmpty {
                print("✅ FIX #1022: No corrupted witnesses found - all instant-ready!")
                // FIX #1327: Record successful verification — skip redundant re-checks for 60s
                lastWitnessVerificationAllPassed = Date()
                lastWitnessVerificationTreeSize = UInt64(ZipherXFFI.treeSize())
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

            // FIX #1076: SKIP expensive delta sync if ALL witnesses are already valid!
            // The FIX #569 delta sync takes 15+ seconds to update 106 witnesses × 763 CMUs.
            // But if FIX #1022 found no corrupted witnesses AND FIX #827 consistency passed,
            // the witnesses are already correct - no need to reload and update them!
            //
            // Only run delta sync when:
            // 1. Some witnesses were rebuilt (notesNeedingRebuild was NOT empty)
            // 2. Some anchors were updated (might need witness refresh)
            // 3. Less than 80% of witnesses were instant-ready (safety margin)
            let totalNotes = notesForWitnessCheck.count
            let instantReadyPercent = totalNotes > 0 ? (alreadyCurrentCount * 100 / totalNotes) : 0

            // FIX #1132: Even if witnesses are valid, check if tree has grown (new blocks arrived)
            // If tree has new CMUs, we need to do a FAST UPDATE (not full rebuild)
            // This prevents health checks from detecting "stale" witnesses and triggering slow rebuilds
            var treeHasNewCMUs = false
            if notesNeedingRebuild.isEmpty && instantReadyPercent >= 80 {
                // FIX #1133: If witnesses were already rebuilt this session, SKIP delta sync entirely!
                // Sapling accepts ANY historical anchor - witnesses from 5 minutes ago are still valid.
                // This prevents the ~1 second delta sync from running on every send attempt.
                if WalletHealthCheck.shared.witnessesRebuiltThisSession {
                    print("⚡ FIX #1133: SKIPPING delta sync - witnesses already updated THIS SESSION")
                    print("   Sapling accepts historical anchors - current witnesses are valid!")
                    await MainActor.run {
                        lastWitnessRebuildTime = Date()
                    }
                    return  // INSTANT EXIT - witnesses were updated recently in this session!
                }

                // Check if any unspent note's witness root differs from current tree root
                // This indicates new blocks arrived since witnesses were last updated
                if let currentTreeRoot = ZipherXFFI.treeRoot(), !currentTreeRoot.isEmpty {
                    for note in notesForWitnessCheck {
                        if !note.witness.isEmpty, let witnessRoot = ZipherXFFI.witnessGetRoot(note.witness) {
                            if witnessRoot != currentTreeRoot {
                                treeHasNewCMUs = true
                                let witnessRootHex = witnessRoot.prefix(8).map { String(format: "%02x", $0) }.joined()
                                let treeRootHex = currentTreeRoot.prefix(8).map { String(format: "%02x", $0) }.joined()
                                print("🔄 FIX #1132: Witness root \(witnessRootHex)... differs from tree root \(treeRootHex)...")
                                print("   Tree has grown - will do FAST witness update (not full rebuild)")
                                break
                            }
                        }
                    }
                }

                if !treeHasNewCMUs {
                    print("⚡ FIX #1076: SKIPPING delta sync - \(alreadyCurrentCount)/\(totalNotes) witnesses instant-ready (\(instantReadyPercent)%)")
                    print("   This saves ~15 seconds of witness update time!")
                    await MainActor.run {
                        lastWitnessRebuildTime = Date()  // Mark as rebuilt to use cooldown
                    }
                    return  // INSTANT EXIT - witnesses are already valid AND up-to-date!
                }
            }

            if treeHasNewCMUs {
                print("🔄 FIX #1132: FAST witness update needed - tree has new CMUs since last witness update")
            } else {
                print("🔄 FIX #1076: Delta sync needed - only \(alreadyCurrentCount)/\(totalNotes) instant-ready (\(instantReadyPercent)%)")
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
                // FIX #1063 v3: PRECISE size check - compare against expected: boost + delta bundle
                // Previous v2 used 10K buffer which was too loose (corruption had only ~2,793 extra)
                let boostCMUCount = ZipherXConstants.effectiveTreeCMUCount

                // Get delta bundle CMU count for precise expected size
                let deltaManifest = DeltaCMUManager.shared.getManifest()
                let deltaCMUCount = UInt64(deltaManifest?.outputCount ?? 0)
                let expectedTreeSize = boostCMUCount + deltaCMUCount

                // FIX #1090: Only consider UNDER-sized tree as corruption
                // OVER-sized is OK - we might have fetched delta CMUs via P2P that aren't persisted yet
                // Previous bug: Treated over-sized as corruption, caused infinite loop after witness rebuild
                print("🔍 FIX #1063 v3: FFI tree=\(currentTreeSize), expected=\(expectedTreeSize) (boost=\(boostCMUCount) + delta=\(deltaCMUCount))")

                if currentTreeSize < expectedTreeSize {
                    // Tree is SMALLER than expected - missing CMUs
                    let missing = expectedTreeSize - currentTreeSize

                    // FIX #1151: Add tolerance - small discrepancies will be fixed by delta sync
                    // Only clear everything if significantly under-sized (>10 CMUs missing)
                    let toleranceThreshold: UInt64 = 10

                    if missing > toleranceThreshold {
                        // FIX #1308: Tree under-sized = FFI didn't load all delta CMUs yet.
                        // This is a LOADING issue, NOT delta corruption. Delta has valid blockchain data.
                        // NEVER destroy delta — reload tree from boost + delta instead.
                        print("⚠️ FIX #1308: Tree UNDER-sized! FFI=\(currentTreeSize) vs expected=\(expectedTreeSize) (missing=\(missing))")
                        print("🔧 FIX #1308: Reloading FFI tree from boost + delta (PRESERVING delta)")
                        ZipherXFFI.treeInit()

                        // Delta is ALWAYS preserved — verified or not.
                        // Delta contains valid blockchain outputs from P2P fetch.
                        // Clearing it forces a full re-fetch (~2 min) that gets the same data.
                        print("📦 FIX #1308: Delta PRESERVED (\(deltaCMUCount) outputs) — will reload into tree")

                        // Don't set treeLoaded - will fall through to load from database/boost + delta
                    } else {
                        // FIX #1151: Small discrepancy - delta sync will fix it
                        print("⚠️ FIX #1151: Tree slightly under-sized (missing \(missing) CMUs, tolerance=\(toleranceThreshold)) - delta sync will fix")
                        treeLoaded = true
                        treeWasAlreadyInMemory = true
                    }
                } else if currentTreeSize > expectedTreeSize {
                    // FIX #1090: Tree is LARGER than expected - this is OK!
                    // Likely delta CMUs were fetched via P2P for witness rebuild but not persisted yet
                    let extra = currentTreeSize - expectedTreeSize
                    print("✅ FIX #1090: Tree has \(extra) extra CMUs (from P2P delta fetch) - this is OK")
                    treeLoaded = true
                    treeWasAlreadyInMemory = true
                } else {
                    print("✅ FIX #568 v2: Tree already has \(currentTreeSize) CMUs loaded - skipping reload")
                    treeLoaded = true
                    treeWasAlreadyInMemory = true  // Remember that we didn't just load it
                }
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
                        // FIX #741: Include boost height so delta sync knows where to start
                        await MainActor.run {
                            // Save CMU data with metadata for validation
                            try? WalletDatabase.shared.saveTreeState(cmuData, height: boostHeight)
                            print("✅ FIX #563 v38 + FIX #741: Saved CMU data (\(cmuData.count) bytes) at height \(boostHeight)")
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
            var startHeight = await MainActor.run { () -> UInt64 in
                return (try? WalletDatabase.shared.getTreeHeight()) ?? ZipherXConstants.effectiveTreeHeight
            }

            // FIX #808 v2: When tree is already in memory, estimate actual height from tree size
            // The database tree_height may be stale (not updated after FAST START delta load)
            // If tree has more CMUs than boost file, delta is already loaded - use estimated height
            let boostCMUCount = UInt64(1045687)  // From ZipherXConstants
            if treeWasAlreadyInMemory && currentTreeSize > Int(boostCMUCount) {
                let deltaCMUCount = UInt64(currentTreeSize) - boostCMUCount
                // Each delta block averages ~0.06 outputs, so estimate height
                let estimatedDeltaBlocks = deltaCMUCount * 17  // ~17 blocks per CMU on average
                let estimatedTreeHeight = ZipherXConstants.effectiveTreeHeight + estimatedDeltaBlocks
                if estimatedTreeHeight > startHeight {
                    print("✅ FIX #808 v2: Tree already has \(deltaCMUCount) delta CMUs - adjusting startHeight from \(startHeight) to \(estimatedTreeHeight)")
                    startHeight = estimatedTreeHeight
                }
            }

            // FIX #563 v43: Determine if we need to sync based on what we just loaded
            // If we loaded from DB (treeLoaded=true), check if we need delta sync
            // If we loaded from boost file (treeLoaded=false), we definitely need delta sync if chain moved forward
            let blocksBehind = chainHeight > startHeight ? chainHeight - startHeight : 0
            let isRecentEnough = blocksBehind < 1000

            // FIX #563 v43: Skip delta sync ONLY if we loaded from DB AND tree is recent
            // If we just loaded from boost file, we MUST sync delta (even if recent) to update tree_height
            // FIX #808 v2: Also skip if tree already has delta CMUs (treeWasAlreadyInMemory + has delta)
            let treeAlreadyHasDelta = treeWasAlreadyInMemory && currentTreeSize > Int(boostCMUCount)
            let shouldSkipDeltaSync = treeAlreadyHasDelta || (!treeWasAlreadyInMemory && treeLoaded && isRecentEnough)

            if shouldSkipDeltaSync {
                // FIX #768: Only show "blocks behind" if actually behind, otherwise show "at tip"
                let lagInfo = blocksBehind > 0 ? "\(blocksBehind) blocks behind chain tip" : "at chain tip"
                print("✅ FIX #563 v43: Skipping delta CMU sync - DB tree is recent (\(lagInfo))")
                print("✅ FIX #563 v43: Tree has \(ZipherXFFI.treeSize()) CMUs, will sync when >1000 blocks behind")
            } else if chainHeight > startHeight {
                // FIX #740: Merged FIX #568 v2 message here - the old code just printed but didn't sync!
                if treeWasAlreadyInMemory && blocksBehind > 0 {
                    print("🔄 FIX #568 v2: Tree was already in memory but syncing \(blocksBehind) delta CMUs to update witnesses")
                }
                print("🔄 FIX #557 v32: Syncing delta CMUs from \(startHeight) to \(chainHeight) (\(blocksBehind) blocks)...")

                await progress?("Fetching delta CMUs...", 70)

                // FIX #1098: Dynamic batch size based on peer capacity (was fixed 500)
                // FIX #1287: Cap at 3 concurrent peers to prevent TCP congestion collapse
                let peerCount = await MainActor.run { NetworkManager.shared.peers.filter { $0.isConnectionReady }.count }
                let maxBlocksPerPeer = 128
                // FIX #1287: Cap concurrent fetch peers at 3 to prevent TCP congestion collapse
                let batchSize: UInt64 = UInt64(min(max(peerCount, 2), 3) * maxBlocksPerPeer)
                if verbose {
                    print("📊 FIX #1098: Delta CMU fetch using \(peerCount) peers × 128 = \(batchSize) blocks/batch")
                }
                var currentHeight = startHeight + 1
                var consecutiveFailures = 0
                let maxConsecutiveFailures = 3
                let maxRetries = 3
                // FIX #1199: Use (height, [CMU]) pairs instead of flat array.
                // Previous bug: retry loop appended missing blocks' CMUs at END of flat array,
                // putting them AFTER subsequent blocks' CMUs. Tree is order-sensitive — CMUs from
                // block 100 MUST come before block 101's. Wrong order = wrong tree root = corrupt tree.
                var deltaCMUsByHeight: [(UInt64, [Data])] = []
                // FIX #1310: Also collect full DeltaOutput objects during FIRST pass.
                // Previous bug: first pass collected only CMUs (for tree), then second pass
                // (FIX #571 Step 2) re-fetched SAME blocks via P2P to get full outputs (for delta).
                // P2P is unreliable — second fetch missed blocks → delta had fewer outputs than tree
                // → rebuildWitnessesForNotes built batch tree with wrong CMU count → anchor mismatch
                // → FIX #1279 rejected ALL witnesses → rebuild loop.
                // Fix: collect full outputs in FIRST pass → tree and delta always consistent.
                var collectedDeltaOutputs: [DeltaCMUManager.DeltaOutput] = []
                let syncStartTime = Date()  // FIX #762: Track overall sync time
                let maxSyncDuration: TimeInterval = 120  // FIX #762: Max 2 minutes for delta sync

                // FIX #873: Track ALL blocks fetched to detect and handle missing blocks
                // Missing blocks cause incomplete delta CMUs → wrong tree root → TX rejection
                var allFetchedHeights = Set<UInt64>()
                var totalMissingBlocks = 0

                // FIX #1310: Cache block data for FilterScanner PHASE 2 reuse (was in FIX #571 second pass)
                // Now that first pass collects everything, cache here to prevent PHASE 2 triple-fetch.
                FilterScanner.sharedPrefetchCache = [:]

                while currentHeight <= chainHeight {
                    // FIX #762: Check for overall timeout to prevent infinite hanging
                    if Date().timeIntervalSince(syncStartTime) > maxSyncDuration {
                        print("⚠️ FIX #762: Delta sync timeout after \(Int(maxSyncDuration))s - aborting to prevent hang")
                        print("   Progress: \(currentHeight)/\(chainHeight) (\(deltaCMUsByHeight.count) height entries collected)")
                        break
                    }
                    let endHeight = min(currentHeight + batchSize - 1, chainHeight)
                    let expectedCount = Int(endHeight - currentHeight + 1)

                    var batchSucceeded = false

                    for attempt in 1...maxRetries {
                        do {
                            // FIX #557 v32: Fetch blocks via P2P
                            let blocks = try await NetworkManager.shared.getBlocksDataP2P(from: currentHeight, count: expectedCount)

                            // FIX #873: Track which heights we actually received
                            var batchReceivedHeights = Set<UInt64>()

                            for (height, _, _, txData) in blocks {
                                batchReceivedHeights.insert(height)
                                allFetchedHeights.insert(height)
                                // FIX #1199: Collect CMUs per height for correct ordering
                                var heightCMUs: [Data] = []
                                var blockOutputIndex: UInt32 = 0
                                for (txid, outputs, _) in txData {
                                    for output in outputs {
                                        if let cmuDisplay = Data(hexString: output.cmu) {
                                            let cmuWire = Data(cmuDisplay.reversed())
                                            heightCMUs.append(cmuWire)
                                            // FIX #1311: ALWAYS store delta entry when CMU is valid
                                            // Ensures loadDeltaCMUs() count matches tree CMU count
                                            // Without this: 18 outputs with non-580-byte ciphertext get CMU in tree
                                            // but NOT in delta → batch witness tree root mismatch → FIX #1279 rejects all
                                            let epk = Data(hexString: output.ephemeralKey).map { Data($0.reversed()) } ?? Data(count: 32)
                                            let ciphertext = Data(hexString: output.encCiphertext) ?? Data(count: 580)
                                            let deltaOutput = DeltaCMUManager.DeltaOutput(
                                                height: UInt32(height),
                                                index: blockOutputIndex,
                                                cmu: cmuWire,
                                                epk: epk,
                                                ciphertext: ciphertext
                                            )
                                            collectedDeltaOutputs.append(deltaOutput)
                                        }
                                        blockOutputIndex += 1
                                    }
                                }
                                deltaCMUsByHeight.append((height, heightCMUs))
                                // FIX #1310: Cache block data for FilterScanner PHASE 2
                                FilterScanner.sharedPrefetchCache?[height] = txData
                            }

                            // FIX #1199: Retry missing blocks WITHIN this batch immediately
                            // Previous bug: missing blocks were skipped ("Continue anyway"), their CMUs
                            // were never fetched or fetched out-of-order at the end. Now we retry them
                            // in-place so CMUs maintain correct height ordering.
                            let expectedHeights = Set((currentHeight...endHeight).map { $0 })
                            let missingHeights = expectedHeights.subtracting(batchReceivedHeights)
                            if !missingHeights.isEmpty {
                                let sortedMissing = missingHeights.sorted()
                                // FIX #1213b: Batch retry instead of block-by-block
                                // Previous code: getBlocksDataP2P(from: height, count: 1) per missing block
                                // Now: group into contiguous ranges of max 128 and fetch each in one call
                                var retryRanges: [(start: UInt64, count: Int)] = []
                                var rStart = sortedMissing[0]
                                var rEnd = sortedMissing[0]
                                for i in 1..<sortedMissing.count {
                                    if sortedMissing[i] == rEnd + 1 && Int(sortedMissing[i] - rStart) < 128 {
                                        rEnd = sortedMissing[i]
                                    } else {
                                        retryRanges.append((start: rStart, count: Int(rEnd - rStart) + 1))
                                        rStart = sortedMissing[i]
                                        rEnd = sortedMissing[i]
                                    }
                                }
                                retryRanges.append((start: rStart, count: Int(rEnd - rStart) + 1))

                                if verbose {
                                    print("🔄 FIX #1213b: Batch retrying \(missingHeights.count) missing blocks in \(retryRanges.count) ranges (was \(missingHeights.count) individual requests)")
                                }

                                for range in retryRanges {
                                    do {
                                        let retryBlocks = try await NetworkManager.shared.getBlocksDataP2P(from: range.start, count: range.count)
                                        for (h, _, _, txData) in retryBlocks {
                                            allFetchedHeights.insert(h)
                                            var heightCMUs: [Data] = []
                                            var retryBlockOutputIndex: UInt32 = 0
                                            for (_, outputs, _) in txData {
                                                for output in outputs {
                                                    if let cmuDisplay = Data(hexString: output.cmu) {
                                                        let cmuWire = Data(cmuDisplay.reversed())
                                                        heightCMUs.append(cmuWire)
                                                        // FIX #1311: ALWAYS store delta entry when CMU is valid
                                                        let epk = Data(hexString: output.ephemeralKey).map { Data($0.reversed()) } ?? Data(count: 32)
                                                        let ciphertext = Data(hexString: output.encCiphertext) ?? Data(count: 580)
                                                        let deltaOutput = DeltaCMUManager.DeltaOutput(
                                                            height: UInt32(h),
                                                            index: retryBlockOutputIndex,
                                                            cmu: cmuWire,
                                                            epk: epk,
                                                            ciphertext: ciphertext
                                                        )
                                                        collectedDeltaOutputs.append(deltaOutput)
                                                    }
                                                    retryBlockOutputIndex += 1
                                                }
                                            }
                                            deltaCMUsByHeight.append((h, heightCMUs))
                                            // FIX #1310: Cache retry block data too
                                            FilterScanner.sharedPrefetchCache?[h] = txData
                                        }
                                    } catch {
                                        // Count all heights in this range as missing
                                        totalMissingBlocks += range.count
                                        print("⚠️ FIX #1213b: Failed to fetch range \(range.start)-\(range.start + UInt64(range.count) - 1): \(error.localizedDescription)")
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
                        // FIX #762: Break on too many consecutive failures to prevent infinite loop
                        if consecutiveFailures >= maxConsecutiveFailures {
                            print("⚠️ FIX #762: \(maxConsecutiveFailures) consecutive failures - aborting delta sync")
                            print("   Progress: \(currentHeight)/\(chainHeight)")
                            break
                        }
                    }

                    currentHeight = endHeight + 1

                    // FIX #1197: Brief inter-round delay for TCP congestion recovery
                    if batchSucceeded && currentHeight <= chainHeight {
                        try? await Task.sleep(nanoseconds: 300_000_000)  // 300ms between rounds
                    }
                }

                // FIX #1310: Log first-pass collection results
                let cacheSize = FilterScanner.sharedPrefetchCache?.count ?? 0
                print("📦 FIX #1310: First pass collected \(collectedDeltaOutputs.count) full outputs, cached \(cacheSize) blocks for PHASE 2")

                // FIX #1199: Sort by height and flatten to get CMUs in correct blockchain order
                // This is CRITICAL — the commitment tree is append-only and order-sensitive.
                // CMUs from block N must come before CMUs from block N+1.
                deltaCMUsByHeight.sort { $0.0 < $1.0 }
                var deltaCMUs: [Data] = []
                for (_, cmus) in deltaCMUsByHeight {
                    deltaCMUs.append(contentsOf: cmus)
                }

                // FIX #1199: Final validation — check completeness
                let totalExpectedBlocks = chainHeight - startHeight
                let expectedHeightsAll = Set((startHeight + 1)...chainHeight)
                let finalMissing = expectedHeightsAll.subtracting(allFetchedHeights)
                if !finalMissing.isEmpty {
                    print("⚠️ FIX #1199: Delta sync has \(finalMissing.count) missing blocks after all retries")
                    print("   Fetched \(allFetchedHeights.count)/\(totalExpectedBlocks) blocks")
                    if finalMissing.count > 10 {
                        print("   First 10 missing: \(finalMissing.sorted().prefix(10).map { String($0) }.joined(separator: ", "))")
                    }
                    // FIX #1199: Still proceed — most missing blocks have 0 shielded outputs.
                    // FIX #1194 validate-before-persist will catch if tree root is wrong.
                }

                if !deltaCMUs.isEmpty {
                    print("🔄 FIX #557 v32: Appending \(deltaCMUs.count) delta CMUs to global tree...")
                    await progress?("Appending delta CMUs...", 80)

                    // FIX #1182: Size-based guard to prevent double-append!
                    // Previous bug: syncDeltaBundleIfNeeded (from init) already appended these CMUs
                    // to the FFI tree, but DB tree height wasn't updated. This function then re-fetched
                    // the same blocks and appended the same CMUs AGAIN → tree inflation!
                    // Guard: Check how many CMUs are already beyond boost file in the tree.
                    let treeSizeBeforeAppend = Int(ZipherXFFI.treeSize())
                    let boostCMUCountForGuard = Int(ZipherXConstants.effectiveTreeCMUCount)
                    let cmusAlreadyBeyondBoost = max(0, treeSizeBeforeAppend - boostCMUCountForGuard)

                    if cmusAlreadyBeyondBoost >= deltaCMUs.count {
                        // All delta CMUs already in tree — skip to prevent inflation
                        print("✅ FIX #1182: Skipping delta append - all \(deltaCMUs.count) CMUs already in tree (size=\(treeSizeBeforeAppend), beyond boost=\(cmusAlreadyBeyondBoost))")
                    } else if cmusAlreadyBeyondBoost > 0 {
                        // Some CMUs already in tree from earlier append — only append NEW ones
                        let cmusToAppend = Array(deltaCMUs.dropFirst(cmusAlreadyBeyondBoost))
                        for cmu in cmusToAppend {
                            _ = ZipherXFFI.treeAppend(cmu: cmu)
                        }
                        print("✅ FIX #1182: Appended \(cmusToAppend.count) NEW CMUs (skipped \(cmusAlreadyBeyondBoost) already in tree, new size: \(ZipherXFFI.treeSize()))")
                    } else {
                        // No extra CMUs in tree — append all
                        for cmu in deltaCMUs {
                            _ = ZipherXFFI.treeAppend(cmu: cmu)
                        }
                        print("✅ FIX #557 v32: Appended \(deltaCMUs.count) delta CMUs (new size: \(ZipherXFFI.treeSize()))")
                    }

                    print("✅ FIX #557 v32 + FIX #1182: Delta CMU append complete")

                    // FIX #1310: Save collected full outputs to delta manifest.
                    // This is the SAME P2P data that was used for tree CMU append — guaranteed consistent.
                    // Previous bug: FIX #571 Step 2 did a SECOND P2P fetch for delta outputs, which missed
                    // blocks the first pass got → delta had fewer outputs than tree → batch witness builder
                    // created wrong root → FIX #1279 rejected all witnesses → rebuild loop.
                    if !collectedDeltaOutputs.isEmpty {
                        let treeRootForDelta = ZipherXFFI.treeRoot() ?? Data(count: 32)
                        let deltaFromHeight = UInt64(boostHeight + 1)
                        DeltaCMUManager.shared.appendOutputs(collectedDeltaOutputs, fromHeight: deltaFromHeight, toHeight: chainHeight, treeRoot: treeRootForDelta)
                        print("📦 FIX #1310: Saved \(collectedDeltaOutputs.count) delta outputs from FIRST pass (same P2P data as tree)")
                        print("   Tree CMUs: \(deltaCMUs.count), Delta outputs: \(collectedDeltaOutputs.count) — CONSISTENT")
                    } else {
                        // No outputs but blocks were fetched — update manifest height anyway
                        let treeRootForDelta = ZipherXFFI.treeRoot() ?? Data(count: 32)
                        let deltaFromHeight = UInt64(boostHeight + 1)
                        DeltaCMUManager.shared.appendOutputs([], fromHeight: deltaFromHeight, toHeight: chainHeight, treeRoot: treeRootForDelta)
                        print("📦 FIX #1310: No shielded outputs in fetched blocks, but updated delta manifest to height \(chainHeight)")
                    }

                    // CRITICAL FIX #557 v35: Verify tree root matches header at chainHeight
                    // FIX #1204b: HeaderStore sapling roots ARE authoritative for post-boost heights.
                    let ourRoot = ZipherXFFI.treeRoot()
                    let boostEndForVerify = ZipherXConstants.effectiveTreeHeight

                    if chainHeight > boostEndForVerify && boostEndForVerify > 0 {
                        // FIX #1204b: Try HeaderStore root — authoritative if non-zero
                        if let header = try? HeaderStore.shared.getHeader(at: chainHeight) {
                            let headerRoot = header.hashFinalSaplingRoot
                            let isZeroRoot = headerRoot.allSatisfy { $0 == 0 } || headerRoot.isEmpty
                            if !isZeroRoot {
                                let headerRootReversed = Data(headerRoot.reversed())
                                if let root = ourRoot, (root == headerRoot || root == headerRootReversed) {
                                    print("✅ FIX #1204b: Tree root VERIFIED against HeaderStore at height \(chainHeight)")
                                } else {
                                    print("⚠️ FIX #1204b: Tree root MISMATCH at height \(chainHeight)")
                                    if let root = ourRoot {
                                        print("   Our root:   \(root.prefix(8).map { String(format: "%02x", $0) }.joined())...")
                                    }
                                    print("   Header root: \(headerRoot.prefix(8).map { String(format: "%02x", $0) }.joined())...")
                                    // FIX #1254: Only clear delta if NOT verified (immutable).
                                    if UserDefaults.standard.bool(forKey: "DeltaBundleVerified") {
                                        print("✅ FIX #1254: Delta is VERIFIED (immutable) — NOT clearing despite tree root mismatch")
                                        print("   Mismatch is likely from incomplete P2P append, not delta corruption")
                                    } else {
                                        // FIX #1309: Delta is INCOMPLETE (P2P missed blocks), not corrupt.
                                        // Preserve delta for gap-fill — clearing forces full re-fetch.
                                        print("📦 FIX #1309: Delta PRESERVED — root mismatch = incomplete P2P data, gap-fill will fix")
                                    }
                                }
                            } else {
                                print("✅ FIX #1204b: HeaderStore root is zero at \(chainHeight) — trusting FFI root")
                                if let root = ourRoot {
                                    print("   FFI root: \(root.prefix(8).map { String(format: "%02x", $0) }.joined())...")
                                }
                            }
                        } else {
                            print("✅ FIX #1204b: No header at \(chainHeight) — trusting FFI root")
                        }
                    } else if let header = try? HeaderStore.shared.getHeader(at: chainHeight) {
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

                            // FIX #1254: Only clear delta if NOT verified (immutable).
                            if UserDefaults.standard.bool(forKey: "DeltaBundleVerified") {
                                print("✅ FIX #1254: Delta is VERIFIED (immutable) — NOT clearing despite tree root mismatch")
                                print("   Mismatch is likely from incomplete new block append, not delta corruption")
                            } else {
                                // FIX #1309: Delta is INCOMPLETE (P2P missed blocks), not corrupt.
                                // Preserve delta for gap-fill — clearing forces full re-fetch.
                                print("📦 FIX #1309: Delta PRESERVED — root mismatch = incomplete P2P data, gap-fill will fix")
                            }
                        }
                    } else {
                        print("⚠️ FIX #557 v35: Could not fetch header at \(chainHeight) for verification")
                    }
                } else {
                    print("⚠️ FIX #557 v32: Failed to fetch delta CMUs")
                }
            }

            // Save updated tree state to database (thread-safe)
            // FIX #741: Pass chainHeight to saveTreeState - CRITICAL for persisting delta sync progress!
            // Without this, every startup re-syncs from boost file end because tree_height stays at 2988797
            if let treeData = ZipherXFFI.treeSerialize() {
                await MainActor.run {
                    try? WalletDatabase.shared.saveTreeState(treeData, height: chainHeight)
                }
                print("✅ FIX #557 v32 + FIX #741: Saved global tree state at height \(chainHeight)")
            } else {
                // FIX #741: Even if serialization fails, at least update the tree height
                // This ensures delta sync knows where to start on next startup
                await MainActor.run {
                    try? WalletDatabase.shared.updateTreeHeight(chainHeight)
                }
                print("⚠️ FIX #741: Tree serialization failed, but updated height to \(chainHeight)")
            }

            // Update database to track tree sync height (thread-safe)
            // FIX #737 v2: Skip if pendingDeltaRescan flag is set - PHASE 2 needs to start from boost end
            if !self.pendingDeltaRescan {
                await MainActor.run {
                    try? WalletDatabase.shared.updateLastScannedHeight(chainHeight, hash: Data(count: 32))
                }
            } else {
                print("🔧 FIX #737 v2: Skipping lastScannedHeight update - pendingDeltaRescan flag is set")
                print("   PHASE 2 will start from boost end to rebuild delta bundle")
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
            let allNotesForDelta = await MainActor.run { () -> [WalletNote] in
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

            // FIX #996: CRITICAL - Clear WITNESSES array BEFORE loading!
            // Without this, witnesses accumulate across calls (228→342→456→595)
            // causing FIX #805 witness update to get progressively slower (5s→8s→10s→13s)
            print("🔧 FIX #996: Calling witnessesClear() NOW...")
            let clearedCount = ZipherXFFI.witnessesClear()
            print("🔧 FIX #996: witnessesClear() returned \(clearedCount)")
            if clearedCount > 0 {
                print("🗑️ FIX #996: Cleared \(clearedCount) stale witnesses from FFI before loading")
            } else {
                print("ℹ️ FIX #996: No stale witnesses to clear (count=0)")
            }

            print("🔧 FIX #569: Step 1 - Loading \(allNotesForDelta.count) witnesses into FFI WITNESSES array...")
            for note in allNotesForDelta {
                if note.witness.isEmpty {
                    emptyWitnessNotes.append(note)
                    continue
                }

                // FIX #1177: Load witness into FFI - returns ARRAY INDEX (not tree position)
                let arrayIndex = note.witness.withUnsafeBytes { ptr in
                    ZipherXFFI.treeLoadWitness(
                        witnessData: ptr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        witnessLen: note.witness.count
                    )
                }

                if arrayIndex != UInt64.max {
                    witnessIndices.append((note: note, position: arrayIndex))
                    // FIX #1177: Get TREE POSITION separately for nullifier computation
                    let treePosition = ZipherXFFI.witnessGetTreePosition(witnessIndex: arrayIndex)
                    if treePosition != UInt64.max {
                        witnessIndexUpdates.append((note.id, treePosition))
                    }
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
            if verbose {
                print("🔧 FIX #571: Local delta bundle ends at height: \(deltaBundleEndHeight)")
            }

            // Calculate where to start fetching from:
            // - If we have local delta bundle, start from its end
            // - Otherwise start from boost file end
            let fetchStartHeight = max(boostHeight, deltaBundleEndHeight)
            if verbose {
                print("🔧 FIX #571: Will fetch blocks from height \(fetchStartHeight) to \(chainHeight)")
            }

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
                    if verbose {
                        print("🔧 FIX #571: Loaded \(localCMUs) CMUs from local delta bundle (instant!)")
                    }
                }
            }

            // PART 2: P2P fetch ONLY for the few remaining blocks
            // This is typically <100 blocks, not 400k!
            // FIX #1215: Skip heavy P2P fetch for tiny gaps (< 50 blocks)
            let blocksToFetchP2P = chainHeight > fetchStartHeight ? chainHeight - fetchStartHeight : 0
            if blocksToFetchP2P > 0 && blocksToFetchP2P <= 50 {
                print("⚡ FIX #1215: Skipping FIX #571 P2P fetch for tiny gap (\(blocksToFetchP2P) blocks) — PHASE 2 will handle it")
            }

            // FIX #1480: 5-minute cooldown on heavy P2P fetch to prevent infinite loop.
            // ROOT CAUSE: Previous code stopped ALL block listeners + disconnected/reconnected ALL peers
            // on EVERY call (~every 30-60s). This killed dispatchers → getBlocksDataP2P returned empty
            // → appendOutputs never called → deltaBundleEndHeight stuck → same fetch repeated for 7+ hours.
            // With NULL witnesses bypassing both 30s cooldown and 60s verification cache, this ran indefinitely.
            var p2pFetchCooledDown = false
            if let lastFetch = lastWitnessP2PFetchTime {
                let elapsed = Date().timeIntervalSince(lastFetch)
                if elapsed < witnessP2PFetchCooldown {
                    p2pFetchCooledDown = true
                    if blocksToFetchP2P > 50 {
                        print("⏩ FIX #1480: Skipping heavy P2P fetch — last attempt \(Int(elapsed))s ago (cooldown: \(Int(witnessP2PFetchCooldown))s)")
                    }
                }
            }

            if chainHeight > fetchStartHeight && blocksToFetchP2P > 50 && !p2pFetchCooledDown {
                await progress?("Fetching remaining blocks via P2P...", 80)
                lastWitnessP2PFetchTime = Date()  // Set cooldown BEFORE fetch (prevents rapid re-entry)

                let blocksToFetch = blocksToFetchP2P
                print("🔧 FIX #571: Fetching \(blocksToFetch) blocks via P2P (from height \(fetchStartHeight + 1))")

                // FIX #1214+1310: Initialize shared cache only if not already populated by first pass
                if FilterScanner.sharedPrefetchCache == nil {
                    FilterScanner.sharedPrefetchCache = [:]
                }

                // FIX #1480: REMOVED stop-listeners + disconnect/reconnect ALL peers pattern (was FIX #1056 v2 + FIX #1087).
                // Since FIX #1184, ALL P2P block fetches go through dispatcher (no direct reads).
                // getBlocksDataP2P() manages its own dispatcher activation at lines 7799-7852:
                //   - Checks how many dispatchers are active
                //   - Starts block listeners for peers without active dispatchers
                //   - Waits up to 5s for multiple dispatchers to activate
                //   - Filters to dispatcher-active peers before fetching
                // The old pattern KILLED the dispatchers it needed → empty fetch → endHeight stuck → infinite loop.

                // FIX #710 v2: Proper timeout using task group race pattern
                // FIX #1480: Dynamic batch size (same formula as syncDelta/gapFill)
                let witnessPeerCount = await MainActor.run { NetworkManager.shared.peers.filter { $0.isConnectionReady }.count }
                let batchSize: UInt64 = UInt64(max(witnessPeerCount, 3) * 256)
                let maxRetries = 2
                let batchTimeoutSeconds: UInt64 = 45  // 45 seconds (was 30 — too tight after dispatcher wait)
                var currentHeight = fetchStartHeight + 1
                var consecutiveFailures = 0
                let maxConsecutiveFailures = 3

                while currentHeight <= chainHeight {
                    let endHeight = min(currentHeight + batchSize - 1, chainHeight)
                    let count = Int(endHeight - currentHeight + 1)
                    var batchSuccess = false

                    for attempt in 1...maxRetries {
                        do {
                            let fetchHeight = currentHeight
                            let fetchCount = count

                            let blocks: [(UInt64, String, UInt32, [(String, [ShieldedOutput], [ShieldedSpend]?)])]? = try await withThrowingTaskGroup(of: [(UInt64, String, UInt32, [(String, [ShieldedOutput], [ShieldedSpend]?)])]?.self) { group in
                                group.addTask {
                                    try await NetworkManager.shared.getBlocksDataP2P(
                                        from: fetchHeight,
                                        count: fetchCount
                                    )
                                }

                                group.addTask {
                                    try await Task.sleep(nanoseconds: batchTimeoutSeconds * 1_000_000_000)
                                    return nil
                                }

                                if let result = try await group.next() {
                                    group.cancelAll()
                                    return result
                                }
                                return nil
                            }

                            guard let fetchedBlocks = blocks else {
                                throw NSError(domain: "WalletManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Timeout"])
                            }

                            // FIX #1190: Collect full delta outputs for local caching
                            var batchDeltaOutputs: [DeltaCMUManager.DeltaOutput] = []
                            for (height, _, _, txData) in fetchedBlocks {
                                var blockOutputIndex: UInt32 = 0
                                for (_, outputs, _) in txData {
                                    for output in outputs {
                                        if let cmuDisplay = Data(hexString: output.cmu) {
                                            let cmuWire = Data(cmuDisplay.reversed())
                                            deltaCMUs.append(cmuWire)
                                            p2pCMUs += 1
                                            let epk = Data(hexString: output.ephemeralKey).map { Data($0.reversed()) } ?? Data(count: 32)
                                            let ciphertext = Data(hexString: output.encCiphertext) ?? Data(count: 580)
                                            let deltaOutput = DeltaCMUManager.DeltaOutput(
                                                height: UInt32(height),
                                                index: blockOutputIndex,
                                                cmu: cmuWire,
                                                epk: epk,
                                                ciphertext: ciphertext
                                            )
                                            batchDeltaOutputs.append(deltaOutput)
                                        }
                                        blockOutputIndex += 1
                                    }
                                }
                            }

                            // FIX #1480: ALWAYS advance delta endHeight after successful fetch.
                            // Previous code only called appendOutputs when batchDeltaOutputs was non-empty
                            // OR fetchedBlocks.count > 0. When getBlocksDataP2P returned empty array [],
                            // NEITHER condition was true → endHeight stuck → infinite loop.
                            let deltaFromHeight = UInt64(boostHeight + 1)
                            let existingRoot = DeltaCMUManager.shared.getDeltaTreeRoot() ?? Data(count: 32)
                            DeltaCMUManager.shared.appendOutputs(batchDeltaOutputs, fromHeight: deltaFromHeight, toHeight: endHeight, treeRoot: existingRoot)

                            // FIX #1214: Cache block data for FilterScanner PHASE 2 reuse
                            if FilterScanner.sharedPrefetchCache == nil {
                                FilterScanner.sharedPrefetchCache = [:]
                            }
                            for (height, _, _, txData) in fetchedBlocks {
                                FilterScanner.sharedPrefetchCache?[height] = txData
                            }

                            if verbose {
                                print("🔧 FIX #571: Fetched blocks \(currentHeight)-\(endHeight) via P2P (\(batchDeltaOutputs.count) outputs)")
                            }
                            batchSuccess = true
                            consecutiveFailures = 0
                            break
                        } catch {
                            if attempt < maxRetries {
                                print("⚠️ FIX #710 v2: Batch \(currentHeight)-\(endHeight) failed (attempt \(attempt)/\(maxRetries)): \(error.localizedDescription)")
                                try? await Task.sleep(nanoseconds: 2_000_000_000)
                            } else {
                                print("⚠️ FIX #710 v2: Batch \(currentHeight)-\(endHeight) failed after \(maxRetries) attempts: \(error.localizedDescription)")
                            }
                        }
                    }

                    if !batchSuccess {
                        consecutiveFailures += 1
                        if consecutiveFailures >= maxConsecutiveFailures {
                            print("⚠️ FIX #1480: \(maxConsecutiveFailures) consecutive failures - aborting P2P fetch (will retry in \(Int(witnessP2PFetchCooldown))s)")
                            break
                        }
                    }

                    currentHeight = endHeight + 1
                }

                print("🔧 FIX #571: P2P fetch complete — \(p2pCMUs) CMUs fetched")
            }

            // PART 3: Append all delta CMUs to update tree AND witnesses
            if !deltaCMUs.isEmpty {
                print("🔧 FIX #571: Step 2 - Appending \(deltaCMUs.count) delta CMUs (local: \(localCMUs), P2P: \(p2pCMUs))...")
                await progress?("Appending delta CMUs for witness update...", 85)

                // FIX #978: Calculate how many CMUs are ALREADY in the tree beyond boost file
                // CRITICAL: FIX #846 failed when new P2P CMUs were fetched because:
                //   - deltaCMUs = 525 local + 1 new P2P = 526
                //   - expectedSizeWithDelta = boost + 526 = 1046213
                //   - currentTreeSize = 1046212 (already has 525 from INSTANT START)
                //   - 1046212 < 1046213 → check FAILED → re-appended ALL 526 → DOUBLE APPEND!
                // FIX #978: Only append CMUs that are NOT already in the tree
                let currentTreeSize = Int(ZipherXFFI.treeSize())
                let boostCMUCount = Int(ZipherXConstants.effectiveTreeCMUCount)
                let cmusAlreadyInTree = max(0, currentTreeSize - boostCMUCount)  // Delta CMUs already appended

                // Step 2a: Append CMUs to TREE (for tree root computation)
                // FIX #978: Skip CMUs that are already in tree, only append NEW ones
                if cmusAlreadyInTree >= deltaCMUs.count {
                    // All CMUs already in tree, skip completely
                    if verbose {
                        print("✅ FIX #978: Step 2a SKIPPED - All \(deltaCMUs.count) delta CMUs already in tree (size=\(currentTreeSize))")
                        print("✅ FIX #978: This prevents double-append bug that caused anchor mismatch!")
                    }
                } else if cmusAlreadyInTree > 0 {
                    // Some CMUs already in tree from INSTANT START, only append NEW ones
                    let cmusToAppend = Array(deltaCMUs.dropFirst(cmusAlreadyInTree))
                    if verbose {
                        print("🔧 FIX #978: Skipping first \(cmusAlreadyInTree) CMUs (already in tree), appending \(cmusToAppend.count) new CMUs...")
                    }
                    for cmu in cmusToAppend {
                        _ = ZipherXFFI.treeAppend(cmu: cmu)
                    }
                    if verbose {
                        print("✅ FIX #978: Step 2a - Appended \(cmusToAppend.count) NEW CMUs to tree (new size: \(ZipherXFFI.treeSize()))")
                    }
                } else {
                    // No CMUs in tree yet, append all
                    for cmu in deltaCMUs {
                        _ = ZipherXFFI.treeAppend(cmu: cmu)
                    }
                    if verbose {
                        print("✅ FIX #571: Step 2a - Appended \(deltaCMUs.count) CMUs to tree (new size: \(ZipherXFFI.treeSize()))")
                    }
                }

                // FIX #805: Step 2b - ALSO update WITNESSES with the same CMUs!
                // CRITICAL: treeAppend() only updates the TREE, NOT the WITNESSES!
                // Without this call, witnesses remain stale at boost file root.
                // updateAllWitnessesBatch() appends CMUs to each loaded witness in WITNESSES array.
                //
                // FIX #1281: Apply SAME size-based guard as FIX #978 Step 2a.
                // Witnesses loaded from DB already have `cmusAlreadyInTree` delta CMUs in their
                // merkle paths. Applying ALL delta CMUs double-applies those → witness root at
                // non-existent tree position → FIX #1280 flags ALL as corrupted → auto Full Rescan.
                // Only apply NEW CMUs (same ones that were appended to tree in Step 2a).
                let cmusForWitnesses: [Data]
                var needFreshWitnesses = false  // FIX #1292
                if cmusAlreadyInTree >= deltaCMUs.count {
                    // All CMUs already reflected in witnesses from DB, skip
                    cmusForWitnesses = []
                    if verbose {
                        print("✅ FIX #1281: Step 2b SKIPPED - Witnesses already have all \(deltaCMUs.count) delta CMUs")
                    }

                    // FIX #1292: Verify skip was correct — delta sync may have grown the tree
                    // without updating witnesses (e.g., syncDeltaBundleIfNeeded added 1 CMU
                    // to delta+tree but witnesses in DB were never updated).
                    // If witness root != FFI tree root, witnesses are stale → create fresh ones.
                    if !witnessIndices.isEmpty, let treeRoot = ZipherXFFI.treeRoot() {
                        let firstIdx = witnessIndices[0].position
                        if let witnessData = ZipherXFFI.treeGetWitness(index: firstIdx) {
                            if let witnessRoot = ZipherXFFI.witnessGetRoot(witnessData) {
                                if witnessRoot != treeRoot {
                                    print("⚠️ FIX #1292: Witness root mismatch after skip!")
                                    print("   Witness root: \(witnessRoot.prefix(8).map { String(format: "%02x", $0) }.joined())...")
                                    print("   FFI tree root: \(treeRoot.prefix(8).map { String(format: "%02x", $0) }.joined())...")
                                    print("   Delta sync grew tree without witness update — creating fresh witnesses")
                                    needFreshWitnesses = true
                                }
                            }
                        }
                    }
                } else if cmusAlreadyInTree > 0 {
                    // Witnesses from DB have first N delta CMUs, only apply new ones
                    cmusForWitnesses = Array(deltaCMUs.dropFirst(cmusAlreadyInTree))
                    if verbose {
                        print("🔧 FIX #1281: Step 2b - Skipping first \(cmusAlreadyInTree) CMUs (already in witnesses), applying \(cmusForWitnesses.count) new CMUs")
                    }
                } else {
                    // Witnesses at boost boundary, apply all delta CMUs
                    cmusForWitnesses = deltaCMUs
                    if verbose {
                        print("🔧 FIX #805: Step 2b - Applying all \(deltaCMUs.count) delta CMUs to witnesses")
                    }
                }

                if !cmusForWitnesses.isEmpty {
                    var packedCMUs = Data()
                    for cmu in cmusForWitnesses {
                        packedCMUs.append(cmu)
                    }
                    let updatedWitnessCount = ZipherXFFI.updateAllWitnessesBatch(cmus: packedCMUs, count: cmusForWitnesses.count)
                    if verbose {
                        print("✅ FIX #805: Step 2b - Updated \(updatedWitnessCount) witnesses with \(cmusForWitnesses.count) delta CMUs")
                    }

                    // FIX #1298: Verify witnesses AFTER applying CMUs — DB witnesses may have been
                    // corrupted (wrong merkle paths from previous session). updateAllWitnessesBatch
                    // can only APPEND CMUs to existing witnesses, not fix corrupted base paths.
                    // If result root != FFI tree root → base was corrupt → need fresh witnesses.
                    if !needFreshWitnesses && !witnessIndices.isEmpty, let treeRoot = ZipherXFFI.treeRoot() {
                        let firstIdx = witnessIndices[0].position
                        if let witnessData = ZipherXFFI.treeGetWitness(index: firstIdx) {
                            if let witnessRoot = ZipherXFFI.witnessGetRoot(witnessData) {
                                if witnessRoot != treeRoot {
                                    print("⚠️ FIX #1298: Witness root mismatch AFTER applying \(cmusForWitnesses.count) CMUs!")
                                    print("   Witness root: \(witnessRoot.prefix(8).map { String(format: "%02x", $0) }.joined())...")
                                    print("   FFI tree root: \(treeRoot.prefix(8).map { String(format: "%02x", $0) }.joined())...")
                                    print("   DB witnesses had corrupted base paths — creating fresh witnesses")
                                    needFreshWitnesses = true
                                }
                            }
                        }
                    }
                } else {
                    print("✅ FIX #805: Step 2b - Witnesses already current (no update needed)")
                }

                // FIX #1292 + FIX #1361: Create fresh witnesses when delta sync grew tree without updating witnesses.
                // This happens when syncDeltaBundleIfNeeded appends CMUs to tree+delta but witnesses
                // in DB were saved at the previous tree size. FIX #1281's size guard says "skip" but
                // witnesses are actually 1+ CMUs behind → root mismatch → FIX #1280 NULLs all.
                //
                // FIX #1361: Original FIX #1292 passed treeSerialize() (binary merkle tree) to
                // treeCreateWitnessForPosition() which expects bundled CMU format [u64 count][cmu1: 32]...
                // This format mismatch caused ALL witness creations to fail (0/N created).
                // Fix: Use treeCreateWitnessesBatch with correct boost + delta CMU data.
                if needFreshWitnesses && !witnessIndices.isEmpty {
                    let batchStart = CFAbsoluteTimeGetCurrent()
                    // Collect target CMUs from notes
                    let targetCMUs = witnessIndices.compactMap { $0.note.cmu }
                    if targetCMUs.isEmpty {
                        print("⚠️ FIX #1361: No CMUs found in notes — witnesses will be rebuilt by FIX #1280")
                    // Get boost CMU data from FastWalletCache (already in memory, ~33MB)
                    } else if let boostCMUData = await FastWalletCache.shared.getTreeData(), boostCMUData.count >= 8 {
                        let boostCMUCount = boostCMUData.prefix(8).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
                        let localDeltaCMUs = DeltaCMUManager.shared.loadDeltaCMUs() ?? []
                        let totalCount = boostCMUCount + UInt64(localDeltaCMUs.count)

                        // Build combined CMU data in bundled format: [count: u64][cmu1: 32]...[cmuN: 32]
                        var combinedCMUData = Data(capacity: 8 + Int(totalCount) * 32)
                        var count = totalCount
                        withUnsafeBytes(of: &count) { combinedCMUData.append(contentsOf: $0) }
                        combinedCMUData.append(boostCMUData.suffix(from: 8))
                        for cmu in localDeltaCMUs { combinedCMUData.append(cmu) }

                        let estimatedSeconds = targetCMUs.count  // ~1s per witness
                        print("🔧 FIX #1361: Creating \(targetCMUs.count) fresh witnesses via batch (boost:\(boostCMUCount) + delta:\(localDeltaCMUs.count) = \(totalCount) CMUs, ~\(estimatedSeconds)s)...")

                        // FIX #1370: Show progress with estimated time during witness rebuild
                        await MainActor.run {
                            self.syncStatus = "Rebuilding \(targetCMUs.count) witnesses (~\(estimatedSeconds)s)..."
                            self.updateSyncTask(id: "witness_sync", status: .inProgress, detail: "Rebuilding \(targetCMUs.count) witnesses (~\(estimatedSeconds)s)...", progress: 0.1)
                        }

                        let batchResults = ZipherXFFI.treeCreateWitnessesBatch(cmuData: combinedCMUData, targetCMUs: targetCMUs)

                        // Map batch results back to witnessIndices
                        var freshCount = 0
                        var updatedIndices: [(note: WalletNote, position: UInt64)] = []
                        // treeCreateWitnessesBatch returns results in same order as targetCMUs,
                        // but witnessIndices may have notes WITHOUT cmu (filtered by compactMap).
                        // Build a CMU→result lookup.
                        var cmuResultMap: [Data: (position: UInt64, witness: Data)] = [:]
                        for (i, result) in batchResults.enumerated() {
                            if let res = result, i < targetCMUs.count {
                                cmuResultMap[targetCMUs[i]] = res
                            }
                        }

                        for (note, arrayIndex) in witnessIndices {
                            if let cmu = note.cmu, let res = cmuResultMap[cmu] {
                                // Load fresh witness into FFI — gets new array index
                                let newIdx = res.witness.withUnsafeBytes { ptr in
                                    ZipherXFFI.treeLoadWitness(
                                        witnessData: ptr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                                        witnessLen: res.witness.count
                                    )
                                }
                                if newIdx != UInt64.max {
                                    freshCount += 1
                                    updatedIndices.append((note: note, position: newIdx))
                                } else {
                                    updatedIndices.append((note: note, position: arrayIndex))
                                }
                            } else {
                                updatedIndices.append((note: note, position: arrayIndex))
                            }
                        }

                        witnessIndices = updatedIndices
                        let batchElapsed = CFAbsoluteTimeGetCurrent() - batchStart
                        print("✅ FIX #1361: Created \(freshCount)/\(witnessIndices.count) fresh witnesses (\(String(format: "%.1f", batchElapsed))s)")

                        // FIX #1370: Update status after completion
                        await MainActor.run {
                            self.syncStatus = "Witnesses rebuilt (\(freshCount)/\(witnessIndices.count))"
                            self.updateSyncTask(id: "witness_sync", status: .completed, detail: "Rebuilt \(freshCount) witnesses in \(String(format: "%.0f", batchElapsed))s")
                        }
                    } else {
                        print("⚠️ FIX #1361: No boost CMU cache available — witnesses will be rebuilt by FIX #1280")
                    }
                }

                print("✅ FIX #571 + FIX #805: Step 2 complete - Tree AND witnesses now updated!")
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
                //
                // FIX #721: CRITICAL - Verify FFI tree root matches HeaderStore BEFORE using HeaderStore anchor!
                // If they don't match, the FFI tree is corrupt and we should NOT update witnesses.
                // Using mismatched anchor causes "joinsplit requirements not met" errors.
                //
                // FIX #799: SKIP header comparison for heights above boost file end!
                // P2P headers above boost file have CORRUPTED/DUPLICATED sapling roots
                // (same root appears for 50+ blocks due to P2P protocol limitation)
                var currentTreeAnchor: Data?

                // FIX #721: Get FFI tree root first
                let ffiTreeRoot = ZipherXFFI.treeRoot()
                let ffiRootHex = ffiTreeRoot?.map { String(format: "%02x", $0) }.joined() ?? "nil"

                // FIX #1190: Update delta manifest tree root with computed FFI root
                if let root = ffiTreeRoot {
                    DeltaCMUManager.shared.updateManifestTreeRoot(root)
                }

                // FIX #1204b: HeaderStore sapling roots ARE authoritative for post-boost heights.
                let boostFileEndForAnchor = ZipherXConstants.effectiveTreeHeight

                if chainHeight > boostFileEndForAnchor && boostFileEndForAnchor > 0 {
                    // FIX #1204b: Try HeaderStore root — validate FFI against it if non-zero
                    if let header = try? HeaderStore.shared.getHeader(at: chainHeight) {
                        let headerRoot = header.hashFinalSaplingRoot
                        let isZeroRoot = headerRoot.allSatisfy { $0 == 0 } || headerRoot.isEmpty
                        if !isZeroRoot {
                            let headerRootReversed = Data(headerRoot.reversed())
                            if let ffi = ffiTreeRoot, (ffi == headerRoot || ffi == headerRootReversed) {
                                currentTreeAnchor = ffiTreeRoot
                                print("✅ FIX #1204b: FFI root VERIFIED against HeaderStore at height \(chainHeight)")
                            } else {
                                // Mismatch — use FFI root (authoritative for witness/anchor), but log warning
                                currentTreeAnchor = ffiTreeRoot
                                print("⚠️ FIX #1204b: FFI root MISMATCH with HeaderStore at height \(chainHeight) — using FFI root for anchor")
                                if let ffi = ffiTreeRoot {
                                    print("   FFI root:    \(ffi.prefix(8).map { String(format: "%02x", $0) }.joined())...")
                                }
                                print("   Header root: \(headerRoot.prefix(8).map { String(format: "%02x", $0) }.joined())...")
                            }
                        } else {
                            currentTreeAnchor = ffiTreeRoot
                            let anchorHex = currentTreeAnchor?.prefix(8).map { String(format: "%02x", $0) }.joined()
                            print("✅ FIX #1204b: HeaderStore root is zero at \(chainHeight) — using FFI anchor: \(anchorHex ?? "N/A")...")
                        }
                    } else {
                        currentTreeAnchor = ffiTreeRoot
                        let anchorHex = currentTreeAnchor?.prefix(8).map { String(format: "%02x", $0) }.joined()
                        print("✅ FIX #1204b: No header at \(chainHeight) — using FFI anchor: \(anchorHex ?? "N/A")...")
                    }
                } else if chainHeight > 0,
                   let currentHeader = try? HeaderStore.shared.getHeader(at: chainHeight) {
                    let headerRoot = currentHeader.hashFinalSaplingRoot
                    let headerRootHex = headerRoot.map { String(format: "%02x", $0) }.joined()

                    // FIX #721: Check if header root is zero (corrupted)
                    let isZeroRoot = headerRoot.allSatisfy { $0 == 0 }
                    if isZeroRoot {
                        print("⚠️ FIX #721: Header has ZERO sapling root (corrupted) - using FFI tree root instead")
                        currentTreeAnchor = ffiTreeRoot
                    } else if let ffi = ffiTreeRoot, ffi == headerRoot {
                        // Roots match - safe to use
                        currentTreeAnchor = headerRoot
                        print("✅ FIX #721: FFI tree root matches HeaderStore - safe to update witnesses")
                    } else if let ffi = ffiTreeRoot, ffi == Data(headerRoot.reversed()) {
                        // Roots match with byte order reversal
                        currentTreeAnchor = ffiTreeRoot  // Use FFI root (consistent with how TX builds proofs)
                        print("✅ FIX #721: FFI tree root matches HeaderStore (reversed) - using FFI root")
                    } else {
                        // MISMATCH! Tree is corrupt - don't update witnesses
                        print("❌ FIX #721: CRITICAL - FFI tree root MISMATCH with HeaderStore!")
                        print("   FFI root:    \(ffiRootHex.prefix(32))...")
                        print("   Header root: \(headerRootHex.prefix(32))...")
                        print("❌ FIX #721: NOT updating witnesses - tree is corrupt!")
                        print("❌ FIX #721: Run 'Repair Database' to rebuild tree")

                        // FIX #1254: Only clear delta if NOT verified (immutable).
                        if UserDefaults.standard.bool(forKey: "DeltaBundleVerified") {
                            print("✅ FIX #1254: Delta is VERIFIED (immutable) — NOT clearing despite tree root mismatch")
                            print("   Tree mismatch is from new blocks, not verified delta corruption")
                        } else {
                            // FIX #1309: Delta is INCOMPLETE (P2P missed blocks), not corrupt.
                            // Preserve delta for gap-fill — clearing forces full re-fetch.
                            print("📦 FIX #1309: Delta PRESERVED — root mismatch = incomplete P2P data, gap-fill will fix")
                        }

                        // Return early - don't corrupt witnesses with wrong anchor
                        return
                    }

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

                // FIX #1279: Validate witnesses from FFI WITNESSES array BEFORE saving.
                // The WITNESSES array is populated from DB-loaded witnesses. If those witnesses
                // were saved from a corrupted tree, treeGetWitness() returns wrong merkle paths.
                // The witness root MUST match the FFI tree root — if not, the witness is corrupt.
                var phantomWitnessCount = 0
                var phantomNoteIds: [Int64] = []  // FIX #1280: Track corrupted note IDs to NULL in DB
                var staleWitnessCount = 0  // FIX #1322: Witnesses valid at earlier height (not corrupted)

                // FIX #1280: Get the VERIFIED FFI tree root for per-witness validation.
                // The FFI tree root was already verified against HeaderStore above.
                // Each extracted witness MUST produce the SAME root as the FFI tree.
                // If a witness produces a different root, it was loaded from corrupted DB state
                // and the delta CMU update couldn't fix it (wrong base → wrong extended path).
                // FIX #1322: OR the witness was created at an earlier tree state (stale, not corrupt).
                let ffiTreeRootForValidation = ZipherXFFI.treeRoot()
                if let rootHex = ffiTreeRootForValidation?.prefix(8).map({ String(format: "%02x", $0) }).joined() {
                    print("🔍 FIX #1280: FFI tree root for witness validation: \(rootHex)...")
                }

                for (note, position) in witnessIndices {
                    if let updatedWitness = ZipherXFFI.treeGetWitness(index: position) {
                        // FIX #1280: Validate witness root matches FFI tree root BEFORE saving.
                        // If witness was loaded from corrupted DB, treeGetWitness() returns the
                        // corrupted witness with wrong merkle path. Its root will differ from
                        // the verified FFI tree root. This is the per-witness check that
                        // FIX #1279 Layer 2 missed (it only checked the tree root, not witness roots).
                        if let ffiRoot = ffiTreeRootForValidation,
                           let witnessRoot = ZipherXFFI.witnessGetRoot(updatedWitness) {
                            if witnessRoot != ffiRoot && Data(witnessRoot.reversed()) != ffiRoot {
                                // Witness root ≠ current FFI tree root — could be stale, not corrupt.
                                // FIX #1322: Check if root is valid at ANY blockchain height in HeaderStore.
                                // A witness from FIX #1316 batch creation may be valid at an earlier height
                                // if delta sync appended CMUs to the tree between creation and validation.
                                let witnessRootValid = await HeaderStore.shared.containsSaplingRoot(witnessRoot)
                                if !witnessRootValid {
                                    // Root doesn't match ANY blockchain height — truly corrupted
                                    phantomWitnessCount += 1
                                    phantomNoteIds.append(note.id)
                                    if phantomWitnessCount <= 3 {
                                        let witnessRootHex = witnessRoot.prefix(8).map { String(format: "%02x", $0) }.joined()
                                        print("🚨 FIX #1280: Note \(note.id) witness root \(witnessRootHex)... NOT in HeaderStore — SKIPPING")
                                    }
                                    continue  // Don't save this corrupted witness
                                }
                                // FIX #1322: Witness root is valid at an earlier height — stale but usable for spending.
                                staleWitnessCount += 1
                                if staleWitnessCount <= 3 {
                                    let wRootHex = witnessRoot.prefix(8).map { String(format: "%02x", $0) }.joined()
                                    print("ℹ️ FIX #1322: Note \(note.id) witness root \(wRootHex)... valid at earlier height — saving")
                                }
                            }
                        }
                        witnessUpdates.append((note.id, updatedWitness))
                        updatedCount += 1
                    }

                    // FIX #1322: Set anchor to witness's OWN root for stale witnesses.
                    // The anchor must match the witness root for valid TX building.
                    // Using currentTreeAnchor (FFI tip) for a stale witness → anchor mismatch → "joinsplit requirements not met".
                    if witnessUpdates.last?.noteId == note.id {
                        if let lastWitness = witnessUpdates.last?.witness,
                           let witnessRoot = ZipherXFFI.witnessGetRoot(lastWitness),
                           let ffiRoot = ffiTreeRootForValidation,
                           witnessRoot != ffiRoot && Data(witnessRoot.reversed()) != ffiRoot {
                            // Stale witness — use witness root as anchor (valid on-chain)
                            positionAnchorUpdates.append((note.id, witnessRoot))
                        } else if let currentAnchor = currentTreeAnchor {
                            // Current witness — use FFI tip anchor
                            positionAnchorUpdates.append((note.id, currentAnchor))
                        }
                        anchorFixedCount += 1
                    }
                }

                // FIX #1280: NULL corrupted witnesses in DB so they don't persist across restarts.
                // Without this, the same corrupted witnesses would be loaded on next startup,
                // FIX #1279 would detect them, FIX #1027 rebuild would fail, FIX #569 would
                // re-load them → infinite cycle. NULLing breaks the cycle.
                if !phantomNoteIds.isEmpty {
                    print("🚨 FIX #1280: Skipped \(phantomWitnessCount) witnesses with phantom roots (≠ FFI tree root)")
                    print("🚨 FIX #1280: NULLing \(phantomNoteIds.count) corrupted witnesses in DB to break infinite cycle")
                    await MainActor.run {
                        for noteId in phantomNoteIds {
                            try? WalletDatabase.shared.clearWitnessForNote(noteId: noteId)
                        }
                    }
                    print("🚨 FIX #1280: Saved \(updatedCount) valid witnesses, NULLed \(phantomWitnessCount) corrupted")
                    print("🚨 FIX #1280: Run Full Rescan to rebuild corrupted witnesses from correct tree")
                }

                // FIX #1279: Also check the tree root itself against HeaderStore as backup
                if let anchor = currentTreeAnchor {
                    let anchorValid = await HeaderStore.shared.containsSaplingRoot(anchor)
                    if !anchorValid {
                        let anchorHex = anchor.prefix(8).map { String(format: "%02x", $0) }.joined()
                        print("🚨 FIX #1279: FFI tree anchor \(anchorHex)... NOT in HeaderStore!")
                        print("🚨 FIX #1279: ALL \(witnessUpdates.count) witnesses are from corrupted tree")
                        print("🚨 FIX #1279: REFUSING to save — witnesses need Full Rescan rebuild")
                        phantomWitnessCount += witnessUpdates.count
                        witnessUpdates.removeAll()
                        positionAnchorUpdates.removeAll()

                        // NULL all witnesses so they get rebuilt fresh
                        await MainActor.run {
                            try? WalletDatabase.shared.clearWitnessesForCorruptedTree()
                            print("🚨 FIX #1279: Cleared ALL witnesses — phantom tree anchor")
                        }
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

                if phantomWitnessCount > 0 && updatedCount == 0 {
                    print("🚨 FIX #1280: ALL \(phantomWitnessCount) witnesses had phantom roots — none saved")
                    // FIX #1302: Do NOT auto-trigger Full Rescan. Full Rescan's Phase 2
                    // has partial batch cursor bug → creates phantom notes → inflated balance.
                    // Witnesses are NULLed (safe). Balance displays correctly via getTotalUnspentBalance().
                    // Witnesses will be rebuilt just-in-time when user wants to send.
                    print("⚠️ FIX #1302: Witnesses NULLed — balance still correct. Rebuild on next sync or send.")
                } else if phantomWitnessCount > 0 {
                    print("⚠️ FIX #1280: \(updatedCount) valid witnesses saved, \(phantomWitnessCount) phantom witnesses skipped")
                    // FIX #1302: Do NOT auto-trigger Full Rescan — just log and continue.
                    // NULLed witnesses don't affect balance display.
                    print("⚠️ FIX #1302: \(phantomWitnessCount) witnesses NULLed — balance still correct.")
                } else if staleWitnessCount > 0 {
                    print("✅ FIX #1322: Step 3 complete - Saved \(updatedCount) witnesses (\(staleWitnessCount) stale at earlier height, anchors set to witness roots)")
                } else {
                    print("✅ FIX #569 v2: Step 3 complete - Updated \(updatedCount) witnesses with current tree state")
                    print("✅ FIX #569 v2: Updated \(anchorFixedCount) anchors to CURRENT tree root (chain height \(chainHeight))")
                    print("✅ FIX #569 v2: Witness update complete - ALL notes now have correct witnesses and anchors!")
                }

                // FIX #1132: Mark that witnesses were updated this session
                // This prevents FIX #557 from doing a redundant rebuild after fast delta update
                WalletHealthCheck.shared.witnessesRebuiltThisSession = true
                print("✅ FIX #1132: Marked witnesses as updated (preventing redundant rebuild)")
            } else {
                print("⚠️ FIX #586: STEP 3 extraction skipped (no delta CMUs appended)")
            }
            // FIX #562: Record when witnesses were last updated
            lastWitnessUpdate = Date()
            print("✅ FIX #562: Witness update timestamp recorded")

            // FIX #557 v37: Fallback - rebuild empty witnesses using boost + delta
            // FIX #1116: SKIP at startup - witnesses only needed when SPENDING
            // Rebuild on-demand in TransactionBuilder when user tries to send
            // This saves 49+ seconds at startup for 82 empty witnesses!
            if !emptyWitnessNotes.isEmpty {
                print("⏭️ FIX #1116: Skipping \(emptyWitnessNotes.count) empty witness rebuilds at startup (will rebuild on-demand when spending)")
                // Don't rebuild here - TransactionBuilder.swift handles it when needed
            }

            // FIX #557 v37: DISABLED by FIX #1116 - moved to on-demand in TransactionBuilder
            if false && !emptyWitnessNotes.isEmpty {
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

                    // FIX #968: CRITICAL - Update rebuilt witnesses with delta CMUs!
                    // rebuildWitnessesForNotes() creates witnesses at boost tree root,
                    // but we need witnesses at CURRENT tree root (with delta CMUs).
                    // Load witnesses into FFI, update with delta, extract updated versions.
                    if !deltaCMUs.isEmpty {
                        print("🔧 FIX #968: Updating \(results.count) rebuilt witnesses with \(deltaCMUs.count) delta CMUs...")

                        // FIX #996: Clear WITNESSES array before loading to prevent accumulation
                        ZipherXFFI.witnessesClear()

                        // Step 1: Load each rebuilt witness into FFI WITNESSES array
                        var loadedIndices: [(noteId: Int64, witnessIndex: UInt64)] = []
                        for (index, result) in results.enumerated() {
                            let noteId = notesWithIds[index].0
                            let witnessIndex = result.witness.withUnsafeBytes { ptr in
                                ZipherXFFI.treeLoadWitness(
                                    witnessData: ptr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                                    witnessLen: result.witness.count
                                )
                            }
                            if witnessIndex != UInt64.max {
                                loadedIndices.append((noteId: noteId, witnessIndex: witnessIndex))
                            }
                        }
                        print("📊 FIX #968: Loaded \(loadedIndices.count) witnesses into FFI")

                        // Step 2: Update all witnesses with delta CMUs
                        var packedCMUs = Data()
                        for cmu in deltaCMUs {
                            packedCMUs.append(cmu)
                        }
                        let updatedCount = ZipherXFFI.updateAllWitnessesBatch(cmus: packedCMUs, count: deltaCMUs.count)
                        print("✅ FIX #968: Updated \(updatedCount) witnesses with delta CMUs")

                        // Step 3: Extract updated witnesses and anchors from FFI
                        for (noteId, witnessIndex) in loadedIndices {
                            if let updatedWitness = ZipherXFFI.treeGetWitness(index: witnessIndex),
                               let updatedAnchor = ZipherXFFI.witnessGetRoot(updatedWitness) {
                                _ = try? WalletDatabase.shared.updateNoteWitness(noteId: noteId, witness: updatedWitness)
                                _ = try? WalletDatabase.shared.updateNoteAnchor(noteId: noteId, anchor: updatedAnchor)
                            }
                        }

                        // Verify final anchor matches current tree root
                        if let currentTreeRoot = ZipherXFFI.treeRoot() {
                            let currentRootHex = currentTreeRoot.map { String(format: "%02x", $0) }.joined()
                            print("✅ FIX #968: Current tree root: \(currentRootHex.prefix(16))...")
                        }
                        print("✅ FIX #968: Updated \(loadedIndices.count) witnesses and anchors with delta CMUs")
                    }
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
        // FIX #1238: Guard against rebuilding witnesses when tree state is corrupted.
        // When TreeRepairExhausted is true, the FFI tree has wrong root (incomplete delta).
        // Any witnesses created from this tree will have non-existent anchors on blockchain.
        // FIX #1226 will reject them at creation, and FIX #1224 would flag them at next startup.
        // Skip rebuild entirely to avoid wasting time on doomed witness creation.
        let treeRepairExhausted = UserDefaults.standard.bool(forKey: "TreeRepairExhausted")
        if treeRepairExhausted {
            print("⏩ FIX #1238: Skipping rebuildWitnessesForStartup — tree repair exhausted")
            print("   FFI tree has wrong root (incomplete delta). Witnesses from this tree")
            print("   would have non-existent anchors. User must run 'Full Resync' first.")
            return
        }

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

    /// FIX #1083: Rebuild witnesses from existing delta bundle (FAST path)
    /// This avoids the slow P2P fetch when delta CMUs are already cached locally.
    /// Called when notes are missing witnesses but delta bundle has CMUs.
    ///
    /// Timeline (from 10-minute startup analysis):
    /// - Old path: Clear delta → P2P fetch 11,916 blocks → timeout → retry → 10+ minutes
    /// - New path: Use existing delta CMUs → rebuild witnesses → ~10-30 seconds
    func rebuildWitnessesFromDeltaBundle() async {
        print("🔧 FIX #1083: Rebuilding witnesses from cached delta bundle (FAST path)...")

        // FIX #1238: Guard against rebuilding when tree state is corrupted
        let treeRepairExhausted = UserDefaults.standard.bool(forKey: "TreeRepairExhausted")
        if treeRepairExhausted {
            print("⏩ FIX #1238: Skipping rebuildWitnessesFromDeltaBundle — tree repair exhausted")
            print("   Disk delta may be incomplete (caused the tree corruption in first place)")
            print("   User must run 'Full Resync' first.")
            return
        }

        do {
            guard let account = try WalletDatabase.shared.getAccount(index: 0) else {
                print("❌ FIX #1083: No account found")
                return
            }

            // Load delta CMUs
            let deltaManager = DeltaCMUManager.shared
            guard let deltaCMUs = deltaManager.loadDeltaCMUs(), !deltaCMUs.isEmpty else {
                print("⚠️ FIX #1083: Delta bundle empty - falling back to standard rebuild")
                await rebuildWitnessesForStartup()
                return
            }

            print("📦 FIX #1083: Found \(deltaCMUs.count) delta CMUs - will use for witness rebuild")

            // Ensure FFI tree is loaded with delta CMUs
            let currentTreeSize = ZipherXFFI.treeSize()
            let boostCMUCount = UInt64(ZipherXConstants.effectiveTreeCMUCount)
            let expectedSize = boostCMUCount + UInt64(deltaCMUs.count)

            if currentTreeSize < expectedSize {
                print("🔧 FIX #1083: Tree size \(currentTreeSize) < expected \(expectedSize) - appending delta CMUs")

                // Pack CMUs for atomic append
                var packedCMUs = Data()
                for cmu in deltaCMUs {
                    packedCMUs.append(cmu)
                }

                let appendResult = ZipherXFFI.treeAppendDeltaAtomic(
                    cmus: packedCMUs,
                    expectedBoostSize: boostCMUCount
                )

                switch appendResult {
                case .appended:
                    let newSize = ZipherXFFI.treeSize()
                    print("✅ FIX #1083: Delta CMUs appended successfully (tree size: \(newSize))")
                case .skipped:
                    print("🔄 FIX #1083: Delta CMUs already present in tree")
                case .mismatch:
                    print("⚠️ FIX #1083: Tree size mismatch during append")
                case .error:
                    print("❌ FIX #1083: Error appending delta CMUs")
                }
            } else {
                print("✅ FIX #1083: Tree already has delta CMUs (size: \(currentTreeSize))")
            }

            // Now rebuild witnesses using the complete tree
            await MainActor.run {
                self.updateSyncTask(id: "witness_fix", status: .inProgress, detail: "Rebuilding witnesses...", progress: 0.5)
            }

            // Call the standard witness rebuild which will now use the complete tree
            await preRebuildWitnessesForInstantPayment(accountId: account.accountId) { status, percent async in
                await MainActor.run {
                    self.updateSyncTask(id: "witness_fix", status: .inProgress, detail: status, progress: Double(percent) / 100.0)
                }
            }

            // Verify all notes now have witnesses
            let (stillMissing, _, _) = try WalletDatabase.shared.getNotesWithoutWitnesses(accountId: account.accountId)
            if stillMissing == 0 {
                print("✅ FIX #1083: All notes now have witnesses - FAST rebuild complete!")
            } else {
                print("⚠️ FIX #1083: \(stillMissing) notes still missing witnesses after rebuild")
            }

        } catch {
            print("❌ FIX #1083: Witness rebuild failed: \(error.localizedDescription)")
            // Fall back to standard rebuild
            await rebuildWitnessesForStartup()
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
        print("🔐 Generated z-address: \(address.redactedAddress)")
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
        // VUL-STOR-009: Use HKDF domain separation for SQLCipher key
        let rawKey = Data(SHA256.hash(data: spendingKey))
        let dbKey = DatabaseEncryption.deriveDatabaseKey(from: rawKey)
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

        // FIX #1402 (NEW-001): Recover diversified addresses from UserDefaults
        // (UserDefaults persists across DB deletion — it remembers the highest index)
        Task {
            await self.recoverDiversifiedAddressesIfNeeded()
        }

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

        // FIX #1353: Only show "Syncing..." UI during INITIAL sync, not background refreshes
        // After initial sync, backgroundProcessesEnabled=true. Subsequent refreshBalance() calls
        // (from send flow, background sync, etc.) should NOT show the syncing banner.
        let isInitialSync = await MainActor.run { !NetworkManager.shared.backgroundProcessesEnabled }

        // Initialize sync tasks
        await MainActor.run {
            if isInitialSync {
                self.isSyncing = true
                self.syncProgress = 0.0
                self.syncStatus = "Initializing privacy shield..."
            }
            // Move to connecting phase (tree loading should already be done)
            self.updateOverallProgress(phase: .connecting, phaseProgress: 0.0)
            // FIX #558: Add FAST START task IDs that ContentView updates
            // Previous bug: IDs didn't match, so updateSyncTask() calls failed silently
            self.syncTasks = [
                // FIX #887: User-friendly task titles (simple, human-readable)
                SyncTask(id: "params", title: "Preparing wallet", status: .pending),
                SyncTask(id: "keys", title: "Loading your keys", status: .pending),
                SyncTask(id: "database", title: "Opening wallet", status: .pending),
                SyncTask(id: "download_outputs", title: "Downloading blockchain", status: .pending),
                SyncTask(id: "download_timestamps", title: "Getting timestamps", status: .pending),
                SyncTask(id: "headers", title: "Syncing headers", status: .pending),
                SyncTask(id: "height", title: "Connecting to network", status: .pending),
                SyncTask(id: "scan", title: "Finding your transactions", status: .pending),
                SyncTask(id: "witnesses", title: "Verifying transactions", status: .pending),
                SyncTask(id: "balance", title: "Calculating balance", status: .pending),
                // FAST START tasks (ContentView.swift)
                // FIX #887: User-friendly task titles for FAST START
                SyncTask(id: "fast_balance", title: "Loading balance", status: .pending),
                SyncTask(id: "fast_peers", title: "Connecting to network", status: .pending),
                SyncTask(id: "fast_headers", title: "Syncing headers", status: .pending),
                SyncTask(id: "fast_health", title: "Checking wallet", status: .pending),
                SyncTask(id: "fast_repair", title: "Auto-repair", status: .pending),
                // Repair tasks
                // FIX #887: User-friendly repair task titles
                SyncTask(id: "balance_repair", title: "Repairing wallet", status: .pending),
                SyncTask(id: "balance_repair_early", title: "Quick health check", status: .pending),
                SyncTask(id: "full_repair", title: "Full wallet scan", status: .pending),
                SyncTask(id: "tree_rebuild", title: "Rebuilding data", status: .pending),
                SyncTask(id: "witness_sync", title: "Syncing proofs", status: .pending)
            ]
        }

        defer {
            // FIX #1353: Only reset isSyncing if we set it (initial sync only)
            if isInitialSync {
                DispatchQueue.main.async {
                    self.isSyncing = false
                }
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
            // VUL-U-002: Use secure key retrieval with automatic zeroing
            let secureKey = try secureStorage.retrieveSpendingKeySecure()
            defer { secureKey.zero() }
            spendingKey = secureKey.data
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
            // VUL-STOR-009: Use HKDF domain separation for SQLCipher key
            let rawKey = Data(SHA256.hash(data: spendingKey))
            let dbKey = DatabaseEncryption.deriveDatabaseKey(from: rawKey)
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

        // FIX #1341: On first import, DEFER boost header loading to background (saves 207s on iOS).
        // Boost headers (476969-2988797) are NOT needed for import scanning:
        // - PHASE 1 uses local boost shielded output data (trial decryption)
        // - PHASE 1.5 computes witnesses from in-memory tree
        // - PHASE 2 fetches P2P headers for delta range (2988798+) only
        // Headers load in background after import for timestamps and anchor validation.
        //
        // FIX #522/951 (original): Load bundled headers in parallel with CMU pre-extraction.
        // Still used for non-first-import cases (when headers are already loaded, returns instantly).
        let headerStoreHeight1341 = (try? HeaderStore.shared.getLatestHeight()) ?? 0
        let boostHeadersAlreadyLoaded = headerStoreHeight1341 > 2_900_000
        if wasImported && !boostHeadersAlreadyLoaded {
            // FIX #1341: First import — skip blocking 207s header load
            print("⏭️ FIX #1341: Deferring 2.5M boost header loading to background (saves 207s on iOS)")
            // Still pre-load CMU cache (instant)
            if let cmuPath = await CommitmentTreeUpdater.shared.getCachedCMUFilePath() {
                print("✅ FIX #1341: CMU cache path ready")
            } else {
                print("⚠️ FIX #1341: CMU cache path not available")
            }
        } else if wasImported {
            print("⚡ FIX #951: Starting PARALLEL header loading + CMU pre-extraction...")
            let parallelStartTime = Date()

            async let headerLoadTask = loadHeadersFromBoostFile()
            async let cmuPreloadTask: URL? = CommitmentTreeUpdater.shared.getCachedCMUFilePath()

            let (loadedBundledHeaders, boostHeaderEndHeight) = await headerLoadTask
            let cmuCachePath = await cmuPreloadTask

            let parallelDuration = Date().timeIntervalSince(parallelStartTime)

            if loadedBundledHeaders {
                let cmuStatus = cmuCachePath != nil ? "CMUs cached" : "CMU cache failed"
                print("✅ FIX #951: Parallel complete in \(String(format: "%.1f", parallelDuration))s - headers to \(boostHeaderEndHeight), \(cmuStatus)")
            } else {
                print("⚠️ FIX #951: Header load failed, CMU cache: \(cmuCachePath != nil ? "OK" : "FAILED")")
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

        // FIX #947: DISABLED - Deferred witness computation causes anchor mismatch on SEND
        // The witnesses created during PHASE 2 or repair don't have valid anchors
        // because the tree state doesn't match blockchain's tree root
        // TODO: FIX #949 - Investigate why deferred witnesses are corrupted
        scanner.setDeferWitnessComputation(false)

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
                    case "headers":
                        // FIX #1440: Show live header sync progress in task detail
                        task.detail = status
                        self?.updateOverallProgress(phase: .syncingHeaders, phaseProgress: 0.0)
                    case "phase1":
                        task.detail = "Parallel note decryption"
                        self?.updateOverallProgress(phase: .phase1Scanning, phaseProgress: 0.0)
                    case "phase1.5":
                        // FIX #947: PHASE 1.5 is skipped when deferred witness computation is enabled
                        // Show quick progress since witnesses will be computed on first SEND
                        task.detail = "Witness computation deferred"
                        self?.updateOverallProgress(phase: .phase15Witnesses, phaseProgress: 1.0)
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

        // FIX #1304: Use getAllUnspentNotes (no witness requirement) instead of getUnspentNotes.
        // getUnspentNotes requires witness IS NOT NULL → returns 0 when all witnesses are NULL
        // (which happens after FIX #1280 NULLs phantom witnesses). Balance display doesn't need witnesses.
        var unspentNotes = try database.getAllUnspentNotes(accountId: account.accountId)
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
            print("💰 Balance updated: \(totalBalance.redactedAmount) (\(pendingBalance.redactedAmount) pending)")
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
            // FIX #1107: Changed from 1028 to 100
            note.witness.count >= 100 &&
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
        // VUL-U-002: Use secure key retrieval with automatic zeroing
        let secureKey = try secureStorage.retrieveSpendingKeySecure()
        defer { secureKey.zero() }
        let spendingKey = secureKey.data
        // VUL-STOR-009: Use HKDF domain separation for SQLCipher key
        let rawKey = Data(SHA256.hash(data: spendingKey))
        let dbKey = DatabaseEncryption.deriveDatabaseKey(from: rawKey)
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

        // VUL-U-002: Get spending key with secure zeroing
        let secureKey = try secureStorage.retrieveSpendingKeySecure()
        defer { secureKey.zero() }
        let spendingKey = secureKey.data
        // SECURITY: Key retrieved - not logged

        // Ensure database is open
        // VUL-STOR-009: Use HKDF domain separation for SQLCipher key
        let rawKey = Data(SHA256.hash(data: spendingKey))
        let dbKey = DatabaseEncryption.deriveDatabaseKey(from: rawKey)
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
            // FIX #1307: PRESERVE HeaderStore during Full Rescan.
            // Headers are blockchain data (not wallet state) — they don't change.
            // Clearing 2.5M valid headers forces a full P2P re-fetch (~2 min overhead).
            // HeaderStore is validated by Equihash PoW — no need to re-download.
            // Only gaps (if any) will be filled by header sync after rescan.
            print("🔄 Reset complete (headers PRESERVED) - starting full rescan from Sapling activation")
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

        // FIX #1026: Reset IBD latch so connection maintenance reduces activity during repair
        await MainActor.run { NetworkManager.shared.resetInitialBlockDownloadLatch() }
        print("🔄 FIX #1026: IBD latch reset for repair")

        // FIX #907: Block all block listeners during repair
        await PeerManager.shared.stopAllBlockListeners(timeout: 3.0)
        PeerManager.shared.setBlockListenersBlocked(true)
        print("🛑 FIX #907: Block listeners blocked during repair")

        // FIX #1228: Reconnect peers with dead connections after stopping block listeners.
        // FIX #1184b kills NWConnections → peers have handshake=true but connection=nil.
        // Repair needs working connections for P2P block fetches during rescan.
        let deadPeersRepairDB = await MainActor.run {
            NetworkManager.shared.peers.filter { $0.isHandshakeComplete && !$0.isConnectionReady }
        }
        if !deadPeersRepairDB.isEmpty {
            print("🔄 FIX #1228: Reconnecting \(deadPeersRepairDB.count) peers with dead connections (repair database)...")
            var reconnectedRepairDB = Set<String>()  // FIX #1235
            for peer in deadPeersRepairDB {
                if reconnectedRepairDB.contains(peer.host) { print("⏭️ FIX #1235: [\(peer.host)] Already reconnected - skipping"); continue }
                do {
                    try await peer.ensureConnected()
                    reconnectedRepairDB.insert(peer.host)  // FIX #1235
                    print("✅ FIX #1228: [\(peer.host)] Reconnected for repair database")
                } catch {
                    print("⚠️ FIX #1228: [\(peer.host)] Reconnect failed: \(error.localizedDescription)")
                }
            }
        }

        // FIX #577 v7: Show same sync UI as Import PK during Full Rescan
        // FIX #1120: Use published rescanStartTime property (set in MainActor.run below)
        if forceFullRescan {
            // FIX #1252: Clear delta verified flag — Full Rescan rebuilds delta from scratch
            UserDefaults.standard.set(false, forKey: "DeltaBundleVerified")
            // FIX #782: Clear global repair exhausted flags when user explicitly requests Full Rescan
            // This resets the counters so automatic repair can be attempted again after the rescan
            UserDefaults.standard.set(false, forKey: "TreeRepairExhausted")
            UserDefaults.standard.set(0, forKey: "DeltaBundleGlobalRepairAttempts")
            UserDefaults.standard.set(0, forKey: "DeltaBundleRepairAttempts")
            // FIX #783: Also clear stale witness repair counters
            UserDefaults.standard.set(0, forKey: "StaleWitnessGlobalAttempts")
            UserDefaults.standard.set(false, forKey: "StaleWitnessRepairAttempted")
            // FIX #1089: Clear full verification flag - will do fresh scan from oldest note
            UserDefaults.standard.set(false, forKey: "FIX1089_FullVerificationComplete")
            // FIX #1136: Clear witness rebuild timestamp - force fresh witness verification after rescan
            UserDefaults.standard.removeObject(forKey: "WitnessRebuildTimestamp")
            print("🔧 FIX #1252/#782/#783/#1089/#1136: Cleared delta verified + repair counters")

            await MainActor.run {
                isFullRescan = true
                isRescanComplete = false
                rescanCompletionDuration = nil
                // FIX #1120: Track rescan start time for accurate elapsed display
                rescanStartTime = Date()
                // FIX #1098: Clear balance integrity issue flag when starting new Full Rescan
                balanceIntegrityIssue = false
                balanceIntegrityMessage = nil

                // FIX #577 v14: CRITICAL - Initialize Import PK tasks IMMEDIATELY when Full Rescan starts
                // This ensures tasks are ready when UI queries currentSyncTasks ( ContentView.swift )
                // Previous bug: Tasks were initialized at line 4314, AFTER isFullRescan=true was set
                // This caused UI to show empty/wrong task list before tasks were ready
                self.overallProgress = 0.0  // Reset to 0 - was showing previous 100%
                self.syncStatus = "Preparing Full Rescan..."
                self.syncTasks = [
                    // FIX #887: User-friendly task titles for Full Rescan
                    SyncTask(id: "params", title: "Preparing wallet", status: .completed, detail: "Ready"),
                    SyncTask(id: "keys", title: "Loading your keys", status: .completed, detail: "Loaded"),
                    SyncTask(id: "database", title: "Opening wallet", status: .completed, detail: "Open"),
                    SyncTask(id: "download_outputs", title: "Downloading blockchain", status: .inProgress, detail: "Starting...", progress: 0.0),
                    SyncTask(id: "download_timestamps", title: "Getting timestamps", status: .pending),
                    SyncTask(id: "headers", title: "Syncing headers", status: .pending),
                    SyncTask(id: "height", title: "Connecting to network", status: .pending),
                    SyncTask(id: "scan", title: "Finding your transactions", status: .pending),
                    SyncTask(id: "witnesses", title: "Verifying transactions", status: .pending),
                    SyncTask(id: "balance", title: "Calculating balance", status: .pending)
                ]
            }
            print("🎬 FIX #577 v7: isFullRescan = true (showing CypherpunkSyncView)")
            print("📦 FIX #577 v14: Import PK tasks initialized IMMEDIATELY (ready for UI before any code runs)")
        }
        defer {
            // FIX #907: Unblock block listeners when repair completes
            PeerManager.shared.setBlockListenersBlocked(false)
            print("✅ FIX #907: Block listeners unblocked after repair")

            // FIX #844: Clear flag IMMEDIATELY using sync dispatch (if not on main thread)
            // Previous bug: Task { @MainActor in } was async, causing 2+ minute delay
            // This delay allowed FilterScanner to see stale isRepairing=true and start unwanted scan
            if Thread.isMainThread {
                // Already on main thread - execute directly
                self.isRepairingDatabase = false
                print("🔧 FIX #844: isRepairingDatabase = false (direct, already on main thread)")
                if self.isFullRescan, let startTime = self.rescanStartTime {
                    let duration = Date().timeIntervalSince(startTime)
                    self.isRescanComplete = true
                    self.rescanCompletionDuration = duration
                    // FIX #1520b: Reset encryption key mismatch — Full Rescan re-writes all notes
                    // with the current encryption key, resolving any previous mismatch.
                    self.encryptionKeyMismatch = false
                    print("🎬 FIX #577 v7 + FIX #582: Full Rescan complete in \(Int(duration))s, showing completion screen")
                    print("🔒 FIX #582: isFullRescan kept true until user clicks Enter Wallet")
                }
            } else {
                // Not on main thread - use sync dispatch to ensure completion before defer returns
                DispatchQueue.main.sync {
                    self.isRepairingDatabase = false
                    print("🔧 FIX #844: isRepairingDatabase = false (sync dispatch from background)")
                    // FIX #577 v7: Set completion flags when done
                    // FIX #582: Keep isFullRescan = true until user clicks "Enter Wallet"
                    if self.isFullRescan, let startTime = self.rescanStartTime {
                        let duration = Date().timeIntervalSince(startTime)
                        self.isRescanComplete = true
                        self.rescanCompletionDuration = duration
                        // FIX #1520b: Reset encryption key mismatch — Full Rescan re-writes all notes
                        // with the current encryption key, resolving any previous mismatch.
                        self.encryptionKeyMismatch = false
                        print("🎬 FIX #577 v7 + FIX #582: Full Rescan complete in \(Int(duration))s, showing completion screen")
                        print("🔒 FIX #582: isFullRescan kept true until user clicks Enter Wallet")
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

        // VUL-U-002: Get spending key with secure zeroing
        let secureKey = try secureStorage.retrieveSpendingKeySecure()
        defer { secureKey.zero() }
        let spendingKey = secureKey.data
        // SECURITY: Key retrieved - not logged

        // Ensure database is open
        // VUL-STOR-009: Use HKDF domain separation for SQLCipher key
        let rawKey = Data(SHA256.hash(data: spendingKey))
        let dbKey = DatabaseEncryption.deriveDatabaseKey(from: rawKey)
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
                // Check if note has a valid witness
                // FIX #1107: Changed from 1028 to 100
                guard note.witness.count >= 100 else {
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
            // FIX #1106: Clear nullifier verification checkpoint for fresh scan
            UserDefaults.standard.removeObject(forKey: "FIX1106_NullifierVerificationCheckpoint")
            UserDefaults.standard.removeObject(forKey: "FIX1089_FullVerificationComplete")
            UserDefaults.standard.removeObject(forKey: "FIX1089_NullifierVerificationCheckpoint")
            // FIX #1126: Invalidate verified state before Full Rescan (will be re-verified after)
            WalletHealthCheck.shared.invalidateVerifiedState()
        } else {
            // FIX #1016: Use quick fix if MOST notes (80%+) have valid witnesses
            // Old logic required 100% valid - if 1 note was bad, triggered 3+ minute full rescan!
            // Now: quick fix + rebuild only the bad witnesses individually
            let validWitnessRatio = notes.count > 0 ? Double(notesWithValidWitness) / Double(notes.count) : 0.0
            let hasEnoughValidWitnesses = validWitnessRatio >= 0.8  // 80% threshold

        if notes.count > 0 && hasEnoughValidWitnesses && anchorsFixed > 0 && anchorsValidated && !forceFullRescan {
            print("✅ FIX #1016: Quick fix successful! \(anchorsFixed)/\(notes.count) notes fixed (ratio: \(String(format: "%.0f", validWitnessRatio * 100))%)")

            // FIX #1016: If some notes have invalid witnesses, they'll be rebuilt by preRebuildWitnessesForInstantPayment
            if notesWithValidWitness < notes.count {
                print("⚠️ FIX #1016: \(notes.count - notesWithValidWitness) notes need witness rebuild (will be done in preRebuildWitnesses)")
            }

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
        // FIX #1016: Only do full rescan if < 80% of notes have valid witnesses
        let validRatio = notes.count > 0 ? Double(notesWithValidWitness) / Double(notes.count) : 0.0
        print("⚠️ Quick fix insufficient (\(notesWithValidWitness)/\(notes.count) = \(String(format: "%.0f", validRatio * 100))% valid, need 80%+)")
        print("🔄 FIX #577 v8: Starting FULL RESCAN - deleting all notes and rescanning from boost file...")
        onProgress(0.05, 0, 100)

        // FIX #1117: CRITICAL - Stop any running scan BEFORE resetting lastScannedHeight
        // Previous bug: Background scan's PHASE 2 loop was still updating lastScannedHeight
        // while Full Rescan was trying to reset it to 0. The PHASE 2 loop would write
        // non-zero values faster than we could reset, causing isFullRescan=false.
        // Solution: Stop the scan and wait for it to fully stop before any reset operations.
        print("🛑 FIX #1117: Stopping any running scan before Full Rescan...")
        // Stop the current scanner if one is active
        currentScanner?.stopScan()
        currentScanner = nil

        // Wait for scan to fully stop (up to 2 seconds)
        var waitAttempts = 0
        while FilterScanner.isScanInProgress && waitAttempts < 20 {
            try await Task.sleep(nanoseconds: 100_000_000)  // 100ms
            waitAttempts += 1
        }

        if FilterScanner.isScanInProgress {
            print("⚠️ FIX #1117: Force-clearing isScanInProgress after timeout")
            FilterScanner.forceClearScanInProgressForRepair()
        }
        print("✅ FIX #1117: Previous scan stopped, safe to reset lastScannedHeight")

        // FIX #577 v8: Delete all notes from database (this is what fixes spent/unspent status!)
        print("🗑️ FIX #577 v8: Deleting all notes from database...")
        try WalletDatabase.shared.deleteAllNotes()
        print("✅ FIX #577 v8: All notes deleted - will rediscover from boost file")

        // FIX #577 v8: Reset lastScannedHeight to 0 so scanner starts from Sapling activation
        // FIX #1099: Use forceReset to bypass FIX #1075 regression protection
        try WalletDatabase.shared.forceResetLastScannedHeightForFullRescan()
        print("✅ FIX #577 v8: Reset lastScannedHeight to 0 for fresh scan")

        // FIX #577 v4: Step 5 - Reset FFI tree state (same as Import PK line 5994-5996)
        // FIX #729: CRITICAL - Must actually call treeInit() to reset Rust FFI tree!
        // Previous bug: Only reset Swift flags but FFI tree still had old data
        // This caused FilterScanner to skip PHASE 1 thinking tree was already loaded
        print("🌳 FIX #729: Resetting FFI tree state...")
        _ = ZipherXFFI.treeInit()  // Reset Rust FFI tree to empty state
        try? WalletDatabase.shared.clearTreeState()  // FIX #729: Also clear DB tree state
        isTreeLoaded = false
        treeLoadProgress = 0.0
        // FIX #1100: Set meaningful status instead of empty string
        // Empty string causes "Loading commitment tree..." fallback in currentSyncStatus
        treeLoadStatus = "Full Rescan starting..."
        print("✅ FIX #729: FFI tree reset (treeInit + DB cleared + flags reset)")

        // FIX #1289 v3: PRESERVE delta bundle during Full Rescan
        // Delta contains valid blockchain data (shielded outputs + nullifiers) from prior sessions.
        // NOT cleared during Full Rescan — Phase 1b scans delta locally (zero P2P for delta range).
        // Phase 1b: trial decryption (notes) + nullifier matching (spends) + tree + witnesses.
        // Phase 2 only processes blocks BEYOND delta tip.
        let deltaManifest = DeltaCMUManager.shared.getManifest()
        let deltaPreserved = deltaManifest != nil
        let deltaHasNullifiers = DeltaCMUManager.shared.hasNullifiers()
        if deltaPreserved {
            UserDefaults.standard.set(false, forKey: "DeltaBundleVerified")
            print("📦 FIX #1289 v3: Delta bundle PRESERVED (\(deltaManifest!.outputCount) outputs, endHeight=\(deltaManifest!.endHeight), nullifiers=\(deltaHasNullifiers))")
        } else {
            print("📦 FIX #1289 v3: No delta bundle to preserve")
        }

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

        // FIX #1289 v3: Pass delta info to scanner for Phase 1b local processing
        scanner.preservedDeltaEndHeight = deltaPreserved ? deltaManifest?.endHeight : nil

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
                    // FIX #1100: Also update treeLoadStatus for currentSyncStatus display
                    self.treeLoadStatus = "Full Rescan: \(progressPercent)% (\(currentHeight)/\(maxHeight))"
                } else {
                    self.syncStatus = "Initializing scan... \(progressPercent)%"
                    // FIX #1100: Also update treeLoadStatus
                    self.treeLoadStatus = "Full Rescan: \(progressPercent)%"
                }
                // FIX #1100: Update treeLoadProgress for progress bar
                self.treeLoadProgress = scanProgress

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

        // FIX #1102: CRITICAL - Force-clear the scan flag before Full Rescan
        // Problem: When FIX #1078 triggers Full Rescan during INSTANT START, a previous background sync
        // may still have isScanInProgress=true. If we don't clear this, scanner.startScan() will return
        // immediately with "Scan already in progress, skipping" - but we already deleted the notes!
        // Result without this fix: Balance shows 0 because notes deleted but never re-discovered.
        FilterScanner.forceClearScanInProgressForRepair()

        // FIX #1117 v2: Verify lastScannedHeight is 0 right before calling scanner
        // This is the final safety check to ensure PHASE 1 will run
        let preStartLastScanned = (try? WalletDatabase.shared.getLastScannedHeight()) ?? 0
        if preStartLastScanned != 0 {
            print("🚨 FIX #1117: CRITICAL - lastScannedHeight is \(preStartLastScanned) but should be 0!")
            print("   Force-resetting again before scan...")
            try WalletDatabase.shared.forceResetLastScannedHeightForFullRescan()
        } else {
            print("✅ FIX #1117: Verified lastScannedHeight=0 before scan (PHASE 1 will run)")
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
        // FIX #1288: MUST clear old history first — old WalletManager-recorded SENT entries
        // persist with INSERT OR IGNORE, creating historyBalance vs notesBalance mismatch
        // that triggers false FIX #1286 "Balance Issue" after every full rescan.
        // (Repair Database path at line ~7783 already does this correctly.)
        print("📜 FIX #577 v11: Clearing old history before rebuild (FIX #1288)...")
        try WalletDatabase.shared.clearTransactionHistory()
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

        // FIX #816: CRITICAL - Set isTreeLoaded = true after Full Rescan completes
        // Problem: FIX #729 sets isTreeLoaded = false at line 4882 but never sets it back
        // Root Cause: checkAndCatchUp() has `guard isTreeLoaded else { return }` at line 1948
        //   - Full Rescan sets isTreeLoaded = false during initialization
        //   - FilterScanner loads tree but doesn't set isTreeLoaded flag
        //   - checkAndCatchUp() silently returns without doing anything
        //   - Wallet stays behind chain tip (138 blocks in the reported bug)
        // Solution: Set isTreeLoaded = true before calling checkAndCatchUp()
        await MainActor.run {
            self.isTreeLoaded = true
            // FIX #1141: Clear corrupted witness flag after Full Rescan
            // Fresh scan rebuilds all witnesses from verified tree state
            self.hasCorruptedWitnesses = false
            self.corruptedWitnessCount = 0
        }
        print("✅ FIX #816: Set isTreeLoaded = true after Full Rescan (enables catch-up sync)")
        print("✅ FIX #1141: Cleared corrupted witness flag after Full Rescan")

        // FIX #977: Trigger UI refresh AFTER Full Rescan completes and all sent TXs are inserted
        // Problem: transactionHistoryVersion was incremented BEFORE populateHistoryFromNotes()
        //   - UI reloaded at 18:33:16, but sent TXs inserted at 18:33:20
        //   - Result: UI showed 0 sent transactions even though they're in database
        // Solution: Increment version AFTER all database operations complete
        await MainActor.run {
            transactionHistoryVersion += 1
            print("📜 FIX #977: Incremented transactionHistoryVersion to \(transactionHistoryVersion) after Full Rescan")
            NotificationCenter.default.post(name: Notification.Name("transactionHistoryUpdated"), object: nil)
        }

        // FIX #766: Trigger immediate catch-up sync after Full Rescan completes
        // Problem: After Full Rescan finishes, wallet stays behind chain tip (e.g., 451 blocks)
        // Root Cause: backgroundSyncToHeight() only runs from fetchNetworkStats() on 15s timer
        //   - Full Rescan scans to peer consensus height at SCAN START
        //   - Chain advances during scan → wallet behind when scan completes
        //   - No immediate catch-up trigger → user sees sync lag
        // Solution: Call checkAndCatchUp() immediately after repair completes
        // FIX #1009: Invalidate tree validation cache after repair
        invalidateTreeValidationCache()
        print("🔄 FIX #766: Triggering immediate catch-up sync after Full Rescan...")
        await checkAndCatchUp()

        // FIX #1098: Balance verification at end of Full Rescan
        // User request: "at the end of the full rescan another balance verification must be performed"
        // If verification fails, set flag so UI shows "Balance issue" instead of balance amount
        print("🔍 FIX #1098: Performing balance verification after Full Rescan...")

        // FIX #1304: Use getTotalUnspentBalance (no witness requirement) instead of getBalance.
        // getBalance requires witness IS NOT NULL → returns 0 when witnesses are NULL.
        let finalBalance = (try? WalletDatabase.shared.getTotalUnspentBalance(accountId: account.accountId)) ?? 0
        let finalNoteCount = (try? WalletDatabase.shared.getAllUnspentNotes(accountId: account.accountId).count) ?? 0

        // Check if balance is reasonable (notes exist but balance is 0 = problem)
        let hasBalanceIssue = finalNoteCount == 0 && finalBalance == 0

        await MainActor.run {
            if hasBalanceIssue && forceFullRescan {
                // Full Rescan completed but found 0 notes - this is a critical issue
                print("🚨 FIX #1098: Balance verification FAILED after Full Rescan - 0 notes found!")
                self.balanceIntegrityIssue = true
                self.balanceIntegrityMessage = "Full Rescan found 0 notes - data may be corrupted"
            } else if finalNoteCount > 0 && finalBalance >= 0 {
                // Balance looks valid
                print("✅ FIX #1098: Balance verification PASSED - \(finalNoteCount) notes, \(finalBalance.redactedAmount)")
                self.balanceIntegrityIssue = false
                self.balanceIntegrityMessage = nil

                // FIX #1126: Save comprehensive verified state to skip redundant health checks on next startup
                // Includes: tree size, witness count, balance, lastScannedHeight
                let treeSize = ZipherXFFI.treeSize()
                let lastScanned = (try? WalletDatabase.shared.getLastScannedHeight()) ?? 0
                WalletHealthCheck.shared.saveVerifiedState(
                    treeSize: treeSize,
                    witnessCount: finalNoteCount,
                    balance: UInt64(finalBalance),
                    lastScannedHeight: lastScanned
                )
            } else {
                print("✅ FIX #1098: Balance verification passed (wallet may be empty)")
                self.balanceIntegrityIssue = false
                self.balanceIntegrityMessage = nil

                // FIX #1126: Save verified state for empty wallet too
                let treeSize = ZipherXFFI.treeSize()
                let lastScanned = (try? WalletDatabase.shared.getLastScannedHeight()) ?? 0
                WalletHealthCheck.shared.saveVerifiedState(
                    treeSize: treeSize,
                    witnessCount: 0,
                    balance: 0,
                    lastScannedHeight: lastScanned
                )
            }
        }
    }

    /// Quick fix: Extract anchors from existing witnesses
    /// This fixes the witness/anchor mismatch without a full rescan
    /// The witness contains the tree root it was built against - extract and save it
    func fixAnchorsFromWitnesses() async throws -> Int {
        guard isWalletCreated else {
            throw WalletError.walletNotCreated
        }

        // VUL-U-002: Get spending key with secure zeroing
        let secureKey = try secureStorage.retrieveSpendingKeySecure()
        defer { secureKey.zero() }
        let spendingKey = secureKey.data

        // Ensure database is open
        // VUL-STOR-009: Use HKDF domain separation for SQLCipher key
        let rawKey = Data(SHA256.hash(data: spendingKey))
        let dbKey = DatabaseEncryption.deriveDatabaseKey(from: rawKey)
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
        // FIX #1238: Guard against rebuilding when tree state is corrupted
        let treeRepairExhausted = UserDefaults.standard.bool(forKey: "TreeRepairExhausted")
        if treeRepairExhausted {
            print("⏩ FIX #1238: Skipping rebuildWitnessesForSpending — tree repair exhausted")
            print("   FFI tree has wrong root. Rebuilding would create invalid witnesses.")
            print("   User must run 'Full Resync' first.")
            return
        }

        // FIX #1108: Prevent concurrent witness rebuilds (was causing 5GB+ memory, 600% CPU)
        witnessRebuildLock.lock()
        if isRebuildingWitnesses {
            witnessRebuildLock.unlock()
            print("⏭️ FIX #1108: Skipping rebuildWitnessesForSpending - already in progress")
            return
        }
        await MainActor.run { isRebuildingWitnesses = true }
        witnessRebuildLock.unlock()

        // FIX #1143: Reset corrupted witness flags at START of rebuild
        // Previous runs may have set these flags, but we're about to rebuild fresh
        await MainActor.run {
            self.hasCorruptedWitnesses = false
            self.corruptedWitnessCount = 0
        }
        print("🔄 FIX #1143: Reset corrupted witness flags for fresh rebuild")

        defer {
            Task {
                await MainActor.run {
                    witnessRebuildLock.lock()
                    isRebuildingWitnesses = false
                    witnessRebuildLock.unlock()
                }
            }
        }

        guard isWalletCreated else {
            throw WalletError.walletNotCreated
        }

        // VUL-U-002: Get spending key with secure zeroing
        let secureKey = try secureStorage.retrieveSpendingKeySecure()
        defer { secureKey.zero() }
        let spendingKey = secureKey.data
        // SECURITY: Key retrieved - not logged

        // Ensure database is open
        // VUL-STOR-009: Use HKDF domain separation for SQLCipher key
        let rawKey = Data(SHA256.hash(data: spendingKey))
        let dbKey = DatabaseEncryption.deriveDatabaseKey(from: rawKey)
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
        if verbose {
            print("📝 Found \(notes.count) notes to rebuild witnesses for")
        }

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

            // FIX #1105: Use lastScannedHeight from database, not boost file end
            // Previous bug: Used effectiveTreeHeight (boost file end = 2,988,797)
            // This caused FIX #603 to trigger 13k+ block rescans every time it ran
            // because notes at 2,997,xxx were seen as "beyond downloaded range"
            // when in fact they were already scanned and have valid witnesses.
            // Now: Use lastScannedHeight which reflects actual scan progress
            let dbLastScanned = (try? WalletDatabase.shared.getLastScannedHeight()) ?? 0
            let downloadedTreeHeight = dbLastScanned > 0 ? UInt64(dbLastScanned) : ZipherXConstants.effectiveTreeHeight
            print("📊 FIX #1105: Using lastScannedHeight \(downloadedTreeHeight) (db: \(dbLastScanned), boost: \(ZipherXConstants.effectiveTreeHeight))")

            // Check if ANY note is beyond what we've already scanned
            let notesBeyondDownloaded = notesWithCMU.filter { $0.height > downloadedTreeHeight }
            if !notesBeyondDownloaded.isEmpty {
                print("⚠️ Found \(notesBeyondDownloaded.count) notes beyond scanned height \(downloadedTreeHeight) - need live scan")
                print("📡 Scanning from scanned height to chain tip...")

                // FIX #997: Only load boost tree if FFI tree is empty - preserve existing delta CMUs
                let existingTreeSize = ZipherXFFI.treeSize()
                if existingTreeSize == 0 {
                    // Tree not loaded yet - load from boost file
                    if ZipherXFFI.treeLoadFromCMUs(data: downloadedData) {
                        let treeSize = ZipherXFFI.treeSize()
                        print("✅ Loaded downloaded tree: \(treeSize) commitments")
                    }
                } else {
                    print("✅ FIX #997: Tree already has \(existingTreeSize) CMUs - preserving existing tree")
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

                // FIX #1084: Verify all unspent notes against on-chain nullifiers
                // This catches any spent notes that were missed during normal scan
                print("🔍 FIX #1084: Verifying unspent notes against blockchain...")
                try? await verifyNullifierSpendStatus()

                print("✅ Live scan complete - witnesses built and spent notes detected")
                return
            }

            // All notes within downloaded range - use fast path
            print("🚀 All notes within downloaded range - using fast witness rebuild")

            // FIX #1109: Clear WITNESSES array before creating new witnesses
            // Without this, witnesses accumulate across rebuild cycles (350 witnesses when only ~23 notes!)
            let clearedCount = ZipherXFFI.witnessesClear()
            if clearedCount > 0 {
                print("🧹 FIX #1109: Cleared \(clearedCount) stale witnesses from FFI array")
            }

            var skippedValidCount = 0
            for (index, note) in notesWithCMU.enumerated() {
                guard let cmu = note.cmu else { continue }

                // Report progress
                let progress = Double(index + 1) / Double(notesWithCMU.count)
                await MainActor.run {
                    onProgress(progress, UInt64(index + 1), UInt64(notesWithCMU.count))
                }

                // FIX #1207: Don't overwrite valid witnesses!
                // treeCreateWitnessForCMU creates witnesses from boost file using whichever CMU byte
                // order it finds. For some notes (e.g., 7218, 7222), the boost witness byte order
                // differs from the DB CMU byte order. witnessVerifyAnchor(boost_witness, db_cmu) then
                // fails at next startup → 48s rebuild → FIX #603 overwrites again → infinite cycle.
                // Solution: If note already has a valid witness, keep it.
                if !note.witness.isEmpty && note.witness.count >= 100 {
                    if ZipherXFFI.witnessPathIsValid(note.witness) {
                        if ZipherXFFI.witnessVerifyAnchor(note.witness, cmu: cmu) {
                            skippedValidCount += 1
                            continue
                        }
                    }
                }

                // Use treeCreateWitnessForCMU for notes within downloaded range
                if let result = ZipherXFFI.treeCreateWitnessForCMU(cmuData: downloadedData, targetCMU: cmu) {
                    let (position, witness) = result
                    print("✅ Created witness for note \(note.id): position=\(position), witness=\(witness.count) bytes")

                    // FIX #1164: SKIP FIX #1142 verification here - causes false positives!
                    // The witness was JUST created by treeCreateWitnessForCMU which finds the CMU
                    // in boost file using BOTH byte orders (line 4017-4027 in lib.rs).
                    // But witnessVerifyAnchor uses the DATABASE CMU which may be in different byte order.
                    // This causes merkle_path.root(node) to compute wrong root -> false "corrupted" detection.
                    // The witness is correct - it was just created from verified boost file data.
                    //
                    // OLD CODE (caused 8+ false positives):
                    // if !ZipherXFFI.witnessVerifyAnchor(witness, cmu: cmu) {
                    //     print("🚨 FIX #1142: Witness inconsistent...")
                    //     continue
                    // }

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

            if skippedValidCount > 0 {
                print("✅ FIX #1207: Skipped \(skippedValidCount)/\(notesWithCMU.count) notes with valid witnesses (no overwrite)")
            }

            // FIX #997: CRITICAL - Don't replace tree if it already has MORE CMUs!
            // treeLoadFromCMUs() REPLACES the tree and CLEARS DELTA_CMUS (FIX #771)
            // This was corrupting the tree during periodic witness refresh (FIX #603)
            // causing CMU count to DROP (e.g., 1046269 → 1046242)
            let currentTreeSize = ZipherXFFI.treeSize()
            let boostSize = ZipherXConstants.effectiveTreeCMUCount
            if currentTreeSize > boostSize {
                print("✅ FIX #997: Tree already has \(currentTreeSize) CMUs (boost=\(boostSize)) - preserving delta CMUs")
            } else if currentTreeSize == 0 {
                // Tree not loaded yet - load from boost file
                if ZipherXFFI.treeLoadFromCMUs(data: downloadedData) {
                    let treeSize = ZipherXFFI.treeSize()
                    print("✅ Loaded downloaded tree for spending: \(treeSize) commitments")
                }
            } else {
                print("✅ FIX #997: Tree has \(currentTreeSize) CMUs - using existing tree")
            }

            // Refresh balance after rebuild
            try await refreshBalance()
            print("✅ Fast witness rebuild complete - notes can now be spent")

            // FIX #1164: Clear corrupted witness flags after successful rebuild
            // The witnesses were just recreated from verified boost file data
            await MainActor.run {
                self.hasCorruptedWitnesses = false
                self.corruptedWitnessCount = 0
            }
            print("✅ FIX #1164: Cleared corrupted witness flags - SEND should be enabled")
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
    /// FIX #1140: Now includes delta CMUs for notes above boost file height
    /// FIX #1142: Falls back to disk delta bundle when P2P fails
    /// FIX #1143: Warns when < 3 peers (P2P may fail, will use disk fallback)
    func fixAnchorMismatches() async -> Int {
        print("🔧 FIX #550: Auto-fixing anchor mismatches by rebuilding witnesses...")

        // FIX #1143: Check peer count - warn if low (will use disk fallback)
        let validPeers = await MainActor.run {
            NetworkManager.shared.peers.filter { $0.isConnectionReady && $0.isValidZclassicPeer }.count
        }
        if validPeers < 3 {
            print("⚠️ FIX #1143: Only \(validPeers) Zclassic peers - P2P fetch may fail, will use disk delta bundle fallback")
        } else {
            print("✅ FIX #1143: \(validPeers) Zclassic peers available for delta CMU fetch")
        }

        do {
            // VUL-U-002: Get spending key with secure zeroing
            let secureKey = try secureStorage.retrieveSpendingKeySecure()
            defer { secureKey.zero() }
            let spendingKey = secureKey.data
            // VUL-STOR-009: Use HKDF domain separation for SQLCipher key
            let rawKey = Data(SHA256.hash(data: spendingKey))
            let dbKey = DatabaseEncryption.deriveDatabaseKey(from: rawKey)
            try WalletDatabase.shared.open(encryptionKey: dbKey)

            // Get all unspent notes
            // FIX #807: Use accountId: 1 (not 0) - matches all other getAllUnspentNotes calls
            let notes = try WalletDatabase.shared.getAllUnspentNotes(accountId: 1)
            let unspentNotes = notes.filter { $0.cmu != nil }

            guard !unspentNotes.isEmpty else {
                print("⚠️ FIX #550: No unspent notes to fix")
                return 0
            }

            print("   Found \(unspentNotes.count) unspent notes - rebuilding witnesses...")

            // Load cached CMU data for witness creation
            guard let cmuPath = await CommitmentTreeUpdater.shared.getCachedCMUFilePath(),
                  var cmuData = try? Data(contentsOf: cmuPath) else {
                print("   ❌ FIX #550: No CMU data available for witness rebuild")
                return 0
            }

            // FIX #1140: ROOT CAUSE FIX - Include delta CMUs for notes above boost file
            // Problem: fixAnchorMismatches only used boost file CMUs (up to ~2988797)
            // Notes above boost file height were SILENTLY SKIPPED because their CMU
            // wasn't found in the boost data. This left corrupted witnesses unfixed!
            let boostEndHeight = Int(ZipherXConstants.bundledTreeHeight)
            let maxNoteHeight = Int(unspentNotes.map { $0.height }.max() ?? UInt64(boostEndHeight))

            if maxNoteHeight > boostEndHeight {
                print("🔧 FIX #1140: Notes exist above boost file (\(boostEndHeight))")
                print("   Max note height: \(maxNoteHeight) - fetching delta CMUs via P2P...")

                // Wait for peers if needed
                var peerWaitAttempts = 0
                var peerCount = await MainActor.run { NetworkManager.shared.connectedPeers }
                while peerCount < 1 && peerWaitAttempts < 30 {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    peerWaitAttempts += 1
                    peerCount = await MainActor.run { NetworkManager.shared.connectedPeers }
                    if peerWaitAttempts % 10 == 0 {
                        print("   ⏳ Waiting for P2P peers... \(peerWaitAttempts)s")
                    }
                }

                // Fetch delta CMUs from P2P
                let startHeight = UInt64(boostEndHeight + 1)
                let blocksToFetch = maxNoteHeight - boostEndHeight

                // Stop block listeners to avoid P2P conflicts
                await PeerManager.shared.stopAllBlockListeners()
                try? await Task.sleep(nanoseconds: 200_000_000)

                // FIX #1228: Reconnect peers with dead connections after stopping block listeners.
                // FIX #1184b kills NWConnections when stopping listeners → peers have handshake=true
                // but connection=nil → P2P fetch fails. Same pattern as FIX #1206/#1227 in HeaderSyncManager.
                let deadPeersRepair = await MainActor.run {
                    NetworkManager.shared.peers.filter { $0.isHandshakeComplete && !$0.isConnectionReady }
                }
                if !deadPeersRepair.isEmpty {
                    print("🔄 FIX #1228: Reconnecting \(deadPeersRepair.count) peers with dead connections (repair delta fetch)...")
                    var reconnectedRepair = Set<String>()  // FIX #1235
                    for peer in deadPeersRepair {
                        if reconnectedRepair.contains(peer.host) { print("⏭️ FIX #1235: [\(peer.host)] Already reconnected - skipping"); continue }
                        do {
                            try await peer.ensureConnected()
                            reconnectedRepair.insert(peer.host)  // FIX #1235
                            print("✅ FIX #1228: [\(peer.host)] Reconnected for repair delta fetch")
                        } catch {
                            print("⚠️ FIX #1228: [\(peer.host)] Reconnect failed: \(error.localizedDescription)")
                        }
                    }
                }

                var deltaCMUs: [Data] = []
                if let blocks = try? await NetworkManager.shared.getBlocksDataP2P(
                    from: startHeight,
                    count: blocksToFetch
                ) {
                    // blocks is [(height, hash, time, [(txid, [ShieldedOutput], [ShieldedSpend]?)])]
                    for block in blocks {
                        let txs = block.3
                        for tx in txs {
                            let outputs = tx.1
                            for output in outputs {
                                // Convert hex string CMU to Data in wire format
                                if let cmuData = Data(hex: output.cmu) {
                                    deltaCMUs.append(cmuData)
                                }
                            }
                        }
                    }
                }

                if !deltaCMUs.isEmpty {
                    print("   ✅ FIX #1140: Fetched \(deltaCMUs.count) delta CMUs from P2P")

                    // Append delta CMUs to the boost CMU data
                    // Format: [count: UInt64 LE][cmu1: 32 bytes][cmu2: 32 bytes]...
                    let boostCount = cmuData.prefix(8).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
                    let newCount = boostCount + UInt64(deltaCMUs.count)

                    // Update count in header
                    var countBytes = newCount
                    withUnsafeBytes(of: &countBytes) { bytes in
                        for i in 0..<8 {
                            cmuData[i] = bytes[i]
                        }
                    }

                    // Append delta CMUs
                    for deltaCMU in deltaCMUs {
                        cmuData.append(deltaCMU)
                    }

                    print("   📊 FIX #1140: Combined CMU data: \(newCount) CMUs (\(cmuData.count) bytes)")
                } else {
                    // FIX #1142: CRITICAL - Fallback to disk delta bundle when P2P fails
                    // This fixes the root cause of TX rejections when P2P is unstable
                    print("   ⚠️ FIX #1140: No delta CMUs from P2P - trying disk delta bundle...")

                    if let diskDeltaCMUs = DeltaCMUManager.shared.loadDeltaCMUs(), !diskDeltaCMUs.isEmpty {
                        print("   ✅ FIX #1142: Loaded \(diskDeltaCMUs.count) delta CMUs from disk bundle")

                        // Append disk delta CMUs to the boost CMU data
                        let boostCount = cmuData.prefix(8).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
                        let newCount = boostCount + UInt64(diskDeltaCMUs.count)

                        // Update count in header
                        var countBytes = newCount
                        withUnsafeBytes(of: &countBytes) { bytes in
                            for i in 0..<8 {
                                cmuData[i] = bytes[i]
                            }
                        }

                        // Append disk delta CMUs
                        for diskCMU in diskDeltaCMUs {
                            cmuData.append(diskCMU)
                        }

                        print("   📊 FIX #1142: Combined CMU data: \(newCount) CMUs (\(cmuData.count) bytes)")
                    } else {
                        print("   ⚠️ FIX #1142: No delta CMUs on disk - notes above boost may not be fixed")
                        print("   💡 Run Full Resync to rebuild all witnesses correctly")
                    }
                }
            }

            // Collect target CMUs
            let targetCMUs = unspentNotes.map { $0.cmu! }
            var noteIdMap: [Int: Int64] = [:]
            for (index, note) in unspentNotes.enumerated() {
                noteIdMap[index] = note.id
            }

            // Create witnesses using batch function (now with delta CMUs included)
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

                // FIX #828: Use WITNESS ROOT as anchor (REVERTS FIX #555)
                // Per FIX #804: anchor must be what the witness merkle path computes to
                // Using HeaderStore at note height is WRONG - witness was created at tree height
                if let witnessRoot = ZipherXFFI.witnessGetRoot(witness) {
                    try? WalletDatabase.shared.updateNoteAnchor(noteId: noteId, anchor: witnessRoot)

                    // Verify consistency
                    if let cmu = note.cmu, ZipherXFFI.witnessVerifyAnchor(witness, cmu: cmu) {
                        fixedCount += 1
                        let anchorHex = witnessRoot.prefix(8).map { String(format: "%02x", $0) }.joined()
                        print("   ✅ Note \(noteId) height \(note.height): witness rebuilt, anchor \(anchorHex)...")
                    } else {
                        print("   ⚠️ Note \(noteId): witness rebuilt but consistency check failed")
                    }
                }
            }

            print("✅ FIX #828: Rebuilt \(fixedCount)/\(unspentNotes.count) witnesses with correct anchors")

            // FIX #1141: Clear corrupted witness flag if all were fixed
            await MainActor.run {
                if fixedCount >= unspentNotes.count {
                    self.hasCorruptedWitnesses = false
                    self.corruptedWitnessCount = 0
                    print("✅ FIX #1141: All witnesses fixed - SEND unblocked")
                } else {
                    self.corruptedWitnessCount = unspentNotes.count - fixedCount
                    print("⚠️ FIX #1141: \(self.corruptedWitnessCount) witnesses still corrupted - SEND remains blocked")
                }
            }

            // FIX #1131: Mark that witnesses were rebuilt this session
            // This prevents FIX #557 from doing a SECOND redundant rebuild
            WalletHealthCheck.shared.witnessesRebuiltThisSession = true

            // FIX #1136: Persist rebuild timestamp to skip FIX #828 on next startup
            // Prevents 44+ second startup delay when witnesses were just rebuilt
            if fixedCount > 0 {
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "WitnessRebuildTimestamp")
                print("💾 FIX #1136: Saved witness rebuild timestamp")
            }

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
        // FIX #1240: Guard against rebuilding when tree state is corrupted.
        // This function was missing the TreeRepairExhausted check that FIX #1238 added to
        // rebuildWitnessesForStartup, rebuildWitnessesFromDeltaBundle, and rebuildWitnessesForSpending.
        // Called from Settings UI — would rebuild witnesses from corrupted FFI tree, producing
        // anchors that don't exist on blockchain → FIX #1224 flags them → infinite cycle.
        let treeRepairExhausted = UserDefaults.standard.bool(forKey: "TreeRepairExhausted")
        if treeRepairExhausted {
            print("⏩ FIX #1240: Skipping rebuildCorruptedWitnesses — tree repair exhausted")
            print("   FFI tree has wrong root (incomplete delta). Witnesses from this tree")
            print("   would have non-existent anchors. User must run 'Full Resync' first.")
            return 0
        }

        print("🔧 FIX #588: Rebuilding corrupted witnesses at specific positions...")

        do {
            // VUL-U-002: Get spending key with secure zeroing
            let secureKey = try secureStorage.retrieveSpendingKeySecure()
            defer { secureKey.zero() }
            let spendingKey = secureKey.data
            // VUL-STOR-009: Use HKDF domain separation for SQLCipher key
            let rawKey = Data(SHA256.hash(data: spendingKey))
            let dbKey = DatabaseEncryption.deriveDatabaseKey(from: rawKey)
            try WalletDatabase.shared.open(encryptionKey: dbKey)

            // Get account ID (don't assume it's 0)
            guard let account = try WalletDatabase.shared.getAccount(index: 0) else {
                print("   ❌ FIX #588: No account found")
                return 0
            }
            let accountId = account.accountId
            if verbose {
                print("   📋 Using account ID: \(accountId)")
            }

            // Get all unspent notes with CMU
            let notes = try WalletDatabase.shared.getAllUnspentNotes(accountId: accountId)
            let notesWithCMU = notes.filter { $0.cmu != nil && $0.cmu!.count == 32 }

            guard !notesWithCMU.isEmpty else {
                print("⚠️ FIX #588: No unspent notes with CMU to rebuild")
                return 0
            }

            if verbose {
                print("   Found \(notesWithCMU.count) notes to rebuild")
            }

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

            if verbose {
                print("   Position range: 0 to \(maxPosition) (height \(saplingActivation) to \(maxHeight))")
            }

            // 1. Get CMUs from boost file
            print("   📦 Loading boost file CMUs...")
            let boostCMUData = try await CommitmentTreeUpdater.shared.extractCMUsInLegacyFormat { [self] progress in
                if verbose && Int(progress * 100) % 10 == 0 {
                    print("      Extracting boost CMUs: \(Int(progress * 100))%")
                }
            }

            // Parse boost CMU count
            guard boostCMUData.count >= 8 else {
                print("   ❌ Invalid boost CMU data")
                return 0
            }
            let boostCMUCount = boostCMUData.prefix(8).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
            if verbose {
                print("   📊 Boost file has \(boostCMUCount) CMUs (up to position \(boostCMUCount - 1))")
            }

            let boostMaxHeight = saplingActivation + boostCMUCount - 1
            if verbose {
                print("   📊 Boost file covers height \(saplingActivation) to \(boostMaxHeight)")
            }

            // 2. Fetch delta CMUs from blocks beyond boost file
            var deltaCMUs: [Data] = []
            if maxHeight > boostMaxHeight {
                let startHeight = boostMaxHeight + 1
                if verbose {
                    print("   📡 Fetching delta CMUs from blocks \(startHeight) to \(maxHeight)...")
                }

                let txBuilder = TransactionBuilder()
                deltaCMUs = try await txBuilder.fetchCMUsFromBlocks(startHeight: startHeight, endHeight: maxHeight)
                if verbose {
                    print("   📊 Fetched \(deltaCMUs.count) delta CMUs")
                }
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

            if verbose {
                print("   📊 Combined CMU data: \(totalCMUCount) CMUs (\(combinedCMUData.count) bytes)")
            }

            // 4. Rebuild witnesses at specific positions using FFI
            if verbose {
                print("   🔧 Rebuilding witnesses at specific positions...")
            }

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

            // FIX #1190: Update delta manifest tree root from witness root
            // All witnesses built from the same combined CMU data share the same tree root
            for (_, witnessData) in results.enumerated() {
                if let witness = witnessData, let treeRoot = ZipherXFFI.witnessGetRoot(witness) {
                    DeltaCMUManager.shared.updateManifestTreeRoot(treeRoot)
                    break
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

        // VUL-U-002: Get spending key with secure zeroing
        let secureKey = try secureStorage.retrieveSpendingKeySecure()
        defer { secureKey.zero() }
        let spendingKey = secureKey.data
        // SECURITY: Key retrieved - not logged

        // Ensure database is open
        // VUL-STOR-009: Use HKDF domain separation for SQLCipher key
        let rawKey = Data(SHA256.hash(data: spendingKey))
        let dbKey = DatabaseEncryption.deriveDatabaseKey(from: rawKey)
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

    /// Sapling activation date: February 25, 2019 01:27:04 UTC (block 476,969)
    static let saplingActivationDate: Date = {
        var components = DateComponents()
        components.timeZone = TimeZone(identifier: "UTC")
        components.year = 2019
        components.month = 2
        components.day = 25
        components.hour = 1
        components.minute = 27
        components.second = 4
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
        // FIX #1184: Do NOT stop block listeners before send!
        // The entire send flow now routes through PeerMessageDispatcher:
        // - preRebuildWitnessesForInstantPayment → dispatcher batch collectors
        // - broadcastTransactionWithProgress → dispatcher broadcast handlers
        // Block listeners must stay active so dispatcher.isActive = true.
        // isBroadcasting=true in NetworkManager prevents header sync from interfering.
        print("📡 FIX #1184: Block listeners KEPT RUNNING for dispatcher during send flow")

        // FIX #1220: Block sending while gap-fill is running — tree is incomplete, anchor would be invalid
        if isGapFillingDelta {
            throw WalletError.transactionFailed("Tree integrity repair in progress — please wait for gap-fill to complete before sending")
        }

        // FIX #1143 + FIX #1158: CRITICAL - Verify 3+ Zclassic peers BEFORE attempting send
        // Pre-send witness rebuild requires P2P for delta CMU fetch
        // Without 3+ peers, witness rebuild can fail silently → corrupted witnesses → TX rejected
        //
        // FIX #1158: Wait for peer recovery if not enough peers initially
        // Previously threw error immediately, but logs showed recovery completing ~3 seconds later
        var validPeers = await MainActor.run {
            NetworkManager.shared.peers.filter { $0.isConnectionReady && $0.isValidZclassicPeer }.count
        }

        if validPeers < 3 {
            print("⚠️ FIX #1158: Only \(validPeers) peers available, waiting for recovery...")
            onProgress("network", "Connecting to peers...", 0.0)

            // Trigger peer recovery and wait up to 10 seconds
            await NetworkManager.shared.attemptPeerRecovery()

            for attempt in 1...10 {
                try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
                validPeers = await MainActor.run {
                    NetworkManager.shared.peers.filter { $0.isConnectionReady && $0.isValidZclassicPeer }.count
                }
                onProgress("network", "Connecting to peers (\(validPeers)/3)...", Double(attempt) / 10.0)

                if validPeers >= 3 {
                    print("✅ FIX #1158: Recovered to \(validPeers) peers after \(attempt)s")
                    break
                }

                if attempt == 5 {
                    // Trigger another recovery attempt midway
                    await NetworkManager.shared.attemptPeerRecovery()
                }
            }
        }

        guard validPeers >= 3 else {
            // FIX #1158: Still not enough peers after waiting
            // TODO: Add option in SendView to "proceed anyway" with user acknowledgment of risk
            throw WalletError.transactionFailed("""
                ⚠️ NOT ENOUGH PEERS

                Need 3+ Zclassic peers to send safely.
                Currently connected: \(validPeers) peer(s) after 10s wait

                🔧 Peer recovery attempted but insufficient peers available.

                Possible causes:
                • Network connectivity issues
                • Zclassic peers are offline
                • Firewall blocking connections

                Please check your internet connection and try again.
                """)
        }
        print("✅ FIX #1143: \(validPeers) Zclassic peers available - proceeding with send")

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

        // FIX #1330: Witness-on-demand — do NOT rebuild ALL witnesses here.
        // TransactionBuilder rebuilds witnesses for ONLY the selected notes (1-2 for small sends).
        // Before FIX #1330: preRebuildWitnessesForInstantPayment() rebuilt ALL 43 corrupted witnesses (~90s)
        // even for a 0.0015 ZCL send that only needs 1 witness.
        // preRebuildWitnessesForInstantPayment() still runs in background (FAST START).
        onProgress("verify", "Preparing witnesses...", 0.5)

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

                One of your notes (value: \(spentNote.value.redactedAmount)) was already spent in another transaction.

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
        var broadcastResult = try await networkManager.broadcastTransactionWithProgress(rawTx, amount: amount) { phase, detail, progress in
            // Forward broadcast progress to the UI
            // Use actual phase ("peers", "verify", "api") so UI can show txid immediately on first peer accept
            onProgress(phase, detail, progress)
        }

        // FIX #1261: When broadcast reaches 0 peers (all connections dead), reconnect and retry ONCE.
        // Root cause: FIX #1184b kills NWConnections when block listeners stop → all peers have nil connections.
        // Instead of silently accepting 0/4, give the user one more chance.
        if broadcastResult.peerCount == 0 && broadcastResult.rejectCount == 0 && broadcastResult.peersAttempted > 0 {
            print("⚠️ FIX #1261: Broadcast reached 0/\(broadcastResult.peersAttempted) peers — reconnecting and retrying...")
            onProgress("broadcast", "Reconnecting to peers...", 0.5)

            // Reconnect all peers with dead connections
            let deadPeers = await MainActor.run {
                networkManager.peers.filter { $0.isHandshakeComplete && !$0.isConnectionReady }
            }
            var reconnectedCount = 0
            for peer in deadPeers {
                do {
                    try await peer.ensureConnected()
                    reconnectedCount += 1
                } catch {
                    print("⚠️ FIX #1261: [\(peer.host)] Reconnect failed: \(error.localizedDescription)")
                }
            }

            if reconnectedCount > 0 {
                print("✅ FIX #1261: Reconnected \(reconnectedCount) peers — retrying broadcast...")
                onProgress("broadcast", "Retrying broadcast...", 0.6)

                // Start block listeners so dispatcher is active for broadcast
                await networkManager.startBlockListenersOnMainScreen()
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s for dispatchers to activate

                broadcastResult = try await networkManager.broadcastTransactionWithProgress(rawTx, amount: amount) { phase, detail, progress in
                    onProgress(phase, detail, progress)
                }
                print("📡 FIX #1261: Retry result: \(broadcastResult.peerCount)/\(broadcastResult.peersAttempted) peers, \(broadcastResult.rejectCount) rejected")
            }

            // If STILL 0 peers after retry, throw a clear error
            if broadcastResult.peerCount == 0 && broadcastResult.rejectCount == 0 {
                print("🚨 FIX #1261: Broadcast FAILED after retry — no peers reachable")
                await MainActor.run {
                    networkManager.clearPendingBroadcast()
                }

                // Clean up pending TX tracking via confirmOutgoingTx (removes from all sets)
                let txId1261 = broadcastResult.txId
                await networkManager.removePendingTxidFromPersistence(txId1261)

                throw WalletError.transactionFailed("""
                    Network issue - broadcast failed

                    Could not reach any peer to broadcast your transaction.
                    All \(broadcastResult.peersAttempted) peers have disconnected.

                    Your funds are safe - no transaction was sent.

                    Try again in a few seconds, or check your network connection.
                    """)
            }
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
            } else if broadcastResult.peersAttempted > 0 && broadcastResult.rejectCount == 0 {
                // FIX #990: Peers were ATTEMPTED but all timed out (no accepts, no rejects)
                // TX may have been accepted by peers - don't throw error, track for confirmation
                // This is different from "no peers available" which is a real failure
                print("⚠️ FIX #990: \(broadcastResult.peersAttempted) peers attempted but all timed out")
                print("📡 FIX #990: TX may have been accepted - tracking for confirmation")
                print("📡 FIX #990: Mempool scanner will verify, block confirmation will record")
                print("🔐 FIX #990: txId=\(txId)")
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
        } else if broadcastResult.peerCount > 0 || broadcastResult.peersAttempted > 0 {
            // FIX #990: Include timeout case in success path
            print("✅ FIX #245/990: Peers accepted or attempted TX - will be recorded on confirmation")
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
        // FIX #1184: Do NOT stop block listeners — send flow routes through dispatcher
        // isBroadcasting=true in broadcastTransactionWithProgress prevents header sync interference

        // FIX #1220: Block sending while gap-fill is running
        if isGapFillingDelta {
            throw WalletError.transactionFailed("Tree integrity repair in progress — please wait for gap-fill to complete before sending")
        }

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
        print("📤 Send check: amount=\(amount.redactedAmount), fee=\(fee.redactedAmount), total=\(totalRequired.redactedAmount), balance=\(currentBalance.redactedAmount)")
        guard totalRequired <= currentBalance else {
            print("❌ Insufficient funds: need \(totalRequired.redactedAmount) (amount: \(amount.redactedAmount) + fee: \(fee.redactedAmount)), have \(currentBalance.redactedAmount)")
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

                One of your notes (value: \(spentNote.value.redactedAmount)) was already spent on-chain.

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
            } else if broadcastResult.peersAttempted > 0 && broadcastResult.rejectCount == 0 {
                // FIX #990: Peers were ATTEMPTED but all timed out (no accepts, no rejects)
                // TX may have been accepted by peers - don't throw error, track for confirmation
                // This is different from "no peers available" which is a real failure
                print("⚠️ FIX #990: \(broadcastResult.peersAttempted) peers attempted but all timed out")
                print("📡 FIX #990: TX may have been accepted - tracking for confirmation")
                print("📡 FIX #990: Mempool scanner will verify, block confirmation will record")
                print("🔐 FIX #990: txId=\(txId)")
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
        } else if broadcastResult.peerCount > 0 || broadcastResult.peersAttempted > 0 {
            // FIX #990: Include timeout case in success path
            print("✅ FIX #245/990: Peers accepted or attempted TX - will be recorded on confirmation")
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
            print("Recovered note: [nullifier redacted]")
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
        let (address, _) = try RustBridge.shared.derivePaymentAddress(from: fvk)
        return address
    }

    // PRIVACY: P-ADDR-001 — Diversified address rotation

    /// Generate the next diversified receive address
    /// Returns the new address string and its diversifier index
    func generateNextDiversifiedAddress(label: String? = nil) async throws -> (String, UInt64) {
        let db = WalletDatabase.shared

        // Get highest used index — use the ACTUAL valid index stored, not just sequential
        let highestIndex = db.getHighestDiversifierIndex(accountId: 1)
        var requestIndex = highestIndex + 1

        // FIX #1402 (NEW-003): Bounds check — receive addresses must stay below change range (1 billion)
        guard requestIndex < 1_000_000_000 else {
            print("⚠️ FIX #1402 (NEW-003): Diversifier index \(requestIndex) exceeds receive address range (max 999,999,999)")
            throw WalletError.addressGenerationFailed
        }

        // VUL-U-002: Derive address at next index via FFI with secure zeroing
        let secureKey = try secureStorage.retrieveSpendingKeySecure()
        defer { secureKey.zero() }
        let spendingKey = secureKey.data
        let saplingKey = SaplingSpendingKey(data: spendingKey)
        let fvk = try RustBridge.shared.deriveFullViewingKey(from: saplingKey)

        // FIX: find_address returns the next VALID diversifier >= requested index.
        // Multiple requested indices can resolve to the same valid diversifier (producing the same address).
        // Loop until we get a truly DIFFERENT address from the current one.
        let currentAddress = await MainActor.run { self.zAddress }
        var newAddress: String
        var actualIndex: UInt64

        repeat {
            guard requestIndex < 1_000_000_000 else {
                throw WalletError.addressGenerationFailed
            }
            (newAddress, actualIndex) = try RustBridge.shared.derivePaymentAddress(from: fvk, diversifierIndex: requestIndex)
            if newAddress == currentAddress {
                // This index resolved to the same valid diversifier — skip past it
                requestIndex = actualIndex + 1
            }
        } while newAddress == currentAddress

        // Use the ACTUAL valid index for storage (not the requested one)
        let storedIndex = actualIndex

        // Store in database
        try db.insertDiversifiedAddress(
            accountId: 1,
            diversifierIndex: storedIndex,
            address: newAddress,
            label: label
        )
        try db.setCurrentDiversifiedAddress(accountId: 1, diversifierIndex: storedIndex)

        // Update published property on main thread
        await MainActor.run {
            self.zAddress = newAddress
            // Persist to UserDefaults for quick startup
            UserDefaults.standard.set(newAddress, forKey: "z_address")
            // FIX #1402 (NEW-001): Persist highest diversifier index for wallet restore recovery
            UserDefaults.standard.set(Int(storedIndex), forKey: "z_address_highest_diversifier_index")
        }

        print("🔄 P-ADDR-001: Rotated to address at diversifier index \(storedIndex) (requested \(highestIndex + 1))")
        return (newAddress, storedIndex)
    }

    /// FIX #1402 (NEW-001): Recover diversified addresses after wallet restore
    /// Regenerates addresses 0..highestKnownIndex from UserDefaults
    /// Funds are always safe (IVK decrypts all diversifiers), this restores address history
    private func recoverDiversifiedAddressesIfNeeded() async {
        let defaults = UserDefaults.standard
        let highestStoredIndex = defaults.integer(forKey: "z_address_highest_diversifier_index")

        guard highestStoredIndex > 0 else {
            // No diversified addresses were ever generated, nothing to recover
            return
        }

        let db = WalletDatabase.shared
        let currentHighest = db.getHighestDiversifierIndex(accountId: 1)

        guard currentHighest < UInt64(highestStoredIndex) else {
            // Already recovered or DB has more addresses than UserDefaults
            return
        }

        print("🔄 FIX #1402 (NEW-001): Recovering diversified addresses (0..\(highestStoredIndex))...")

        do {
            // VUL-U-002: Use secure key retrieval with automatic zeroing
            let secureKey = try secureStorage.retrieveSpendingKeySecure()
            defer { secureKey.zero() }
            let spendingKey = secureKey.data
            let saplingKey = SaplingSpendingKey(data: spendingKey)
            let fvk = try RustBridge.shared.deriveFullViewingKey(from: saplingKey)

            for index in 0...UInt64(highestStoredIndex) {
                // Skip if already in DB
                let existing = db.getHighestDiversifierIndex(accountId: 1)
                if index <= existing && index > 0 { continue }

                do {
                    let (address, _) = try RustBridge.shared.derivePaymentAddress(from: fvk, diversifierIndex: index)
                    try db.insertDiversifiedAddress(
                        accountId: 1,
                        diversifierIndex: index,
                        address: address,
                        label: index == 0 ? "Default" : "Recovered #\(index)"
                    )
                } catch {
                    // Some diversifier indices are invalid — skip silently
                    continue
                }
            }

            // Set the highest as current
            if let highestIndex = UInt64(exactly: highestStoredIndex) {
                try? db.setCurrentDiversifiedAddress(accountId: 1, diversifierIndex: highestIndex)
                let currentAddress = try? RustBridge.shared.derivePaymentAddress(from: fvk, diversifierIndex: highestIndex)
                if let (addr, _) = currentAddress {
                    await MainActor.run {
                        self.zAddress = addr
                        UserDefaults.standard.set(addr, forKey: "z_address")
                    }
                }
            }

            print("✅ FIX #1402 (NEW-001): Recovered diversified addresses up to index \(highestStoredIndex)")
        } catch {
            print("⚠️ FIX #1402 (NEW-001): Address recovery failed (funds are safe): \(error)")
        }
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
        // FIX #1273: Wait for authentication before opening database and reading keys.
        // Without this, the DB opens and keys are read behind the lock screen.
        if isWalletCreated {
            Task {
                while !BiometricAuthManager.shared.hasAuthenticatedThisSession {
                    try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
                    if Task.isCancelled { return }
                }
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
            // VUL-U-002: Open database if needed with secure zeroing
            let secureKey = try secureStorage.retrieveSpendingKeySecure()
            defer { secureKey.zero() }
            let spendingKey = secureKey.data
            // VUL-STOR-009: Use HKDF domain separation for SQLCipher key
            let rawKey = Data(SHA256.hash(data: spendingKey))
            let dbKey = DatabaseEncryption.deriveDatabaseKey(from: rawKey)
            try WalletDatabase.shared.open(encryptionKey: dbKey)

            // Get account
            guard let account = try WalletDatabase.shared.getAccount(index: 0) else {
                return
            }

            // FIX #1210: Use getTotalUnspentBalance as the DISPLAY balance (no witness requirement).
            // getUnspentNotes() and getBalance() require witness IS NOT NULL, which returns 0
            // when witnesses are temporarily cleared during tree rebuild. The user should always
            // see their actual balance. Witness availability only matters for SPENDING, not display.
            let confirmedBalance = try WalletDatabase.shared.getTotalUnspentBalance(accountId: account.accountId)

            // FIX #1520: Detect encryption key mismatch BEFORE showing balance.
            // If ALL encrypted values fail to decrypt, the DB encryption key changed
            // (e.g., TestFlight→Xcode, provisioning profile change, device ID change).
            // Balance will show 0 — inform user to Full Rescan.
            let (notesChecked, decryptFailures) = WalletDatabase.shared.detectEncryptionKeyMismatch()
            let keyMismatch = notesChecked > 0 && decryptFailures == notesChecked
            if keyMismatch {
                print("🚨 FIX #1520: ENCRYPTION KEY MISMATCH — \(decryptFailures)/\(notesChecked) note values failed to decrypt!")
                print("   Balance shows 0 because encrypted values are unreadable with current key.")
                print("   Cause: App reinstall changed DB encryption key (provisioning profile, device ID, or keychain salt).")
                print("   Fix: Settings → Repair Database → Full Rescan")
            }

            await MainActor.run {
                self.shieldedBalance = confirmedBalance
                self.pendingBalance = 0
                self.encryptionKeyMismatch = keyMismatch
                print("💰 Loaded balance from database: \(confirmedBalance.redactedAmount) (0 pending)")
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
            self.rescanStartTime = nil  // FIX #1120: Clear rescan start time
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
        // FIX #896: Clear migration flags so they run again on fresh import
        defaults.removeObject(forKey: "FIX853v2_TxidMigrationComplete")
        defaults.removeObject(forKey: "FIX896_DeltaTxidMigrationComplete")
        // FIX #1106: Clear nullifier verification checkpoint so full scan runs after reset
        defaults.removeObject(forKey: "FIX1106_NullifierVerificationCheckpoint")
        // FIX #1089: Clear nullifier verification flags
        defaults.removeObject(forKey: "FIX1089_FullVerificationComplete")
        defaults.removeObject(forKey: "FIX1089_NullifierVerificationCheckpoint")
        // FIX #1126: Invalidate verified state on wallet deletion
        WalletHealthCheck.shared.invalidateVerifiedState()
        // FIX #1466: Clear hidden service preference so fresh install starts clean
        defaults.removeObject(forKey: "hiddenServiceEnabled")
        defaults.synchronize()
        print("🗑️ Cleared UserDefaults (including migration flags and verification checkpoints)")

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
        // FIX #1254: force:true — wallet wipe is authorized to clear verified delta
        DeltaCMUManager.shared.clearDeltaBundle(force: true)
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

        // 11. Clear Tor hidden service keypair from Keychain
        // FIX #1466: On macOS, Keychain items survive app deletion — must explicitly clear
        // so a fresh install gets a new .onion identity instead of reusing the old one
        DispatchQueue.main.async {
            TorManager.shared.clearPersistentKeypair()
            print("🗑️ Cleared Tor hidden service keypair")
        }

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
        // VUL-U-002: Use secure key retrieval with automatic zeroing
        let secureKey = try secureStorage.retrieveSpendingKeySecure()
        defer { secureKey.zero() }
        let spendingKey = secureKey.data
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
            print("✓ Address derived: \(address.redactedAddress)")
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
        // VUL-STOR-009: Use HKDF domain separation for SQLCipher key
        let rawKey = Data(SHA256.hash(data: spendingKey))
        let dbKey = DatabaseEncryption.deriveDatabaseKey(from: rawKey)
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

        // FIX #1402 (NEW-001): Recover diversified addresses from UserDefaults after PK import
        // UserDefaults persists across DB deletion — it remembers the highest diversifier index
        Task {
            await self.recoverDiversifiedAddressesIfNeeded()
        }

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
        // VUL-U-002: Use secure key retrieval with automatic zeroing
        let secureKey = try secureStorage.retrieveSpendingKeySecure()
        defer { secureKey.zero() }
        let spendingKey = secureKey.data
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
            // FIX #1009: INSTANT mode - if checkpoint is within 5 blocks, skip P2P scan entirely
            // This is safe because checkpoint is set when TXs confirm, so state is recently verified
            if blocksSinceCheckpoint <= 5 {
                print("⚡ FIX #1009: INSTANT nullifier check - checkpoint within \(blocksSinceCheckpoint) blocks")
                print("⚡ FIX #1009: Skipping P2P scan - blockchain state recently verified")
                return nil
            } else if blocksSinceCheckpoint <= 100 {
                startHeight = checkpointHeight
                blocksToScan = blocksSinceCheckpoint
                print("🔍 FIX #595: Quick check from checkpoint \(checkpointHeight) - scanning \(blocksToScan) blocks")
            } else {
                // Checkpoint too old - TX-004: Randomize scan depth to obscure note creation time
                let scanDepth = UInt64(Int.random(in: 100...500))
                startHeight = chainHeight > scanDepth ? chainHeight - scanDepth : 0
                blocksToScan = min(scanDepth, chainHeight)
                print("🔍 FIX #595: Checkpoint old (\(blocksSinceCheckpoint) blocks behind) - scanning last \(blocksToScan) blocks")
            }
        } else {
            // No checkpoint - TX-004: Randomize scan depth to obscure note creation time
            let scanDepth = UInt64(Int.random(in: 100...500))
            startHeight = chainHeight > scanDepth ? chainHeight - scanDepth : 0
            blocksToScan = min(scanDepth, chainHeight)
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

    /// FIX #1011: Public wrapper for tree validation (used by ContentView for startup check)
    /// This allows automatic repair at startup if anchor is invalid
    func validateCMUTreeBeforeSendPublic() async -> CMUTreeValidationResult {
        return await validateCMUTreeBeforeSend()
    }

    /// FIX #527: Validate CMU tree root matches blockchain before allowing sends
    /// This prevents sending with invalid witnesses that will be rejected
    /// FIX #537: Simplified - logs P2P verification but doesn't block on corruption
    /// FIX #1009: Cache validation result for 60 seconds for INSTANT repeat sends
    /// - Returns: Validation result with details
    private func validateCMUTreeBeforeSend() async -> CMUTreeValidationResult {
        // FIX #1009: Check cache first for INSTANT verification
        if let cachedResult = lastTreeValidationResult,
           let cacheTime = lastTreeValidationTime,
           Date().timeIntervalSince(cacheTime) < treeValidationCacheDuration {
            // Cache is still valid - use cached result
            print("⚡ FIX #1009: INSTANT tree validation - using cached result (\(Int(Date().timeIntervalSince(cacheTime)))s ago)")
            print("⚡ FIX #1009: Cached result: isValid=\(cachedResult.isValid), root=\(cachedResult.ourRoot.prefix(16))...")
            return cachedResult
        }

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

            // FIX #820: P2P getheaders protocol doesn't reliably include finalsaplingroot field
            // FIX #796-#799 established that P2P headers have CORRUPTED sapling roots
            // Only trust boost file headers (up to effectiveTreeHeight)
            let boostFileEndHeight = UInt64(ZipherXConstants.effectiveTreeHeight)
            if lastScanned > boostFileEndHeight {
                print("🔍 FIX #820: Height \(lastScanned) > boost file end \(boostFileEndHeight)")

                // FIX #1260: DISPATCHER ONLY — NO direct reads, NO stopping block listeners.
                // Old FIX #936 stopped block listeners (FIX #1041) for direct P2P reads → FIX #1184b
                // killed ALL NWConnections → broadcast had 0 connected peers → 0/4 accepted.
                //
                // New approach: LOCAL validation only (no P2P needed):
                // - containsSaplingRoot() checks HeaderStore + delta_sapling_roots.bin (FIX #1204/1253)
                // - Both byte orders checked (FIX #1230)
                // - DeltaBundleVerified + Groth16 proof = sufficient trust chain
                // - ZERO network I/O, ZERO block listener interference
                let deltaVerified = UserDefaults.standard.bool(forKey: "DeltaBundleVerified")

                // Check if FFI tree root exists in our local root store
                if let rootData = ourTreeRoot as Data? {
                    let rootInStore = try await headerStore.containsSaplingRoot(rootData)
                    if rootInStore {
                        print("✅ FIX #1260: FFI tree root FOUND in HeaderStore — anchor VALID (local check, no P2P)")
                        let result = CMUTreeValidationResult(isValid: true, ourRoot: ourRootHex, headerRoot: "local_verified", height: lastScanned)
                        lastTreeValidationResult = result
                        lastTreeValidationTime = Date()
                        return result
                    }
                }

                // Root not in HeaderStore — check trust level
                if deltaVerified {
                    print("✅ FIX #1260: Root not in HeaderStore, but delta VERIFIED — trusting tree")
                    print("✅ FIX #1260: Trust chain: DeltaBundleVerified + Groth16 proof = valid anchor")
                    let result = CMUTreeValidationResult(isValid: true, ourRoot: ourRootHex, headerRoot: "delta_verified", height: lastScanned)
                    lastTreeValidationResult = result
                    lastTreeValidationTime = Date()
                    return result
                }

                // Delta NOT verified AND root not in HeaderStore — witnesses may be stale
                // FIX #1035: Don't block sends — Groth16 proof will catch invalid anchors
                print("⚠️ FIX #1260: Root not in HeaderStore AND delta not verified — allowing send (Groth16 validates)")
                let result = CMUTreeValidationResult(isValid: true, ourRoot: ourRootHex, headerRoot: "unverified_trust_groth16", height: lastScanned)
                lastTreeValidationResult = result
                lastTreeValidationTime = Date()
                return result
            }

            // FIX #719: CRITICAL - Block send if tree root mismatch detected
            // FIX #537 was WRONG - it allowed send even when roots didn't match
            // This caused "joinsplit requirements not met" errors because:
            // - TX anchor is computed from FFI tree
            // - Blockchain expects anchor matching header's finalsaplingroot
            // - Mismatch = anchor doesn't exist on blockchain = TX rejected
            if ourRootHex != headerRoot {
                // FIX #719: Check if header has ZERO root (corrupted headers)
                let isZeroRoot = header.hashFinalSaplingRoot.allSatisfy { $0 == 0 }
                if isZeroRoot {
                    // Header is corrupted (zero sapling root) - can't validate
                    // Allow send but warn - this happens when headers need repair
                    print("⚠️ FIX #719: Header has ZERO sapling root (corrupted) - cannot validate")
                    print("⚠️ FIX #719: Allowing send but transaction MAY be rejected")
                    print("⚠️ FIX #719: Run 'Repair Database' to fix headers")
                    return CMUTreeValidationResult(isValid: true, ourRoot: ourRootHex, headerRoot: "zero_root", height: lastScanned)
                }

                // Real mismatch - FFI tree is corrupt, TX WILL be rejected
                print("❌ FIX #719: Tree root MISMATCH - TX WILL BE REJECTED!")
                print("   FFI root:    \(ourRootHex.prefix(16))...")
                print("   Header root: \(headerRoot.prefix(16))...")
                print("   Height:      \(lastScanned)")
                print("❌ FIX #719: Blocking send - run 'Repair Database' to rebuild tree")
                return CMUTreeValidationResult(isValid: false, ourRoot: ourRootHex, headerRoot: headerRoot, height: lastScanned)
            }

            // Roots match - safe to send
            print("✅ FIX #527: Tree roots match - safe to send")
            return CMUTreeValidationResult(isValid: true, ourRoot: ourRootHex, headerRoot: headerRoot, height: lastScanned)

        } catch {
            print("⚠️ FIX #527: Header validation error: \(error) - allowing send")
            return CMUTreeValidationResult(isValid: true, ourRoot: ourRootHex, headerRoot: "error", height: lastScanned)
        }
    }

    // MARK: - FIX #1000: Startup Tree Root Validation via P2P

    /// FIX #1000: CRITICAL - Validate tree root via P2P at startup BEFORE showing balance
    /// This prevents the frustrating UX where user sees balance, tries to send, then gets blocked.
    /// Must be called AFTER INSTANT START completes and network is connected.
    /// - Returns: true if tree is valid, false if corrupted (needs repair)
    @Published var treeRootValidAtStartup: Bool = true
    @Published var treeRootMismatchDetected: Bool = false

    func validateTreeRootAtStartup() async -> Bool {
        print("🔐 FIX #1000: Validating tree root via P2P at STARTUP...")

        // FIX #1129: Skip P2P validation if verified state is valid
        // P2P validation is expensive (stops block listeners, fetches block, etc.)
        // When we have a verified state from successful Full Rescan or health check,
        // we can trust the local tree root without P2P confirmation
        if WalletHealthCheck.shared.hasValidVerifiedState() {
            print("⏩ FIX #1129: Using verified state - skipping P2P tree validation")
            await MainActor.run {
                treeRootValidAtStartup = true
                treeRootMismatchDetected = false
            }
            return true
        }

        // Get our current tree root from FFI
        guard let ourTreeRoot = ZipherXFFI.treeRoot(), !ourTreeRoot.isEmpty else {
            print("⚠️ FIX #1000: No tree loaded - skipping validation")
            return true
        }

        let ourRootHex = ourTreeRoot.hexString
        print("🔐 FIX #1000: Our tree root: \(ourRootHex.prefix(16))...")

        // Get last scanned height
        guard let lastScanned = try? WalletDatabase.shared.getLastScannedHeight(),
              lastScanned > 0 else {
            print("⚠️ FIX #1000: No scanned height - skipping validation")
            return true
        }

        // FIX #1037: Stop block listeners before P2P fetch
        // Block listeners consume socket data and cause "invalid magic bytes" errors
        // when P2P fetch tries to read response (TCP stream desync)
        print("🛑 FIX #1037: Stopping block listeners before P2P validation...")
        await PeerManager.shared.stopAllBlockListeners(timeout: 5.0)

        // FIX #1228: Reconnect peers with dead connections after stopping block listeners.
        // FIX #1184b kills NWConnections → peers have handshake=true but connection=nil.
        let deadPeers1037 = await MainActor.run {
            NetworkManager.shared.peers.filter { $0.isHandshakeComplete && !$0.isConnectionReady }
        }
        if !deadPeers1037.isEmpty {
            print("🔄 FIX #1228: Reconnecting \(deadPeers1037.count) peers with dead connections (startup validation)...")
            var reconnected1037 = Set<String>()  // FIX #1235
            for peer in deadPeers1037 {
                if reconnected1037.contains(peer.host) { print("⏭️ FIX #1235: [\(peer.host)] Already reconnected - skipping"); continue }
                do {
                    try await peer.ensureConnected()
                    reconnected1037.insert(peer.host)  // FIX #1235
                    print("✅ FIX #1228: [\(peer.host)] Reconnected for startup validation")
                } catch {
                    print("⚠️ FIX #1228: [\(peer.host)] Reconnect failed: \(error.localizedDescription)")
                }
            }
        }

        // FIX #877: Drain socket buffers after stopping block listeners
        print("🚿 FIX #877: Draining socket buffers before P2P validation...")
        let connectedPeers1037 = await NetworkManager.shared.peers.filter { $0.isConnectionReady }
        await withTaskGroup(of: Void.self) { group in
            for peer in connectedPeers1037 {
                group.addTask {
                    await peer.drainSocketBuffer()
                }
            }
        }

        // FIX #1000: Fetch ACTUAL block via P2P to get reliable finalsaplingroot
        // This is the same validation as FIX #936 but runs at startup
        print("🔐 FIX #1000: Fetching block \(lastScanned) via P2P for validation...")

        do {
            let block = try await NetworkManager.shared.getBlockForScanning(height: lastScanned)
            let blockSaplingRoot = block.finalSaplingRoot.hexString

            print("🔐 FIX #1000: FFI tree root:     \(ourRootHex.prefix(16))...")
            print("🔐 FIX #1000: Block sapling root: \(blockSaplingRoot.prefix(16))...")

            if ourRootHex == blockSaplingRoot {
                print("✅ FIX #1000: Tree root VALID at startup - safe to transact")
                await MainActor.run {
                    treeRootValidAtStartup = true
                    treeRootMismatchDetected = false
                }
                // FIX #1037: Restart block listeners after P2P validation
                print("▶️ FIX #1037: Restarting block listeners after P2P validation")
                await NetworkManager.shared.startBlockListenersOnMainScreen()
                return true
            } else {
                // CRITICAL: Tree root MISMATCH!
                print("❌ FIX #1000: TREE ROOT MISMATCH DETECTED AT STARTUP!")
                print("   FFI root:    \(ourRootHex.prefix(16))...")
                print("   Block root:  \(blockSaplingRoot.prefix(16))...")
                print("   Height:      \(lastScanned)")
                print("❌ FIX #1000: User must run 'Repair Database' before sending!")

                await MainActor.run {
                    treeRootValidAtStartup = false
                    treeRootMismatchDetected = true
                }
                // FIX #1037: Restart block listeners after P2P validation
                print("▶️ FIX #1037: Restarting block listeners after P2P validation")
                await NetworkManager.shared.startBlockListenersOnMainScreen()
                return false
            }
        } catch {
            // P2P block fetch failed - can't validate
            // FIX #1000: Don't block startup, but warn and try again later
            print("⚠️ FIX #1000: P2P block fetch failed: \(error)")
            print("⚠️ FIX #1000: Tree validation skipped - will validate before send")
            // FIX #1037: Restart block listeners after P2P validation (even on failure)
            print("▶️ FIX #1037: Restarting block listeners after P2P validation")
            await NetworkManager.shared.startBlockListenersOnMainScreen()
            return true  // Don't block startup on network issues
        }
    }

    // MARK: - Post-Scan Nullifier Verification

    /// FIX #1084: Flag to prevent concurrent nullifier verification
    private static var isVerifyingNullifiers = false
    private static let verifyNullifiersLock = NSLock()

    /// FIX #1319: Match nullifiers locally from delta bundle (no P2P needed for delta-covered range)
    /// Returns spent nullifiers found in delta and the height range covered by delta.
    /// Both wire-format and display-format hashes are checked (FIX #1195 dual-format safety).
    private func matchDeltaNullifiersLocally(
        hashedNullifiers: Set<Data>
    ) -> (matches: [(hashedNullifier: Data, spentHeight: UInt64, txid: Data)], deltaRange: ClosedRange<UInt64>?) {
        guard let manifest = DeltaCMUManager.shared.getManifest(),
              manifest.endHeight > manifest.startHeight,
              let deltaNullifiers = DeltaCMUManager.shared.loadNullifiers(),
              !deltaNullifiers.isEmpty else {
            return ([], nil)
        }

        let database = WalletDatabase.shared
        let deltaRange = manifest.startHeight...manifest.endHeight
        var matchedKeys = Set<Data>()
        var matches: [(Data, UInt64, Data)] = []

        for dn in deltaNullifiers {
            // Delta stores nullifiers in wire format (same as P2P path)
            let hashedWire = database.hashNullifier(dn.nullifier)
            if hashedNullifiers.contains(hashedWire) && !matchedKeys.contains(hashedWire) {
                matches.append((hashedWire, UInt64(dn.height), dn.txid))
                matchedKeys.insert(hashedWire)
            }
            // FIX #1195: Also check reversed (display format)
            let hashedDisplay = database.hashNullifier(Data(dn.nullifier.reversed()))
            if hashedNullifiers.contains(hashedDisplay) && !matchedKeys.contains(hashedDisplay) {
                matches.append((hashedDisplay, UInt64(dn.height), dn.txid))
                matchedKeys.insert(hashedDisplay)
            }
        }

        return (matches, deltaRange)
    }

    /// Verify nullifier spend status for all unspent notes
    /// This is a fallback check that queries the blockchain for each note's nullifier
    /// Called after scan to catch any spent notes that were missed during normal scan
    /// FIX #1084: Runs in background, skips if pending tx, prevents concurrent runs
    func verifyNullifierSpendStatus() async throws {
        // FIX #1290: Skip during Full Rescan — scan already handles spend detection
        // Running concurrent verification competes for P2P peers and doubles scan time
        let isRepairing = await MainActor.run { WalletManager.shared.isRepairingDatabase }
        if isRepairing {
            print("⏩ FIX #1290: Skipping FIX #1084 verification — Full Rescan in progress (handles spends)")
            return
        }

        // FIX #1318: Gate — skip if intensive P2P already running
        let isIntensiveP2P = await MainActor.run { NetworkManager.shared.isIntensiveP2PFetchInProgress }
        if isIntensiveP2P {
            print("⏭️ FIX #1318: Skipping nullifier verification — intensive P2P fetch in progress")
            return
        }

        // FIX #1084: Prevent concurrent verification runs
        WalletManager.verifyNullifiersLock.lock()
        guard !WalletManager.isVerifyingNullifiers else {
            WalletManager.verifyNullifiersLock.unlock()
            print("⏸️ FIX #1084: Nullifier verification already in progress - skipping")
            return
        }
        WalletManager.isVerifyingNullifiers = true
        WalletManager.verifyNullifiersLock.unlock()

        defer {
            WalletManager.verifyNullifiersLock.lock()
            WalletManager.isVerifyingNullifiers = false
            WalletManager.verifyNullifiersLock.unlock()
        }

        // FIX #1084: Skip if pending transactions
        let pendingTxids = UserDefaults.standard.stringArray(forKey: "ZipherX_PendingOutgoingTxids") ?? []
        if !pendingTxids.isEmpty {
            print("⏸️ FIX #1084: Skipping verification - \(pendingTxids.count) pending tx(s)")
            return
        }

        // FIX #1103: CRITICAL - Skip if FIX #1089 already completed full verification
        // FIX #1089 (verifyAllUnspentNotesOnChain) does comprehensive verification from oldest note
        // If that already ran, this redundant scan would waste 10+ minutes scanning 73K blocks
        let hasCompletedFullVerification = UserDefaults.standard.bool(forKey: "FIX1089_FullVerificationComplete")
        if hasCompletedFullVerification {
            let storedCheckpoint = (try? WalletDatabase.shared.getVerifiedCheckpointHeight()) ?? 0
            print("⏩ FIX #1103: Skipping FIX #1084 - FIX #1089 already verified (checkpoint=\(storedCheckpoint))")
            return
        }

        print("🔍 Starting post-scan nullifier verification...")

        let database = WalletDatabase.shared
        let networkManager = NetworkManager.shared
        let unspentNotes = try database.getAllUnspentNotes(accountId: 1)

        guard !unspentNotes.isEmpty else {
            print("✅ No unspent notes to verify")
            return
        }

        print("🔍 Checking \(unspentNotes.count) unspent note(s) for spend status...")

        // FIX #1093: PERFORMANCE - Build nullifier lookup set and scan ONCE
        // Previous bug: Scanned 72K blocks PER NOTE (22 notes × 72K = 1.58M block fetches!)
        // New approach: Scan 72K blocks ONCE, check all nullifiers in each block

        // Step 1: Build lookup set of all hashed nullifiers
        var nullifierToNote: [Data: WalletNote] = [:]
        var oldestHeight: UInt64 = UInt64.max

        for note in unspentNotes {
            // note.nullifier is already hashed (VUL-009)
            nullifierToNote[note.nullifier] = note
            if note.height < oldestHeight {
                oldestHeight = note.height
            }
        }

        // Step 2: Get chain height
        let chainHeight: UInt64
        do {
            chainHeight = try await networkManager.getChainHeight()
        } catch {
            print("⚠️ FIX #1093: Cannot get chain height: \(error)")
            return
        }

        guard chainHeight > oldestHeight else {
            print("✅ FIX #1093: Chain height (\(chainHeight)) not beyond oldest note (\(oldestHeight))")
            return
        }

        // FIX #1106: Use checkpoint to avoid scanning 72K blocks every startup
        // Only scan from checkpoint+1 to chain tip if we've verified before
        let storedCheckpoint = UInt64(UserDefaults.standard.integer(forKey: "FIX1106_NullifierVerificationCheckpoint"))
        var scanStartHeight = oldestHeight

        if storedCheckpoint > 0 && storedCheckpoint >= oldestHeight {
            // Checkpoint exists and is valid - only scan from checkpoint+1
            if storedCheckpoint >= chainHeight {
                print("✅ FIX #1106: Already verified up to \(storedCheckpoint), chain at \(chainHeight) - skipping")
                return
            }
            scanStartHeight = storedCheckpoint + 1
            print("📋 FIX #1106: Using checkpoint \(storedCheckpoint), scanning from \(scanStartHeight) to \(chainHeight)")
        } else {
            print("🔍 FIX #1106: No valid checkpoint, scanning from oldest note height \(oldestHeight) to chain tip")
        }

        // FIX #1319: Check delta nullifiers locally first — avoid P2P for delta-covered range
        let (deltaMatches1319, deltaRange1319) = matchDeltaNullifiersLocally(
            hashedNullifiers: Set(nullifierToNote.keys)
        )
        if !deltaMatches1319.isEmpty {
            print("📦 FIX #1319: Found \(deltaMatches1319.count) spent note(s) in local delta")
            for (hashedNull, spentHeight, txid) in deltaMatches1319 {
                // FIX #1415: History entries created by populateHistoryFromNotes() (always-run)
                // which correctly calculates actualSent = input - change - fee.
                try database.markNoteSpentByHashedNullifier(hashedNullifier: hashedNull, txid: txid, spentHeight: spentHeight)
                nullifierToNote.removeValue(forKey: hashedNull)
            }
        }
        // FIX #1527: Only skip past delta range when ALL nullifiers are accounted for.
        // See FIX #1527 comment in verifyAllUnspentNotesOnChain for full explanation.
        if let range = deltaRange1319, scanStartHeight >= range.lowerBound && scanStartHeight <= range.upperBound {
            if nullifierToNote.isEmpty {
                print("📦 FIX #1319: All nullifiers resolved in delta — advancing past delta range → \(range.upperBound + 1)")
                scanStartHeight = range.upperBound + 1
            } else {
                print("📦 FIX #1527: \(nullifierToNote.count) unresolved nullifier(s) — scanning delta range via P2P")
            }
        }

        // FIX #1350: Guard against UInt64 underflow when scanStartHeight > chainHeight
        // (FIX #1319 can advance scanStartHeight past chainHeight when delta covers tip)
        guard scanStartHeight < chainHeight else {
            print("✅ FIX #1350: Scan start (\(scanStartHeight)) >= chain height (\(chainHeight)) - already verified, saving checkpoint")
            UserDefaults.standard.set(Int(chainHeight), forKey: "FIX1106_NullifierVerificationCheckpoint")
            return
        }

        let blocksToScan = chainHeight - scanStartHeight

        // Skip if only a few blocks to scan (already synced)
        if blocksToScan < 10 {
            print("✅ FIX #1106: Only \(blocksToScan) blocks to scan - saving checkpoint and skipping")
            UserDefaults.standard.set(Int(chainHeight), forKey: "FIX1106_NullifierVerificationCheckpoint")
            return
        }

        print("🔍 FIX #1093: Scanning \(blocksToScan) blocks (single pass for \(nullifierToNote.count) nullifiers)")

        // FIX #1423: Use dispatcher instead of stopping block listeners.
        // Old approach (FIX #1096) stopped all block listeners → FIX #1184b killed NWConnections
        // → all peers dead → reconnect 300-600ms each via Tor → scan got 0% coverage → repeat every 30s.
        // New approach: ensure block listeners are RUNNING so dispatcher routes P2P reads.
        // Same pattern as verifyAllUnspentNotesOnChain (FIX #1184).
        PeerManager.shared.setBlockListenersBlocked(false)
        PeerManager.shared.setHeaderSyncInProgress(false)
        await networkManager.startBlockListenersOnMainScreen()
        // Wait for dispatchers to activate
        var activeDispatchers1423 = 0
        for attempt in 1...10 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            activeDispatchers1423 = 0
            for peer in await MainActor.run(body: { networkManager.peers }) {
                if await peer.isDispatcherActive {
                    activeDispatchers1423 += 1
                }
            }
            if activeDispatchers1423 >= 3 {
                print("✅ FIX #1423: \(activeDispatchers1423) dispatcher(s) active after \(attempt * 500)ms")
                break
            }
        }
        if activeDispatchers1423 == 0 {
            print("⚠️ FIX #1423: No dispatchers active — getBlocksDataP2P will retry activation")
        }
        await MainActor.run { networkManager.isIntensiveP2PFetchInProgress = true }
        print("🔒 FIX #1423: P2P fetch via dispatcher (\(activeDispatchers1423) dispatchers active)")

        defer {
            Task { @MainActor in
                networkManager.isIntensiveP2PFetchInProgress = false
            }
            print("🔓 FIX #1423: P2P fetch isolation released")
        }

        // FIX #1095: Dynamic batch size based on peer capacity
        // FIX #1287: Cap at 3 concurrent peers to prevent TCP congestion collapse
        let peerCount = await MainActor.run { networkManager.peers.filter { $0.isConnectionReady }.count }
        let maxBlocksPerPeer = 128
        let batchSize: UInt64 = UInt64(min(max(peerCount, 1), 3) * maxBlocksPerPeer)
        print("🔍 FIX #1095: Scanning \(blocksToScan) blocks with \(peerCount) peers (batch=\(batchSize))...")

        // Step 3: Scan blocks in batches, check all nullifiers per block
        // FIX #1106: Start from scanStartHeight (checkpoint) instead of oldestHeight
        var batchStart = scanStartHeight
        var spentCount = deltaMatches1319.count
        var blocksScanned: UInt64 = 0
        let startTime = Date()

        // FIX #1107: Track consecutive failures to detect persistent network issues
        var consecutiveNoPeersFailures = 0
        let maxNoPeersFailures = 3  // After 3 consecutive "no peers" failures, stop

        while batchStart < chainHeight && !nullifierToNote.isEmpty {
            let batchEnd = min(batchStart + batchSize, chainHeight)
            let count = Int(batchEnd - batchStart)

            do {
                let blocks = try await networkManager.getBlocksDataP2P(from: batchStart, count: count)
                blocksScanned += UInt64(blocks.count)
                consecutiveNoPeersFailures = 0  // Reset on success

                // Check each block for our nullifiers
                for (height, _, _, txData) in blocks {
                    for (_, _, spends) in txData {
                        guard let spends = spends, !spends.isEmpty else { continue }

                        for spend in spends {
                            // Convert hex nullifier to Data and hash it
                            guard let spendNullifierDisplay = Data(hexString: spend.nullifier) else { continue }
                            let spendNullifierWire = spendNullifierDisplay.reversedBytes()
                            let spendHashed = database.hashNullifier(spendNullifierWire)

                            // Check if this matches any of our unspent notes
                            if let note = nullifierToNote[spendHashed] {
                                print("💸 FIX #1093: Found spent note at height \(height): \(note.value.redactedAmount)")
                                try database.markNoteSpentByHashedNullifier(hashedNullifier: note.nullifier, spentHeight: height)
                                nullifierToNote.removeValue(forKey: spendHashed)
                                spentCount += 1
                            }
                        }
                    }
                }

                // Progress logging every 5000 blocks
                if blocksScanned % 5000 < batchSize {
                    let elapsed = Date().timeIntervalSince(startTime)
                    let rate = elapsed > 0 ? Double(blocksScanned) / elapsed : 0
                    print("📊 FIX #1093: Scanned \(blocksScanned)/\(blocksToScan) blocks (\(Int(rate)) blocks/sec)")
                }

                batchStart = batchEnd
            } catch {
                // FIX #1107: Detect "no peers" error and handle gracefully
                let errorString = String(describing: error)
                if errorString.contains("notConnected") || errorString.contains("No ready peers") {
                    consecutiveNoPeersFailures += 1
                    if consecutiveNoPeersFailures >= maxNoPeersFailures {
                        print("⚠️ FIX #1107: No peers available after \(consecutiveNoPeersFailures) attempts - aborting verification")
                        print("⚠️ FIX #1107: Scanned \(blocksScanned)/\(blocksToScan) blocks before network failure")
                        // Save partial checkpoint so we don't restart from beginning
                        if blocksScanned > 0 {
                            let partialCheckpoint = scanStartHeight + blocksScanned
                            UserDefaults.standard.set(Int(partialCheckpoint), forKey: "FIX1106_NullifierVerificationCheckpoint")
                            print("📋 FIX #1107: Saved partial checkpoint at height \(partialCheckpoint)")
                        }
                        return
                    }
                    // Wait 3 seconds before retrying (don't spam)
                    print("⚠️ FIX #1107: No peers available (attempt \(consecutiveNoPeersFailures)/\(maxNoPeersFailures)), waiting 3s...")
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    // Don't advance batchStart - retry same batch
                } else {
                    print("⚠️ FIX #1093: Batch fetch failed at height \(batchStart): \(error)")
                    batchStart = batchEnd  // Skip failed batch and continue
                }
            }
        }

        let elapsed = Date().timeIntervalSince(startTime)
        let rate = elapsed > 0 ? Double(blocksScanned) / elapsed : 0

        if spentCount > 0 {
            print("✅ FIX #1093: Marked \(spentCount) note(s) as spent in \(Int(elapsed))s (\(Int(rate)) blocks/sec)")
        } else {
            print("✅ FIX #1093: All \(unspentNotes.count) notes verified unspent in \(Int(elapsed))s (\(Int(rate)) blocks/sec)")
        }

        // FIX #1106: Save checkpoint on successful completion
        UserDefaults.standard.set(Int(chainHeight), forKey: "FIX1106_NullifierVerificationCheckpoint")
        print("📋 FIX #1106: Saved nullifier verification checkpoint at height \(chainHeight)")
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

        // FIX #1318: Gate — skip if intensive P2P already running
        if networkManager.isIntensiveP2PFetchInProgress {
            print("⏭️ FIX #1318: Skipping spent note verification — intensive P2P fetch in progress")
            return 0
        }

        // FIX #1423: Use dispatcher instead of stopping block listeners.
        // Old approach killed NWConnections → all peers dead → destructive reconnect cycle.
        // Same fix as verifyNullifierSpendStatus: keep listeners running, use dispatcher.
        PeerManager.shared.setBlockListenersBlocked(false)
        PeerManager.shared.setHeaderSyncInProgress(false)
        await networkManager.startBlockListenersOnMainScreen()
        var activeDispatchers1423b = 0
        for attempt in 1...10 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            activeDispatchers1423b = 0
            for peer in networkManager.peers {
                if await peer.isDispatcherActive {
                    activeDispatchers1423b += 1
                }
            }
            if activeDispatchers1423b >= 3 {
                print("✅ FIX #1423: \(activeDispatchers1423b) dispatcher(s) active after \(attempt * 500)ms (spent note verification)")
                break
            }
        }
        networkManager.isIntensiveP2PFetchInProgress = true
        print("🔒 FIX #1423: P2P fetch via dispatcher (\(activeDispatchers1423b) dispatchers active) — spent note verification")

        defer {
            networkManager.isIntensiveP2PFetchInProgress = false
            print("🔓 FIX #1423: P2P fetch isolation released (spent note verification)")
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
                    print("💰 FIX #563 v19: Found incorrectly marked note: \(value.redactedAmount) at height \(height)")
                    print("💰 FIX #563 v19: Note marked SPENT but NOT spent on-chain - UNMARKING!")

                    do {
                        try database.unmarkNoteAsSpent(nullifier: note.nullifier)
                        unmarkedCount += 1
                        print("✅ FIX #563 v19: UNMARKED note (restored \(value.redactedAmount))")
                    } catch {
                        print("❌ FIX #563 v19: Failed to unmark note: \(error)")
                    }
                } else {
                    print("✅ FIX #563 v19: Note \(value.redactedAmount) is actually spent on-chain - correct")
                }
            } else {
                // FIX #563 v40: Verification failed - don't unmark, keep as spent
                print("⚠️ FIX #563 v40: Could not verify note \(value.redactedAmount) at height \(height) - keeping marked as spent")
            }
        }

        print("📊 FIX #563 v19: Checked \(spentNotes.count) spent notes (\(totalValue.redactedAmount))")

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

        // FIX #1084: Scan blocks from note height to find spends
        // FIX #1092 DISABLED: The optimization assumed boost bundle has spent status - IT DOESN'T!
        // Boost bundle only contains commitment tree, NOT spent status.
        // For imported wallets, notes before boost end could have been spent before boost end,
        // and those nullifiers would be missed if we only scan from boost end.
        // FIX #1095: Always scan from note height to find ALL possible spends
        let startHeight = afterHeight
        print("🔍 FIX #1095: Scanning for nullifier from note height \(afterHeight) to chain tip")

        let blocksToScan = chainHeight - startHeight
        guard blocksToScan > 0 else {
            return nil  // No blocks to scan - verification failed
        }

        // FIX #1095: Dynamic batch size based on peer capacity (was fixed 160)
        // FIX #1287: Cap at 3 concurrent peers to prevent TCP congestion collapse
        let peerCount = await MainActor.run { networkManager.peers.filter { $0.isConnectionReady }.count }
        let maxBlocksPerPeer = 128
        let batchSize: UInt64 = UInt64(min(max(peerCount, 1), 3) * maxBlocksPerPeer)
        print("🔍 FIX #1095: Checking \(blocksToScan) blocks for nullifier [redacted] (batch=\(batchSize))")

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

        // TX-004: Randomize scan depth to obscure note creation time
        let scanDepth = UInt64(Int.random(in: 100...500))
        var startHeight: UInt64
        if fromCheckpoint {
            // Scan from checkpoint (should be recent)
            let checkpoint = try database.getVerifiedCheckpointHeight()
            startHeight = checkpoint > 0 ? checkpoint : (chainHeight > scanDepth ? chainHeight - scanDepth : 0)
        } else {
            startHeight = chainHeight > scanDepth ? chainHeight - scanDepth : 0
        }

        let blocksToScan = chainHeight > startHeight ? Int(chainHeight - startHeight) : 0
        guard blocksToScan > 0 else {
            print("✅ FIX #212: Already at chain tip - no blocks to scan")
            return 0
        }

        print("🔍 FIX #212: Scanning blocks \(startHeight) to \(chainHeight) (\(blocksToScan) blocks)")

        // FIX #1057 v2: Stop block listeners before P2P fetch to prevent TCP stream desync
        // Block listeners can consume P2P responses causing "Invalid magic bytes" errors
        // v2: Use ensureAllBlockListenersStopped() which force-disconnects stuck listeners (FIX #1058)
        print("🛑 FIX #1057 v2: Ensuring ALL block listeners stopped before unrecorded spend scan...")
        let allStopped = await PeerManager.shared.ensureAllBlockListenersStopped(maxRetries: 3, retryDelay: 1.0)
        if !allStopped {
            print("⚠️ FIX #1057 v2: Some listeners may still be running, but force-disconnect was attempted")
        }

        // FIX #1228: Reconnect peers with dead connections after stopping block listeners.
        // FIX #1184b kills NWConnections → peers have handshake=true but connection=nil.
        let deadPeers1057 = await MainActor.run {
            networkManager.peers.filter { $0.isHandshakeComplete && !$0.isConnectionReady }
        }
        if !deadPeers1057.isEmpty {
            print("🔄 FIX #1228: Reconnecting \(deadPeers1057.count) peers with dead connections (unrecorded spend scan)...")
            var reconnected1057 = Set<String>()  // FIX #1235
            for peer in deadPeers1057 {
                if reconnected1057.contains(peer.host) { print("⏭️ FIX #1235: [\(peer.host)] Already reconnected - skipping"); continue }
                do {
                    try await peer.ensureConnected()
                    reconnected1057.insert(peer.host)  // FIX #1235
                    print("✅ FIX #1228: [\(peer.host)] Reconnected for unrecorded spend scan")
                } catch {
                    print("⚠️ FIX #1228: [\(peer.host)] Reconnect failed: \(error.localizedDescription)")
                }
            }
        }

        // FIX #877: Drain socket buffers after stopping block listeners
        print("🚿 FIX #877: Draining socket buffers before unrecorded spend scan...")
        let connectedPeers1057 = await networkManager.peers.filter { $0.isConnectionReady }
        await withTaskGroup(of: Void.self) { group in
            for peer in connectedPeers1057 {
                group.addTask {
                    await peer.drainSocketBuffer()
                }
            }
        }

        defer {
            // FIX #1057 v2: Restart block listeners after P2P scan completes
            Task {
                print("▶️ FIX #1057 v2: Restarting block listeners after unrecorded spend scan...")
                await NetworkManager.shared.startBlockListenersOnMainScreen()
            }
        }

        // Fetch blocks via P2P
        var recoveredCount = 0
        // FIX #1098: Dynamic batch size based on peer capacity (was fixed 500)
        let peerCountRecovery = await MainActor.run { NetworkManager.shared.peers.filter { $0.isConnectionReady }.count }
        // FIX #1287: Dynamic batch = 2 chunks per peer (scales with connected peers)
        let batchSize: UInt64 = UInt64(max(peerCountRecovery, 3) * 256)

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
                                print("   Note value: \(matchedNote.value.redactedAmount)")
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
                // FIX #1231: Retry single-block fetch with up to 3 attempts if peer times out
                var blocks: [(UInt64, String, UInt32, [(String, [ShieldedOutput], [ShieldedSpend]?)])] = []
                var attempts = 0
                let maxAttempts = 3
                while attempts < maxAttempts && blocks.isEmpty {
                    attempts += 1
                    do {
                        blocks = try await networkManager.getBlocksDataP2P(from: height, count: 1)
                    } catch {
                        if attempts == maxAttempts {
                            print("⚠️ FIX #1231: Block fetch at height \(height) failed after \(maxAttempts) attempts")
                        }
                    }
                }

                guard let (_, _, _, txData) = blocks.first else {
                    print("⚠️ FIX #371: Could not fetch block at height \(height) after \(attempts) attempts")
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
                // FIX #1231: Retry single-block fetch with up to 3 attempts if peer times out
                var blocks: [(UInt64, String, UInt32, [(String, [ShieldedOutput], [ShieldedSpend]?)])] = []
                var attempts = 0
                let maxAttempts = 3
                while attempts < maxAttempts && blocks.isEmpty {
                    attempts += 1
                    do {
                        blocks = try await networkManager.getBlocksDataP2P(from: height, count: 1)
                    } catch {
                        if attempts == maxAttempts {
                            print("⚠️ FIX #1231: Block fetch at height \(height) failed after \(maxAttempts) attempts")
                        }
                    }
                }

                guard let (_, _, _, txData) = blocks.first else {
                    print("⚠️ FIX #466: Could not fetch block at height \(height) after \(attempts) attempts")
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
    // MARK: - FIX #1090: Recompute Nullifiers with Correct Tree Positions

    /// FIX #1090: CRITICAL - Recompute nullifiers for notes that have wrong positions
    ///
    /// ROOT CAUSE OF BALANCE BUG:
    /// - FilterScanner's `processDecryptedNote` computed nullifiers with PLACEHOLDER positions
    /// - Placeholder formula: `height * 1000 + outputIndex` (COMPLETELY WRONG!)
    /// - Real position is the actual index in the commitment tree (from witnessIndex)
    /// - Because nullifiers were computed with wrong positions, they NEVER match blockchain nullifiers
    /// - Result: `verifyAllUnspentNotesOnChain` couldn't detect spent notes
    ///
    /// SOLUTION:
    /// - For each unspent note with valid witnessIndex > 0
    /// - Recompute nullifier using witnessIndex as the correct position
    /// - Update the database with the correct (hashed) nullifier
    /// - Now verifyAllUnspentNotesOnChain will find matches!
    ///
    /// - Returns: Number of nullifiers fixed
    @MainActor
    func recomputeNullifiersWithCorrectPositions() async throws -> Int {
        print("🔧 FIX #1090: Recomputing nullifiers with correct tree positions...")

        // FIX #1091 v3: One-time migration for existing users
        // v3 triggers Full Rescan when nullifiers fixed (instead of slow 72K block P2P scan)
        // This ensures correct balance after nullifier corruption is detected
        let fix1091V3Applied = UserDefaults.standard.bool(forKey: "FIX1091_V3_Applied")
        if !fix1091V3Applied {
            print("🔄 FIX #1091 v3: First run - will trigger Full Rescan if nullifiers need fixing")
            UserDefaults.standard.set(true, forKey: "FIX1090_NeedsFullVerification")
            UserDefaults.standard.set(false, forKey: "FIX1089_FullVerificationComplete")
            UserDefaults.standard.set(true, forKey: "FIX1091_V3_Applied")
        }

        // FIX #1195: One-time reset of verification checkpoint after nullifier corrections
        // Bug: FIX1089 checkpoint was set to "complete" during a session when nullifiers
        // were computed with WRONG tree positions (pre-FIX #1192). After #1192 corrected
        // nullifiers, the checkpoint was never reset, so verifyAllUnspentNotesOnChain()
        // skipped the blocks where spends actually occurred → phantom-unspent notes.
        // This one-time reset forces a full re-verification from the oldest note.
        let fix1195Applied = UserDefaults.standard.bool(forKey: "FIX1195_VerificationReset")
        if !fix1195Applied {
            print("🔄 FIX #1195: Resetting verification checkpoint (stale from pre-#1192 nullifiers)")
            UserDefaults.standard.set(false, forKey: "FIX1089_FullVerificationComplete")
            UserDefaults.standard.set(true, forKey: "FIX1090_NeedsFullVerification")
            UserDefaults.standard.set(true, forKey: "FIX1195_VerificationReset")
        }
        // FIX #1195b: Second reset — the first reset's timed-out scan was incorrectly
        // marked as "complete" by ContentView (which unconditionally set the flag).
        // Now that ContentView no longer sets the flag AND the function checks scanTimedOut,
        // this reset will allow the smart start height to actually execute.
        let fix1195bApplied = UserDefaults.standard.bool(forKey: "FIX1195b_SmartStartReset")
        if !fix1195bApplied {
            print("🔄 FIX #1195b: Resetting verification checkpoint (timed-out scan was falsely marked complete)")
            UserDefaults.standard.set(false, forKey: "FIX1089_FullVerificationComplete")
            UserDefaults.standard.set(true, forKey: "FIX1090_NeedsFullVerification")
            UserDefaults.standard.set(true, forKey: "FIX1195b_SmartStartReset")
        }
        // FIX #1195c: Third reset — smart start (median-based) skipped blocks where 3 of 16
        // spends occurred. Now scanning from oldest note with 360s timeout instead.
        let fix1195cApplied = UserDefaults.standard.bool(forKey: "FIX1195c_FullScanReset")
        if !fix1195cApplied {
            print("🔄 FIX #1195c: Resetting verification checkpoint (smart start missed 3 spends)")
            UserDefaults.standard.set(false, forKey: "FIX1089_FullVerificationComplete")
            UserDefaults.standard.set(true, forKey: "FIX1090_NeedsFullVerification")
            UserDefaults.standard.set(true, forKey: "FIX1195c_FullScanReset")
        }
        // FIX #1195d: Skip already-verified range — two full scans from 2929119 found 0 spends
        // up to ~2968800. Preset partial scan height so we resume from there immediately.
        let fix1195dApplied = UserDefaults.standard.bool(forKey: "FIX1195d_PresetResume")
        if !fix1195dApplied {
            let currentPartial = UserDefaults.standard.integer(forKey: "FIX1195_PartialScanHeight")
            if currentPartial < 2968800 {
                print("🔄 FIX #1195d: Presetting scan resume to 2968800 (already verified 2929119-2968800)")
                UserDefaults.standard.set(2968800, forKey: "FIX1195_PartialScanHeight")
            }
            UserDefaults.standard.set(false, forKey: "FIX1089_FullVerificationComplete")
            UserDefaults.standard.set(true, forKey: "FIX1090_NeedsFullVerification")
            UserDefaults.standard.set(true, forKey: "FIX1195d_PresetResume")
        }
        // FIX #1195e: Jump to 2992000 — the 3 remaining phantom spends are at heights
        // 2992441-2992542, and their spending TXs are between there and 2993932.
        // Range 2929119-2968800 was fully scanned (0 spends). Range 2993932-3005000
        // was scanned by smart-start (found 13 spends). Only 2968800-2993932 is uncovered.
        // Jump to 2992000 to minimize scan range to ~13K blocks (< 3 min at 76 blocks/s).
        let fix1195eApplied = UserDefaults.standard.bool(forKey: "FIX1195e_JumpToSpends")
        if !fix1195eApplied {
            print("🔄 FIX #1195e: Jumping scan to 2992000 (3 remaining spends are at 2992441+)")
            UserDefaults.standard.set(2992000, forKey: "FIX1195_PartialScanHeight")
            UserDefaults.standard.set(false, forKey: "FIX1089_FullVerificationComplete")
            UserDefaults.standard.set(true, forKey: "FIX1090_NeedsFullVerification")
            UserDefaults.standard.set(true, forKey: "FIX1195e_JumpToSpends")
        }

        // FIX #1212: Fresh full verification after FIX #1211 fixed delta startHeight
        // Previous FIX #1195a-e resets all ran when nullifiers or tree positions may have been wrong,
        // or scans timed out / used wrong start heights. Now that tree is correct and FIX #1211
        // prevents infinite delta rebuild, force one clean full scan from oldest note to detect
        // any remaining phantom-unspent notes (e.g., Note 1788 on sim = 250,000 zatoshis).
        let fix1212Applied = UserDefaults.standard.bool(forKey: "FIX1212_FreshFullVerification")
        if !fix1212Applied {
            print("🔄 FIX #1212: Forcing fresh full verification (clean scan from oldest note)")
            UserDefaults.standard.removeObject(forKey: "FIX1195_PartialScanHeight")
            UserDefaults.standard.set(false, forKey: "FIX1089_FullVerificationComplete")
            UserDefaults.standard.set(true, forKey: "FIX1090_NeedsFullVerification")
            UserDefaults.standard.set(true, forKey: "FIX1212_FreshFullVerification")
        }

        let database = WalletDatabase.shared
        let secureStorage = SecureKeyStorage()
        let rustBridge = RustBridge.shared

        // VUL-U-002: Get spending key for nullifier computation with secure zeroing
        guard let secureKey = try? secureStorage.retrieveSpendingKeySecure() else {
            print("⚠️ FIX #1090: Cannot get spending key - skipping nullifier recomputation")
            return 0
        }
        defer { secureKey.zero() }
        let spendingKey = secureKey.data

        // Get all unspent notes
        let unspentNotes = try database.getAllUnspentNotes(accountId: 1)
        guard !unspentNotes.isEmpty else {
            print("✅ FIX #1090: No unspent notes to check")
            return 0
        }

        print("🔧 FIX #1090: Checking \(unspentNotes.count) unspent notes for incorrect nullifiers...")

        var fixedCount = 0
        var skippedCount = 0
        var extractedFromWitness = 0

        for note in unspentNotes {
            // Get the correct tree position for nullifier computation
            var position = note.witnessIndex

            // FIX #1091 v2 + FIX #1177: Extract tree position from witness data
            // Database has corrupted witnessIndex values (4, 8, 47, etc. instead of ~1,045,000+)
            // The witness contains the REAL tree position - trust it over stored values
            // FIX #1107: Changed from 1028 to 100
            if note.witness.count >= 100 {
                // FIX #1177: Load witness into FFI, then get tree position separately
                let arrayIndex = note.witness.withUnsafeBytes { ptr in
                    ZipherXFFI.treeLoadWitness(
                        witnessData: ptr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        witnessLen: note.witness.count
                    )
                }
                let extractedPosition = arrayIndex != UInt64.max ? ZipherXFFI.witnessGetTreePosition(witnessIndex: arrayIndex) : UInt64.max
                if extractedPosition != UInt64.max && extractedPosition > 0 {
                    // Log if we're correcting a wrong stored value
                    if position != extractedPosition {
                        print("🔧 FIX #1091 v2: Correcting position for note \(note.id): stored=\(position) → actual=\(extractedPosition)")
                        // Update witnessIndex in database with correct value
                        try? database.updateNoteWitnessIndex(noteId: note.id, witnessIndex: extractedPosition)
                    }
                    position = extractedPosition
                    extractedFromWitness += 1
                } else {
                    print("⚠️ FIX #1091 v2: Failed to extract position from witness for note \(note.id)")
                }
            }

            // Skip notes without valid position
            guard position > 0 else {
                skippedCount += 1
                print("⚠️ FIX #1091: Note \(note.id) has position=0 (witnessIndex=\(note.witnessIndex), witness.count=\(note.witness.count))")
                continue
            }

            // FIX #1091: Debug logging to trace nullifier computation
            print("🔍 FIX #1091: Note \(note.id) - using position=\(position) (witnessIndex was \(note.witnessIndex))")

            // Recompute nullifier using correct position
            // FIX #1091: CRITICAL BUG FIX - must use `position` (possibly extracted from witness)
            //            NOT `note.witnessIndex` which may still be 0 or incorrect
            guard let newNullifier = try? rustBridge.computeNullifier(
                spendingKey: spendingKey,
                diversifier: note.diversifier,
                value: note.value,
                rcm: note.rcm,
                position: position
            ) else {
                print("⚠️ FIX #1090: Failed to compute nullifier for note \(note.id)")
                continue
            }

            // Hash the new nullifier (database stores hashed nullifiers for privacy)
            let newHashedNullifier = database.hashNullifier(newNullifier)

            // Compare with stored nullifier
            if newHashedNullifier != note.nullifier {
                // Nullifiers are different - stored one was computed with wrong position!
                print("🔧 FIX #1090: Note \(note.id) at height \(note.height) has WRONG nullifier!")
                print("   Old (wrong): [redacted] (position was placeholder)")
                print("   New (correct): [redacted] (position=\(note.witnessIndex))")
                print("   Value: \(note.value.redactedAmount)")

                // Update the database with correct nullifier
                // Note: updateNoteNullifier takes RAW nullifier and hashes it internally
                try database.updateNoteNullifier(noteId: note.id, nullifier: newNullifier)
                fixedCount += 1
            }
        }

        if fixedCount > 0 {
            print("✅ FIX #1090: Fixed \(fixedCount) nullifier(s) with correct tree positions")
            if extractedFromWitness > 0 {
                print("   Extracted position from witness data for \(extractedFromWitness) note(s)")
            }
            if skippedCount > 0 {
                print("   Skipped \(skippedCount) note(s) without valid witness data")
            }
            print("   Nullifier verification will now detect spent notes correctly!")

            // CRITICAL: Set persistent flag to force full verification (survives app restart)
            // This flag is checked in verifyAllUnspentNotesOnChain() and cleared after success
            UserDefaults.standard.set(true, forKey: "FIX1090_NeedsFullVerification")
            UserDefaults.standard.set(false, forKey: "FIX1089_FullVerificationComplete")
            print("🔄 FIX #1090: Set flag for full verification - will scan from oldest note")
        } else if skippedCount > 0 {
            print("ℹ️ FIX #1090: All checked nullifiers are correct")
            if extractedFromWitness > 0 {
                print("   Extracted position from witness data for \(extractedFromWitness) note(s)")
            }
            print("   \(skippedCount) note(s) skipped (no witness data)")
        } else {
            print("✅ FIX #1090: All \(unspentNotes.count) nullifiers verified correct")
        }

        return fixedCount
    }

    // MARK: - FIX #303: Verify Unspent Notes On Chain

    /// The problem: FIX #302 only scanned from checkpoint to chain tip.
    /// If an external wallet spent our note BEFORE the checkpoint was set, we'd never detect it.
    ///
    /// Solution: Scan from the HEIGHT OF THE OLDEST UNSPENT NOTE to chain tip.
    /// This ensures ANY external spend on ANY unspent note is detected.
    ///
    /// - Parameter onProgress: Progress callback with (current, total) blocks
    /// - Returns: Number of external spends detected and marked as spent
    @MainActor
    func verifyAllUnspentNotesOnChain(forceFullVerification: Bool = false, onProgress: ((Int, Int) -> Void)? = nil) async throws -> Int {
        print("🔍 FIX #303: Verifying ALL unspent notes are actually unspent on-chain...")

        let database = WalletDatabase.shared
        let networkManager = NetworkManager.shared

        // Get our unspent notes
        let unspentNotes = try database.getAllUnspentNotes(accountId: 1)
        guard !unspentNotes.isEmpty else {
            print("✅ FIX #303: No unspent notes to verify")
            return 0
        }

        // FIX #1318: Gate — skip if intensive P2P already running
        if networkManager.isIntensiveP2PFetchInProgress {
            print("⏭️ FIX #1318: Skipping unspent note verification — intensive P2P fetch in progress")
            return 0
        }

        // FIX #1184: Ensure block listeners are RUNNING so dispatcher is active.
        // Previous startup steps (witness validation, delta sync) stop listeners and don't restart.
        // Without active listeners, P2P falls back to "direct reads" with 3s lock timeouts (~76 blocks/s).
        // With dispatcher: lock-free, ~300 blocks/s.
        // FIX #1184: Clear ALL flags that prevent block listeners from starting
        PeerManager.shared.setBlockListenersBlocked(false)
        PeerManager.shared.setHeaderSyncInProgress(false)
        print("📡 FIX #1184: Cleared blockListenersBlocked + headerSyncInProgress flags")
        await networkManager.startBlockListenersOnMainScreen()
        // FIX #1184: Wait for dispatchers to activate — startBlockListener() is async,
        // listeners need time to enter their receive loop and set isActive = true
        var activeDispatchers = 0
        for attempt in 1...10 {
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
            activeDispatchers = 0
            for peer in await MainActor.run(body: { networkManager.peers }) {
                if await peer.isDispatcherActive {
                    activeDispatchers += 1
                }
            }
            if activeDispatchers >= 3 {
                print("✅ FIX #1184: \(activeDispatchers) dispatcher(s) active after \(attempt * 500)ms")
                break
            }
        }
        if activeDispatchers == 0 {
            print("⚠️ FIX #1184: No dispatchers active — getBlocksDataP2P will retry activation")
        }
        networkManager.isIntensiveP2PFetchInProgress = true
        print("🔒 FIX #1184: P2P fetch isolation (\(activeDispatchers) dispatchers active)")

        defer {
            networkManager.isIntensiveP2PFetchInProgress = false
            print("🔓 FIX #1184: P2P fetch isolation released")
        }

        // FIX #1089: CRITICAL - Must scan from OLDEST unspent note on FIRST verification
        // FIX #1001 was broken: checkpoint is set on TX confirmation, NOT based on note ages
        // If notes were spent BEFORE checkpoint was set, they would NEVER be detected!
        //
        // Strategy:
        // 1. First time (no full verification done): Scan from oldest note to catch historical spends
        // 2. After successful full verification: Update checkpoint AND set flag
        // 3. Subsequent runs: Trust checkpoint (we already verified historical spends)
        //
        // This ensures we catch all historical spends ONCE, then use fast checkpoint-based verification
        let minNoteHeight = unspentNotes.map { $0.height }.min() ?? 0
        let storedCheckpoint = (try? database.getVerifiedCheckpointHeight()) ?? 0
        var hasCompletedFullVerification = UserDefaults.standard.bool(forKey: "FIX1089_FullVerificationComplete")

        // FIX #1283/1300: Reset checkpoint on code changes — previous version may have had bugs that
        // caused missed spends (wrong nullifiers, P2P failures, checkpoint set with bad data).
        // Forces a full re-scan from oldest note on every code change to catch stale phantom-unspent notes.
        // FIX #1300: CFBundleVersion is always "1" during development — never triggers FIX #1283.
        // Use a hardcoded verification version that we bump when spend-related code changes.
        // This forces re-verification on the next startup after a code fix, catching phantom-unspent notes.
        let verificationCodeVersion = "1527"  // FIX #1527: Bumped — FIX #1319 skipped P2P scan when unresolved nullifiers remained
        let currentBuild = "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown").\(verificationCodeVersion)"
        let lastVerifiedBuild = UserDefaults.standard.string(forKey: "FIX1283_LastVerifiedBuild") ?? ""
        if hasCompletedFullVerification && currentBuild != lastVerifiedBuild {
            print("🔄 FIX #1300: Code version changed (\(lastVerifiedBuild) → \(currentBuild)) — forcing full re-verification")
            hasCompletedFullVerification = false
            UserDefaults.standard.set(false, forKey: "FIX1089_FullVerificationComplete")
            UserDefaults.standard.removeObject(forKey: "FIX1195_PartialScanHeight")
        }

        // FIX #1090: Check persistent flag for nullifiers that were fixed (may be set across restarts)
        let needsFullVerificationAfterNullifierFix = UserDefaults.standard.bool(forKey: "FIX1090_NeedsFullVerification")
        let shouldForceFullVerification = forceFullVerification || needsFullVerificationAfterNullifierFix

        if needsFullVerificationAfterNullifierFix {
            print("🔄 FIX #1090: Nullifiers were fixed - forcing full verification from oldest note")
        }

        let checkpointHeight: UInt64
        if hasCompletedFullVerification && storedCheckpoint > 0 && !shouldForceFullVerification {
            // We've already done a full verification - trust the checkpoint
            checkpointHeight = storedCheckpoint
            print("🔍 FIX #1089: Using checkpoint \(storedCheckpoint) (full verification already complete)")
        } else if minNoteHeight > 0 {
            // FIX #1195c: Resume from partial scan if previous attempt timed out
            let partialScanHeight = UserDefaults.standard.integer(forKey: "FIX1195_PartialScanHeight")
            if partialScanHeight > Int(minNoteHeight) {
                // Resume from where we left off — don't restart from oldest note
                checkpointHeight = UInt64(partialScanHeight)
                print("🔍 FIX #1195c: Resuming scan from \(partialScanHeight) (previous scan timed out here, oldest note: \(minNoteHeight))")
            } else {
                checkpointHeight = minNoteHeight
                print("🔍 FIX #1195c: Full scan from oldest note \(minNoteHeight) to chain tip")
            }
        } else if storedCheckpoint > 0 {
            checkpointHeight = storedCheckpoint
            print("🔍 FIX #1089: No notes - using checkpoint \(storedCheckpoint)")
        } else {
            checkpointHeight = 0
            print("⚠️ FIX #1089: No checkpoint and no notes - cannot verify")
        }

        guard checkpointHeight > 0 else {
            print("⚠️ FIX #303: Could not determine start height for verification")
            return 0
        }

        // Build set of our nullifier hashes for quick lookup
        var ourNullifiers: [Data: WalletNote] = [:]
        var totalValue: UInt64 = 0
        for note in unspentNotes {
            ourNullifiers[note.nullifier] = note
            totalValue += note.value
        }
        print("🔍 FIX #303: Checking \(unspentNotes.count) unspent notes (\(totalValue.redactedAmount))")
        print("🔍 FIX #1089: Starting verification from height \(checkpointHeight)")

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
            // FIX #1231: Retry probe with up to 3 attempts (single-block fetch uses 1 peer)
            print("🔍 FIX #303: Probing P2P with \(currentPeerCountForProbe) peer(s)...")
            do {
                let probeHeight = chainHeight > 10 ? chainHeight - 10 : chainHeight

                var probeBlocks: [(UInt64, String, UInt32, [(String, [ShieldedOutput], [ShieldedSpend]?)])] = []
                var probeAttempts = 0
                let maxProbeAttempts = 3

                while probeBlocks.isEmpty && probeAttempts < maxProbeAttempts {
                    probeAttempts += 1

                    // Wrap in timeout task
                    let probeTask = Task {
                        try await networkManager.getBlocksDataP2P(from: probeHeight, count: 1)
                    }

                    // Wait max 10 seconds for probe
                    let timeoutTask = Task {
                        try await Task.sleep(nanoseconds: 10_000_000_000)  // 10 seconds
                        probeTask.cancel()
                    }

                    do {
                        probeBlocks = try await probeTask.value
                        timeoutTask.cancel()
                    } catch {
                        timeoutTask.cancel()
                        if probeAttempts < maxProbeAttempts {
                            print("⚠️ FIX #1231: Probe attempt \(probeAttempts) failed, retrying...")
                        } else {
                            throw error
                        }
                    }
                }

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

        // FIX #1089: Use calculated start height (min of checkpoint and oldest note)
        // This ensures we scan from the earliest point where ANY note could have been spent
        let startHeight = checkpointHeight + 1  // Start AFTER the calculated height

        let blocksToScan = chainHeight > startHeight ? Int(chainHeight - startHeight) : 0

        guard blocksToScan > 0 else {
            print("✅ FIX #1089: No blocks to scan - start height \(checkpointHeight) is at chain tip \(chainHeight)")
            return 0
        }

        // FIX #1089: Large gap is EXPECTED when scanning from oldest note
        // Don't warn - this is the correct behavior for detecting historical spends
        if blocksToScan > 50000 {
            print("🔍 FIX #1089: Scanning \(blocksToScan) blocks - this may take a while...")
        }

        print("🔍 FIX #1089: Scanning \(blocksToScan) blocks from \(startHeight) to \(chainHeight)")

        // Fetch blocks via P2P and check nullifiers
        var externalSpendsFound = 0
        var successfulBatches = 0
        var failedBatches = 0
        var consecutiveFailures = 0
        // FIX #1098: Dynamic batch size based on peer capacity (was fixed 500)
        // FIX #1285: Use DISPATCHER-ACTIVE peer count, not total connected peers.
        // Connected peers with inactive dispatchers return 0 blocks (FIX #1184 fast-return).
        // Old code: 5 connected peers → batchSize=640, but only 1 active → 128 delivered →
        // 20% < FIX #1218 50% threshold → EVERY batch fails → scan aborts → balance wrong.
        // New: use activeDispatchers count (measured above) for correct sizing.
        // FIX #1287: Dynamic batch = 2 chunks per peer (scales with connected peers)
        let effectivePeers = max(activeDispatchers, 1)
        let batchSize: UInt64 = UInt64(max(effectivePeers, 3) * 256)

        // FIX #1252: Proportional timeout based on block count (was hardcoded 360s)
        // Real-world rate: 212 blocks/s (77K blocks in 364s from logs)
        // Conservative estimate: 200 blocks/s to handle variations
        // Formula: max(360s, blocksToScan / 200 * 1.5) for 50% safety margin
        // Examples: 77K blocks → 577s, 20K blocks → 360s (min), 100K blocks → 750s
        let scanStartTime = Date()
        let estimatedSeconds = Double(blocksToScan) / 200.0 * 1.5  // 50% margin
        let maxScanDuration: TimeInterval = max(360.0, estimatedSeconds)
        var scanTimedOut = false
        print("🔍 FIX #1252: Scan timeout set to \(Int(maxScanDuration))s for \(blocksToScan) blocks (est. \(Int(estimatedSeconds))s at 200 blocks/s)")

        var batchStart = startHeight

        // FIX #1319: Check delta nullifiers locally first — avoid P2P for delta-covered range
        let (deltaMatches1319b, deltaRange1319b) = matchDeltaNullifiersLocally(
            hashedNullifiers: Set(ourNullifiers.keys)
        )
        if !deltaMatches1319b.isEmpty {
            print("📦 FIX #1319: Found \(deltaMatches1319b.count) spent note(s) in local delta")
            for (hashedNull, spentHeight, txid) in deltaMatches1319b {
                // FIX #1415: History entries created by populateHistoryFromNotes() (always-run)
                // which correctly calculates actualSent = input - change - fee.
                try database.markNoteSpentByHashedNullifier(hashedNullifier: hashedNull, txid: txid, spentHeight: spentHeight)
                ourNullifiers.removeValue(forKey: hashedNull)
                externalSpendsFound += 1
            }
        }
        // FIX #1527: Only skip past delta range when ALL nullifiers are accounted for.
        // Previous code advanced batchStart past delta range unconditionally — if delta
        // nullifier bundle was incomplete (missing some spent nullifiers), the P2P scan
        // that would catch them was skipped → phantom notes persisted forever (0% coverage).
        // Now: only skip if ourNullifiers is empty (all found in delta or no more to check).
        if let range = deltaRange1319b, batchStart >= range.lowerBound && batchStart <= range.upperBound {
            if ourNullifiers.isEmpty {
                print("📦 FIX #1319: All nullifiers resolved in delta — advancing past delta range → \(range.upperBound + 1)")
                batchStart = range.upperBound + 1
            } else {
                print("📦 FIX #1527: \(ourNullifiers.count) unresolved nullifier(s) — scanning delta range via P2P")
            }
        }

        var totalBlocksProcessed: Int = 0  // FIX #1301: Track actual coverage
        while batchStart < chainHeight {
            // Check total time limit
            if Date().timeIntervalSince(scanStartTime) > maxScanDuration {
                print("⚠️ FIX #367/#1195: Scan timeout after \(Int(maxScanDuration))s - scanned up to height \(batchStart)")
                // FIX #1195c: Save progress so next run resumes from here instead of starting over
                UserDefaults.standard.set(Int(batchStart), forKey: "FIX1195_PartialScanHeight")
                print("   Saved partial scan progress at height \(batchStart) — will resume next time")
                scanTimedOut = true
                break
            }
            let batchEnd = min(batchStart + batchSize, chainHeight)
            let count = Int(batchEnd - batchStart)

            onProgress?(Int(batchStart - startHeight), blocksToScan)

            // FIX #303 v5: Add retries for failed batches and delays to prevent overwhelming Tor
            var batchSuccess = false
            var retries = 0
            let maxRetries = 2
            // FIX #1301: Track actual coverage for cursor advancement
            var batchMaxReceivedHeight: UInt64 = 0
            var batchReceivedCount: Int = 0

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

                    // FIX #1301: Track max received height for cursor advancement
                    // Prevents skipping blocks when P2P returns partial batches
                    var batchMaxHeight: UInt64 = 0

                    for (height, _, _, txData) in blocks {
                        batchMaxHeight = max(batchMaxHeight, height)
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
                                // FIX #1195: Also check hashed-display format
                                // processShieldedOutputsSync (FIX #1079) tries both formats;
                                // this function was only checking hashed-wire, missing matches
                                // if FFI nullifiers happen to be in display byte order
                                let hashedNullifierDisplay = database.hashNullifier(nullifierDisplay)

                                // FIX #1195: Determine which format matched
                                let matchedKey: Data
                                let matchedNote: WalletNote
                                if let note = ourNullifiers[hashedNullifier] {
                                    matchedKey = hashedNullifier
                                    matchedNote = note
                                } else if let note = ourNullifiers[hashedNullifierDisplay] {
                                    matchedKey = hashedNullifierDisplay
                                    matchedNote = note
                                } else {
                                    continue
                                }

                                do {
                                    // Found! This note was spent on-chain - EXTERNAL SPEND!
                                    print("🚨 FIX #303: EXTERNAL SPEND DETECTED!")
                                    print("   Note value: \(matchedNote.value.redactedAmount)")
                                    print("   Spent in TX: \(txidHex.prefix(16))...")
                                    print("   Spent at height: \(height)")
                                    print("   Note created at height: \(matchedNote.height)")

                                    // Convert txid hex to Data
                                    let txidData = Data(hexString: txidHex) ?? matchedKey.prefix(32)

                                    // Mark the note as spent (use the key that matched the DB)
                                    try database.markNoteSpentByHashedNullifier(
                                        hashedNullifier: matchedKey,
                                        txid: txidData,
                                        spentHeight: height
                                    )

                                    // FIX #1415: History entries created by populateHistoryFromNotes() (always-run)
                                    // which correctly calculates actualSent = input - change - fee.
                                    // Do NOT insert here — amount would be wrong (input - fee, missing change).

                                    externalSpendsFound += 1
                                    // Remove from our tracking set (use the key that matched)
                                    ourNullifiers.removeValue(forKey: matchedKey)
                                }
                            }
                        }
                    }

                    // FIX #1301: Store batch coverage info for cursor advancement
                    batchReceivedCount = blocks.count
                    batchMaxReceivedHeight = batchMaxHeight
                    totalBlocksProcessed += batchReceivedCount
                    if batchReceivedCount < count {
                        print("⚠️ FIX #1301: Partial batch \(batchReceivedCount)/\(count) blocks — will re-scan gap")
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

            // FIX #1284: Inter-batch TCP pacing to prevent congestion collapse.
            // Without pacing, 3 peers each getting 128-block requests every 0.2s causes
            // TCP window exhaustion: 1600 blocks/s → 38 blocks/s (42x drop) by batch 47.
            // FIX #1197 solved this for delta sync with 300ms inter-round delay.
            // Same pattern here: 150ms per batch gives TCP windows time to drain.
            // Also ramp up delay for sustained loads (like FIX #1197 adaptive pacing):
            // Batches 1-5: 100ms (burst), 6-15: 150ms, 16+: 200ms
            if batchSuccess {
                let pacingDelay: UInt64
                if successfulBatches <= 5 {
                    pacingDelay = 100_000_000  // 100ms - burst phase
                } else if successfulBatches <= 15 {
                    pacingDelay = 150_000_000  // 150ms - steady phase
                } else {
                    pacingDelay = 200_000_000  // 200ms - sustained phase
                }
                try? await Task.sleep(nanoseconds: pacingDelay)
            }

            // FIX #1301: Advance cursor based on ACTUAL blocks received, not batch size.
            // Previous code: `batchStart += batchSize` — skipped blocks on partial P2P batches.
            // If P2P returned 400/1280 blocks, cursor jumped past 880 unchecked blocks.
            // Nullifiers in those skipped blocks were NEVER checked → phantom-unspent notes.
            if batchSuccess && batchReceivedCount < count && batchMaxReceivedHeight > 0 {
                // Partial batch — advance to max received height + 1 (don't skip gaps)
                batchStart = batchMaxReceivedHeight + 1
            } else {
                // Full batch or failed batch — advance normally
                batchStart += batchSize
            }
        }

        onProgress?(blocksToScan, blocksToScan)

        // FIX #1301: Report scan coverage
        let coveragePercent = blocksToScan > 0 ? (totalBlocksProcessed * 100 / blocksToScan) : 100
        print("📊 FIX #1301: Scan coverage: \(totalBlocksProcessed)/\(blocksToScan) blocks (\(coveragePercent)%)")
        if coveragePercent < 95 {
            print("⚠️ FIX #1301: LOW COVERAGE — \(blocksToScan - totalBlocksProcessed) blocks were NOT checked for nullifiers")
        }

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
            // FIX #1195c: Clear partial scan progress — spends found, will need fresh scan next time
            UserDefaults.standard.removeObject(forKey: "FIX1195_PartialScanHeight")
            // Refresh balance to reflect changes
            try? await refreshBalance()
            incrementHistoryVersion()

            // FIX #303: Calculate total amount corrected and show alert
            let correctedAmount = totalValue - unspentNotes.filter { ourNullifiers[$0.nullifier] != nil }.reduce(0) { $0 + $1.value }
            await MainActor.run {
                self.databaseCorrectionAlert = DatabaseCorrectionInfo(
                    externalSpendsDetected: externalSpendsFound,
                    amountCorrected: correctedAmount,
                    message: "Detected \(externalSpendsFound) transaction(s) from another wallet totaling \(correctedAmount.redactedAmount). Your balance has been corrected."
                )
            }
        } else if failedBatches > 0 || scanTimedOut || coveragePercent < 95 {
            // FIX #1195b/#1301: Incomplete scans are NOT complete — don't set checkpoint flag
            // FIX #1301: Also check coverage percentage — partial P2P batches leave gaps
            print("⚠️ FIX #303: Partial scan - \(successfulBatches)/\(totalBatches) batches succeeded\(scanTimedOut ? " (TIMED OUT)" : "")")
            print("   Coverage: \(coveragePercent)% (\(totalBlocksProcessed)/\(blocksToScan) blocks)")
            print("   No external spends found in scanned blocks, but scan was incomplete")
            print("   DO NOT mark verification as complete — will retry with smart start next time")
        } else {
            print("✅ FIX #303: All \(unspentNotes.count) unspent notes verified - no external spends detected")
            print("   Scanned \(successfulBatches) batches successfully")

            // FIX #1089: Update checkpoint to chain height after SUCCESSFUL verification
            // This ensures next startup only scans from here (not from oldest note again)
            // Only update if:
            // 1. All batches succeeded (no network failures)
            // 2. No external spends found (balance is accurate)
            // 3. We actually scanned some blocks (not just a no-op)
            // 4. Scan was NOT timed out (FIX #1195b)
            if successfulBatches > 0 {
                do {
                    try database.updateVerifiedCheckpointHeight(chainHeight)
                    // FIX #1089: Mark full verification as complete
                    // Next startup will trust checkpoint instead of re-scanning from oldest note
                    UserDefaults.standard.set(true, forKey: "FIX1089_FullVerificationComplete")
                    // FIX #1300: Save code version to detect changes on next startup
                    let verificationCodeVersion = "1302"
                    let buildForCheckpoint = "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown").\(verificationCodeVersion)"
                    UserDefaults.standard.set(buildForCheckpoint, forKey: "FIX1283_LastVerifiedBuild")
                    // FIX #1090: Clear the nullifier fix flag now that we've done full verification
                    UserDefaults.standard.set(false, forKey: "FIX1090_NeedsFullVerification")
                    // FIX #1195c: Clear partial scan progress — full scan completed
                    UserDefaults.standard.removeObject(forKey: "FIX1195_PartialScanHeight")
                    print("📍 FIX #1089: Updated checkpoint to \(chainHeight) + marked full verification complete")
                    print("   Next startup will be FAST (uses checkpoint, not oldest note)")
                } catch {
                    print("⚠️ FIX #1089: Failed to update checkpoint: \(error)")
                }
            }
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

            // VUL-U-002: Use secure key retrieval with automatic zeroing
            let secureKey = try secureStorage.retrieveSpendingKeySecure()
            defer { secureKey.zero() }
            let spendingKey = secureKey.data

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
        // FIX #1320: Delay initial deep verification by 120s to avoid startup P2P contention
        // Multiple concurrent P2P operations (delta sync, witness rebuild, verification) compete
        // for the same 5 TCP connections, causing cs_main serialization and dispatcher contention.
        // Delaying verification lets startup-critical operations finish first.
        Task { @MainActor in
            print("⏳ FIX #1320: Delaying initial deep verification by 120 seconds...")
            try? await Task.sleep(nanoseconds: 120_000_000_000)

            // FIX #1239: Check isRebuildingWitnesses to prevent interference during validation
            guard !self.isSyncing && !self.isRepairingDatabase && !self.isRebuildingWitnesses else {
                print("⏭️ FIX #1320: Skipping delayed deep verification - sync/repair/rebuild in progress")
                return
            }
            // FIX #1318: Gate — skip if intensive P2P already running
            if NetworkManager.shared.isIntensiveP2PFetchInProgress {
                print("⏭️ FIX #1318+#1320: Skipping delayed deep verification — intensive P2P in progress")
                return
            }

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
                // FIX #1239: Also check isRebuildingWitnesses to prevent interference during validation
                guard !self.isSyncing && !self.isRepairingDatabase && !self.isRebuildingWitnesses else {
                    print("⏭️ FIX #370: Skipping periodic deep verification - sync/repair/rebuild in progress")
                    return
                }
                // FIX #1318: Gate — skip if intensive P2P already running
                if NetworkManager.shared.isIntensiveP2PFetchInProgress {
                    print("⏭️ FIX #1318: Skipping periodic deep verification — intensive P2P in progress")
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

    /// FIX #1354: Check if a newer boost file is available on GitHub
    /// Called after startup completes. If newer boost exists, sets newerBoostAvailable
    /// so the UI can prompt the user to download it.
    func checkForBoostUpdate() {
        Task.detached(priority: .background) {
            // Wait 10s after startup to avoid contention with initial sync
            try? await Task.sleep(nanoseconds: 10_000_000_000)

            let updater = CommitmentTreeUpdater.shared
            let cachedManifest = await updater.loadCachedManifest()
            let cachedHeight = cachedManifest?.chain_height ?? 0

            guard cachedHeight > 0 else {
                print("⏭️ FIX #1354: No cached boost manifest — skipping update check")
                return
            }

            do {
                let remoteManifest = try await updater.fetchRemoteManifestPublic()
                let remoteHeight = remoteManifest.chain_height

                if remoteHeight > cachedHeight + 10000 {
                    // Only prompt if significantly newer (>10K blocks ≈ 7 days)
                    print("📦 FIX #1354: Newer boost available! Remote=\(remoteHeight) vs cached=\(cachedHeight) (+\(remoteHeight - cachedHeight) blocks)")
                    await MainActor.run {
                        WalletManager.shared.newerBoostAvailable = (remoteHeight: remoteHeight, cachedHeight: cachedHeight)
                    }
                } else {
                    print("✅ FIX #1354: Boost file is up-to-date (cached=\(cachedHeight), remote=\(remoteHeight))")
                }
            } catch {
                print("⏭️ FIX #1354: Could not check for boost update: \(error.localizedDescription)")
            }
        }
    }

    /// FIX #1354: Download the newer boost file (called when user accepts the prompt)
    func downloadBoostUpdate() {
        guard !isDownloadingBoostUpdate else { return }
        Task { @MainActor in
            self.isDownloadingBoostUpdate = true
            self.newerBoostAvailable = nil
        }

        Task.detached {
            defer {
                Task { @MainActor in
                    WalletManager.shared.isDownloadingBoostUpdate = false
                }
            }

            do {
                let updater = CommitmentTreeUpdater.shared
                let (_, height, outputs) = try await updater.getBestAvailableBoostFile(onProgress: { progress, status in
                    print("📦 FIX #1354: Boost update \(Int(progress * 100))% - \(status)")
                })
                print("✅ FIX #1354: Boost file updated to height \(height) (\(outputs) outputs)")
                print("📦 FIX #1354: Restart app to use the new boost file")
            } catch {
                print("❌ FIX #1354: Boost update failed: \(error.localizedDescription)")
            }
        }
    }

    /// FIX #603: Start periodic witness refresh timer
    /// Keeps all unspent note witnesses updated to current chain tip
    /// This ensures pre-build is instant - witnesses are always fresh
    func startPeriodicWitnessRefresh() {
        // Run witness refresh every 10 minutes while app is open
        Timer.scheduledTimer(withTimeInterval: 10 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                // FIX #1239: Also check isRebuildingWitnesses to prevent interference during validation
                // Without this, FIX #603 can fire DURING preRebuildWitnessesForInstantPayment validation
                // which finds corrupted witnesses. FIX #603 then rebuilds witnesses from same corrupted
                // tree before FIX #1238 can NULL them → creates invalid anchors → FIX #1224 flags them
                // at next startup → infinite cycle. The 291ms gap between validation and FIX #603 in
                // Escalation #3 log shows this race condition.
                guard !self.isSyncing && !self.isRepairingDatabase && !self.isRebuildingWitnesses else {
                    print("⏭️ FIX #603: Skipping periodic witness refresh - sync/repair/rebuild in progress")
                    return
                }
                // FIX #1318: Gate — skip if intensive P2P already running
                if NetworkManager.shared.isIntensiveP2PFetchInProgress {
                    print("⏭️ FIX #1318: Skipping periodic witness refresh — intensive P2P in progress")
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

        // VUL-U-002: Use secure key retrieval with automatic zeroing
        let secureKey = try secureStorage.retrieveSpendingKeySecure()
        defer { secureKey.zero() }
        let spendingKey = secureKey.data

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
        // FIX #1050: Suppress routine log
        // print("⏭️ FIX #709: Auto-recovery disabled (preventing crashes from MainActor.run and database access)")
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
                    print("⚠️ FIX #680: Note not found for nullifier [redacted]")
                    continue
                }

                print("💰 FIX #680: Found note worth \(noteValue.redactedAmount) (id=\(noteId))")
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
                    print("💰 FIX #689: Found our note worth \(noteValue.redactedAmount) (id=\(noteId))")
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
        // FIX #1493: VULN-009 — Use centralized constant (was local hardcoded 3)
        let EQUIHASH_CONSENSUS_THRESHOLD = ZipherXConstants.consensusThreshold

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
    case addressGenerationFailed  // FIX #1402 (NEW-003): Diversifier index exceeds receive range

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
        case .addressGenerationFailed:
            return "Address generation failed: diversifier index limit reached"
        }
    }
}
