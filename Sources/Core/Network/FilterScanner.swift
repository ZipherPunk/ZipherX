import Foundation

/// Compact Block Scanner for Zclassic (ZIP-307)
/// Uses trial decryption to find shielded transactions - preserves privacy
final class FilterScanner {

    private let networkManager: NetworkManager
    private let database: WalletDatabase
    private let rustBridge: RustBridge
    // FIX #896: Removed InsightAPI - ZipherX is a cypherpunk P2P-only wallet, no centralized explorer dependency

    // FIX #1348: Verbose logging control (suppress high-volume per-block/per-output logs)
    private let verbose = false

    // Scanning parameters
    private let batchSize = 500 // Larger batches for faster sync
    private var isScanning = false
    private var scanTask: Task<Void, Never>?

    // SECURITY: Thread-safe lock to prevent concurrent scans across all instances
    private static let globalScanLock = NSLock()
    private static var _isScanningFlag = false
    // FIX #873: Track when scan started to detect stuck scans
    private static var _scanStartTime: Date?
    // FIX #1074: Track when progress was last made (not just when scan started!)
    private static var _lastProgressTime: Date?
    // FIX #1074: Increased timeout and now based on PROGRESS, not start time
    private static let SCAN_TIMEOUT_SECONDS: TimeInterval = 900 // 15 minutes with NO PROGRESS

    /// Check if any scan is currently in progress (thread-safe)
    /// FIX #873: Also checks for stuck scans and auto-clears the flag
    /// FIX #1074: Now checks time since LAST PROGRESS, not time since start
    static var isScanInProgress: Bool {
        globalScanLock.lock()
        defer { globalScanLock.unlock() }

        // FIX #1074: Check if scan is stuck (no progress for 15 minutes)
        // Uses _lastProgressTime (updated on each progress) instead of _scanStartTime
        if _isScanningFlag, let lastProgress = _lastProgressTime {
            let elapsed = Date().timeIntervalSince(lastProgress)
            if elapsed > SCAN_TIMEOUT_SECONDS {
                let totalTime = _scanStartTime.map { Date().timeIntervalSince($0) } ?? elapsed
                print("🚨 FIX #1074: Scan stuck - no progress for \(Int(elapsed))s (total time: \(Int(totalTime))s) - force-clearing")
                _isScanningFlag = false
                _scanStartTime = nil
                _lastProgressTime = nil
                return false
            }
        }

        return _isScanningFlag
    }

    /// Thread-safe setter for scan flag
    /// FIX #873: Also tracks scan start time for timeout detection
    private static func setScanInProgress(_ value: Bool) {
        globalScanLock.lock()
        _isScanningFlag = value
        // FIX #873: Track start time when scan begins, clear when it ends
        if value {
            _scanStartTime = Date()
            _lastProgressTime = Date()  // FIX #1074: Also set initial progress time
            print("🔍 FIX #873: Scan started at \(Date())")
        } else {
            if let startTime = _scanStartTime {
                let elapsed = Date().timeIntervalSince(startTime)
                print("✅ FIX #873: Scan completed in \(Int(elapsed))s")
            }
            _scanStartTime = nil
            _lastProgressTime = nil  // FIX #1074: Clear progress time
        }
        globalScanLock.unlock()
    }

    /// FIX #1074: Update progress time to prevent timeout while scan is actively working
    /// Call this whenever the scan makes meaningful progress (fetched blocks, saved checkpoint, etc.)
    static func updateScanProgress() {
        globalScanLock.lock()
        if _isScanningFlag {
            _lastProgressTime = Date()
        }
        globalScanLock.unlock()
    }

    /// FIX #1102: CRITICAL - Force-clear the scan flag for Full Rescan operations
    /// Problem: When FIX #1078 triggers Full Rescan during INSTANT START, a previous background sync
    /// may still have isScanInProgress=true. The repair's startScan() checks this flag and returns
    /// immediately with "Scan already in progress, skipping" - but the notes were already deleted!
    /// Result: Balance shows 0 because notes are deleted but never re-discovered.
    /// Solution: Call this before starting a Full Rescan to ensure the scan actually runs.
    /// ONLY use during repair operations that have already deleted notes - not for normal scans!
    public static func forceClearScanInProgressForRepair() {
        globalScanLock.lock()
        let wasSet = _isScanningFlag
        _isScanningFlag = false
        _scanStartTime = nil
        _lastProgressTime = nil
        globalScanLock.unlock()

        if wasSet {
            print("🔧 FIX #1102: Force-cleared isScanInProgress flag (was true from previous scan)")
            print("   This ensures Full Rescan can run after notes were deleted")
        }
    }

    // Progress callback - (progress, currentHeight, maxHeight)
    var onProgress: ((Double, UInt64, UInt64) -> Void)?

    // Status callback - (phase, status message)
    // Phases: "phase1" (parallel scan), "phase1.5" (witnesses), "phase1.6" (spends), "phase2" (sequential)
    var onStatusUpdate: ((String, String) -> Void)?

    // Witness update progress callback - (current, total, status)
    var onWitnessProgress: ((Int, Int, String) -> Void)?

    // Progress ranges for each phase (total = 100%)
    private let phase1ProgressRange = 0.0...0.40      // 0-40%: Parallel note discovery
    private let phase15ProgressRange = 0.40...0.55   // 40-55%: Witness computation
    private let phase16ProgressRange = 0.55...0.60   // 55-60%: Spend detection
    private let phase2ProgressRange = 0.60...1.0     // 60-100%: Sequential scan

    // Current chain height (updated during scan)
    private(set) var currentChainHeight: UInt64 = 0

    // FIX #1092: Track if current scan is a full scan (PHASE 1 + PHASE 2 from boost file)
    // Used to skip redundant FIX #1084 nullifier verification at end of scan
    private var isFullScanInProgress = false

    // Tracked notes and nullifiers
    private var knownNullifiers: Set<Data> = []

    // Commitment tree state
    private var treeInitialized = false
    private var pendingWitnesses: [(noteId: Int64, witnessIndex: UInt64)] = []
    private var existingWitnessIndices: [(noteId: Int64, witnessIndex: UInt64)] = []

    // CMU data for position lookup during parallel scan
    // This may be from bundled tree OR downloaded from GitHub (if newer)
    private var cmuDataForPositionLookup: Data?
    private var cmuDataHeight: UInt64 = 0  // Height of the CMU data source
    private var cmuDataCount: UInt64 = 0   // Number of CMUs in the data

    // Notes discovered AFTER downloadedTreeHeight that need nullifier recomputation
    // These notes have position=0 (wrong) because they weren't in downloaded tree
    // After PHASE 2, we recompute their nullifiers using correct tree positions
    // Format: (noteId, cmu, diversifier, value, rcm, height)
    private var notesNeedingNullifierFix: [(noteId: Int64, cmu: Data, diversifier: Data, value: UInt64, rcm: Data, height: UInt64)] = []

    // Note: Tree validation now uses ZipherXConstants.effectiveTreeCMUCount
    // which may be higher than bundled if a newer tree was downloaded from GitHub

    // NEW WALLET OPTIMIZATION: Skip note decryption for brand new wallets
    // New wallets can't have any notes yet (address was just created)
    // We still append CMUs to tree but skip tryDecryptNote() calls
    private var isNewWalletInitialSync = false

    // DELTA BUNDLE: Collect shielded outputs during PHASE 2 for local caching
    // Format: 652 bytes per output (same as GitHub boost file)
    // This enables instant witness generation on subsequent launches
    private var deltaOutputsCollected: [DeltaCMUManager.DeltaOutput] = []
    private var deltaCollectionStartHeight: UInt64 = 0
    private var deltaCollectionEnabled = false

    // FIX #874: Track outputs found when delta is "disabled" (manifest says it covers range)
    // Problem: FIX #795 disables delta collection when manifest covers target height
    //          But if previous scan missed outputs, new outputs are added to TREE but not DELTA
    //          This causes tree/delta mismatch → tree root mismatch at send time
    // Solution: Always collect outputs, even when "disabled", then update delta if any found
    private var deltaOutputsFoundInCoveredRange: [DeltaCMUManager.DeltaOutput] = []

    // FIX #1289 v3: Collect nullifiers alongside delta outputs for local spend detection
    // During Full Rescan, Phase 1b uses these to detect spends without P2P block fetching
    private var deltaNullifiersCollected: [DeltaCMUManager.DeltaNullifier] = []

    /// FIX #1214: Shared prefetch cache to avoid double-fetching blocks
    /// Set by preRebuildWitnessesForInstantPayment (FIX #571), consumed by PHASE 2
    /// When FIX #571 P2P fetches blocks for tree/witness updates, it caches parsed block data here.
    /// FilterScanner PHASE 2 pre-populates its prefetchedBlocks from this cache, avoiding re-download.
    static var sharedPrefetchCache: [UInt64: [(String, [ShieldedOutput], [ShieldedSpend]?)]]?

    // FIX #947: PERFORMANCE - Defer witness computation to first SEND
    // When true, PHASE 1.5 is skipped entirely during import
    // Witnesses are computed lazily when user attempts to send
    // This saves 40-60 seconds during Import PK
    private var deferWitnessComputation = false

    // FIX #1007: Prevent duplicate CMU appending in PHASE 2
    // Problem: Step 2a (FIX #571) fetches CMUs via P2P and appends them to tree for witness update
    //          Then PHASE 2 scans the same blocks and calls treeAppend() again → DOUBLE APPEND!
    // Solution: Track expected tree size at PHASE 2 start, skip append if tree already has CMU
    private var treeSizeAtPhase2Start: Int = 0
    private var cmusAppendedInPhase2: Int = 0

    // FIX #1053: Skip tree modification when delta sync already covered the range
    private var skipTreeModification: Bool = false

    /// FIX #1289: When set, delta outputs are available locally for re-scan (no P2P needed)
    /// Phase 1b will scan delta outputs from disk, Phase 2 starts from deltaEndHeight + 1
    var preservedDeltaEndHeight: UInt64? = nil

    /// FIX #947: Enable deferred witness computation for faster Import PK
    /// Set this before calling startScan() to skip PHASE 1.5
    func setDeferWitnessComputation(_ defer: Bool) {
        deferWitnessComputation = `defer`
        if `defer` {
            print("⚡ FIX #947: Deferred witness computation ENABLED - Import will be ~40-60s faster")
            print("   Witnesses will be computed on first SEND attempt")
        }
    }

    // MARK: - Progress Helpers

    /// Map phase-local progress (0-1) to overall progress within that phase's range
    private func mapProgress(_ localProgress: Double, in range: ClosedRange<Double>) -> Double {
        let rangeSize = range.upperBound - range.lowerBound
        return range.lowerBound + (localProgress * rangeSize)
    }

    /// Report progress for PHASE 1 (parallel note discovery)
    private func reportPhase1Progress(_ localProgress: Double, height: UInt64, maxHeight: UInt64, customDetail: String? = nil) {
        let overall = mapProgress(localProgress, in: phase1ProgressRange)
        onProgress?(overall, height, maxHeight)
        // FIX #469: Use custom detail if provided, otherwise show default with percentage
        if let detail = customDetail {
            onStatusUpdate?("phase1", detail)
        } else {
            // FIX #128: Always show progress percentage during note decryption
            let percent = Int(localProgress * 100)
            onStatusUpdate?("phase1", "Decrypting shielded notes (\(percent)%)...")
        }
    }

    /// Report progress for PHASE 1.5 (witness computation)
    private func reportPhase15Progress(_ localProgress: Double, current: Int, total: Int) {
        let overall = mapProgress(localProgress, in: phase15ProgressRange)
        onProgress?(overall, UInt64(current), UInt64(total))
        onStatusUpdate?("phase1.5", "Computing Merkle witnesses (\(current)/\(total))...")
    }

    /// Report progress for PHASE 1.6 (spend detection)
    private func reportPhase16Progress(_ localProgress: Double, detected: Int, total: Int) {
        let overall = mapProgress(localProgress, in: phase16ProgressRange)
        onProgress?(overall, UInt64(detected), UInt64(total))
        if localProgress < 0.01 {
            onStatusUpdate?("phase1.6", "Detecting spent notes...")
        }
    }

    /// Report progress for PHASE 2 (sequential scan)
    private func reportPhase2Progress(_ localProgress: Double, height: UInt64, maxHeight: UInt64) {
        let overall = mapProgress(localProgress, in: phase2ProgressRange)
        onProgress?(overall, height, maxHeight)
        // FIX #202: Show OVERALL progress (same as progress bar), not local phase progress
        // Previous bug: Status showed localProgress (29%) but bar showed overall (90%)
        let percent = Int(overall * 100)
        let blocksRemaining = maxHeight > height ? maxHeight - height : 0
        onStatusUpdate?("phase2", "Building commitment tree (\(percent)%, \(blocksRemaining) blocks left)...")
    }

    // FIX #896: Removed InsightAPI parameter - pure P2P implementation
    init(networkManager: NetworkManager = .shared,
         database: WalletDatabase = .shared,
         rustBridge: RustBridge = .shared) {
        self.networkManager = networkManager
        self.database = database
        self.rustBridge = rustBridge
    }

    // MARK: - Scanning

    /// Start scanning for transactions
    /// - Parameters:
    ///   - accountId: Account to scan for
    ///   - viewingKey: Spending key (used as viewing key)
    ///   - fromHeight: Optional custom start height (for quick scan)
    func startScan(for accountId: Int64, viewingKey: Data, fromHeight customStartHeight: UInt64? = nil, expectedBlockCount: UInt64 = 0) async throws {
        // FIX #1097: Log entry into startScan for debugging
        print("🔍 FIX #1097: startScan called - isScanning=\(isScanning), isScanInProgress=\(FilterScanner.isScanInProgress), expectedBlocks=\(expectedBlockCount)")

        // SECURITY: Thread-safe check and acquisition of global lock
        guard !isScanning && !FilterScanner.isScanInProgress else {
            print("⚠️ Scan already in progress, skipping (isScanning=\(isScanning), isScanInProgress=\(FilterScanner.isScanInProgress))")
            return
        }

        isScanning = true
        FilterScanner.setScanInProgress(true)

        // FIX #1290: Prevent macOS App Nap during sync — keeps P2P connections alive
        // Without this, screen lock or backgrounding throttles network I/O completely
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "ZipherX blockchain sync in progress"
        )
        defer { ProcessInfo.processInfo.endActivity(activity) }

