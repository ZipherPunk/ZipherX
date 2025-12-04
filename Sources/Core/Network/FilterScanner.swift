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

    // Witness update progress callback - (current, total, status)
    var onWitnessProgress: ((Int, Int, String) -> Void)?

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

    // Notes discovered AFTER bundledTreeHeight that need nullifier recomputation
    // These notes have position=0 (wrong) because they weren't in bundled tree
    // After PHASE 2, we recompute their nullifiers using correct tree positions
    // Format: (noteId, cmu, diversifier, value, rcm, height)
    private var notesNeedingNullifierFix: [(noteId: Int64, cmu: Data, diversifier: Data, value: UInt64, rcm: Data, height: UInt64)] = []

    // Note: Tree validation now uses ZipherXConstants.effectiveTreeCMUCount
    // which may be higher than bundled if a newer tree was downloaded from GitHub

    // NEW WALLET OPTIMIZATION: Skip note decryption for brand new wallets
    // New wallets can't have any notes yet (address was just created)
    // We still append CMUs to tree but skip tryDecryptNote() calls
    private var isNewWalletInitialSync = false

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
        print("📡 Getting chain height...")
        guard let latestHeight = try? await getChainHeight() else {
            print("❌ Failed to get chain height")
            throw ScanError.networkError
        }
        currentChainHeight = latestHeight
        print("📊 Chain height: \(latestHeight)")

        // Test P2P block fetching before starting scan
        // This determines if we can use P2P or need to fall back to InsightAPI
        if FilterScanner.p2pBlockFetchingWorks == nil {
            let p2pWorks = await testP2PBlockFetching()
            FilterScanner.p2pBlockFetchingWorks = p2pWorks
            if p2pWorks {
                print("✅ P2P block fetching enabled")
            } else {
                if useP2POnly {
                    print("❌ P2P-only mode enabled but P2P block fetch failed!")
                    throw ScanError.networkError
                }
                print("⚠️ P2P block fetch failed, will use InsightAPI")
            }
        }

        // Determine start height
        var startHeight: UInt64

        // VUL-018: Use shared constants for bundled tree
        let bundledTreeHeight = ZipherXConstants.bundledTreeHeight
        let bundledTreeCMUCount = ZipherXConstants.bundledTreeCMUCount
        // Use effectiveTreeHeight which may be higher if a newer tree was downloaded from GitHub
        let effectiveTreeHeight = ZipherXConstants.effectiveTreeHeight

        // Track if we're scanning within bundled tree range (notes only, no tree building)
        var scanWithinBundledRange = false

        // If custom start height provided (quick scan), use it
        if let customStart = customStartHeight {
            startHeight = customStart
            // Check if this is within effective tree range (could be GitHub tree height)
            if startHeight <= effectiveTreeHeight {
                scanWithinBundledRange = true
                print("🔍 Scan mode: starting from user-specified height \(startHeight) (within tree range, effective height: \(effectiveTreeHeight))")
            } else {
                print("🔍 Scan mode: starting from user-specified height \(startHeight)")
            }
        } else {
            // Normal scan - determine start height automatically
            // Get last scanned height
            let lastScanned = try database.getLastScannedHeight()

            // Check if we have tree state (database or bundled)
            let treeExists = (try? database.getTreeState()) != nil
            let bundledTreeAvailable = Bundle.main.url(forResource: "commitment_tree", withExtension: "bin") != nil

            // Check if this is an imported/restored wallet (may have historical notes)
            let isImportedWallet = WalletManager.shared.isImportedWallet
            let customScanHeight = WalletManager.shared.importScanStartHeight

            if lastScanned > 0 {
                // Existing wallet - continue from last scanned
                startHeight = lastScanned + 1
                print("📊 Continuing from last scanned height \(lastScanned)")
            } else if isImportedWallet {
                // IMPORTED/RESTORED WALLET: Need to scan WITHIN tree range for historical notes
                // Use custom start height if user selected a date, otherwise full scan from Sapling activation
                if let customHeight = customScanHeight, customHeight > ZclassicCheckpoints.saplingActivationHeight {
                    startHeight = customHeight
                    print("📦 Imported wallet - scanning from user-selected date (block \(startHeight))")
                } else {
                    startHeight = ZclassicCheckpoints.saplingActivationHeight
                    print("📦 Imported wallet - FULL historical scan from Sapling activation \(startHeight)")
                }

                // Enable PHASE 1 for parallel scanning within tree range
                scanWithinBundledRange = true

                // DOWNLOAD CMU FILE FROM GITHUB if newer than bundled (for faster position lookups)
                // The CMU file is ~33MB and contains all note commitments for PHASE 1 position lookup
                print("🌲 Checking GitHub for updated CMU file...")
                if let (cmuPath, cmuHeight, cmuCount) = try? await CommitmentTreeUpdater.shared.getCMUFileForImportedWallet(onProgress: { progress, status in
                    self.onProgress?(progress * 0.1, startHeight, latestHeight) // First 10% for download
                    print("🌲 \(status)")
                }) {
                    print("🌲 Downloaded CMU file from GitHub: height \(cmuHeight) (\(cmuCount) CMUs)")
                    // Store downloaded CMU data for position lookup
                    if let downloadedData = try? Data(contentsOf: cmuPath) {
                        self.cmuDataForPositionLookup = downloadedData
                        self.cmuDataHeight = cmuHeight
                        self.cmuDataCount = cmuCount
                    }
                } else {
                    print("⚠️ GitHub CMU file not available or not newer, will use bundled")
                }

                // Safe calculation to avoid underflow
                let totalBlocks = latestHeight >= startHeight ? latestHeight - startHeight + 1 : 0
                print("   📊 Scanning \(totalBlocks) blocks to find all historical notes")
                // NOTE: PHASE 1 is limited to bundledTreeHeight (not effectiveTreeHeight)
                // because we need CMU positions from bundled file for correct nullifiers
                print("   📊 PHASE 1: blocks \(startHeight) to \(bundledTreeHeight) (parallel, with bundled CMU lookup)")
                print("   📊 PHASE 2: blocks \(bundledTreeHeight + 1) to \(latestHeight) (sequential, with tree building)")
            } else if treeExists || bundledTreeAvailable {
                // NEW WALLET: Fast startup - no historical notes possible
                startHeight = effectiveTreeHeight + 1
                isNewWalletInitialSync = true  // Skip note decryption (no notes can exist)
                print("📦 New wallet with tree - fast startup from \(startHeight) (skip note decryption)")
            } else {
                // No tree anywhere - full scan from Sapling activation
                startHeight = ZclassicCheckpoints.saplingActivationHeight
                print("🔄 Full rescan - starting from Sapling activation \(startHeight)")
            }
        }

        // If startHeight > latestHeight, chain may have grown - refresh height
        if startHeight > latestHeight {
            print("⚠️ Start height \(startHeight) > chain height \(latestHeight), refreshing...")
            // Try InsightAPI for more accurate height
            if let apiHeight = try? await insightAPI.getStatus().height, apiHeight >= startHeight {
                currentChainHeight = apiHeight
                print("📊 Updated chain height from InsightAPI: \(apiHeight)")
            } else {
                // Truly already synced
                print("✅ Already synced to chain tip")
                onProgress?(1.0, latestHeight, latestHeight)
                return
            }
        }

        let targetHeight = currentChainHeight
        print("🔍 Scanning from \(startHeight) to \(targetHeight)")

        guard startHeight <= targetHeight else {
            // Already fully synced
            print("✅ Already synced")
            onProgress?(1.0, targetHeight, targetHeight) // Report 100% completion
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
        print("🔍 FilterScanner: Loaded \(knownNullifiers.count) known nullifiers from database")

        // NOTE: Existing witnesses are loaded AFTER tree is ready (see below)
        // This is critical - witnesses must be loaded into an initialized tree
        let existingNotes = try database.getUnspentNotes(accountId: accountId)
        existingWitnessIndices = []

        // Determine if we need to reset tree for a rescan
        // Only reload tree for EXPLICIT rescans from effective height, NOT for background sync
        // Background sync passes heights > effectiveTreeHeight and should APPEND
        // A rescan specifically starts at effectiveTreeHeight + 1 to rebuild from current tree state
        let initialTreeSize = ZipherXFFI.treeSize()
        let effectiveTreeCMUCount = ZipherXConstants.effectiveTreeCMUCount
        let treeHasProgress = initialTreeSize > effectiveTreeCMUCount

        // Only force fresh tree if:
        // 1. Custom height provided AND starting exactly from effective+1 (rescan scenario)
        // 2. AND tree doesn't already have progress (hasn't appended CMUs beyond effective)
        let needsFreshBundledTree = customStartHeight != nil
            && customStartHeight! == effectiveTreeHeight + 1
            && !treeHasProgress

        print("🔍 Tree check: initialSize=\(initialTreeSize), effectiveCount=\(effectiveTreeCMUCount), effectiveHeight=\(effectiveTreeHeight), hasProgress=\(treeHasProgress), needsFresh=\(needsFreshBundledTree)")

        // CRITICAL: Wait for WalletManager to finish loading tree before proceeding
        // This prevents race condition where both load concurrently and corrupt the global tree
        // Tree loading takes ~53 seconds, so we wait up to 120 seconds
        if !needsFreshBundledTree {
            let walletManager = WalletManager.shared
            var waitAttempts = 0
            let maxWaitAttempts = 1200 // 120 seconds max wait (tree takes ~53s)
            while !walletManager.isTreeLoaded && waitAttempts < maxWaitAttempts {
                if waitAttempts == 0 {
                    print("⏳ Waiting for WalletManager to finish loading tree...")
                } else if waitAttempts % 100 == 0 {
                    print("⏳ Still waiting for tree... (\(waitAttempts / 10)s)")
                }
                try await Task.sleep(nanoseconds: 100_000_000) // 100ms
                waitAttempts += 1
            }
            if waitAttempts > 0 && walletManager.isTreeLoaded {
                print("✅ WalletManager tree loading complete after \(waitAttempts / 10)s, proceeding with scan")
            } else if waitAttempts >= maxWaitAttempts {
                print("⚠️ Timeout waiting for WalletManager tree load - will check tree state")
            }
        }

        // CRITICAL: Check if tree is already loaded in FFI memory (WalletManager may have loaded it)
        // This prevents race condition where FilterScanner loads again while WalletManager is loading
        let existingTreeSize = ZipherXFFI.treeSize()

        // CRITICAL FIX: For imported wallets scanning within bundled range, we MUST use the bundled tree
        // because that's what cmuDataForPositionLookup contains for position lookup.
        // GitHub serialized tree has DIFFERENT CMU positions than bundled CMU file!
        let needsBundledTreeForPositionLookup = scanWithinBundledRange
        let requiredTreeSize = needsBundledTreeForPositionLookup ? bundledTreeCMUCount : effectiveTreeCMUCount

        if !needsFreshBundledTree && existingTreeSize > 0 {
            // For imported wallets: Check against bundledTreeCMUCount (tree must match cmuDataForPositionLookup)
            // For new wallets: Check against effectiveTreeCMUCount (can use GitHub tree)
            if existingTreeSize >= requiredTreeSize {
                // ADDITIONAL CHECK: If scanning within bundled range, verify tree is EXACTLY bundled size
                // A bigger tree (GitHub) would have wrong CMU positions for bundled data lookup!
                if needsBundledTreeForPositionLookup && existingTreeSize > bundledTreeCMUCount {
                    print("⚠️ Tree in memory has \(existingTreeSize) CMUs but PHASE 1 needs bundled tree (\(bundledTreeCMUCount) CMUs)")
                    print("🔄 Forcing reload from bundled CMUs for correct position lookup...")
                    treeInitialized = false
                } else {
                    print("🌳 Tree already loaded in memory with \(existingTreeSize) commitments")
                    treeInitialized = true
                    // Load CMU data for position lookup during parallel scan
                    // Prefer downloaded CMU file from GitHub if available
                    if let cachedPath = await CommitmentTreeUpdater.shared.getCachedCMUFilePath(),
                       let cachedInfo = await CommitmentTreeUpdater.shared.getCachedTreeInfo(),
                       let cachedData = try? Data(contentsOf: cachedPath) {
                        self.cmuDataForPositionLookup = cachedData
                        self.cmuDataHeight = cachedInfo.height
                        self.cmuDataCount = cachedInfo.cmuCount
                        print("🌳 Using downloaded CMU data for position lookup (height \(cachedInfo.height))")
                    } else if let bundledCMUsURL = Bundle.main.url(forResource: "commitment_tree", withExtension: "bin"),
                              let bundledData = try? Data(contentsOf: bundledCMUsURL) {
                        self.cmuDataForPositionLookup = bundledData
                        self.cmuDataHeight = ZipherXConstants.bundledTreeHeight
                        self.cmuDataCount = ZipherXConstants.bundledTreeCMUCount
                    }
                }
            } else {
                print("⚠️ Tree in memory has \(existingTreeSize) CMUs but expected at least \(requiredTreeSize)")
                print("🔄 Clearing invalid tree and reloading from bundled file...")
                // CRITICAL: Clear the invalid database tree so we don't reload it below
                try? database.clearTreeState()
                treeInitialized = false
            }
        }

        // Initialize commitment tree
        // Priority: 1) Already in memory, 2) Database state (unless rescanning), 3) Bundled tree, 4) Empty tree
        if !treeInitialized && !needsFreshBundledTree, let treeData = try? database.getTreeState() {
            if ZipherXFFI.treeDeserialize(data: treeData) {
                let treeSize = ZipherXFFI.treeSize()
                // VALIDATION: Check database tree has correct size
                // For imported wallets: use bundledTreeCMUCount, for new wallets: use effectiveTreeCMUCount
                if treeSize >= requiredTreeSize {
                    // ADDITIONAL CHECK: For PHASE 1, database tree must not be bigger than bundled
                    if needsBundledTreeForPositionLookup && treeSize > bundledTreeCMUCount {
                        print("⚠️ Database tree has \(treeSize) CMUs but PHASE 1 needs bundled tree (\(bundledTreeCMUCount) CMUs)")
                        print("🔄 Clearing database tree and loading bundled CMUs...")
                        try? database.clearTreeState()
                        treeInitialized = false
                    } else {
                        print("🌳 Restored commitment tree with \(treeSize) commitments")
                        treeInitialized = true
                    }
                } else {
                    print("⚠️ Database tree has \(treeSize) CMUs but expected at least \(requiredTreeSize)")
                    print("🔄 Clearing invalid database tree...")
                    try? database.clearTreeState()
                    treeInitialized = false
                }
            } else {
                print("⚠️ Failed to restore tree from database")
                treeInitialized = false
            }
        }

        // Force load bundled tree for rescans starting after bundled height
        if needsFreshBundledTree {
            print("🌳 Rescan mode: loading fresh bundled tree (ignoring database state)")
            treeInitialized = false // Force reload from bundled data
        }

        // Try to load CMUs for tree building - prefer downloaded from GitHub if available
        // CMUs allow us to build the tree properly and create valid witnesses
        if !treeInitialized {
            // PRIORITY 1: Check for downloaded CMU file from GitHub (may be newer than bundled)
            var cmuDataURL: URL?
            var cmuSourceName = "bundled"

            if let cachedPath = await CommitmentTreeUpdater.shared.getCachedCMUFilePath(),
               let cachedInfo = await CommitmentTreeUpdater.shared.getCachedTreeInfo() {
                // Use downloaded CMU file (newer than bundled)
                cmuDataURL = cachedPath
                cmuSourceName = "downloaded from GitHub"
                self.cmuDataHeight = cachedInfo.height
                self.cmuDataCount = cachedInfo.cmuCount
                print("🌳 Found downloaded CMU file at height \(cachedInfo.height) (\(cachedInfo.cmuCount) CMUs)")
            }

            // PRIORITY 2: Fall back to bundled CMU file
            if cmuDataURL == nil, let bundledPath = Bundle.main.url(forResource: "commitment_tree", withExtension: "bin") {
                cmuDataURL = bundledPath
                cmuSourceName = "bundled"
                self.cmuDataHeight = ZipherXConstants.bundledTreeHeight
                self.cmuDataCount = ZipherXConstants.bundledTreeCMUCount
            }

            // Load and build tree from CMU file
            if let cmuURL = cmuDataURL, let cmuData = try? Data(contentsOf: cmuURL) {
                print("🌳 Loading \(cmuSourceName) CMUs (\(cmuData.count / 1024 / 1024) MB)...")
                // Store CMU data for position lookup during parallel scan
                self.cmuDataForPositionLookup = cmuData

                // Initialize empty tree
                _ = ZipherXFFI.treeInit()

                // Parse CMUs file: [count: UInt64][cmu1: 32 bytes][cmu2: 32 bytes]...
                guard cmuData.count >= 8 else {
                    print("⚠️ Invalid CMUs file")
                    treeInitialized = false
                    return
                }

                let count = cmuData.withUnsafeBytes { ptr -> UInt64 in
                    ptr.load(as: UInt64.self)
                }

                print("🌳 Building tree from \(count) \(cmuSourceName) CMUs...")
                let buildStart = Date()

                // Append all CMUs to tree
                cmuData.withUnsafeBytes { ptr in
                    let basePtr = ptr.baseAddress!.advanced(by: 8)
                    for i in 0..<Int(count) {
                        let cmuPtr = basePtr.advanced(by: i * 32)
                        _ = ZipherXFFI.treeAppendRaw(cmu: cmuPtr.assumingMemoryBound(to: UInt8.self))
                    }
                }

                let buildTime = Date().timeIntervalSince(buildStart)
                let treeSize = ZipherXFFI.treeSize()
                print("🌳 Built commitment tree with \(treeSize) commitments in \(String(format: "%.1f", buildTime))s")
                treeInitialized = true

                // Save tree state to database
                if let treeData = ZipherXFFI.treeSerialize() {
                    try? database.saveTreeState(treeData)
                }
            } else if let bundledTreeURL = Bundle.main.url(forResource: "sapling_tree", withExtension: "bin"),
               let bundledData = try? Data(contentsOf: bundledTreeURL) {
                // Fallback to serialized tree (less useful but faster to load)
                if ZipherXFFI.treeDeserialize(data: bundledData) {
                    let treeSize = ZipherXFFI.treeSize()
                    print("🌳 Loaded bundled tree with \(treeSize) commitments (frontier only)")
                    treeInitialized = true
                    try? database.saveTreeState(bundledData)
                }
            }
        }

        // Fall back to empty tree
        if !treeInitialized {
            treeInitialized = ZipherXFFI.treeInit()
            print("🌳 Initialized empty commitment tree")
        }

        guard treeInitialized else {
            print("❌ Failed to initialize commitment tree")
            throw ScanError.databaseError
        }

        // NOW load existing witnesses into FFI - tree is ready!
        // This is critical - witnesses become stale when new CMUs are added
        // By loading them now, they'll be auto-updated as we append new CMUs
        var notesWithoutWitnesses = 0
        for note in existingNotes {
            if note.witness.count >= 1028 {
                // Load witness into FFI - it will be updated as we append CMUs
                let witnessIndex = note.witness.withUnsafeBytes { ptr in
                    ZipherXFFI.treeLoadWitness(
                        witnessData: ptr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        witnessLen: note.witness.count
                    )
                }
                if witnessIndex != UInt64.max {
                    existingWitnessIndices.append((noteId: note.id, witnessIndex: witnessIndex))
                    print("📝 Loaded witness for existing note \(note.id)")
                }
            } else {
                // Note exists but has no witness (cleared during rebuild)
                // Its witness will be rebuilt when rediscovered during scan
                notesWithoutWitnesses += 1
                print("📝 Note \(note.id) has no witness, will be rebuilt during scan")
            }
        }
        if notesWithoutWitnesses > 0 {
            print("📝 Found \(notesWithoutWitnesses) existing notes without witnesses")
        }

        // Clear pending witnesses for this scan
        pendingWitnesses = []

        // Report initial progress immediately so UI shows progress bar
        onProgress?(0.01, startHeight, targetHeight)

        // Determine scanning strategy:
        // - If scanning within bundled tree range: use PARALLEL mode (note discovery only)
        // - If scanning after bundled tree: use SEQUENTIAL mode (tree building + note discovery)
        var currentHeight = startHeight

        // PHASE 1: If we're scanning within CMU data range, scan those blocks first (batch/fast)
        // CRITICAL: PHASE 1 must only go up to cmuDataHeight (bundled OR downloaded from GitHub)
        // because that's where we have CMU data for position lookup. Beyond cmuDataHeight, notes
        // MUST be scanned in PHASE 2 sequential mode where positions are computed as CMUs are appended.
        // Use downloaded CMU height if available, otherwise fall back to bundled height
        let phase1EndHeight = cmuDataHeight > 0 ? cmuDataHeight : bundledTreeHeight

        if scanWithinBundledRange && startHeight <= phase1EndHeight {
            print("⚡ PHASE 1: Scanning blocks \(startHeight) to \(phase1EndHeight) for notes (batch P2P + Rayon parallel decryption)")
            if cmuDataHeight > bundledTreeHeight {
                print("   (Using downloaded CMU file from GitHub: height \(cmuDataHeight), \(cmuDataCount) CMUs)")
            } else {
                print("   (Using bundled CMU file: height \(bundledTreeHeight), \(bundledTreeCMUCount) CMUs)")
            }

            let parallelEndHeight = min(phase1EndHeight, targetHeight)
            let parallelTotalBlocks = parallelEndHeight - startHeight + 1
            var parallelScannedBlocks: UInt64 = 0
            let batchSize = 500 // Larger batches for P2P batch fetching

            // Collect ALL spends during PHASE 1 for later spend detection (PHASE 1.6)
            // Format: (height, txid, nullifierHex)
            var collectedSpends: [(UInt64, String, String)] = []

            while currentHeight <= parallelEndHeight && isScanning {
                let remainingBlocks = Int(parallelEndHeight - currentHeight + 1)
                let thisBatchSize = min(batchSize, remainingBlocks)
                let endHeight = currentHeight + UInt64(thisBatchSize) - 1

                print("⚡ Batch fetching blocks \(currentHeight) to \(endHeight) (\(thisBatchSize) blocks)...")

                // Use batch P2P fetch - much faster than individual requests!
                var blockDataMap: [UInt64: [(String, [ShieldedOutput], [ShieldedSpend]?)]] = [:]

                do {
                    // Try P2P batch fetch first
                    if FilterScanner.p2pBlockFetchingWorks != false && networkManager.isConnected {
                        let results = try await networkManager.getBlocksDataP2P(from: currentHeight, count: thisBatchSize)
                        for (height, _, txData) in results {
                            blockDataMap[height] = txData
                        }
                        FilterScanner.p2pBlockFetchingWorks = true
                    } else {
                        throw ScanError.networkError
                    }
                } catch {
                    // Fallback to InsightAPI with parallel fetching (still faster than sequential)
                    if !useP2POnly {
                        print("⚠️ P2P batch failed, using InsightAPI fallback...")
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

                // PARALLEL BATCH PROCESSING (6.7x speedup via Rayon)
                // Process entire batch at once instead of one-by-one
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

                // Update progress
                parallelScannedBlocks += UInt64(endHeight - currentHeight + 1)
                let progress = Double(parallelScannedBlocks) / Double(parallelTotalBlocks)
                onProgress?(progress * 0.5, endHeight, targetHeight) // 50% for phase 1

                // Save progress for bundled range scan
                try? database.updateLastScannedHeight(endHeight, hash: Data(count: 32))
                print("⚡ Batch scanned \(currentHeight) to \(endHeight)")
                currentHeight = endHeight + 1
            }

            print("✅ PHASE 1 complete: scanned \(startHeight) to \(parallelEndHeight)")
            print("📊 Found \(knownNullifiers.count) notes with nullifiers")
            print("📊 Collected \(collectedSpends.count) spends during PHASE 1")

            // PHASE 1.6: SPEND DETECTION PASS (using cached spends - NO network fetch!)
            // During PHASE 1, we cached all spends we encountered.
            // Now check them against knownNullifiers (which is now complete).
            if !knownNullifiers.isEmpty && !collectedSpends.isEmpty {
                print("🔍 PHASE 1.6: Checking \(collectedSpends.count) cached spends against \(knownNullifiers.count) known nullifiers...")
                var spendsDetected = 0

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
                        print("💸 Detected spend at height \(height) in tx \(txid.prefix(16))...")
                    }
                }
                print("✅ PHASE 1.6 complete: detected \(spendsDetected) spent notes")
            }

            // PHASE 1.5: Pre-compute witnesses for notes discovered in bundled range
            // This runs in background so user doesn't wait at spend time
            if let bundledData = cmuDataForPositionLookup {
                await computeWitnessesForBundledNotes(bundledData: bundledData)
            }

            // Move to blocks after bundled tree height for PHASE 2
            // CRITICAL: Must be bundledTreeHeight + 1, not effectiveTreeHeight + 1
            // PHASE 2 must scan ALL blocks after bundledTreeHeight to get correct positions
            currentHeight = bundledTreeHeight + 1
        }

        // PHASE 2: Continue scanning blocks after bundled tree (tree building mode)
        // This runs if:
        // - We did PHASE 1 and there are more blocks after phase1EndHeight
        // - OR no custom start height was provided (normal auto-scan)
        // - OR custom start height is AFTER CMU data height (must use sequential for correct positions)
        let continueAfterBundledRange = scanWithinBundledRange && currentHeight <= targetHeight

        // Quick scan is ONLY safe when scanning WITHIN CMU data range where positions are known
        // If starting AFTER CMU data, we MUST use sequential mode for correct nullifier computation
        let isQuickScanOnly = customStartHeight != nil && !scanWithinBundledRange && customStartHeight! <= phase1EndHeight

        // If custom start is AFTER CMU data height, force sequential mode
        let forceSequentialAfterBundled = customStartHeight != nil && customStartHeight! > phase1EndHeight

        if continueAfterBundledRange || forceSequentialAfterBundled {
            print("⚡ PHASE 2: Scanning blocks \(currentHeight) to \(targetHeight) for notes + tree building (sequential)")
        }

        if isQuickScanOnly {
            // PARALLEL MODE with RAYON - 6.7x faster note decryption!
            // Fetches blocks in parallel, then batch decrypts all outputs using Rayon
            let parallelBatchSize = 500 // Larger batches to maximize Rayon efficiency

            while currentHeight <= targetHeight && isScanning {
                let endHeight = min(currentHeight + UInt64(parallelBatchSize) - 1, targetHeight)
                let heights = Array(currentHeight...endHeight)

                print("⚡ Parallel scanning blocks \(currentHeight) to \(endHeight)...")

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
                print("⚡ Parallel scanned \(currentHeight) to \(endHeight)")
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
                        // Use pre-fetched data with timeout protection
                        print("🚀 Using pre-fetched data for blocks \(currentHeight)-\(endHeight)")
                        blockData = try await withTimeout(seconds: 60) {
                            try await prefetchTask.value
                        }
                        nextBatchTask = nil
                    } else {
                        // First batch or pre-fetch failed - fetch synchronously with timeout
                        print("📦 Fetching blocks \(currentHeight) to \(endHeight) via \(useP2POnly ? "P2P only" : "P2P+fallback")...")
                        blockData = try await withTimeout(seconds: 60) {
                            try await self.fetchBlocksData(heights: heights.map { UInt64($0) })
                        }
                    }
                } catch {
                    print("❌ Failed to fetch blocks \(currentHeight)-\(endHeight): \(error)")
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
                // This overlaps network I/O with tree building (the slow part)
                let nextStart = endHeight + 1
                if nextStart <= targetHeight && isScanning {
                    let nextEnd = min(nextStart + UInt64(batchSize) - 1, targetHeight)
                    let nextHeights = Array(nextStart...nextEnd).map { UInt64($0) }
                    nextBatchTask = Task { [self] in
                        try await self.fetchBlocksData(heights: nextHeights)
                    }
                    print("📡 Pre-fetching batch \(nextStart)-\(nextEnd) in background...")
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
                    // Report progress every 10 blocks for better UI feedback
                    if scannedBlocks % 10 == 0 || scannedBlocks == 1 {
                        let progress = Double(scannedBlocks) / Double(totalBlocks)
                        onProgress?(progress, height, targetHeight)
                    }
                }

                // Save progress
                try? database.updateLastScannedHeight(endHeight, hash: Data(count: 32))

                // Persist tree state periodically
                if let treeData = ZipherXFFI.treeSerialize() {
                    try? database.saveTreeState(treeData)
                }

                // Log progress every 500 blocks to reduce verbosity
                if scannedBlocks % 500 == 0 || scannedBlocks == totalBlocks {
                    print("📦 Processed \(scannedBlocks) of \(totalBlocks) blocks (heights \(startHeight) to \(endHeight))")
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
        for (noteId, witnessIndex) in existingWitnessIndices {
            if let witnessData = ZipherXFFI.treeGetWitness(index: witnessIndex) {
                try? database.updateNoteWitness(noteId: noteId, witness: witnessData)
                try? database.updateNoteAnchor(noteId: noteId, anchor: currentAnchor)
                witnessesUpdated += 1
                print("📝 Updated witness for existing note \(noteId)")
                onWitnessProgress?(witnessesUpdated, totalWitnesses, "Witness \(witnessesUpdated)/\(totalWitnesses)")
            }
        }

        // Update new notes' witnesses and anchors (discovered during this scan)
        for (noteId, witnessIndex) in pendingWitnesses {
            if let witnessData = ZipherXFFI.treeGetWitness(index: witnessIndex) {
                try? database.updateNoteWitness(noteId: noteId, witness: witnessData)
                try? database.updateNoteAnchor(noteId: noteId, anchor: currentAnchor)
                witnessesUpdated += 1
                print("📝 Updated witness for new note \(noteId)")
                onWitnessProgress?(witnessesUpdated, totalWitnesses, "Witness \(witnessesUpdated)/\(totalWitnesses)")
            }
        }

        if totalWitnesses > 0 {
            print("✅ Updated \(totalWitnesses) witness(es) to match current tree state")
            onWitnessProgress?(totalWitnesses, totalWitnesses, "All witnesses synced!")
        } else {
            onWitnessProgress?(0, 0, "No witnesses to update")
        }

        // PHASE 2.5: Check for notes that couldn't get correct positions during PHASE 1
        // With the fix limiting PHASE 1 to bundledTreeHeight, this should rarely/never happen.
        // Notes after bundledTreeHeight are now scanned in PHASE 2 sequential mode.
        if !notesNeedingNullifierFix.isEmpty {
            print("⚠️ PHASE 2.5: Found \(notesNeedingNullifierFix.count) notes with potentially wrong nullifiers")
            print("   These notes were within bundledTreeHeight but CMU wasn't in bundled data.")
            print("   Use 'Repair Notes' in Settings to fix if balance is wrong.")

            // Clear the tracking array - we've warned the user
            notesNeedingNullifierFix.removeAll()
        }

        print("✅ Scan complete")
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

        let bits = data.loadUInt32(at: offset)
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
                    print("💸 Note spent at height \(height)")
                }
            }
        }

        // Trial-decrypt each output to find notes for us
        for tx in block.transactions {
            for (outputIndex, output) in tx.outputs.enumerated() {
                // Try to decrypt with our incoming viewing key
                if let note = tryDecryptOutput(output, ivk: ivk) {
                    print("🔓 Successfully decrypted note at height \(height)!")
                    // We found a note addressed to us!
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
        // CRITICAL: Check for spent notes (nullifier detection) FIRST
        // This must be done before processing outputs
        if let spends = spends, !spends.isEmpty {
            print("🔍 SPEND DEBUG: Block \(height) has \(spends.count) spend(s), checking against \(knownNullifiers.count) known nullifiers")
            // Convert txid from hex string to Data for database storage
            let txidData = Data(hexString: txid)
            for spend in spends {
                guard let nullifierDisplay = Data(hexString: spend.nullifier) else {
                    print("⚠️ SPEND DEBUG: Could not parse nullifier hex: \(spend.nullifier.prefix(32))...")
                    continue
                }
                // CRITICAL FIX: API returns nullifier in big-endian (display format)
                // but our knownNullifiers are stored in little-endian (wire format)
                // Must reverse before comparison!
                let nullifierWire = nullifierDisplay.reversedBytes()
                let nullifierWireHex = nullifierWire.map { String(format: "%02x", $0) }.joined()
                if knownNullifiers.contains(nullifierWire) {
                    // One of our notes was spent! Include txid for history tracking
                    print("💸 SPEND DETECTED! Nullifier: \(nullifierWireHex.prefix(32))... at height \(height)")
                    if let txidData = txidData {
                        try database.markNoteSpent(nullifier: nullifierWire, txid: txidData, spentHeight: height)
                    } else {
                        try database.markNoteSpent(nullifier: nullifierWire, spentHeight: height)
                    }
                    print("💸 Note spent at height \(height)")
                } else {
                    // Log first few bytes for debugging (don't log full nullifier for privacy)
                    print("🔍 SPEND DEBUG: Nullifier \(nullifierWireHex.prefix(16))... NOT in knownNullifiers")
                }
            }
        }

        for (_, output) in outputs.enumerated() {
            // Convert hex strings to binary data
            guard let cmuDisplay = Data(hexString: output.cmu),
                  let epkDisplay = Data(hexString: output.ephemeralKey),
                  let encCiphertext = Data(hexString: output.encCiphertext) else {
                continue
            }

            // Reverse byte order: display format (big-endian) -> wire format (little-endian)
            let epk = epkDisplay.reversedBytes()
            let cmu = cmuDisplay.reversedBytes()

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

            print("💰 Found note: \(value) zatoshis at height \(height)")
            print("📝 Diversifier bytes to store: \(Array(Data(diversifier)).map { String(format: "%02x", $0) }.joined(separator: ", "))")

            let txidData = Data(hexString: txid) ?? Data()

            // Compute nullifier using spending key (required for proper PRF_nf)
            let nullifier = try rustBridge.computeNullifier(
                spendingKey: spendingKey,
                diversifier: Data(diversifier),
                value: value,
                rcm: Data(rcm),
                position: treePosition
            )

            // Debug: Log the computed nullifier (first 16 chars only for privacy)
            let nullifierHex = nullifier.map { String(format: "%02x", $0) }.joined()
            print("📝 NOTE DEBUG: Computed nullifier \(nullifierHex.prefix(16))... at position \(treePosition) for \(value) zatoshi note")

            knownNullifiers.insert(nullifier)
            print("📝 NOTE DEBUG: knownNullifiers now has \(knownNullifiers.count) entries")

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
                let isPending = NetworkManager.shared.isPendingOutgoingSync(txid: txid)
                if isPending {
                    isChangeOutput = true
                    print("💰 Detected pending outgoing tx \(txid.prefix(12))... (change output)")
                }
            }

            if isChangeOutput {
                print("💰 Skipping change output (txid already exists as sent): \(value) zatoshis")
                // NO notification for change outputs - don't trigger fireworks on sender
            } else {
                // Real incoming tx found in block (0 confirmations)
                // Track it as pending incoming - notification will be sent once it has 1+ confirmations
                Task { @MainActor in
                    await NetworkManager.shared.trackPendingIncoming(txid: txid, amount: value)
                }
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
            debugLog(.sync, "⚡ Batch \(heightRange.lowerBound)-\(heightRange.upperBound): 0 outputs, \(totalSpends) spends collected")
            return
        }

        debugLog(.sync, "🚀 Parallel decrypting \(batchOutputs.count) outputs from \(heightRange.count) blocks...")

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
        let bundledTreeHeight = ZipherXConstants.bundledTreeHeight
        var notesFound = 0

        for (idx, maybeNote) in results.enumerated() {
            guard let note = maybeNote else { continue }
            notesFound += 1

            let info = batchOutputs[idx]
            let output = info.output

            // Convert CMU to wire format for database/position lookup
            guard let cmuDisplay = Data(hexString: output.cmu) else { continue }
            let cmu = cmuDisplay.reversedBytes()

            print("💰 Found note: \(note.value) zatoshis at height \(info.height) (parallel)")

            let txidData = Data(hexString: info.txid) ?? Data()

            // Look up position from bundled CMU data
            var position: UInt64 = 0
            var needsNullifierFix = false

            if let bundledData = cmuDataForPositionLookup {
                if let realPos = ZipherXFFI.findCMUPosition(cmuData: bundledData, targetCMU: cmu) {
                    position = realPos
                    debugLog(.sync, "📍 Found CMU position in bundled tree: \(position)")
                } else {
                    needsNullifierFix = true
                    if info.height > bundledTreeHeight {
                        debugLog(.sync, "⚠️ Note at height \(info.height) > bundled: nullifier fix needed")
                    }
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
                // Track as incoming
                Task { @MainActor in
                    await NetworkManager.shared.trackPendingIncoming(txid: info.txid, amount: note.value)
                }
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
            print("🚀 Parallel batch: found \(notesFound)/\(batchOutputs.count) notes using \(ZipherXFFI.getRayonThreads()) threads")
        }
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
                    print("💸 Note spent at height \(height)")
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

            print("💰 Found note: \(value) zatoshis at height \(height)")
            print("📝 Diversifier bytes to store: \(Array(Data(diversifier)).map { String(format: "%02x", $0) }.joined(separator: ", "))")

            let txidData = Data(hexString: txid) ?? Data()

            // Try to find real position from bundled CMU data
            var position: UInt64 = 0
            var needsNullifierFix = false
            let bundledTreeHeight = ZipherXConstants.bundledTreeHeight

            if let bundledData = cmuDataForPositionLookup {
                if let realPos = ZipherXFFI.findCMUPosition(cmuData: bundledData, targetCMU: cmu) {
                    position = realPos
                    print("📍 Found CMU position in bundled tree: \(position)")
                } else {
                    // CMU not in bundled tree - position 0 is WRONG
                    // CRITICAL FIX: Always set needsNullifierFix when CMU lookup fails
                    // This prevents wrong nullifiers from being added to knownNullifiers
                    needsNullifierFix = true
                    if height > bundledTreeHeight {
                        print("⚠️ Note at height \(height) > bundled \(bundledTreeHeight): nullifier will be fixed in PHASE 2.5")
                    } else {
                        print("⚠️ CMU not found in bundled tree (height \(height) <= bundled \(bundledTreeHeight)): nullifier will be fixed in PHASE 2.5")
                    }
                }
            } else {
                // No bundled data available - can't compute correct position
                // CRITICAL FIX: Always set needsNullifierFix when no bundled data
                needsNullifierFix = true
                if height > bundledTreeHeight {
                    print("⚠️ Note at height \(height) > bundled \(bundledTreeHeight) (no bundled data): nullifier will be fixed in PHASE 2.5")
                } else {
                    print("⚠️ No bundled CMU data for note at height \(height): nullifier will be fixed in PHASE 2.5")
                }
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
                let isPending = NetworkManager.shared.isPendingOutgoingSync(txid: txid)
                if isPending {
                    isChangeOutput = true
                    print("💰 Detected pending outgoing tx \(txid.prefix(12))... (change output)")
                }
            }

            if isChangeOutput {
                print("💰 Skipping change output (txid already exists as sent): \(value) zatoshis")
                // NO notification for change outputs - don't trigger fireworks on sender
            } else {
                // Real incoming tx found in block (0 confirmations)
                // Track it as pending incoming - notification will be sent once it has 1+ confirmations
                Task { @MainActor in
                    await NetworkManager.shared.trackPendingIncoming(txid: txid, amount: value)
                }
                let memoText = String(data: memo.prefix(while: { $0 != 0 }), encoding: .utf8)
                try database.recordReceivedTransaction(
                    txid: txidData,
                    height: height,
                    value: value,
                    memo: memoText
                )
            }

            print("📝 Stored note \(noteId) with value \(value)")

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
                print("📋 Queued note \(noteId) for nullifier fix in PHASE 2.5")
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

            // Debug: print sizes
            if height >= 2918699 {
                print("📊 Output \(index): cmu=\(cmu.count)B epk=\(epk.count)B enc=\(encCiphertext.count)B pos=\(treePosition)")
            }

            // Try to decrypt with spending key (uses zcash_primitives internally for IVK derivation)
            guard let decryptedData = ZipherXFFI.tryDecryptNoteWithSK(
                spendingKey: spendingKey,
                epk: epk,
                cmu: cmu,
                ciphertext: encCiphertext
            ) else {
                // Not addressed to us - CMU still added to tree above
                if height >= 2918699 {
                    print("🔒 Output \(index) at height \(height) not for us (could not decrypt)")
                }
                continue
            }
            print("🔓 Successfully decrypted note \(index) at height \(height)!")

            // Create witness for this note (must be done immediately after append)
            let witnessIndex = ZipherXFFI.treeWitnessCurrent()
            if witnessIndex == UInt64.max {
                print("⚠️ Failed to create witness for note at height \(height)")
            }

            // Parse decrypted note data: diversifier(11) + value(8) + rcm(32) + memo(512)
            guard decryptedData.count >= 51 else {
                print("⚠️ Decrypted data too short: \(decryptedData.count)")
                continue
            }

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

            // We found a note addressed to us!
            print("💰 Found note: \(value) zatoshis at height \(height)")

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
                let isPending = NetworkManager.shared.isPendingOutgoingSync(txid: txid)
                if isPending {
                    isChangeOutput = true
                    print("💰 Detected pending outgoing tx \(txid.prefix(12))... (change output)")
                }
            }

            if isChangeOutput {
                print("💰 Skipping change output (txid already exists as sent): \(note.value) zatoshis")
                // NO notification for change outputs - don't trigger fireworks on sender
            } else {
                // Send notification for real incoming payments only
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

            print("💰 Stored note \(noteId): \(note.value) zatoshis at height \(height), tree pos \(position)")
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
            let isPending = NetworkManager.shared.isPendingOutgoingSync(txid: txidHex)
            if isPending {
                isChangeOutput = true
                print("💰 Detected pending outgoing tx \(txidHex.prefix(12))... (change output)")
            }
        }

        if isChangeOutput {
            print("💰 Skipping change output (txid already exists as sent): \(note.value) zatoshis")
            // Don't record change outputs in transaction history - they would confuse the user
            // The note is still saved and adds to balance, but won't show as separate "RECEIVED"
            // NO notification for change outputs - don't trigger fireworks on sender
        } else {
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

        print("💰 Found note: \(note.value) zatoshis at height \(height)")
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
            print("❌ No valid chain heights available")
            throw ScanError.networkError
        }

        // Also validate HeaderStore against consensus
        let maxHeightDeviation: UInt64 = 10
        if let hsHeight = try? HeaderStore.shared.getLatestHeight() {
            if hsHeight > consensusHeight + maxHeightDeviation {
                print("🚨 [SECURITY] HeaderStore has FAKE headers up to \(hsHeight)!")
                print("🧹 [SECURITY] Clearing fake headers (consensus: \(consensusHeight))...")
                try? HeaderStore.shared.clearAllHeaders()
                print("✅ Fake headers cleared")
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
        print("🔄 P2P status reset - will re-test on next scan")
    }

    /// Test P2P block fetching by requesting a single recent block
    /// Call this before starting scan to verify P2P is working
    private func testP2PBlockFetching() async -> Bool {
        guard networkManager.isConnected else {
            print("⚠️ P2P test: Not connected to any peers")
            return false
        }

        // Try to fetch a recent block via P2P to verify it works
        // Use a block from HeaderStore (most recent one)
        guard let latestHeight = try? HeaderStore.shared.getLatestHeight(),
              let header = try? HeaderStore.shared.getHeader(at: latestHeight) else {
            print("⚠️ P2P test: No headers in store to test with")
            return false
        }

        print("🔍 Testing P2P block fetch at height \(latestHeight)...")

        do {
            // Try to get this block via P2P
            guard let peer = networkManager.peers.first else {
                print("⚠️ P2P test: No peers available")
                return false
            }

            let block = try await peer.getBlockByHash(hash: header.blockHash)
            print("✅ P2P test: Successfully fetched block at height \(latestHeight) with \(block.transactions.count) transactions")
            return true
        } catch {
            print("❌ P2P test: Failed to fetch block - \(error.localizedDescription)")
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
                // P2P failed - mark it as not working and fall back
                if FilterScanner.p2pBlockFetchingWorks == nil {
                    print("⚠️ P2P block fetch failed, will use InsightAPI for remaining blocks")
                    FilterScanner.p2pBlockFetchingWorks = false
                }
                if useP2POnly {
                    throw error
                }
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
                for (h, _, txData) in results {
                    blockData.append((h, txData))
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
                    print("📡 P2P: Got shielded data for \(blockData.count) blocks")
                    return blockData
                } else if !blockData.isEmpty {
                    // Got blocks but no shielded data - P2P parsing may be broken
                    // Don't mark as working, fall through to InsightAPI
                    print("⚠️ P2P: Got \(blockData.count) blocks but no shielded tx data - will try InsightAPI")
                    FilterScanner.p2pBlockFetchingWorks = false
                }
            } catch {
                if FilterScanner.p2pBlockFetchingWorks == nil {
                    print("⚠️ P2P batch fetch failed, switching to InsightAPI")
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
        print("🔧 PHASE 1.5: Pre-computing witnesses for notes in bundled range...")

        do {
            // Get the account ID
            guard let account = try database.getAccount(index: 0) else {
                print("⚠️ No account found, skipping witness pre-computation")
                return
            }

            // Get all notes that have empty witnesses (from bundled range scanning)
            let notes = try database.getAllUnspentNotes(accountId: account.id)
            let notesNeedingWitness = notes.filter { note in
                // Check if witness is empty (all zeros) or wrong size
                note.witness.count != 1028 || note.witness.allSatisfy { $0 == 0 }
            }

            if notesNeedingWitness.isEmpty {
                print("✅ All notes already have valid witnesses")
                return
            }

            print("📝 Found \(notesNeedingWitness.count) note(s) needing witness computation")

            for (index, note) in notesNeedingWitness.enumerated() {
                guard let cmu = note.cmu, cmu.count == 32 else {
                    print("⚠️ Note \(note.id) missing CMU, cannot compute witness")
                    continue
                }

                print("🔧 Computing witness for note \(index + 1)/\(notesNeedingWitness.count)...")

                // Use the FFI function to compute witness from bundled data
                if let result = ZipherXFFI.treeCreateWitnessForCMU(cmuData: bundledData, targetCMU: cmu) {
                    // Update the note with the computed witness
                    try database.updateNoteWitness(noteId: note.id, witness: result.witness)
                    print("✅ Computed witness for note \(note.id) at position \(result.position)")
                } else {
                    print("⚠️ Could not compute witness for note \(note.id) - CMU may be beyond bundled tree")
                }
            }

            print("✅ PHASE 1.5 complete: witness pre-computation finished")

        } catch {
            print("❌ Error pre-computing witnesses: \(error)")
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

    var errorDescription: String? {
        switch self {
        case .networkError:
            return "Network error during scan"
        case .decodingError:
            return "Failed to decode filter or block"
        case .databaseError:
            return "Database error during scan"
        }
    }
}

