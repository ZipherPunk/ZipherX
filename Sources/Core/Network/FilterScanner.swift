import Foundation

/// Compact Block Scanner for Zclassic (ZIP-307)
/// Uses trial decryption to find shielded transactions - preserves privacy
final class FilterScanner {

    private let networkManager: NetworkManager
    private let database: WalletDatabase
    private let rustBridge: RustBridge
    private let insightAPI: InsightAPI

    // P2P-Only Mode: When true, uses P2P network exclusively (no InsightAPI)
    // When false (default), tries P2P first then falls back to InsightAPI
    // Reads from UserDefaults - can be changed in Settings
    var useP2POnly: Bool = UserDefaults.standard.bool(forKey: "useP2POnly")

    // Scanning parameters
    private let batchSize = 500 // Larger batches for faster sync
    private var isScanning = false
    private var scanTask: Task<Void, Never>?

    // SECURITY: Thread-safe lock to prevent concurrent scans across all instances
    private static let globalScanLock = NSLock()
    private static var _isScanningFlag = false

    /// Check if any scan is currently in progress (thread-safe)
    static var isScanInProgress: Bool {
        globalScanLock.lock()
        defer { globalScanLock.unlock() }
        return _isScanningFlag
    }

    /// Thread-safe setter for scan flag
    private static func setScanInProgress(_ value: Bool) {
        globalScanLock.lock()
        _isScanningFlag = value
        globalScanLock.unlock()
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

    // MARK: - Progress Helpers

    /// Map phase-local progress (0-1) to overall progress within that phase's range
    private func mapProgress(_ localProgress: Double, in range: ClosedRange<Double>) -> Double {
        let rangeSize = range.upperBound - range.lowerBound
        return range.lowerBound + (localProgress * rangeSize)
    }

    /// Report progress for PHASE 1 (parallel note discovery)
    private func reportPhase1Progress(_ localProgress: Double, height: UInt64, maxHeight: UInt64) {
        let overall = mapProgress(localProgress, in: phase1ProgressRange)
        onProgress?(overall, height, maxHeight)
        if localProgress < 0.01 {
            onStatusUpdate?("phase1", "Decrypting shielded notes (parallel)...")
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
        if localProgress < 0.01 {
            onStatusUpdate?("phase2", "Building commitment tree...")
        }
    }

    init(networkManager: NetworkManager = .shared,
         database: WalletDatabase = .shared,
         rustBridge: RustBridge = .shared,
         insightAPI: InsightAPI = .shared) {
        self.networkManager = networkManager
        self.database = database
        self.rustBridge = rustBridge
        self.insightAPI = insightAPI
    }

    // MARK: - Scanning

    /// Start scanning for transactions
    /// - Parameters:
    ///   - accountId: Account to scan for
    ///   - viewingKey: Spending key (used as viewing key)
    ///   - fromHeight: Optional custom start height (for quick scan)
    func startScan(for accountId: Int64, viewingKey: Data, fromHeight customStartHeight: UInt64? = nil) async throws {
        // SECURITY: Thread-safe check and acquisition of global lock
        guard !isScanning && !FilterScanner.isScanInProgress else {
            print("⚠️ Scan already in progress, skipping")
            return
        }

        isScanning = true
        FilterScanner.setScanInProgress(true)
        defer {
            isScanning = false
            FilterScanner.setScanInProgress(false)
        }

        // Get current chain height
        guard let latestHeight = try? await getChainHeight() else {
            print("❌ Failed to get chain height")
            throw ScanError.networkError
        }
        currentChainHeight = latestHeight

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
        if FilterScanner.p2pBlockFetchingWorks == nil {
            let p2pWorks = await testP2PBlockFetching()
            FilterScanner.p2pBlockFetchingWorks = p2pWorks
            if !p2pWorks && useP2POnly {
                print("❌ P2P-only mode enabled but P2P block fetch failed!")
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

            if lastScanned > 0 {
                startHeight = lastScanned + 1
            } else if isImportedWallet {
                if let customHeight = customScanHeight, customHeight > ZclassicCheckpoints.saplingActivationHeight {
                    startHeight = customHeight
                } else {
                    startHeight = ZclassicCheckpoints.saplingActivationHeight
                }
                scanWithinDownloadedRange = true

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
                isNewWalletInitialSync = true
            } else {
                // No tree downloaded yet - must download first
                startHeight = ZclassicCheckpoints.saplingActivationHeight
            }
        }

        // If startHeight > latestHeight, refresh height
        if startHeight > latestHeight {
            if let apiHeight = try? await insightAPI.getStatus().height, apiHeight >= startHeight {
                currentChainHeight = apiHeight
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

        // Only force fresh tree if:
        // 1. Custom height provided AND starting exactly from effective+1 (rescan scenario)
        // 2. AND tree doesn't already have progress (hasn't appended CMUs beyond effective)
        let needsFreshTree = customStartHeight != nil
            && customStartHeight! == effectiveTreeHeight + 1
            && !treeHasProgress

        // Wait for WalletManager to finish loading tree before proceeding
        if !needsFreshTree {
            let walletManager = WalletManager.shared
            var waitAttempts = 0
            let maxWaitAttempts = 1200 // 120 seconds max wait
            while !walletManager.isTreeLoaded && waitAttempts < maxWaitAttempts {
                try await Task.sleep(nanoseconds: 100_000_000) // 100ms
                waitAttempts += 1
            }
        }

        // CRITICAL: Check if tree is already loaded in FFI memory (WalletManager may have loaded it)
        // This prevents race condition where FilterScanner loads again while WalletManager is loading
        let existingTreeSize = ZipherXFFI.treeSize()

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

                        if let treeData = ZipherXFFI.treeSerialize() {
                            try? database.saveTreeState(treeData)
                        }
                    }
                } catch {
                    print("⚠️ Failed to extract serialized tree: \(error)")
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

                        if let treeData = ZipherXFFI.treeSerialize() {
                            try? database.saveTreeState(treeData)
                        }
                    }
                } catch {
                    print("❌ Failed to extract tree from boost file: \(error)")
                    treeInitialized = false
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
            if note.witness.count >= 1028 {
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

        if scanWithinDownloadedRange && startHeight <= phase1EndHeight {
            let parallelEndHeight = min(phase1EndHeight, targetHeight)
            print("⚡ PHASE 1: \(startHeight) → \(parallelEndHeight) (\(parallelEndHeight - startHeight + 1) blocks)")
            let parallelTotalBlocks = parallelEndHeight - startHeight + 1
            var parallelScannedBlocks: UInt64 = 0
            let batchSize = 500 // Larger batches for P2P batch fetching

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
                        self.onStatusUpdate?("phase1", detail)
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
                        self.reportPhase1Progress(subProgress, height: self.currentChainHeight, maxHeight: targetHeight)
                    }
                    print("🦀 Rust scan complete: \(result.notesFound) notes, \(result.notesSpent) spent, balance: \(Double(result.balance) / 100_000_000) ZCL")
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
                    // PRIORITY 2: Network fetch (P2P or InsightAPI)
                    do {
                        // Try P2P batch fetch first
                        if FilterScanner.p2pBlockFetchingWorks != false && networkManager.isConnected {
                            let results = try await networkManager.getBlocksDataP2P(from: currentHeight, count: thisBatchSize)
                            for (height, _, timestamp, txData) in results {
                                blockDataMap[height] = txData
                                // Cache real block timestamps for transaction history
                                BlockTimestampManager.shared.cacheTimestamp(height: height, timestamp: timestamp)
                            }
                            FilterScanner.p2pBlockFetchingWorks = true
                        } else {
                            throw ScanError.networkError
                        }
                    } catch {
                        // Fallback to InsightAPI with parallel fetching
                        if !useP2POnly {
                            await withTaskGroup(of: (UInt64, [(String, [ShieldedOutput], [ShieldedSpend]?)]?).self) { group in
                                for height in currentHeight...endHeight {
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
                currentHeight = endHeight + 1
            }

            print("✅ PHASE 1 complete: \(knownNullifiers.count) notes, \(collectedSpends.count) spends")

            // PHASE 1.5: Pre-compute witnesses using PARALLEL function (Rayon multi-threaded)
            // This computes all witnesses in ~78 seconds using all CPU cores
            if let bundledData = cmuDataForPositionLookup {
                await computeWitnessesForBundledNotesBatch(bundledData: bundledData)

                // CRITICAL: After PHASE 1.5, load the computed witnesses into FFI global tree
                // so they get auto-updated during PHASE 2 CMU appends.
                // This ensures all notes end up with the SAME anchor (enabling INSTANT mode).
                do {
                    guard let account = try database.getAccount(index: 0) else { throw ScanError.databaseError }
                    let phase1Notes = try database.getAllUnspentNotes(accountId: account.id)
                    var loadedCount = 0
                    for note in phase1Notes {
                        // Only load valid witnesses (1028 bytes, not all zeros)
                        if note.witness.count >= 1028 && !note.witness.allSatisfy({ $0 == 0 }) {
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
                    if knownNullifiers.contains(nullifierWire) {
                        let txidData = Data(hexString: txid)
                        if let txidData = txidData {
                            try? database.markNoteSpent(nullifier: nullifierWire, txid: txidData, spentHeight: height)
                        } else {
                            try? database.markNoteSpent(nullifier: nullifierWire, spentHeight: height)
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
            if let treeData = ZipherXFFI.treeSerialize() {
                try? database.saveTreeState(treeData)
            }
            print("💾 PHASE 1 checkpoint saved at height \(phase1EndHeight)")

            // Move to blocks after CMU data height for PHASE 2
            // Use phase1EndHeight (which is cmuDataHeight from GitHub if available)
            // PHASE 2 only needs to scan blocks beyond what we have CMU data for
            currentHeight = phase1EndHeight + 1
        }

        // PHASE 2: Continue scanning blocks after bundled tree (tree building mode)
        // This runs if:
        // - We did PHASE 1 and there are more blocks after phase1EndHeight
        // - OR no custom start height was provided (normal auto-scan)
        // - OR custom start height is AFTER CMU data height (must use sequential for correct positions)
        let continueAfterBundledRange = scanWithinDownloadedRange && currentHeight <= targetHeight

        // Quick scan is ONLY safe when scanning WITHIN CMU data range where positions are known
        // If starting AFTER CMU data, we MUST use sequential mode for correct nullifier computation
        let isQuickScanOnly = customStartHeight != nil && !scanWithinDownloadedRange && customStartHeight! <= phase1EndHeight

        // If custom start is AFTER CMU data height, force sequential mode
        let forceSequentialAfterBundled = customStartHeight != nil && customStartHeight! > phase1EndHeight

        if continueAfterBundledRange || forceSequentialAfterBundled {
            print("⚡ PHASE 2: \(currentHeight) → \(targetHeight) (\(targetHeight - currentHeight + 1) blocks)")
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
                currentHeight = endHeight + 1
            }
        } else if !isQuickScanOnly || continueAfterBundledRange || forceSequentialAfterBundled {
            // SEQUENTIAL MODE with PRE-FETCH PIPELINE for ~40% speed improvement
            // Tree building must be sequential, but network I/O can overlap with processing
            //
            // Pipeline: While processing batch N, pre-fetch batch N+1 in background
            // This hides network latency during tree processing time
            //
            // P2P-FIRST: Uses P2P network with InsightAPI fallback (unless useP2POnly is true)

            print("🔧 PHASE 2: Building commitment tree (sequential mode)...")
            onStatusUpdate?("phase2", "Building commitment tree...")
            reportPhase2Progress(0.0, height: currentHeight, maxHeight: targetHeight)

            // DELTA BUNDLE: Enable collection for outputs AFTER the bundled/downloaded range
            // These outputs will be saved locally for instant witness generation
            let bundledEndHeight = cmuDataHeight > 0 ? cmuDataHeight : ZipherXConstants.bundledTreeHeight
            if currentHeight > bundledEndHeight {
                deltaCollectionEnabled = true
                // SMART START: Continue from existing delta if valid, otherwise from boost end
                if let manifest = DeltaCMUManager.shared.getManifest(), manifest.endHeight >= bundledEndHeight {
                    // Delta exists and is valid - continue from where it left off
                    deltaCollectionStartHeight = manifest.endHeight + 1
                    print("📦 DeltaCMU: Continuing from existing delta (height \(manifest.endHeight) → \(currentHeight))")
                } else {
                    // No delta or invalid - start fresh from boost end
                    deltaCollectionStartHeight = bundledEndHeight + 1
                    print("📦 DeltaCMU: Starting fresh from boost end (height \(bundledEndHeight + 1))")
                }
                deltaOutputsCollected.removeAll()

                // Update delta sync status to syncing
                await MainActor.run {
                    WalletManager.shared.updateDeltaSyncStatus(.syncing)
                }
            }

            // Pre-fetch task for next batch (runs in background)
            var nextBatchTask: Task<[(UInt64, [(String, [ShieldedOutput], [ShieldedSpend]?)])], Error>? = nil

            while currentHeight <= targetHeight && isScanning {
                let endHeight = min(currentHeight + UInt64(batchSize) - 1, targetHeight)
                let heights = Array(currentHeight...endHeight)

                // Get current batch data (from pre-fetch or fetch now)
                // Use 60-second timeout to prevent hanging on unresponsive P2P peers
                var blockData: [(UInt64, [(String, [ShieldedOutput], [ShieldedSpend]?)])] = []
                do {
                    if let prefetchTask = nextBatchTask {
                        blockData = try await withTimeout(seconds: 60) {
                            try await prefetchTask.value
                        }
                        nextBatchTask = nil
                    } else {
                        blockData = try await withTimeout(seconds: 60) {
                            try await self.fetchBlocksData(heights: heights.map { UInt64($0) })
                        }
                    }
                } catch {
                    debugLog(.error, "Failed to fetch blocks \(currentHeight)-\(endHeight): \(error)")
                    if useP2POnly {
                        throw error
                    }
                    // In fallback mode, continue with empty data for this batch
                    // Cancel the pre-fetch task to prevent resource leak
                    nextBatchTask?.cancel()
                    nextBatchTask = nil
                    currentHeight = endHeight + 1
                    continue
                }

                // Start pre-fetching NEXT batch while we process current batch
                let nextStart = endHeight + 1
                if nextStart <= targetHeight && isScanning {
                    let nextEnd = min(nextStart + UInt64(batchSize) - 1, targetHeight)
                    let nextHeights = Array(nextStart...nextEnd).map { UInt64($0) }
                    nextBatchTask = Task { [self] in
                        try await self.fetchBlocksData(heights: nextHeights)
                    }
                }

                // Sort by height for sequential tree processing
                blockData.sort { $0.0 < $1.0 }

                // Process sequentially (data already fetched, network I/O happening in background for next batch)
                for (height, txList) in blockData {
                    guard isScanning else { break }

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
                                        height: height
                                    )
                                }
                            } catch {
                                print("⚠️ Error processing tx \(txid): \(error)")
                            }
                        }
                    }

                    scannedBlocks += 1
                    // Report PHASE 2 progress (60-100%) every 10 blocks for better UI feedback
                    // CHECKPOINT: Save every 10 blocks to minimize data loss on crash
                    if scannedBlocks % 10 == 0 || scannedBlocks == 1 {
                        let localProgress = Double(scannedBlocks) / Double(totalBlocks)
                        reportPhase2Progress(localProgress, height: height, maxHeight: targetHeight)

                        // Save checkpoint every 10 blocks
                        try? database.updateLastScannedHeight(height, hash: Data(count: 32))
                        if let treeData = ZipherXFFI.treeSerialize() {
                            try? database.saveTreeState(treeData)
                        }
                    }
                }

                // Save progress at end of batch (for any remaining blocks not divisible by 10)
                try? database.updateLastScannedHeight(endHeight, hash: Data(count: 32))

                // Persist tree state at end of batch
                if let treeData = ZipherXFFI.treeSerialize() {
                    try? database.saveTreeState(treeData)
                }


                currentHeight = endHeight + 1
            }

            // Cancel any remaining pre-fetch task if scan was stopped
            nextBatchTask?.cancel()
        }

        // Final tree persistence
        if let treeData = ZipherXFFI.treeSerialize() {
            try? database.saveTreeState(treeData)
            let treeSize = ZipherXFFI.treeSize()
            print("🌳 Saved commitment tree with \(treeSize) commitments")
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

        // Get current tree root (anchor) to save with witnesses
        let currentAnchor = ZipherXFFI.treeRoot() ?? Data()

        // Calculate total witnesses to update
        let totalWitnesses = existingWitnessIndices.count + pendingWitnesses.count
        var witnessesUpdated = 0

        // Report witness sync starting
        if totalWitnesses > 0 {
            onWitnessProgress?(0, totalWitnesses, "Syncing \(totalWitnesses) witness(es)...")
        }

        // Update existing notes' witnesses and anchors
        // CRITICAL FIX: Use header store anchor (blockchain's finalSaplingRoot) for each note,
        // NOT the end-of-scan tree root! The header anchor is the canonical blockchain state.
        let headerStore = HeaderStore.shared
        try? headerStore.open()

        for (noteId, witnessIndex) in existingWitnessIndices {
            if let witnessData = ZipherXFFI.treeGetWitness(index: witnessIndex) {
                try? database.updateNoteWitness(noteId: noteId, witness: witnessData)

                // Get anchor from witness itself (most accurate - matches witness state)
                if let witnessAnchor = ZipherXFFI.witnessGetRoot(witnessData) {
                    try? database.updateNoteAnchor(noteId: noteId, anchor: witnessAnchor)
                } else {
                    // Fallback: use current tree root
                    try? database.updateNoteAnchor(noteId: noteId, anchor: currentAnchor)
                }
                witnessesUpdated += 1
                onWitnessProgress?(witnessesUpdated, totalWitnesses, "Witness \(witnessesUpdated)/\(totalWitnesses)")
            }
        }

        // Update new notes' witnesses and anchors (discovered during this scan)
        for (noteId, witnessIndex) in pendingWitnesses {
            if let witnessData = ZipherXFFI.treeGetWitness(index: witnessIndex) {
                try? database.updateNoteWitness(noteId: noteId, witness: witnessData)

                // Get anchor from witness itself (most accurate - matches witness state)
                if let witnessAnchor = ZipherXFFI.witnessGetRoot(witnessData) {
                    try? database.updateNoteAnchor(noteId: noteId, anchor: witnessAnchor)
                } else {
                    // Fallback: use current tree root
                    try? database.updateNoteAnchor(noteId: noteId, anchor: currentAnchor)
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

        // Save tree checkpoint after scan completes
        await saveTreeCheckpointAfterSync()

        // DELTA BUNDLE: Save collected outputs for instant witness generation
        if deltaCollectionEnabled && !deltaOutputsCollected.isEmpty {
            if let treeRoot = ZipherXFFI.treeRoot() {
                let lastScanned = (try? database.getLastScannedHeight()) ?? targetHeight
                DeltaCMUManager.shared.appendOutputs(
                    deltaOutputsCollected,
                    fromHeight: deltaCollectionStartHeight,  // Track the full scanned range!
                    toHeight: lastScanned,
                    treeRoot: treeRoot
                )
                print("📦 DeltaCMU: Saved \(deltaOutputsCollected.count) outputs to delta bundle (height \(deltaCollectionStartHeight)-\(lastScanned))")

                // Update delta sync status to synced
                await MainActor.run {
                    WalletManager.shared.updateDeltaSyncStatus(.synced)
                }
            }
            deltaOutputsCollected.removeAll()
            deltaCollectionEnabled = false
        } else if deltaCollectionEnabled {
            // No outputs collected but delta collection was enabled
            // Still need to update manifest height so system knows we've scanned these blocks
            if let treeRoot = ZipherXFFI.treeRoot() {
                let lastScanned = (try? database.getLastScannedHeight()) ?? targetHeight
                DeltaCMUManager.shared.appendOutputs(
                    [],  // Empty outputs
                    fromHeight: deltaCollectionStartHeight,  // Track the full scanned range!
                    toHeight: lastScanned,
                    treeRoot: treeRoot
                )
                print("📦 DeltaCMU: Updated manifest to height \(deltaCollectionStartHeight)-\(lastScanned) (no new outputs)")
            }
            await MainActor.run {
                WalletManager.shared.updateDeltaSyncStatus(.synced)
            }
            deltaCollectionEnabled = false
        }

        print("✅ Scan complete")
    }

    /// Save a tree checkpoint after sync completes
    /// This ensures we have a verified tree state for reliable transaction building
    private func saveTreeCheckpointAfterSync() async {
        do {
            // Get current tree state
            guard let treeSerialized = ZipherXFFI.treeSerialize() else {
                print("⚠️ Cannot save checkpoint - tree not serialized")
                return
            }

            let treeSize = ZipherXFFI.treeSize()
            guard treeSize > 0 else {
                print("⚠️ Cannot save checkpoint - tree is empty")
                return
            }

            // Get the tree root
            guard let treeRoot = ZipherXFFI.treeRoot() else {
                print("⚠️ Cannot save checkpoint - no tree root")
                return
            }

            // Get last scanned height and block hash
            let lastScanned = try database.getLastScannedHeight()
            guard lastScanned > 0 else {
                print("⚠️ Cannot save checkpoint - no scanned height")
                return
            }

            // Get block hash from HeaderStore
            guard let header = try HeaderStore.shared.getHeader(at: lastScanned) else {
                print("⚠️ Cannot save checkpoint - no header at height \(lastScanned)")
                return
            }

            // Validate tree root matches HeaderStore before saving
            if treeRoot != header.hashFinalSaplingRoot {
                print("⚠️ Tree root mismatch at height \(lastScanned) - NOT saving checkpoint")
                print("   Our root:    \(treeRoot.hexString)")
                print("   Header root: \(header.hashFinalSaplingRoot.hexString)")
                return
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

        } catch {
            print("⚠️ Failed to save tree checkpoint: \(error)")
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

        let version = data.loadUInt32(at: offset)
        offset += 4

        let prevHash = Data(data[offset..<offset+32])
        offset += 32

        let merkleRoot = Data(data[offset..<offset+32])
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

                if knownNullifiers.contains(spend.nullifier) {
                    // One of our notes was spent! Include txid for history tracking
                    try database.markNoteSpent(nullifier: spend.nullifier, txid: tx.txHash, spentHeight: height)
                    debugLog(.wallet, "💸 Note spent @ height \(height)")
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
    @MainActor
    private func processShieldedOutputsSync(
        outputs: [ShieldedOutput],
        spends: [ShieldedSpend]? = nil,
        txid: String,
        accountId: Int64,
        spendingKey: Data,
        ivk: Data,
        height: UInt64
    ) throws {
        // Check for spent notes (nullifier detection) FIRST
        if let spends = spends, !spends.isEmpty {
            let txidData = Data(hexString: txid)
            for spend in spends {
                guard let nullifierDisplay = Data(hexString: spend.nullifier) else { continue }
                let nullifierWire = nullifierDisplay.reversedBytes()
                if knownNullifiers.contains(nullifierWire) {
                    if let txidData = txidData {
                        try database.markNoteSpent(nullifier: nullifierWire, txid: txidData, spentHeight: height)
                    } else {
                        try database.markNoteSpent(nullifier: nullifierWire, spentHeight: height)
                    }
                }
            }
        }

        for (outputIndex, output) in outputs.enumerated() {
            // Convert hex strings to binary data
            guard let cmuDisplay = Data(hexString: output.cmu),
                  let epkDisplay = Data(hexString: output.ephemeralKey),
                  let encCiphertext = Data(hexString: output.encCiphertext) else {
                continue
            }

            // Reverse byte order: display format (big-endian) -> wire format (little-endian)
            let epk = epkDisplay.reversedBytes()
            let cmu = cmuDisplay.reversedBytes()

            // DELTA BUNDLE: Collect output for local caching (enables instant witness generation)
            // Format: 652 bytes = height(4) + index(4) + cmu(32) + epk(32) + ciphertext(580)
            if deltaCollectionEnabled {
                let deltaOutput = DeltaCMUManager.DeltaOutput(
                    height: UInt32(height),
                    index: UInt32(outputIndex),
                    cmu: cmu,
                    epk: epk,
                    ciphertext: encCiphertext
                )
                deltaOutputsCollected.append(deltaOutput)
            }

            // Append CMU to commitment tree (must be done for ALL outputs, not just ours)
            let treePosition = ZipherXFFI.treeAppend(cmu: cmu)

            // NEW WALLET OPTIMIZATION: Skip note decryption for new wallets
            // No notes can exist for a brand new address that was just created
            if isNewWalletInitialSync {
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
            let value = valueBytes.withUnsafeBytes { $0.load(as: UInt64.self) }
            let rcm = decryptedData[19..<51]
            let memo = decryptedData.count >= 563 ? decryptedData[51..<563] : Data()

            debugLog(.wallet, "💰 Note found: \(Double(value)/100_000_000) ZCL @ height \(height)")

            let txidData = Data(hexString: txid) ?? Data()

            // Compute nullifier using spending key (required for proper PRF_nf)
            let nullifier = try rustBridge.computeNullifier(
                spendingKey: spendingKey,
                diversifier: Data(diversifier),
                value: value,
                rcm: Data(rcm),
                position: treePosition
            )

            knownNullifiers.insert(nullifier)

            // Get witness
            let witness = ZipherXFFI.treeGetWitness(index: witnessIndex) ?? Data(count: 1028)

            // Store note with CMU
            let noteId = try database.insertNote(
                accountId: accountId,
                diversifier: Data(diversifier),
                value: value,
                rcm: Data(rcm),
                memo: Data(memo),
                nullifier: nullifier,
                txid: txidData,
                height: height,
                witness: witness,
                cmu: cmu // Store CMU for potential witness rebuild
            )

            // IMMEDIATELY record in transaction history for real-time consistency
            // CRITICAL: Check if this is a change output from our own send
            // Method 1: Check database for existing "sent" record
            var isChangeOutput = (try? database.transactionExists(txid: txidData, type: .sent)) ?? false

            // Method 2: Check NetworkManager's pendingOutgoing tracking (catches race condition)
            if !isChangeOutput {
                isChangeOutput = NetworkManager.shared.isPendingOutgoingSync(txid: txid)
            }

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
            }

            pendingWitnesses.append((noteId: noteId, witnessIndex: witnessIndex))
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
        guard !isNewWalletInitialSync else { return }

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
            if !needsNullifierFix {
                knownNullifiers.insert(nullifier)
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
                cmu: cmu
            )

            // Check if change output
            var isChangeOutput = (try? database.transactionExists(txid: txidData, type: .sent)) ?? false
            if !isChangeOutput {
                isChangeOutput = NetworkManager.shared.isPendingOutgoingSync(txid: info.txid)
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

            debugLog(.wallet, "💰 Note found: \(Double(note.value)/100_000_000) ZCL @ height \(height)")

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
            knownNullifiers.insert(nullifier)

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
            // Create a pseudo-txid for bundled outputs (grouped by height)
            let txidData = "boost_\(note.height)".data(using: .utf8) ?? Data()

            // Add to known nullifiers for future spend detection
            knownNullifiers.insert(note.nullifier)

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

            // Record in transaction history
            try? database.recordReceivedTransaction(
                txid: txidData,
                height: UInt64(note.height),
                value: note.value,
                memo: nil
            )

            // If Rust already determined this note is spent, mark it
            if note.isSpent {
                // Use a pseudo-txid for the spend (we don't have the actual spend txid from boost)
                let spendTxid = "boost_spent_\(note.height)".data(using: .utf8) ?? Data()
                try database.markNoteSpent(
                    nullifier: note.nullifier,
                    txid: spendTxid,
                    spentHeight: UInt64(note.height)
                )
                debugLog(.wallet, "💸 Note marked spent: \(Double(note.value) / 100_000_000) ZCL @ height \(note.height)")
            } else {
                debugLog(.wallet, "💰 Unspent note: \(Double(note.value) / 100_000_000) ZCL @ height \(note.height)")
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
                if knownNullifiers.contains(nullifierWire) {
                    // One of our notes was spent! Include txid for history tracking
                    if let txidData = txidData {
                        try database.markNoteSpent(nullifier: nullifierWire, txid: txidData, spentHeight: height)
                    } else {
                        try database.markNoteSpent(nullifier: nullifierWire, spentHeight: height)
                    }
                    debugLog(.wallet, "💸 Note spent @ height \(height)")
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
            if isNewWalletInitialSync {
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
            let value = valueBytes.withUnsafeBytes { $0.load(as: UInt64.self) }
            let rcm = decryptedData[19..<51]
            let memo = decryptedData.count >= 563 ? decryptedData[51..<563] : Data()

            debugLog(.wallet, "💰 Note found: \(Double(value)/100_000_000) ZCL @ height \(height)")

            let txidData = Data(hexString: txid) ?? Data()

            // Try to find real position from downloaded CMU data
            var position: UInt64 = 0
            var needsNullifierFix = false
            let downloadedTreeHeight = ZipherXConstants.effectiveTreeHeight

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
            if !needsNullifierFix {
                knownNullifiers.insert(nullifier)
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
                cmu: cmu // Store CMU for witness rebuild
            )

            // IMMEDIATELY record in transaction history for real-time consistency
            // CRITICAL: Check if this is a change output from our own send
            // Method 1: Check database for existing "sent" record
            var isChangeOutput = (try? database.transactionExists(txid: txidData, type: .sent)) ?? false

            // Method 2: Check NetworkManager's pendingOutgoing tracking (catches race condition)
            if !isChangeOutput {
                isChangeOutput = NetworkManager.shared.isPendingOutgoingSync(txid: txid)
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
                print("⚠️ Failed to parse output \(index) hex data")
                continue
            }

            // Reverse byte order: display format (big-endian) -> wire format (little-endian)
            let epk = epkDisplay.reversedBytes()
            let cmu = cmuDisplay.reversedBytes()

            // Append CMU to commitment tree (must be done for ALL outputs, not just ours)
            let treePosition = ZipherXFFI.treeAppend(cmu: cmu)
            if treePosition == UInt64.max {
                print("⚠️ Failed to append CMU to tree at height \(height)")
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
            let value = valueBytes.withUnsafeBytes { $0.load(as: UInt64.self) }
            let rcm = decryptedData[19..<51]
            let memo = decryptedData.count >= 564 ? decryptedData[52..<564] : Data()

            let note = DecryptedNote(
                diversifier: Data(diversifier),
                value: value,
                rcm: Data(rcm),
                memo: Data(memo)
            )

            debugLog(.wallet, "💰 Note found: \(Double(value)/100_000_000) ZCL @ height \(height)")

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
            knownNullifiers.insert(nullifier)

            // Get current witness (will be updated at end of scan with final tree state)
            let witness = ZipherXFFI.treeGetWitness(index: witnessIndex) ?? Data(count: 1028)

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
                cmu: cmu // Store CMU for potential witness rebuild
            )

            // Track for final witness update
            pendingWitnesses.append((noteId: noteId, witnessIndex: witnessIndex))

            // IMMEDIATELY record in transaction history for real-time consistency
            // CRITICAL: Check if this is a change output from our own send
            // Method 1: Check database for existing "sent" record
            var isChangeOutput = (try? database.transactionExists(txid: txidData, type: .sent)) ?? false

            // Method 2: Check NetworkManager's pendingOutgoing tracking (catches race condition)
            if !isChangeOutput {
                isChangeOutput = NetworkManager.shared.isPendingOutgoingSync(txid: txid)
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
        knownNullifiers.insert(nullifier)

        // Get witness for the note commitment
        let witness = try await getWitness(for: output.cmu, at: height)

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
            witness: witness
        )

        // Record transaction history for received note
        // CRITICAL: Check if this is a change output from our own send
        // If we already have a "sent" transaction with this txid, this is change - don't record as received
        // Note: txid parameter is already Data type, no conversion needed
        // Method 1: Check database for existing "sent" record
        var isChangeOutput = (try? database.transactionExists(txid: txid, type: .sent)) ?? false

        // Method 2: Check NetworkManager's pendingOutgoing tracking (catches race condition)
        if !isChangeOutput {
            let txidHex = txid.map { String(format: "%02x", $0) }.joined()
            isChangeOutput = NetworkManager.shared.isPendingOutgoingSync(txid: txidHex)
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
        debugLog(.wallet, "💰 Note found: \(Double(note.value)/100_000_000) ZCL @ height \(height)")
    }

    // MARK: - Helper Methods

    private func getChainHeight() async throws -> UInt64 {
        // SECURITY: Use unified consensus function that:
        // 1. Collects heights from InsightAPI + P2P peers
        // 2. Finds agreeing sources within 5 blocks
        // 3. Returns MINIMUM of agreeing sources (conservative)
        // 4. BANS peers reporting heights >10 blocks above consensus

        let consensusHeight = await insightAPI.getConsensusChainHeight(networkManager: networkManager)

        guard consensusHeight > 0 else {
            throw ScanError.networkError
        }

        // Also validate HeaderStore against consensus
        let maxHeightDeviation: UInt64 = 10
        if let hsHeight = try? HeaderStore.shared.getLatestHeight() {
            if hsHeight > consensusHeight + maxHeightDeviation {
                print("🚨 SECURITY: Fake headers detected (store: \(hsHeight), consensus: \(consensusHeight)) - clearing")
                try? HeaderStore.shared.clearAllHeaders()
            }
        }

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
        guard networkManager.isConnected else { return false }

        // Try to fetch a recent block via P2P
        guard let latestHeight = try? HeaderStore.shared.getLatestHeight(),
              let header = try? HeaderStore.shared.getHeader(at: latestHeight) else {
            return false
        }

        do {
            guard let peer = networkManager.peers.first else { return false }
            let block = try await peer.getBlockByHash(hash: header.blockHash)
            debugLog(.network, "P2P test: OK (\(block.transactions.count) txs @ \(latestHeight))")
            return true
        } catch {
            debugLog(.error, "P2P test failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Fetch block data for scanning - tries P2P first, falls back to InsightAPI
    /// Returns: [(txid, [ShieldedOutput], [ShieldedSpend]?)]
    private func fetchBlockData(height: UInt64) async throws -> [(String, [ShieldedOutput], [ShieldedSpend]?)] {
        // Try P2P if it's known to work or hasn't been tested yet
        if FilterScanner.p2pBlockFetchingWorks != false && networkManager.isConnected {
            do {
                let (_, txData) = try await networkManager.getBlockDataP2P(height: height)
                FilterScanner.p2pBlockFetchingWorks = true
                return txData
            } catch {
                if FilterScanner.p2pBlockFetchingWorks == nil {
                    FilterScanner.p2pBlockFetchingWorks = false
                }
                if useP2POnly { throw error }
            }
        }

        // Fallback to InsightAPI (unless P2P-only mode)
        if useP2POnly {
            throw ScanError.networkError
        }

        let blockHash = try await insightAPI.getBlockHash(height: height)
        let block = try await insightAPI.getBlock(hash: blockHash)

        var txData: [(String, [ShieldedOutput], [ShieldedSpend]?)] = []
        for txid in block.tx {
            let tx = try await insightAPI.getTransaction(txid: txid)
            let hasOutputs = tx.vShieldedOutput?.isEmpty == false
            let hasSpends = tx.vShieldedSpend?.isEmpty == false
            if hasOutputs || hasSpends {
                txData.append((txid, tx.vShieldedOutput ?? [], tx.vShieldedSpend))
            }
        }

        return txData
    }

    /// Fetch multiple blocks' data for scanning - tries P2P batch first, falls back to InsightAPI
    /// Returns: [(height, [(txid, [ShieldedOutput], [ShieldedSpend]?)])]
    private func fetchBlocksData(heights: [UInt64]) async throws -> [(UInt64, [(String, [ShieldedOutput], [ShieldedSpend]?)])] {
        // Try P2P batch fetch if it's known to work or hasn't been tested
        if FilterScanner.p2pBlockFetchingWorks != false && networkManager.isConnected && !heights.isEmpty {
            do {
                let startHeight = heights.min()!
                let count = heights.count
                let results = try await networkManager.getBlocksDataP2P(from: startHeight, count: count)

                var blockData: [(UInt64, [(String, [ShieldedOutput], [ShieldedSpend]?)])] = []
                var hasAnyShieldedData = false
                for (h, _, timestamp, txData) in results {
                    blockData.append((h, txData))
                    // Cache real block timestamps for transaction history
                    BlockTimestampManager.shared.cacheTimestamp(height: h, timestamp: timestamp)
                    // Check if any transaction has actual shielded data
                    for (_, outputs, spends) in txData {
                        if !outputs.isEmpty || spends?.isEmpty == false {
                            hasAnyShieldedData = true
                        }
                    }
                }

                // IMPORTANT: Only trust P2P if we actually got shielded data OR we know the blocks have none
                // If we got blocks but zero shielded tx data, P2P parsing might be broken
                // Fall back to InsightAPI to be safe
                if !blockData.isEmpty && hasAnyShieldedData {
                    FilterScanner.p2pBlockFetchingWorks = true
                    return blockData
                } else if !blockData.isEmpty {
                    FilterScanner.p2pBlockFetchingWorks = false
                }
            } catch {
                if FilterScanner.p2pBlockFetchingWorks == nil {
                    FilterScanner.p2pBlockFetchingWorks = false
                }
                if useP2POnly {
                    throw error
                }
            }
        }

        // Fallback to InsightAPI with parallel fetching
        if useP2POnly {
            throw ScanError.networkError
        }

        var results: [(UInt64, [(String, [ShieldedOutput], [ShieldedSpend]?)])] = []
        let batchSize = 10 // Parallel fetch 10 blocks at a time

        for batchStart in stride(from: 0, to: heights.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, heights.count)
            let batch = Array(heights[batchStart..<batchEnd])

            let batchResults = await withTaskGroup(of: (UInt64, [(String, [ShieldedOutput], [ShieldedSpend]?)])?.self) { group in
                for height in batch {
                    group.addTask {
                        do {
                            let blockHash = try await self.insightAPI.getBlockHash(height: height)
                            let block = try await self.insightAPI.getBlock(hash: blockHash)

                            var txData: [(String, [ShieldedOutput], [ShieldedSpend]?)] = []
                            for txid in block.tx {
                                let tx = try await self.insightAPI.getTransaction(txid: txid)
                                let hasOutputs = tx.vShieldedOutput?.isEmpty == false
                                let hasSpends = tx.vShieldedSpend?.isEmpty == false
                                if hasOutputs || hasSpends {
                                    txData.append((txid, tx.vShieldedOutput ?? [], tx.vShieldedSpend))
                                }
                            }
                            return (height, txData)
                        } catch {
                            return nil
                        }
                    }
                }

                var collected: [(UInt64, [(String, [ShieldedOutput], [ShieldedSpend]?)])] = []
                for await result in group {
                    if let r = result {
                        collected.append(r)
                    }
                }
                return collected
            }

            results.append(contentsOf: batchResults)
        }

        return results.sorted { $0.0 < $1.0 }
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

            let notes = try database.getAllUnspentNotes(accountId: account.id)
            let notesNeedingWitness = notes.filter { note in
                note.witness.count != 1028 || note.witness.allSatisfy { $0 == 0 }
            }

            if notesNeedingWitness.isEmpty {
                reportPhase15Progress(1.0, current: 0, total: 0)
                return
            }

            print("🔧 PHASE 1.5: \(notesNeedingWitness.count) witnesses to compute")
            reportPhase15Progress(0.05, current: 0, total: notesNeedingWitness.count)

            for (index, note) in notesNeedingWitness.enumerated() {
                guard let cmu = note.cmu, cmu.count == 32 else { continue }

                if let result = ZipherXFFI.treeCreateWitnessForCMU(cmuData: bundledData, targetCMU: cmu) {
                    try database.updateNoteWitness(noteId: note.id, witness: result.witness)
                    // Extract anchor from witness and save it - enables INSTANT mode!
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

    /// Pre-compute witnesses using BATCH function (builds tree once, creates all witnesses)
    private func computeWitnessesForBundledNotesBatch(bundledData: Data) async {
        reportPhase15Progress(0.0, current: 0, total: 1)

        do {
            guard let account = try database.getAccount(index: 0) else {
                reportPhase15Progress(1.0, current: 0, total: 0)
                return
            }

            let notes = try database.getAllUnspentNotes(accountId: account.id)
            let notesNeedingWitness = notes.filter { note in
                note.witness.count != 1028 || note.witness.allSatisfy { $0 == 0 }
            }

            if notesNeedingWitness.isEmpty {
                reportPhase15Progress(1.0, current: 0, total: 0)
                return
            }

            // Collect all CMUs that need witnesses
            var targetCMUs: [Data] = []
            var noteIdMap: [Int: Int64] = [:]

            for note in notesNeedingWitness {
                guard let cmu = note.cmu, cmu.count == 32 else { continue }
                targetCMUs.append(cmu)
                noteIdMap[targetCMUs.count - 1] = note.id
            }

            guard !targetCMUs.isEmpty else {
                reportPhase15Progress(1.0, current: 0, total: 0)
                return
            }

            print("🔧 PHASE 1.5: Computing \(targetCMUs.count) witnesses (batch mode)")
            onStatusUpdate?("phase1.5", "Computing \(targetCMUs.count) Merkle witnesses...")
            reportPhase15Progress(0.1, current: 0, total: targetCMUs.count)
            let startTime = Date()

            // Use BATCH witness function - builds tree once and creates all witnesses in single pass
            let results = ZipherXFFI.treeCreateWitnessesBatch(cmuData: bundledData, targetCMUs: targetCMUs)

            let elapsed = Date().timeIntervalSince(startTime)
            reportPhase15Progress(0.9, current: targetCMUs.count, total: targetCMUs.count)

            // Update database with computed witnesses AND anchors
            // CRITICAL: treeCreateWitnessesBatch builds its OWN tree, not the global COMMITMENT_TREE.
            // The anchor must be extracted FROM the witness using witnessGetRoot().
            // This ensures INSTANT mode works - the stored anchor matches the witness.
            var successCount = 0
            for (index, result) in results.enumerated() {
                guard let noteId = noteIdMap[index] else { continue }
                if let (_, witness) = result {
                    try database.updateNoteWitness(noteId: noteId, witness: witness)
                    // Extract anchor from witness and save it - enables INSTANT mode!
                    if let anchor = ZipherXFFI.witnessGetRoot(witness) {
                        try database.updateNoteAnchor(noteId: noteId, anchor: anchor)
                    }
                    successCount += 1
                }
            }

            reportPhase15Progress(1.0, current: successCount, total: targetCMUs.count)
            print("✅ PHASE 1.5: \(successCount)/\(targetCMUs.count) witnesses in \(String(format: "%.1f", elapsed))s")

        } catch {
            debugLog(.error, "PHASE 1.5 batch error: \(error)")
            reportPhase15Progress(1.0, current: 0, total: 0)
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