        // FIX #1410: For small background syncs (≤ 10 blocks), DON'T stop block listeners.
        // Stopping listeners cancels ALL NWConnections (especially Tor SOCKS5), causing peers
        // to drop to 0 for 5-10 seconds during reconnection. For 1-2 block syncs this is
        // extremely disruptive and unnecessary — the dispatcher handles block fetches fine
        // while listeners are running.
        let isLightweightScan = expectedBlockCount > 0 && expectedBlockCount <= 10
        if isLightweightScan {
            print("🔍 FIX #1410: Lightweight scan (\(expectedBlockCount) blocks) — keeping block listeners active")
        } else {
            // FIX #1425: Use dispatcher pattern instead of stopping block listeners.
            // OLD approach (FIX #907): stopAllBlockListeners → FIX #1184b killed ALL NWConnections
            // → all peers dead (connection=nil) → FIX #1228 reconnected 5 peers via Tor (5-10s overhead)
            // → scan proceeded with freshly reconnected peers.
            // NEW approach: Keep block listeners RUNNING — they ARE the dispatcher.
            // Block fetches route through dispatcher (lock-free, 300+ blocks/s).
            // Same pattern as FIX #1423 (verifyNullifierSpendStatus) and FIX #1184 (verifyAllUnspentNotesOnChain).
            print("🔍 FIX #1425: Full scan (\(expectedBlockCount) blocks) — using dispatcher (keeping block listeners active)")
            PeerManager.shared.setBlockListenersBlocked(false)
            PeerManager.shared.setHeaderSyncInProgress(false)
            await networkManager.startBlockListenersOnMainScreen()
            var activeDispatchers1425 = 0
            for attempt in 1...10 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                activeDispatchers1425 = 0
                for peer in await MainActor.run(body: { networkManager.peers }) {
                    if await peer.isDispatcherActive {
                        activeDispatchers1425 += 1
                    }
                }
                if activeDispatchers1425 >= 3 {
                    print("✅ FIX #1425: \(activeDispatchers1425) dispatcher(s) active after \(attempt * 500)ms")
                    break
                }
            }
            if activeDispatchers1425 == 0 {
                print("⚠️ FIX #1425: No dispatchers active — getBlocksDataP2P will retry activation")
            }
        }

        defer {
            isScanning = false
            FilterScanner.setScanInProgress(false)
            // FIX #1425: No need to unblock — we never blocked (dispatcher stays active)
        }

        // Get current chain height
        guard let latestHeight = try? await getChainHeight() else {
            print("❌ Failed to get chain height")
            throw ScanError.networkError
        }

        // FIX #216: Sanity check on chain height (absolute max 10M blocks)
        let absoluteMaxHeight: UInt64 = 10_000_000
        guard latestHeight <= absoluteMaxHeight else {
            print("🚨 FIX #216: REJECTED impossible chain height \(latestHeight) (absolute max: \(absoluteMaxHeight))")
            throw ScanError.networkError
        }

        currentChainHeight = latestHeight

        // FIX #967: Update cachedChainHeight at START of scan (not just end)
        // This ensures FIX #167's validation in updateLastScannedHeight() uses current chain tip
        // Without this, FIX #167 blocks the update because cachedChainHeight is stale (from last session)
        // and new height is >100 blocks ahead of the "trusted" sources
        UserDefaults.standard.set(Int(latestHeight), forKey: "cachedChainHeight")
        print("📊 FIX #967: Updated cachedChainHeight to \(latestHeight) at scan start (enables FIX #167 validation)")

        // LOAD SHIELDED OUTPUTS FROM BOOST FILE
        await WalletManager.shared.updateDownloadTask("download_outputs", status: .inProgress)
        let bundledOutputs = BundledShieldedOutputs.shared
        let (loadSuccess, outputCount, _) = await bundledOutputs.loadFromBoostFile { progress, status in
            self.onStatusUpdate?("download", status)
            Task { @MainActor in
                WalletManager.shared.updateDownloadTaskProgress("download_outputs", detail: status, progress: progress)
            }
            self.onProgress?(progress * 0.05, 0, UInt64(latestHeight))
        }
        await WalletManager.shared.updateDownloadTask("download_outputs", status: .completed, detail: loadSuccess ? "\(outputCount) outputs" : "Using P2P")

        // DOWNLOAD/UPDATE BLOCK TIMESTAMPS FROM GITHUB
        await WalletManager.shared.updateDownloadTask("download_timestamps", status: .inProgress)
        let (timestampsSuccess, timestampsMaxHeight) = await BlockTimestampManager.shared.downloadIfNeeded { progress, status in
            self.onStatusUpdate?("download", status)
            Task { @MainActor in
                WalletManager.shared.updateDownloadTaskProgress("download_timestamps", detail: status, progress: progress)
            }
            self.onProgress?(0.05 + progress * 0.05, 0, UInt64(latestHeight))
        }
        await WalletManager.shared.updateDownloadTask("download_timestamps", status: .completed, detail: timestampsSuccess ? "Height \(timestampsMaxHeight)" : "Using estimates")

        // Test P2P block fetching before starting scan
        // FIX #896: Always use P2P (cypherpunk wallet - no centralized explorer)
        if FilterScanner.p2pBlockFetchingWorks == nil {
            let p2pWorks = await testP2PBlockFetching()
            FilterScanner.p2pBlockFetchingWorks = p2pWorks
            if !p2pWorks {
                print("❌ P2P block fetch failed - no fallback available (cypherpunk mode)")
                throw ScanError.networkError
            }
        }

        // Determine start height
        var startHeight: UInt64

        // VUL-018: Use shared constants - all tree data comes from GitHub
        // effectiveTreeHeight is the downloaded tree height (0 if not downloaded yet)
        let effectiveTreeHeight = ZipherXConstants.effectiveTreeHeight
        let effectiveTreeCMUCount = ZipherXConstants.effectiveTreeCMUCount

        // Track if we're scanning within downloaded tree range (notes only, no tree building)
        var scanWithinDownloadedRange = false

        // If custom start height provided (quick scan), use it
        if let customStart = customStartHeight {
            startHeight = customStart
            if startHeight <= effectiveTreeHeight {
                scanWithinDownloadedRange = true
            }
        } else {
            // Normal scan - determine start height automatically
            let lastScanned = try database.getLastScannedHeight()
            let treeExists = (try? database.getTreeState()) != nil
            let hasDownloadedTree = ZipherXConstants.hasDownloadedTree
            let isImportedWallet = WalletManager.shared.isImportedWallet
            let customScanHeight = WalletManager.shared.importScanStartHeight

            // FIX #726: Check if this is a Full Rescan (lastScanned=0 but wallet exists with tree)
            // In this case, we MUST scan from Sapling activation and enable PHASE 1
            // FIX #728: Also trigger for database repair (isRepairingDatabase) regardless of isImportedWallet
            let isRepairing = WalletManager.shared.isRepairingDatabase
            let isFullRescan = lastScanned == 0 && (treeExists || hasDownloadedTree) && (!isImportedWallet || isRepairing)

            // FIX #728: Debug logging to diagnose why PHASE 1 might be skipped
            if verbose {
                print("🔍 FIX #728: Start height determination:")
                print("   lastScanned=\(lastScanned), treeExists=\(treeExists), hasDownloadedTree=\(hasDownloadedTree)")
                print("   isImportedWallet=\(isImportedWallet), isRepairing=\(isRepairing), isFullRescan=\(isFullRescan)")
                print("   effectiveTreeHeight=\(effectiveTreeHeight)")
            }

            if isFullRescan {
                // FIX #726: CRITICAL - Full Rescan must start from Sapling activation
                // This ensures PHASE 1 runs to rediscover ALL historical notes
                startHeight = ZclassicCheckpoints.saplingActivationHeight
                scanWithinDownloadedRange = true
                isFullScanInProgress = true  // FIX #1092: Track full scan to skip redundant nullifier verification
                print("🔄 FIX #726: Full Rescan detected - starting from Sapling activation (\(startHeight)) with PHASE 1 enabled")

                // FIX #726: Load boost file data (should already be cached from previous use)
                let (_, boostHeight, boostOutputCount) = try await CommitmentTreeUpdater.shared.getBestAvailableBoostFile(onProgress: { progress, status in
                    self.onProgress?(progress * 0.10, startHeight, latestHeight)
                    self.onStatusUpdate?("download", "📥 \(status)")
                })
                // Extract CMUs in legacy format for position lookup
                if let cmuPath = await CommitmentTreeUpdater.shared.getCachedCMUFilePath(),
                   let cmuData = try? Data(contentsOf: cmuPath) {
                    self.cmuDataForPositionLookup = cmuData
                    self.cmuDataHeight = boostHeight
                    self.cmuDataCount = boostOutputCount
                    if verbose {
                        print("📦 FIX #726: Loaded CMU data for PHASE 1 - \(boostOutputCount) CMUs up to height \(boostHeight)")
                    }
                }

                // Load block hashes if not already loaded
                if !BundledBlockHashes.shared.isLoaded {
                    try? await BundledBlockHashes.shared.loadBundledHashes { _, _ in }
                }
            } else if lastScanned > 0 {
                startHeight = lastScanned + 1
                // FIX #178: CRITICAL - Set scanWithinDownloadedRange if notes may exist in downloaded tree range
                // This ensures PHASE 1 runs for consecutive startups where notes need to be discovered
                // without tree building. Without this, PHASE 1 is skipped and notes are lost!
                if startHeight <= effectiveTreeHeight && hasDownloadedTree {
                    scanWithinDownloadedRange = true
                    if verbose {
                        print("📋 FIX #178: Enabling PHASE 1 scan for consecutive startup (lastScanned=\(lastScanned), startHeight=\(startHeight), effectiveTreeHeight=\(effectiveTreeHeight))")
                    }
                }
            } else if isImportedWallet {
                if let customHeight = customScanHeight, customHeight > ZclassicCheckpoints.saplingActivationHeight {
                    startHeight = customHeight
                } else {
                    startHeight = ZclassicCheckpoints.saplingActivationHeight
                }
                scanWithinDownloadedRange = true
                isFullScanInProgress = true  // FIX #1092: Track full scan to skip redundant nullifier verification

                // DOWNLOAD BOOST FILE FROM GITHUB (required for imported wallets)
                let (_, boostHeight, boostOutputCount) = try await CommitmentTreeUpdater.shared.getBestAvailableBoostFile(onProgress: { progress, status in
                    // Show download progress prominently (0-30% of overall progress)
                    self.onProgress?(progress * 0.30, startHeight, latestHeight)
                    // Update status text to show download state
                    self.onStatusUpdate?("download", "📥 \(status)")
                })
                // Extract CMUs in legacy format for position lookup
                if let cmuPath = await CommitmentTreeUpdater.shared.getCachedCMUFilePath(),
                   let cmuData = try? Data(contentsOf: cmuPath) {
                    self.cmuDataForPositionLookup = cmuData
                    self.cmuDataHeight = boostHeight
                    self.cmuDataCount = boostOutputCount
                }

                // LOAD BLOCK HASHES for fast P2P block fetching
                if !BundledBlockHashes.shared.isLoaded {
                    try? await BundledBlockHashes.shared.loadBundledHashes { _, _ in }
                }
            } else if treeExists || hasDownloadedTree {
                startHeight = effectiveTreeHeight + 1
                // FIX #960: CRITICAL - Only skip trial decryption for TRULY new wallets
                // Previous bug: Set isNewWalletInitialSync=true when treeExists, but tree can exist
                // for existing wallets doing catch-up sync after app restart with lastScanned=0 (corruption)
                // This caused ZERO notes to be found on iOS because trial decryption was skipped!
                // Only skip decryption if:
                // 1. Tree does NOT exist in database (fresh wallet)
                // 2. We just downloaded the tree from boost file (new wallet setup)
                // If tree EXISTS in database, this is likely an existing wallet - NEED trial decryption
                isNewWalletInitialSync = !treeExists && hasDownloadedTree
                if verbose {
                    print("🔍 FIX #960: isNewWalletInitialSync=\(isNewWalletInitialSync) (treeExists=\(treeExists), hasDownloadedTree=\(hasDownloadedTree))")
                }
            } else {
                // No tree downloaded yet - must download first
                startHeight = ZclassicCheckpoints.saplingActivationHeight
                isFullScanInProgress = true  // FIX #1092: Track full scan to skip redundant nullifier verification
            }
        }

        // If startHeight > latestHeight, refresh height from P2P (FIX #896: no InsightAPI)
        if startHeight > latestHeight {
            if let p2pHeight = try? await networkManager.getChainHeight(), p2pHeight >= startHeight {
                currentChainHeight = p2pHeight
            } else {
                onProgress?(1.0, latestHeight, latestHeight)
                return
            }
        }

        let targetHeight = currentChainHeight

        guard startHeight <= targetHeight else {
            onProgress?(1.0, targetHeight, targetHeight)
            return
        }

        // Calculate total blocks to scan
        let totalBlocks = targetHeight - startHeight + 1
        var scannedBlocks: UInt64 = 0

        // Keep spending key for direct decryption (uses zcash_primitives internally)
        let spendingKey = viewingKey
        // SECURITY: Never log keys or IVK

        // Derive IVK for nullifier computation
        let ivk = deriveIncomingViewingKey(from: viewingKey)
        // SECURITY: IVK and address details not logged

        let walletAddress = WalletManager.shared.zAddress
        _ = ZipherXFFI.decodeAddress(walletAddress) // Decode for internal use only

        // Load known nullifiers from database for spend detection
        knownNullifiers = try database.getAllNullifiers()
        // FIX #288: Debug - show loaded nullifiers
        if verbose {
            print("🔍 FIX #288: Loaded \(knownNullifiers.count) nullifiers from DB for spend detection")
            for (idx, nf) in knownNullifiers.enumerated().prefix(5) {
                let shortNf = nf.prefix(8).map { String(format: "%02x", $0) }.joined()
                print("🔍 FIX #288: knownNullifier[\(idx)] = \(shortNf)...")
            }
        }

        // NOTE: Existing witnesses are loaded AFTER tree is ready (see below)
        // This is critical - witnesses must be loaded into an initialized tree
        let existingNotes = try database.getUnspentNotes(accountId: accountId)
        existingWitnessIndices = []

        // Determine if we need to reset tree for a rescan
        // Only reload tree for EXPLICIT rescans from effective height, NOT for background sync
        // Background sync passes heights > effectiveTreeHeight and should APPEND
        // A rescan specifically starts at effectiveTreeHeight + 1 to rebuild from current tree state
        let initialTreeSize = ZipherXFFI.treeSize()
        let treeHasProgress = initialTreeSize > effectiveTreeCMUCount

        // FIX #780: Check if pendingDeltaRescan flag is set
        // When FIX #765 clears delta bundle and sets this flag, we MUST reset the tree
        // Otherwise the tree accumulates stale CMUs from previous scans
        let hasPendingDeltaRescan = await MainActor.run { WalletManager.shared.pendingDeltaRescan }

        // Only force fresh tree if:
        // 1. Custom height provided AND starting exactly from effective+1 (rescan scenario)
        // 2. AND tree doesn't already have progress (hasn't appended CMUs beyond effective)
        // FIX #780: OR if pendingDeltaRescan is set (delta was cleared, need fresh tree)
        let needsFreshTree = (customStartHeight != nil
            && customStartHeight! == effectiveTreeHeight + 1
            && !treeHasProgress) || hasPendingDeltaRescan

        if hasPendingDeltaRescan {
            print("🔧 FIX #780: pendingDeltaRescan detected - forcing fresh tree from boost file")
        }

        // CRITICAL: Check if tree is already loaded in FFI memory (WalletManager may have loaded it)
        // This prevents race condition where FilterScanner loads again while WalletManager is loading
        let existingTreeSize = ZipherXFFI.treeSize()

        // Wait for WalletManager to finish loading tree before proceeding
        // FIX #1294: Skip when tree already in FFI (catch-up after Full Rescan) or during Full Rescan itself
        if !needsFreshTree && !isFullScanInProgress && existingTreeSize == 0 {
            let walletManager = WalletManager.shared
            var waitAttempts = 0
            let maxWaitAttempts = 1200 // 120 seconds max wait
            while !walletManager.isTreeLoaded && waitAttempts < maxWaitAttempts {
                try await Task.sleep(nanoseconds: 100_000_000) // 100ms
                waitAttempts += 1
            }
        }

        // For imported wallets scanning within downloaded tree range
        _ = scanWithinDownloadedRange  // Used implicitly via effectiveTreeCMUCount
        let requiredTreeSize = effectiveTreeCMUCount

        if !needsFreshTree && existingTreeSize > 0 {
            if existingTreeSize >= requiredTreeSize {
                treeInitialized = true
                // Load CMU data for position lookup from GitHub cache
                if let cachedPath = await CommitmentTreeUpdater.shared.getCachedCMUFilePath(),
                   let cachedInfo = await CommitmentTreeUpdater.shared.getCachedTreeInfo(),
                   let cachedData = try? Data(contentsOf: cachedPath) {
                    self.cmuDataForPositionLookup = cachedData
                    self.cmuDataHeight = cachedInfo.height
                    self.cmuDataCount = cachedInfo.cmuCount
                }
            } else {
                try? database.clearTreeState()
                treeInitialized = false
            }
        }

        // Initialize from database state
        if !treeInitialized && !needsFreshTree, let treeData = try? database.getTreeState() {
            if ZipherXFFI.treeDeserialize(data: treeData) {
                let treeSize = ZipherXFFI.treeSize()
                if treeSize >= requiredTreeSize {
                    treeInitialized = true
                } else {
                    try? database.clearTreeState()
                    treeInitialized = false
                }
            } else {
                treeInitialized = false
            }
        }

        // Force reload tree for rescans
        if needsFreshTree {
            // FIX #780: Clear FFI tree when forcing fresh tree
            // This ensures we don't accumulate CMUs from previous failed scans
            if hasPendingDeltaRescan {
                print("🔧 FIX #780: Clearing FFI tree before fresh scan")
                _ = ZipherXFFI.treeInit()
            }
            treeInitialized = false
        }

        // Load tree from boost file - MUST download from GitHub
        if !treeInitialized {
            // Try to extract serialized tree from cached boost file
            if await CommitmentTreeUpdater.shared.hasCachedBoostFile(),
               let cachedInfo = await CommitmentTreeUpdater.shared.getCachedTreeInfo() {

                do {
                    // Extract serialized tree (fast - just the frontier)
                    let serializedTree = try await CommitmentTreeUpdater.shared.extractSerializedTree()
                    if ZipherXFFI.treeDeserialize(data: serializedTree) {
                        let treeSize = ZipherXFFI.treeSize()
                        print("🌳 Tree deserialized: \(treeSize) commitments from boost file")
                        treeInitialized = true
                        self.cmuDataHeight = cachedInfo.height
                        self.cmuDataCount = cachedInfo.cmuCount

                        // Also load CMU data for position lookup (needed for nullifier computation)
                        if let cmuPath = await CommitmentTreeUpdater.shared.getCachedCMUFilePath(),
                           let cmuData = try? Data(contentsOf: cmuPath) {
                            self.cmuDataForPositionLookup = cmuData
                        }

                        // FIX #1138: Save tree state WITH HEIGHT from cached boost info
                        if let treeData = ZipherXFFI.treeSerialize() {
                            try? database.saveTreeState(treeData, height: cachedInfo.height)
                        }
                    } else {
                        // FIX #528: Deserialization failed - try legacy CMU fallback
                        print("⚠️ FIX #528: Cached tree deserialization failed - trying legacy CMU fallback")
                        treeInitialized = await loadTreeFromLegacyCMUs(boostHeight: cachedInfo.height, boostOutputCount: cachedInfo.cmuCount)
                    }
                } catch {
                    print("⚠️ FIX #528: Failed to extract serialized tree: \(error) - trying legacy CMU fallback")
                    treeInitialized = await loadTreeFromLegacyCMUs(boostHeight: cachedInfo.height, boostOutputCount: cachedInfo.cmuCount)
                }
            }

            // If still not initialized, download boost file from GitHub
            if !treeInitialized {
                print("⚠️ No commitment tree available - downloading from GitHub...")
                let (_, boostHeight, boostOutputCount) = try await CommitmentTreeUpdater.shared.getBestAvailableBoostFile { progress, status in
                    // Show download progress prominently (0-30% of overall progress)
                    self.onProgress?(progress * 0.30, startHeight, targetHeight)
                    // Update status text to show download state
                    self.onStatusUpdate?("download", "📥 \(status)")
                }

                // Extract and deserialize tree
                do {
                    let serializedTree = try await CommitmentTreeUpdater.shared.extractSerializedTree()
                    if ZipherXFFI.treeDeserialize(data: serializedTree) {
                        let treeSize = ZipherXFFI.treeSize()
                        print("🌳 Tree deserialized: \(treeSize) commitments from GitHub boost file")
                        treeInitialized = true
                        self.cmuDataHeight = boostHeight
                        self.cmuDataCount = boostOutputCount

                        // Load CMU data for position lookup
                        if let cmuPath = await CommitmentTreeUpdater.shared.getCachedCMUFilePath(),
                           let cmuData = try? Data(contentsOf: cmuPath) {
                            self.cmuDataForPositionLookup = cmuData
                        }

                        // FIX #1138: Save tree state WITH HEIGHT from boost file
                        if let treeData = ZipherXFFI.treeSerialize() {
                            try? database.saveTreeState(treeData, height: boostHeight)
                        }
                    } else {
                        // FIX #528: Deserialization failed - try loading from legacy CMU file
                        print("⚠️ FIX #528: Tree deserialization failed - trying legacy CMU fallback")
                        treeInitialized = await loadTreeFromLegacyCMUs(boostHeight: boostHeight, boostOutputCount: boostOutputCount)
                    }
                } catch {
                    print("❌ Failed to extract tree from boost file: \(error)")
                    // FIX #528: Try fallback to legacy CMU loading
                    print("⚠️ FIX #528: Extract failed - trying legacy CMU fallback")
                    treeInitialized = await loadTreeFromLegacyCMUs(boostHeight: boostHeight, boostOutputCount: boostOutputCount)
                }
            }
        }

        if !treeInitialized {
            treeInitialized = ZipherXFFI.treeInit()
        }

        guard treeInitialized else {
            print("❌ Failed to initialize commitment tree")
            throw ScanError.databaseError
        }

        // Load existing witnesses into FFI
        for note in existingNotes {
            // FIX #1107: Changed from 1028 to 100
            if note.witness.count >= 100 {
                let witnessIndex = note.witness.withUnsafeBytes { ptr in
                    ZipherXFFI.treeLoadWitness(
                        witnessData: ptr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        witnessLen: note.witness.count
                    )
                }
                if witnessIndex != UInt64.max {
                    existingWitnessIndices.append((noteId: note.id, witnessIndex: witnessIndex))
                }
            }
        }

        // Clear pending witnesses for this scan
        pendingWitnesses = []

        // Report initial progress immediately so UI shows progress bar
        onProgress?(0.01, startHeight, targetHeight)

        // Determine scanning strategy:
        // - If scanning within downloaded tree range: use PARALLEL mode (note discovery only)
        // - If scanning after downloaded tree: use SEQUENTIAL mode (tree building + note discovery)
        var currentHeight = startHeight

        // PHASE 1: If we're scanning within CMU data range, scan those blocks first (batch/fast)
        // CRITICAL: PHASE 1 must only go up to cmuDataHeight (downloaded from GitHub)
        // because that's where we have CMU data for position lookup. Beyond cmuDataHeight, notes
        // MUST be scanned in PHASE 2 sequential mode where positions are computed as CMUs are appended.
        let phase1EndHeight = cmuDataHeight > 0 ? cmuDataHeight : effectiveTreeHeight

        // FIX #1097: Debug logging to understand why PHASE 1 might be skipped
        if verbose {
            print("🔍 FIX #1097: PHASE 1 check - scanWithinDownloadedRange=\(scanWithinDownloadedRange), startHeight=\(startHeight), phase1EndHeight=\(phase1EndHeight)")
            print("🔍 FIX #1097: cmuDataHeight=\(cmuDataHeight), effectiveTreeHeight=\(effectiveTreeHeight), targetHeight=\(targetHeight)")
            if !scanWithinDownloadedRange {
                print("⚠️ FIX #1097: PHASE 1 will be SKIPPED - scanWithinDownloadedRange is FALSE")
            } else if startHeight > phase1EndHeight {
                print("⚠️ FIX #1097: PHASE 1 will be SKIPPED - startHeight (\(startHeight)) > phase1EndHeight (\(phase1EndHeight))")
            }
        }

        if scanWithinDownloadedRange && startHeight <= phase1EndHeight {
            let parallelEndHeight = min(phase1EndHeight, targetHeight)
            print("⚡ PHASE 1: \(startHeight) → \(parallelEndHeight) (\(parallelEndHeight - startHeight + 1) blocks)")
            let parallelTotalBlocks = parallelEndHeight - startHeight + 1
            var parallelScannedBlocks: UInt64 = 0
            // FIX #1095: Dynamic batch size based on peer capacity
            let peerCount = await MainActor.run { NetworkManager.shared.peers.filter { $0.isConnectionReady }.count }
            let maxBlocksPerPeer = 128
            // FIX #1287: Dynamic batch = 2 chunks per peer (scales with connected peers)
            let batchSize = max(peerCount, 3) * 256

            // Collect ALL spends during PHASE 1 for later spend detection (PHASE 1.6)
            // Format: (height, txid, nullifierHex)
            var collectedSpends: [(UInt64, String, String)] = []

            // =====================================================================
            // NEW: Use complete Rust FFI for boost file scanning (migrated from Swift)
            // This processes the ENTIRE boost file at once, exactly like bench_boost_scan.rs
            // Key insight: position = enumerate index in outputs array (blockchain order)
            // =====================================================================
            var usedRustBoostScan = false

            if await CommitmentTreeUpdater.shared.hasCachedBoostFile() {
                do {
                    // Update status BEFORE the long Rust operation
                    onStatusUpdate?("phase1", "Decrypting historical notes (Rust)...")
                    reportPhase1Progress(0.05, height: currentHeight, maxHeight: targetHeight)

                    print("🦀 Starting complete Rust boost file scan...")
                    let result = try await processBoostFileWithRust(
                        accountId: accountId,
                        spendingKey: spendingKey
                    ) { phase, detail in
                        // Progress callback from processBoostFileWithRust
                        // Map sub-phases to 5-40% progress
                        let subProgress: Double
                        switch phase {
                        case "extract_outputs": subProgress = 0.10
                        case "extract_spends": subProgress = 0.15
                        case "rust_scan": subProgress = 0.20
                        case "store_notes": subProgress = 0.80
                        case "complete": subProgress = 1.0
                        default: subProgress = 0.50
                        }
                        // FIX #469: Pass custom detail to preserve the descriptive message
                        self.reportPhase1Progress(subProgress, height: self.currentChainHeight, maxHeight: targetHeight, customDetail: detail)
                    }
                    print("🦀 Rust scan complete: \(result.notesFound) notes, \(result.notesSpent) spent, balance: \(result.balance.redactedAmount)")
                    usedRustBoostScan = true

                    // Skip to PHASE 2 since boost file covers everything up to phase1EndHeight
                    currentHeight = parallelEndHeight + 1

                    // Report progress as 40% complete (PHASE 1 done)
                    reportPhase1Progress(1.0, height: parallelEndHeight, maxHeight: targetHeight)

                } catch {
                    print("⚠️ Rust boost scan failed, falling back to batch processing: \(error)")
                    usedRustBoostScan = false
                }
            }

            // Only use batch processing if Rust scan failed or boost file unavailable
            while !usedRustBoostScan && currentHeight <= parallelEndHeight && isScanning {
                let remainingBlocks = Int(parallelEndHeight - currentHeight + 1)
                let thisBatchSize = min(batchSize, remainingBlocks)
                let endHeight = currentHeight + UInt64(thisBatchSize) - 1


                // Use batch P2P fetch - much faster than individual requests!
                var blockDataMap: [UInt64: [(String, [ShieldedOutput], [ShieldedSpend]?)]] = [:]

                // PRIORITY 1: Use bundled shielded outputs file if available (FAST BINARY PATH)
                let bundledOutputs = BundledShieldedOutputs.shared
                var usedOptimizedPath = false

                if bundledOutputs.isAvailable && endHeight <= bundledOutputs.bundledEndHeight {
                    // OPTIMIZED: Use direct binary path - no hex string conversion!
                    // This matches the benchmark's performance (~14s instead of ~90s for 1M outputs)
                    let boostOutputs = bundledOutputs.getOutputsForParallelDecryption(from: currentHeight, to: endHeight)

                    if !boostOutputs.isEmpty {
                        do {
                            try processBoostOutputsParallel(
                                outputs: boostOutputs,
                                accountId: accountId,
                                spendingKey: spendingKey,
                                baseHeight: currentHeight
                            )
                            usedOptimizedPath = true
                        } catch {
                            print("⚠️ Optimized boost path failed, falling back to network: \(error)")
                        }
                    }
                }

                if !usedOptimizedPath {
                    // FIX #294: Track and retry failed block fetches
                    var failedHeights: Set<UInt64> = []
                    let maxRetries = 3

                    // PRIORITY 2: Network fetch (P2P or InsightAPI)
                    do {
                        // Try P2P batch fetch first
                        let isConnectedForBatch = await MainActor.run { networkManager.isConnected }
                        if FilterScanner.p2pBlockFetchingWorks != false && isConnectedForBatch {
                            let results = try await networkManager.getBlocksDataP2P(from: currentHeight, count: thisBatchSize)
                            for (height, _, timestamp, txData) in results {
                                blockDataMap[height] = txData
                                // Cache real block timestamps for transaction history
                                BlockTimestampManager.shared.cacheTimestamp(height: height, timestamp: timestamp)
                            }
                            FilterScanner.p2pBlockFetchingWorks = true

                            // FIX #294: Track any heights that weren't returned
                            let fetchedHeights = Set(results.map { $0.0 })
                            for height in currentHeight...endHeight {
                                if !fetchedHeights.contains(height) {
                                    failedHeights.insert(height)
                                }
                            }
                        } else {
                            throw ScanError.networkError
                        }
                    } catch {
                        // FIX #896: P2P only mode - no InsightAPI fallback (cypherpunk wallet)
                        // Mark all heights as failed for retry
                        for height in currentHeight...endHeight {
                            failedHeights.insert(height)
                        }
                    }

                    // FIX #294: Retry failed block fetches with exponential backoff
                    if !failedHeights.isEmpty && isScanning {
                        if verbose {
                            print("⚠️ FIX #294: \(failedHeights.count) blocks failed, retrying...")
                        }

                        for attempt in 1...maxRetries {
                            guard isScanning && !failedHeights.isEmpty else { break }

                            // Exponential backoff: 1s, 2s, 4s
                            try? await Task.sleep(nanoseconds: UInt64(1_000_000_000 * (1 << (attempt - 1))))

                            var stillFailed: Set<UInt64> = []

                            // FIX #1213: Batch retry failed heights in contiguous ranges instead of one-by-one
                            // Previous code fetched each height with getBlocksDataP2P(count: 1) — extremely slow
                            // for large failures (30ms/block × 1000 blocks = 30 seconds vs ~2 seconds batched)
                            let sortedFailed = Array(failedHeights.sorted())
                            let isConnectedForRetry = await MainActor.run { networkManager.isConnected }
                            if isConnectedForRetry && !sortedFailed.isEmpty {
                                // Group into contiguous ranges (max 128 per batch - P2P protocol limit)
                                var ranges: [(start: UInt64, count: Int)] = []
                                var rangeStart = sortedFailed[0]
                                var rangeEnd = sortedFailed[0]
                                for i in 1..<sortedFailed.count {
                                    if sortedFailed[i] == rangeEnd + 1 && Int(sortedFailed[i] - rangeStart) < 128 {
                                        rangeEnd = sortedFailed[i]
                                    } else {
                                        ranges.append((start: rangeStart, count: Int(rangeEnd - rangeStart) + 1))
                                        rangeStart = sortedFailed[i]
                                        rangeEnd = sortedFailed[i]
                                    }
                                }
                                ranges.append((start: rangeStart, count: Int(rangeEnd - rangeStart) + 1))

                                if verbose {
                                    print("🔄 FIX #1213: Retrying \(sortedFailed.count) failed heights in \(ranges.count) batches (was \(sortedFailed.count) individual requests)")
                                }

                                for range in ranges {
                                    do {
                                        let results = try await networkManager.getBlocksDataP2P(from: range.start, count: range.count)
                                        for (h, _, timestamp, txData) in results {
                                            blockDataMap[h] = txData
                                            BlockTimestampManager.shared.cacheTimestamp(height: h, timestamp: timestamp)
                                        }
                                    } catch {
                                        // All heights in this range stay as failed
                                    }
                                }

                                // Determine which heights are still missing
                                for height in sortedFailed {
                                    if blockDataMap[height] == nil {
                                        stillFailed.insert(height)
                                    }
                                }
                            } else {
                                stillFailed = failedHeights
                            }

                            failedHeights = stillFailed

                            if failedHeights.isEmpty {
                                if verbose {
                                    print("✅ FIX #294: All blocks recovered on retry \(attempt)")
                                }
                                break
                            } else if attempt < maxRetries {
                                if verbose {
                                    print("⚠️ FIX #294: Retry \(attempt)/\(maxRetries) - \(failedHeights.count) blocks still failing")
                                }
                            }
                        }

                        // Log permanently failed blocks (potential missed transactions!)
                        if !failedHeights.isEmpty {
                            let sortedFailed = failedHeights.sorted()
                            print("❌ FIX #294: CRITICAL - \(failedHeights.count) blocks permanently failed: \(sortedFailed.prefix(10))...")
                            print("   ⚠️ Transactions in these blocks may be MISSED! Consider repair database.")
                        }
                    }
                }

                // PARALLEL BATCH PROCESSING (6.7x speedup via Rayon)
                // Process entire batch at once instead of one-by-one
                // Skip if we already used the optimized boost path (processBoostOutputsParallel)
                if !usedOptimizedPath && !blockDataMap.isEmpty {
                    do {
                        try processBlocksBatchParallel(
                            blockDataMap: blockDataMap,
                            heightRange: currentHeight...endHeight,
                            accountId: accountId,
                            spendingKey: spendingKey,
                            collectedSpends: &collectedSpends,
                            cmuDataForPositionLookup: self.cmuDataForPositionLookup
                        )
                    } catch {
                        print("❌ Error in parallel batch processing: \(error)")
                    }
                }

                // Update progress (PHASE 1: 0-40%)
                parallelScannedBlocks += UInt64(endHeight - currentHeight + 1)
                let localProgress = Double(parallelScannedBlocks) / Double(parallelTotalBlocks)
                reportPhase1Progress(localProgress, height: endHeight, maxHeight: targetHeight)

                try? database.updateLastScannedHeight(endHeight, hash: Data(count: 32))
                FilterScanner.updateScanProgress()  // FIX #1074: Update progress time to prevent timeout
                currentHeight = endHeight + 1
            }

            print("✅ PHASE 1 complete: \(knownNullifiers.count) notes, \(collectedSpends.count) spends")

            // PHASE 1.5: Pre-compute witnesses using PARALLEL function (Rayon multi-threaded)
            // This computes all witnesses in ~40-60 seconds using all CPU cores
            // FIX #947: Skip PHASE 1.5 if deferred witness computation is enabled
            // Witnesses will be computed lazily on first SEND attempt
            if deferWitnessComputation {
                print("⚡ FIX #947: PHASE 1.5 SKIPPED - Deferred witness computation enabled")
                print("   Witnesses will be computed on first SEND (saves ~40-60 seconds)")
                // Still report progress to keep UI moving
                reportPhase15Progress(1.0, current: 0, total: 0)
            } else if let bundledData = cmuDataForPositionLookup {
                await computeWitnessesForBundledNotesBatch(bundledData: bundledData)

                // CRITICAL: After PHASE 1.5, load the computed witnesses into FFI global tree
                // so they get auto-updated during PHASE 2 CMU appends.
                // This ensures all notes end up with the SAME anchor (enabling INSTANT mode).
                do {
                    guard let account = try database.getAccount(index: 0) else { throw ScanError.databaseError }
                    let phase1Notes = try database.getAllUnspentNotes(accountId: account.accountId)
                    var loadedCount = 0
                    for note in phase1Notes {
                        // Only load valid witnesses (not empty/all zeros)
                        // FIX #1107: Changed from 1028 to 100
                        if note.witness.count >= 100 && !note.witness.allSatisfy({ $0 == 0 }) {
                            let witnessIndex = note.witness.withUnsafeBytes { ptr in
                                ZipherXFFI.treeLoadWitness(
                                    witnessData: ptr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                                    witnessLen: note.witness.count
                                )
                            }
                            if witnessIndex != UInt64.max {
                                // Track for later update at end of PHASE 2
                                existingWitnessIndices.append((noteId: note.id, witnessIndex: witnessIndex))
                                loadedCount += 1
                            }
                        }
                    }
                    if loadedCount > 0 {
                        print("🔧 Loaded \(loadedCount) PHASE 1 witnesses into FFI for PHASE 2 updates")
                    }
                } catch {
                    debugLog(.error, "Failed to load PHASE 1.5 witnesses into FFI: \(error)")
                }
            }

            // PHASE 1.6: SPEND DETECTION PASS
            if !knownNullifiers.isEmpty && !collectedSpends.isEmpty {
                reportPhase16Progress(0.0, detected: 0, total: collectedSpends.count)
                var spendsDetected = 0
                var processed = 0

                for (height, txid, nullifierHex) in collectedSpends {
                    guard let nullifierDisplay = Data(hexString: nullifierHex) else { continue }
                    let nullifierWire = nullifierDisplay.reversedBytes()
                    // FIX #367: Hash the blockchain nullifier before comparing
                    let hashedNullifier = database.hashNullifier(nullifierWire)
                    let hashedNullifierReversed = database.hashNullifier(nullifierDisplay)

                    // FIX #1079: Check all formats - hashed and raw, both byte orders
                    let matchesHashedWire = knownNullifiers.contains(hashedNullifier)
                    let matchesHashedDisplay = knownNullifiers.contains(hashedNullifierReversed)
                    let matchesRawWire = knownNullifiers.contains(nullifierWire)
                    let matchesRawDisplay = knownNullifiers.contains(nullifierDisplay)

                    if matchesHashedWire || matchesHashedDisplay || matchesRawWire || matchesRawDisplay {
                        let nullifierForDb = (matchesHashedWire || matchesRawWire) ? nullifierWire : nullifierDisplay
                        let txidData = Data(hexString: txid)
                        if let txidData = txidData {
                            try? database.markNoteSpent(nullifier: nullifierForDb, txid: txidData, spentHeight: height)
                        } else {
                            try? database.markNoteSpent(nullifier: nullifierForDb, spentHeight: height)
                        }
                        spendsDetected += 1
                    }
                    processed += 1
                    if processed % 1000 == 0 {
                        let localProgress = Double(processed) / Double(collectedSpends.count)
                        reportPhase16Progress(localProgress, detected: spendsDetected, total: collectedSpends.count)
                    }
                }
                reportPhase16Progress(1.0, detected: spendsDetected, total: collectedSpends.count)
                if spendsDetected > 0 {
                    print("✅ PHASE 1.6: \(spendsDetected) spent notes detected")
                }
            }

            // CHECKPOINT: Save state at PHASE 1 completion
            // This ensures we don't have to re-scan historical blocks if interrupted
            try? database.updateLastScannedHeight(phase1EndHeight, hash: Data(count: 32))
            FilterScanner.updateScanProgress()  // FIX #1074: Update progress time to prevent timeout
            // FIX #1138: Save tree state WITH HEIGHT
            if let treeData = ZipherXFFI.treeSerialize() {
                try? database.saveTreeState(treeData, height: phase1EndHeight)
            }
            print("💾 FIX #1138: PHASE 1 checkpoint saved at height \(phase1EndHeight)")

            // Move to blocks after CMU data height for PHASE 2
            // Use phase1EndHeight (which is cmuDataHeight from GitHub if available)
            // PHASE 2 only needs to scan blocks beyond what we have CMU data for
            currentHeight = phase1EndHeight + 1

            // ═══════════════════════════════════════════════════════════════════
            // PHASE 1b: Local delta scan with nullifiers (FIX #1289 v3)
            //
            // Delta bundle stores BOTH outputs (CMU+epk+ciphertext) AND nullifiers
            // (spends). This enables complete local processing:
            // 1. Trial decryption → note discovery (same as boost scan)
            // 2. Nullifier matching → spend detection (same as Phase 1.6)
            // 3. Tree building → correct commitment tree
            // 4. Witness creation → spendable notes
            //
            // Requires: Delta nullifiers SUFFICIENT for block range (FIX #1299)
            // Fallback: If nullifiers absent/insufficient, Phase 2 handles via P2P
            // ═══════════════════════════════════════════════════════════════════
            // FIX #1299: Check delta nullifier SUFFICIENCY (not just existence)
            // hasNullifiers() only checks file exists — could have 1 entry from recent catch-up
            // Phase 1b needs nullifiers covering the FULL delta range for reliable spend detection
            // Without sufficient nullifiers: notes found but spends missed → balance inflation (FIX #1289 v3 bug)
            // Blockchain average: ~1 nullifier per 6 blocks (434K / 2.5M Sapling blocks)
            // Conservative minimum: 1 per 100 blocks, floor of 5
            let deltaHasEnoughNullifiers: Bool = {
                guard let deh = preservedDeltaEndHeight, deh > phase1EndHeight else { return false }
                guard let nullifiers = DeltaCMUManager.shared.loadNullifiers() else { return false }
                let rangeCount = nullifiers.filter {
                    UInt64($0.height) > phase1EndHeight && UInt64($0.height) <= deh
                }.count
                let blockCount = Int(deh - phase1EndHeight)
                let minRequired = max(5, blockCount / 100)
                if rangeCount < minRequired {
                    print("⚠️ FIX #1299: Delta nullifiers insufficient (\(rangeCount) in range, need \(minRequired) for \(blockCount) blocks) — skipping Phase 1b, Phase 2 will handle")
                } else {
                    print("✅ FIX #1299: Delta nullifiers sufficient (\(rangeCount) in range, need \(minRequired) for \(blockCount) blocks)")
                }
                return rangeCount >= minRequired
            }()

            if let deltaEndHeight = preservedDeltaEndHeight,
               deltaEndHeight > phase1EndHeight,
               deltaHasEnoughNullifiers {

                let deltaBlockCount = deltaEndHeight - phase1EndHeight
                print("⚡ PHASE 1b: Scanning delta locally (\(deltaBlockCount) blocks, \(phase1EndHeight + 1) → \(deltaEndHeight))")
                let phase1bStart = Date()

                // ── Step 1: Trial decrypt delta outputs (note discovery) ──
                let boostCMUCount = cmuDataCount
                var phase1bNotesFound = 0
                if let deltaOutputs = DeltaCMUManager.shared.getOutputsForParallelDecryption(startGlobalPosition: boostCMUCount),
                   !deltaOutputs.isEmpty {
                    var ffiOutputs: [(output: ZipherXFFI.FFIShieldedOutput, height: UInt32, cmu: Data, globalPosition: UInt64)] = []
                    ffiOutputs.reserveCapacity(deltaOutputs.count)
                    for item in deltaOutputs {
                        let ffiOutput = ZipherXFFI.FFIShieldedOutput(epk: item.epk, cmu: item.cmu, ciphertext: item.ciphertext)
                        ffiOutputs.append((output: ffiOutput, height: item.height, cmu: item.cmu, globalPosition: item.globalPosition))
                    }

                    if !ffiOutputs.isEmpty {
                        let baseHeight = UInt64(ffiOutputs.first!.height)
                        let notesBefore = knownNullifiers.count
                        try processBoostOutputsParallel(
                            outputs: ffiOutputs,
                            accountId: accountId,
                            spendingKey: spendingKey,
                            baseHeight: baseHeight
                        )
                        phase1bNotesFound = knownNullifiers.count - notesBefore
                        if verbose {
                            print("✅ FIX #1289 v3: Phase 1b trial decryption found \(phase1bNotesFound) notes in \(deltaOutputs.count) outputs")
                        }
                    }
                }

                // ── Step 2: Spend detection using delta nullifiers ──
                var phase1bSpendsDetected = 0
                if let deltaNullifiers = DeltaCMUManager.shared.loadNullifiers(), !deltaNullifiers.isEmpty {
                    for nf in deltaNullifiers {
                        let nullifierWire = nf.nullifier
                        let nullifierDisplay = Data(nullifierWire.reversed())

                        let hashedWire = database.hashNullifier(nullifierWire)
                        let hashedDisplay = database.hashNullifier(nullifierDisplay)

                        let matchesHashedWire = knownNullifiers.contains(hashedWire)
                        let matchesHashedDisplay = knownNullifiers.contains(hashedDisplay)
                        let matchesRawWire = knownNullifiers.contains(nullifierWire)
                        let matchesRawDisplay = knownNullifiers.contains(nullifierDisplay)

                        if matchesHashedWire || matchesHashedDisplay || matchesRawWire || matchesRawDisplay {
                            let nullifierForDb = (matchesHashedWire || matchesRawWire) ? nullifierWire : nullifierDisplay
                            try? database.markNoteSpent(nullifier: nullifierForDb, txid: nf.txid, spentHeight: UInt64(nf.height))
                            phase1bSpendsDetected += 1
                        }
                    }
                    if phase1bSpendsDetected > 0 {
                        if verbose {
                            print("💸 FIX #1289 v3: Phase 1b detected \(phase1bSpendsDetected) spends from \(deltaNullifiers.count) nullifiers")
                        }
                    }
                }

                // ── Step 3: Append delta CMUs to tree + create witnesses ──
                var phase1bWitnessCount = 0
                if let deltaCMUs = DeltaCMUManager.shared.loadDeltaCMUs(), !deltaCMUs.isEmpty {
                    let treeSize = Int(ZipherXFFI.treeSize())
                    let boostSize = Int(boostCMUCount)
                    // FIX #978: Size-based guard — skip CMUs already in tree
                    let cmusAlreadyBeyondBoost = max(0, treeSize - boostSize)
                    let cmusToAppend = cmusAlreadyBeyondBoost > 0
                        ? Array(deltaCMUs.dropFirst(cmusAlreadyBeyondBoost))
                        : deltaCMUs

                    // Build map of CMU → noteId for delta-range notes (for witness creation)
                    // Pre-load once before the append loop to avoid repeated DB queries
                    var cmuToNoteId: [Data: Int64] = [:]
                    if let account = try? database.getAccount(index: 0) {
                        let allNotes = try? database.getAllNotes(accountId: account.accountId)
                        for note in allNotes ?? [] {
                            if note.height > phase1EndHeight && note.height <= deltaEndHeight,
                               let cmu = note.cmu, cmu.count == 32 {
                                cmuToNoteId[cmu] = note.id
                            }
                        }
                    }

                    // Append CMUs and create witnesses inline
                    var witnessIndices: [(noteId: Int64, witnessIndex: UInt64)] = []
                    for cmu in cmusToAppend {
                        _ = ZipherXFFI.treeAppend(cmu: cmu)

                        // When we hit a CMU belonging to a note, register witness
                        if let noteId = cmuToNoteId[cmu] {
                            let witnessIndex = ZipherXFFI.treeWitnessCurrent()
                            if witnessIndex != UInt64.max {
                                witnessIndices.append((noteId: noteId, witnessIndex: witnessIndex))
                            }
                        }
                    }

                    if verbose {
                        print("🌳 FIX #1289 v3: Appended \(cmusToAppend.count) delta CMUs (tree size: \(ZipherXFFI.treeSize()))")
                    }

                    // ── Step 4: Save witnesses with anchor validation ──
                    for (noteId, witnessIndex) in witnessIndices {
                        guard let witnessData = ZipherXFFI.treeGetWitness(index: witnessIndex) else { continue }
                        // FIX #1280: Validate witness root against FFI tree root
                        guard let witnessRoot = ZipherXFFI.witnessGetRoot(witnessData),
                              let treeRoot = ZipherXFFI.treeRoot(),
                              witnessRoot == treeRoot else {
                            print("⚠️ FIX #1289 v3: Witness root mismatch for note \(noteId) — skipping")
                            continue
                        }
                        try? database.updateNoteWitness(noteId: noteId, witness: witnessData)
                        try? database.updateNoteAnchor(noteId: noteId, anchor: treeRoot)
                        try? database.updateNoteWitnessIndex(noteId: noteId, witnessIndex: witnessIndex)
                        // Load into FFI for Phase 2 auto-updates
                        existingWitnessIndices.append((noteId: noteId, witnessIndex: witnessIndex))
                        phase1bWitnessCount += 1
                    }
                    if phase1bWitnessCount > 0 {
                        if verbose {
                            print("✅ FIX #1289 v3: Created \(phase1bWitnessCount) witnesses for delta-range notes")
                        }
                    }
                }

                // ── Step 5: Checkpoint at delta end height ──
                try? database.updateLastScannedHeight(deltaEndHeight, hash: Data(count: 32))
                FilterScanner.updateScanProgress()
                if let treeData = ZipherXFFI.treeSerialize() {
                    try? database.saveTreeState(treeData, height: deltaEndHeight)
                }
                currentHeight = deltaEndHeight + 1

                let phase1bDuration = Date().timeIntervalSince(phase1bStart)
                print("💾 FIX #1289 v3: Phase 1b complete in \(String(format: "%.2f", phase1bDuration))s — notes: \(phase1bNotesFound), spends: \(phase1bSpendsDetected), witnesses: \(phase1bWitnessCount)")
                print("   Phase 2 starts from height \(currentHeight) (delta tip + 1)")

            } else if let deltaEndHeight = preservedDeltaEndHeight,
                      deltaEndHeight > phase1EndHeight {
                // Delta preserved but nullifiers absent or insufficient (FIX #1299) — Phase 2 handles via P2P
                // This is the SAFE path: Phase 2 scans blocks and detects spends reliably
                print("📦 FIX #1299: Delta preserved (\(deltaEndHeight - phase1EndHeight) blocks) but nullifiers insufficient — Phase 2 will process via P2P (safe)")
            }
        }

        // PHASE 2: Continue scanning blocks after bundled tree (tree building mode)
        // This runs if:
        // - We did PHASE 1 and there are more blocks after phase1EndHeight
        // - OR no custom start height was provided (normal auto-scan)
        // - OR custom start height is AFTER CMU data height (must use sequential for correct positions)

        // FIX #362: Recalculate continueAfterBundledRange with CURRENT height (after PHASE 1 updated it)
        // Previously this was calculated once at the start and didn't reflect PHASE 1's height update
        let continueAfterBundledRange = currentHeight <= targetHeight && currentHeight > phase1EndHeight

        // FIX #362: Log all conditions for debugging
        if verbose {
            print("🔍 FIX #362: PHASE 2 check - currentHeight=\(currentHeight), targetHeight=\(targetHeight), phase1EndHeight=\(phase1EndHeight)")
            print("🔍 FIX #362: continueAfterBundledRange=\(continueAfterBundledRange), scanWithinDownloadedRange=\(scanWithinDownloadedRange)")
        }

        // Quick scan is ONLY safe when scanning WITHIN CMU data range where positions are known
        // If starting AFTER CMU data, we MUST use sequential mode for correct nullifier computation
        let isQuickScanOnly = customStartHeight != nil && !scanWithinDownloadedRange && customStartHeight! <= phase1EndHeight

        // If custom start is AFTER CMU data height, force sequential mode
        let forceSequentialAfterBundled = customStartHeight != nil && customStartHeight! > phase1EndHeight

        if verbose {
            print("🔍 FIX #362: isQuickScanOnly=\(isQuickScanOnly), forceSequentialAfterBundled=\(forceSequentialAfterBundled)")
        }

        if continueAfterBundledRange || forceSequentialAfterBundled {
            print("⚡ PHASE 2: \(currentHeight) → \(targetHeight) (\(targetHeight - currentHeight + 1) blocks)")
        } else if currentHeight <= targetHeight {
            // FIX #362: Force PHASE 2 if there are still blocks to scan
            print("⚡ FIX #362: Forcing PHASE 2 - still \(targetHeight - currentHeight + 1) blocks remaining")
        }

        if isQuickScanOnly {
            // PARALLEL MODE with RAYON - 6.7x faster note decryption!
            // Fetches blocks in parallel, then batch decrypts all outputs using Rayon
            let parallelBatchSize = 500 // Larger batches to maximize Rayon efficiency

            while currentHeight <= targetHeight && isScanning {
                let endHeight = min(currentHeight + UInt64(parallelBatchSize) - 1, targetHeight)
                let heights = Array(currentHeight...endHeight)


                // Fetch all blocks in parallel using P2P-first approach
                var blockDataMap: [UInt64: [(String, [ShieldedOutput], [ShieldedSpend]?)]] = [:]

                await withTaskGroup(of: (UInt64, [(String, [ShieldedOutput], [ShieldedSpend]?)]?).self) { group in
                    for height in heights {
                        group.addTask {
                            do {
                                let txData = try await self.fetchBlockData(height: height)
                                return (height, txData.isEmpty ? nil : txData)
                            } catch {
                                return (height, nil)
                            }
                        }
                    }

                    for await (height, txData) in group {
                        if let data = txData {
                            blockDataMap[height] = data
                        }
                    }
                }

                // PARALLEL BATCH PROCESSING (6.7x speedup via Rayon)
                var quickScanSpends: [(UInt64, String, String)] = []
                do {
                    try processBlocksBatchParallel(
                        blockDataMap: blockDataMap,
                        heightRange: currentHeight...endHeight,
                        accountId: accountId,
                        spendingKey: spendingKey,
                        collectedSpends: &quickScanSpends,
                        cmuDataForPositionLookup: nil  // Quick scan doesn't use position lookup
                    )
                } catch {
                    print("❌ Error in parallel batch processing: \(error)")
                }

                // Update progress
                let blocksInBatch = UInt64(endHeight - currentHeight + 1)
                scannedBlocks += blocksInBatch
                let progress = Double(scannedBlocks) / Double(totalBlocks)
                onProgress?(progress, endHeight, targetHeight)

                // Save progress
                try? database.updateLastScannedHeight(endHeight, hash: Data(count: 32))
                FilterScanner.updateScanProgress()  // FIX #1074: Update progress time to prevent timeout
                currentHeight = endHeight + 1
            }
        } else if currentHeight <= targetHeight {
            // FIX #362: Simplified condition - always run PHASE 2 if blocks remain
            // Previous condition was complex and could miss cases
            // FIX #190: PARALLEL PRE-FETCH ALL BLOCKS for 5-6x speed improvement
            // Old approach: Fetch 500 blocks → process → repeat (13s fetch + 0.5s process per batch)
            // New approach: Fetch ALL blocks in parallel across all peers, then process sequentially
            //
            // With 6 peers and 6678 blocks:
            // - Old: 14 batches × 13s = 182 seconds
            // - New: 6678/6 = 1113 blocks/peer in parallel = ~20-30 seconds total

            // FIX #406: Ensure headers are synced BEFORE attempting block fetch
            // P2P block fetch requires block hashes from HeaderStore. If HeaderStore is behind,
            // blocks can't be fetched and notes will be MISSED!
            var headerSyncAttempts = 0
            let maxHeaderSyncAttempts = 3
            var headersAvailable = false

            // FIX #440: CRITICAL - When HeaderStore is empty (Full Rescan), don't sync from height 1!
            // Height 1 has PRE-Bubbles Equihash (1344 bytes), we expect POST-Bubbles (400 bytes)
            // Instead, use BundledBlockHashes end height as the starting point
            let bundledHashes = BundledBlockHashes.shared
            let bundledEndHeight = bundledHashes.isLoaded ? bundledHashes.endHeight : UInt64(0)

            // FIX #413: Load bundled headers from boost file FIRST (instant vs P2P timeout!)
            // The boost file contains 2.4M+ pre-verified headers - loading them is instant
            // This avoids P2P sync timeout issues with block listeners consuming responses
            // FIX #1341: Skip on first import (headers not loaded yet = 207s block).
            // PHASE 2 only needs P2P headers for delta range (2988798+), not boost headers.
            let headerStoreHeight1341 = (try? HeaderStore.shared.getLatestHeight()) ?? 0
            if headerStoreHeight1341 > 2_900_000 {
                // Headers already loaded (subsequent launch) — fast check
                print("📜 FIX #413: Loading bundled headers from boost file before PHASE 2...")
                let (loadedBundledHeaders, boostHeaderEndHeight) = await WalletManager.shared.loadHeadersFromBoostFile()
                if loadedBundledHeaders {
                    print("✅ FIX #413: Loaded bundled headers up to \(boostHeaderEndHeight) - instant header load!")
                } else {
                    print("⚠️ FIX #413: Could not load bundled headers, will use P2P sync")
                }
            } else {
                print("⏭️ FIX #1341: Skipping boost header loading in PHASE 2 (deferred to background)")
            }

            // FIX #525: NEVER skip header sync during PHASE 2!
            // Headers MUST be synced to targetHeight for tree root validation
            // Even if WalletManager loaded bundled headers during import (FIX #522),
            // we still need to sync the delta (boost height → target height)
            //
            // Previous FIX #523 blocked this sync, causing:
            // - Tree built with CMUs from blocks beyond boost file
            // - But HeaderStore had no headers for those blocks
            // - Tree root validation failed (no header at target height)
            // - Result: "Anchor NOT FOUND" errors when sending
            print("⚡ FIX #525: Ensuring headers synced to target height \(targetHeight) for tree root validation")

            // FIX #1418: Header sync now routes through the dispatcher (sendAndWaitViaDispatcher).
            // Block listeners stay running — they receive "headers" responses and dispatch them.
            // No more stop/verify/reconnect cycle that killed NWConnections and dropped peer counts.
            // Old FIX #462/#903/#1228/#1416 stop logic REMOVED — dispatcher handles everything.

            // Quick check: skip sync entirely if headers already available
            let preCheckHeight = (try? HeaderStore.shared.getLatestHeight()) ?? 0
            if preCheckHeight >= targetHeight {
                print("✅ FIX #1418: Headers already at \(preCheckHeight) >= target \(targetHeight) — no sync needed")
                headersAvailable = true
            }

            while headerSyncAttempts < maxHeaderSyncAttempts && !headersAvailable {
                let headerStoreHeight = (try? HeaderStore.shared.getLatestHeight()) ?? 0

                if headerStoreHeight >= targetHeight {
                    headersAvailable = true
                    if verbose {
                        print("✅ FIX #406: Headers available up to \(headerStoreHeight) (target: \(targetHeight))")
                    }
                    break
                }

                // FIX #440: Determine the effective starting height for header sync
                // If HeaderStore is empty/below bundled range AND BundledBlockHashes is loaded,
                // start from bundledEndHeight + 1 (post-Bubbles heights only!)
                let effectiveHeaderHeight: UInt64
                if headerStoreHeight <= bundledEndHeight && bundledEndHeight > 0 {
                    effectiveHeaderHeight = bundledEndHeight
                    if verbose {
                        print("📋 FIX #440: HeaderStore (\(headerStoreHeight)) <= bundled end (\(bundledEndHeight))")
                        print("📋 FIX #440: Will sync headers from bundled end + 1 = \(bundledEndHeight + 1)")
                    }
                } else {
                    effectiveHeaderHeight = headerStoreHeight
                }

                headerSyncAttempts += 1
                let headersBehind = targetHeight - effectiveHeaderHeight
                // FIX #769: Use "headers behind" wording to avoid false sync lag alerts
                print("⚠️ FIX #406: HeaderStore (\(headerStoreHeight)) is \(headersBehind) headers behind target (\(targetHeight))")
                print("🔄 FIX #406: Syncing headers (attempt \(headerSyncAttempts)/\(maxHeaderSyncAttempts))...")
                onStatusUpdate?("headers", "Syncing headers (attempt \(headerSyncAttempts))...")

                // Sync headers with timeout
                let headerSyncManager = HeaderSyncManager(
                    headerStore: HeaderStore.shared,
                    networkManager: networkManager
                )

                // FIX #464: Report header sync progress
                headerSyncManager.onProgress = { [weak self] progress in
                    Task { @MainActor in
                        self?.onProgress?(Double(progress.currentHeight) / Double(max(progress.totalHeight, 1)), progress.currentHeight, progress.totalHeight)
                    }
                }

                do {
                    // FIX #411: REMOVED limit - sync ALL missing headers
                    // Headers MUST be 100% synced before processing blocks
                    // Dynamic timeout: 1 second per 100 headers, minimum 60s, maximum 600s
                    let dynamicTimeout = Double(max(60, min(600, Int(headersBehind / 100) + 60)))
                    try await withTimeout(seconds: dynamicTimeout) {
                        // FIX #440: Use effectiveHeaderHeight + 1 as start, NOT headerStoreHeight + 1
                        try await headerSyncManager.syncHeaders(from: effectiveHeaderHeight + 1, maxHeaders: headersBehind)
                    }
                    let newHeaderHeight = (try? HeaderStore.shared.getLatestHeight()) ?? 0
                    if verbose {
                        print("✅ FIX #406: Header sync complete, now at height \(newHeaderHeight)")
                    }

                    if newHeaderHeight >= targetHeight {
                        headersAvailable = true
                    } else if newHeaderHeight == headerStoreHeight {
                        // No progress - likely stuck, try again
                        print("⚠️ FIX #406: No header progress, will retry...")
                    }
                } catch {
                    print("⚠️ FIX #406: Header sync failed (attempt \(headerSyncAttempts)): \(error.localizedDescription)")
                }
            }

            // FIX #406: If headers still missing after all attempts, mark scan as incomplete
            // FIX #1155: Reduced log severity for small gaps (1-2 blocks) - this is expected during chain tip advancement
            if !headersAvailable {
                let finalHeaderHeight = (try? HeaderStore.shared.getLatestHeight()) ?? 0
                let blocksGap = targetHeight - finalHeaderHeight
                if blocksGap <= 2 {
                    // Small gap is expected when peers haven't propagated latest block yet
                    print("⏳ FIX #406: Headers \(finalHeaderHeight + 1)-\(targetHeight) not yet available from peers (gap=\(blocksGap))")
                    print("⏳ FIX #406: On-demand P2P fetch will be attempted as fallback...")
                } else {
                    // Larger gap is more concerning
                    print("🚨 FIX #406: CRITICAL - Headers missing after \(maxHeaderSyncAttempts) attempts!")
                    print("🚨 FIX #406: HeaderStore at \(finalHeaderHeight), need \(targetHeight)")
                    print("🚨 FIX #406: Blocks \(finalHeaderHeight + 1) to \(targetHeight) may have MISSING NOTES!")
                    print("🚨 FIX #406: On-demand P2P fetch will be attempted as fallback...")
                }
                // Continue with on-demand fallback - it may work
            }

            // FIX #1418: No listener restart needed — listeners were never stopped.
            // Dispatcher-based header sync keeps connections alive throughout.

            // FIX #362: Explicit entry log to confirm PHASE 2 is running
            print("✅ FIX #362: Entering PHASE 2 sequential mode (currentHeight=\(currentHeight), targetHeight=\(targetHeight))")
            print("🔧 PHASE 2: Building commitment tree (sequential mode)...")
            onStatusUpdate?("phase2", "Building commitment tree...")
            reportPhase2Progress(0.0, height: currentHeight, maxHeight: targetHeight)

            // FIX #1007: Track tree size at PHASE 2 start to detect CMUs already appended by Step 2a
            // Step 2a (FIX #571 in WalletManager) may have already appended CMUs via P2P for witness update
            // If PHASE 2 appends them again, tree becomes corrupted with duplicate CMUs
            treeSizeAtPhase2Start = Int(ZipherXFFI.treeSize())
            cmusAppendedInPhase2 = 0
            print("🌳 FIX #1007: PHASE 2 starting with tree size \(treeSizeAtPhase2Start)")

            // FIX #1312: Check if delta sync already brought tree to target height
            // If so, we should NOT modify the tree - just scan for notes
            // This prevents corruption when FIX #370 deep verification runs after delta sync
            //
            // FIX #1312: OLD code used block HEIGHTS (~3M) instead of CMU COUNTS (~1M):
            //   expectedTreeSize = bundledTreeHeight + 1 + (endHeight - boostHeight) = 3,009,425
            //   treeSizeAtPhase2Start = 1,047,039
            //   Guard: 1,047,039 >= 3,009,425 → FALSE → NEVER fired!
            // Result: PHASE 2 appended 15 CMUs already in tree → root mismatch → repair loop
            // FIX: Use actual CMU counts from boost file (cmuDataCount) and delta manifest (outputCount)
            skipTreeModification = false
            if let manifest = DeltaCMUManager.shared.getManifest() {
                let boostCMUs = Int(cmuDataCount)  // Actual boost CMU count (e.g. 1045687)
                let deltaCMUs = Int(manifest.outputCount)  // Actual delta CMU count (e.g. 1352)
                let expectedTreeSize = boostCMUs + deltaCMUs  // Correct: 1047039
                if manifest.endHeight >= targetHeight && treeSizeAtPhase2Start >= expectedTreeSize {
                    skipTreeModification = true
                    print("⚡ FIX #1312: Delta already covers target \(targetHeight) - SKIPPING tree modification in PHASE 2")
                    print("   Delta end: \(manifest.endHeight), Tree: \(treeSizeAtPhase2Start), Expected: \(expectedTreeSize) (boost=\(boostCMUs) + delta=\(deltaCMUs))")
                }
            }

            // DELTA BUNDLE: Enable collection for outputs AFTER the bundled/downloaded range
            // These outputs will be saved locally for instant witness generation
            let deltaBundledEndHeight = cmuDataHeight > 0 ? cmuDataHeight : ZipherXConstants.bundledTreeHeight
            if currentHeight > deltaBundledEndHeight {
                // FIX #874: Clear array for tracking outputs found when delta is "disabled"
                deltaOutputsFoundInCoveredRange.removeAll()

                // SMART START: Continue from existing delta if valid, otherwise from boost end
                if let manifest = DeltaCMUManager.shared.getManifest(), manifest.endHeight >= deltaBundledEndHeight {
                    // FIX #795: Check if delta already covers our target - if so, skip collection
                    // This prevents backwards ranges when delta was pre-synced at startup
                    // Scenario: Delta synced to 2991352, PHASE 2 scans 2991302→2991352
                    // Old bug: deltaCollectionStartHeight=2991353 > lastScanned=2991352 → backwards!
                    if manifest.endHeight >= targetHeight {
                        // Delta already covers everything we're about to scan - no need to collect
                        deltaCollectionEnabled = false
                        print("📦 FIX #795: Delta already covers target \(targetHeight) (manifest.endHeight=\(manifest.endHeight)) - skipping collection")
                    } else {
                        // Delta exists and is valid but doesn't cover target - continue from where it left off
                        deltaCollectionEnabled = true
                        deltaCollectionStartHeight = manifest.endHeight + 1
                        print("📦 DeltaCMU: Continuing from existing delta (height \(manifest.endHeight) → \(currentHeight))")
                    }
                } else {
                    // No delta or invalid - start fresh from boost end
                    deltaCollectionEnabled = true
                    deltaCollectionStartHeight = deltaBundledEndHeight + 1
                    print("📦 DeltaCMU: Starting fresh from boost end (height \(deltaBundledEndHeight + 1))")
                }

                if deltaCollectionEnabled {
                    deltaOutputsCollected.removeAll()

                    // Update delta sync status to syncing
                    await MainActor.run {
                        WalletManager.shared.updateDeltaSyncStatus(.syncing)
                    }
                }
            }

            // FIX #190 v6: PARALLEL BATCH FETCHING FOR 3-4x SPEEDUP
            // - Uses 500 blocks per batch
            // - Fetches 4 batches IN PARALLEL using TaskGroup
            // - Progress during FETCH phase: "📥 Fetching blocks X/Y"
            // - Progress during PROCESSING phase: "🔧 Processing blocks X/Y"

            // FIX #216: Sanity check - reject impossible block counts (Sybil attack protection)
            // If targetHeight somehow got corrupted to ~669M by a malicious peer,
            // the subtraction would produce hundreds of millions of blocks
            guard targetHeight >= currentHeight else {
                print("🚨 FIX #216: Invalid scan range: target \(targetHeight) < current \(currentHeight)")
                return  // Exit the scan - we're already synced
            }

            let rawBlockCount = targetHeight - currentHeight + 1
            let maxReasonableBlocks: UInt64 = 100_000  // Max 100K blocks in one scan
            guard rawBlockCount <= maxReasonableBlocks else {
                print("🚨 FIX #216: REJECTED impossible block count \(rawBlockCount) (max: \(maxReasonableBlocks))")
                print("🚨 FIX #216: targetHeight=\(targetHeight), currentHeight=\(currentHeight)")
                print("🚨 FIX #216: This is likely a corrupt chain height from a malicious peer")
                return  // Exit the scan - corrupt height detected
            }

            let totalBlocksToFetch = Int(rawBlockCount)
            // FIX #1095: Dynamic batch size based on peer capacity
            // With 6 peers × 128 blocks/peer = 768 blocks per round
            let p2pPeerCount = await MainActor.run { NetworkManager.shared.peers.filter { $0.isConnectionReady }.count }
            let maxBlocksPerPeer = 128
            // FIX #1287: Dynamic batch = 2 chunks per peer (scales with connected peers)
            let prefetchBatchSize = max(p2pPeerCount, 3) * 256
            // FIX #1095: With all peers used per batch, parallel batches cause conflicts
            // One batch uses ALL peers already - no benefit from parallel batches
            let parallelBatches = 1

            print("🚀 FIX #1095: Pre-fetching \(totalBlocksToFetch) blocks using \(p2pPeerCount) peers (batch=\(prefetchBatchSize))...")
            onStatusUpdate?("prefetch", "📥 Fetching 0/\(totalBlocksToFetch) blocks...")
            let prefetchStartTime = Date()

            // FIX #897: Fetch blocks with retry logic - don't skip failed blocks!
            // Previous bug: Failed batches advanced prefetchHeight, losing transactions
            var prefetchedBlocks: [UInt64: [(String, [ShieldedOutput], [ShieldedSpend]?)]] = [:]
            var prefetchHeight = currentHeight
            let maxRetries = 3
            var consecutiveEmptyFetches = 0
            let maxConsecutiveEmpty = 5  // Give up after 5 rounds with 0 blocks fetched

            // FIX #1214: Pre-populate from shared cache (set by FIX #571 P2P fetch in preRebuildWitnesses)
            // This avoids double-fetching the same blocks that FIX #571 already downloaded
            if let cache = FilterScanner.sharedPrefetchCache {
                var cacheHits = 0
                for (height, txData) in cache {
                    if height >= currentHeight && height <= targetHeight {
                        prefetchedBlocks[height] = txData
                        cacheHits += 1
                    }
                }
                FilterScanner.sharedPrefetchCache = nil  // Free memory
                if cacheHits > 0 {
                    print("⚡ FIX #1214: Pre-loaded \(cacheHits)/\(totalBlocksToFetch) blocks from shared cache (avoiding double-fetch)")
                    // Advance prefetchHeight past the contiguous cached range from currentHeight
                    var contiguousEnd = currentHeight
                    while contiguousEnd <= targetHeight && prefetchedBlocks[contiguousEnd] != nil {
                        contiguousEnd += 1
                    }
                    if contiguousEnd > currentHeight {
                        prefetchHeight = contiguousEnd
                        print("⚡ FIX #1214: Skipping P2P fetch for heights \(currentHeight)-\(contiguousEnd - 1) (cached), starting at \(prefetchHeight)")
                    }
                }
            }

            // FIX #1104: Pre-reconnect ALL peers ONCE before the prefetch loop
            // CRITICAL: This was previously INSIDE the while loop (line 1381), causing a reconnection
            // storm that killed in-flight P2P requests (error 89: Operation canceled).
            // Moving it outside ensures we reconnect once, then use stable connections for all batches.
            // FIX #1214: Skip reconnect if all blocks already cached (no P2P needed)
            if prefetchHeight <= targetHeight {
                await networkManager.preReconnectPeersForBlockFetch()
            }

            while prefetchHeight <= targetHeight && isScanning {
                // Create up to `parallelBatches` concurrent fetch tasks
                var batchTasks: [(start: UInt64, end: UInt64, heights: [UInt64])] = []
                var taskStart = prefetchHeight

                for _ in 0..<parallelBatches {
                    guard taskStart <= targetHeight else { break }
                    let taskEnd = min(taskStart + UInt64(prefetchBatchSize) - 1, targetHeight)
                    let heights = Array(taskStart...taskEnd).map { UInt64($0) }
                    batchTasks.append((start: taskStart, end: taskEnd, heights: heights))
                    taskStart = taskEnd + 1
                }

                guard !batchTasks.isEmpty else { break }

                // Report fetch progress (0-50% of PHASE 2)
                let fetchProgress = Double(prefetchedBlocks.count) / Double(totalBlocksToFetch)
                let fetchPercent = Int(fetchProgress * 100)
                let batchCount = batchTasks.count
                if verbose {
                    print("📥 FIX #897: Fetching \(prefetchedBlocks.count)/\(totalBlocksToFetch) (\(fetchPercent)%) - \(batchCount) parallel batches from height \(prefetchHeight)...")
                }
                onStatusUpdate?("prefetch", "📥 Fetching \(prefetchedBlocks.count)/\(totalBlocksToFetch) blocks...")
                reportPhase2Progress(fetchProgress * 0.5, height: prefetchHeight, maxHeight: targetHeight)
                FilterScanner.updateScanProgress()  // FIX #1074: Update progress time during block prefetch

                // FIX #1104: Pre-reconnect moved OUTSIDE while loop (see line ~1354)
                // Previous bug: Reconnecting every iteration (1-2 seconds) caused reconnection storm
                // that killed in-flight requests with error 89 (Operation canceled)
                // Now: Single reconnect before loop, stable connections throughout prefetch

                // Fetch all batches IN PARALLEL using TaskGroup
                // FIX #1071/1104: All peers are now ready - no per-batch reconnection needed
                var batchBlocksFetched = 0
                let batchResults = await withTaskGroup(of: [(UInt64, [(String, [ShieldedOutput], [ShieldedSpend]?)])]?.self) { group in
                    for task in batchTasks {
                        group.addTask {
                            do {
                                return try await withTimeout(seconds: 60) {
                                    // FIX #1071: skipPreReconnect=true - already done above
                                    try await self.fetchBlocksData(heights: task.heights, skipPreReconnect: true)
                                }
                            } catch {
                                if self.verbose {
                                    print("⚠️ FIX #897: Batch \(task.start)-\(task.end) failed: \(error)")
                                }
                                return nil
                            }
                        }
                    }

                    var allResults: [[(UInt64, [(String, [ShieldedOutput], [ShieldedSpend]?)])]] = []
                    for await result in group {
                        if let data = result {
                            allResults.append(data)
                        }
                    }
                    return allResults
                }

                // Merge results into cache
                for batchData in batchResults {
                    for (height, txData) in batchData {
                        prefetchedBlocks[height] = txData
                        batchBlocksFetched += 1
                    }
                }

                // FIX #897: Check for missing blocks in this batch range and retry
                let batchEndHeight = batchTasks.last!.end
                var missingHeights: [UInt64] = []
                for h in prefetchHeight...batchEndHeight {
                    if prefetchedBlocks[h] == nil {
                        missingHeights.append(h)
                    }
                }

                if !missingHeights.isEmpty {
                    if verbose {
                        print("⚠️ FIX #897: \(missingHeights.count) blocks missing from batch, retrying...")
                    }

                    // Retry missing blocks in smaller sequential batches
                    for retryAttempt in 1...maxRetries {
                        guard isScanning else { break }

                        // Only retry blocks that are still missing
                        let stillMissing = missingHeights.filter { prefetchedBlocks[$0] == nil }
                        if stillMissing.isEmpty { break }

                        if verbose {
                            print("🔄 FIX #897: Retry \(retryAttempt)/\(maxRetries) for \(stillMissing.count) blocks...")
                        }

                        // FIX #1287: Retry in 384-block chunks (3 peers × 128) for multi-peer parallelism.
                        // Previous 50-block chunks used only 1 peer → 250 blocks/sec instead of 1000+.
                        let retryChunkSize = 384
                        for chunkStart in stride(from: 0, to: stillMissing.count, by: retryChunkSize) {
                            guard isScanning else { break }
                            let chunkEnd = min(chunkStart + retryChunkSize, stillMissing.count)
                            let chunkHeights = Array(stillMissing[chunkStart..<chunkEnd])

                            do {
                                let retryResults = try await withTimeout(seconds: 30) {
                                    try await self.fetchBlocksData(heights: chunkHeights)
                                }
                                for (height, txData) in retryResults {
                                    prefetchedBlocks[height] = txData
                                    batchBlocksFetched += 1
                                }
                            } catch {
                                if verbose {
                                    print("⚠️ FIX #897: Retry chunk \(chunkHeights.first ?? 0)-\(chunkHeights.last ?? 0) failed: \(error)")
                                }
                            }
                        }

                        // FIX #1080: Reduced pause from 1s to 0.3s for faster retries
                        if retryAttempt < maxRetries {
                            try? await Task.sleep(nanoseconds: 300_000_000)  // 0.3 second
                        }
                    }

                    // Log final status for this batch
                    let finalMissing = missingHeights.filter { prefetchedBlocks[$0] == nil }
                    if !finalMissing.isEmpty {
                        if verbose {
                            print("❌ FIX #897: \(finalMissing.count) blocks still missing after \(maxRetries) retries (heights: \(finalMissing.prefix(5).map { String($0) }.joined(separator: ", "))...)")
                        }
                    } else {
                        if verbose {
                            print("✅ FIX #897: All missing blocks recovered after retry")
                        }
                    }
                }

                // FIX #897: Track consecutive empty fetches to detect persistent network issues
                if batchBlocksFetched == 0 {
                    consecutiveEmptyFetches += 1
                    if verbose {
                        print("⚠️ FIX #897: Empty fetch round \(consecutiveEmptyFetches)/\(maxConsecutiveEmpty)")
                    }
                    if consecutiveEmptyFetches >= maxConsecutiveEmpty {
                        print("❌ FIX #897: \(maxConsecutiveEmpty) consecutive empty fetches - network may be down, aborting prefetch")
                        break
                    }
                    // FIX #1080: Reduced wait from 2s to 0.5s for faster recovery
                    try? await Task.sleep(nanoseconds: 500_000_000)  // 0.5 seconds
                } else {
                    consecutiveEmptyFetches = 0  // Reset on successful fetch
                }

                // Move to next set of parallel batches
                prefetchHeight = batchEndHeight + 1

                if verbose {
                    print("✅ FIX #897: Batch complete - \(prefetchedBlocks.count)/\(totalBlocksToFetch) blocks cached")
                }
            }

            let prefetchDuration = Date().timeIntervalSince(prefetchStartTime)
            let fetchRate = Double(prefetchedBlocks.count) / max(prefetchDuration, 0.001)

            // FIX #789: Count total shielded outputs fetched for debugging delta collection
            var totalOutputsFetched = 0
            var blocksWithOutputs = 0
            for (_, txList) in prefetchedBlocks {
                for (_, outputs, _) in txList {
                    totalOutputsFetched += outputs.count
                    if !outputs.isEmpty {
                        blocksWithOutputs += 1
                    }
                }
            }
            if verbose {
                print("✅ FIX #897: Pre-fetched \(prefetchedBlocks.count)/\(totalBlocksToFetch) blocks in \(String(format: "%.1f", prefetchDuration))s (\(String(format: "%.0f", fetchRate)) blocks/sec)")
                print("📊 FIX #789: Fetched \(totalOutputsFetched) shielded outputs across \(blocksWithOutputs) blocks")
            }

            // FIX #910: CRITICAL - Detect network failure and throw error to trigger retry
            // If we fetched less than 50% of needed blocks and network failed (consecutive empty),
            // throw error instead of continuing with incomplete data
            let fetchedPercentage = Double(prefetchedBlocks.count) / Double(totalBlocksToFetch)

            // FIX #932: CRITICAL - Lower threshold and remove consecutiveEmptyFetches dependency
            // Problem: FIX #910 only triggered when BOTH <50% fetched AND consecutive empty rounds
            // But partial fetches reset consecutiveEmptyFetches → never triggers even with 73% missing!
            // Log showed: "Processing 46 blocks" but "1/173" needed → 127 missing → tree mismatch
            // Solution: Trigger on EITHER condition to prevent incomplete tree building
            // - <80% fetched: Too many missing blocks, CMUs will be incomplete
            // - consecutiveEmptyFetches: Network completely down
            let hasTooManyMissing = fetchedPercentage < 0.8
            let hasNetworkDown = consecutiveEmptyFetches >= maxConsecutiveEmpty

            if hasTooManyMissing || hasNetworkDown {
                let reason = hasTooManyMissing ? "too many missing blocks (\(Int((1 - fetchedPercentage) * 100))%)" : "network down"
                print("🚨 FIX #932: ABORT - Only fetched \(Int(fetchedPercentage * 100))% of blocks (\(reason))")
                print("🚨 FIX #932: Throwing error to trigger automatic retry when network recovers")

                // FIX #1203: Only save partial progress if we actually fetched blocks
                // Bug: When prefetchedBlocks is empty, ?? currentHeight fell through to target height,
                // advancing lastScannedHeight past blocks that were NEVER scanned.
                if let partialHeight = prefetchedBlocks.keys.max() {
                    try? database.updateLastScannedHeight(partialHeight, hash: Data(count: 32))
                    FilterScanner.updateScanProgress()
                    if let treeData = ZipherXFFI.treeSerialize() {
                        try? database.saveTreeState(treeData, height: partialHeight)
                    }
                    print("📍 FIX #1203: Saved partial progress at height \(partialHeight)")
                } else {
                    print("⚠️ FIX #1203: Zero blocks fetched — NOT advancing lastScannedHeight (staying at \(currentHeight - 1))")
                }

                // Mark scan as not in progress so it can be retried
                isScanning = false
                Self.setScanInProgress(false)

                throw NetworkError.scanAbortedDueToNetworkFailure(
                    fetched: prefetchedBlocks.count,
                    needed: totalBlocksToFetch,
                    lastHeight: prefetchedBlocks.keys.max() ?? (currentHeight > 0 ? currentHeight - 1 : 0)
                )
            }

            // PROCESSING PHASE: Build commitment tree from pre-fetched blocks
            print("🔧 FIX #190: Processing \(prefetchedBlocks.count) blocks for commitment tree...")
            onStatusUpdate?("phase2", "🔧 Processing 0/\(totalBlocksToFetch) blocks...")
            let processStartTime = Date()
            var processedCount = 0
            var lastActuallyScannedHeight: UInt64 = currentHeight > 0 ? currentHeight - 1 : 0  // FIX #1203

            // Process blocks sequentially from pre-fetched cache
            while currentHeight <= targetHeight && isScanning {
                // Get block data from pre-fetched cache
                let blockData: [(UInt64, [(String, [ShieldedOutput], [ShieldedSpend]?)])]
                if let txData = prefetchedBlocks[currentHeight] {
                    blockData = [(currentHeight, txData)]
                    lastActuallyScannedHeight = currentHeight  // FIX #1203: Only advance for fetched blocks
                } else {
                    // FIX #1203: Block not in cache — fetch failed, DO NOT treat as empty.
                    // Missing blocks could contain our transactions (outputs + nullifiers).
                    // Skip processing but do NOT advance lastScannedHeight past this gap.
                    if verbose {
                        print("⚠️ FIX #1203: Block \(currentHeight) missing from cache — skipping (will re-scan)")
                    }
                    currentHeight += 1
                    continue
                }

                // Process sequentially (all data already in memory)
                for (height, txList) in blockData {
                    guard isScanning else { break }

                    // FIX #786: Track per-block output index to avoid duplicate (height, index) keys
                    // Problem: outputIndex from outputs.enumerated() is per-transaction, not per-block
                    // If block has TX A (2 outputs) and TX B (1 output), both TX A[0] and TX B[0] got index=0
                    // Solution: Use blockOutputIndex that increments across ALL transactions in a block
                    var blockOutputIndex: UInt32 = 0

                    for (txid, outputs, spends) in txList {
                        // Process if there are outputs OR spends (for nullifier detection)
                        let hasOutputs = !outputs.isEmpty
                        let hasSpends = spends?.isEmpty == false
                        if hasOutputs || hasSpends {
                            // Process on main actor to avoid SQLite threading issues
                            do {
                                try await MainActor.run {
                                    try self.processShieldedOutputsSync(
                                        outputs: outputs,
                                        spends: spends,
                                        txid: txid,
                                        accountId: accountId,
                                        spendingKey: spendingKey,
                                        ivk: ivk,
                                        height: height,
                                        blockOutputStartIndex: blockOutputIndex  // FIX #786: Pass per-block index
                                    )
                                }
                                // FIX #786: Increment by number of outputs processed
                                blockOutputIndex += UInt32(outputs.count)
                            } catch {
                                if verbose {
                                    print("⚠️ Error processing tx \(txid): \(error)")
                                }
                            }
                        }
                    }

                    scannedBlocks += 1
                    processedCount += 1

                    // FIX #190 v6: Report PROCESSING progress every 500 blocks
                    // Progress is 50-100% of PHASE 2 (fetch was 0-50%)
                    if processedCount % prefetchBatchSize == 0 || processedCount == 1 {
                        let processProgress = Double(processedCount) / Double(totalBlocksToFetch)
                        let processPercent = Int(processProgress * 100)
                        if verbose {
                            print("🔧 FIX #190: Processing blocks \(processedCount)/\(totalBlocksToFetch) (\(processPercent)%)...")
                        }
                        onStatusUpdate?("phase2", "🔧 Processing \(processedCount)/\(totalBlocksToFetch) blocks...")
                        reportPhase2Progress(0.5 + processProgress * 0.5, height: height, maxHeight: targetHeight)
                    }

                    // FIX #293: Save checkpoint every 10 blocks (was 500 - too risky!)
                    // If app crashes/force-quits, at most 10 blocks need re-scan
                    // FIX #1203: Only save lastScannedHeight for blocks that were actually fetched
                    // (lastActuallyScannedHeight tracks the highest contiguous fetched block)
                    if scannedBlocks % 10 == 0 {
                        try? database.updateLastScannedHeight(lastActuallyScannedHeight, hash: Data(count: 32))
                        FilterScanner.updateScanProgress()  // FIX #1074: Update progress time to prevent timeout
                        if let treeData = ZipherXFFI.treeSerialize() {
                            try? database.saveTreeState(treeData, height: lastActuallyScannedHeight)
                        }
                    }
                }

                // Move to next block
                currentHeight += 1
            }

            // FIX #190: Log total processing time
            let processDuration = Date().timeIntervalSince(processStartTime)
            let processRate = Double(scannedBlocks) / max(processDuration, 0.001)
            if verbose {
                print("✅ FIX #190: Processed \(scannedBlocks) blocks in \(String(format: "%.1f", processDuration))s (\(String(format: "%.0f", processRate)) blocks/sec)")
            }

            // FIX #206 + FIX #1203: Save FINAL lastScannedHeight after PHASE 2 completes
            // FIX #1203: Use lastActuallyScannedHeight instead of targetHeight
            // Bug: targetHeight was saved even when blocks were missing from cache,
            // permanently skipping blocks that failed to fetch (including our own TXs).
            let finalHeight = lastActuallyScannedHeight
            try? database.updateLastScannedHeight(finalHeight, hash: Data(count: 32))
            FilterScanner.updateScanProgress()  // FIX #1074: Update progress time to prevent timeout
            if finalHeight < targetHeight {
                print("📍 FIX #1203: Final lastScannedHeight saved: \(finalHeight) (target was \(targetHeight) — \(targetHeight - finalHeight) blocks will be re-scanned)")
            } else {
                print("📍 FIX #206: Final lastScannedHeight saved: \(finalHeight)")
            }
        }

        // Final tree persistence
        // FIX #1138: Save tree state WITH HEIGHT to ensure tree_height is persisted!
        // Bug: saveTreeState called without height → tree_height stays 0 → delta resync on every startup
        if let treeData = ZipherXFFI.treeSerialize() {
            try? database.saveTreeState(treeData, height: targetHeight)
            let treeSize = ZipherXFFI.treeSize()
            print("🌳 FIX #1138: Saved commitment tree with \(treeSize) commitments at height \(targetHeight)")
        }

        // CRITICAL: Update ALL note witnesses to match current tree state!
        //
        // The FFI's treeAppend() automatically updates all loaded witnesses.
        // We must save these updated witnesses back to the database so that:
        // 1. Witness matches the CURRENT tree root (anchor)
        // 2. At spend time, use current tree root as anchor
        // 3. Witness + anchor are always consistent
        //
        // This applies to BOTH:
        // - existingWitnessIndices: notes that existed before this scan
        // - pendingWitnesses: notes discovered during this scan
        //
        // When a note is discovered at block N, the witness is for tree root at N.
        // If more blocks are scanned (N+1, ..., latest), the tree grows and the
        // witness becomes stale. We MUST update it to match the final tree root.

        // FIX #554: NO currentAnchor fallback! Using final tree root for all notes causes mismatches.
        // Each note's anchor must come from its block's header (via HeaderStore).
        // Witness anchors are extracted below. If extraction fails, we get anchor from HeaderStore.

        // Calculate total witnesses to update
        let totalWitnesses = existingWitnessIndices.count + pendingWitnesses.count
        var witnessesUpdated = 0

        // Report witness sync starting
        if totalWitnesses > 0 {
            onWitnessProgress?(0, totalWitnesses, "Syncing \(totalWitnesses) witness(es)...")
        }

        // Update existing notes' witnesses and anchors
        // CRITICAL: Use header store anchor (blockchain's finalSaplingRoot) for each note,
        // NOT the end-of-scan tree root! The header anchor is the canonical blockchain state.
        let headerStore = HeaderStore.shared
        try? headerStore.open()

        for (noteId, witnessIndex) in existingWitnessIndices {
            if let witnessData = ZipherXFFI.treeGetWitness(index: witnessIndex) {
                try? database.updateNoteWitness(noteId: noteId, witness: witnessData)

                // FIX #555: ALWAYS use HeaderStore anchor - witness root is from end of scan, WRONG!
                if let noteHeight = try? database.getNoteHeight(noteId: noteId),
                   let headerAnchor = try? headerStore.getSaplingRoot(at: UInt64(noteHeight)) {
                    try? database.updateNoteAnchor(noteId: noteId, anchor: headerAnchor)
                }
                witnessesUpdated += 1
                onWitnessProgress?(witnessesUpdated, totalWitnesses, "Witness \(witnessesUpdated)/\(totalWitnesses)")
            }
        }

        // Update new notes' witnesses and anchors (discovered during this scan)
        for (noteId, witnessIndex) in pendingWitnesses {
            if let witnessData = ZipherXFFI.treeGetWitness(index: witnessIndex) {
                try? database.updateNoteWitness(noteId: noteId, witness: witnessData)

                // FIX #555: ALWAYS use HeaderStore anchor - witness root is from end of scan, WRONG!
                if let noteHeight = try? database.getNoteHeight(noteId: noteId),
                   let headerAnchor = try? headerStore.getSaplingRoot(at: UInt64(noteHeight)) {
                    try? database.updateNoteAnchor(noteId: noteId, anchor: headerAnchor)
                }
                witnessesUpdated += 1
                onWitnessProgress?(witnessesUpdated, totalWitnesses, "Witness \(witnessesUpdated)/\(totalWitnesses)")
            }
        }

        if totalWitnesses > 0 {
            print("✅ Witnesses updated: \(totalWitnesses)")
            onWitnessProgress?(totalWitnesses, totalWitnesses, "All witnesses synced!")
        } else {
            onWitnessProgress?(0, 0, "No witnesses to update")
        }

        // PHASE 2.5: Notes that couldn't get correct positions during PHASE 1
        if !notesNeedingNullifierFix.isEmpty {
            print("⚠️ \(notesNeedingNullifierFix.count) notes need nullifier fix - use 'Repair Notes' in Settings")
            notesNeedingNullifierFix.removeAll()
        }

        // FIX #736: Save delta CMUs BEFORE FIX #524 repair, so repair can load them!
        // Previously delta save was AFTER FIX #524, causing "No delta CMUs found" error
        // DELTA BUNDLE: Save collected outputs for instant witness generation
        // FIX #558 v4: Debug logging
        // FIX #789: Enhanced logging for delta collection debugging
        if verbose {
            print("📦 FIX #789: Delta save check - enabled=\(deltaCollectionEnabled), collected=\(deltaOutputsCollected.count), startHeight=\(deltaCollectionStartHeight)")
        }
        if deltaOutputsCollected.isEmpty && deltaCollectionEnabled {
            print("⚠️ FIX #789: WARNING - Delta collection was enabled but NO outputs collected!")
            print("⚠️ FIX #789: This could mean P2P fetch failed or blocks had no shielded outputs")
        }
        if deltaCollectionEnabled && !deltaOutputsCollected.isEmpty {
            if let treeRoot = ZipherXFFI.treeRoot() {
                let lastScanned = (try? database.getLastScannedHeight()) ?? targetHeight

                // FIX #759: Validate height range before saving delta bundle
                // If deltaCollectionStartHeight > lastScanned, the range is backwards/invalid
                // This happens when Full Rescan resets lastScanned but delta uses old manifest
                if deltaCollectionStartHeight > lastScanned {
                    print("⚠️ FIX #759: INVALID delta range \(deltaCollectionStartHeight)-\(lastScanned) (backwards)")
                    // FIX #1254: Only clear delta if NOT verified (immutable).
                    if UserDefaults.standard.bool(forKey: "DeltaBundleVerified") {
                        print("✅ FIX #1254: Delta is VERIFIED (immutable) — NOT clearing despite invalid range")
                        print("   Backwards range is from new scan state, not delta corruption")
                    } else {
                        print("⚠️ FIX #759: Clearing corrupted delta bundle and NOT saving invalid data")
                        DeltaCMUManager.shared.clearDeltaBundle()
                    }
                } else {
                    DeltaCMUManager.shared.appendOutputs(
                        deltaOutputsCollected,
                        fromHeight: deltaCollectionStartHeight,  // Track the full scanned range!
                        toHeight: lastScanned,
                        treeRoot: treeRoot
                    )
                    if verbose {
                        print("📦 DeltaCMU: Saved \(deltaOutputsCollected.count) outputs to delta bundle (height \(deltaCollectionStartHeight)-\(lastScanned))")
                    }

                    // FIX #1289 v3: Save collected nullifiers alongside delta outputs
                    // These enable Phase 1b to detect spends locally during Full Rescan
                    if !deltaNullifiersCollected.isEmpty {
                        DeltaCMUManager.shared.appendNullifiers(deltaNullifiersCollected)
                        if verbose {
                            print("📦 FIX #1289 v3: Saved \(deltaNullifiersCollected.count) nullifiers with delta bundle")
                        }
                        deltaNullifiersCollected.removeAll()
                    }

                    // Update delta sync status to synced
                    await MainActor.run {
                        WalletManager.shared.updateDeltaSyncStatus(.synced)
                        // FIX #737 v2: Clear pendingDeltaRescan flag - delta bundle rebuilt successfully
                        if WalletManager.shared.pendingDeltaRescan {
                            WalletManager.shared.pendingDeltaRescan = false
                            print("🔧 FIX #737 v2: Cleared pendingDeltaRescan flag - delta bundle rebuilt")
                        }
                    }
                }
            }
            deltaOutputsCollected.removeAll()
            deltaCollectionEnabled = false
        } else if deltaCollectionEnabled {
            // No outputs collected but delta collection was enabled
            // Still need to update manifest height so system knows we've scanned these blocks
            if let treeRoot = ZipherXFFI.treeRoot() {
                let lastScanned = (try? database.getLastScannedHeight()) ?? targetHeight

                // FIX #759: Validate height range before updating manifest
                if deltaCollectionStartHeight > lastScanned {
                    print("⚠️ FIX #759: INVALID delta range \(deltaCollectionStartHeight)-\(lastScanned) (backwards, no outputs)")
                    // FIX #1254: Only clear delta if NOT verified (immutable).
                    if UserDefaults.standard.bool(forKey: "DeltaBundleVerified") {
                        print("✅ FIX #1254: Delta is VERIFIED (immutable) — NOT clearing despite invalid range")
                    } else {
                        print("⚠️ FIX #759: Clearing corrupted delta bundle")
                        DeltaCMUManager.shared.clearDeltaBundle()
                    }
                } else {
                    DeltaCMUManager.shared.appendOutputs(
                        [],  // Empty outputs
                        fromHeight: deltaCollectionStartHeight,  // Track the full scanned range!
                        toHeight: lastScanned,
                        treeRoot: treeRoot
                    )
                    if verbose {
                        print("📦 DeltaCMU: Updated manifest to height \(deltaCollectionStartHeight)-\(lastScanned) (no new outputs)")
                    }

                    // FIX #1289 v3: Save nullifiers even when no outputs collected
                    // Blocks can have spends (nullifiers) without outputs to our wallet
                    if !deltaNullifiersCollected.isEmpty {
                        DeltaCMUManager.shared.appendNullifiers(deltaNullifiersCollected)
                        if verbose {
                            print("📦 FIX #1289 v3: Saved \(deltaNullifiersCollected.count) nullifiers (no-output path)")
                        }
                        deltaNullifiersCollected.removeAll()
                    }
                }
            }
            await MainActor.run {
                WalletManager.shared.updateDeltaSyncStatus(.synced)
            }
            deltaCollectionEnabled = false
        }

        // FIX #874: If we found outputs in range that delta "already covers", update delta bundle
        // This happens when previous scans missed outputs due to P2P issues
        // Without this fix, tree and delta get out of sync → tree root mismatch at send time
        if !deltaOutputsFoundInCoveredRange.isEmpty {
            print("⚠️ FIX #874: Found \(deltaOutputsFoundInCoveredRange.count) outputs that delta MISSED!")
            print("⚠️ FIX #874: Adding missed outputs to delta bundle to keep tree/delta in sync...")

            if let treeRoot = ZipherXFFI.treeRoot() {
                let lastScanned = (try? database.getLastScannedHeight()) ?? targetHeight
                DeltaCMUManager.shared.appendOutputs(
                    deltaOutputsFoundInCoveredRange,
                    fromHeight: ZipherXConstants.bundledTreeHeight + 1,
                    toHeight: lastScanned,
                    treeRoot: treeRoot
                )
                print("✅ FIX #874: Updated delta bundle with \(deltaOutputsFoundInCoveredRange.count) missed outputs")
            }
            deltaOutputsFoundInCoveredRange.removeAll()
        }

        // Save tree checkpoint after scan completes
        let checkpointSaved = await saveTreeCheckpointAfterSync()

        // FIX #524: If checkpoint wasn't saved due to tree root mismatch, fix the tree!
        // This happens when FFI tree state becomes corrupted during PHASE 2
        // Symptoms: witnesses are 37 bytes (invalid), tree root doesn't match blockchain
        // FIX #736: Delta CMUs are now saved BEFORE this runs, so repair can load them!
        var treeRepairFailed = false  // FIX #1238: Track if tree is corrupted (prevents stale witness creation)
        if !checkpointSaved {
            print("🔧 FIX #524: Tree root mismatch detected - attempting repair...")
            if await fixTreeRootMismatch(lastScannedHeight: targetHeight) {
                print("✅ FIX #524: Tree root mismatch repaired - witnesses updated")
            } else {
                print("⚠️ FIX #524: Could not repair tree root mismatch - may need full rescan")
                // FIX #1238: Check if repair was exhausted — tree state is CORRUPTED
                // When TreeRepairExhausted is true, the FFI tree has wrong root because delta
                // CMUs are incomplete. ANY witnesses created from this tree will have anchors
                // that don't exist on the blockchain → FIX #1224 flags them ALL as corrupted
                // → infinite rebuild cycle. MUST NULL all witnesses and skip all rebuild paths.
                let repairExhausted = UserDefaults.standard.bool(forKey: "TreeRepairExhausted")
                if repairExhausted {
                    treeRepairFailed = true
                    print("🛑 FIX #1238: Tree repair EXHAUSTED — tree state is corrupted!")
                    print("   Nullifying ALL witnesses to prevent creation from corrupted tree")
                    print("   Witnesses from corrupted tree have non-existent anchors → phantom TXs")
                    print("   User must run 'Full Resync' in Settings to fix")
                    // NULL all witnesses — they are ALL invalid (created from corrupted tree)
                    // This prevents any code path from using these bad witnesses for spending
                    do {
                        let cleared = try WalletDatabase.shared.clearWitnessesForCorruptedTree()
                        print("🛑 FIX #1238: Cleared \(cleared) corrupted witnesses via SQL")
                    } catch {
                        print("❌ FIX #1238: Failed to clear witnesses: \(error)")
                    }
                }
            }
        }

        // FIX #176: Update verified checkpoint after successful scan
        // This prevents health check from flagging "blocks skipped" on next startup
        if let lastScanned = try? database.getLastScannedHeight(), lastScanned > 0 {
            try? database.updateVerifiedCheckpointHeight(lastScanned)
            print("📍 FIX #176: Checkpoint updated to \(lastScanned) after scan complete")
        }

        // FIX #1101: PERFORMANCE - Skip redundant FIX #1089 verification after Full Rescan
        // Problem: Full Rescan clears FIX1089_FullVerificationComplete flag, causing FIX #945
        // to trigger a 73K+ block scan from oldest note - even though Full Rescan already
        // verified all spends in PHASE 1 (boost scan) and PHASE 2 (P2P delta scan).
        // Solution: Set the flag after successful Full Rescan, so FIX #1089 uses checkpoint.
        // This saves ~76 seconds (73K blocks × 1ms/block = 73 seconds + overhead).
        if await WalletManager.shared.isRepairingDatabase {
            UserDefaults.standard.set(true, forKey: "FIX1089_FullVerificationComplete")
            // FIX #1300: Save code version after Full Rescan verification
            let verificationCodeVersion = "1302"
            let buildForRescan = "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown").\(verificationCodeVersion)"
            UserDefaults.standard.set(buildForRescan, forKey: "FIX1283_LastVerifiedBuild")
            print("✅ FIX #1101: Set FIX1089_FullVerificationComplete=true after Full Rescan (skips redundant 73K block scan)")
            // FIX #1252: Mark delta as verified after Full Rescan — immutable from now on.
            // Full Rescan builds delta with complete P2P scan (same rigor as boost file).
            // No more validation/repair/gap-fill needed on subsequent startups.
            if checkpointSaved {
                UserDefaults.standard.set(true, forKey: "DeltaBundleVerified")
                print("✅ FIX #1252: Delta marked VERIFIED after Full Rescan (immutable like boost)")
            }
        }

        // FIX #1425: Block listeners were kept running via dispatcher — just ensure unblocked
        print("▶️ FIX #907: Resuming block listeners after scan complete...")
        PeerManager.shared.setBlockListenersBlocked(false)
        await PeerManager.shared.resumeAllBlockListeners()
        print("✅ FIX #907: Block listeners resumed")

        // FIX #1090: CRITICAL - Recompute nullifiers with correct tree positions BEFORE verification
        // ROOT CAUSE: processDecryptedNote used placeholder positions (height * 1000 + outputIndex)
        // instead of real tree positions from witnessIndex. This caused nullifiers to be WRONG
        // and verifyAllUnspentNotesOnChain could never find matches on blockchain.
        var fixedNullifiers = 0
        do {
            fixedNullifiers = try await WalletManager.shared.recomputeNullifiersWithCorrectPositions()
            if fixedNullifiers > 0 {
                print("🔧 FIX #1090: Fixed \(fixedNullifiers) nullifier(s) - verification can now detect spent notes")
            }
        } catch {
            print("⚠️ FIX #1090: Failed to recompute nullifiers: \(error)")
        }

        // FIX #945: CRITICAL - Verify all unspent notes are actually unspent on-chain
        // Problem: P2P block fetch may miss blocks due to network issues (timeouts, disconnections)
        // If a block containing a spend is missed, the nullifier won't be detected
        // Result: Note stays marked as "unspent" when it's actually spent = WRONG BALANCE
        // Solution: After scan completes, verify each unspent note's nullifier isn't on-chain
        // This catches any spends that were missed during the scan
        // FIX #1090: Force full verification if we just fixed nullifiers
        // FIX #1296: Skip during Full Rescan — it already scanned ALL blocks from Sapling activation.
        // The 79K-block re-verification is redundant and blocks UI transition for 5-10 minutes.
        // WalletManager.repairDatabase() does its own FIX #1098 balance verification after scan.
        let isFullRescanActive = await WalletManager.shared.isRepairingDatabase
        // FIX #1340 + FIX #1345: Skip nullifier verification during entire initial sync session.
        // On first import: PHASE 1 found notes via trial decryption, PHASE 2 scanned all post-boost
        // blocks for spends. Nullifiers are guaranteed correct. The redundant 86K-block P2P scan
        // (from oldest note height to chain tip) wastes 10+ minutes on iOS.
        // FIX #1345: Changed from one-shot UserDefaults flag to session-scoped check.
        // Bug: FIX #1340 set FIX1340_FirstScanComplete=true after first PHASE 2 pass, then
        // catch-up PHASE 2 (4 new blocks) saw isFirstImport=false → triggered full 86K scan anyway.
        // Fix: Use backgroundProcessesEnabled (false during entire initial sync, true only after).
        let isInitialSyncSession = await !NetworkManager.shared.backgroundProcessesEnabled
        if isFullRescanActive {
            print("⏭️ FIX #1296: Skipping FIX #945 post-scan verification during Full Rescan (redundant — all blocks already scanned)")
        } else if isInitialSyncSession {
            print("⏭️ FIX #1345: Skipping FIX #945 verification during initial sync — PHASE 2 already verified all blocks")
            // Set FIX #1089 checkpoint so future startups don't trigger the full 86K scan either
            UserDefaults.standard.set(true, forKey: "FIX1089_FullVerificationComplete")
        } else {
            print("🔍 FIX #945: Running post-scan spend verification...")
            do {
                let externalSpends = try await WalletManager.shared.verifyAllUnspentNotesOnChain(forceFullVerification: fixedNullifiers > 0)
                if externalSpends > 0 {
                    print("✅ FIX #945: Detected and fixed \(externalSpends) missed spend(s)")
                    // Refresh balance after fixing missed spends
                    try? await WalletManager.shared.refreshBalance()
                } else {
                    print("✅ FIX #945: All unspent notes verified - no missed spends")
                }
            } catch {
                print("⚠️ FIX #945: Post-scan verification failed: \(error)")
                print("   Balance may be incorrect if spends occurred in missed blocks")
                print("   Use 'Full Resync' in Settings if balance seems wrong")
            }
        }

        // FIX #1082: CRITICAL - Rebuild witnesses for notes that STILL don't have them!
        // During scan, only notes with existing witnesses get updated (existingWitnessIndices).
        // Notes without witnesses (empty witness field) are SKIPPED because they can't be loaded
        // into the FFI tree. This leaves those notes unable to be spent!
        //
        // Now that delta CMUs have been collected during PHASE 2, we can rebuild these witnesses.
        // This is MUCH faster than health check's full P2P delta fetch because:
        // 1. Delta CMUs are already in the DeltaCMUManager (saved above)
        // 2. No duplicate P2P fetching needed
        // 3. Instant witness generation from local data
        //
        // FIX #1238: SKIP witness rebuild when tree repair is exhausted!
        // If treeRepairFailed is true, the FFI tree has a wrong root (incomplete delta).
        // Creating witnesses from this tree produces anchors that don't exist on blockchain.
        // FIX #1224 would flag them ALL as corrupted at next startup → rebuild cycle → same
        // bad witnesses. Better to leave witnesses NULL until user runs Full Resync.
        if treeRepairFailed {
            print("⏩ FIX #1238: Skipping FIX #1082 witness rebuild — tree state is corrupted")
            print("   Creating witnesses from corrupted tree would produce invalid anchors")
            print("   Witnesses left NULL — user must run 'Full Resync' in Settings")
        } else {
        print("🔍 FIX #1082: Checking for notes without witnesses after scan...")
        do {
            let (missingCount, missingValue, minHeight) = try database.getNotesWithoutWitnesses(accountId: 1)

            if missingCount == 0 {
                print("✅ FIX #1082: All notes have valid witnesses")
            } else {
                let valueZCL = Double(missingValue) / 100_000_000.0
                print("⚠️ FIX #1082: \(missingCount) notes still without witnesses (\(missingValue.redactedAmount))")
                print("   📍 Min note height: \(minHeight)")
                print("   🔧 FIX #1082: Triggering post-scan witness rebuild...")

                // Use WalletManager's rebuildWitnessesForStartup which handles boost + delta
                await WalletManager.shared.rebuildWitnessesForStartup()

                // Verify fix worked
                let (stillMissing, _, _) = try database.getNotesWithoutWitnesses(accountId: 1)
                if stillMissing == 0 {
                    print("✅ FIX #1082: Post-scan witness rebuild successful - all notes now have witnesses!")
                    // Refresh balance to reflect spendable notes
                    try? await WalletManager.shared.refreshBalance()
                } else {
                    print("⚠️ FIX #1082: \(stillMissing) notes still missing witnesses (will try on next send)")
                }
            }
        } catch {
            print("⚠️ FIX #1082: Error checking notes without witnesses: \(error)")
        }
        } // end FIX #1238 guard

        // FIX #1084: Verify all unspent notes against on-chain nullifiers
        // This catches spent notes that were missed during normal scan
        // (e.g., spends from other wallet instances with same seed)
        // SKIP if there are pending transactions to avoid race conditions
        // FIX #1092: SKIP during Full Scan (FULL START, Import PK, Full Rescan) - we just scanned ALL blocks, nullifiers already verified
        let hasPendingTx = (try? database.getPendingSentTransactions())?.isEmpty == false
        let pendingTxids = UserDefaults.standard.stringArray(forKey: "ZipherX_PendingOutgoingTxids") ?? []
        let hasPendingOutgoing = !pendingTxids.isEmpty

        if isFullScanInProgress {
            print("⏩ FIX #1092: Skipping FIX #1084 - Full scan just scanned all blocks, nullifiers already verified")
            isFullScanInProgress = false  // Reset flag for next scan
        } else if hasPendingTx || hasPendingOutgoing {
            print("⏸️ FIX #1084: Skipping nullifier verification - pending transaction in progress")
        } else {
            print("🔍 FIX #1084: Verifying unspent notes against blockchain nullifiers...")
            do {
                try await WalletManager.shared.verifyNullifierSpendStatus()
            } catch {
                print("⚠️ FIX #1084: Nullifier verification error: \(error)")
            }
        }

        print("✅ Scan complete")
    }

    /// Save a tree checkpoint after sync completes
    /// This ensures we have a verified tree state for reliable transaction building
    /// - Returns: true if checkpoint was saved, false if validation failed
    private func saveTreeCheckpointAfterSync() async -> Bool {
        do {
            // Get current tree state
            guard let treeSerialized = ZipherXFFI.treeSerialize() else {
                print("⚠️ Cannot save checkpoint - tree not serialized")
                return false
            }

            let treeSize = ZipherXFFI.treeSize()
            guard treeSize > 0 else {
                print("⚠️ Cannot save checkpoint - tree is empty")
                return false
            }

            // Get the tree root
            guard let treeRoot = ZipherXFFI.treeRoot() else {
                print("⚠️ Cannot save checkpoint - no tree root")
                return false
            }

            // Get last scanned height and block hash
            let lastScanned = try database.getLastScannedHeight()
            guard lastScanned > 0 else {
                print("⚠️ Cannot save checkpoint - no scanned height")
                return false
            }

            // Get block hash from HeaderStore
            guard let header = try HeaderStore.shared.getHeader(at: lastScanned) else {
                print("⚠️ Cannot save checkpoint - no header at height \(lastScanned)")
                return false
            }

            // FIX #1204b: Validate tree root against HeaderStore for ALL heights
            // getheaders stores real finalsaplingroot, FIX #1204 adds from full block fetches
            let boostEndHeight = ZipherXConstants.effectiveTreeHeight
            let isPeerSyncedHeight = lastScanned > boostEndHeight

            if isPeerSyncedHeight {
                // FIX #1204b: HeaderStore sapling roots ARE authoritative for post-boost heights.
                // getheaders stores real finalsaplingroot + FIX #1204 saves from full block fetches.
                // If non-zero, validate against it. Only trust FFI blindly if root is zero/missing.
                let headerRoot = header.hashFinalSaplingRoot
                let isZeroRoot = headerRoot.allSatisfy { $0 == 0 } || headerRoot.isEmpty

                if !isZeroRoot {
                    // FIX #1204b: Authoritative root available — validate
                    let headerRootReversed = Data(headerRoot.reversed())
                    if treeRoot == headerRoot || treeRoot == headerRootReversed {
                        print("✅ FIX #1204b: Tree root VERIFIED against HeaderStore at height \(lastScanned)")
                    } else {
                        print("⚠️ FIX #1204b: Tree root MISMATCH at height \(lastScanned) — NOT saving checkpoint")
                        print("   Our root:    \(treeRoot.prefix(8).map { String(format: "%02x", $0) }.joined())...")
                        print("   Header root: \(headerRoot.prefix(8).map { String(format: "%02x", $0) }.joined())...")
                        return false
                    }
                } else {
                    // Zero/missing root — trust our computed tree root
                    print("✅ FIX #798: Height \(lastScanned) > boost file end \(boostEndHeight) — HeaderStore root is zero, trusting FFI root")
                    print("   Our tree root: \(treeRoot.prefix(8).map { String(format: "%02x", $0) }.joined())...")
                }

                // FIX #801: Auto-clear exhaustion flags when tree root validates
                let wasExhausted = UserDefaults.standard.bool(forKey: "TreeRepairExhausted")
                if wasExhausted {
                    UserDefaults.standard.set(false, forKey: "TreeRepairExhausted")
                    UserDefaults.standard.set(0, forKey: "DeltaBundleGlobalRepairAttempts")
                    UserDefaults.standard.set(0, forKey: "StaleWitnessGlobalAttempts")
                    print("✅ FIX #801: Cleared exhaustion flags")
                }
            } else {
                // For heights within boost file range, header sapling roots are reliable - validate normally
                if treeRoot != header.hashFinalSaplingRoot {
                    print("⚠️ Tree root mismatch at height \(lastScanned) - NOT saving checkpoint")
                    print("   Our root:    \(treeRoot.prefix(8).map { String(format: "%02x", $0) }.joined())...")
                    print("   Header root: \(header.hashFinalSaplingRoot.prefix(8).map { String(format: "%02x", $0) }.joined())...")
                    return false
                }
            }

            // Save the verified checkpoint
            try database.saveTreeCheckpoint(
                height: lastScanned,
                treeRoot: treeRoot,
                treeSerialized: treeSerialized,
                cmuCount: UInt64(treeSize),
                blockHash: header.blockHash
            )

            // Prune old checkpoints periodically (keep storage manageable)
            if lastScanned % 100 == 0 {
                try database.pruneOldCheckpoints()
            }

            print("✅ Checkpoint saved at height \(lastScanned) with \(treeSize) CMUs")
            return true

        } catch {
            print("⚠️ Failed to save tree checkpoint: \(error)")
            return false
        }
    }

    /// FIX #524: Repair tree root mismatch by reloading from boost file
    /// This fixes the issue where PHASE 2 corrupts the FFI tree state
    /// - Parameter lastScannedHeight: The height we scanned to
    /// - Returns: true if repair succeeded, false otherwise
    private func fixTreeRootMismatch(lastScannedHeight: UInt64) async -> Bool {
        print("🔧 FIX #524: Starting tree root mismatch repair...")

        // FIX #1204b: HeaderStore sapling roots ARE authoritative for post-boost heights.
        // getheaders stores real finalsaplingroot + FIX #1204 saves from full block fetches.
        // If we have a non-zero root, compare it. If zero/missing, trust FFI (no repair needed).
        let boostEndHeight = ZipherXConstants.effectiveTreeHeight
        if lastScannedHeight > boostEndHeight {
            if let header = try? HeaderStore.shared.getHeader(at: lastScannedHeight) {
                let headerRoot = header.hashFinalSaplingRoot
                let isZeroRoot = headerRoot.allSatisfy { $0 == 0 } || headerRoot.isEmpty
                if !isZeroRoot, let ourRoot = ZipherXFFI.treeRoot() {
                    let headerRootReversed = Data(headerRoot.reversed())
                    if ourRoot == headerRoot || ourRoot == headerRootReversed {
                        print("✅ FIX #1204b: Tree root matches HeaderStore at \(lastScannedHeight) — no repair needed")
                        return true
                    }
                    // Real mismatch — fall through to repair
                    print("⚠️ FIX #1204b: Tree root MISMATCH at \(lastScannedHeight) — repair needed!")
                    print("   Our root:    \(ourRoot.prefix(8).map { String(format: "%02x", $0) }.joined())...")
                    print("   Header root: \(headerRoot.prefix(8).map { String(format: "%02x", $0) }.joined())...")
                } else {
                    // Zero root — trust FFI
                    print("✅ FIX #1204b: HeaderStore root is zero at \(lastScannedHeight) — trusting computed tree root")
                    return true
                }
            } else {
                // No header — trust FFI
                print("✅ FIX #1204b: No header at \(lastScannedHeight) — trusting computed tree root")
                return true
            }
        }

        // CRITICAL FIX #557 v35: Check if tree root already matches header (FIX #557 v32 handles this now!)
        // FIX #524 should NOT run if FIX #557 v32 already synced the tree!
        // Note: This only runs for heights <= boost file (where header comparison IS reliable)
        if let header = try? HeaderStore.shared.getHeader(at: lastScannedHeight),
           let ourRoot = ZipherXFFI.treeRoot() {
            if ourRoot == header.hashFinalSaplingRoot {
                print("✅ FIX #557 v35: Tree root already matches header at \(lastScannedHeight) - FIX #524 not needed!")
                return true
            }
        }

        // Step 1: Get the correct tree root from boost file (should match blockchain)
        let effectiveHeight = ZipherXConstants.effectiveTreeHeight
        let effectiveCMUCount = ZipherXConstants.effectiveTreeCMUCount

        print("🔧 FIX #524: Boost file ends at height \(effectiveHeight) with \(effectiveCMUCount) CMUs")

        // Step 2: Load tree from boost file serialized tree section (correct state)
        // FIX #529 v2: Use extractSerializedTree() to get the proper serialized tree format
        // Do NOT use legacy CMU file - it might be cached from old boost file!
        do {
            let serializedTree = try await CommitmentTreeUpdater.shared.extractSerializedTree()
            if verbose {
                print("🔧 FIX #524: Extracted serialized tree from boost file: \(serializedTree.count) bytes")
            }

            // Reset FFI tree
            _ = ZipherXFFI.treeInit()

            // Deserialize the serialized tree (correct format!)
            if ZipherXFFI.treeDeserialize(data: serializedTree) {
                let treeSize = ZipherXFFI.treeSize()
                print("🔧 FIX #524: Loaded tree from boost file: \(treeSize) CMUs")

                // FIX #744: Diagnostic - check tree root immediately after deserialize
                if let boostTreeRoot = ZipherXFFI.treeRoot() {
                    let rootHex = boostTreeRoot.map { String(format: "%02x", $0) }.joined()
                    if verbose {
                        print("🔍 FIX #744: Tree root AFTER deserialize (before delta): \(rootHex.prefix(32))...")
                    }

                    // Check against expected boost file root
                    if let header = try? HeaderStore.shared.getHeader(at: effectiveHeight) {
                        let headerRootHex = header.hashFinalSaplingRoot.map { String(format: "%02x", $0) }.joined()
                        if verbose {
                            print("🔍 FIX #744: Expected header root at \(effectiveHeight): \(headerRootHex.prefix(32))...")
                        }
                        if boostTreeRoot == header.hashFinalSaplingRoot {
                            print("✅ FIX #744: Boost tree root MATCHES header at \(effectiveHeight)!")
                        } else {
                            print("❌ FIX #744: Boost tree root MISMATCH at \(effectiveHeight)!")
                        }
                    }
                }

                // Step 3: If we scanned beyond boost file, append delta CMUs
                if lastScannedHeight > effectiveHeight {
                    let blockRange = lastScannedHeight - effectiveHeight
                    if verbose {
                        print("🔧 FIX #524: Appending delta CMUs from height \(effectiveHeight + 1) to \(lastScannedHeight)...")
                        print("🔧 FIX #765: Block range spans \(blockRange) blocks - checking for missing CMUs...")
                    }

                    // FIX #739 v4: Get delta CMUs from Rust memory (DELTA_CMUS array)
                    // This contains ALL CMUs appended via treeAppend() during this session,
                    // including those from FIX #571 P2P fetch which aren't in the file-based delta bundle
                    let memoryDeltaCMUs = ZipherXFFI.getDeltaCMUsFromMemory()
                    let memoryCount = memoryDeltaCMUs.count

                    // Also try file-based delta bundle as fallback
                    let fileDeltaCMUs = DeltaCMUManager.shared.loadDeltaCMUsForHeightRange(
                        startHeight: effectiveHeight + 1,
                        endHeight: lastScannedHeight
                    )
                    let fileCount = fileDeltaCMUs?.count ?? 0

                    if verbose {
                        print("🔧 FIX #524 v4: Delta CMUs - memory: \(memoryCount), file: \(fileCount)")
                    }

                    // Use whichever source has more CMUs (memory is usually more complete)
                    let deltaCMUs: [Data]
                    if memoryCount >= fileCount && memoryCount > 0 {
                        deltaCMUs = memoryDeltaCMUs
                        if verbose {
                            print("🔧 FIX #524 v4: Using memory delta CMUs (\(memoryCount))")
                        }
                    } else if let fileCMUs = fileDeltaCMUs, !fileCMUs.isEmpty {
                        deltaCMUs = fileCMUs
                        if verbose {
                            print("🔧 FIX #524 v4: Using file delta CMUs (\(fileCount))")
                        }
                    } else {
                        deltaCMUs = []
                    }

                    if !deltaCMUs.isEmpty {
                        var appendedCount = 0
                        for cmu in deltaCMUs {
                            let position = ZipherXFFI.treeAppend(cmu: cmu)
                            if position != UInt64.max {
                                appendedCount += 1
                            }
                        }
                        if verbose {
                            print("🔧 FIX #524: Appended \(appendedCount) delta CMUs")
                        }
                    } else {
                        print("⚠️ FIX #524: No delta CMUs found for range \(effectiveHeight + 1)-\(lastScannedHeight)")
                    }
                }

                // Step 4: Verify tree root now matches
                if let newTreeRoot = ZipherXFFI.treeRoot() {
                    let treeSize = ZipherXFFI.treeSize()
                    if verbose {
                        print("🔧 FIX #524: New tree root: \(newTreeRoot.prefix(8).map { String(format: "%02x", $0) }.joined())...")
                        print("🔧 FIX #524: New tree size: \(treeSize) CMUs")
                    }

                    // Try to validate against last scanned height
                    if let header = try? HeaderStore.shared.getHeader(at: lastScannedHeight) {
                        if newTreeRoot == header.hashFinalSaplingRoot {
                            print("✅ FIX #524: Tree root now matches blockchain at height \(lastScannedHeight)!")

                            // Step 5: Force rebuild ALL witnesses using GLOBAL tree
                            // FIX #739: CRITICAL - Use GLOBAL tree (which FIX #524 just fixed) instead of batch function
                            // The batch function builds its OWN tree from raw CMU data, producing a different root!
                            // The global COMMITMENT_TREE has the correct root after FIX #524 appended delta CMUs
                            print("🔧 FIX #524+#739: Rebuilding all witnesses from GLOBAL tree (correct root)...")

                            let accountId = (try? database.getAccount(index: 0)?.accountId) ?? 0
                            let allNotes = (try? database.getAllNotes(accountId: accountId)) ?? []

                            // Collect all notes with valid CMUs and positions
                            var validNotes: [(note: WalletNote, cmu: Data)] = []
                            for note in allNotes {
                                if let cmu = note.cmu, cmu.count == 32 {
                                    validNotes.append((note: note, cmu: cmu))
                                }
                            }

                            if verbose {
                                print("🔧 FIX #739: Processing \(validNotes.count) notes using GLOBAL tree...")
                            }

                            // Get the global tree's correct root for verification
                            let globalTreeRoot = ZipherXFFI.treeRoot()
                            if let root = globalTreeRoot {
                                if verbose {
                                    print("🔧 FIX #739: Global tree root (correct): \(root.prefix(8).map { String(format: "%02x", $0) }.joined())...")
                                }
                            }

                            // FIX #1282: After FIX #524 tree repair, create FRESH witnesses from the repaired tree.
                            // DO NOT load old witnesses from DB — they may be corrupted (e.g., FIX #1281 double-apply
                            // from a previous build). Old approach: load DB witnesses → updateAllWitnessesBatch → extract.
                            // FIX #1281's size guard incorrectly skipped the update because tree size matched, but
                            // the witnesses in DB were corrupted (wrong merkle paths). updateAllWitnessesBatch can't
                            // fix corrupted witnesses — it only APPENDS CMUs to existing paths.
                            // New approach: treeCreateWitnessForPosition() creates FRESH merkle paths from the
                            // repaired tree. Each witness root = repaired tree root (validated against blockchain).
                            print("🔧 FIX #1282: Creating fresh witnesses from repaired tree (not loading from DB)...")

                            var rebuiltCount = 0
                            if let repairedTreeData = ZipherXFFI.treeSerialize() {
                                for noteData in validNotes {
                                    let witnessIndex = noteData.note.witnessIndex
                                    if let result = ZipherXFFI.treeCreateWitnessForPosition(
                                        treeData: repairedTreeData,
                                        position: witnessIndex
                                    ) {
                                        if result.witness.count >= 100 {
                                            try? database.updateNoteWitness(noteId: noteData.note.id, witness: result.witness)
                                            // FIX #804: Use witness root as anchor
                                            if let witnessAnchor = ZipherXFFI.witnessGetRoot(result.witness) {
                                                try? database.updateNoteAnchor(noteId: noteData.note.id, anchor: witnessAnchor)
                                            }
                                            rebuiltCount += 1
                                        }
                                    }
                                }
                                print("✅ FIX #1282: Created \(rebuiltCount)/\(validNotes.count) fresh witnesses from repaired tree")
                            } else {
                                print("❌ FIX #1282: Failed to serialize repaired tree for witness creation")

                                // Fallback: load witnesses from DB and force-apply ALL delta CMUs
                                // (bypass FIX #1281 guard since we know repair just happened)
                                ZipherXFFI.witnessesClear()
                                var loadedNotes: [(ffiIndex: UInt64, noteId: Int64)] = []
                                for noteData in validNotes {
                                    if !noteData.note.witness.isEmpty {
                                        let index = ZipherXFFI.treeLoadWitness(
                                            witnessData: noteData.note.witness.withUnsafeBytes { $0.baseAddress!.assumingMemoryBound(to: UInt8.self) },
                                            witnessLen: noteData.note.witness.count
                                        )
                                        if index != UInt64.max {
                                            loadedNotes.append((ffiIndex: index, noteId: noteData.note.id))
                                        }
                                    }
                                }

                                let deltaCMUs = DeltaCMUManager.shared.loadDeltaCMUs() ?? []
                                if !deltaCMUs.isEmpty {
                                    // FIX #1282 fallback: force ALL delta CMUs (no FIX #1281 guard — repair path)
                                    var packedCMUs = Data()
                                    for cmu in deltaCMUs { packedCMUs.append(cmu) }
                                    let updatedCount = ZipherXFFI.updateAllWitnessesBatch(cmus: packedCMUs, count: deltaCMUs.count)
                                    if verbose {
                                        print("🔧 FIX #1282 fallback: Updated \(updatedCount) witnesses with ALL \(deltaCMUs.count) delta CMUs")
                                    }
                                }

                                for (ffiIndex, noteId) in loadedNotes {
                                    if let updatedWitness = ZipherXFFI.treeGetWitness(index: ffiIndex) {
                                        if updatedWitness.count >= 100 {
                                            try? database.updateNoteWitness(noteId: noteId, witness: updatedWitness)
                                            if let witnessAnchor = ZipherXFFI.witnessGetRoot(updatedWitness) {
                                                try? database.updateNoteAnchor(noteId: noteId, anchor: witnessAnchor)
                                            }
                                            rebuiltCount += 1
                                        }
                                    }
                                }
                            }

                            print("✅ FIX #524+#1282: Rebuilt \(rebuiltCount)/\(validNotes.count) witnesses (delta sync mode)")

                            // Save the corrected tree state
                            // FIX #1138: Save tree state WITH HEIGHT
                            if let treeData = ZipherXFFI.treeSerialize() {
                                try? database.saveTreeState(treeData, height: lastScannedHeight)
                                print("💾 FIX #524+1138: Saved corrected tree state at height \(lastScannedHeight)")
                            }

                            return true
                        } else {
                            print("⚠️ FIX #524: Tree root still doesn't match blockchain")
                            print("   Our root:    \(newTreeRoot.prefix(8).map { String(format: "%02x", $0) }.joined())...")
                            print("   Header root: \(header.hashFinalSaplingRoot.prefix(8).map { String(format: "%02x", $0) }.joined())...")

                            // FIX #765: Delta CMUs are incomplete/corrupted - P2P scan missed some outputs
                            // FIX #779: Prevent infinite loop - limit delta clearing attempts per session
                            // FIX #782: Add GLOBAL limit across ALL sessions to break persistent loops
                            let deltaRepairKey = "DeltaBundleRepairAttempts"
                            let deltaRepairSessionKey = "DeltaBundleRepairSession"
                            let globalRepairKey = "DeltaBundleGlobalRepairAttempts"  // FIX #782

                            let currentSession = Int(Date().timeIntervalSince1970 / 300) // 5-minute sessions
                            let lastSession = UserDefaults.standard.integer(forKey: deltaRepairSessionKey)
                            var repairAttempts = UserDefaults.standard.integer(forKey: deltaRepairKey)
                            var globalAttempts = UserDefaults.standard.integer(forKey: globalRepairKey)  // FIX #782

                            // Reset session counter if new session
                            if currentSession != lastSession {
                                repairAttempts = 0
                                UserDefaults.standard.set(currentSession, forKey: deltaRepairSessionKey)
                            }

                            // FIX #782: Check GLOBAL limit first (persists across app restarts)
                            // After 5 total attempts, STOP trying - user must manually Full Rescan
                            let maxGlobalAttempts = 5
                            if globalAttempts >= maxGlobalAttempts {
                                print("🛑 FIX #782: Max GLOBAL delta repair attempts (\(maxGlobalAttempts)) exceeded!")
                                print("🛑 FIX #782: Breaking infinite loop - will NOT attempt any more repairs")
                                print("🛑 FIX #782: P2P likely cannot fetch all CMUs - user MUST run 'Full Resync' in Settings")
                                // Mark that we've given up on automatic repair
                                UserDefaults.standard.set(true, forKey: "TreeRepairExhausted")
                                // Don't clear delta or reset - just return and let app continue with boost-only tree
                                return false
                            }

                            let maxRepairAttempts = 2
                            if repairAttempts >= maxRepairAttempts {
                                print("🛑 FIX #779: Max delta repair attempts (\(maxRepairAttempts)) reached this session")
                                print("🛑 FIX #779: Skipping repair for this session (global attempts: \(globalAttempts)/\(maxGlobalAttempts))")
                                // Don't clear delta or reset - just return and let app continue
                                return false
                            }

                            repairAttempts += 1
                            globalAttempts += 1  // FIX #782
                            UserDefaults.standard.set(repairAttempts, forKey: deltaRepairKey)
                            UserDefaults.standard.set(globalAttempts, forKey: globalRepairKey)  // FIX #782
                            if verbose {
                                print("🔧 FIX #779: Delta repair attempt \(repairAttempts)/\(maxRepairAttempts) this session")
                                print("🔧 FIX #782: Global repair attempt \(globalAttempts)/\(maxGlobalAttempts) total")
                            }

                            // FIX #1219: Distinguish INCOMPLETE delta from CORRUPT delta.
                            // Previous bug: always cleared delta on mismatch, even when the delta
                            // was incomplete (P2P fetched 1 CMU out of ~5,800 expected). Clearing
                            // forces a full rebuild but FIX #524 just loads the same incomplete delta
                            // from disk → same 1 CMU → same wrong root → infinite repair loop.
                            //
                            // Incomplete = CMU count is far too low for the block range
                            // Corrupt = CMU count is reasonable but data is wrong
                            let currentDeltaCount = DeltaCMUManager.shared.loadDeltaCMUs()?.count ?? 0
                            let blockRange = lastScannedHeight - effectiveHeight
                            // Zclassic averages ~0.35 shielded outputs per block
                            let expectedMinCMUs = max(1, blockRange / 10)  // Conservative: at least 1 per 10 blocks
                            let isIncomplete = currentDeltaCount < expectedMinCMUs && blockRange > 100

                            // FIX #1252: NEVER clear a verified delta — it was built correctly.
                            // If tree root mismatches with verified delta, the issue is in THIS scan's
                            // P2P fetch (new blocks), not in the delta itself.
                            let deltaIsVerified = UserDefaults.standard.bool(forKey: "DeltaBundleVerified")
                            if deltaIsVerified {
                                print("✅ FIX #1252: Delta is VERIFIED (immutable) — NOT clearing despite tree root mismatch")
                                print("   Mismatch is from new blocks in this scan, not from delta corruption")
                                print("   Delta will remain intact for next startup")
                            } else if isIncomplete {
                                // FIX #1219: Delta is INCOMPLETE, not corrupt. Clearing it won't help
                                // because the same P2P issues will reproduce the same incomplete delta.
                                // Instead, leave it and let syncDeltaBundleIfNeeded fill the gaps next time.
                                print("🔧 FIX #1219: Delta is INCOMPLETE, not corrupt (\(currentDeltaCount) CMUs for \(blockRange) blocks, expected ≥\(expectedMinCMUs))")
                                print("   NOT clearing delta — will retry P2P fetch on next sync cycle")
                                print("   Previous bug: clearing incomplete delta → reload same data → same mismatch → infinite loop")
                            } else {
                                // Delta has a reasonable number of CMUs but produces wrong root = corrupt
                                print("🔧 FIX #765: Delta CMUs appear CORRUPT (\(currentDeltaCount) CMUs for \(blockRange) blocks)")
                                print("   Clearing delta bundle to force rebuild during next PHASE 2 scan")
                                DeltaCMUManager.shared.clearDeltaBundle()
                            }

                            // FIX #1219: Only reset tree and lastScannedHeight for CORRUPT delta.
                            // For incomplete delta, preserve existing state — resetting just forces
                            // the same incomplete P2P fetch again (infinite loop at 1 CMU / 16,693 blocks).
                            // FIX #1252: NEVER reset for verified delta — it's immutable.
                            if deltaIsVerified {
                                print("✅ FIX #1252: Skipping tree/height reset — delta is verified & immutable")
                            } else if !isIncomplete {
                                // FIX #778: CRITICAL - Reset the FFI tree to boost file state!
                                // Without this, the FFI tree still has delta CMUs in memory even though:
                                // 1. Delta manifest was cleared
                                // 2. lastScannedHeight was reset to boost end
                                // This causes WalletHealthCheck to see tree size > boost file but no manifest,
                                // leading to validation at wrong height → mismatch → repair loop forever.
                                print("🔧 FIX #778: Resetting FFI tree to boost file state...")
                                if let serializedTree = try? await CommitmentTreeUpdater.shared.extractSerializedTree() {
                                    _ = ZipherXFFI.treeInit()  // Clear tree and delta CMUs (FIX #764, #771)
                                    if ZipherXFFI.treeDeserialize(data: serializedTree) {
                                        let resetTreeSize = ZipherXFFI.treeSize()
                                        print("✅ FIX #778: FFI tree reset to boost file state (\(resetTreeSize) CMUs)")
                                    } else {
                                        print("⚠️ FIX #778: Could not deserialize boost tree - treeInit already cleared delta CMUs")
                                    }
                                } else {
                                    // Fallback: Just init the tree to clear delta CMUs
                                    _ = ZipherXFFI.treeInit()
                                    print("⚠️ FIX #778: Could not load boost tree - cleared delta CMUs via treeInit")
                                }

                                // Also reset lastScannedHeight to boost file end so PHASE 2 rescans the full range
                                // This ensures we re-fetch all blocks and properly collect ALL shielded outputs
                                let boostEndHeight = ZipherXConstants.effectiveTreeHeight
                                print("🔧 FIX #765: Resetting lastScannedHeight from \(lastScannedHeight) to \(boostEndHeight)")
                                try? database.updateLastScannedHeight(boostEndHeight, hash: Data(count: 32))
                                FilterScanner.updateScanProgress()  // FIX #1074: Update progress time to prevent timeout

                                // Set flag to trigger PHASE 2 rescan
                                await MainActor.run {
                                    WalletManager.shared.pendingDeltaRescan = true
                                }
                                print("🔧 FIX #765: Set pendingDeltaRescan=true - will rescan from boost file end")
                            } else {
                                // FIX #1219: Incomplete delta — keep existing state, just trigger a delta re-sync
                                print("🔧 FIX #1219: Keeping existing delta + tree state (incomplete, not corrupt)")
                                print("   syncDeltaBundleIfNeeded will fill gaps on next cycle")
                                // Reset global repair counter since this isn't a real repair failure
                                UserDefaults.standard.set(max(0, globalAttempts - 1), forKey: globalRepairKey)
                            }

                            return false
                        }
                    } else {
                        print("⚠️ FIX #524: Cannot validate - no header at height \(lastScannedHeight)")
                        return false
                    }
                } else {
                    print("⚠️ FIX #524: No tree root available after deserialization")
                    return false
                }
            } else {
                print("❌ FIX #524: Failed to deserialize tree from boost file")
                return false
            }
        } catch {
            print("❌ FIX #524: Failed to extract serialized tree from boost file: \(error.localizedDescription)")
            return false
        }
    }

    /// Parse raw block data into CompactBlock format
    private func parseRawBlock(_ data: Data, height: UInt64, hash: String) -> CompactBlock? {
        guard data.count >= 140 else {
            print("⚠️ Block \(height) too small: \(data.count) bytes")
            return nil
        }

        // Parse all blocks including those with transactions
        // This is necessary to get all CMUs for the commitment tree

        var offset = 0

        // Block header (Zcash/Zclassic uses extended header)
        // Version (4) + prevHash (32) + merkleRoot (32) + reserved (32) + time (4) + bits (4) + nonce (32) = 140 bytes
        // Then Equihash solution (variable)

        _ = data.loadUInt32(at: offset)  // version - not used
        offset += 4

        let prevHash = Data(data[offset..<offset+32])
        offset += 32

        _ = Data(data[offset..<offset+32])  // merkleRoot - not used
        offset += 32

        // Final Sapling Root (the anchor!) - NOT "reserved"
        let finalSaplingRoot = Data(data[offset..<offset+32])
        offset += 32

        let time = data.loadUInt32(at: offset)
        offset += 4

        _ = data.loadUInt32(at: offset) // bits - not used
        offset += 4

        _ = Data(data[offset..<offset+32]) // nonce - not used
        offset += 32

        // Skip Equihash solution (variable length with compact size prefix)
        if offset < data.count {
            let solutionSize = readCompactSize(data, offset: &offset)
            guard solutionSize >= 0 && solutionSize < data.count else {
                print("⚠️ Block \(height) invalid solution size: \(solutionSize)")
                return nil
            }
            offset += solutionSize
        }

        // Parse transactions
        var transactions: [CompactTx] = []

        guard offset < data.count else {
            return CompactBlock(
                blockHeight: height,
                blockHash: Data(hexString: hash) ?? Data(count: 32),
                prevHash: prevHash,
                finalSaplingRoot: finalSaplingRoot,
                time: time,
                transactions: []
            )
        }

        // Transaction count
        let txCount = readCompactSize(data, offset: &offset)

        // Sanity check tx count
        guard txCount >= 0 && txCount < 10000 else {
            print("⚠️ Block \(height) invalid tx count: \(txCount)")
            return nil
        }

        for txIndex in 0..<txCount {
            guard offset < data.count else { break }

            // Parse transaction
            let (tx, newOffset) = parseTransaction(data, offset: offset, txIndex: txIndex)
            offset = newOffset

            if let tx = tx {
                transactions.append(tx)
            }
        }

        return CompactBlock(
            blockHeight: height,
            blockHash: Data(hexString: hash) ?? Data(count: 32),
            prevHash: prevHash,
            finalSaplingRoot: finalSaplingRoot,
            time: time,
            transactions: transactions
        )
    }

    /// Read compact size (variable int) with bounds checking
    /// SECURITY: Validates size is within reasonable bounds to prevent DoS attacks
    private func readCompactSize(_ data: Data, offset: inout Int) -> Int {
        guard offset < data.count else { return 0 }

        let first = data[offset]
        offset += 1

        var value: UInt64 = 0

        if first < 253 {
            value = UInt64(first)
        } else if first == 253 {
            guard offset + 2 <= data.count else { return 0 }
            value = UInt64(data.loadUInt16(at: offset))
            offset += 2
        } else if first == 254 {
            guard offset + 4 <= data.count else { return 0 }
            value = UInt64(data.loadUInt32(at: offset))
            offset += 4
        } else {
            guard offset + 8 <= data.count else { return 0 }
            value = data.loadUInt64(at: offset)
            offset += 8
        }

        // SECURITY: Bounds check - reject unreasonably large values
        // Max allowed: 100MB to prevent memory exhaustion attacks
        let maxAllowedSize: UInt64 = 100 * 1024 * 1024
        guard value <= maxAllowedSize else {
            print("⚠️ SECURITY: Rejected varint value \(value) exceeding max \(maxAllowedSize)")
            return 0
        }

        return Int(value)
    }

    /// Parse a single transaction from raw data
    private func parseTransaction(_ data: Data, offset: Int, txIndex: Int) -> (CompactTx?, Int) {
        var currentOffset = offset

        guard currentOffset + 4 <= data.count else {
            return (nil, data.count)
        }

        // Read version with overwintered flag
        let header = data.loadUInt32(at: currentOffset)
        currentOffset += 4

        let isOverwintered = (header >> 31) != 0
        let version = header & 0x7FFFFFFF

        // Version group ID for Sapling
        if isOverwintered {
            guard currentOffset + 4 <= data.count else { return (nil, data.count) }
            currentOffset += 4 // versionGroupId
        }

        // Transparent inputs
        let vinCount = readCompactSize(data, offset: &currentOffset)
        guard vinCount >= 0 && vinCount < 10000 else { return (nil, data.count) }
        for _ in 0..<vinCount {
            guard currentOffset + 36 <= data.count else { return (nil, data.count) }
            currentOffset += 36 // prevout (32 hash + 4 index)

            let scriptLen = readCompactSize(data, offset: &currentOffset)
            guard scriptLen >= 0 && currentOffset + scriptLen <= data.count else { return (nil, data.count) }
            currentOffset += scriptLen // scriptSig

            guard currentOffset + 4 <= data.count else { return (nil, data.count) }
            currentOffset += 4 // sequence
        }

        // Transparent outputs
        let voutCount = readCompactSize(data, offset: &currentOffset)
        guard voutCount >= 0 && voutCount < 10000 else { return (nil, data.count) }
        for _ in 0..<voutCount {
            guard currentOffset + 8 <= data.count else { return (nil, data.count) }
            currentOffset += 8 // value

            let scriptLen = readCompactSize(data, offset: &currentOffset)
            guard scriptLen >= 0 && currentOffset + scriptLen <= data.count else { return (nil, data.count) }
            currentOffset += scriptLen // scriptPubKey
        }

        // Lock time
        guard currentOffset + 4 <= data.count else { return (nil, data.count) }
        currentOffset += 4

        // Sapling fields (version >= 4)
        var spends: [CompactSpend] = []
        var outputs: [CompactOutput] = []

        if version >= 4 && isOverwintered {
            // Expiry height
            guard currentOffset + 4 <= data.count else { return (nil, data.count) }
            currentOffset += 4

            // Value balance (int64)
            guard currentOffset + 8 <= data.count else { return (nil, data.count) }
            currentOffset += 8

            // Sapling spends
            let spendCount = readCompactSize(data, offset: &currentOffset)
            guard spendCount >= 0 && spendCount < 1000 else { return (nil, data.count) }
            for _ in 0..<spendCount {
                // cv (32) + anchor (32) + nullifier (32) + rk (32) + zkproof (192) + spendAuthSig (64) = 384
                guard currentOffset + 384 <= data.count else { break }

                currentOffset += 32 // cv
                currentOffset += 32 // anchor

                let nullifier = Data(data[currentOffset..<currentOffset+32])
                currentOffset += 32

                spends.append(CompactSpend(nullifier: nullifier))

                currentOffset += 32 // rk
                currentOffset += 192 // zkproof
                currentOffset += 64 // spendAuthSig
            }

            // Sapling outputs
            let outputCount = readCompactSize(data, offset: &currentOffset)
            guard outputCount >= 0 && outputCount < 1000 else { return (nil, data.count) }
            for _ in 0..<outputCount {
                // cv (32) + cmu (32) + ephemeralKey (32) + encCiphertext (580) + outCiphertext (80) + zkproof (192) = 948
                guard currentOffset + 948 <= data.count else { break }

                currentOffset += 32 // cv

                let cmu = Data(data[currentOffset..<currentOffset+32])
                currentOffset += 32

                let epk = Data(data[currentOffset..<currentOffset+32])
                currentOffset += 32

                let ciphertext = Data(data[currentOffset..<currentOffset+580])
                currentOffset += 580

                outputs.append(CompactOutput(cmu: cmu, epk: epk, ciphertext: ciphertext))

                currentOffset += 80 // outCiphertext
                currentOffset += 192 // zkproof
            }

            // Binding sig if there are spends or outputs
            if spendCount > 0 || outputCount > 0 {
                guard currentOffset + 64 <= data.count else { return (nil, data.count) }
                currentOffset += 64
            }
        }

        // Compute txid (double SHA256 of raw tx)
        let txData = data[offset..<currentOffset]
        let txHash = Data(txData).doubleSHA256()

        let tx = CompactTx(
            txIndex: UInt64(txIndex),
            txHash: Data(txHash.reversed()), // Reverse for display
            spends: spends,
            outputs: outputs
        )

        return (tx, currentOffset)
    }

    /// Process a ZIP-307 compact block using trial decryption
    private func processCompactBlock(_ block: CompactBlock, accountId: Int64, ivk: Data, spendingKey: Data, height: UInt64) async throws {
        // Check for spent notes (nullifier detection)
        for tx in block.transactions {
            for spend in tx.spends {
                // SECURITY: Check for nullifier match without logging sensitive data
                // FIX #367: Hash the blockchain nullifier before comparing
                let hashedNullifier = database.hashNullifier(spend.nullifier)
                if knownNullifiers.contains(hashedNullifier) {
                    // One of our notes was spent! Include txid for history tracking
                    try database.markNoteSpent(nullifier: spend.nullifier, txid: tx.txHash, spentHeight: height)
                    debugLog(.wallet, "💸 Note spent @ height \(height)")

                    // FIX #396: When our note is spent, check if this is our pending outgoing TX
                    // If so, confirm it to clear the "awaiting confirmation" UI state
                    // FIX #859: CRITICAL - tx.txHash is in wire format (little-endian)
                    // But pendingOutgoingTxidSet contains display format (big-endian) txids
                    // computed via rawTx.doubleSHA256().reversed()
                    // We must reverse tx.txHash to match the display format for comparison
                    let txidDisplayFormat = tx.txHash.reversed().map { String(format: "%02x", $0) }.joined()
                    if await NetworkManager.shared.isPendingOutgoingTx(txidDisplayFormat) {
                        if verbose {
                            print("📤 FIX #859: Our pending TX \(txidDisplayFormat.prefix(16))... confirmed in block \(height)")
                        }
                        // FIX #1264: Pass actual block height for accurate DB recording
                        await NetworkManager.shared.confirmOutgoingTx(txid: txidDisplayFormat, blockHeight: height)
                    }
                }
            }
        }

        // Trial-decrypt each output to find notes for us
        for tx in block.transactions {
            for (outputIndex, output) in tx.outputs.enumerated() {
                // Try to decrypt with our incoming viewing key
                if let note = tryDecryptOutput(output, ivk: ivk) {
                    try await processDecryptedNote(
                        note: note,
                        output: output,
                        txid: tx.txHash,
                        outputIndex: UInt32(outputIndex),
                        accountId: accountId,
                        height: height,
                        spendingKey: spendingKey,
                        blockTime: block.time
                    )
                }
            }
        }
    }

    /// Trial-decrypt a single output with our viewing key
    private func tryDecryptOutput(_ output: CompactOutput, ivk: Data) -> DecryptedNote? {
        // Use RustBridge for Sapling trial decryption
        return rustBridge.tryDecryptNote(
            ivk: ivk,
            ephemeralKey: output.epk,
            cmu: output.cmu,
            encCiphertext: output.ciphertext
        )
    }

    /// Stop scanning
    func stopScan() {
        isScanning = false
        scanTask?.cancel()
    }

    /// Process shielded outputs from Insight API transaction (synchronous version for MainActor)
    /// IMPORTANT: Must be called sequentially per block to maintain tree order
    /// Also checks spends for nullifiers to detect spent notes
    /// FIX #786: blockOutputStartIndex is the starting index for outputs in THIS transaction within the BLOCK
    ///          (not per-transaction index) to avoid duplicate (height, index) keys in delta bundle
    @MainActor
    private func processShieldedOutputsSync(
        outputs: [ShieldedOutput],
        spends: [ShieldedSpend]? = nil,
        txid: String,
        accountId: Int64,
        spendingKey: Data,
        ivk: Data,
        height: UInt64,
        blockOutputStartIndex: UInt32 = 0  // FIX #786: Per-block output index (not per-tx)
    ) throws {
        // FIX #843: Track external spend details for this TX (spent from another wallet or after app restart)
        var externalSpendTxids = Set<String>()
        var externalSpendNoteValue: UInt64 = 0  // Value of the note that was spent

        // FIX #288: Check for spent notes (nullifier detection) FIRST
        // FIX #1050: Suppress verbose per-TX spend processing log (routine during sync)
        // FIX #1403: Track if we already confirmed this txid (a TX with N spends triggers N matches)
        var didConfirmOutgoingTx = false
        if let spends = spends, !spends.isEmpty {
            // FIX #1289 v3: Collect nullifiers for delta bundle (enables local spend detection in Phase 1b)
            if deltaCollectionEnabled, let txidData = Data(hexString: txid) {
                for spend in spends {
                    if let nfDisplay = Data(hexString: spend.nullifier) {
                        deltaNullifiersCollected.append(DeltaCMUManager.DeltaNullifier(
                            height: UInt32(height),
                            txid: txidData,
                            nullifier: nfDisplay.reversedBytes()  // wire format
                        ))
                    }
                }
            }

            // Spend detection happens silently - matches still log via FIX #952
            let txidData = Data(hexString: txid)
            for spend in spends {
                guard let nullifierDisplay = Data(hexString: spend.nullifier) else {
                    if verbose {
                        print("⚠️ FIX #288: Failed to parse nullifier hex")
                    }
                    continue
                }
                let nullifierWire = nullifierDisplay.reversedBytes()
                // FIX #367: Hash the blockchain nullifier before comparing
                // knownNullifiers contains HASHED nullifiers (from getAllNullifiers() and insertions)
                // VUL-009 stores hashed nullifiers to prevent spending pattern analysis
                let hashedNullifier = database.hashNullifier(nullifierWire)
                let shortNf = nullifierWire.prefix(8).map { String(format: "%02x", $0) }.joined()

                // FIX #952: CRITICAL - Try both byte orderings for nullifier matching
                // The boost file Rust scan returns nullifiers in canonical format, but there may be
                // byte order inconsistencies between how nullifiers are stored vs how they appear on chain.
                // Try both orderings to ensure external spend detection works correctly.
                let hashedNullifierReversed = database.hashNullifier(nullifierDisplay)

                // FIX #1079: Also check RAW (unhashed) nullifiers for backwards compatibility
                // Some notes may have been stored before VUL-009 hashing, or with wrong position
                // Try all possible formats: hashed wire, hashed display, raw wire, raw display
                let matchesHashedWire = knownNullifiers.contains(hashedNullifier)
                let matchesHashedDisplay = knownNullifiers.contains(hashedNullifierReversed)
                let matchesRawWire = knownNullifiers.contains(nullifierWire)
                let matchesRawDisplay = knownNullifiers.contains(nullifierDisplay)

                let nullifierMatched = matchesHashedWire || matchesHashedDisplay || matchesRawWire || matchesRawDisplay

                // FIX #1079: Determine which format matched for correct database operations
                let matchFormat: String
                let nullifierForDb: Data
                if matchesHashedWire {
                    matchFormat = "hashed-wire"
                    nullifierForDb = nullifierWire
                } else if matchesHashedDisplay {
                    matchFormat = "hashed-display"
                    nullifierForDb = nullifierDisplay
                } else if matchesRawWire {
                    matchFormat = "raw-wire"
                    nullifierForDb = nullifierWire
                } else if matchesRawDisplay {
                    matchFormat = "raw-display"
                    nullifierForDb = nullifierDisplay
                } else {
                    matchFormat = "none"
                    nullifierForDb = nullifierWire  // Default, won't be used if no match
                }

                if nullifierMatched {
                    let shortNf = nullifierWire.prefix(8).map { String(format: "%02x", $0) }.joined()
                    if verbose {
                        print("💸 FIX #1079: MATCH! Nullifier \(shortNf)... found (\(matchFormat)) - marking note as spent")
                    }

                    // FIX #1031: Get note value BEFORE marking spent!
                    // Bug: getNoteByNullifier has "AND is_spent = 0" filter
                    // If we call it AFTER markNoteSpent(), the note is already spent and query returns nil
                    // This broke FIX #843 external spend detection - change outputs were shown as "received"
                    // FIX #1079: Try both wire and display formats to find the note
                    let spentNoteInfo = (try? database.getNoteByNullifier(nullifier: nullifierForDb))
                        ?? (try? database.getNoteByNullifier(nullifier: nullifierWire))
                        ?? (try? database.getNoteByNullifier(nullifier: nullifierDisplay))

                    if let txidData = txidData {
                        try database.markNoteSpent(nullifier: nullifierForDb, txid: txidData, spentHeight: height)
                    } else {
                        try database.markNoteSpent(nullifier: nullifierForDb, spentHeight: height)
                    }

                    // FIX #396: Confirm pending outgoing TX when nullifier found in block
                    // This clears the "awaiting confirmation" UI state
                    // FIX #859: txid parameter is in wire format (from P2P), but pending set uses display format
                    // Convert wire→display by reversing the bytes in the hex string
                    let txidDisplayFormat: String
                    if let txidData = Data(hexString: txid) {
                        txidDisplayFormat = txidData.reversed().map { String(format: "%02x", $0) }.joined()
                    } else {
                        txidDisplayFormat = txid  // Fallback if parsing fails
                    }
                    // FIX #1403: Only confirm once per txid (first nullifier match wins)
                    if !didConfirmOutgoingTx && NetworkManager.shared.isPendingOutgoingTx(txidDisplayFormat) {
                        didConfirmOutgoingTx = true
                        if verbose {
                            print("📤 FIX #859: Pending TX \(txidDisplayFormat.prefix(16))... confirmed in block \(height)")
                        }
                        Task {
                            await NetworkManager.shared.confirmOutgoingTx(txid: txidDisplayFormat, blockHeight: height)
                        }
                    } else if !didConfirmOutgoingTx {
                        // FIX #843: External spend or app-restart case
                        // We detected our nullifier but TX wasn't in pending list
                        // This happens when:
                        // 1. TX was sent from another wallet with same key
                        // 2. App was restarted before TX was confirmed
                        // Record as SENT if not already recorded
                        if let txidData = txidData {
                            let alreadyRecorded = (try? database.transactionExists(txid: txidData, type: .sent)) ?? false
                            if !alreadyRecorded {
                                // FIX #1031: Use the note info we got BEFORE marking spent
                                if let spentNote = spentNoteInfo {
                                    if verbose {
                                        print("💸 FIX #843: External/restart spend detected")
                                        print("   TX: \(txid.prefix(16))... at height \(height)")
                                        print("   Note value: \(spentNote.value.redactedAmount)")
                                    }
                                    // Track this TX for reconciliation when we find the change output
                                    externalSpendTxids.insert(txid)
                                    // FIX #1395: ACCUMULATE total input value (not overwrite)
                                    // When 2+ notes are spent in same TX, we need total to compute sentAmount correctly
                                    // Bug: was `= spentNote.value` → only last note's value → wrong sentAmount
                                    externalSpendNoteValue += spentNote.value
                                }
                            }
                        }
                    }
                } else {
                    // FIX #1050: Suppress verbose non-match logging (was FIX #952 debug)
                    // Only log when nullifier MATCHES (spend detected) - that's important info
                    // Non-matches are the common case during sync and create excessive log noise
                }
            }
        }

        for (outputIndex, output) in outputs.enumerated() {
            // FIX #1311: Only require CMU to parse — use fallbacks for EPK/ciphertext
            // This ensures every CMU that enters the tree also enters the delta
            guard let cmuDisplay = Data(hexString: output.cmu) else {
                continue
            }

            // Reverse byte order: display format (big-endian) -> wire format (little-endian)
            // FIX #1311: Use fallback zeros when EPK/ciphertext hex parsing fails
            // Trial decryption on zeros returns nil (harmless), but CMU still enters tree
            let epk = Data(hexString: output.ephemeralKey)?.reversedBytes() ?? Data(count: 32)
            let encCiphertext = Data(hexString: output.encCiphertext) ?? Data(count: 580)
            let cmu = cmuDisplay.reversedBytes()

            // FIX #786: Calculate per-BLOCK output index (not per-transaction)
            // blockOutputStartIndex is where this TX's outputs start within the block
            // outputIndex is the position within THIS transaction
            // Combined = unique index within the BLOCK for the delta bundle key
            let blockOutputIndex = blockOutputStartIndex + UInt32(outputIndex)

            // DELTA BUNDLE: Collect output for local caching (enables instant witness generation)
            // Format: 652 bytes = height(4) + index(4) + cmu(32) + epk(32) + ciphertext(580)
            let deltaOutput = DeltaCMUManager.DeltaOutput(
                height: UInt32(height),
                index: blockOutputIndex,  // FIX #786: Use per-block index, not per-tx
                cmu: cmu,
                epk: epk,
                ciphertext: encCiphertext
            )

            if deltaCollectionEnabled {
                deltaOutputsCollected.append(deltaOutput)

                // FIX #789: Log delta collection progress every 100 outputs
                if deltaOutputsCollected.count % 100 == 1 || deltaOutputsCollected.count == 1 {
                    if verbose {
                        print("📦 FIX #789: Collecting delta output \(deltaOutputsCollected.count) at height \(height)")
                    }
                }
            } else if height > ZipherXConstants.bundledTreeHeight {
                // FIX #874: Collect outputs even when delta is "disabled" (manifest says it covers range)
                // These are outputs that previous scans MISSED - we need to add them to delta
                deltaOutputsFoundInCoveredRange.append(deltaOutput)
                if deltaOutputsFoundInCoveredRange.count == 1 {
                    print("⚠️ FIX #874: Found output at height \(height) in range that delta 'covers' - previous scan missed it!")
                }
            }

            // FIX #1007 + FIX #1053: Check if this CMU was already appended
            // Problem: Step 2a/delta sync may have already appended these CMUs
            //          Then PHASE 2 scans the same blocks and would append them again
            // Solution: Skip tree modification if delta sync already covered this range
            let currentTreeSize = Int(ZipherXFFI.treeSize())
            let expectedTreeSize = treeSizeAtPhase2Start + cmusAppendedInPhase2

            let treePosition: UInt64
            if skipTreeModification {
                // FIX #1312: Delta sync already brought tree to target - don't modify tree
                // Just use the expected position for note discovery
                treePosition = UInt64(expectedTreeSize)
                // Log once per block to avoid spam
                if outputIndex == 0 {
                    if verbose {
                        print("⏭️ FIX #1312: Skipping treeAppend at height \(height) - delta sync already covered this range")
                    }
                }
            } else if currentTreeSize > expectedTreeSize {
                // FIX #1007: Tree is already larger than expected - Step 2a already appended this CMU
                // Get the position this CMU would have (it's already in the tree)
                treePosition = UInt64(expectedTreeSize)
                // Log once per block to avoid spam
                if outputIndex == 0 {
                    if verbose {
                        print("⏭️ FIX #1007: Skipping treeAppend at height \(height) - CMU already in tree (size \(currentTreeSize) > expected \(expectedTreeSize))")
                    }
                }
            } else {
                // Tree at expected size - append normally
                treePosition = ZipherXFFI.treeAppend(cmu: cmu)
            }
            // Always increment counter to track expected position
            cmusAppendedInPhase2 += 1

            // NEW WALLET OPTIMIZATION: Skip note decryption for new wallets
            // No notes can exist for a brand new address that was just created
            // FIX #960: Only skip for truly new wallets (see line 369)
            if isNewWalletInitialSync {
                // FIX #960: Log when skipping to help debug note detection issues
                if outputIndex == 0 {
                    if verbose {
                        print("⏭️ FIX #960: Skipping trial decryption (isNewWalletInitialSync=true) at height \(height)")
                    }
                }
                _ = treePosition  // Silence unused variable warning
                continue  // Skip decryption, just append CMUs to tree
            }

            // Try to decrypt with spending key
            guard let decryptedData = ZipherXFFI.tryDecryptNoteWithSK(
                spendingKey: spendingKey,
                epk: epk,
                cmu: cmu,
                ciphertext: encCiphertext
            ) else {
                continue
            }

            // Create witness for this note
            let witnessIndex = ZipherXFFI.treeWitnessCurrent()

            // Parse decrypted note data
            // Format: diversifier (11) + value (8) + rcm (32) + memo (512) = 563 bytes
            // Note: FFI returns plaintext without version byte
            guard decryptedData.count >= 51 else { continue }

            let diversifier = decryptedData.prefix(11)
            let valueBytes = Data(decryptedData[11..<19])
            let value = valueBytes.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
            let rcm = decryptedData[19..<51]
            let memo = decryptedData.count >= 563 ? decryptedData[51..<563] : Data()

            debugLog(.wallet, "💰 Note found: [REDACTED] ZCL @ height \(height)")

            let txidData = Data(hexString: txid) ?? Data()

            // Compute nullifier using spending key (required for proper PRF_nf)
            let nullifier = try rustBridge.computeNullifier(
                spendingKey: spendingKey,
                diversifier: Data(diversifier),
                value: value,
                rcm: Data(rcm),
                position: treePosition
            )

            // FIX #953: DEBUG - Log nullifier details when adding to knownNullifiers
            let hashedNf = database.hashNullifier(nullifier)
            if verbose {
                let nfShort = nullifier.prefix(8).map { String(format: "%02x", $0) }.joined()
                print("🔑 FIX #953: Adding nullifier to knownNullifiers at height \(height)")
                print("   Position: \(treePosition), Value: \(value.redactedAmount)")
                print("   Nullifier (wire): \(nfShort)...")
                let hashedNfShort = hashedNf.prefix(8).map { String(format: "%02x", $0) }.joined()
                print("   Hashed nullifier: \(hashedNfShort)...")
            }

            // FIX #367: Insert HASHED nullifier to match getAllNullifiers() and DB storage
            knownNullifiers.insert(hashedNf)

            // Get witness
            let witness = ZipherXFFI.treeGetWitness(index: witnessIndex) ?? Data(count: 1028)

            // FIX #1138: CRITICAL - Use computed CMU instead of blockchain CMU
            // ROOT CAUSE FIX: P2P path was storing blockchain CMU directly, but during
            // transaction building, CMU is recomputed from note parts. If there's any
            // byte order difference, the comparison fails → "joinsplit requirements not met"
            // This matches FIX #585 which does the same for boost file notes.
            let cmuToStore: Data
            if let computedCMU = ZipherXFFI.computeNoteCMU(
                diversifier: Data(diversifier),
                rcm: Data(rcm),
                value: value,
                spendingKey: spendingKey
            ) {
                // Verify CMU matches (compare in both byte orders)
                let cmuReversed = Data(cmu.reversed())
                if computedCMU == cmu {
                    // Direct match - blockchain CMU is in correct format
                    cmuToStore = cmu
                } else if computedCMU == cmuReversed {
                    // Byte order mismatch - use computed CMU (transaction building format)
                    if verbose {
                        print("⚠️ FIX #1138: CMU byte order mismatch at height \(height) - using computed CMU")
                        print("   Blockchain CMU: \(cmu.prefix(8).map { String(format: "%02x", $0) }.joined())...")
                        print("   Computed CMU:   \(computedCMU.prefix(8).map { String(format: "%02x", $0) }.joined())...")
                    }
                    cmuToStore = computedCMU
                } else {
                    // Complete mismatch - use computed CMU for safety
                    if verbose {
                        print("❌ FIX #1138: CMU MISMATCH at height \(height)!")
                        print("   Blockchain CMU: \(cmu.map { String(format: "%02x", $0) }.joined())")
                        print("   Reversed:       \(cmuReversed.map { String(format: "%02x", $0) }.joined())")
                        print("   Computed CMU:   \(computedCMU.map { String(format: "%02x", $0) }.joined())")
                    }
                    cmuToStore = computedCMU
                }
            } else {
                // Failed to compute CMU - fallback to blockchain CMU
                if verbose {
                    print("⚠️ FIX #1138: Could not compute CMU at height \(height) - using blockchain CMU")
                }
                cmuToStore = cmu
            }

            // FIX #1142: CRITICAL - Verify witness consistency BEFORE storing
            // Problem: If cmuToStore != cmu (byte order mismatch), witness was built with wrong CMU
            // The witness merkle_path.root(cmu) won't match merkle_path.root(cmuToStore)
            // This causes "joinsplit requirements not met" at send time
            var witnessToStore = witness
            if !ZipherXFFI.witnessVerifyAnchor(witness, cmu: cmuToStore) {
                print("🚨 FIX #1142: Witness inconsistent with stored CMU at height \(height)")
                print("   This note will need witness rebuild before spending")
                print("   Setting hasCorruptedWitnesses = true to block SEND until fixed")
                // FIX #1141: Immediately block SEND - don't wait for health check
                Task { @MainActor in
                    WalletManager.shared.hasCorruptedWitnesses = true
                    WalletManager.shared.corruptedWitnessCount += 1
                }
            } else {
                debugLog(.wallet, "✅ FIX #1142: Witness verified for note at height \(height)")
            }

            // Store note with verified CMU
            let noteId = try database.insertNote(
                accountId: accountId,
                diversifier: Data(diversifier),
                value: value,
                rcm: Data(rcm),
                memo: Data(memo),
                nullifier: nullifier,
                txid: txidData,
                height: height,
                witness: witnessToStore,
                cmu: cmuToStore // FIX #1138: Use computed CMU for transaction building consistency
            )

            // IMMEDIATELY record in transaction history for real-time consistency
            // CRITICAL: Check if this is a change output from our own send
            // Method 1: Check database for existing "sent" record
            var isChangeOutput = (try? database.transactionExists(txid: txidData, type: .sent)) ?? false

            // Method 2: Check NetworkManager's pendingOutgoing tracking (catches race condition)
            // FIX #942: txid is in WIRE format but pendingOutgoingTxidSet stores DISPLAY format
            // Must convert wire → display by reversing bytes before comparison
            if !isChangeOutput {
                let txidDisplayFormat = txidData.reversed().map { String(format: "%02x", $0) }.joined()
                isChangeOutput = NetworkManager.shared.isPendingOutgoingSync(txid: txidDisplayFormat)
            }

            // FIX #843: Handle external spend / app-restart case
            // We detected our nullifier spent but TX wasn't in pending list
            // Now we found our change output - record the SENT transaction
            if !isChangeOutput && externalSpendTxids.contains(txid) && externalSpendNoteValue > 0 {
                let fee: UInt64 = 10000  // Standard fee
                let changeValue = value
                let sentAmount = externalSpendNoteValue > (changeValue + fee) ?
                    externalSpendNoteValue - changeValue - fee : 0

                if verbose {
                    print("💸 FIX #843: Recording external spend as SENT transaction")
                    print("   Input note: \(externalSpendNoteValue.redactedAmount)")
                    print("   Change output: \(changeValue.redactedAmount)")
                    print("   Sent amount: \(sentAmount.redactedAmount)")
                    print("   Fee: \(fee.redactedAmount)")
                }

                _ = try database.recordSentTransactionAtomic(
                    hashedNullifier: Data(),  // We don't have it here, note already marked spent
                    txid: txidData,
                    spentHeight: height,
                    amount: sentAmount,
                    fee: fee,
                    toAddress: "[External - FIX #843]",
                    memo: "[External wallet or app-restart spend - FIX #843]"
                )
                isChangeOutput = true  // Mark as change so we don't record as received
                externalSpendTxids.remove(txid)  // Handled, remove from tracking
            }

            // FIX #690: DISABLED by FIX #864 - This logic was fatally flawed!
            // The original logic: if we found our output + tx has spends + didn't detect OUR spends
            //   → assume it's our sent transaction with deleted note
            // BUG: When someone ELSE sends to us, their tx also has:
            //   - Our output (what we received)
            //   - Their spends (not ours)
            //   - We don't detect OUR spends (because we didn't spend anything!)
            // This caused received transactions to be incorrectly labeled as "sent"
            // FIX #864: Removed this flawed logic entirely. External spends are handled by FIX #843.
            // If we truly need to detect "our sent with deleted note", we should check pendingOutgoingTxids
            // instead of making assumptions based on spends existing in the transaction.

            if !isChangeOutput {
                // NOTE: Do NOT call trackPendingIncoming here - this is block scanning, not mempool.
                // trackPendingIncoming should only be called for mempool (0-confirmation) transactions.
                // Block transactions are already confirmed so they don't need pending tracking.
                let memoText = String(data: memo.prefix(while: { $0 != 0 }), encoding: .utf8)
                try database.recordReceivedTransaction(
                    txid: txidData,
                    height: height,
                    value: value,
                    memo: memoText
                )

                // FIX #1332: Notify UI when incoming TX discovered in a block.
                // Without this: mempool detection can miss short-lived TXs (mined within 1 scan interval).
                // Note is saved to DB but UI never refreshes TX history and no notification is sent.
                // Bug: user sent from sim→macOS, TX mined before mempool scan, macOS showed no notification.
                let blockValue = value
                let blockTxid = txid
                NotificationCenter.default.post(name: Notification.Name("transactionHistoryUpdated"), object: nil)
                print("📜 FIX #1332: Posted transactionHistoryUpdated after incoming note discovered in block \(height)")

                // Send system notification so user sees incoming TX even if app is in background
                NotificationManager.shared.notifyReceived(amount: blockValue, txid: blockTxid)
                print("🔔 FIX #1332: System notification sent for incoming \(blockValue.redactedAmount) in block \(height)")
            }

            pendingWitnesses.append((noteId: noteId, witnessIndex: witnessIndex))
        }

        // FIX #843: Handle external spend with NO change output (entire amount sent)
        // If we detected our nullifier spent but never found a change output, record as SENT
        if !externalSpendTxids.isEmpty && externalSpendNoteValue > 0 {
            for externalTxid in externalSpendTxids {
                if let txidData = Data(hexString: externalTxid) {
                    let fee: UInt64 = 10000
                    let sentAmount = externalSpendNoteValue > fee ? externalSpendNoteValue - fee : 0

                    if verbose {
                        print("💸 FIX #843: Recording external spend (no change) as SENT transaction")
                        print("   TX: \(externalTxid.prefix(16))...")
                        print("   Input note: \(externalSpendNoteValue.redactedAmount)")
                        print("   Sent amount: \(sentAmount.redactedAmount) (no change output)")
                    }

                    _ = try database.recordSentTransactionAtomic(
                        hashedNullifier: Data(),
                        txid: txidData,
                        spentHeight: height,
                        amount: sentAmount,
                        fee: fee,
                        toAddress: "[External - FIX #843]",
                        memo: "[External spend - no change - FIX #843]"
                    )
                }
            }
        }
    }

    // MARK: - Parallel Batch Processing (6.7x speedup via Rayon)

    /// Metadata for each output in a batch (used to store notes after parallel decryption)
    private struct BatchOutputInfo {
        let txid: String
        let height: UInt64
        let output: ShieldedOutput  // Original InsightAPI output (has cmu for position lookup)
        let outputIndex: Int        // Index within transaction
    }

    /// Process a batch of blocks using parallel Rayon-based decryption
    /// This provides ~6.7x speedup over sequential decryption by using all CPU cores
    ///
    /// - Parameters:
    ///   - blockDataMap: Map of height -> [(txid, outputs, spends)] from P2P/InsightAPI
    ///   - heightRange: Range of heights to process (in order)
    ///   - accountId: Account to store notes for
    ///   - spendingKey: Spending key for decryption
    ///   - collectedSpends: Output array to collect spends for PHASE 1.6
    ///   - cmuDataForPositionLookup: Bundled CMU data for position lookup
    private func processBlocksBatchParallel(
        blockDataMap: [UInt64: [(String, [ShieldedOutput], [ShieldedSpend]?)]],
        heightRange: ClosedRange<UInt64>,
        accountId: Int64,
        spendingKey: Data,
        collectedSpends: inout [(UInt64, String, String)],
        cmuDataForPositionLookup: Data?
    ) throws {
        // Skip if new wallet (no notes to find)
        // FIX #960: Only skip for truly new wallets (see line 369)
        guard !isNewWalletInitialSync else {
            if verbose {
                print("⏭️ FIX #960: Skipping batch parallel processing (isNewWalletInitialSync=true)")
            }
            return
        }

        // Step 1: Collect ALL outputs from the batch with metadata
        var batchOutputs: [BatchOutputInfo] = []
        var totalSpends = 0

        for height in heightRange {
            guard let transactions = blockDataMap[height] else { continue }

            for (txid, outputs, spends) in transactions {
                // Collect spends for PHASE 1.6
                if let spends = spends {
                    for spend in spends {
                        collectedSpends.append((height, txid, spend.nullifier))
                    }
                    totalSpends += spends.count
                }

                // Collect outputs with metadata
                for (idx, output) in outputs.enumerated() {
                    batchOutputs.append(BatchOutputInfo(
                        txid: txid,
                        height: height,
                        output: output,
                        outputIndex: idx
                    ))
                }
            }
        }

        guard !batchOutputs.isEmpty else {
            // Empty batch - no debug logging (too spammy for 2.4M blocks)
            return
        }

        // Only log every 10th batch with outputs to reduce spam
        if heightRange.lowerBound % 5000 == 0 {
            debugLog(.sync, "🚀 Parallel decrypting \(batchOutputs.count) outputs...")
        }

        // Step 2: Convert to FFI format (handles byte order conversion)
        let ffiOutputs = batchOutputs.map { info -> ZipherXFFI.FFIShieldedOutput in
            ZipherXFFI.FFIShieldedOutput(
                epkHex: info.output.ephemeralKey,
                cmuHex: info.output.cmu,
                ciphertextHex: info.output.encCiphertext
            )
        }

        // Step 3: Call parallel decryption (6.7x speedup via Rayon)
        // Use the first height in range for version byte validation
        let results = ZipherXFFI.tryDecryptNotesParallel(
            spendingKey: spendingKey,
            outputs: ffiOutputs,
            height: heightRange.lowerBound
        )

        // Step 4: Process decrypted notes
        var notesFound = 0

        for (idx, maybeNote) in results.enumerated() {
            guard let note = maybeNote else { continue }
            notesFound += 1

            let info = batchOutputs[idx]
            let output = info.output

            // Convert CMU to wire format for database/position lookup
            guard let cmuDisplay = Data(hexString: output.cmu) else { continue }
            let cmu = cmuDisplay.reversedBytes()

            debugLog(.wallet, "💰 Note found: \(Double(note.value)/100_000_000) ZCL @ height \(info.height)")

            let txidData = Data(hexString: info.txid) ?? Data()

            // Look up position from bundled CMU data
            var position: UInt64 = 0
            var needsNullifierFix = false

            if let bundledData = cmuDataForPositionLookup {
                if let realPos = ZipherXFFI.findCMUPosition(cmuData: bundledData, targetCMU: cmu) {
                    position = realPos
                } else {
                    needsNullifierFix = true
                }
            } else {
                needsNullifierFix = true
            }

            // Compute nullifier
            let nullifier = try rustBridge.computeNullifier(
                spendingKey: spendingKey,
                diversifier: note.diversifier,
                value: note.value,
                rcm: note.rcm,
                position: position
            )

            // Add to known nullifiers only if position is correct
            // FIX #367: Insert HASHED nullifier to match getAllNullifiers() and DB storage
            if !needsNullifierFix {
                knownNullifiers.insert(database.hashNullifier(nullifier))
            }

            // FIX #1138: CRITICAL - Use computed CMU instead of blockchain CMU
            // Same logic as main P2P path - ensures consistency with transaction building
            let cmuToStore: Data
            if let computedCMU = ZipherXFFI.computeNoteCMU(
                diversifier: note.diversifier,
                rcm: note.rcm,
                value: note.value,
                spendingKey: spendingKey
            ) {
                let cmuReversed = Data(cmu.reversed())
                if computedCMU == cmu {
                    cmuToStore = cmu
                } else if computedCMU == cmuReversed {
                    if verbose {
                        print("⚠️ FIX #1138: CMU byte order mismatch at height \(info.height) - using computed CMU")
                    }
                    cmuToStore = computedCMU
                } else {
                    if verbose {
                        print("❌ FIX #1138: CMU MISMATCH at height \(info.height)!")
                    }
                    cmuToStore = computedCMU
                }
            } else {
                cmuToStore = cmu
            }

            // Store note
            let noteId = try database.insertNote(
                accountId: accountId,
                diversifier: note.diversifier,
                value: note.value,
                rcm: note.rcm,
                memo: note.memo,
                nullifier: nullifier,
                txid: txidData,
                height: info.height,
                witness: Data(count: 1028),
                cmu: cmuToStore // FIX #1138: Use computed CMU for transaction building consistency
            )

            // Check if change output
            var isChangeOutput = (try? database.transactionExists(txid: txidData, type: .sent)) ?? false
            if !isChangeOutput {
                // FIX #942: info.txid is in WIRE format (little-endian) but pendingOutgoingTxidSet stores DISPLAY format (big-endian)
                // Must convert wire → display by reversing bytes before comparison
                let txidDisplayFormat = txidData.reversed().map { String(format: "%02x", $0) }.joined()
                isChangeOutput = NetworkManager.shared.isPendingOutgoingSync(txid: txidDisplayFormat)
            }

            if !isChangeOutput {
                // NOTE: Do NOT call trackPendingIncoming here - this is block scanning, not mempool.
                // trackPendingIncoming should only be called for mempool (0-confirmation) transactions.
                let memoText = String(data: note.memo.prefix(while: { $0 != 0 }), encoding: .utf8)
                try database.recordReceivedTransaction(
                    txid: txidData,
                    height: info.height,
                    value: note.value,
                    memo: memoText
                )
            }

            // Queue for nullifier fix if needed
            if needsNullifierFix {
                notesNeedingNullifierFix.append((
                    noteId: noteId,
                    cmu: cmu,
                    diversifier: note.diversifier,
                    value: note.value,
                    rcm: note.rcm,
                    height: info.height
                ))
            }
        }

        if notesFound > 0 {
            debugLog(.sync, "🚀 Parallel batch: \(notesFound) notes found in \(batchOutputs.count) outputs")
        }
    }

    /// OPTIMIZED: Process boost file outputs directly using binary Data (no hex conversion)
    /// This matches the benchmark's performance by avoiding hex string conversions entirely.
    /// The boost file stores outputs in wire format (little-endian), ready for direct FFI use.
    ///
    /// - Parameters:
    ///   - outputs: Pre-processed outputs from BundledShieldedOutputs.getOutputsForParallelDecryption()
    ///             Each tuple contains (output, height, cmu, globalPosition)
    ///   - accountId: Account to store notes for
    ///   - spendingKey: Spending key for decryption
    ///   - baseHeight: Lowest height in batch (for FFI version byte selection)
    private func processBoostOutputsParallel(
        outputs: [(output: ZipherXFFI.FFIShieldedOutput, height: UInt32, cmu: Data, globalPosition: UInt64)],
        accountId: Int64,
        spendingKey: Data,
        baseHeight: UInt64
    ) throws {
        guard !outputs.isEmpty else { return }

        // Extract just the FFI outputs for parallel decryption
        let ffiOutputs = outputs.map { $0.output }

        // Call parallel decryption (6.7x speedup via Rayon)
        let results = ZipherXFFI.tryDecryptNotesParallel(
            spendingKey: spendingKey,
            outputs: ffiOutputs,
            height: baseHeight
        )

        // Process decrypted notes
        var notesFound = 0

        for (idx, maybeNote) in results.enumerated() {
            guard let note = maybeNote else { continue }
            notesFound += 1

            let info = outputs[idx]
            let cmu = info.cmu  // Already in wire format from boost file
            let height = UInt64(info.height)
            let position = info.globalPosition  // Position from boost file index (matches benchmark)

            debugLog(.wallet, "💰 Note found: [REDACTED] ZCL @ height \(height)")

            // Generate a pseudo-txid for bundled outputs (grouped by height)
            let txidData = "boost_\(height)_\(idx)".data(using: .utf8) ?? Data()

            // Compute nullifier using globalPosition from boost file index
            // This matches how the benchmark computes positions: enumerate index = position
            let nullifier = try rustBridge.computeNullifier(
                spendingKey: spendingKey,
                diversifier: note.diversifier,
                value: note.value,
                rcm: note.rcm,
                position: position
            )

            // Add to known nullifiers - position is always correct from boost file index
            // FIX #367: Insert HASHED nullifier to match getAllNullifiers() and DB storage
            knownNullifiers.insert(database.hashNullifier(nullifier))

            // Store note (noteId unused - witnesses computed in PHASE 1.5)
            _ = try database.insertNote(
                accountId: accountId,
                diversifier: note.diversifier,
                value: note.value,
                rcm: note.rcm,
                memo: note.memo,
                nullifier: nullifier,
                txid: txidData,
                height: height,
                witness: Data(count: 1028),
                cmu: cmu
            )

            // Record in transaction history immediately
            try? database.recordReceivedTransaction(
                txid: txidData,
                height: height,
                value: note.value,
                memo: String(data: note.memo.prefix(512).filter { $0 != 0 }, encoding: .utf8)
            )

            // Note: Witnesses are computed in PHASE 1.5 (computeWitnessesForBundledNotesBatch)
            // The notes are stored with empty witnesses, and PHASE 1.5 batch-computes them
        }

        if notesFound > 0 {
            debugLog(.sync, "⚡ Boost batch: \(notesFound) notes found in \(outputs.count) outputs (binary path)")
        }
    }

    /// Process entire boost file using Rust FFI (complete migration from Swift)
    /// This uses the same approach as bench_boost_scan.rs which correctly finds all notes
    /// Key insight: position = enumerate index in outputs array (blockchain order)
    ///
    /// - Parameters:
    ///   - accountId: Account to store notes for
    ///   - spendingKey: Spending key for decryption
    /// - Returns: Tuple of (notes found, notes spent, unspent balance in zatoshis)
    private func processBoostFileWithRust(
        accountId: Int64,
        spendingKey: Data,
        onProgress: ((String, String) -> Void)? = nil
    ) async throws -> (notesFound: Int, notesSpent: Int, balance: UInt64) {
        // Get section info from boost manifest
        let treeUpdater = CommitmentTreeUpdater.shared

        guard let cachedInfo = await treeUpdater.getCachedInfo() else {
            throw ScanError.boostFileMissing
        }

        let outputCount = Int(cachedInfo.outputCount)
        let spendCount = Int(cachedInfo.spendCount)

        debugLog(.sync, "🦀 Rust boost scan: \(outputCount) outputs, \(spendCount) spends")
        onProgress?("extract_outputs", "Extracting \(outputCount.formatted()) outputs...")

        // Extract raw data from boost file
        let outputsData = try await treeUpdater.extractShieldedOutputs()
        onProgress?("extract_spends", "Extracting \(spendCount.formatted()) spends...")
        let spendsData = try await treeUpdater.extractShieldedSpends()

        debugLog(.sync, "📦 Extracted: outputs=\(outputsData.count) bytes, spends=\(spendsData.count) bytes")
        onProgress?("rust_scan", "Scanning \(outputCount.formatted()) outputs (Rayon parallel)...")

        // Call Rust FFI for complete scanning
        guard let result = ZipherXFFI.scanBoostOutputs(
            spendingKey: spendingKey,
            outputsData: outputsData,
            outputCount: outputCount,
            spendsData: spendsData,
            spendCount: spendCount
        ) else {
            throw ScanError.decryptionFailed
        }

        debugLog(.sync, """
            🦀 Rust scan result:
               Notes found: \(result.summary.notesFound)
               Notes spent: \(result.summary.notesSpent)
               Unspent balance: \(Double(result.summary.unspentBalance) / 100_000_000) ZCL
               Total received: \(Double(result.summary.totalReceived) / 100_000_000) ZCL
            """)

        // Report scan complete, storing notes
        if result.summary.notesFound > 0 {
            onProgress?("store_notes", "Storing \(result.summary.notesFound) notes in vault...")
        } else {
            onProgress?("store_notes", "No notes found for this wallet")
        }

        // Store all notes in database
        for note in result.notes {
            // FIX #461: Use REAL txid from boost file instead of creating placeholder!
            // The boost file contains the actual transaction ID that created this output
            let txidData = note.receivedTxid  // Real txid - no more placeholders!

            // Add to known nullifiers for future spend detection
            // FIX #367: Insert HASHED nullifier to match getAllNullifiers() and DB storage
            knownNullifiers.insert(database.hashNullifier(note.nullifier))

            // Insert note into database
            _ = try database.insertNote(
                accountId: accountId,
                diversifier: note.diversifier,
                value: note.value,
                rcm: note.rcm,
                memo: Data(count: 512), // Memo not extracted in this path
                nullifier: note.nullifier,
                txid: txidData,
                height: UInt64(note.height),
                witness: Data(count: 1028), // Witnesses computed in PHASE 1.5
                cmu: note.cmu
            )

            // Record in transaction history with REAL txid
            try? database.recordReceivedTransaction(
                txid: txidData,
                height: UInt64(note.height),
                value: note.value,
                memo: nil
            )

            // If Rust already determined this note is spent, mark it with REAL txid
            if note.isSpent {
                // Use the REAL txid from boost file - no more placeholders!
                try database.markNoteSpent(
                    nullifier: note.nullifier,
                    txid: note.spentTxid,
                    spentHeight: UInt64(note.spentHeight)
                )
                debugLog(.wallet, "💸 Note spent: [REDACTED] ZCL @ height \(note.height)")
            } else {
                debugLog(.wallet, "💰 Unspent note: [REDACTED] ZCL @ height \(note.height)")
            }
        }

        // Report completion
        onProgress?("complete", "Boost scan complete: \(result.summary.notesFound) notes")

        return (
            notesFound: Int(result.summary.notesFound),
            notesSpent: Int(result.summary.notesSpent),
            balance: result.summary.unspentBalance
        )
    }

    /// Process shielded outputs for note discovery only (no tree building)
    /// Used by quick scan - much faster as it skips CMU appending
    /// Also checks spends for nullifiers to detect spent notes
    /// cmuDataForPositionLookup: Optional bundled CMU data for looking up real positions
    private func processShieldedOutputsForNotesOnly(
        outputs: [ShieldedOutput],
        spends: [ShieldedSpend]? = nil,
        txid: String,
        accountId: Int64,
        spendingKey: Data,
        ivk: Data,
        height: UInt64,
        cmuDataForPositionLookup: Data? = nil
    ) throws {
        // CRITICAL: Check for spent notes (nullifier detection) FIRST
        // This must be done before processing outputs so we can catch spends
        // of notes we already know about
        // FIX #1403: Track if we already confirmed this txid (a TX with N spends triggers N matches)
        var didConfirmOutgoingTx = false
        if let spends = spends {
            // Convert txid from hex string to Data for database storage
            let txidData = Data(hexString: txid)
            for spend in spends {
                guard let nullifierDisplay = Data(hexString: spend.nullifier) else {
                    continue
                }
                // CRITICAL FIX: API returns nullifier in big-endian (display format)
                // but our knownNullifiers are stored in little-endian (wire format)
                // Must reverse before comparison!
                let nullifierWire = nullifierDisplay.reversedBytes()
                // FIX #367: Hash the blockchain nullifier before comparing
                let hashedNullifier = database.hashNullifier(nullifierWire)
                if knownNullifiers.contains(hashedNullifier) {
                    // One of our notes was spent! Include txid for history tracking
                    if let txidData = txidData {
                        try database.markNoteSpent(nullifier: nullifierWire, txid: txidData, spentHeight: height)
                    } else {
                        try database.markNoteSpent(nullifier: nullifierWire, spentHeight: height)
                    }
                    debugLog(.wallet, "💸 Note spent @ height \(height)")

                    // FIX #396: Confirm pending outgoing TX when nullifier found in block
                    // FIX #859: txid parameter is in wire format, but pending set uses display format
                    // FIX #1403: Only confirm once per txid (first nullifier match wins)
                    if !didConfirmOutgoingTx {
                        let txidDisplayFormat: String
                        if let txidData = Data(hexString: txid) {
                            txidDisplayFormat = txidData.reversed().map { String(format: "%02x", $0) }.joined()
                        } else {
                            txidDisplayFormat = txid  // Fallback
                        }
                        if NetworkManager.shared.isPendingOutgoingSync(txid: txidDisplayFormat) {
                            didConfirmOutgoingTx = true
                            if verbose {
                                print("📤 FIX #859: Pending TX \(txidDisplayFormat.prefix(16))... confirmed in block \(height)")
                            }
                            Task {
                                await NetworkManager.shared.confirmOutgoingTx(txid: txidDisplayFormat, blockHeight: height)
                            }
                        }
                    }
                }
            }
        }
        for output in outputs {
            // Convert hex strings to binary data
            guard let cmuDisplay = Data(hexString: output.cmu),
                  let epkDisplay = Data(hexString: output.ephemeralKey),
                  let encCiphertext = Data(hexString: output.encCiphertext) else {
                continue
            }

            // encCiphertext parsed successfully (580 bytes expected)

            // Reverse byte order: display format (big-endian) -> wire format (little-endian)
            let epk = epkDisplay.reversedBytes()
            let cmu = cmuDisplay.reversedBytes()

            // NEW WALLET OPTIMIZATION: Skip note decryption for new wallets
            // No notes can exist for a brand new address that was just created
            // FIX #960: Only skip for truly new wallets (see line 369)
            if isNewWalletInitialSync {
                if verbose {
                    print("⏭️ FIX #960: Skipping trial decryption in boost path (isNewWalletInitialSync=true)")
                }
                continue  // Skip decryption entirely
            }

            // Skip tree operations for speed - just try to decrypt
            guard let decryptedData = ZipherXFFI.tryDecryptNoteWithSK(
                spendingKey: spendingKey,
                epk: epk,
                cmu: cmu,
                ciphertext: encCiphertext
            ) else {
                continue
            }

            // Parse decrypted note data
            // Format: diversifier (11) + value (8) + rcm (32) + memo (512) = 563 bytes
            // Note: FFI returns plaintext without version byte
            guard decryptedData.count >= 51 else { continue }

            let diversifier = decryptedData.prefix(11)
            let valueBytes = Data(decryptedData[11..<19])
            let value = valueBytes.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
            let rcm = decryptedData[19..<51]
            let memo = decryptedData.count >= 563 ? decryptedData[51..<563] : Data()

            debugLog(.wallet, "💰 Note found: [REDACTED] ZCL @ height \(height)")

            let txidData = Data(hexString: txid) ?? Data()

            // Try to find real position from downloaded CMU data
            var position: UInt64 = 0
            var needsNullifierFix = false
            _ = ZipherXConstants.effectiveTreeHeight  // downloadedTreeHeight - not used

            if let downloadedData = cmuDataForPositionLookup {
                if let realPos = ZipherXFFI.findCMUPosition(cmuData: downloadedData, targetCMU: cmu) {
                    position = realPos
                } else {
                    needsNullifierFix = true
                }
            } else {
                needsNullifierFix = true
            }

            // Compute nullifier using spending key with current position (may be 0 if needs fix)
            let nullifier = try rustBridge.computeNullifier(
                spendingKey: spendingKey,
                diversifier: Data(diversifier),
                value: value,
                rcm: Data(rcm),
                position: position
            )

            // SECURITY: Never log nullifiers - they are sensitive privacy data

            // Only add to knownNullifiers if we're confident the nullifier is correct
            // Notes needing fix will have their nullifiers added after PHASE 2.5
            // FIX #367: Insert HASHED nullifier to match getAllNullifiers() and DB storage
            if !needsNullifierFix {
                knownNullifiers.insert(database.hashNullifier(nullifier))
            }

            // FIX #1138: CRITICAL - Use computed CMU instead of blockchain CMU
            // Same logic as main P2P path - ensures consistency with transaction building
            let cmuToStore: Data
            if let computedCMU = ZipherXFFI.computeNoteCMU(
                diversifier: Data(diversifier),
                rcm: Data(rcm),
                value: value,
                spendingKey: spendingKey
            ) {
                let cmuReversed = Data(cmu.reversed())
                if computedCMU == cmu {
                    cmuToStore = cmu
                } else if computedCMU == cmuReversed {
                    print("⚠️ FIX #1138: CMU byte order mismatch at height \(height) - using computed CMU")
                    cmuToStore = computedCMU
                } else {
                    print("❌ FIX #1138: CMU MISMATCH at height \(height)!")
                    cmuToStore = computedCMU
                }
            } else {
                cmuToStore = cmu
            }

            // Store note with CMU and empty witness (will need to rebuild for spending)
            let noteId = try database.insertNote(
                accountId: accountId,
                diversifier: Data(diversifier),
                value: value,
                rcm: Data(rcm),
                memo: Data(memo),
                nullifier: nullifier,
                txid: txidData,
                height: height,
                witness: Data(count: 1028), // Empty witness - needs rebuild for spending
                cmu: cmuToStore // FIX #1138: Use computed CMU for transaction building consistency
            )

            // IMMEDIATELY record in transaction history for real-time consistency
            // CRITICAL: Check if this is a change output from our own send
            // Method 1: Check database for existing "sent" record
            var isChangeOutput = (try? database.transactionExists(txid: txidData, type: .sent)) ?? false

            // Method 2: Check NetworkManager's pendingOutgoing tracking (catches race condition)
            // FIX #942: txid is in WIRE format but pendingOutgoingTxidSet stores DISPLAY format
            // Must convert wire → display by reversing bytes before comparison
            if !isChangeOutput {
                let txidDisplayFormat = txidData.reversed().map { String(format: "%02x", $0) }.joined()
                isChangeOutput = NetworkManager.shared.isPendingOutgoingSync(txid: txidDisplayFormat)
            }

            if !isChangeOutput {
                // NOTE: Do NOT call trackPendingIncoming here - this is block scanning, not mempool.
                // trackPendingIncoming should only be called for mempool (0-confirmation) transactions.
                let memoText = String(data: memo.prefix(while: { $0 != 0 }), encoding: .utf8)
                try database.recordReceivedTransaction(
                    txid: txidData,
                    height: height,
                    value: value,
                    memo: memoText
                )
            }

            // Track notes that need nullifier recomputation after PHASE 2
            if needsNullifierFix {
                notesNeedingNullifierFix.append((
                    noteId: noteId,
                    cmu: cmu,
                    diversifier: Data(diversifier),
                    value: value,
                    rcm: Data(rcm),
                    height: height
                ))
            }
        }
    }

    /// Process shielded outputs from Insight API transaction (async version - legacy)
    /// IMPORTANT: Must be called sequentially per block to maintain tree order
    private func processShieldedOutputs(
        outputs: [ShieldedOutput],
        txid: String,
        accountId: Int64,
        spendingKey: Data,
        ivk: Data,
        height: UInt64
    ) async throws {
        for (index, output) in outputs.enumerated() {
            // Convert hex strings to binary data
            // IMPORTANT: EPK and CMU from JSON are in display format (big-endian)
            // but librustzcash expects wire format (little-endian), so we reverse bytes
            guard let cmuDisplay = Data(hexString: output.cmu),
                  let epkDisplay = Data(hexString: output.ephemeralKey),
                  let encCiphertext = Data(hexString: output.encCiphertext) else {
                if verbose {
                    print("⚠️ Failed to parse output \(index) hex data")
                }
                continue
            }

            // Reverse byte order: display format (big-endian) -> wire format (little-endian)
            let epk = epkDisplay.reversedBytes()
            let cmu = cmuDisplay.reversedBytes()

            // Append CMU to commitment tree (must be done for ALL outputs, not just ours)
            let treePosition = ZipherXFFI.treeAppend(cmu: cmu)
            if treePosition == UInt64.max {
                if verbose {
                    print("⚠️ Failed to append CMU to tree at height \(height)")
                }
            }

            // Try to decrypt with spending key (uses zcash_primitives internally for IVK derivation)
            guard let decryptedData = ZipherXFFI.tryDecryptNoteWithSK(
                spendingKey: spendingKey,
                epk: epk,
                cmu: cmu,
                ciphertext: encCiphertext
            ) else {
                continue
            }

            // Create witness for this note (must be done immediately after append)
            let witnessIndex = ZipherXFFI.treeWitnessCurrent()

            // Parse decrypted note data: diversifier(11) + value(8) + rcm(32) + memo(512)
            guard decryptedData.count >= 51 else { continue }

            let diversifier = decryptedData.prefix(11)
            let valueBytes = Data(decryptedData[11..<19])
            let value = valueBytes.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
            let rcm = decryptedData[19..<51]
            let memo = decryptedData.count >= 564 ? decryptedData[52..<564] : Data()

            let note = DecryptedNote(
                diversifier: Data(diversifier),
                value: value,
                rcm: Data(rcm),
                memo: Data(memo)
            )

            debugLog(.wallet, "💰 Note found: [REDACTED] ZCL @ height \(height)")

            let txidData = Data(hexString: txid) ?? Data()

            // Use real tree position for nullifier computation
            let position = treePosition

            // Compute nullifier for this note using spending key
            let nullifier = try rustBridge.computeNullifier(
                spendingKey: spendingKey,
                diversifier: note.diversifier,
                value: note.value,
                rcm: note.rcm,
                position: position
            )

            // Track this nullifier for spend detection
            // FIX #367: Insert HASHED nullifier to match getAllNullifiers() and DB storage
            knownNullifiers.insert(database.hashNullifier(nullifier))

            // Get current witness (will be updated at end of scan with final tree state)
            let witness = ZipherXFFI.treeGetWitness(index: witnessIndex) ?? Data(count: 1028)

            // FIX #1138: CRITICAL - Use computed CMU instead of blockchain CMU
            // Same logic as main P2P path - ensures consistency with transaction building
            let cmuToStore: Data
            if let computedCMU = ZipherXFFI.computeNoteCMU(
                diversifier: note.diversifier,
                rcm: note.rcm,
                value: note.value,
                spendingKey: spendingKey
            ) {
                let cmuReversed = Data(cmu.reversed())
                if computedCMU == cmu {
                    cmuToStore = cmu
                } else if computedCMU == cmuReversed {
                    print("⚠️ FIX #1138: CMU byte order mismatch at height \(height) - using computed CMU")
                    cmuToStore = computedCMU
                } else {
                    print("❌ FIX #1138: CMU MISMATCH at height \(height)!")
                    cmuToStore = computedCMU
                }
            } else {
                cmuToStore = cmu
            }

            // FIX #1142: CRITICAL - Verify witness consistency BEFORE storing
            // This ensures the app NEVER breaks witnesses by storing invalid data
            if !ZipherXFFI.witnessVerifyAnchor(witness, cmu: cmuToStore) {
                print("🚨 FIX #1142: Witness inconsistent with stored CMU at height \(height)")
                print("   This note will need witness rebuild before spending")
                print("   Setting hasCorruptedWitnesses = true to block SEND until fixed")
                Task { @MainActor in
                    WalletManager.shared.hasCorruptedWitnesses = true
                    WalletManager.shared.corruptedWitnessCount += 1
                }
            } else {
                debugLog(.wallet, "✅ FIX #1142: Witness verified for note at height \(height)")
            }

            // Store note in database with CMU
            let noteId = try database.insertNote(
                accountId: accountId,
                diversifier: note.diversifier,
                value: note.value,
                rcm: note.rcm,
                memo: note.memo,
                nullifier: nullifier,
                txid: txidData,
                height: height,
                witness: witness,
                cmu: cmuToStore // FIX #1138: Use computed CMU for transaction building consistency
            )

            // Track for final witness update
            pendingWitnesses.append((noteId: noteId, witnessIndex: witnessIndex))

            // IMMEDIATELY record in transaction history for real-time consistency
            // CRITICAL: Check if this is a change output from our own send
            // Method 1: Check database for existing "sent" record
            var isChangeOutput = (try? database.transactionExists(txid: txidData, type: .sent)) ?? false

            // Method 2: Check NetworkManager's pendingOutgoing tracking (catches race condition)
            // FIX #942: txid is in WIRE format but pendingOutgoingTxidSet stores DISPLAY format
            // Must convert wire → display by reversing bytes before comparison
            if !isChangeOutput {
                let txidDisplayFormat = txidData.reversed().map { String(format: "%02x", $0) }.joined()
                isChangeOutput = NetworkManager.shared.isPendingOutgoingSync(txid: txidDisplayFormat)
            }

            if !isChangeOutput {
                NotificationManager.shared.notifyReceived(amount: value, txid: txid)
                let memoText: String? = {
                    let truncated = note.memo.prefix(512)
                    let filtered = truncated.filter { $0 != 0 }
                    guard !filtered.isEmpty else { return nil }
                    return String(data: Data(filtered), encoding: .utf8)
                }()
                try database.recordReceivedTransaction(
                    txid: txidData,
                    height: height,
                    value: note.value,
                    memo: memoText
                )
            }
        }
    }


    /// Process a successfully decrypted note
    private func processDecryptedNote(
        note: DecryptedNote,
        output: CompactOutput,
        txid: Data,
        outputIndex: UInt32,
        accountId: Int64,
        height: UInt64,
        spendingKey: Data,
        blockTime: UInt32
    ) async throws {
        // Calculate position in commitment tree (simplified)
        let position = height * 1000 + UInt64(outputIndex)

        // Compute nullifier for this note using spending key
        let nullifier = try rustBridge.computeNullifier(
            spendingKey: spendingKey,
            diversifier: note.diversifier,
            value: note.value,
            rcm: note.rcm,
            position: position
        )

        // Track this nullifier for spend detection
        // FIX #367: Insert HASHED nullifier to match getAllNullifiers() and DB storage
        knownNullifiers.insert(database.hashNullifier(nullifier))

        // Get witness for the note commitment
        let witness = try await getWitness(for: output.cmu, at: height)

        // FIX #1138: CRITICAL - Use computed CMU instead of compact block CMU
        // This ensures consistency with transaction building
        let cmuToStore: Data
        if let computedCMU = ZipherXFFI.computeNoteCMU(
            diversifier: note.diversifier,
            rcm: note.rcm,
            value: note.value,
            spendingKey: spendingKey
        ) {
            let cmuReversed = Data(output.cmu.reversed())
            if computedCMU == output.cmu {
                cmuToStore = output.cmu
            } else if computedCMU == cmuReversed {
                print("⚠️ FIX #1138: CMU byte order mismatch at height \(height) - using computed CMU")
                cmuToStore = computedCMU
            } else {
                print("❌ FIX #1138: CMU MISMATCH at height \(height)!")
                cmuToStore = computedCMU
            }
        } else {
            cmuToStore = output.cmu
        }

        // FIX #1142: CRITICAL - Verify witness consistency BEFORE storing
        // This ensures the app NEVER breaks witnesses by storing invalid data
        if !ZipherXFFI.witnessVerifyAnchor(witness, cmu: cmuToStore) {
            print("🚨 FIX #1142: Witness inconsistent with stored CMU at height \(height)")
            print("   This note will need witness rebuild before spending")
            print("   Setting hasCorruptedWitnesses = true to block SEND until fixed")
            Task { @MainActor in
                WalletManager.shared.hasCorruptedWitnesses = true
                WalletManager.shared.corruptedWitnessCount += 1
            }
        } else {
            debugLog(.wallet, "✅ FIX #1142: Witness verified for note at height \(height)")
        }

        // Store note in database
        _ = try database.insertNote(
            accountId: accountId,
            diversifier: note.diversifier,
            value: note.value,
            rcm: note.rcm,
            memo: note.memo,
            nullifier: nullifier,
            txid: txid,
            height: height,
            witness: witness,
            cmu: cmuToStore // FIX #1138: Store computed CMU for transaction building consistency
        )

        // Record transaction history for received note
        // CRITICAL: Check if this is a change output from our own send
        // If we already have a "sent" transaction with this txid, this is change - don't record as received
        // Note: txid parameter is already Data type, no conversion needed
        // Method 1: Check database for existing "sent" record
        var isChangeOutput = (try? database.transactionExists(txid: txid, type: .sent)) ?? false

        // Method 2: Check NetworkManager's pendingOutgoing tracking (catches race condition)
        // FIX #942: txid is in WIRE format but pendingOutgoingTxidSet stores DISPLAY format
        // Must convert wire → display by reversing bytes before comparison
        if !isChangeOutput {
            let txidDisplayFormat = txid.reversed().map { String(format: "%02x", $0) }.joined()
            isChangeOutput = NetworkManager.shared.isPendingOutgoingSync(txid: txidDisplayFormat)
        }

        if !isChangeOutput {
            // This is a real incoming payment found in a mined block!
            let txidHex = txid.map { String(format: "%02x", $0) }.joined()

            // Trigger the mined celebration for incoming confirmed tx
            // This will show the cypherpunk "mined" message and system notification
            await NetworkManager.shared.confirmIncomingTx(txid: txidHex, amount: note.value)
            // Extract memo string from memo data (filter null bytes, convert to UTF8)
            let memoString: String? = {
                let truncated = note.memo.prefix(512)
                let filtered = truncated.filter { $0 != 0 }
                guard !filtered.isEmpty else { return nil }
                return String(data: Data(filtered), encoding: .utf8)
            }()
            _ = try database.insertTransactionHistory(
                txid: txid,
                height: height,
                blockTime: UInt64(blockTime), // Real blockchain timestamp from block header
                type: .received,
                value: note.value,
                fee: nil,
                toAddress: nil, // We received it, so our address
                fromDiversifier: note.diversifier,
                memo: memoString
            )
        }
        debugLog(.wallet, "💰 Note found: [REDACTED] ZCL @ height \(height)")
    }

    // MARK: - Helper Methods

    private func getChainHeight() async throws -> UInt64 {
        // FIX #120/#167: P2P-only with strict consensus validation
        // SECURITY: Requires minimum 3 peers for consensus before accepting height
        // This prevents Sybil attacks where malicious peers report fake heights

        // FIX #228: Wait for enough peers before giving up on import sync
        // Problem: Import sync was failing immediately with 2 peers, leaving wallet with 0 balance
        let minPeersForConsensus = 3
        let maxRetries = 5
        let retryDelay: UInt64 = 3_000_000_000 // 3 seconds

        for attempt in 1...maxRetries {
            let connectedPeers = await MainActor.run { networkManager.connectedPeers }
            if connectedPeers >= minPeersForConsensus {
                break
            }

            if attempt < maxRetries {
                if verbose {
                    print("⏳ [FIX #228] Waiting for peers: \(connectedPeers)/\(minPeersForConsensus) (attempt \(attempt)/\(maxRetries))")
                }
                try await Task.sleep(nanoseconds: retryDelay)

                // Try to connect to more peers
                if connectedPeers < minPeersForConsensus {
                    try? await networkManager.connect()
                }
            } else {
                print("🚨 [FIX #228] Insufficient peers for consensus after \(maxRetries) retries: \(connectedPeers)/\(minPeersForConsensus)")
                throw ScanError.networkError
            }
        }

        let connectedPeers = await MainActor.run { networkManager.connectedPeers }
        guard connectedPeers >= minPeersForConsensus else {
            print("🚨 [FIX #167] Insufficient peers for consensus: \(connectedPeers)/\(minPeersForConsensus)")
            throw ScanError.networkError
        }

        // P2P-only: get chain height from NetworkManager (requires peer consensus)
        let consensusHeight = try await networkManager.getChainHeight()

        guard consensusHeight > 0 else {
            throw ScanError.networkError
        }

        // FIX #167: Additional validation against HeaderStore (Equihash-verified headers)
        let headerStoreHeight = (try? HeaderStore.shared.getLatestHeight()) ?? 0
        let maxHeightDeviation: UInt64 = 200

        // If HeaderStore exists and is way ahead of consensus, something is wrong
        if headerStoreHeight > 0 && headerStoreHeight > consensusHeight + maxHeightDeviation {
            print("🚨 [FIX #167] SECURITY: Fake headers detected (store: \(headerStoreHeight), consensus: \(consensusHeight)) - clearing")
            try? HeaderStore.shared.clearAllHeaders()
        }

        // If consensus is way ahead of HeaderStore, that's NORMAL during initial sync
        // Only warn if HeaderStore was recently synced (within last 1000 blocks of cached height)
        let cachedHeight = UInt64(UserDefaults.standard.integer(forKey: "cachedChainHeight"))
        let headerStoreRecentlySynced = headerStoreHeight > 0 && cachedHeight > 0 && headerStoreHeight > cachedHeight - 1000

        if headerStoreRecentlySynced && consensusHeight > headerStoreHeight + maxHeightDeviation {
            print("⚠️ [FIX #167] HeaderStore behind consensus by \(consensusHeight - headerStoreHeight) blocks - will sync headers")
            // Don't reject consensus - headers will sync in background
        }

        // Update cached chain height for future validation
        UserDefaults.standard.set(Int(consensusHeight), forKey: "cachedChainHeight")

        return consensusHeight
    }

    private func deriveIncomingViewingKey(from viewingKey: Data) -> Data {
        // The viewingKey passed in is actually the full viewing key data
        // We need to derive the IVK properly using the FFI
        // If viewingKey is 169 bytes, it's the spending key - derive IVK from it
        if viewingKey.count == 169 {
            if let ivk = ZipherXFFI.deriveIVK(from: viewingKey) {
                return ivk
            }
        }
        // Fallback: extract first 32 bytes (this may not work correctly)
        return Data(viewingKey.prefix(32))
    }

    private func getWitness(for cmu: Data, at height: UInt64) async throws -> Data {
        // Legacy placeholder - real witnesses are now generated via commitment tree
        // This is kept for processCompactBlock compatibility
        return Data(count: 1028) // Real witness size: 4 + 32*32
    }

    // MARK: - P2P Block Data Fetching

    /// Track if P2P block fetching is working (to avoid repeated failures)
    /// IMPORTANT: Default to false until P2P transaction parsing is verified working
    /// The P2P block parsing currently returns empty transactions even for blocks with shielded tx
    private static var p2pBlockFetchingWorks: Bool? = false

    /// Reset P2P status to re-test on next scan
    static func resetP2PStatus() {
        p2pBlockFetchingWorks = nil
        debugLog(.network, "P2P status reset")
    }

    /// Test P2P block fetching by requesting a single recent block
    private func testP2PBlockFetching() async -> Bool {
        let isConnected = await MainActor.run { networkManager.isConnected }
        guard isConnected else { return false }

        // Try to fetch a recent block via P2P
        guard let latestHeight = try? HeaderStore.shared.getLatestHeight(),
              let header = try? HeaderStore.shared.getHeader(at: latestHeight) else {
            return false
        }

        do {
            // FIX #384: Use PeerManager for centralized peer access
            let maybePeer: Peer? = await MainActor.run { PeerManager.shared.getBestPeer() }
            guard let peer = maybePeer else { return false }
            let block = try await peer.getBlockByHash(hash: header.blockHash)
            debugLog(.network, "P2P test: OK (\(block.transactions.count) txs @ \(latestHeight))")
            return true
        } catch {
            debugLog(.error, "P2P test failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Fetch block data for scanning - P2P ONLY (FIX #896: removed InsightAPI)
    /// Returns: [(txid, [ShieldedOutput], [ShieldedSpend]?)]
    private func fetchBlockData(height: UInt64) async throws -> [(String, [ShieldedOutput], [ShieldedSpend]?)] {
        // FIX #896: P2P only - no InsightAPI fallback (cypherpunk wallet)
        let isConnectedForP2P = await MainActor.run { networkManager.isConnected }
        guard isConnectedForP2P else {
            throw ScanError.networkError
        }

        let (_, txData) = try await networkManager.getBlockDataP2P(height: height)
        FilterScanner.p2pBlockFetchingWorks = true
        return txData
    }

    /// Fetch multiple blocks' data for scanning - P2P ONLY (FIX #896: removed InsightAPI)
    /// Returns: [(height, [(txid, [ShieldedOutput], [ShieldedSpend]?)])]
    /// - Parameter skipPreReconnect: If true, skip P2P pre-reconnection (already done at caller level via FIX #1071)
    private func fetchBlocksData(heights: [UInt64], skipPreReconnect: Bool = false) async throws -> [(UInt64, [(String, [ShieldedOutput], [ShieldedSpend]?)])] {
        // FIX #896: P2P only - no InsightAPI fallback (cypherpunk wallet)
        let isConnected = await MainActor.run { networkManager.isConnected }
        guard isConnected && !heights.isEmpty else {
            throw ScanError.networkError
        }

        let startHeight = heights.min()!
        let count = heights.count
        // FIX #1071: Pass skipPreReconnect to avoid redundant reconnection when called from parallel batches
        let results = try await networkManager.getBlocksDataP2P(from: startHeight, count: count, skipPreReconnect: skipPreReconnect)

        var blockData: [(UInt64, [(String, [ShieldedOutput], [ShieldedSpend]?)])] = []
        for (h, _, timestamp, txData) in results {
            blockData.append((h, txData))
            // Cache real block timestamps for transaction history
            BlockTimestampManager.shared.cacheTimestamp(height: h, timestamp: timestamp)
        }

        FilterScanner.p2pBlockFetchingWorks = true
        return blockData
    }

    // MARK: - Witness Pre-computation

    /// Pre-compute witnesses for notes discovered during PHASE 1 (bundled range)
    /// This runs after parallel scanning to prepare witnesses for spending
    private func computeWitnessesForBundledNotes(bundledData: Data) async {
        reportPhase15Progress(0.0, current: 0, total: 1)

        do {
            guard let account = try database.getAccount(index: 0) else {
                reportPhase15Progress(1.0, current: 0, total: 0)
                return
            }

            let notes = try database.getAllUnspentNotes(accountId: account.accountId)
            // FIX #1107: Changed from != 1028 to < 100
            let notesNeedingWitness = notes.filter { note in
                note.witness.count < 100 || note.witness.allSatisfy { $0 == 0 }
            }

            if notesNeedingWitness.isEmpty {
                reportPhase15Progress(1.0, current: 0, total: 0)
                return
            }

            if verbose {
                print("🔧 PHASE 1.5: \(notesNeedingWitness.count) witnesses to compute")
            }
            reportPhase15Progress(0.05, current: 0, total: notesNeedingWitness.count)

            // FIX #1109: Clear WITNESSES array before creating new witnesses
            // Without this, witnesses accumulate across rebuild cycles
            let clearedCount = ZipherXFFI.witnessesClear()
            if clearedCount > 0 {
                if verbose {
                    print("🧹 FIX #1109: Cleared \(clearedCount) stale witnesses from FFI array")
                }
            }

            for (index, note) in notesNeedingWitness.enumerated() {
                guard let cmu = note.cmu, cmu.count == 32 else { continue }

                if let result = ZipherXFFI.treeCreateWitnessForCMU(cmuData: bundledData, targetCMU: cmu) {
                    try database.updateNoteWitness(noteId: note.id, witness: result.witness)
                    // FIX #804: Use witness root as anchor (what the merkle path computes to)
                    if let anchor = ZipherXFFI.witnessGetRoot(result.witness) {
                        try database.updateNoteAnchor(noteId: note.id, anchor: anchor)
                    }
                }

                let progress = 0.1 + 0.85 * (Double(index + 1) / Double(notesNeedingWitness.count))
                reportPhase15Progress(progress, current: index + 1, total: notesNeedingWitness.count)
                await Task.yield()
            }

            reportPhase15Progress(1.0, current: notesNeedingWitness.count, total: notesNeedingWitness.count)
            print("✅ PHASE 1.5 complete")

        } catch {
            debugLog(.error, "PHASE 1.5 error: \(error)")
        }
    }

    /// FIX #197: Pre-compute witnesses using COMBINED tree load + witness creation
    /// This eliminates PHASE 1.5 bottleneck by loading tree AND creating witnesses in SINGLE pass
    /// Previous approach: Load tree (15s) + rebuild tree for witnesses (56s) = 71s
    /// New approach: Load tree with witnesses (15-20s) = 3-4x faster
    private func computeWitnessesForBundledNotesBatch(bundledData: Data) async {
        reportPhase15Progress(0.0, current: 0, total: 1)

        do {
            guard let account = try database.getAccount(index: 0) else {
                reportPhase15Progress(1.0, current: 0, total: 0)
                return
            }

            let notes = try database.getAllUnspentNotes(accountId: account.accountId)
            // FIX #1107: Changed from != 1028 to < 100
            let notesNeedingWitness = notes.filter { note in
                note.witness.count < 100 || note.witness.allSatisfy { $0 == 0 }
            }

            if notesNeedingWitness.isEmpty {
                reportPhase15Progress(1.0, current: 0, total: 0)
                return
            }

            // Collect all CMUs that need witnesses
            // FIX #793: Also track note height for HeaderStore anchor lookup
            var targetCMUs: [Data] = []
            var noteIdMap: [Int: Int64] = [:]
            var noteHeightMap: [Int: UInt64] = [:]  // FIX #793

            for note in notesNeedingWitness {
                guard let cmu = note.cmu, cmu.count == 32 else { continue }
                targetCMUs.append(cmu)
                let idx = targetCMUs.count - 1
                noteIdMap[idx] = note.id
                noteHeightMap[idx] = note.height  // FIX #793
            }

            guard !targetCMUs.isEmpty else {
                reportPhase15Progress(1.0, current: 0, total: 0)
                return
            }

            if verbose {
                print("🔧 FIX #197 PHASE 1.5: Computing \(targetCMUs.count) witnesses (combined load+witness)")
            }
            onStatusUpdate?("phase1.5", "Loading tree + \(targetCMUs.count) witnesses...")
            reportPhase15Progress(0.05, current: 0, total: 1)
            let startTime = Date()

            // FIX #469: Verify CMU cache matches current tree size before witness creation
            // The tree size (number of CMUs) should match the CMU count from the boost file
            // Note: cmuDataHeight is block height, cmuDataCount is number of CMUs
            var actualBundledData = bundledData
            let currentTreeSize = ZipherXFFI.treeSize()
            // Only invalidate if we have CMU data loaded but the count doesn't match
            if cmuDataCount > 0 && cmuDataCount != currentTreeSize {
                print("⚠️ FIX #469: CMU cache size mismatch (cache has \(cmuDataCount) CMUs, tree has \(currentTreeSize)) - invalidating cache...")
                await CommitmentTreeUpdater.shared.invalidateCMUCachePublic()
                // Reload CMU data
                if let newCmuPath = await CommitmentTreeUpdater.shared.getCachedCMUFilePath(),
                   let newCmuData = try? Data(contentsOf: newCmuPath) {
                    actualBundledData = newCmuData
                    print("✅ FIX #469: Reloaded fresh CMU data (\(newCmuData.count) bytes)")
                }
            }

            // FIX #197: Use COMBINED tree load + witness creation
            // This loads tree into global FFI memory AND creates witnesses in single pass
            // Much faster than separate load + batch witness (56s → 15-20s)
            let witnessCount = UInt64(targetCMUs.count)
            let results = ZipherXFFI.treeLoadWithWitnesses(
                data: actualBundledData,
                targetCMUs: targetCMUs,
                onProgress: { [weak self] current, total in
                    let progress = 0.05 + 0.85 * (Double(current) / Double(max(total, 1)))
                    // FIX #467: Show witness count in status, but use CMU progress for percentage
                    // If total equals witnessCount, this is witness update progress
                    // Otherwise it's tree building progress (CMU count)
                    let displayCurrent = total == witnessCount ? current : witnessCount
                    let displayTotal = total == witnessCount ? total : witnessCount
                    self?.reportPhase15Progress(progress, current: Int(displayCurrent), total: Int(displayTotal))
                }
            )

            let elapsed = Date().timeIntervalSince(startTime)
            reportPhase15Progress(0.95, current: targetCMUs.count, total: targetCMUs.count)

            // Update database with computed witnesses AND anchors
            // FIX #197: treeLoadWithWitnesses stores tree in GLOBAL memory, so witnesses
            // match the global tree's anchor. Extract anchor from witness for INSTANT mode.
            // FIX #804: REVERTS FIX #793 - Use WITNESS ROOT as anchor, not HeaderStore at note height!
            // The witness merkle path computes to the TREE ROOT at witness creation time (boost file).
            // Storing HeaderStore root at note height causes anchor mismatch because:
            //   - Note was received at height X (with tree root A)
            //   - Witness was created at boost file height Y (with tree root B)
            //   - FIX #793 stored root A, but witness path computes root B → MISMATCH!
            // The correct anchor is the witness root (what the path actually computes to).
            var successCount = 0
            for (index, result) in results.enumerated() {
                guard let noteId = noteIdMap[index] else { continue }
                if let (_, witness) = result {
                    try database.updateNoteWitness(noteId: noteId, witness: witness)
                    // FIX #804: Use witness root as anchor (what the merkle path computes to)
                    if let anchor = ZipherXFFI.witnessGetRoot(witness) {
                        try database.updateNoteAnchor(noteId: noteId, anchor: anchor)
                    }
                    successCount += 1
                }
            }

            reportPhase15Progress(1.0, current: successCount, total: targetCMUs.count)
            if verbose {
                print("✅ FIX #197 PHASE 1.5: \(successCount)/\(targetCMUs.count) witnesses in \(String(format: "%.1f", elapsed))s (3-4x faster!)")
            }

            // FIX #469: If witness creation failed completely, invalidate CMU cache and retry
            // This handles the case where cached CMU file doesn't match database notes
            if successCount == 0 && targetCMUs.count > 0 {
                print("⚠️ FIX #469: Witness creation failed - invalidating stale CMU cache and retrying...")
                let treeUpdater = CommitmentTreeUpdater.shared
                await treeUpdater.invalidateCMUCachePublic()

                // Try to reload CMU data
                if let newCmuPath = await CommitmentTreeUpdater.shared.getCachedCMUFilePath(),
                   let newCmuData = try? Data(contentsOf: newCmuPath) {
                    print("🔄 FIX #469: Retrying witness creation with fresh CMU data...")
                    let retryResults = ZipherXFFI.treeLoadWithWitnesses(
                        data: newCmuData,
                        targetCMUs: targetCMUs,
                        onProgress: { [weak self] current, total in
                            self?.reportPhase15Progress(0.95, current: Int(current), total: Int(total))
                        }
                    )

                    var retrySuccessCount = 0
                    for (index, result) in retryResults.enumerated() {
                        guard let noteId = noteIdMap[index] else { continue }
                        if let (_, witness) = result {
                            try database.updateNoteWitness(noteId: noteId, witness: witness)
                            // FIX #804: Use witness root as anchor (what the merkle path computes to)
                            if let anchor = ZipherXFFI.witnessGetRoot(witness) {
                                try database.updateNoteAnchor(noteId: noteId, anchor: anchor)
                            }
                            retrySuccessCount += 1
                        }
                    }

                    if retrySuccessCount > 0 {
                        print("✅ FIX #469: Retry succeeded - \(retrySuccessCount)/\(targetCMUs.count) witnesses created")
                        reportPhase15Progress(1.0, current: retrySuccessCount, total: targetCMUs.count)
                    } else {
                        print("❌ FIX #469: Retry also failed - CMUs may not be in bundled data")
                    }
                }
            }

        } catch {
            debugLog(.error, "FIX #197 PHASE 1.5 error: \(error)")
            reportPhase15Progress(1.0, current: 0, total: 0)
        }
    }

    // MARK: - FIX #528: Legacy CMU Tree Loading

    /// FIX #528: Load tree from legacy CMU file when deserialization fails
    /// This is a fallback when the serialized tree format is incompatible
    /// - Parameter boostHeight: Height from boost file (to set cmuDataHeight)
    /// - Parameter boostOutputCount: Output count from boost file (to set cmuDataCount)
    /// - Returns: true if tree was loaded successfully
    private func loadTreeFromLegacyCMUs(boostHeight: UInt64, boostOutputCount: UInt64) async -> Bool {
        print("🔧 FIX #528: Loading tree from legacy CMU file...")

        // Get legacy CMU file path
        guard let cmuPath = await CommitmentTreeUpdater.shared.getCachedCMUFilePath() else {
            print("❌ FIX #528: No cached CMU file available")
            return false
        }

        // Load CMU data
        guard let cmuData = try? Data(contentsOf: cmuPath) else {
            print("❌ FIX #528: Failed to load CMU file")
            return false
        }

        print("🔧 FIX #528: Loaded \(cmuData.count) bytes of CMU data")

        // Initialize tree
        _ = ZipherXFFI.treeInit()

        // Load tree from CMUs (this builds the tree from scratch)
        let loaded = ZipherXFFI.treeLoadFromCMUs(data: cmuData)

        if loaded {
            let treeSize = ZipherXFFI.treeSize()
            print("✅ FIX #528: Tree loaded from legacy CMUs: \(treeSize) commitments")

            // Set metadata for position lookup
            self.cmuDataHeight = boostHeight
            self.cmuDataCount = boostOutputCount
            self.cmuDataForPositionLookup = cmuData

            // Save tree state for future use
            // FIX #1138: Save tree state WITH HEIGHT
            if let treeData = ZipherXFFI.treeSerialize() {
                try? WalletDatabase.shared.saveTreeState(treeData, height: boostHeight)
                print("✅ FIX #528+1138: Saved tree state at height \(boostHeight)")
            }

            return true
        } else {
            print("❌ FIX #528: Failed to load tree from CMUs")
            return false
        }
    }
}

// MARK: - ZIP-307 Compact Block Types

/// Compact block containing only shielded transaction data
struct CompactBlock: Hashable {
    let blockHeight: UInt64
    let blockHash: Data
    let prevHash: Data
    let finalSaplingRoot: Data  // The anchor! (32 bytes)
    let time: UInt32
    let transactions: [CompactTx]
}

/// Compact transaction with spends and outputs
struct CompactTx: Hashable {
    let txIndex: UInt64
    let txHash: Data
    let spends: [CompactSpend]
    let outputs: [CompactOutput]
}

/// Nullifier for spend detection
struct CompactSpend: Hashable {
    let nullifier: Data  // 32 bytes
}

/// Encrypted output for trial decryption
struct CompactOutput: Hashable {
    let cmu: Data        // Note commitment (32 bytes)
    let epk: Data        // Ephemeral public key (32 bytes)
    let ciphertext: Data // Encrypted note plaintext (~580 bytes)
}


// MARK: - Errors

enum ScanError: LocalizedError {
    case networkError
    case decodingError
    case databaseError
    case boostFileMissing
    case decryptionFailed

    var errorDescription: String? {
        switch self {
        case .networkError:
            return "Network error during scan"
        case .decodingError:
            return "Failed to decode filter or block"
        case .databaseError:
            return "Database error during scan"
        case .boostFileMissing:
            return "Boost file not available"
        case .decryptionFailed:
            return "Note decryption failed"
        }
    }
}

