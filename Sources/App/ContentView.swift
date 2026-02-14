import SwiftUI

struct ContentView: View {
    @EnvironmentObject var walletManager: WalletManager
    @EnvironmentObject var networkManager: NetworkManager
    @EnvironmentObject var themeManager: ThemeManager
    @StateObject private var biometricManager = BiometricAuthManager.shared
    #if os(macOS)
    @StateObject private var modeManager = WalletModeManager.shared  // FIX #448: Observe wallet source changes
    #endif
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab: Tab = .balance
    @State private var isFirstLaunch: Bool = false
    @State private var isInitialSync: Bool = true  // Track initial sync state
    @State private var hasCompletedInitialSync: Bool = false  // Prevent re-running
    // FIX #1273: Lock screen ALWAYS starts TRUE — auth is mandatory at startup.
    // The biometric setting controls which auth type (Face ID vs passcode), not whether auth is required.
    @State private var isShowingLockScreen: Bool = true
    @State private var lastActivityTime: Date = Date()  // Track user activity
    @State private var inactivityTimer: Timer?  // Timer to check inactivity
    @State private var wasInBackground: Bool = false  // FIX #258: Track if we were in background
    @State private var hasAcceptedDisclaimer: Bool = UserDefaults.standard.bool(forKey: "hasAcceptedDisclaimer")

    // Startup timing - uses walletCreationTime from WalletManager
    // This ensures timing starts from when user clicks create/import/restore, not app launch
    @State private var syncCompletionDuration: TimeInterval? = nil
    @State private var showCompletionScreen: Bool = false
    private let estimatedSyncDuration: TimeInterval = 60  // ~60 seconds estimated for new wallet

    // FIX #1079: Track max progress to ensure progress NEVER goes backward
    @State private var maxDisplayedProgress: Double = 0.0

    // DEBUG: Set to true to pause at sync completion with a confirmation button
    private let DEBUG_PAUSE_AT_COMPLETION = true
    @State private var debugWaitingForConfirmation = false
    @State private var debugCompletionMessage = ""

    /// Get the effective start time for sync timing display
    /// FIX #1120: Uses rescanStartTime for Full Rescan, walletCreationTime for initial sync
    private var effectiveStartTime: Date {
        if walletManager.isFullRescan, let rescanStart = walletManager.rescanStartTime {
            return rescanStart
        }
        return walletManager.walletCreationTime ?? appStartupTime
    }

    // FIX #1276: Task id that changes when wallet mode switches (macOS only).
    // On iOS there's no mode switching, so constant id = task runs once.
    #if os(macOS)
    private var startupTaskId: String { modeManager.walletSource.rawValue }
    #else
    private var startupTaskId: String { "zipherx" }
    #endif

    // Cypherpunk mode sheet states
    @State private var showCypherpunkSettings = false
    @State private var showCypherpunkSend = false
    @State private var showCypherpunkReceive = false
    @State private var showCypherpunkChat = false

    // Disk space warning
    @State private var showInsufficientDiskSpaceAlert = false
    @State private var availableDiskSpace: String = ""

    // FIX #164: Repair needed warning (blocks were skipped, spent notes may be missed)
    @State private var showRepairNeededAlert = false
    @State private var repairNeededReason = ""

    // FIX #175: Sybil attack and external wallet spend alerts
    @State private var showSybilAttackAlert = false
    @State private var showExternalWalletSpendAlert = false

    // FIX #231: Reduced verification warning (insufficient peers for consensus)
    @State private var showReducedVerificationAlert = false

    // FIX #888: Download failed alert (ask user to retry import)
    @State private var showDownloadFailedAlert = false

    // FIX #409: Critical health alert
    @State private var showCriticalHealthAlert = false

    // FIX #409: Computed property to avoid complex type-check expression
    private var healthAlertTitle: String {
        guard let alert = networkManager.criticalHealthAlert else { return "⚠️ Health Issue" }
        return "\(alert.severity.rawValue) \(alert.title)"
    }

    enum Tab {
        case balance, send, receive, chat, settings
    }

    var body: some View {
        // Show disclaimer on first launch before anything else
        if !hasAcceptedDisclaimer {
            DisclaimerView(hasAcceptedDisclaimer: $hasAcceptedDisclaimer)
        } else {
            mainAppContent
        }
    }

    // MARK: - Main App Content (after disclaimer accepted)

    private var mainAppContent: some View {
        ZStack {
            // Themed background
            themeManager.currentTheme.backgroundColor
                .ignoresSafeArea()

            // Show main wallet view ONLY if:
            // 1. Wallet is created AND
            // 2. Mnemonic backup is NOT pending (user has confirmed backup)
            if walletManager.isWalletCreated && !walletManager.isMnemonicBackupPending {
                mainWalletView
                    // FIX #1276: Use .task(id:) so this re-runs when switching between
                    // wallet.dat and ZipherX modes. Without this, if the app starts in
                    // wallet.dat mode (task returns early), switching to ZipherX mode
                    // never triggers the P2P startup sequence.
                    .task(id: startupTaskId) {
                        // FIX #1273: Skip entire P2P startup in wallet.dat (Full Node) mode.
                        // FullNodeWalletView has its own .task for RPC-based startup.
                        // Running P2P tree loading, header sync, etc. is wasteful and causes
                        // confusing duplicate "Waiting for authentication" log messages.
                        #if os(macOS)
                        if modeManager.walletSource == .walletDat {
                            print("🔐 FIX #1273: wallet.dat mode — skipping P2P startup task")
                            // FIX #1278: Must clear initial sync state so CypherpunkSyncView doesn't
                            // overlay on top of FullNodeWalletView (isInitialSync defaults to true).
                            await MainActor.run {
                                isInitialSync = false
                                hasCompletedInitialSync = true
                            }
                            return
                        }
                        #endif

                        // FIX #1273: SECURITY — Wait for authentication before starting ANY wallet operations.
                        // The lock screen is a visual overlay, but the .task fires immediately.
                        // Without this guard, network connections, tree loading, header sync, and
                        // balance queries all run BEHIND the lock screen before user authenticates.
                        // Auth is ALWAYS mandatory at startup (not just when biometric is enabled).
                        if !biometricManager.hasAuthenticatedThisSession {
                            print("🔐 FIX #1273: Waiting for authentication before starting wallet operations...")
                            while !biometricManager.hasAuthenticatedThisSession {
                                try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
                                if Task.isCancelled { return }
                            }
                            print("🔐 FIX #1273: Authentication confirmed — proceeding with startup")
                        }

                        // FIX #881: Startup timing profiler for performance analysis
                        let startupStart = CFAbsoluteTimeGetCurrent()
                        var phaseTimings: [(String, Double)] = []

                        func logPhase(_ name: String, since: CFAbsoluteTime) -> Void {
                            let elapsed = CFAbsoluteTimeGetCurrent() - since
                            phaseTimings.append((name, elapsed))
                            print("⏱️ FIX #881: \(name) took \(String(format: "%.2f", elapsed * 1000))ms")
                        }

                        print("DEBUGZIPHERX: 🚀 Task: Starting initial sync task...")

                        // Only run initial sync once
                        guard !hasCompletedInitialSync else {
                            print("DEBUGZIPHERX: 🚀 Task: Already completed, returning")
                            return
                        }

                        // CHECK DISK SPACE AT STARTUP (need ~750 MB for shielded outputs download + processing)
                        let diskSpaceBytes = BundledShieldedOutputs.getAvailableDiskSpace()
                        let requiredBytes: Int64 = 750_000_000 // 750 MB
                        if diskSpaceBytes < requiredBytes {
                            let formatter = ByteCountFormatter()
                            formatter.allowedUnits = [.useGB, .useMB]
                            formatter.countStyle = .file
                            availableDiskSpace = formatter.string(fromByteCount: diskSpaceBytes)
                            await MainActor.run {
                                showInsufficientDiskSpaceAlert = true
                            }
                            print("🚨 INSUFFICIENT DISK SPACE: \(availableDiskSpace) available, need ~750 MB")
                        } else {
                            let formatter = ByteCountFormatter()
                            formatter.allowedUnits = [.useGB, .useMB]
                            formatter.countStyle = .file
                            print("✅ Disk space OK: \(formatter.string(fromByteCount: diskSpaceBytes)) available")
                        }

                        // Suppress background sync during initial startup to avoid race conditions
                        networkManager.suppressBackgroundSync = true

                        // Note: Timing uses global appStartupTime (from ZipherXApp.swift)
                        // which is captured at the very first moment of app launch

                        print("DEBUGZIPHERX: 🚀 Task: isTreeLoaded = \(walletManager.isTreeLoaded)")

                        // Check if this is first launch (tree not yet cached)
                        isFirstLaunch = !walletManager.isTreeLoaded && walletManager.treeLoadProgress < 1.0

                        // FIX #1341: On first import, start P2P connection early (parallel with tree loading).
                        // Tree takes ~24s (ZSTD + deserialize), peers need ~5-10s.
                        // By connecting now, peers are ready when FULL START needs them — saves 10s.
                        if isFirstLaunch {
                            Task { try? await networkManager.connect() }
                        }

                        // Trigger tree loading if not already loaded
                        // This handles the case where wallet was just created/imported
                        if !walletManager.isTreeLoaded {
                            print("DEBUGZIPHERX: 🚀 Task: Triggering tree load...")
                            await walletManager.ensureTreeLoaded()
                        }

                        // WAIT for tree to load before proceeding with network operations
                        var treeWaitCount = 0
                        while !walletManager.isTreeLoaded {
                            treeWaitCount += 1
                            if treeWaitCount % 50 == 0 {
                                print("DEBUGZIPHERX: 🚀 Task: Still waiting for tree... (\(treeWaitCount))")
                            }
                            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                        }
                        print("DEBUGZIPHERX: 🚀 Task: Tree is loaded!")

                        // ==========================================================
                        // FAST START MODE: For consecutive app launches
                        // If wallet is already synced, show cached balance immediately
                        // and do background sync later (achieves <5s startup)
                        // ==========================================================
                        var lastScannedHeight = (try? WalletDatabase.shared.getLastScannedHeight()) ?? 0
                        let cachedChainHeight = UInt64(UserDefaults.standard.integer(forKey: "cachedChainHeight"))

                        // FIX #168: Use verified_checkpoint_height for INSTANT startup
                        // If checkpoint == lastScannedHeight, wallet is fully verified - NO health checks needed!
                        let checkpointHeight = (try? WalletDatabase.shared.getVerifiedCheckpointHeight()) ?? 0

                        // FIX #1051: Recover from corrupted lastScannedHeight
                        // If checkpoint exists but lastScannedHeight=0, restore from checkpoint
                        // This prevents unnecessary FULL START when wallet was previously synced
                        if lastScannedHeight == 0 && checkpointHeight > 0 {
                            print("🔧 FIX #1051: lastScannedHeight=0 but checkpoint=\(checkpointHeight) - recovering...")
                            // Use empty hash - will be updated on next scan
                            try? WalletDatabase.shared.updateLastScannedHeight(checkpointHeight, hash: Data())
                            lastScannedHeight = checkpointHeight
                            print("✅ FIX #1051: Restored lastScannedHeight to \(checkpointHeight)")
                        }

                        let blocksBehind = cachedChainHeight > lastScannedHeight ? cachedChainHeight - lastScannedHeight : 0
                        let checkpointGap = lastScannedHeight > checkpointHeight ? lastScannedHeight - checkpointHeight : 0
                        let isCheckpointValid = checkpointHeight > 0 && checkpointGap <= 10  // Within 10 blocks = valid

                        print("📍 FIX #168: Checkpoint=\(checkpointHeight), LastScanned=\(lastScannedHeight), Gap=\(checkpointGap)")

                        // FIX #120: Check if cached chain height is stale
                        // If lastScannedHeight is significantly AHEAD of cached height, the cache is stale
                        // This can happen if P2P peers reported fake heights or cache wasn't updated
                        let cacheIsStale = lastScannedHeight > cachedChainHeight + 100
                        if cacheIsStale {
                            print("⚠️ STALE CACHE: lastScannedHeight (\(lastScannedHeight)) >> cachedChainHeight (\(cachedChainHeight))")
                            print("⚠️ Disabling FAST START - need to verify chain height via P2P")
                        }

                        // ==========================================================
                        // FIX #535: CRITICAL - Sync headers BEFORE showing UI as "ready"
                        // The app MUST have complete headers before ANY operation
                        // Otherwise transactions fail with "Anchor NOT FOUND" errors
                        // ==========================================================
                        let headerStoreHeight = (try? HeaderStore.shared.getLatestHeight()) ?? 0
                        print("📍 FIX #535: HeaderStore height at startup: \(headerStoreHeight), LastScanned: \(lastScannedHeight)")

                        // Load bundled headers from boost file FIRST (instant)
                        // FIX #1341: Skip on first import (lastScannedHeight=0) — saves 207s on iOS.
                        // Boost headers (476969-2988797) are NOT needed for PHASE 1/2 scanning:
                        // - PHASE 1 uses local boost shielded outputs (trial decryption)
                        // - PHASE 2 fetches P2P headers for delta range (2988798+) only
                        // Headers load in background after import completes.
                        if headerStoreHeight < 2964000 && lastScannedHeight > 0 {
                            print("📦 FIX #535: Loading bundled headers from boost file...")
                            await MainActor.run {
                                walletManager.setConnecting(true, status: "Loading block headers...")
                            }
                            let (loadedBoost, boostEndHeight) = await walletManager.loadHeadersFromBoostFile()
                            if loadedBoost {
                                print("✅ FIX #535: Loaded bundled headers up to \(boostEndHeight)")
                            }
                        } else if lastScannedHeight == 0 {
                            print("⏭️ FIX #1341: Skipping boost header loading on first import (saves 207s)")
                        }

                        // Connect to P2P network for delta header sync
                        // FIX #1341: Skip on first import — FULL START handles its own P2P connection
                        // and PHASE 2 fetches delta headers via P2P internally.
                        let needsHeaderSync = lastScannedHeight > 0
                        if needsHeaderSync {
                            print("🔗 FIX #535: Connecting to P2P network for header sync...")
                            do {
                                try await networkManager.connect()

                                // Wait for peers with chain height
                                var peerWait = 0
                                let maxPeerWait = 300 // 30 seconds
                                var chainHeight: UInt64 = 0

                                while (networkManager.connectedPeers < 3 || chainHeight == 0) && peerWait < maxPeerWait {
                                    try? await Task.sleep(nanoseconds: 100_000_000)
                                    peerWait += 1
                                    chainHeight = networkManager.chainHeight

                                    if peerWait % 50 == 0 {
                                        print("⏳ FIX #535: Waiting for peers... peers=\(networkManager.connectedPeers), chainHeight=\(chainHeight)")
                                    }
                                }

                                // Sync headers to match current chain height
                                let currentHeaderHeight = (try? HeaderStore.shared.getLatestHeight()) ?? 0
                                if chainHeight > currentHeaderHeight {
                                    let headersNeeded = chainHeight - currentHeaderHeight
                                    print("📥 FIX #535: Syncing \(headersNeeded) headers from P2P...")
                                    await MainActor.run {
                                        walletManager.setConnecting(true, status: "Syncing \(headersNeeded) headers...")
                                    }

                                    let hsm = HeaderSyncManager(headerStore: HeaderStore.shared, networkManager: networkManager)
                                    hsm.onProgress = { progress in
                                        Task { @MainActor in
                                            let percent = Int(progress.percentComplete)
                                            walletManager.setConnecting(true, status: "Syncing headers \(percent)%")
                                        }
                                    }

                                    try await hsm.syncHeaders(from: currentHeaderHeight + 1, maxHeaders: headersNeeded + 100)
                                    print("✅ FIX #535: Header sync complete")
                                }
                            } catch {
                                print("⚠️ FIX #535: Header sync failed: \(error.localizedDescription)")
                            }
                        }

                        // Fast start if: already synced (within 50 blocks) AND has cached data AND cache is not stale
                        let isFastStart = lastScannedHeight > 0 && cachedChainHeight > 0 && blocksBehind <= 50 && !cacheIsStale

                        if isFastStart {
                            // FIX #768: Only show "blocks behind" if actually behind, otherwise show "synced"
                            let lagInfo = blocksBehind > 0 ? "\(blocksBehind) blocks behind" : "synced"
                            print("⚡ FAST START MODE: Wallet synced to \(lastScannedHeight), chain at \(cachedChainHeight) (\(lagInfo))")

                            // ================================================================
                            // FIX #477: VALIDATE last_scanned_height vs HeaderStore
                            // Prevent race condition where database says we're at height X
                            // but HeaderStore only has headers up to height Y (where Y < X)
                            // ================================================================
                            let headerStoreHeight = (try? HeaderStore.shared.getLatestHeight()) ?? 0
                            print("📍 FIX #477: lastScannedHeight=\(lastScannedHeight), HeaderStore=\(headerStoreHeight), gap=\(lastScannedHeight > headerStoreHeight ? lastScannedHeight - headerStoreHeight : 0)")

                            // CRITICAL: If last_scanned_height is ahead of HeaderStore, we have a problem
                            // The scanner will try to scan blocks we don't have headers for!
                            var effectiveStartHeight = lastScannedHeight
                            if lastScannedHeight > headerStoreHeight && headerStoreHeight > 0 {
                                // FIX #749: Only trigger race condition fix if HeaderStore has SOME headers
                                // If headerStoreHeight == 0, headers were just cleared by FIX #677 for fresh reload
                                // Don't reset lastScannedHeight - boost file will reload headers soon
                                let heightGap = lastScannedHeight - headerStoreHeight
                                print("🚨 FIX #477: RACE CONDITION DETECTED!")
                                print("🚨   Database says we're at height \(lastScannedHeight)")
                                print("🚨   But HeaderStore only has headers up to \(headerStoreHeight)")
                                print("🚨   Gap: \(heightGap) blocks")
                                print("🚨   This would cause scanner to skip blocks!")
                                print("🔧 FIX #477: Using effective start height = HeaderStore height (\(headerStoreHeight))")
                                print("🔧 FIX #477: Database last_scanned_height will be corrected after header sync")

                                // Use HeaderStore height as effective start
                                effectiveStartHeight = headerStoreHeight

                                // Reset database to match HeaderStore
                                try? WalletDatabase.shared.updateLastScannedHeight(headerStoreHeight, hash: Data(count: 32))
                            } else if headerStoreHeight == 0 {
                                // FIX #749: HeaderStore is empty (just cleared by FIX #677)
                                // Don't reset lastScannedHeight - headers will be reloaded from boost file
                                print("📋 FIX #749: HeaderStore is empty (headers being reloaded)")
                                print("📋 FIX #749: Keeping lastScannedHeight=\(lastScannedHeight) intact")
                            }

                            // ================================================================
                            // FIX #168: CHECKPOINT-BASED INSTANT START
                            // If checkpoint is valid (within 10 blocks of effectiveStartHeight), wallet
                            // state is fully verified - skip ALL blocking operations!
                            // ================================================================

                            // FIX #408: Verify HeaderStore is healthy before INSTANT START
                            // Checkpoint proves PAST state was valid, but HeaderStore may have
                            // become stale. Without healthy headers, new blocks can't be fetched.
                            // Reuse headerStoreHeight from above (FIX #477)
                            let headersBehind = cachedChainHeight > headerStoreHeight ? cachedChainHeight - headerStoreHeight : 0
                            let isHeaderStoreHealthy = headerStoreHeight > 0 && headersBehind <= 100  // Within 100 blocks

                            print("📍 FIX #408: HeaderStore=\(headerStoreHeight), CachedChain=\(cachedChainHeight), Behind=\(headersBehind)")

                            if isCheckpointValid && isHeaderStoreHealthy {
                                // FIX #881: Profile INSTANT START phases
                                let instantStartBegin = CFAbsoluteTimeGetCurrent()

                                print("⚡ FIX #168: INSTANT START - checkpoint valid (gap=\(checkpointGap))")
                                print("⚡ FIX #408: HeaderStore healthy (within \(headersBehind) blocks)")

                                // FIX #530: CRITICAL - Initialize tree from boost file before health checks
                                // Without this, FFI tree state is corrupted from previous session
                                // This causes DeltaCMU manager to clear its bundle (tree root mismatch)
                                print("🌳 FIX #530: Initializing tree from boost file...")
                                await MainActor.run {
                                    walletManager.setConnecting(true, status: "Initializing commitment tree...")
                                }

                                // FIX #819: Validate CMU cache byte order BEFORE loading
                                // Stale cache from before FIX #743 has reversed CMUs causing tree root mismatch
                                // FIX #881: This is now O(1) after first validation thanks to version caching
                                let cacheValidStart = CFAbsoluteTimeGetCurrent()
                                let cacheValid = await CommitmentTreeUpdater.shared.validateAndClearStaleCMUCache()
                                logPhase("CMU cache validation", since: cacheValidStart)
                                if !cacheValid {
                                    print("🗑️ FIX #819: Stale CMU cache cleared - will regenerate from boost file")
                                }

                                do {
                                    // FIX #881: Time tree deserialization
                                    let treeDeserializeStart = CFAbsoluteTimeGetCurrent()

                                    // Extract and deserialize tree from cached boost file
                                    let serializedTree = try await CommitmentTreeUpdater.shared.extractSerializedTree()
                                    if ZipherXFFI.treeDeserialize(data: serializedTree) {
                                        let treeSize = ZipherXFFI.treeSize()
                                        print("🌳 FIX #530: Tree deserialized: \(treeSize) commitments from boost file")

                                        // FIX #534: CRITICAL - Validate tree root after deserialization
                                        // The Python serialization might be incompatible with Rust deserialization
                                        // If tree root doesn't match manifest, fall back to building from CMUs
                                        if let manifest = CommitmentTreeUpdater.shared.loadCachedManifest(),
                                           let deserializedRoot = ZipherXFFI.treeRoot() {
                                            let expectedRoot = manifest.tree_root
                                            // FIX #548: Reverse bytes for comparison (manifest stores big-endian, treeRoot returns little-endian)
                                            let actualRoot = Data(deserializedRoot.reversed()).hexString

                                            if actualRoot != expectedRoot {
                                                print("❌ FIX #534: Tree root MISMATCH after deserialization!")
                                                print("   Expected: \(expectedRoot)")
                                                print("   Actual:   \(actualRoot)")
                                                print("🔄 FIX #534: Falling back to building tree from CMUs...")

                                                // Reset and build from CMUs instead
                                                _ = ZipherXFFI.treeInit()

                                                // First, try to load from legacy cache
                                                var cmuData: Data?
                                                var cmuLoaded = false

                                                if let cmuPath = await CommitmentTreeUpdater.shared.getCachedCMUFilePath(),
                                                   FileManager.default.fileExists(atPath: cmuPath.path) {
                                                    cmuData = try? Data(contentsOf: cmuPath)
                                                }

                                                // If CMU file doesn't exist or failed to load, extract from boost file
                                                if cmuData == nil {
                                                    print("🔧 FIX #534: CMU cache not found - extracting from boost file...")
                                                    do {
                                                        cmuData = try await CommitmentTreeUpdater.shared.extractCMUsInLegacyFormat()
                                                        print("✅ FIX #534: Extracted CMUs from boost file: \(cmuData!.count) bytes")
                                                    } catch {
                                                        print("❌ FIX #534: Failed to extract CMUs from boost file: \(error)")
                                                    }
                                                }

                                                // Build tree from CMUs
                                                if let data = cmuData {
                                                    print("🔍 FIX #534 DEBUG: About to load {} bytes into tree...", data.count)
                                                    print("🔍 FIX #534 DEBUG: First 8 bytes (count): {}", data.prefix(8).hexString)
                                                    print("🔍 FIX #534 DEBUG: First CMU (bytes 8-40): {}", data.subdata(in: 8..<40).hexString)

                                                    if ZipherXFFI.treeLoadFromCMUs(data: data) {
                                                        let rebuiltSize = ZipherXFFI.treeSize()
                                                        print("✅ FIX #534: Rebuilt tree from CMUs: \(rebuiltSize) commitments")

                                                        // Verify the rebuilt tree root
                                                        if let rebuiltRoot = ZipherXFFI.treeRoot() {
                                                            // FIX #548: Reverse bytes for comparison (manifest stores big-endian, treeRoot returns little-endian)
                                                            let rebuiltRootHex = Data(rebuiltRoot.reversed()).hexString
                                                            print("🔍 FIX #534: Rebuilt tree root: \(rebuiltRootHex)")

                                                            if rebuiltRootHex == expectedRoot {
                                                                print("✅ FIX #534: Tree root MATCHES manifest - CMU build successful!")
                                                            } else {
                                                                print("⚠️ FIX #534: Tree root still MISMATCH - deleting corrupted cache")
                                                                // Delete corrupted cache so it will be regenerated
                                                                if let cmuPath = await CommitmentTreeUpdater.shared.getCachedCMUFilePath() {
                                                                    try? FileManager.default.removeItem(at: cmuPath)
                                                                    print("🗑️ FIX #534: Deleted corrupted CMU cache - will regenerate on next restart")
                                                                }
                                                            }
                                                        }
                                                    } else {
                                                        print("❌ FIX #534: Failed to build tree from CMUs")
                                                    }
                                                } else {
                                                    print("❌ FIX #534: No CMU data available - tree will be empty")
                                                }
                                            } else {
                                                print("✅ FIX #534: Tree root validation PASSED - deserialization is correct")
                                            }
                                        }

                                        // Load delta CMUs on top if available
                                        if let manifest = DeltaCMUManager.shared.getManifest(),
                                           manifest.endHeight > ZipherXConstants.effectiveTreeHeight {
                                            // FIX #840: ATOMIC delta append - eliminates TOCTOU race condition
                                            // Previous FIX #831 re-checked tree size but wasn't atomic.
                                            // FIX #840 holds all FFI locks throughout the check-and-append operation.
                                            let effectiveCMUCount = ZipherXConstants.effectiveTreeCMUCount

                                            print("📦 FIX #840: Loading delta CMUs from height \(ZipherXConstants.effectiveTreeHeight + 1) to \(manifest.endHeight)... [INSTANT START]")
                                            if let deltaCMUs = DeltaCMUManager.shared.loadDeltaCMUsForHeightRange(
                                                startHeight: ZipherXConstants.effectiveTreeHeight + 1,
                                                endHeight: manifest.endHeight
                                            ) {
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
                                                    print("✅ FIX #840: ATOMIC append SUCCESS - \(deltaCMUs.count) delta CMUs [INSTANT START]")
                                                    print("🌳 FIX #840: Tree size after delta: \(newTreeSize) commitments")

                                                case .skipped:
                                                    let currentTreeSize = ZipherXFFI.treeSize()
                                                    print("🔄 FIX #840: ATOMIC append SKIPPED - delta already present (size=\(currentTreeSize)) [INSTANT START]")

                                                case .mismatch:
                                                    let currentTreeSize = ZipherXFFI.treeSize()
                                                    print("⚠️ FIX #840: ATOMIC append MISMATCH - tree smaller than expected (size=\(currentTreeSize)) [INSTANT START]")

                                                case .error:
                                                    print("❌ FIX #840: ATOMIC append ERROR [INSTANT START]")
                                                }
                                            }
                                        }

                                        // FIX #748: Set isTreeLoaded for FAST START so background sync works
                                        // Previously the flag was only set during FULL START (import)
                                        // causing background sync to be blocked after FAST START
                                        await MainActor.run {
                                            walletManager.setTreeLoaded(true)
                                        }
                                        // FIX #881: Log tree deserialization time
                                        logPhase("Tree deserialization + delta load", since: treeDeserializeStart)
                                        print("✅ FIX #748: Set isTreeLoaded = true for FAST START")
                                    } else {
                                        print("⚠️ FIX #530: Failed to deserialize tree - will initialize fresh")
                                        _ = ZipherXFFI.treeInit()
                                    }
                                } catch {
                                    print("⚠️ FIX #530: Failed to extract tree: \(error.localizedDescription) - initializing fresh")
                                    _ = ZipherXFFI.treeInit()
                                }

                                // FIX #409: Run QUICK health check before showing UI
                                // User expects wallet state to be validated at startup
                                print("🏥 FIX #409: Running quick health check before INSTANT START...")
                                await MainActor.run {
                                    walletManager.setConnecting(true, status: "Validating wallet...")
                                }

                                // Load cached balance immediately
                                // FIX #881: Time balance loading
                                let balanceLoadStart = CFAbsoluteTimeGetCurrent()
                                walletManager.loadCachedBalance()
                                logPhase("Cached balance load", since: balanceLoadStart)

                                // FIX #1306: Wait for gap-fill to complete BEFORE health check.
                                // Gap-fill runs in background from validateAndSyncDeltaBundle (WalletManager init).
                                // If health check runs during gap-fill, it sees partially-rebuilt tree → mismatch
                                // → CRITICAL → "please restart" → user stuck in loop. Wait up to 120s.
                                let gapFillWaitStart = CFAbsoluteTimeGetCurrent()
                                var gapFillWaiting = false
                                for _ in 1...240 {  // Up to 120s (240 x 500ms)
                                    let isGapFilling = await MainActor.run { walletManager.isGapFillingDelta }
                                    if !isGapFilling { break }
                                    if !gapFillWaiting {
                                        gapFillWaiting = true
                                        print("⏳ FIX #1306: Waiting for gap-fill to complete before health check...")
                                        await MainActor.run {
                                            walletManager.setConnecting(true, status: "Rebuilding tree...")
                                        }
                                    }
                                    try? await Task.sleep(nanoseconds: 500_000_000)
                                }
                                if gapFillWaiting {
                                    let elapsed = CFAbsoluteTimeGetCurrent() - gapFillWaitStart
                                    print("✅ FIX #1306: Gap-fill wait complete after \(String(format: "%.1f", elapsed))s")
                                }

                                // Quick health check - only critical checks
                                // FIX #881: Time health checks
                                let healthCheckStart = CFAbsoluteTimeGetCurrent()
                                let healthResults = await WalletHealthCheck.shared.runAllChecks()
                                logPhase("Health checks", since: healthCheckStart)
                                // FIX #723: Filter critical issues properly - check .critical flag OR keywords
                                // Tree Root Validation returns critical=true but details say "Full Rescan" not "REPAIR"
                                let criticalIssues = healthResults.filter {
                                    !$0.passed && ($0.critical || $0.details.contains("REPAIR") || $0.details.contains("Full Rescan"))
                                }

                                // FIX #778: Track repair attempts to break infinite loop
                                // Root cause: After repair, tree root still mismatches because delta CMUs are wrong
                                // This causes: health check → repair → same mismatch → repair → loop
                                let repairAttemptsKey = "TreeRootRepairAttempts"
                                let repairSessionKey = "TreeRootRepairSession"
                                let currentSession = Int(Date().timeIntervalSince1970 / 300) // 5-minute sessions
                                let lastSession = UserDefaults.standard.integer(forKey: repairSessionKey)
                                var repairAttempts = UserDefaults.standard.integer(forKey: repairAttemptsKey)

                                // Reset counter if new session
                                if currentSession != lastSession {
                                    repairAttempts = 0
                                    UserDefaults.standard.set(currentSession, forKey: repairSessionKey)
                                }

                                let maxRepairAttempts = 2
                                let hasTreeRootIssue = criticalIssues.contains { $0.checkName == "Tree Root Validation" }

                                // FIX #778: Skip repair if we've already tried max times this session
                                if hasTreeRootIssue && repairAttempts >= maxRepairAttempts {
                                    print("🛑 FIX #778: Max repair attempts (\(maxRepairAttempts)) reached for tree root mismatch")
                                    print("🛑 FIX #778: Breaking loop - user must manually resync via Settings → Repair Database")
                                    // Clear the counter so next app restart can try again
                                    UserDefaults.standard.set(0, forKey: repairAttemptsKey)
                                    // Continue to UI without repair - user can manually fix
                                }

                                // FIX #686: Automatic repair at startup - NO user prompts
                                if !criticalIssues.isEmpty && !(hasTreeRootIssue && repairAttempts >= maxRepairAttempts) {
                                    print("⚠️ FIX #686: INSTANT START detected issues - triggering automatic repair")
                                    for issue in criticalIssues {
                                        print("⚠️ Critical Issue: \(issue.checkName) - \(issue.details)")
                                    }

                                    // FIX #723: Check for Tree Root mismatch specifically - needs FULL rescan
                                    let hasTreeRootMismatch = criticalIssues.contains {
                                        $0.checkName == "Tree Root Validation"
                                    }

                                    // FIX #1078: Check for Balance Integrity failure - needs FULL rescan
                                    let hasBalanceCorruption = criticalIssues.contains {
                                        $0.checkName == "Balance Integrity"
                                    }
                                    if hasBalanceCorruption {
                                        print("🔧 FIX #1078: Balance corruption detected (INSTANT START) - AUTO-triggering FULL RESCAN...")
                                    }

                                    // FIX #1302: Auto Full Rescan DISABLED. Phase 2 P2P has partial batch
                                    // cursor bug → creates phantom notes → inflated balance. Tree root
                                    // mismatch and balance corruption are logged but NOT auto-repaired.
                                    // User can manually trigger Full Rescan from Settings if needed.
                                    let needsFullRescan = false // was: hasTreeRootMismatch || hasBalanceCorruption

                                    // Trigger automatic repair instead of showing alert
                                    await MainActor.run {
                                        if hasBalanceCorruption {
                                            walletManager.setConnecting(true, status: "Balance issue - rebuilding from scratch...")
                                        } else if hasTreeRootMismatch {
                                            walletManager.setConnecting(true, status: "Tree mismatch - rebuilding from scratch...")
                                        } else {
                                            walletManager.setConnecting(true, status: "Repairing wallet state...")
                                        }
                                        // FIX #887: User-friendly task titles
                                        walletManager.syncTasks.append(SyncTask(id: "instant_repair", title: needsFullRescan ? "Repairing wallet" : "Auto-repair", status: .inProgress, progress: 0.0))
                                    }

                                    do {
                                        // FIX #723/#1078: For tree root mismatch OR balance corruption, force FULL rescan
                                        if needsFullRescan {
                                            if hasBalanceCorruption {
                                                print("🔧 FIX #1078: Balance corruption detected - triggering FULL RESCAN")
                                            }
                                            if hasTreeRootMismatch {
                                                print("🔧 FIX #723: Tree root mismatch detected - triggering FULL RESCAN")
                                            }
                                            // FIX #778: Increment repair attempt counter
                                            UserDefaults.standard.set(repairAttempts + 1, forKey: repairAttemptsKey)
                                            print("🔧 FIX #778: Repair attempt \(repairAttempts + 1)/\(maxRepairAttempts)")
                                        }
                                        try await walletManager.repairNotesAfterDownloadedTree(onProgress: { progress, current, total in
                                            print("🔧 FIX #686/723/1078: Instant repair progress \(Int(progress * 100))% (\(current)/\(total))")
                                            Task { @MainActor in
                                                walletManager.updateSyncTask(id: "instant_repair", status: .inProgress, detail: "\(current)/\(total)", progress: progress)
                                            }
                                        }, forceFullRescan: needsFullRescan)
                                        await MainActor.run {
                                            walletManager.updateSyncTask(id: "instant_repair", status: .completed)
                                        }
                                        print("✅ FIX #686/723: Instant repair complete")

                                        // FIX #778: Post-repair verification for tree root mismatch
                                        if hasTreeRootMismatch {
                                            print("🔍 FIX #778: Verifying tree root after repair...")
                                            let postRepairResults = await WalletHealthCheck.shared.runAllChecks()
                                            let stillHasTreeRootIssue = postRepairResults.contains {
                                                $0.checkName == "Tree Root Validation" && !$0.passed
                                            }
                                            if stillHasTreeRootIssue {
                                                print("⚠️ FIX #778: Tree root still mismatches after repair - will retry on next startup")
                                            } else {
                                                print("✅ FIX #778: Tree root now matches - resetting repair counter")
                                                UserDefaults.standard.set(0, forKey: repairAttemptsKey)
                                            }
                                        }
                                    } catch {
                                        print("❌ FIX #686/723: Instant repair failed: \(error.localizedDescription)")
                                        // Even on failure, continue to UI - user can manually trigger repair from Settings
                                    }
                                }

                                // FIX #557 v9: Rebuild all stale witnesses BEFORE showing UI!
                                // This ensures when the balance is shown, all witnesses are current
                                // Same as FAST START FIX #557 v8, but for INSTANT START path
                                //
                                // FIX #1131: Skip if witnesses were ALREADY rebuilt during health checks (FIX #550/828)
                                // This prevents duplicate 40+ second witness rebuilds
                                if WalletHealthCheck.shared.witnessesRebuiltThisSession {
                                    print("⏩ FIX #1131: Skipping FIX #557 v9 - witnesses already rebuilt by FIX #550/828 this session")
                                } else if WalletHealthCheck.shared.hasValidVerifiedState() {
                                    print("⏩ FIX #1131: Skipping FIX #557 v9 - verified state is valid (FIX #1126)")
                                } else {
                                    // FIX #1220: Wait for gap-fill to finish before witness rebuild.
                                    // Gap-fill runs in detached Task from WalletManager.init() — concurrent with INSTANT START.
                                    // Witness rebuild (FIX #571) makes P2P requests that compete with gap-fill for bandwidth.
                                    // Wait up to 5 minutes for gap-fill to complete, then proceed.
                                    if await walletManager.isGapFillingDelta {
                                        print("⏳ FIX #1220: Waiting for gap-fill to complete before witness rebuild...")
                                        await MainActor.run {
                                            walletManager.setConnecting(true, status: "Repairing tree integrity...")
                                        }
                                        for _ in 1...600 {  // Up to 5 min (600 × 500ms)
                                            if await !walletManager.isGapFillingDelta { break }
                                            try? await Task.sleep(nanoseconds: 500_000_000)
                                        }
                                        print("✅ FIX #1220: Gap-fill finished — proceeding with witness rebuild")
                                    }

                                    print("🔄 FIX #557 v9: Rebuilding stale witnesses before showing UI (INSTANT START)...")
                                    await MainActor.run {
                                        walletManager.setConnecting(true, status: "Updating witnesses for instant send...")
                                    }

                                    // FIX #563 v31: DISABLED tree corruption check before witness rebuild
                                    // The tree rebuild was losing PHASE 2 delta CMUs and causing crashes
                                    // If tree is corrupted, user can run "Settings → Repair Database" manually
                                    print("🔍 FIX #563 v31: Skipping tree corruption check (causes crashes during witness rebuild)")

                                    // FIX #881: Time witness rebuild
                                    let witnessRebuildStart = CFAbsoluteTimeGetCurrent()
                                    await walletManager.rebuildWitnessesForStartup()
                                    logPhase("Witness rebuild", since: witnessRebuildStart)
                                    print("✅ FIX #557 v9: Witnesses synced - balance is now accurate!")
                                }

                                // FIX #1090: CRITICAL - Recompute nullifiers with correct positions + verify
                                // This MUST run after witnesses are rebuilt (they contain the correct positions)
                                // Without this, spent notes won't be detected and balance will be WRONG
                                print("🔧 FIX #1090: Verifying nullifiers at INSTANT START...")
                                // FIX #1283: Reset progress and show verification task so UI doesn't show 100%
                                await MainActor.run {
                                    walletManager.setConnecting(true, status: "Verifying balance accuracy...")
                                    maxDisplayedProgress = 0.0  // Reset monotonic progress tracker
                                    walletManager.setVerificationProgress(0.90)  // Reset to 90% — verification is the last 10%
                                    walletManager.syncTasks.append(SyncTask(id: "balance_verify", title: "Verifying balance on-chain", status: .inProgress, detail: "Scanning blocks...", progress: 0.0))
                                }
                                // FIX #1283: Capture pre-verification balance to detect changes
                                let preVerifyBalance = try? WalletDatabase.shared.getTotalUnspentBalance(accountId: 1)
                                var verificationDetectedSpends = false
                                // FIX #1283: Progress callback for block scan
                                let verifyProgress: (Int, Int) -> Void = { scanned, total in
                                    Task { @MainActor in
                                        let pct = total > 0 ? Double(scanned) / Double(total) : 0.0
                                        walletManager.updateSyncTask(id: "balance_verify", status: .inProgress, detail: "\(scanned)/\(total) blocks", progress: pct)
                                        walletManager.setVerificationProgress(0.90 + (0.09 * pct))  // 90-99%
                                    }
                                }
                                do {
                                    let fixedNullifiers = try await walletManager.recomputeNullifiersWithCorrectPositions()
                                    if fixedNullifiers > 0 {
                                        print("🔧 FIX #1192: Fixed \(fixedNullifiers) nullifier(s) in-place - refreshing balance (no rescan needed)")
                                        try? await walletManager.refreshBalance()
                                        let externalSpends = try await walletManager.verifyAllUnspentNotesOnChain(forceFullVerification: true, onProgress: verifyProgress)
                                        if externalSpends > 0 {
                                            print("✅ FIX #1192: Detected \(externalSpends) external spend(s) after nullifier fix")
                                            try? await walletManager.refreshBalance()
                                            verificationDetectedSpends = true
                                        }
                                        print("✅ FIX #1192: Nullifiers corrected + balance refreshed - no rescan loop!")
                                    } else {
                                        let externalSpends = try await walletManager.verifyAllUnspentNotesOnChain(forceFullVerification: false, onProgress: verifyProgress)
                                        if externalSpends > 0 {
                                            print("✅ FIX #1090: Detected and fixed \(externalSpends) external spend(s)")
                                            try? await walletManager.refreshBalance()
                                            verificationDetectedSpends = true
                                        } else {
                                            print("✅ FIX #1090: All unspent notes verified - balance is accurate!")
                                        }
                                    }
                                    // FIX #1283: Check if balance changed after verification
                                    let postVerifyBalance = try? WalletDatabase.shared.getTotalUnspentBalance(accountId: 1)
                                    if let pre = preVerifyBalance, let post = postVerifyBalance, pre != post {
                                        print("⚠️ FIX #1283: Balance CHANGED after verification: \(pre) → \(post) zatoshis")
                                        print("   Phantom-unspent notes detected and corrected")
                                        verificationDetectedSpends = true
                                    }
                                    await MainActor.run {
                                        walletManager.updateSyncTask(id: "balance_verify", status: .completed)
                                    }
                                } catch {
                                    print("⚠️ FIX #1091 v2: Repair failed: \(error)")
                                    print("   Run 'Full Resync' in Settings if balance seems wrong")
                                    await MainActor.run {
                                        walletManager.updateSyncTask(id: "balance_verify", status: .failed("Error: \(error.localizedDescription)"))
                                    }
                                }

                                // FIX #1118 v2: Detect balance issues BEFORE UI transition
                                // This blocks SEND and shows warning even if discrepancy is marked non-critical
                                // (Non-critical is used to prevent Full Rescan loops, but user should still see warning)

                                // DEBUG: Print all health results to diagnose
                                print("🔍 FIX #1118 DEBUG: Checking \(healthResults.count) health results for Balance Integrity issues:")
                                for result in healthResults {
                                    print("   - \(result.checkName): passed=\(result.passed), critical=\(result.critical)")
                                }

                                // FIX #1283: Include both health check results AND blockchain verification results
                                let hasAnyBalanceIssue = healthResults.contains {
                                    $0.checkName == "Balance Integrity" && !$0.passed
                                } || verificationDetectedSpends
                                print("🔍 FIX #1118 DEBUG: hasAnyBalanceIssue = \(hasAnyBalanceIssue) (health=\(healthResults.contains { $0.checkName == "Balance Integrity" && !$0.passed }), verification=\(verificationDetectedSpends))")

                                if hasAnyBalanceIssue {
                                    print("⚠️ FIX #1118: Balance discrepancy detected - blocking SEND and showing warning")
                                }

                                await MainActor.run {
                                    if hasAnyBalanceIssue {
                                        walletManager.balanceIntegrityIssue = true
                                        if verificationDetectedSpends {
                                            walletManager.balanceIntegrityMessage = "Balance corrected — phantom notes detected and removed"
                                        } else {
                                            walletManager.balanceIntegrityMessage = "Balance discrepancy detected - run Full Resync in Settings"
                                        }
                                        print("🚨 FIX #1118 v2: balanceIntegrityIssue set to TRUE before UI transition")
                                    }

                                    // NOW transition UI - BalanceView will see the correct flag value
                                    walletManager.setRepairingHistory(false)
                                    walletManager.setConnecting(false, status: nil)
                                    isInitialSync = false
                                    hasCompletedInitialSync = true
                                    walletManager.completeProgress()
                                }

                                // FIX #881: Log total INSTANT START time
                                let instantStartTotal = CFAbsoluteTimeGetCurrent() - instantStartBegin
                                print("⚡ FIX #881: INSTANT START total: \(String(format: "%.2f", instantStartTotal))s")
                                print("⚡ FIX #881: Phase breakdown:")
                                for (phase, elapsed) in phaseTimings {
                                    print("   • \(phase): \(String(format: "%.2f", elapsed * 1000))ms")
                                }
                                print("⚡ FIX #168: INSTANT START COMPLETE (with health check + witness rebuild)!")

                                // FIX #560: Mark all fast_* tasks as completed before returning
                                // Without this, progress stays at 0% because tasks are still .pending
                                await MainActor.run {
                                    walletManager.updateSyncTask(id: "fast_balance", status: .completed)
                                    walletManager.updateSyncTask(id: "fast_peers", status: .completed)
                                    walletManager.updateSyncTask(id: "fast_headers", status: .completed)
                                    walletManager.updateSyncTask(id: "fast_health", status: .completed)
                                    print("✅ FIX #560: All FAST START tasks marked as completed - progress should show 100%")

                                    // FIX #560: Enable background processes for INSTANT START
                                    // User is going directly to main view, need background processes active
                                    networkManager.enableBackgroundProcesses()
                                    print("✅ FIX #560: Background processes enabled for INSTANT START")

                                    // FIX #603: Start periodic witness refresh
                                    walletManager.startPeriodicWitnessRefresh()

                                    // FIX #370 + FIX #681: Start periodic deep verification and auto-recovery
                                    walletManager.startPeriodicDeepVerification()

                                    // FIX #1354: Check if newer boost file available on GitHub
                                    walletManager.checkForBoostUpdate()
                                }

                                // FIX #1128: Run delta bundle compaction in background (non-blocking)
                                // This removes duplicate CMUs that accumulate over time from re-scans
                                // Running after startup so user can start using app immediately
                                Task.detached(priority: .background) {
                                    let result = DeltaCMUManager.shared.compactDeltaBundleIfNeeded()
                                    if result.removed > 0 {
                                        print("✅ FIX #1128: Background compaction removed \(result.removed) duplicate CMUs")
                                    }
                                }

                                // FIX #560: DO NOT enable background processes yet!
                                // Background processes will be enabled AFTER FAST START completes
                                // Starting them now causes mempool scan, block notifications to interfere
                                Task {
                                    do {
                                        try await networkManager.connect()
                                        await networkManager.fetchNetworkStats()
                                    } catch {
                                        print("⚠️ FIX #168: Background connect error: \(error.localizedDescription)")
                                    }
                                }
                                return  // EXIT - UI is now showing!
                            } else if isCheckpointValid && !isHeaderStoreHealthy {
                                // FIX #408: Checkpoint is valid but HeaderStore is stale
                                // Fall through to REGULAR FAST START which will sync headers
                                // FIX #769: Use "headers behind" wording to avoid false sync lag alerts
                                print("⚠️ FIX #408: Checkpoint valid but HeaderStore is \(headersBehind) headers behind!")
                                print("⚠️ FIX #408: Falling back to REGULAR FAST START for header sync")
                            }

                            // ================================================================
                            // REGULAR FAST START (checkpoint gap > 10 blocks OR HeaderStore stale)
                            // Need to verify wallet state before showing UI
                            // ================================================================
                            if !isCheckpointValid {
                                print("📍 FIX #168: Checkpoint gap >\(checkpointGap) - running verification...")
                            }

                            // FIX #162: Set flag to prevent Views from calling populateHistoryFromNotes()
                            // during FAST START - it would undo any repairs we make
                            walletManager.setRepairingHistory(true)

                            // Initialize FAST START tasks for UI display
                            // Note: Use unique IDs (fast_*) to avoid conflict with currentSyncTasks computed property
                            // which adds its own "tree" and "connect" tasks
                            // FIX #558 v3: Update existing tasks instead of replacing the array
                            // The tasks are already initialized in WalletManager.syncTasks
                            await MainActor.run {
                                walletManager.updateSyncTask(id: "fast_balance", status: .inProgress)
                            }

                            // Load cached balance immediately (no network wait!)
                            await MainActor.run {
                                walletManager.setConnecting(true, status: "Loading cached balance...")
                            }

                            // Load balance from database (instant)
                            walletManager.loadCachedBalance()

                            // Update task: balance loaded
                            await MainActor.run {
                                walletManager.updateSyncTask(id: "fast_balance", status: .completed)
                                walletManager.updateSyncTask(id: "fast_peers", status: .inProgress)
                            }

                            // =================================================================
                            // FIX #147: Check if transactions need timestamps BEFORE completing
                            // If headers are missing, we MUST sync them before showing balance
                            // Otherwise user sees transaction history with wrong/missing dates
                            // =================================================================
                            let earliestNeedingTimestamp = try? WalletDatabase.shared.getEarliestHeightNeedingTimestamp()
                            var needsHeaderSync = earliestNeedingTimestamp != nil

                            // FIX #412: If HeaderStore is severely behind lastScannedHeight, we need P2P for header sync
                            // Tree Root Validation needs header at lastScannedHeight - can't validate without P2P!
                            // Without this check, health checks run BEFORE peers connect, causing FIX #411 to fail
                            let headerStoreHeight412 = (try? HeaderStore.shared.getLatestHeight()) ?? 0
                            let lastScanned412 = (try? WalletDatabase.shared.getLastScannedHeight()) ?? 0
                            if lastScanned412 > 0 && headerStoreHeight412 < lastScanned412 {
                                let headerGap412 = lastScanned412 - headerStoreHeight412
                                if headerGap412 > 100 {  // More than 100 headers behind
                                    // FIX #769: Use "headers behind" wording to avoid false sync lag alerts
                                    print("⚠️ FIX #412: HeaderStore is \(headerGap412) headers behind lastScannedHeight (\(lastScanned412))")
                                    print("⚠️ FIX #412: Need P2P network FIRST for header sync (Tree Root Validation requires it)")
                                    needsHeaderSync = true
                                }
                            }

                            if needsHeaderSync {
                                print("⚠️ FIX #147: Transactions need timestamps - running header sync BEFORE showing UI")
                                print("⚠️ FIX #147: Earliest height needing timestamp: \(earliestNeedingTimestamp ?? 0)")

                                // Connect to network first (needed for header sync)
                                await MainActor.run {
                                    walletManager.setConnecting(true, status: "Connecting for header sync...")
                                }

                                do {
                                    try await networkManager.connect()

                                    // FIX #412 v2: Wait for at least 3 peers WITH VALID CHAIN HEIGHT!
                                    // syncHeaders() requires getChainHeight() > 0 to work
                                    var peerWait = 0
                                    let maxPeerWait = 300 // 30 seconds max
                                    var chainHeightHeaderPath: UInt64 = 0

                                    while (networkManager.connectedPeers < 3 || chainHeightHeaderPath == 0) && peerWait < maxPeerWait {
                                        try await Task.sleep(nanoseconds: 100_000_000) // 100ms
                                        peerWait += 1

                                        // Check for chain height (needs peers with peerStartHeight > 0)
                                        chainHeightHeaderPath = networkManager.chainHeight

                                        // Update task progress
                                        let peerProgress = min(Double(networkManager.connectedPeers) / 3.0, 1.0)
                                        let heightProgress = chainHeightHeaderPath > 0 ? 1.0 : 0.0
                                        let combinedProgress = (peerProgress + heightProgress) / 2.0
                                        await MainActor.run {
                                            let statusDetail = chainHeightHeaderPath > 0
                                                ? "\(networkManager.connectedPeers)/3 peers, height=\(chainHeightHeaderPath)"
                                                : "\(networkManager.connectedPeers)/3 peers, waiting for height..."
                                            walletManager.updateSyncTask(id: "fast_peers", status: .inProgress, detail: statusDetail, progress: combinedProgress)
                                        }

                                        // Log every 5 seconds
                                        if peerWait % 50 == 0 {
                                            print("⏳ FIX #412 v2: Header path waiting... peers=\(networkManager.connectedPeers), chainHeight=\(chainHeightHeaderPath)")
                                        }
                                    }

                                    print("✅ FIX #412 v2: Header path ready - \(networkManager.connectedPeers) peers, chainHeight=\(chainHeightHeaderPath) (waited \(peerWait * 100)ms)")

                                    // Update task: peers connected
                                    await MainActor.run {
                                        walletManager.updateSyncTask(id: "fast_peers", status: .completed)
                                        walletManager.updateSyncTask(id: "fast_headers", status: .inProgress)
                                    }

                                    // FIX #413: Check GitHub for newer boost file to minimize delta sync
                                    // This is quick - only downloads if remote is newer than cached
                                    await MainActor.run {
                                        walletManager.updateSyncTask(id: "fast_headers", status: .inProgress, detail: "Checking for updates...")
                                    }
                                    let downloadedNewer = await walletManager.checkAndDownloadNewerBoostFile()
                                    if downloadedNewer {
                                        print("✅ FIX #413: Downloaded newer boost file - reduced delta sync needed")
                                    }

                                    // FIX #413: Load bundled headers from boost file FIRST (much faster than P2P)
                                    // This populates HeaderStore with headers from the boost file
                                    // Then we only need P2P delta sync for recent blocks
                                    await MainActor.run {
                                        walletManager.updateSyncTask(id: "fast_headers", status: .inProgress, detail: "Loading bundled headers...")
                                    }
                                    let (loadedFromBoost, boostEndHeight) = await walletManager.loadHeadersFromBoostFile()
                                    if loadedFromBoost {
                                        print("✅ FIX #413: Loaded bundled headers up to \(boostEndHeight), now syncing delta via P2P...")
                                    }

                                    // Run header sync WITH progress visible to user
                                    // FIX #413: Now only syncs DELTA (blocks after boost file) via P2P
                                    // This uses the floatingHeaderSyncIndicator in ContentView
                                    await walletManager.ensureHeaderTimestamps()

                                    // FIX #412 v2: ensureHeaderTimestamps() only syncs for timestamps (100 blocks)
                                    // Tree Root Validation needs header at lastScannedHeight specifically!
                                    // If HeaderStore still doesn't have it, sync directly to lastScannedHeight
                                    let headerStoreAfterTimestamps = (try? HeaderStore.shared.getLatestHeight()) ?? 0
                                    let lastScannedForTreeRoot = (try? WalletDatabase.shared.getLastScannedHeight()) ?? 0
                                    if lastScannedForTreeRoot > headerStoreAfterTimestamps {
                                        let gapToLastScanned = lastScannedForTreeRoot - headerStoreAfterTimestamps
                                        print("🔧 FIX #412 v2: HeaderStore at \(headerStoreAfterTimestamps), need \(lastScannedForTreeRoot) for Tree Root")
                                        print("🔧 FIX #412 v2: Syncing \(gapToLastScanned) additional headers for Tree Root Validation...")
                                        await MainActor.run {
                                            walletManager.updateSyncTask(id: "fast_headers", status: .inProgress, detail: "Syncing for Tree Root...")
                                        }
                                        // FIX #432: Sync headers to at least lastScannedHeight
                                        // Previous bug: try? swallowed errors, sync appeared to "complete" in 59ms
                                        let hsm = HeaderSyncManager(headerStore: HeaderStore.shared, networkManager: NetworkManager.shared)

                                        // FIX #464: Report header sync progress to UI
                                        hsm.onProgress = { progress in
                                            Task { @MainActor in
                                                walletManager.updateSyncTask(id: "fast_headers", status: .inProgress, detail: "Syncing headers \(progress.currentHeight)/\(progress.totalHeight)...")
                                            }
                                        }

                                        do {
                                            try await hsm.syncHeaders(from: headerStoreAfterTimestamps + 1, maxHeaders: gapToLastScanned + 100)
                                            let newHeight = (try? HeaderStore.shared.getLatestHeight()) ?? 0
                                            print("✅ FIX #432: Header sync for Tree Root complete (now at height \(newHeight))")
                                        } catch {
                                            print("⚠️ FIX #432: Header sync for Tree Root FAILED: \(error.localizedDescription)")
                                            // Don't block - Tree Root Validation will handle the failure
                                        }
                                    }

                                    // Update task: headers synced
                                    await MainActor.run {
                                        walletManager.updateSyncTask(id: "fast_headers", status: .completed)
                                    }

                                    print("✅ FIX #147: Header sync complete - NOW showing main UI")
                                } catch {
                                    print("⚠️ FIX #147: Header sync failed: \(error.localizedDescription)")
                                    // Mark as failed but continue
                                    await MainActor.run {
                                        walletManager.updateSyncTask(id: "fast_peers", status: .failed(error.localizedDescription))
                                        walletManager.updateSyncTask(id: "fast_headers", status: .failed(error.localizedDescription))
                                    }
                                }
                            } else {
                                print("✅ FIX #147: No transactions need timestamps - fast path")

                                // FIX #412: ALWAYS wait for P2P network to be healthy before health checks!
                                // Previous bug: Only waited 2 seconds, health checks ran without network
                                // Health checks (Tree Root Validation, etc.) NEED network to:
                                //   1. Get consensus chain height from peers
                                //   2. Sync headers for validation
                                //   3. Perform any repair operations
                                await MainActor.run {
                                    walletManager.updateSyncTask(id: "fast_peers", status: .inProgress, detail: "Connecting to network...")
                                }

                                // FIX #412: Connect to network FIRST (blocking, not background!)
                                do {
                                    try await networkManager.connect()
                                    print("✅ FIX #412: Network connection started")
                                } catch {
                                    print("⚠️ FIX #412: Network connection failed: \(error.localizedDescription)")
                                }

                                // FIX #412 v2: Wait for at least 3 peers WITH VALID CHAIN HEIGHT!
                                // Previous bug: Only counted connected peers, not peers with peerStartHeight > 0
                                // syncHeaders() requires getChainHeight() > 0 which needs peers with valid height
                                var peerWait = 0
                                let maxPeerWait = 300 // 30 seconds max
                                var chainHeight: UInt64 = 0
                                var peersWithHeight = 0

                                while (networkManager.connectedPeers < 3 || chainHeight == 0) && peerWait < maxPeerWait {
                                    try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                                    peerWait += 1

                                    // FIX #412 v2: Check for peers with valid chain height, not just connected
                                    chainHeight = networkManager.chainHeight
                                    peersWithHeight = networkManager.getAllConnectedPeers().filter { $0.peerStartHeight > 0 }.count

                                    // Update task progress based on both conditions
                                    let peerProgress = min(Double(networkManager.connectedPeers) / 3.0, 1.0)
                                    let heightProgress = chainHeight > 0 ? 1.0 : 0.0
                                    let combinedProgress = (peerProgress + heightProgress) / 2.0
                                    await MainActor.run {
                                        let statusDetail = chainHeight > 0
                                            ? "\(networkManager.connectedPeers)/3 peers, height=\(chainHeight)"
                                            : "\(networkManager.connectedPeers)/3 peers, waiting for height..."
                                        walletManager.updateSyncTask(id: "fast_peers", status: .inProgress, detail: statusDetail, progress: combinedProgress)
                                    }

                                    // Log every 5 seconds
                                    if peerWait % 50 == 0 {
                                        print("⏳ FIX #412 v2: Waiting for P2P... peers=\(networkManager.connectedPeers), peersWithHeight=\(peersWithHeight), chainHeight=\(chainHeight)")
                                    }
                                }

                                print("✅ FIX #412 v2: FAST START proceeding - \(networkManager.connectedPeers) peers, \(peersWithHeight) with height, chainHeight=\(chainHeight) (waited \(peerWait * 100)ms)")

                                await MainActor.run {
                                    walletManager.updateSyncTask(id: "fast_peers", status: .completed, detail: "\(networkManager.connectedPeers) peers")
                                }

                                // FIX #413: Check GitHub for newer boost file to minimize delta sync
                                await MainActor.run {
                                    walletManager.updateSyncTask(id: "fast_headers", status: .inProgress, detail: "Checking for updates...")
                                }
                                let fastDownloadedNewer = await walletManager.checkAndDownloadNewerBoostFile()
                                if fastDownloadedNewer {
                                    print("✅ FIX #413: Fast path - downloaded newer boost file")
                                }

                                // FIX #413: Load bundled headers from boost file FIRST (much faster than P2P)
                                // This populates HeaderStore with headers from the boost file
                                await MainActor.run {
                                    walletManager.updateSyncTask(id: "fast_headers", status: .inProgress, detail: "Loading bundled headers...")
                                }
                                let (fastLoadedFromBoost, fastBoostEndHeight) = await walletManager.loadHeadersFromBoostFile()
                                if fastLoadedFromBoost {
                                    print("✅ FIX #413: Fast path - loaded bundled headers up to \(fastBoostEndHeight)")
                                }

                                // FIX #412 v2: Even in fast path, check if HeaderStore needs sync for Tree Root
                                // This is a safety net - normally gap > 100 forces the header sync path above
                                let fastPathHeaderHeight = (try? HeaderStore.shared.getLatestHeight()) ?? 0
                                let fastPathLastScanned = (try? WalletDatabase.shared.getLastScannedHeight()) ?? 0
                                if fastPathLastScanned > fastPathHeaderHeight {
                                    let fastPathGap = fastPathLastScanned - fastPathHeaderHeight
                                    if fastPathGap > 50 {  // Need significant headers for Tree Root
                                        print("🔧 FIX #412 v2: Fast path - HeaderStore at \(fastPathHeaderHeight), need \(fastPathLastScanned)")
                                        print("🔧 FIX #412 v2: Fast path - Syncing \(fastPathGap) headers for Tree Root Validation...")
                                        await MainActor.run {
                                            walletManager.updateSyncTask(id: "fast_headers", status: .inProgress, detail: "Syncing headers...")
                                        }
                                        let hsm = HeaderSyncManager(headerStore: HeaderStore.shared, networkManager: NetworkManager.shared)

                                        // FIX #464: Report header sync progress to UI
                                        hsm.onProgress = { progress in
                                            Task { @MainActor in
                                                walletManager.updateSyncTask(id: "fast_headers", status: .inProgress, detail: "Syncing headers \(progress.currentHeight)/\(progress.totalHeight)...")
                                            }
                                        }

                                        try? await hsm.syncHeaders(from: fastPathHeaderHeight + 1, maxHeaders: fastPathGap + 100)
                                        print("✅ FIX #412 v2: Fast path header sync complete")
                                    }
                                }

                                await MainActor.run {
                                    walletManager.updateSyncTask(id: "fast_headers", status: .completed)
                                }
                            }

                            // FIX #409: Run health checks BEFORE showing UI (not in background)
                            // User expects wallet state to be fully validated at startup
                            await MainActor.run {
                                walletManager.updateSyncTask(id: "fast_health", status: .inProgress, detail: "Validating...")
                            }

                            print("🏥 FIX #409: Running health checks before FAST START completes...")

                            // FIX #409: Health checks now run BEFORE showing UI (mandatory)
                            var healthResults = await WalletHealthCheck.shared.runAllChecks()

                            // Update task: health checks complete
                            await MainActor.run {
                                let allPassed = !WalletHealthCheck.shared.hasCriticalFailures(healthResults)
                                walletManager.updateSyncTask(id: "fast_health", status: allPassed ? .completed : .failed("Critical issues found"))
                            }

                            // FIX #147: ALWAYS print summary so user sees all check results
                            WalletHealthCheck.shared.printSummary(healthResults)

                            let hasCritical = WalletHealthCheck.shared.hasCriticalFailures(healthResults)
                            let fixableIssues = WalletHealthCheck.shared.getFixableIssues(healthResults)

                            // FIX #164 v4: Check if repair is needed (checkpoint gap detected)
                            let repairNeededCheck = healthResults.first {
                                $0.checkName == "Checkpoint Sync" && !$0.passed && $0.details.contains("REPAIR NEEDED")
                            }
                            // FIX #686: Log repair needed but don't show alert - automatic repair below will handle it
                            if let repair = repairNeededCheck {
                                print("⚠️ FIX #686: Repair needed detected - will trigger automatic repair below")
                                print("⚠️ Issue: \(repair.checkName) - \(repair.details)")
                            }

                            // FIX #120 DEBUG: Log what we found
                            print("🔍 FIX #120 DEBUG: hasCritical=\(hasCritical), fixableIssues.count=\(fixableIssues.count)")
                            for issue in fixableIssues {
                                print("🔍 FIX #120 DEBUG: Fixable issue: \(issue.checkName)")
                            }

                            // FIX #439: Check for Tree Root mismatch (critical but REPAIRABLE via Full Rescan)
                            let hasTreeRootMismatch = healthResults.contains {
                                $0.checkName == "Tree Root Validation" && !$0.passed && $0.critical
                            }

                            // FIX #1078: Check for Balance Integrity failure (critical but REPAIRABLE via Full Rescan)
                            let hasBalanceCorruption = healthResults.contains {
                                $0.checkName == "Balance Integrity" && !$0.passed && $0.critical
                            }

                            // FIX #1302: Auto Full Rescan DISABLED — Phase 2 P2P creates phantom notes.
                            // Log the issue, user can manually Full Rescan from Settings.
                            if false && hasCritical && (hasTreeRootMismatch || hasBalanceCorruption) {
                                // FIX #1078: Balance corruption or Tree Root mismatch - auto-trigger Full Rescan (DISABLED by FIX #1302)
                                if hasBalanceCorruption {
                                    print("🔧 FIX #1078: Balance corruption detected - AUTO-triggering Full Rescan to rebuild notes...")
                                }
                                if hasTreeRootMismatch {
                                    print("🔧 FIX #439: Tree Root mismatch detected - triggering Full Rescan to rebuild tree...")
                                }
                                let statusMsg = hasBalanceCorruption ? "Balance issue - rebuilding..." : "Tree mismatch - rebuilding..."
                                await MainActor.run {
                                    walletManager.setConnecting(true, status: statusMsg)
                                    walletManager.syncTasks.append(SyncTask(id: "tree_rebuild", title: "Rebuilding wallet data", status: .inProgress, progress: 0.0))
                                }

                                // Trigger Full Rescan to rebuild the commitment tree
                                do {
                                    try await walletManager.repairNotesAfterDownloadedTree(onProgress: { progress, current, total in
                                        print("🔧 FIX #439: Tree rebuild progress \(Int(progress * 100))% (\(current)/\(total))")
                                        Task { @MainActor in
                                            walletManager.updateSyncTask(id: "tree_rebuild", status: .inProgress, detail: "\(current)/\(total) blocks", progress: progress)
                                        }
                                    }, forceFullRescan: true)
                                    await MainActor.run {
                                        walletManager.updateSyncTask(id: "tree_rebuild", status: .completed)
                                    }
                                    print("✅ FIX #439: Tree rebuild complete - continuing startup")
                                    // Continue to main UI after successful repair
                                } catch {
                                    print("❌ FIX #439: Tree rebuild failed: \(error.localizedDescription)")
                                    await MainActor.run {
                                        walletManager.updateSyncTask(id: "tree_rebuild", status: .failed("Rebuild failed"))
                                        walletManager.setConnecting(true, status: "Tree rebuild failed - please try Full Rescan in Settings")
                                    }
                                    return
                                }
                            } else if hasCritical {
                                print("❌ FAST START: Critical health check failures detected - wallet may not function correctly")
                                // FIX #120: Stay on sync screen for critical failures
                                // User cannot send ZCL in this state - show error
                                await MainActor.run {
                                    walletManager.setConnecting(true, status: "Critical issue detected - please restart app")
                                }
                                // Don't transition to main UI - keep showing sync screen
                                return
                            } else if !fixableIssues.isEmpty {
                                // FIX #120: Non-critical issues found - attempt to fix BEFORE showing main UI
                                print("⚠️ FAST START: \(fixableIssues.count) fixable issues found - attempting repair...")

                                for issue in fixableIssues {
                                    print("⚠️ Issue: \(issue.checkName) - \(issue.details)")
                                }

                                // Attempt automatic repair based on issue type
                                await MainActor.run {
                                    walletManager.setConnecting(true, status: "Repairing wallet state...")
                                }

                                // Check for specific issues and fix them
                                let hasWitnessIssues = fixableIssues.contains { $0.checkName == "Witness Validity" }
                                let hasDeltaCMUIssues = fixableIssues.contains { $0.checkName == "Delta CMU" }
                                let hasTimestampIssues = fixableIssues.contains { $0.checkName == "Timestamps" }
                                let hasHashIssues = fixableIssues.contains { $0.checkName == "Hash Accuracy" }
                                let hasBalanceIssues = fixableIssues.contains { $0.checkName == "Balance Integrity" }
                                // FIX #177: Handle Checkpoint Sync issues - repair updates checkpoint via FIX #176
                                let hasCheckpointIssues = fixableIssues.contains { $0.checkName == "Checkpoint Sync" }
                                // FIX #411: Handle Tree Root Validation issues - headers not synced to lastScannedHeight
                                let hasTreeRootIssues = fixableIssues.contains { $0.checkName == "Tree Root Validation" }

                                // FIX #120: Handle Hash Accuracy issues - clear and resync headers
                                if hasHashIssues {
                                    print("🔧 FIX #120: Hash mismatch detected - clearing headers for resync...")
                                    await MainActor.run {
                                        walletManager.setConnecting(true, status: "Clearing corrupt headers...")
                                    }
                                    try? HeaderStore.shared.clearAllHeaders()
                                    // Headers will be resynced by ensureHeaderTimestamps below
                                }

                                // FIX #177: Include Checkpoint Sync issues to trigger repair (which updates checkpoint via FIX #176)
                                if hasWitnessIssues || hasDeltaCMUIssues || hasCheckpointIssues {
                                    print("🔧 FIX #120/177: Repairing witnesses and tree state...")
                                    // FIX #156: Add repair task to task list for UI visibility
                                    await MainActor.run {
                                        walletManager.setConnecting(true, status: "Rebuilding witnesses...")
                                        walletManager.syncTasks.append(SyncTask(id: "fast_repair", title: "Verifying transactions", status: .inProgress, progress: 0.0))
                                    }
                                    try? await walletManager.repairNotesAfterDownloadedTree { progress, current, total in
                                        print("🔧 FIX #120: Repair progress \(Int(progress * 100))% (\(current)/\(total))")
                                        // FIX #156: Update task progress in UI
                                        Task { @MainActor in
                                            walletManager.updateSyncTask(id: "fast_repair", status: .inProgress, detail: "\(current)/\(total) witnesses", progress: progress)
                                        }
                                    }
                                    // FIX #156: Mark repair task as complete
                                    await MainActor.run {
                                        walletManager.updateSyncTask(id: "fast_repair", status: .completed)
                                    }
                                }

                                // FIX #120/411: Handle Timestamp, Hash, or Tree Root issues (all need header sync)
                                if hasTimestampIssues || hasHashIssues || hasTreeRootIssues {
                                    if hasTreeRootIssues {
                                        // FIX #418: Load bundled headers from boost file FIRST (instant vs P2P timeout!)
                                        // The boost file has 2.4M+ headers - loading them is instant
                                        // Then we only need P2P delta sync for the last few hundred blocks
                                        print("🔧 FIX #418: Tree Root Validation failed - loading boost file headers first...")
                                        await MainActor.run {
                                            walletManager.setConnecting(true, status: "Loading bundled headers...")
                                        }
                                        let (loadedBoostHeaders, boostEndHeight) = await walletManager.loadHeadersFromBoostFile()
                                        if loadedBoostHeaders {
                                            print("✅ FIX #418: Loaded bundled headers up to \(boostEndHeight)")
                                        }

                                        // FIX #411: Tree Root Validation needs headers at lastScannedHeight
                                        // Now we only need P2P delta sync (boost end → lastScanned)
                                        print("🔧 FIX #411: Tree Root Validation - syncing delta headers via P2P...")
                                        await MainActor.run {
                                            walletManager.setConnecting(true, status: "Syncing delta headers...")
                                        }
                                        let headerStoreHeight = (try? HeaderStore.shared.getLatestHeight()) ?? 0
                                        let lastScanned = (try? WalletDatabase.shared.getLastScannedHeight()) ?? 0
                                        if lastScanned > headerStoreHeight {
                                            let gap = lastScanned - headerStoreHeight
                                            print("🔧 FIX #411: HeaderStore at \(headerStoreHeight), need \(lastScanned), gap=\(gap)")
                                            // Sync headers from headerStoreHeight to at least lastScanned
                                            // maxHeaders = gap + some buffer to ensure we reach lastScanned
                                            let hsm = HeaderSyncManager(headerStore: HeaderStore.shared, networkManager: NetworkManager.shared)

                                            // FIX #464: Report header sync progress to UI
                                            hsm.onProgress = { progress in
                                                Task { @MainActor in
                                                    walletManager.setConnecting(true, status: "Syncing delta headers \(progress.currentHeight)/\(progress.totalHeight)...")
                                                }
                                            }

                                            try? await hsm.syncHeaders(from: headerStoreHeight + 1, maxHeaders: gap + 100)
                                        }
                                    } else {
                                        print("🔧 FIX #120: Syncing headers and timestamps...")
                                    }
                                    await MainActor.run {
                                        walletManager.setConnecting(true, status: "Syncing headers...")
                                    }
                                    await walletManager.ensureHeaderTimestamps()
                                }

                                // FIX #162: Handle Balance Integrity issues - rebuild history from unspent notes ONLY
                                // The old populateHistoryFromNotes() created fake transactions with synthetic txids
                                // causing more corruption. New approach: clear history and add ONLY unspent notes as received.
                                if hasBalanceIssues {
                                    print("🔧 FIX #162: Balance mismatch detected - rebuilding transaction history...")
                                    await MainActor.run {
                                        walletManager.setConnecting(true, status: "Repairing balance history...")
                                        walletManager.syncTasks.append(SyncTask(id: "balance_repair_early", title: "Restoring history", status: .inProgress, progress: 0.0))
                                    }

                                    // Step 1: Clear corrupted history
                                    await MainActor.run {
                                        walletManager.updateSyncTask(id: "balance_repair_early", status: .inProgress, detail: "Clearing old history...", progress: 0.2)
                                    }
                                    try? WalletDatabase.shared.clearTransactionHistory()

                                    // Step 2: Rebuild from unspent notes
                                    await MainActor.run {
                                        walletManager.updateSyncTask(id: "balance_repair_early", status: .inProgress, detail: "Adding unspent notes...", progress: 0.5)
                                    }
                                    try? WalletDatabase.shared.rebuildHistoryFromUnspentNotes()

                                    print("🔧 FIX #162: History rebuilt from unspent notes only (no synthetic txids)")

                                    // Step 3: Sync headers to get timestamps for the new entries
                                    await MainActor.run {
                                        walletManager.updateSyncTask(id: "balance_repair_early", status: .inProgress, detail: "Syncing timestamps...", progress: 0.7)
                                    }
                                    await walletManager.ensureHeaderTimestamps()

                                    // Step 4: Mark complete
                                    await MainActor.run {
                                        walletManager.updateSyncTask(id: "balance_repair_early", status: .completed, detail: "History rebuilt!", progress: 1.0)
                                    }
                                }

                                // Re-run health checks to verify fixes
                                await MainActor.run {
                                    walletManager.setConnecting(true, status: "Verifying repairs...")
                                }
                                let verifyResults = await WalletHealthCheck.shared.runAllChecks()
                                WalletHealthCheck.shared.printSummary(verifyResults)
                                healthResults = verifyResults  // FIX #1293: Update with post-repair results

                                let stillHasIssues = WalletHealthCheck.shared.getFixableIssues(verifyResults)
                                // FIX #412: ALL health checks are now blocking - no exceptions!
                                // User requires: "ALL HEALTH CHECKS CRITICAL BUSINESS TASK MUST BE 100%"
                                // Previous non-blocking checks (P2P Connectivity, Hash Accuracy) now work
                                // because FIX #412 ensures 3+ peers are connected before health checks run.
                                //
                                // ALL critical checks: P2P, Hash Accuracy, Timestamps, Database Integrity,
                                //                     Bundle Files, Delta CMU, Balance Integrity,
                                //                     Tree Root Validation, Equihash, CMU, Notes
                                let blockingIssues = stillHasIssues  // ALL issues are blocking!

                                if !blockingIssues.isEmpty {
                                    // FIX #162: Check if Balance Integrity is the remaining issue
                                    // This can happen when balance check only fails AFTER timestamp sync corrects data
                                    let hasBalanceIssueAfterVerify = blockingIssues.contains { $0.checkName == "Balance Integrity" }

                                    if hasBalanceIssueAfterVerify {
                                        print("🔧 FIX #162: Balance mismatch detected AFTER verification - repairing now...")
                                        await MainActor.run {
                                            walletManager.setConnecting(true, status: "Repairing balance history...")
                                            walletManager.syncTasks.append(SyncTask(id: "balance_repair", title: "Restoring history", status: .inProgress, progress: 0.0))
                                        }

                                        // Step 1: Clear corrupted history
                                        await MainActor.run {
                                            walletManager.updateSyncTask(id: "balance_repair", status: .inProgress, detail: "Clearing old history...", progress: 0.2)
                                        }
                                        try? WalletDatabase.shared.clearTransactionHistory()

                                        // Step 2: Rebuild from unspent notes
                                        await MainActor.run {
                                            walletManager.updateSyncTask(id: "balance_repair", status: .inProgress, detail: "Adding unspent notes...", progress: 0.5)
                                        }
                                        try? WalletDatabase.shared.rebuildHistoryFromUnspentNotes()

                                        // Step 3: Sync timestamps for new entries
                                        await MainActor.run {
                                            walletManager.updateSyncTask(id: "balance_repair", status: .inProgress, detail: "Syncing timestamps...", progress: 0.7)
                                        }
                                        await walletManager.ensureHeaderTimestamps()

                                        // Step 4: Mark complete
                                        await MainActor.run {
                                            walletManager.updateSyncTask(id: "balance_repair", status: .completed, detail: "History rebuilt!", progress: 1.0)
                                        }

                                        print("✅ FIX #162: Balance repair completed - verifying...")

                                        // Re-verify after this repair
                                        let finalResults = await WalletHealthCheck.shared.runAllChecks()
                                        WalletHealthCheck.shared.printSummary(finalResults)
                                        healthResults = finalResults  // FIX #1293: Update with latest results

                                        let finalIssues = WalletHealthCheck.shared.getFixableIssues(finalResults)
                                        // FIX #412: ALL issues are blocking - no filter needed
                                        let finalBlocking = finalIssues

                                        if !finalBlocking.isEmpty {
                                            print("❌ FAST START: Issues still remain after balance repair!")
                                            for issue in finalBlocking {
                                                print("❌ Final issue: \(issue.checkName) - \(issue.details)")
                                            }
                                            await MainActor.run {
                                                walletManager.setConnecting(true, status: "Repair failed - please restart app")
                                            }
                                            return
                                        }
                                        print("✅ FIX #162: Balance repair successful!")
                                    } else {
                                        // FIX #120: Stay on sync screen if issues remain - don't proceed to main UI!
                                        // User cannot send ZCL safely if wallet state is broken
                                        print("❌ FAST START: \(blockingIssues.count) blocking issues remain after repair!")
                                        for issue in blockingIssues {
                                            print("❌ Remaining issue: \(issue.checkName) - \(issue.details)")
                                        }
                                        await MainActor.run {
                                            walletManager.setConnecting(true, status: "Repair incomplete - please restart app")
                                        }
                                        // Keep showing sync screen - don't proceed to main UI
                                        return
                                    }
                                } else {
                                    // FIX #412: ALL issues are blocking - if we get here, all issues are fixed!
                                    print("✅ FAST START: All critical issues fixed! (100% complete)")
                                }
                            } else {
                                print("✅ FAST START: All health checks passed! (100% complete)")
                            }

                            // FIX #557 v8: Rebuild all stale witnesses BEFORE showing UI!
                            // This ensures when the balance is shown, all witnesses are current
                            // and transactions can be built instantly without rejection.
                            // FIX #770: witness_sync task now included in FAST START progress calculation
                            print("🔄 FIX #557 v8: Rebuilding stale witnesses before showing UI...")
                            print("🔄 FIX #770: Adding witness_sync task to FAST START progress")
                            await MainActor.run {
                                walletManager.setConnecting(true, status: "Updating witnesses for instant send...")
                                walletManager.syncTasks.append(SyncTask(id: "witness_sync", title: "Syncing proofs", status: .inProgress, progress: 0.0))
                            }

                            // FIX #557 v8: Rebuild witnesses using WalletManager's account access
                            // Direct call to avoid SwiftUI .id modifier conflict
                            await walletManager.rebuildWitnessesForStartup()

                            await MainActor.run {
                                walletManager.updateSyncTask(id: "witness_sync", status: .completed)
                            }
                            print("✅ FIX #557 v8: Witnesses synced - balance is now accurate!")

                            // FIX #1090: CRITICAL - Recompute nullifiers with correct positions + verify
                            // This MUST run after witnesses are rebuilt (they contain the correct positions)
                            // Without this, spent notes won't be detected and balance will be WRONG
                            print("🔧 FIX #1090: Verifying nullifiers at FAST START...")
                            // FIX #1283: Reset progress and show verification task
                            await MainActor.run {
                                walletManager.setConnecting(true, status: "Verifying balance accuracy...")
                                maxDisplayedProgress = 0.0
                                walletManager.setVerificationProgress(0.90)
                                walletManager.syncTasks.append(SyncTask(id: "balance_verify", title: "Verifying balance on-chain", status: .inProgress, detail: "Scanning blocks...", progress: 0.0))
                            }
                            let preVerifyBalanceFast = try? WalletDatabase.shared.getTotalUnspentBalance(accountId: 1)
                            var verificationDetectedSpendsFast = false
                            let verifyProgressFast: (Int, Int) -> Void = { scanned, total in
                                Task { @MainActor in
                                    let pct = total > 0 ? Double(scanned) / Double(total) : 0.0
                                    walletManager.updateSyncTask(id: "balance_verify", status: .inProgress, detail: "\(scanned)/\(total) blocks", progress: pct)
                                    walletManager.setVerificationProgress(0.90 + (0.09 * pct))
                                }
                            }
                            do {
                                let fixedNullifiers = try await walletManager.recomputeNullifiersWithCorrectPositions()
                                if fixedNullifiers > 0 {
                                    print("🔧 FIX #1192: Fixed \(fixedNullifiers) nullifier(s) in-place - refreshing balance (no rescan needed)")
                                    try? await walletManager.refreshBalance()
                                    let externalSpends = try await walletManager.verifyAllUnspentNotesOnChain(forceFullVerification: true, onProgress: verifyProgressFast)
                                    if externalSpends > 0 {
                                        print("✅ FIX #1192: Detected \(externalSpends) external spend(s) after nullifier fix")
                                        try? await walletManager.refreshBalance()
                                        verificationDetectedSpendsFast = true
                                    }
                                    print("✅ FIX #1192: Nullifiers corrected + balance refreshed - no rescan loop!")
                                } else {
                                    let externalSpends = try await walletManager.verifyAllUnspentNotesOnChain(forceFullVerification: false, onProgress: verifyProgressFast)
                                    if externalSpends > 0 {
                                        print("✅ FIX #1090: Detected and fixed \(externalSpends) external spend(s)")
                                        try? await walletManager.refreshBalance()
                                        verificationDetectedSpendsFast = true
                                    } else {
                                        print("✅ FIX #1090: All unspent notes verified - balance is accurate!")
                                    }
                                }
                                let postVerifyBalanceFast = try? WalletDatabase.shared.getTotalUnspentBalance(accountId: 1)
                                if let pre = preVerifyBalanceFast, let post = postVerifyBalanceFast, pre != post {
                                    print("⚠️ FIX #1283: Balance CHANGED after verification: \(pre) → \(post) zatoshis")
                                    verificationDetectedSpendsFast = true
                                }
                                await MainActor.run {
                                    walletManager.updateSyncTask(id: "balance_verify", status: .completed)
                                }
                            } catch {
                                print("⚠️ FIX #1091 v2: Repair failed: \(error)")
                                print("   Run 'Full Resync' in Settings if balance seems wrong")
                                await MainActor.run {
                                    walletManager.updateSyncTask(id: "balance_verify", status: .failed("Error: \(error.localizedDescription)"))
                                }
                            }

                            // FIX #1283: Include both health check AND blockchain verification results
                            let hasAnyBalanceIssue = healthResults.contains {
                                $0.checkName == "Balance Integrity" && !$0.passed
                            } || verificationDetectedSpendsFast
                            if hasAnyBalanceIssue {
                                print("⚠️ FIX #1118: Balance discrepancy detected (FAST START) - blocking SEND and showing warning")
                            }

                            // Mark initial sync as complete - NOW safe because all checks passed or were fixed
                            print("⚡ FAST START COMPLETE: UI ready!")

                            // FIX #560: Enable background processes AFTER FAST START completes
                            // This prevents mempool scan, block notifications from interfering with startup
                            networkManager.enableBackgroundProcesses()
                            print("✅ FIX #560: Background processes enabled - mempool scan, block notifications now active")

                            // FIX #603: Start periodic witness refresh to keep witnesses fresh for instant spending
                            walletManager.startPeriodicWitnessRefresh()

                            // FIX #370 + FIX #681: Start periodic deep verification and auto-recovery
                            // Runs every 30 minutes to catch missed transactions (including those from broadcast bugs)
                            walletManager.startPeriodicDeepVerification()

                            // FIX #1354: Check if newer boost file available on GitHub
                            walletManager.checkForBoostUpdate()

                            // FIX #1128: Run delta bundle compaction in background (non-blocking)
                            // This removes duplicate CMUs that accumulate over time from re-scans
                            Task.detached(priority: .background) {
                                let result = DeltaCMUManager.shared.compactDeltaBundleIfNeeded()
                                if result.removed > 0 {
                                    print("✅ FIX #1128: Background compaction removed \(result.removed) duplicate CMUs")
                                }
                            }

                            // FIX #500: Clear import progress flag if this was an import
                            if walletManager.isImportInProgress {
                                walletManager.markImportComplete()
                            }

                            // DEBUG: Pause for confirmation if enabled
                            if DEBUG_PAUSE_AT_COMPLETION {
                                await MainActor.run {
                                    // FIX #155: Show which health checks failed
                                    let passedCount = healthResults.filter { $0.passed }.count
                                    let failedChecks = healthResults.filter { !$0.passed }
                                    var healthMessage = "Health: \(passedCount)/\(healthResults.count) passed"
                                    if !failedChecks.isEmpty {
                                        healthMessage += "\n\n⚠️ Failed checks:"
                                        for check in failedChecks {
                                            healthMessage += "\n• \(check.checkName)"
                                        }
                                    }
                                    debugCompletionMessage = "FAST START complete!\n\n\(healthMessage)\nBlocks behind: \(blocksBehind)\nHeader sync: \(needsHeaderSync ? "YES" : "NO")"
                                    debugWaitingForConfirmation = true
                                }
                                print("🔴 DEBUG: Waiting for user confirmation before showing balance...")

                                // Wait for user to tap the confirmation button
                                while debugWaitingForConfirmation {
                                    try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                                }
                                print("🟢 DEBUG: User confirmed, proceeding to balance view")
                            }

                            // FIX #1118 v2: CRITICAL - Set flag AND transition UI in SINGLE MainActor.run block
                            // Two separate MainActor.run blocks caused race condition where SwiftUI rendered
                            // BalanceView before observing the flag change. Now both happen atomically.
                            await MainActor.run {
                                if hasAnyBalanceIssue {
                                    walletManager.balanceIntegrityIssue = true
                                    if verificationDetectedSpendsFast {
                                        walletManager.balanceIntegrityMessage = "Balance corrected — phantom notes detected and removed"
                                    } else {
                                        walletManager.balanceIntegrityMessage = "Balance discrepancy detected - run Full Resync in Settings"
                                    }
                                    print("🚨 FIX #1118 v2: balanceIntegrityIssue set to TRUE before UI transition (FAST START)")
                                }

                                walletManager.setRepairingHistory(false)

                                // NOW transition UI - BalanceView will see the correct flag value
                                walletManager.setConnecting(false, status: nil)
                                isInitialSync = false
                                hasCompletedInitialSync = true
                                walletManager.completeProgress()
                            }

                            // Start background sync for any missed blocks (non-blocking)
                            networkManager.suppressBackgroundSync = false
                            Task {
                                do {
                                    // FIX #147: Skip ensureHeaderTimestamps() here - already done above if needed
                                    if !needsHeaderSync {
                                        try await networkManager.connect()
                                    }

                                    // FIX #145: NOW enable background processes (mempool scan, stats refresh)
                                    // Only after header sync is complete
                                    networkManager.enableBackgroundProcesses()

                                    // Now fetch stats which triggers background sync
                                    await networkManager.fetchNetworkStats()
                                } catch {
                                    print("⚠️ Background connect error: \(error.localizedDescription)")
                                    // Enable background processes even on error so app remains functional
                                    networkManager.enableBackgroundProcesses()
                                }
                            }
                            return
                        }

                        // ==========================================================
                        // FULL START MODE: First launch or wallet needs full sync
                        // ==========================================================
                        print("🚀 FULL START MODE: First launch or needs sync")

                        // FIX #819: Validate CMU cache byte order BEFORE any tree operations
                        // Stale cache from before FIX #743 has reversed CMUs causing tree root mismatch
                        let fullStartCacheValid = await CommitmentTreeUpdater.shared.validateAndClearStaleCMUCache()
                        if !fullStartCacheValid {
                            print("🗑️ FIX #819: Stale CMU cache cleared in FULL START - will regenerate from boost file")
                        }

                        // Show connecting status after tree is loaded
                        print("DEBUGZIPHERX: 📡 Task: Tree loaded, checking network...")
                        await MainActor.run {
                            walletManager.setConnecting(true, status: "Connecting to network...")
                        }

                        // Start network connection in background (non-blocking)
                        print("DEBUGZIPHERX: 📡 Task: Starting network connection...")
                        Task {
                            do {
                                try await networkManager.connect()
                            } catch {
                                print("DEBUGZIPHERX: ⚠️ Background connect error: \(error.localizedDescription)")
                            }
                        }

                        // Wait for at least 2 peers (max 10s)
                        print("DEBUGZIPHERX: 📡 Task: Waiting for peers (max 10s)...")
                        var waitCount = 0
                        let maxWait = 100 // 10 seconds max
                        while networkManager.connectedPeers < 2 && waitCount < maxWait {
                            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                            waitCount += 1
                            if waitCount % 20 == 0 {
                                print("DEBUGZIPHERX: 📡 Task: \(networkManager.connectedPeers) peers connected, waiting... (\(waitCount/10)s)")
                            }
                        }
                        print("DEBUGZIPHERX: 📡 Task: Got \(networkManager.connectedPeers) peers after \(waitCount/10)s")

                        // FIX #185: Equihash verification happens in health check (verifyLatestEquihash)
                        // Boost file verification removed - was too slow (10 separate P2P requests)
                        // Health check verifies latest 100 headers which proves chain validity

                        // Brief pause for UI feedback
                        // FIX #1341: Skip on first import — every second counts
                        if !isFirstLaunch {
                            print("DEBUGZIPHERX: 📡 Task: Waiting 0.5s...")
                            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 sec
                        }

                        // Now fetch stats
                        // FIX #1341: Skip on first import — chainHeight already set by connect() peer consensus (FIX #431).
                        // fetchNetworkStats updates UI info but blocks 2-3s. On first import, scan starts immediately.
                        if !isFirstLaunch {
                            print("DEBUGZIPHERX: 📡 Task: Fetching network stats...")
                            await networkManager.fetchNetworkStats()
                            print("DEBUGZIPHERX: 📡 Task: Network stats fetched")
                        } else {
                            print("⏭️ FIX #1341: Skipping fetchNetworkStats on first import (chainHeight from peer consensus)")
                        }

                        // Auto-sync on launch (downloads params if needed, syncs blockchain)
                        if networkManager.isConnected {
                            // Keep isConnecting true - sync status will update it
                            do {
                                try await walletManager.refreshBalance()
                            } catch {
                                print("⚠️ Auto-sync failed: \(error.localizedDescription)")
                            }
                        }

                        // WAIT for sync to actually START (syncTasks becomes non-empty)
                        // This prevents premature completion when sync hasn't begun yet
                        var syncStartWait = 0
                        while walletManager.syncTasks.isEmpty && syncStartWait < 100 {
                            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                            syncStartWait += 1
                        }

                        // WAIT for sync to actually complete (isSyncing = false AND balance task completed)
                        // This handles cases where refreshBalance() returns but sync continues
                        var syncCompleteWait = 0
                        let maxSyncCompleteWait = 6000 // 10 minutes max for full sync
                        while syncCompleteWait < maxSyncCompleteWait {
                            // Check if balance task is completed (true completion indicator)
                            let balanceTaskCompleted = walletManager.syncTasks.contains {
                                $0.id == "balance" && $0.status == .completed
                            }

                            // Check if ALL tasks are completed
                            let allTasksCompleted = !walletManager.syncTasks.isEmpty && walletManager.syncTasks.allSatisfy {
                                if case .completed = $0.status { return true }
                                if case .failed = $0.status { return true }
                                return false
                            }

                            // If balance is done OR all tasks done, we're done
                            if balanceTaskCompleted {
                                print("✅ Sync complete: balance task finished")
                                break
                            }

                            if allTasksCompleted {
                                print("✅ Sync complete: all tasks finished")
                                break
                            }

                            // Also break if sync stopped for a while (fallback)
                            if !walletManager.isSyncing && syncCompleteWait > 100 {
                                print("✅ Sync complete: sync stopped (fallback)")
                                break
                            }

                            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                            syncCompleteWait += 1
                        }

                        // FIX #1341: Load boost headers in background now that import scan is complete.
                        // These were deferred during first import to save 207s on the critical path.
                        // Needed for: transaction timestamps, anchor validation, health checks.
                        // Runs as fire-and-forget — doesn't block height verification or UI.
                        if isFirstLaunch {
                            Task {
                                print("📜 FIX #1341: Loading 2.5M boost headers in background (deferred from import)...")
                                let (loaded, endHeight) = await walletManager.loadHeadersFromBoostFile()
                                if loaded {
                                    print("✅ FIX #1341: Boost headers loaded in background (to height \(endHeight))")
                                    // Update timestamps for transaction history
                                    await walletManager.ensureHeaderTimestamps()
                                    // Notify UI to refresh history with real timestamps
                                    NotificationCenter.default.post(name: Notification.Name("transactionHistoryUpdated"), object: nil)
                                }
                            }
                        }

                        // ALSO wait for wallet height to match chain height
                        // This ensures we're truly synced, not just "not syncing"
                        print("🔍 FIX #120: Entering height verification phase...")
                        await MainActor.run {
                            walletManager.setConnecting(true, status: "Verifying blockchain height...")
                        }
                        print("🔍 FIX #120: Set connecting status...")
                        var syncWaitCount = 0
                        let maxSyncWait = 300 // 30 seconds max wait for height sync

                        // FIX #198: Use CACHED chain height instead of waiting for Tor to reconnect
                        // The cached height was set during import (networkManager.chainHeight is already set)
                        // No need to call fetchNetworkStats() which waits for Tor + P2P (36 seconds!)
                        let cachedHeight = UInt64(UserDefaults.standard.integer(forKey: "cachedChainHeight"))
                        let targetHeight = cachedHeight > 0 ? cachedHeight : networkManager.chainHeight
                        print("🔍 FIX #198: Using cached height: \(targetHeight), wallet height: \(networkManager.walletHeight) (skipped 36s Tor wait!)")

                        // FIX #205: Skip the 30-second wait loop when background sync is suppressed
                        // The wallet CAN'T sync during this phase because suppressBackgroundSync = true
                        // Catch-up sync at line 872+ will handle the missed blocks directly
                        if !networkManager.suppressBackgroundSync {
                            while networkManager.chainHeight > 0 &&
                                  networkManager.walletHeight < networkManager.chainHeight &&
                                  syncWaitCount < maxSyncWait {
                                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                                syncWaitCount += 1

                                // Update status more frequently (every 500ms) with detailed progress
                                if syncWaitCount % 5 == 0 {
                                    let walletH = networkManager.walletHeight
                                    let chainH = networkManager.chainHeight
                                    let blocksRemaining = chainH > walletH ? chainH - walletH : 0
                                    let elapsed = Double(syncWaitCount) / 10.0 // seconds elapsed

                                    await MainActor.run {
                                        if blocksRemaining > 0 {
                                            walletManager.setConnecting(true, status: "Syncing \(blocksRemaining) remaining blocks... (\(String(format: "%.1f", elapsed))s)")
                                        } else {
                                            walletManager.setConnecting(true, status: "Finalizing sync... (\(String(format: "%.1f", elapsed))s)")
                                        }
                                    }
                                }

                                // FIX #198: Don't re-fetch stats during loop - uses Tor which is slow
                                // The wallet height updates automatically during backgroundSyncToHeight
                            }
                        } else {
                            print("🔍 FIX #205: Skipped 30s wait loop (background sync suppressed)")
                        }

                        // CATCH-UP: Check for blocks that arrived during setup
                        // FIX #198: Use cached values instead of fetchNetworkStats() which waits for Tor
                        print("🔍 FIX #120: Height verification complete, checking for new blocks...")
                        await MainActor.run {
                            walletManager.setConnecting(true, status: "Checking for new blocks...")
                        }
                        // FIX #206 v2: Use DATABASE value, not cached networkManager.walletHeight
                        // Bug: networkManager.walletHeight was stale (not updated after sync)
                        // Result: catch-up triggered even though wallet is fully synced
                        let currentChainHeight = targetHeight  // Use cached target from above
                        let dbWalletHeight = (try? WalletDatabase.shared.getLastScannedHeight()) ?? 0
                        let currentWalletHeight = max(dbWalletHeight, networkManager.walletHeight)
                        print("🔍 FIX #206 v2: Chain height: \(currentChainHeight), wallet height: \(currentWalletHeight) (from DB: \(dbWalletHeight))")

                        // Only catch-up if wallet is actually synced (walletHeight > 0)
                        // and there are just a few missed blocks (not the entire chain)
                        if currentWalletHeight > 0 && currentChainHeight > currentWalletHeight {
                            let missedBlocks = currentChainHeight - currentWalletHeight

                            // FIX #204 v3: Never reject - always sync, just inform user
                            // Estimate: ~37 blocks/sec fetch + processing (from logs)
                            let estimatedSeconds = max(1, Int(missedBlocks / 37))
                            let timeEstimate: String
                            if estimatedSeconds < 60 {
                                timeEstimate = "~\(estimatedSeconds)s"
                            } else if estimatedSeconds < 3600 {
                                timeEstimate = "~\(estimatedSeconds / 60)m"
                            } else {
                                timeEstimate = "~\(estimatedSeconds / 3600)h \((estimatedSeconds % 3600) / 60)m"
                            }

                            print("🔄 Catch-up: \(missedBlocks) block(s) since last sync (\(timeEstimate))")

                            await MainActor.run {
                                walletManager.setConnecting(true, status: "Syncing \(missedBlocks) blocks since last start (\(timeEstimate))...")
                            }

                            // Quick sync to catch up missed blocks
                            do {
                                try await walletManager.refreshBalance()
                            } catch {
                                print("⚠️ Catch-up sync failed: \(error.localizedDescription)")
                            }

                            // Wait for catch-up to complete
                            while walletManager.isSyncing {
                                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                            }
                        }

                        // Clear connecting state after everything is done
                        await MainActor.run {
                            walletManager.setConnecting(false, status: nil)
                        }

                        // Re-enable background sync now that initial sync is complete
                        networkManager.suppressBackgroundSync = false

                        // FIX #145: Sync headers BEFORE showing completion screen
                        // This ensures timestamps are available when user enters main wallet
                        // Header sync gets EXCLUSIVE P2P access (no mempool scan interference)
                        print("📜 FIX #145: Syncing headers for timestamps before completion...")
                        await MainActor.run {
                            walletManager.setConnecting(true, status: "Syncing block timestamps...")
                        }
                        await walletManager.ensureHeaderTimestamps()

                        // FIX #191: Wait for P2P connectivity BEFORE health checks
                        // Tor restoration after header sync is async - health checks need network
                        // Without this, Equihash verification fails ("No peers connected")
                        await MainActor.run {
                            walletManager.setConnecting(true, status: "Connecting to P2P network...")
                        }
                        print("✅ FIX #191: Waiting for P2P connectivity before health checks...")
                        var p2pWaitCount = 0
                        let p2pMaxWait = 50 // 5 seconds max
                        while networkManager.connectedPeers < 3 && p2pWaitCount < p2pMaxWait {
                            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                            p2pWaitCount += 1
                        }
                        if networkManager.connectedPeers >= 3 {
                            print("✅ FIX #191: P2P connected (\(networkManager.connectedPeers) peers) - proceeding with health checks")
                        } else {
                            print("⚠️ FIX #191: Only \(networkManager.connectedPeers) peers after 5s - running health checks anyway")
                        }

                        // FIX #120/#147: Comprehensive health check at every app restart
                        // Verifies: Bundle files, Database, CMUs, Timestamps, Balance, Hashes, P2P, Equihash, Witnesses, Notes
                        // Now properly runs on background thread to prevent UI hang

                        // FIX #1306: Wait for gap-fill to complete BEFORE health check (same as FAST START)
                        let fullStartGapFillWait = CFAbsoluteTimeGetCurrent()
                        var fullStartGapFillWaiting = false
                        for _ in 1...240 {
                            let isGapFilling = await MainActor.run { walletManager.isGapFillingDelta }
                            if !isGapFilling { break }
                            if !fullStartGapFillWaiting {
                                fullStartGapFillWaiting = true
                                print("⏳ FIX #1306: Waiting for gap-fill to complete before FULL START health check...")
                                await MainActor.run {
                                    walletManager.setConnecting(true, status: "Rebuilding tree...")
                                }
                            }
                            try? await Task.sleep(nanoseconds: 500_000_000)
                        }
                        if fullStartGapFillWaiting {
                            let elapsed = CFAbsoluteTimeGetCurrent() - fullStartGapFillWait
                            print("✅ FIX #1306: Gap-fill wait complete (FULL START) after \(String(format: "%.1f", elapsed))s")
                        }

                        await MainActor.run {
                            walletManager.setConnecting(true, status: "Running health checks...")
                        }
                        let fullStartHealthResults = await WalletHealthCheck.shared.runAllChecks()

                        // FIX #147: ALWAYS print summary so user sees all check results
                        WalletHealthCheck.shared.printSummary(fullStartHealthResults)

                        let fullStartHasCritical = WalletHealthCheck.shared.hasCriticalFailures(fullStartHealthResults)
                        let fullStartFixableIssues = WalletHealthCheck.shared.getFixableIssues(fullStartHealthResults)

                        // FIX #164 v4: Check if repair is needed (checkpoint gap detected)
                        let fullStartRepairNeededCheck = fullStartHealthResults.first {
                            $0.checkName == "Checkpoint Sync" && !$0.passed && $0.details.contains("REPAIR NEEDED")
                        }
                        // FIX #686: Automatic repair at startup - NO user prompts
                        if let repair = fullStartRepairNeededCheck {
                            print("⚠️ FIX #686: Repair needed detected (FULL START) - triggering automatic repair")
                            print("⚠️ Issue: \(repair.checkName) - \(repair.details)")

                            // Trigger automatic repair instead of showing alert
                            await MainActor.run {
                                walletManager.setConnecting(true, status: "Repairing wallet state...")
                                walletManager.syncTasks.append(SyncTask(id: "full_start_repair", title: "Auto-repair", status: .inProgress, progress: 0.0))
                            }

                            do {
                                try await walletManager.repairNotesAfterDownloadedTree { progress, current, total in
                                    print("🔧 FIX #686: Full start repair progress \(Int(progress * 100))% (\(current)/\(total))")
                                    Task { @MainActor in
                                        walletManager.updateSyncTask(id: "full_start_repair", status: .inProgress, detail: "\(current)/\(total)", progress: progress)
                                    }
                                }
                                await MainActor.run {
                                    walletManager.updateSyncTask(id: "full_start_repair", status: .completed)
                                }
                                print("✅ FIX #686: Full start repair complete")
                            } catch {
                                print("❌ FIX #686: Full start repair failed: \(error.localizedDescription)")
                                // Even on failure, continue to import - user can manually trigger repair from Settings
                            }
                        }

                        // FIX #439: Check for Tree Root mismatch (critical but REPAIRABLE via Full Rescan)
                        let fullStartHasTreeRootMismatch = fullStartHealthResults.contains {
                            $0.checkName == "Tree Root Validation" && !$0.passed && $0.critical
                        }

                        // FIX #1078: Check for Balance Integrity failure (critical but REPAIRABLE via Full Rescan)
                        let fullStartHasBalanceCorruption = fullStartHealthResults.contains {
                            $0.checkName == "Balance Integrity" && !$0.passed && $0.critical
                        }

                        // FIX #1302: Auto Full Rescan DISABLED — Phase 2 P2P creates phantom notes.
                        // Log the issue, user can manually Full Rescan from Settings.
                        if false && fullStartHasCritical && (fullStartHasTreeRootMismatch || fullStartHasBalanceCorruption) {
                            // FIX #1078: Balance corruption or Tree Root mismatch - auto-trigger Full Rescan (DISABLED by FIX #1302)
                            if fullStartHasBalanceCorruption {
                                print("🔧 FIX #1078: Balance corruption detected (FULL START) - AUTO-triggering Full Rescan...")
                            }
                            if fullStartHasTreeRootMismatch {
                                print("🔧 FIX #439: Tree Root mismatch detected (FULL START) - triggering Full Rescan...")
                            }
                            let fullStartStatusMsg = fullStartHasBalanceCorruption ? "Balance issue - rebuilding..." : "Tree mismatch - rebuilding..."
                            await MainActor.run {
                                walletManager.setConnecting(true, status: fullStartStatusMsg)
                                walletManager.syncTasks.append(SyncTask(id: "tree_rebuild", title: "Rebuilding wallet data", status: .inProgress, progress: 0.0))
                            }

                            do {
                                try await walletManager.repairNotesAfterDownloadedTree(onProgress: { progress, current, total in
                                    print("🔧 FIX #439: Tree rebuild progress \(Int(progress * 100))% (\(current)/\(total))")
                                    Task { @MainActor in
                                        walletManager.updateSyncTask(id: "tree_rebuild", status: .inProgress, detail: "\(current)/\(total) blocks", progress: progress)
                                    }
                                }, forceFullRescan: true)
                                await MainActor.run {
                                    walletManager.updateSyncTask(id: "tree_rebuild", status: .completed)
                                }
                                print("✅ FIX #439: Tree rebuild complete (FULL START)")
                            } catch {
                                print("❌ FIX #439: Tree rebuild failed: \(error.localizedDescription)")
                                await MainActor.run {
                                    walletManager.updateSyncTask(id: "tree_rebuild", status: .failed("Rebuild failed"))
                                    walletManager.setConnecting(true, status: "Tree rebuild failed - please try Full Rescan in Settings")
                                }
                                return
                            }
                        } else if fullStartHasCritical {
                            print("❌ FULL START: Critical health check failures detected - wallet may not function correctly")
                            // FIX #120: Stay on sync screen for critical failures
                            await MainActor.run {
                                walletManager.setConnecting(true, status: "Critical issue detected - please restart app")
                            }
                            // Don't transition to main UI - keep showing sync screen
                            return
                        } else if !fullStartFixableIssues.isEmpty {
                            // FIX #120: Non-critical issues found - attempt to fix BEFORE showing main UI
                            print("⚠️ FULL START: \(fullStartFixableIssues.count) fixable issues found - attempting repair...")

                            for issue in fullStartFixableIssues {
                                print("⚠️ Issue: \(issue.checkName) - \(issue.details)")
                            }

                            // Attempt automatic repair based on issue type
                            await MainActor.run {
                                walletManager.setConnecting(true, status: "Repairing wallet state...")
                            }

                            // Check for specific issues and fix them
                            let fullStartHasWitnessIssues = fullStartFixableIssues.contains { $0.checkName == "Witness Validity" }
                            let fullStartHasDeltaCMUIssues = fullStartFixableIssues.contains { $0.checkName == "Delta CMU" }
                            let fullStartHasTimestampIssues = fullStartFixableIssues.contains { $0.checkName == "Timestamps" }
                            let fullStartHasHashIssues = fullStartFixableIssues.contains { $0.checkName == "Hash Accuracy" }
                            let fullStartHasBalanceIssues = fullStartFixableIssues.contains { $0.checkName == "Balance Integrity" }
                            // FIX #411: Handle Tree Root Validation issues - headers not synced to lastScannedHeight
                            let fullStartHasTreeRootIssues = fullStartFixableIssues.contains { $0.checkName == "Tree Root Validation" }

                            // FIX #120: Handle Hash Accuracy issues - clear and resync headers
                            if fullStartHasHashIssues {
                                print("🔧 FIX #120: Hash mismatch detected - clearing headers for resync...")
                                await MainActor.run {
                                    walletManager.setConnecting(true, status: "Clearing corrupt headers...")
                                }
                                try? HeaderStore.shared.clearAllHeaders()
                                // Headers will be resynced by ensureHeaderTimestamps below
                            }

                            if fullStartHasWitnessIssues || fullStartHasDeltaCMUIssues {
                                print("🔧 FIX #120: Repairing witnesses and tree state...")
                                // FIX #156: Add repair task to task list for UI visibility
                                await MainActor.run {
                                    walletManager.setConnecting(true, status: "Rebuilding witnesses...")
                                    walletManager.syncTasks.append(SyncTask(id: "full_repair", title: "Verifying transactions", status: .inProgress, progress: 0.0))
                                }
                                try? await walletManager.repairNotesAfterDownloadedTree { progress, current, total in
                                    print("🔧 FIX #120: Repair progress \(Int(progress * 100))% (\(current)/\(total))")
                                    // FIX #156: Update task progress in UI
                                    Task { @MainActor in
                                        walletManager.updateSyncTask(id: "full_repair", status: .inProgress, detail: "\(current)/\(total) witnesses", progress: progress)
                                    }
                                }
                                // FIX #156: Mark repair task as complete
                                await MainActor.run {
                                    walletManager.updateSyncTask(id: "full_repair", status: .completed)
                                }
                            }

                            // FIX #120/411: Handle Timestamp, Hash, or Tree Root issues (all need header sync)
                            if fullStartHasTimestampIssues || fullStartHasHashIssues || fullStartHasTreeRootIssues {
                                if fullStartHasTreeRootIssues {
                                    // FIX #479: Check if tree root issue is just PHASE 2 delta CMUs (expected after import)
                                    // If details contain "PHASE 2" or "extra CMUs", this is non-critical and should NOT trigger repair
                                    let treeRootIssue = fullStartFixableIssues.first { $0.checkName == "Tree Root Validation" }
                                    if let issue = treeRootIssue, issue.details.contains("PHASE 2") || issue.details.contains("extra CMUs") {
                                        print("📦 FIX #479/#481: Tree root issue is PHASE 2 delta (expected after import) - skipping automatic repair")
                                        print("📦 FIX #481: Witnesses will be rebuilt on-demand during send (FIX #480)")
                                        // Skip the tree rebuild - witnesses will be rebuilt when needed via FIX #480
                                    } else {
                                        // FIX #418: Load bundled headers from boost file FIRST (instant vs P2P timeout!)
                                    // The boost file has 2.4M+ headers - loading them is instant
                                    // Then we only need P2P delta sync for the last few hundred blocks
                                    print("🔧 FIX #418: Tree Root Validation failed - loading boost file headers first...")
                                    await MainActor.run {
                                        walletManager.setConnecting(true, status: "Loading bundled headers...")
                                    }
                                    let (loadedBoostHeaders, boostEndHeight) = await walletManager.loadHeadersFromBoostFile()
                                    if loadedBoostHeaders {
                                        print("✅ FIX #418: Loaded bundled headers up to \(boostEndHeight)")
                                    }

                                    // FIX #411: Tree Root Validation needs headers at lastScannedHeight
                                    // Now we only need P2P delta sync (boost end → lastScanned)
                                    print("🔧 FIX #411: Tree Root Validation - syncing delta headers via P2P...")
                                    await MainActor.run {
                                        walletManager.setConnecting(true, status: "Syncing delta headers...")
                                    }
                                    let headerStoreHeight = (try? HeaderStore.shared.getLatestHeight()) ?? 0
                                    let lastScanned = (try? WalletDatabase.shared.getLastScannedHeight()) ?? 0
                                    if lastScanned > headerStoreHeight {
                                        let gap = lastScanned - headerStoreHeight
                                        print("🔧 FIX #411: HeaderStore at \(headerStoreHeight), need \(lastScanned), gap=\(gap)")
                                        let hsm = HeaderSyncManager(headerStore: HeaderStore.shared, networkManager: NetworkManager.shared)

                                        // FIX #464: Report header sync progress to UI
                                        hsm.onProgress = { progress in
                                            Task { @MainActor in
                                                walletManager.setConnecting(true, status: "Syncing delta headers \(progress.currentHeight)/\(progress.totalHeight)...")
                                            }
                                        }

                                        try? await hsm.syncHeaders(from: headerStoreHeight + 1, maxHeaders: gap + 100)
                                    }
                                }
                            }
                            }

                            // FIX #162: Handle Balance Integrity issues - rebuild history from unspent notes ONLY
                            // The old populateHistoryFromNotes() created fake transactions with synthetic txids
                            // causing more corruption. New approach: clear history and add ONLY unspent notes as received.
                            if fullStartHasBalanceIssues {
                                print("🔧 FIX #162: Balance mismatch detected - rebuilding transaction history...")
                                await MainActor.run {
                                    walletManager.setConnecting(true, status: "Rebuilding transaction history...")
                                }
                                try? WalletDatabase.shared.clearTransactionHistory()
                                try? WalletDatabase.shared.rebuildHistoryFromUnspentNotes()
                                print("🔧 FIX #162: History rebuilt from unspent notes only (no synthetic txids)")
                            }

                            // Re-run health checks to verify fixes
                            await MainActor.run {
                                walletManager.setConnecting(true, status: "Verifying repairs...")
                            }
                            let fullStartVerifyResults = await WalletHealthCheck.shared.runAllChecks()
                            WalletHealthCheck.shared.printSummary(fullStartVerifyResults)

                            let fullStartStillHasIssues = WalletHealthCheck.shared.getFixableIssues(fullStartVerifyResults)

                            // FIX #488: Filter out non-critical issues (e.g., tree root mismatch at boost height)
                            // Non-critical issues should NOT block the app from completing
                            // Tree root mismatch after PHASE 2 is EXPECTED (tree has extra CMUs from scanning)
                            let fullStartBlockingIssues = fullStartStillHasIssues.filter { $0.critical }
                            let nonCriticalIssues = fullStartStillHasIssues.filter { !$0.critical }

                            // Log non-critical issues for awareness
                            if !nonCriticalIssues.isEmpty {
                                print("⚠️ FULL START: \(nonCriticalIssues.count) non-critical issues (app will continue):")
                                for issue in nonCriticalIssues {
                                    print("   ⚠️ \(issue.checkName): \(issue.details)")
                                }
                            }

                            if !fullStartBlockingIssues.isEmpty {
                                // FIX #412: Stay on sync screen if ANY issues remain
                                print("❌ FULL START: \(fullStartBlockingIssues.count) blocking issues remain after repair!")
                                for issue in fullStartBlockingIssues {
                                    print("❌ Remaining issue: \(issue.checkName) - \(issue.details)")
                                }
                                await MainActor.run {
                                    walletManager.setConnecting(true, status: "Repair incomplete - please restart app")
                                }
                                // Keep showing sync screen - don't proceed to main UI
                                return
                            } else {
                                // FIX #488: All CRITICAL issues fixed! (non-critical issues may remain)
                                if !nonCriticalIssues.isEmpty {
                                    print("✅ FULL START: All CRITICAL issues fixed! (with \(nonCriticalIssues.count) non-critical warnings)")
                                } else {
                                    print("✅ FULL START: All health checks passed! (100% complete)")
                                }
                            }
                        } else {
                            print("✅ FULL START: All health checks passed! (100% complete)")
                        }

                        // FIX #1118: Detect balance issues for FULL START
                        // This blocks SEND and shows warning even if discrepancy is marked non-critical
                        let fullStartHasAnyBalanceIssue = fullStartHealthResults.contains {
                            $0.checkName == "Balance Integrity" && !$0.passed
                        }
                        if fullStartHasAnyBalanceIssue {
                            print("⚠️ FIX #1118: Balance discrepancy detected (FULL START) - blocking SEND and showing warning")
                        }

                        // FIX #1118 v2: Set flag in same block as UI state changes
                        await MainActor.run {
                            if fullStartHasAnyBalanceIssue {
                                walletManager.balanceIntegrityIssue = true
                                walletManager.balanceIntegrityMessage = "Balance discrepancy detected - run Full Resync in Settings"
                                print("🚨 FIX #1118 v2: balanceIntegrityIssue set to TRUE (FULL START)")
                            }
                            walletManager.setConnecting(false, status: nil)
                        }

                        // Calculate final duration and show completion screen
                        // Uses effectiveStartTime (walletCreationTime if set, otherwise appStartupTime)
                        print("🔍 FIX #120: All checks done, showing completion screen")
                        await MainActor.run {
                            syncCompletionDuration = Date().timeIntervalSince(effectiveStartTime)
                            showCompletionScreen = true
                            print("🔍 FIX #120: showCompletionScreen = true, isInitialSync = \(isInitialSync)")
                        }

                        // Wait for user to click the enter button
                        // The button callback will set isInitialSync = false
                    }

                // SINGLE cypherpunk overlay for ALL initial sync phases
                // Shows during: tree loading, connecting, syncing - until initial sync complete
                // FIX #577 v7: Also show during Full Rescan (same UI as Import PK)
                if isInitialSync || walletManager.isFullRescan {
                    CypherpunkSyncView(
                        progress: currentSyncProgress,
                        status: currentSyncStatus,
                        tasks: currentSyncTasks,
                        startTime: effectiveStartTime,  // Use wallet creation time for accurate duration
                        estimatedDuration: estimatedSyncDuration,
                        isComplete: walletManager.isFullRescan ? walletManager.isRescanComplete : showCompletionScreen,
                        completionDuration: walletManager.isFullRescan ? walletManager.rescanCompletionDuration : syncCompletionDuration,
                        onEnterWallet: {
                            // User clicked the enter button
                            withAnimation(.easeOut(duration: 0.3)) {
                                isInitialSync = false
                                hasCompletedInitialSync = true
                                showCompletionScreen = false
                                // FIX #577 v7 + FIX #582: Clear ALL Full Rescan flags when entering wallet
                                if walletManager.isRescanComplete || walletManager.isFullRescan {
                                    walletManager.clearFullRescanFlags()
                                }
                            }

                            // FIX #145: Enable background processes NOW (user is entering main wallet)
                            // Header sync should have completed during initial sync phase
                            networkManager.enableBackgroundProcesses()

                            // FIX #1273: Ensure lock screen shown after initial sync (redundant safety)
                            if !biometricManager.hasAuthenticatedThisSession {
                                isShowingLockScreen = true
                            }

                            // Start inactivity timer now that sync is done
                            startInactivityTimer()

                            // FIX #603: Start periodic witness refresh to keep witnesses fresh
                            walletManager.startPeriodicWitnessRefresh()

                            // FIX #370 + FIX #681: Start periodic deep verification and auto-recovery
                            walletManager.startPeriodicDeepVerification()

                            // FIX #1354: Check if newer boost file available on GitHub
                            walletManager.checkForBoostUpdate()

                            // FIX #1128: Run delta bundle compaction in background (non-blocking)
                            Task.detached(priority: .background) {
                                let result = DeltaCMUManager.shared.compactDeltaBundleIfNeeded()
                                if result.removed > 0 {
                                    print("✅ FIX #1128: Background compaction removed \(result.removed) duplicate CMUs")
                                }
                            }
                        },
                        onStopSync: {
                            // User clicked STOP - cancel sync and go to main wallet
                            walletManager.stopSync()
                            withAnimation(.easeOut(duration: 0.3)) {
                                isInitialSync = false
                                hasCompletedInitialSync = true
                                showCompletionScreen = false
                                // FIX #577 v7 + FIX #582: Clear ALL Full Rescan flags on stop
                                if walletManager.isFullRescan || walletManager.isRescanComplete {
                                    walletManager.clearFullRescanFlags()
                                }
                            }
                            // FIX #145: Enable background processes even on early stop
                            networkManager.enableBackgroundProcesses()

                            // FIX #1273: MUST show lock screen on stop sync too — prevents bypass
                            if !biometricManager.hasAuthenticatedThisSession {
                                isShowingLockScreen = true
                            }

                            // Start inactivity timer
                            startInactivityTimer()
                        },
                        onDeleteAndRestart: {
                            // User wants to delete everything and start over
                            walletManager.stopSync()
                            do {
                                try walletManager.deleteWallet()
                            } catch {
                                print("❌ Failed to delete wallet: \(error)")
                            }
                        }
                    )
                    .transition(.opacity)
                    // FIX #1079: Track max progress to ensure it never decreases
                    .onChange(of: rawSyncProgress) { newProgress in
                        if newProgress > maxDisplayedProgress {
                            maxDisplayedProgress = newProgress
                        }
                    }
                    // FIX #1079: Reset max progress when Full Rescan starts
                    .onChange(of: walletManager.isFullRescan) { isRescan in
                        if isRescan {
                            maxDisplayedProgress = 0.0
                        }
                    }
                    // FIX #1295: Reset monotonic tracker when new sync tasks appear
                    // Prevents locked-at-100% when tree+connect finish before health checks
                    .onChange(of: walletManager.syncTasks.count) { _ in
                        let currentRaw = rawSyncProgress
                        if currentRaw < maxDisplayedProgress - 0.1 {
                            maxDisplayedProgress = currentRaw
                        }
                    }
                }

                // DEBUG: Confirmation overlay to pause before showing balance view
                if debugWaitingForConfirmation {
                    ZStack {
                        // Semi-transparent background
                        Color.black.opacity(0.85)
                            .ignoresSafeArea()

                        VStack(spacing: 20) {
                            Text("🔴 DEBUG PAUSE")
                                .font(.system(size: 28, weight: .bold, design: .monospaced))
                                .foregroundColor(.red)

                            Text(debugCompletionMessage)
                                .font(.system(size: 14, weight: .medium, design: .monospaced))
                                .foregroundColor(.white)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 20)

                            Spacer().frame(height: 20)

                            Button(action: {
                                debugWaitingForConfirmation = false
                            }) {
                                Text("CONTINUE TO BALANCE →")
                                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                                    .foregroundColor(.black)
                                    .padding(.horizontal, 30)
                                    .padding(.vertical, 15)
                                    .background(Color.green)
                                    .cornerRadius(8)
                            }
                            .buttonStyle(.plain)

                            Text("Tap to proceed to main balance view")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.gray)
                        }
                        .padding(40)
                    }
                    .transition(.opacity)
                }

                // Floating sync progress indicator for BACKGROUND syncing
                // Shows when syncing after initial sync is complete (user can still use app)
                if !isInitialSync && walletManager.isSyncing {
                    floatingSyncIndicator
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                // FIX #242: Floating catch-up indicator when returning from background
                // Shows in ORANGE when wallet is behind blockchain after app becomes active
                if !isInitialSync && walletManager.isCatchingUp && !walletManager.isSyncing {
                    floatingCatchUpIndicator
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                // FIX #144: Floating header sync progress indicator
                // Shows when syncing block timestamps - NOW SHOWS DURING INITIAL SYNC TOO
                // Removed !isInitialSync condition so progress bar appears immediately at startup
                if walletManager.isHeaderSyncing {
                    floatingHeaderSyncIndicator
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

            } else {
                WalletSetupView()
            }

            // FIX #1276: Lock screen is OUTSIDE the walletManager conditional.
            // Previously inside the `if isWalletCreated` block — walletManager @Published
            // property changes after auth caused SwiftUI to recreate the entire block,
            // giving LockScreenView a new .onAppear → second Touch ID prompt.
            // Now independent of wallet state changes.
            if isShowingLockScreen && !biometricManager.hasAuthenticatedThisSession {
                LockScreenView(onUnlock: {
                    withAnimation {
                        isShowingLockScreen = false
                        biometricManager.unlockApp()
                        lastActivityTime = Date()
                    }
                })
                .transition(.opacity)
            }
        }
        .onChange(of: scenePhase) { newPhase in
            handleScenePhaseChange(newPhase)
        }
        #if os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.userDidTakeScreenshotNotification)) { _ in
            // Record activity on screenshot (user is interacting)
            recordUserActivity()
        }
        #endif
    }

    // MARK: - Scene Phase Handling

    private func handleScenePhaseChange(_ phase: ScenePhase) {
        switch phase {
        case .background:
            // FIX #258: Track that we went to background (for reconnection on return)
            wasInBackground = true
            // Stop inactivity timer when going to background
            stopInactivityTimer()
            // FIX #1273: Always lock app when going to background
            biometricManager.lockApp()
            isShowingLockScreen = true

        case .active:
            // App became active
            if hasCompletedInitialSync {
                // Check if we need to re-authenticate (inactivity timeout)
                if biometricManager.isBiometricEnabled && biometricManager.isInactivityTimeoutExceeded {
                    isShowingLockScreen = true
                    biometricManager.lockApp()
                } else if biometricManager.isLocked {
                    // Still locked from background - show lock screen
                    isShowingLockScreen = true
                }
            }
            // Record activity on app becoming active
            recordUserActivity()
            // Start inactivity timer when app becomes active
            startInactivityTimer()

            // FIX #258: Force reconnect peers when returning from background
            // iOS suspends network connections in background, so all sockets are dead
            // Only trigger if we actually went to .background (not just .inactive from control center)
            if wasInBackground {
                wasInBackground = false  // Reset flag
                Task {
                    await networkManager.reconnectAfterBackground()
                }
            }

            // FIX #242: Check if wallet is behind and catch up
            if hasCompletedInitialSync {
                Task {
                    await walletManager.checkAndCatchUp()
                }
            }

        case .inactive:
            // Brief transition state - don't change lock status
            break

        @unknown default:
            break
        }
    }

    // MARK: - Activity Tracking

    private func recordUserActivity() {
        lastActivityTime = Date()
        biometricManager.recordUserActivity()
    }

    private func startInactivityTimer() {
        // Stop existing timer
        inactivityTimer?.invalidate()

        // FIX #1273: Always run inactivity timer (auth is always mandatory).
        // Only skip if timeout is set to "Never" (0).
        guard biometricManager.authTimeout > 0 else {
            return
        }

        // Check every 5 seconds
        inactivityTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
            checkInactivityTimeout()
        }
    }

    private func stopInactivityTimer() {
        inactivityTimer?.invalidate()
        inactivityTimer = nil
    }

    private func checkInactivityTimeout() {
        // FIX #1273: Check inactivity regardless of biometric setting (auth always mandatory)
        guard !isShowingLockScreen,
              !isInitialSync,
              biometricManager.isInactivityTimeoutExceeded else {
            return
        }

        // Inactivity timeout exceeded - show lock screen
        DispatchQueue.main.async {
            isShowingLockScreen = true
            biometricManager.lockApp()
        }
    }

    /// Combined progress for all sync phases - MONOTONIC (never decreases!)
    /// FIX #1079: Progress NEVER goes backward - uses max tracking
    private var currentSyncProgress: Double {
        // FIX #560: Check if we're in FAST START mode (tree loaded, initial sync)
        // FIX #577 v13: Also treat Full Rescan like initial sync (same progress display as Import PK)
        // Don't check isSyncing because FAST START might sync headers!
        let isFastStartMode = walletManager.isTreeLoaded && (isInitialSync || walletManager.isFullRescan)

        var rawProgress: Double = 0.0

        if isFastStartMode {
            // FIX #1079: Only count tasks that are ACTUALLY RUNNING or COMPLETED
            // Don't count pending tasks in the denominator (they may never run!)
            var completedCount = 0
            var inProgressCount = 0

            // Tree task (always completed in FAST START)
            completedCount += 1

            // Connect task
            if networkManager.isConnected {
                completedCount += 1
            } else if walletManager.isConnecting {
                inProgressCount += 1
            }

            // FIX #1079: Count only NON-PENDING tasks from syncTasks
            // FIX #1295: Simplified — only essential tasks for progress calculation
            let relevantTaskIds: Set<String>
            if walletManager.isFullRescan {
                relevantTaskIds = [
                    "scan", "witnesses", "balance",
                    "tree_rebuild", "full_start_repair", "full_repair"
                ]
            } else {
                relevantTaskIds = [
                    "fast_balance", "fast_peers", "fast_headers", "fast_health", "fast_repair",
                    "witness_sync", "balance_repair", "balance_repair_early",
                    "tree_rebuild", "instant_repair"
                ]
            }

            // FIX #1079: Only count tasks that have STARTED (not pending)
            // FIX #1121: For Full Rescan, count ALL tasks (pending WILL run!)
            var pendingCount = 0
            for task in walletManager.syncTasks {
                let isRelevant = relevantTaskIds.contains(task.id) ||
                    (!walletManager.isFullRescan && task.id.hasPrefix("fast_"))
                guard isRelevant else { continue }

                switch task.status {
                case .completed, .failed:
                    completedCount += 1
                case .inProgress:
                    inProgressCount += 1
                case .pending:
                    // FIX #1121: For Full Rescan, pending tasks WILL run, so count them
                    if walletManager.isFullRescan {
                        pendingCount += 1
                    }
                    // FIX #1079: For FAST START, DON'T count pending tasks - they may never run!
                }
            }

            // FIX #1121: Calculate progress based on ALL tasks for Full Rescan
            // FIX #1079: For FAST START, only count active tasks
            // FIX #1295: Prevent premature 100% by ensuring minimum task count
            let hasSyncActivity = completedCount + inProgressCount > 2  // More than just tree+connect
            let totalTasks: Int
            if walletManager.isFullRescan {
                // Full Rescan: ALL relevant tasks count (pending WILL run)
                totalTasks = completedCount + inProgressCount + pendingCount
            } else {
                // FAST START: Only active tasks, but always at least 3 to prevent premature 100%
                // FIX #1295: tree(1) + connect(1) alone = 2/2 = 100% BEFORE health checks start
                totalTasks = hasSyncActivity ? (completedCount + inProgressCount) : max(completedCount + inProgressCount, 3)
            }

            if totalTasks > 0 {
                // In-progress tasks count as 50% complete, pending as 0%
                let effectiveComplete = Double(completedCount) + (Double(inProgressCount) * 0.5)
                // If still connecting, cap at 95%
                let maxProgress = walletManager.isConnecting ? 0.95 : 1.0
                rawProgress = min((effectiveComplete / Double(totalTasks)), maxProgress)
            } else {
                rawProgress = 0.1  // At least show some progress
            }
        } else {
            // Use the monotonic progress from WalletManager for normal sync
            // This never goes backward, providing smooth UX
            let baseProgress = walletManager.overallProgress

            // If we're in post-sync verification (isConnecting after tasks complete),
            // cap progress at 98% so user knows it's not fully done yet
            let statusAllTasksCompleted = !walletManager.syncTasks.isEmpty && walletManager.syncTasks.allSatisfy {
                if case .completed = $0.status { return true }
                if case .failed = $0.status { return true }
                return false
            }

            if statusAllTasksCompleted && walletManager.isConnecting {
                rawProgress = min(baseProgress, 0.98)
            } else {
                rawProgress = baseProgress
            }
        }

        // FIX #1079: MONOTONIC - Return the max of raw progress and stored max
        // The actual max tracking happens in the view via onChange
        return max(rawProgress, maxDisplayedProgress)
    }

    /// FIX #1079: Raw progress for tracking (used by onChange to update maxDisplayedProgress)
    /// FIX #1121: For Full Rescan, count pending tasks in total
    private var rawSyncProgress: Double {
        let isFastStartMode = walletManager.isTreeLoaded && (isInitialSync || walletManager.isFullRescan)

        if isFastStartMode {
            var completedCount = 0
            var inProgressCount = 0
            var pendingCount = 0

            completedCount += 1  // Tree always completed

            if networkManager.isConnected {
                completedCount += 1
            } else if walletManager.isConnecting {
                inProgressCount += 1
            }

            // FIX #1295: Simplified — only essential tasks for progress
            let relevantTaskIds: Set<String> = walletManager.isFullRescan ?
                ["scan", "witnesses", "balance",
                 "tree_rebuild", "full_start_repair", "full_repair"] :
                ["fast_balance", "fast_peers", "fast_headers", "fast_health", "fast_repair",
                 "witness_sync", "balance_repair", "balance_repair_early", "tree_rebuild", "instant_repair"]

            for task in walletManager.syncTasks {
                let isRelevant = relevantTaskIds.contains(task.id) ||
                    (!walletManager.isFullRescan && task.id.hasPrefix("fast_"))
                guard isRelevant else { continue }

                switch task.status {
                case .completed, .failed: completedCount += 1
                case .inProgress: inProgressCount += 1
                case .pending:
                    // FIX #1121: For Full Rescan, pending tasks WILL run
                    if walletManager.isFullRescan { pendingCount += 1 }
                }
            }

            // FIX #1121: Include pending tasks in total for Full Rescan
            // FIX #1295: Prevent premature 100% when only tree+connect are done
            let hasSyncActivity = completedCount + inProgressCount > 2
            let totalTasks: Int
            if walletManager.isFullRescan {
                totalTasks = completedCount + inProgressCount + pendingCount
            } else {
                totalTasks = hasSyncActivity ? (completedCount + inProgressCount) : max(completedCount + inProgressCount, 3)
            }

            if totalTasks > 0 {
                let effectiveComplete = Double(completedCount) + (Double(inProgressCount) * 0.5)
                let maxProgress = walletManager.isConnecting ? 0.95 : 1.0
                return min((effectiveComplete / Double(totalTasks)), maxProgress)
            }
            return 0.1
        }

        return walletManager.overallProgress
    }

    /// Combined status for all sync phases
    private var currentSyncStatus: String {
        // Tree loading (first step now)
        if !walletManager.isTreeLoaded {
            return walletManager.treeLoadStatus.isEmpty ? "Loading commitment tree..." : walletManager.treeLoadStatus
        }
        // Connecting (after tree loaded)
        if !networkManager.isConnected {
            return walletManager.isConnecting ? "Connecting to network..." : "Waiting for network..."
        }

        // Check completion status
        let statusAllTasksCompleted = !walletManager.syncTasks.isEmpty && walletManager.syncTasks.allSatisfy {
            if case .completed = $0.status { return true }
            if case .failed = $0.status { return true }
            return false
        }

        // PRIORITY 1: Post-sync verification (isConnecting after sync complete)
        // This shows status like "Verifying sync completion..." or "Checking for new blocks..."
        if statusAllTasksCompleted && walletManager.isConnecting && !walletManager.syncStatus.isEmpty {
            return walletManager.syncStatus
        }

        // PRIORITY 2: All tasks completed but no specific status - show generic message
        if statusAllTasksCompleted {
            return "Finalizing..."
        }

        // Syncing (includes waiting for sync to start)
        if walletManager.isSyncing || !walletManager.syncTasks.isEmpty {
            if walletManager.syncStatus.isEmpty {
                return "Starting blockchain sync..."
            }
            return walletManager.syncStatus
        }

        // Catch-up phase - waiting for new blocks (BEFORE sync tasks created)
        if walletManager.isConnecting && !walletManager.isSyncing {
            // Use the status set by WalletManager if available
            if !walletManager.syncStatus.isEmpty {
                return walletManager.syncStatus
            }
            return "Catching up new blocks..."
        }

        // Tree loaded, network connected, sync complete
        // FIX #255: Don't show Ready when chain height is 0 (peers not yet synced)
        if walletManager.isTreeLoaded && networkManager.isConnected && !isInitialSync && networkManager.chainHeight > 0 {
            return "Ready!"
        }
        // FIX #255: Show connecting status when chain height is 0
        if networkManager.chainHeight == 0 && networkManager.isConnected {
            return "Syncing with peers..."
        }
        // Waiting for sync to start
        return "Preparing sync..."
    }

    /// Combined task list including tree loading
    /// FIX #1297: Tasks sorted in chronological execution order
    private var currentSyncTasks: [SyncTask] {
        let isFastStartMode = walletManager.isTreeLoaded && (isInitialSync || walletManager.isFullRescan)

        var tasks: [SyncTask] = []

        // 1. Tree loading task
        if !walletManager.isTreeLoaded {
            tasks.append(SyncTask(
                id: "tree",
                title: "Load commitment tree",
                status: .inProgress,
                detail: walletManager.treeLoadStatus,
                progress: walletManager.treeLoadProgress
            ))
        } else {
            tasks.append(SyncTask(id: "tree", title: "Loading wallet data", status: .completed))
        }

        // 2. Network connection task
        if walletManager.isTreeLoaded {
            if !networkManager.isConnected {
                let status: SyncTaskStatus = walletManager.isConnecting ? .inProgress : .pending
                tasks.append(SyncTask(id: "connect", title: "Connecting to network", status: status))
            } else {
                tasks.append(SyncTask(id: "connect", title: "Connecting to network", status: .completed))
            }
        } else {
            tasks.append(SyncTask(id: "connect", title: "Connecting to network", status: .pending))
        }

        // 3. Sync tasks from WalletManager — only non-pending, sorted chronologically
        if isFastStartMode {
            if walletManager.isConnecting {
                tasks.append(SyncTask(id: "finalizing", title: "Finalizing startup...", status: .inProgress))
            }

            if walletManager.isFullRescan {
                // FIX #1295: Only essential phases for Full Rescan
                let essentialTaskIds: Set<String> = [
                    "scan", "witnesses", "balance",
                    "tree_rebuild", "full_start_repair", "full_repair"
                ]
                let coreTasks = walletManager.syncTasks.filter { task in
                    guard essentialTaskIds.contains(task.id) else { return false }
                    if case .pending = task.status { return false }
                    return true
                }
                tasks.append(contentsOf: coreTasks)
            } else {
                // FAST START tasks
                let fastStartTaskIds: Set<String> = [
                    "witness_sync", "balance_repair", "balance_repair_early",
                    "tree_rebuild", "instant_repair", "fast_repair"
                ]
                let fastTasks = walletManager.syncTasks.filter { task in
                    let isRelevant = task.id.hasPrefix("fast_") || fastStartTaskIds.contains(task.id)
                    guard isRelevant else { return false }
                    if case .pending = task.status { return false }
                    return true
                }
                tasks.append(contentsOf: fastTasks)
            }
        } else {
            if !walletManager.syncTasks.isEmpty {
                let activeTasks = walletManager.syncTasks.filter { task in
                    if case .pending = task.status { return false }
                    return true
                }
                tasks.append(contentsOf: activeTasks)
            } else if networkManager.isConnected && walletManager.isTreeLoaded && !walletManager.isSyncing {
                tasks.append(SyncTask(id: "scan", title: "Finding transactions", status: .completed))
            }
        }

        // FIX #1297: Sort tasks in chronological execution order
        // Completed tasks first (already done), then in-progress, then pending
        // Within each group, maintain the defined order via the index lookup
        let chronologicalOrder: [String] = [
            "tree", "connect",
            // FAST START order
            "fast_balance", "fast_peers", "fast_headers", "fast_health", "fast_repair",
            // Full Rescan order
            "scan", "witnesses", "balance",
            // Repair tasks
            "instant_repair", "balance_repair_early", "balance_repair",
            "witness_sync", "tree_rebuild", "full_start_repair", "full_repair",
            "balance_verify", "finalizing"
        ]
        tasks.sort { a, b in
            let aStatus: Int = { switch a.status { case .completed, .failed: return 0; case .inProgress: return 1; case .pending: return 2 } }()
            let bStatus: Int = { switch b.status { case .completed, .failed: return 0; case .inProgress: return 1; case .pending: return 2 } }()
            if aStatus != bStatus { return aStatus < bStatus }
            let aIdx = chronologicalOrder.firstIndex(of: a.id) ?? 999
            let bIdx = chronologicalOrder.firstIndex(of: b.id) ?? 999
            return aIdx < bIdx
        }

        return tasks
    }

    /// Check if current theme is Cypherpunk
    private var isCypherpunkTheme: Bool {
        themeManager.currentThemeType == .cypherpunk
    }

    private var mainWalletView: some View {
        Group {
            #if os(macOS)
            // FIX #448: Check if using wallet.dat mode - show FullNodeWalletView instead
            if modeManager.walletSource == .walletDat {
                FullNodeWalletView()
                    .environmentObject(themeManager)
            } else if isCypherpunkTheme {
                // Cypherpunk theme: Single-screen layout with balance, buttons, history
                cypherpunkWalletView
            } else {
                // Classic themes: Tab-based layout
                classicWalletView
            }
            #else
            // iOS: Always light mode views
            if isCypherpunkTheme {
                // Cypherpunk theme: Single-screen layout with balance, buttons, history
                cypherpunkWalletView
            } else {
                // Classic themes: Tab-based layout
                classicWalletView
            }
            #endif
        }
    }

    // MARK: - Cypherpunk Wallet View

    private var cypherpunkWalletView: some View {
        CypherpunkMainView(
            showSettings: $showCypherpunkSettings,
            showSend: $showCypherpunkSend,
            showReceive: $showCypherpunkReceive,
            showChat: $showCypherpunkChat
        )
        .sheet(isPresented: $showCypherpunkSettings) {
            VStack(spacing: 0) {
                // Header
                HStack {
                    Spacer()
                    Text("Settings")
                        .font(.headline)
                        .foregroundColor(NeonColors.primary)
                    Spacer()
                    Button("Done") {
                        showCypherpunkSettings = false
                    }
                    .foregroundColor(NeonColors.primary)
                }
                .padding()
                .background(Color.black)

                SettingsView()
            }
            #if os(macOS)
            // FIX #257: Use min/ideal/max constraints for better macOS window sizing
            .frame(minWidth: 480, idealWidth: 550, maxWidth: 650,
                   minHeight: 550, idealHeight: 650, maxHeight: 800)
            #endif
            .environmentObject(walletManager)
            .environmentObject(networkManager)
            .environmentObject(themeManager)
        }
        .sheet(isPresented: $showCypherpunkSend) {
            VStack(spacing: 0) {
                // Header
                HStack {
                    Button("Cancel") {
                        showCypherpunkSend = false
                    }
                    .foregroundColor(NeonColors.primary)
                    Spacer()
                    Text("Send ZCL")
                        .font(.headline)
                        .foregroundColor(NeonColors.primary)
                    Spacer()
                }
                .padding()
                .background(Color.black)

                SendView(onSendComplete: {
                    showCypherpunkSend = false
                })
            }
            #if os(macOS)
            // FIX #257: Use min/ideal/max constraints for better macOS window sizing
            .frame(minWidth: 450, idealWidth: 520, maxWidth: 600,
                   minHeight: 500, idealHeight: 600, maxHeight: 700)
            #endif
            .environmentObject(walletManager)
            .environmentObject(networkManager)
            .environmentObject(themeManager)
        }
        .sheet(isPresented: $showCypherpunkReceive) {
            VStack(spacing: 0) {
                // Header
                HStack {
                    Spacer()
                    Text("Receive ZCL")
                        .font(.headline)
                        .foregroundColor(NeonColors.primary)
                    Spacer()
                    Button("Done") {
                        showCypherpunkReceive = false
                    }
                    .foregroundColor(NeonColors.primary)
                }
                .padding()
                .background(Color.black)

                ReceiveView()
            }
            #if os(macOS)
            // FIX #257: Use min/ideal/max constraints for better macOS window sizing
            .frame(minWidth: 380, idealWidth: 450, maxWidth: 550,
                   minHeight: 480, idealHeight: 560, maxHeight: 650)
            #endif
            .environmentObject(walletManager)
            .environmentObject(networkManager)
            .environmentObject(themeManager)
        }
        .sheet(isPresented: $showCypherpunkChat) {
            ZStack(alignment: .topTrailing) {
                // FIX #252: Pass callback to navigate to main app settings when Tor is disabled
                ChatView(onShowAppSettings: {
                    showCypherpunkChat = false
                    showCypherpunkSettings = true
                })

                // Close button overlay
                // FIX #252: Moved down to avoid overlapping with + button on iOS navigation bar
                Button(action: { showCypherpunkChat = false }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 24))
                        .foregroundColor(NeonColors.primary.opacity(0.8))
                        .background(Color.black.opacity(0.5))
                        .clipShape(Circle())
                }
                .buttonStyle(PlainButtonStyle())
                #if os(iOS)
                .padding(.top, 52)  // FIX #252: Below navigation bar to avoid overlap with + button
                #else
                .padding(.top, 8)
                #endif
                .padding(.trailing, 8)
            }
            .background(Color.black)
            #if os(macOS)
            // FIX #257: Use min/ideal/max constraints for better macOS window sizing
            .frame(minWidth: 650, idealWidth: 750, maxWidth: 900,
                   minHeight: 550, idealHeight: 650, maxHeight: 800)
            #endif
            .environmentObject(walletManager)
            .environmentObject(networkManager)
            .environmentObject(themeManager)
        }
        // FIX #278: Boost file (CMU bundle) download progress sheet
        // REMOVED: User doesn't need this info box on macOS
        // Progress is shown inline in the UI instead
        .contentShape(Rectangle())
        .onTapGesture {
            recordUserActivity()
        }
        .modifier(CypherpunkAlertsModifier(
            showInsufficientDiskSpaceAlert: $showInsufficientDiskSpaceAlert,
            showRepairNeededAlert: $showRepairNeededAlert,
            showSybilAttackAlert: $showSybilAttackAlert,
            showExternalWalletSpendAlert: $showExternalWalletSpendAlert,
            showReducedVerificationAlert: $showReducedVerificationAlert,
            showCriticalHealthAlert: $showCriticalHealthAlert,
            showDownloadFailedAlert: $showDownloadFailedAlert,
            selectedTab: $selectedTab,
            showCypherpunkSettings: $showCypherpunkSettings,
            availableDiskSpace: availableDiskSpace,
            repairNeededReason: repairNeededReason,
            healthAlertTitle: healthAlertTitle,
            walletManager: walletManager,
            networkManager: networkManager
        ))
    }

    // MARK: - Classic Wallet View (Tab-based)

    private var classicWalletView: some View {
        VStack(spacing: 0) {
            // Menu bar
            System7MenuBar()

            // Main window
            System7Window(title: "ZipherX Wallet") {
                VStack(spacing: 16) {
                    // Tab buttons
                    HStack(spacing: 8) {
                        System7TabButton(title: "Balance", isSelected: selectedTab == .balance) {
                            selectedTab = .balance
                            recordUserActivity()
                        }
                        System7TabButton(title: "Send", isSelected: selectedTab == .send) {
                            selectedTab = .send
                            recordUserActivity()
                        }
                        System7TabButton(title: "Receive", isSelected: selectedTab == .receive) {
                            selectedTab = .receive
                            recordUserActivity()
                        }
                        System7TabButton(title: "Chat", isSelected: selectedTab == .chat) {
                            selectedTab = .chat
                            recordUserActivity()
                        }
                        System7TabButton(title: "Settings", isSelected: selectedTab == .settings) {
                            selectedTab = .settings
                            recordUserActivity()
                        }
                    }
                    .padding(.horizontal)

                    // Content
                    Group {
                        switch selectedTab {
                        case .balance:
                            BalanceView()
                        case .send:
                            SendView(onSendComplete: {
                                selectedTab = .balance
                            })
                        case .receive:
                            ReceiveView()
                        case .chat:
                            // FIX #252: Pass callback to navigate to settings when Tor is disabled
                            ChatView(onShowAppSettings: {
                                selectedTab = .settings
                            })
                        case .settings:
                            SettingsView()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        recordUserActivity()
                    }
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { _ in
                                recordUserActivity()
                            }
                    )
                }
                .padding()
            }
            .padding()
        }
    }

    // MARK: - Floating Sync Indicator

    /// Floating progress indicator shown during background sync (after initial sync)
    private var floatingSyncIndicator: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 8) {
                // Status text
                HStack {
                    ProgressView()
                        .scaleEffect(0.8)
                        #if os(macOS)
                        .controlSize(.small)
                        #endif

                    Text("Syncing blockchain...")
                        .font(themeManager.currentTheme.bodyFont)
                        .foregroundColor(themeManager.currentTheme.textPrimary)

                    Spacer()

                    // Percentage
                    Text("\(Int(walletManager.syncProgress * 100))%")
                        .font(themeManager.currentTheme.monoFont)
                        .foregroundColor(themeManager.currentTheme.primaryColor)
                }

                // Progress bar
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(themeManager.currentTheme.surfaceColor)
                            .frame(height: 8)

                        Rectangle()
                            .fill(themeManager.currentTheme.primaryColor)
                            .frame(width: geometry.size.width * walletManager.syncProgress, height: 8)
                    }
                    .cornerRadius(4)
                }
                .frame(height: 8)

                // Block height
                if walletManager.syncMaxHeight > 0 {
                    HStack {
                        Text("Block \(walletManager.syncCurrentHeight.formatted()) / \(walletManager.syncMaxHeight.formatted())")
                            .font(themeManager.currentTheme.captionFont)
                            .foregroundColor(themeManager.currentTheme.textSecondary)

                        Spacer()

                        // Blocks remaining
                        let remaining = walletManager.syncMaxHeight > walletManager.syncCurrentHeight ?
                            walletManager.syncMaxHeight - walletManager.syncCurrentHeight : 0
                        Text("\(remaining.formatted()) remaining")
                            .font(themeManager.currentTheme.captionFont)
                            .foregroundColor(themeManager.currentTheme.textSecondary)
                    }
                }
            }
            .padding(12)
            .background(themeManager.currentTheme.backgroundColor)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(themeManager.currentTheme.borderColor, lineWidth: 1)
            )
            .cornerRadius(8)
            .shadow(color: themeManager.currentTheme.shadowColor.opacity(0.3), radius: 5, x: 0, y: -2)
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
            #if os(macOS)
            .frame(maxWidth: 400)
            #endif
        }
    }

    // MARK: - FIX #144: Floating Header Sync Indicator

    /// Floating progress indicator shown during header/timestamp sync
    /// Shows block timestamps being synced for transaction history
    private var floatingHeaderSyncIndicator: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 8) {
                // Status text with icon
                HStack(spacing: 8) {
                    // Clock icon for timestamps
                    Image(systemName: "clock.fill")
                        .font(.system(size: 14))
                        .foregroundColor(themeManager.currentTheme.primaryColor)

                    Text(walletManager.headerSyncStatus.isEmpty ? "Syncing timestamps..." : walletManager.headerSyncStatus)
                        .font(themeManager.currentTheme.bodyFont)
                        .foregroundColor(themeManager.currentTheme.textPrimary)
                        .lineLimit(1)

                    Spacer()

                    // Percentage
                    Text("\(Int(walletManager.headerSyncProgress * 100))%")
                        .font(themeManager.currentTheme.monoFont)
                        .foregroundColor(themeManager.currentTheme.primaryColor)
                }

                // Progress bar
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(themeManager.currentTheme.surfaceColor)
                            .frame(height: 8)

                        Rectangle()
                            .fill(themeManager.currentTheme.primaryColor)
                            .frame(width: geometry.size.width * walletManager.headerSyncProgress, height: 8)
                    }
                    .cornerRadius(4)
                }
                .frame(height: 8)

                // Block height info
                if walletManager.headerSyncTargetHeight > 0 {
                    HStack {
                        Text("Block \(walletManager.headerSyncCurrentHeight.formatted()) / \(walletManager.headerSyncTargetHeight.formatted())")
                            .font(themeManager.currentTheme.captionFont)
                            .foregroundColor(themeManager.currentTheme.textSecondary)

                        Spacer()

                        // Blocks remaining
                        let remaining = walletManager.headerSyncTargetHeight > walletManager.headerSyncCurrentHeight ?
                            walletManager.headerSyncTargetHeight - walletManager.headerSyncCurrentHeight : 0
                        Text("\(remaining.formatted()) remaining")
                            .font(themeManager.currentTheme.captionFont)
                            .foregroundColor(themeManager.currentTheme.textSecondary)
                    }
                }

                // Tor bypass indicator
                if walletManager.isTorBypassed {
                    HStack(spacing: 4) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.orange)
                        Text("Direct connection (faster sync)")
                            .font(themeManager.currentTheme.captionFont)
                            .foregroundColor(.orange)
                        Spacer()
                    }
                }
            }
            .padding(12)
            .background(themeManager.currentTheme.backgroundColor)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(themeManager.currentTheme.primaryColor.opacity(0.5), lineWidth: 1)
            )
            .cornerRadius(8)
            .shadow(color: themeManager.currentTheme.shadowColor.opacity(0.3), radius: 5, x: 0, y: -2)
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
            #if os(macOS)
            .frame(maxWidth: 400)
            #endif
        }
    }

    // MARK: - FIX #242: Floating Catch-Up Indicator

    /// Floating progress indicator shown when wallet is catching up after returning from background
    /// Displays in ORANGE to distinguish from regular sync
    private var floatingCatchUpIndicator: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 8) {
                // Status text with warning icon
                HStack(spacing: 8) {
                    // Spinning sync icon
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 14))
                        .foregroundColor(.orange)
                        .rotationEffect(.degrees(walletManager.isCatchingUp ? 360 : 0))
                        .animation(walletManager.isCatchingUp ? .linear(duration: 1.0).repeatForever(autoreverses: false) : .default, value: walletManager.isCatchingUp)

                    Text("Syncing...")
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundColor(.orange)

                    Spacer()

                    // Blocks behind count
                    if walletManager.blocksBehind > 0 {
                        Text("\(walletManager.blocksBehind) blocks behind")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.orange)
                    }
                }

                // Progress bar in orange
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(Color.orange.opacity(0.2))
                            .frame(height: 6)

                        // Animated indeterminate progress
                        Rectangle()
                            .fill(Color.orange)
                            .frame(width: geometry.size.width * 0.3, height: 6)
                            .offset(x: walletManager.isCatchingUp ? geometry.size.width * 0.7 : 0)
                            .animation(walletManager.isCatchingUp ? .easeInOut(duration: 1.0).repeatForever(autoreverses: true) : .default, value: walletManager.isCatchingUp)
                    }
                    .cornerRadius(3)
                }
                .frame(height: 6)

                // Warning about SEND disabled
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.orange.opacity(0.8))
                    Text("SEND disabled until sync complete")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.orange.opacity(0.8))
                    Spacer()
                }
            }
            .padding(12)
            .background(Color.black)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.orange.opacity(0.7), lineWidth: 2)
            )
            .cornerRadius(8)
            .shadow(color: Color.orange.opacity(0.3), radius: 8, x: 0, y: -2)
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
            #if os(macOS)
            .frame(maxWidth: 400)
            #endif
        }
    }
}

// MARK: - Cypherpunk Alerts Modifier (breaks up complex type-check expression)
// FIX #540: Consolidate all alerts into a single unified sheet to prevent SwiftUI warnings
struct CypherpunkAlertsModifier: ViewModifier {
    @Binding var showInsufficientDiskSpaceAlert: Bool
    @Binding var showRepairNeededAlert: Bool
    @Binding var showSybilAttackAlert: Bool
    @Binding var showExternalWalletSpendAlert: Bool
    @Binding var showReducedVerificationAlert: Bool
    @Binding var showCriticalHealthAlert: Bool
    @Binding var showDownloadFailedAlert: Bool  // FIX #888
    @Binding var selectedTab: ContentView.Tab
    @Binding var showCypherpunkSettings: Bool
    let availableDiskSpace: String
    let repairNeededReason: String
    let healthAlertTitle: String
    @ObservedObject var walletManager: WalletManager
    @ObservedObject var networkManager: NetworkManager

    // Unified alert state
    @State private var activeAlert: UnifiedAlert? = nil
    // FIX #562: Track when alert was just dismissed to prevent immediate re-presentation
    @State private var alertDismissedAt: Date? = nil

    func body(content: Content) -> some View {
        content
            .onChange(of: showInsufficientDiskSpaceAlert) { newValue in
                // FIX #562: Only show alert if not just dismissed (within 1 second)
                if newValue, alertDismissedAt == nil || Date().timeIntervalSince(alertDismissedAt!) > 1.0 {
                    activeAlert = .diskSpace
                }
            }
            .onChange(of: showRepairNeededAlert) { newValue in
                // FIX #562: Only show alert if not just dismissed (within 1 second)
                if newValue, alertDismissedAt == nil || Date().timeIntervalSince(alertDismissedAt!) > 1.0 {
                    activeAlert = .repairNeeded
                }
            }
            .onChange(of: showSybilAttackAlert) { newValue in
                // FIX #562: Only show alert if not just dismissed (within 1 second)
                if newValue, alertDismissedAt == nil || Date().timeIntervalSince(alertDismissedAt!) > 1.0 {
                    activeAlert = .sybilAttack
                }
            }
            .onChange(of: showExternalWalletSpendAlert) { newValue in
                // FIX #562: Only show alert if not just dismissed (within 1 second)
                if newValue, alertDismissedAt == nil || Date().timeIntervalSince(alertDismissedAt!) > 1.0 {
                    activeAlert = .externalSpend
                }
            }
            .onChange(of: showReducedVerificationAlert) { newValue in
                // FIX #562: Only show alert if not just dismissed (within 1 second)
                if newValue, alertDismissedAt == nil || Date().timeIntervalSince(alertDismissedAt!) > 1.0 {
                    activeAlert = .reducedVerification
                }
            }
            .onChange(of: networkManager.criticalHealthAlert != nil) { hasAlert in
                // FIX #562: Only show alert if not just dismissed (within 1 second)
                if hasAlert, alertDismissedAt == nil || Date().timeIntervalSince(alertDismissedAt!) > 1.0 {
                    activeAlert = .criticalHealth
                }
            }
            // FIX #888: Show download failed alert when boost download fails
            .onChange(of: walletManager.boostDownloadFailed) { failed in
                if failed, alertDismissedAt == nil || Date().timeIntervalSince(alertDismissedAt!) > 1.0 {
                    activeAlert = .downloadFailed
                }
            }
            .sheet(item: Binding(
                get: { activeAlert },
                set: { newValue in
                    activeAlert = newValue
                    // FIX #562: Record when alert was dismissed to prevent immediate re-presentation
                    if newValue == nil {
                        alertDismissedAt = Date()
                    }
                    // Reset all individual alert states
                    showInsufficientDiskSpaceAlert = false
                    showRepairNeededAlert = false
                    showSybilAttackAlert = false
                    showExternalWalletSpendAlert = false
                    showReducedVerificationAlert = false
                    showCriticalHealthAlert = false
                    showDownloadFailedAlert = false
                    // FIX #888: Reset download failed flag when alert dismissed
                    if walletManager.boostDownloadFailed {
                        walletManager.boostDownloadFailed = false
                    }
                }
            )) { alert in
                UnifiedAlertSheet(
                    alert: alert,
                    availableDiskSpace: availableDiskSpace,
                    repairNeededReason: repairNeededReason,
                    healthAlertTitle: healthAlertTitle,
                    selectedTab: $selectedTab,
                    showCypherpunkSettings: $showCypherpunkSettings,
                    walletManager: walletManager,
                    networkManager: networkManager
                )
            }
    }
}

// MARK: - Unified Alert Types
enum UnifiedAlert: Identifiable {
    case diskSpace
    case repairNeeded
    case sybilAttack
    case externalSpend
    case reducedVerification
    case criticalHealth
    case downloadFailed  // FIX #888

    var id: String {
        switch self {
        case .diskSpace: return "diskSpace"
        case .repairNeeded: return "repairNeeded"
        case .sybilAttack: return "sybilAttack"
        case .externalSpend: return "externalSpend"
        case .reducedVerification: return "reducedVerification"
        case .criticalHealth: return "criticalHealth"
        case .downloadFailed: return "downloadFailed"
        }
    }
}

// MARK: - Unified Alert Sheet
struct UnifiedAlertSheet: View {
    let alert: UnifiedAlert
    let availableDiskSpace: String
    let repairNeededReason: String
    let healthAlertTitle: String
    @Binding var selectedTab: ContentView.Tab
    @Binding var showCypherpunkSettings: Bool
    @ObservedObject var walletManager: WalletManager
    @ObservedObject var networkManager: NetworkManager

    var body: some View {
        switch alert {
        case .diskSpace:
            diskSpaceAlert
        case .repairNeeded:
            repairNeededAlert
        case .sybilAttack:
            sybilAttackAlert
        case .externalSpend:
            externalSpendAlert
        case .reducedVerification:
            reducedVerificationAlert
        case .criticalHealth:
            criticalHealthAlert
        case .downloadFailed:
            downloadFailedAlert
        }
    }

    private var diskSpaceAlert: some View {
        AlertWrapper(
            title: "Insufficient Disk Space",
            message: "ZipherX requires approximately 750 MB of free space to download blockchain data.\n\nAvailable: \(availableDiskSpace)\n\nPlease free up some space and restart the app.",
            primaryButton: ("OK", {})
        )
    }

    private var repairNeededAlert: some View {
        AlertWrapper(
            title: "⚠️ Database Repair Recommended",
            message: "Your wallet may show an incorrect balance.\n\n\(repairNeededReason)\n\nTo fix this:\n1. Go to Settings\n2. Tap 'Repair Database'\n3. Wait for repair to complete\n\nNote: Tor will be temporarily disabled during repair for faster scanning.\n\nSend is disabled until repair is complete to prevent errors.",
            primaryButton: ("Later", {}),
            secondaryButton: ("Open Settings", {
                selectedTab = .settings
                showCypherpunkSettings = true
            })
        )
    }

    private var sybilAttackAlert: some View {
        let alert = networkManager.sybilVersionAttackAlert
        return AlertWrapper(
            title: "🚨 Security Alert: Sybil Attack Detected",
            message: "Detected \(alert?.attackerCount ?? 0) suspicious peer(s) reporting fake blockchain data.\n\n\(alert?.bypassedTor ?? false ? "Tor has been temporarily bypassed to connect directly to trusted peers." : "Malicious peers have been banned.")\n\nYour funds are safe. The wallet is using verified peer consensus.\n\n\"Privacy is necessary for an open society in the electronic age.\"\n— A Cypherpunk's Manifesto",
            primaryButton: ("OK", {
                networkManager.clearSybilAttackAlert()
            })
        )
    }

    private var externalSpendAlert: some View {
        let spend = networkManager.externalWalletSpendDetected
        let zcl = Double(spend?.amount ?? 0) / 100_000_000.0
        return AlertWrapper(
            title: "⚠️ External Wallet Activity Detected",
            message: "Another wallet is spending your funds!\n\nAmount: \(String(format: "%.8f", zcl)) ZCL\nTxID: \((spend?.txid ?? "").prefix(16))...\n\nThis transaction was NOT initiated by ZipherX. If you did not authorize this, your private key may be compromised.\n\nSend is temporarily disabled until this transaction confirms.",
            primaryButton: ("OK", {})
        )
    }

    private var reducedVerificationAlert: some View {
        AlertWrapper(
            title: "⚠️ Reduced Verification Mode",
            message: "Insufficient peers available for full transaction verification.\n\nTransactions will still be sent but with reduced security:\n\n• Validated by fewer peers than recommended\n• Higher vulnerability to Sybil attacks\n• Consider waiting for more connections\n\nThis is normal during initial connection or on mobile networks.",
            primaryButton: ("OK", {})
        )
    }

    private var criticalHealthAlert: some View {
        AlertWrapper(
            title: healthAlertTitle.isEmpty ? "⚠️ Wallet Health Issue Detected" : healthAlertTitle,
            message: "Critical wallet health issues have been detected that may affect your balance or transaction ability.\n\nPlease check the Health section in Settings for details and recommended actions.\n\nYour funds are safe, but functionality may be limited until issues are resolved.",
            primaryButton: ("Open Settings", {
                // FIX #549: Dismiss alert when opening settings to prevent loop
                Task { @MainActor in
                    await networkManager.handleHealthAlertAction(.dismiss)
                }
                selectedTab = .settings
                showCypherpunkSettings = true
            }),
            secondaryButton: ("Dismiss", {
                // FIX #549: Properly dismiss the alert
                Task { @MainActor in
                    await networkManager.handleHealthAlertAction(.dismiss)
                }
            })
        )
    }

    // FIX #888: Download failed alert with retry option
    private var downloadFailedAlert: some View {
        AlertWrapper(
            title: "Download Failed",
            message: "Failed to download blockchain data.\n\n\(walletManager.boostDownloadError)\n\nWould you like to retry the import?",
            primaryButton: ("Retry Import", {
                Task {
                    await walletManager.retryBoostDownload()
                }
            }),
            secondaryButton: ("Cancel", {
                // Just dismiss - user can try again from Settings later
            })
        )
    }
}

// MARK: - Alert Wrapper (replaces .alert() for use in .sheet)
// FIX #674: Added @Environment(\.dismiss) to properly close sheet when buttons are clicked
struct AlertWrapper: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let message: String
    let primaryButton: (String, () -> Void)
    var secondaryButton: (String, () -> Void)? = nil

    var body: some View {
        VStack(spacing: 20) {
            Text(title)
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(.white)

            Text(message)
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.9))
                .multilineTextAlignment(.center)

            HStack(spacing: 16) {
                if let secondary = secondaryButton {
                    Button(action: {
                        secondary.1()
                        dismiss()  // FIX #674: Close sheet after action
                    }) {
                        Text(secondary.0)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.bordered)
                    .foregroundColor(.white)

                    Button(action: {
                        primaryButton.1()
                        dismiss()  // FIX #674: Close sheet after action
                    }) {
                        Text(primaryButton.0)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                } else {
                    Button(action: {
                        primaryButton.1()
                        dismiss()  // FIX #674: Close sheet after action
                    }) {
                        Text(primaryButton.0)
                            .padding(.horizontal, 30)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                }
            }
        }
        .padding(24)
        .frame(maxWidth: 400)
        .background(Color.black.opacity(0.9))
        .cornerRadius(12)
    }
}

// FIX #540: Old individual alert modifiers removed - replaced by unified alert system above

// MARK: - Health Alert Sheet View
struct HealthAlertSheet: View {
    let walletManager: WalletManager
    let networkManager: NetworkManager
    @Binding var isPresented: Bool
    @State private var isProcessing = false

    private var alert: NetworkManager.CriticalHealthAlert? {
        networkManager.criticalHealthAlert
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header with severity icon
            headerView

            Divider()

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Message
                    Text(alert?.message ?? "A health issue was detected.")
                        .font(.body)
                        .foregroundColor(.primary)
                        .fixedSize(horizontal: false, vertical: true)

                    // Reassurance
                    reassuranceView
                }
                .padding()
            }

            Divider()

            // Action buttons
            actionButtonsView
        }
        #if os(iOS)
        .background(Color(UIColor.systemBackground))
        #else
        .background(Color(NSColor.windowBackgroundColor))
        #endif
        #if os(macOS)
        .frame(minWidth: 400, minHeight: 350)
        #endif
    }

    private var headerView: some View {
        VStack(spacing: 8) {
            // Severity icon
            Text(alert?.severity.rawValue ?? "⚠️")
                .font(.system(size: 50))

            // Title
            Text(alert?.title ?? "Health Issue")
                .font(.title2)
                .fontWeight(.bold)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(alert?.severity == .critical ? Color.red.opacity(0.1) : Color.orange.opacity(0.1))
    }

    private var reassuranceView: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.shield.fill")
                .font(.title2)
                .foregroundColor(.green)

            VStack(alignment: .leading, spacing: 4) {
                Text("Your funds are safe")
                    .font(.headline)
                    .foregroundColor(.primary)
                Text("This is a sync issue, not a security problem.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.green.opacity(0.1))
        .cornerRadius(12)
    }

    private var actionButtonsView: some View {
        VStack(spacing: 12) {
            // Primary action button
            if let primarySolution = alert?.solutions.first(where: { $0.action != .dismiss }) {
                Button(action: {
                    handleAction(primarySolution.action)
                }) {
                    HStack {
                        if isProcessing {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .scaleEffect(0.8)
                        }
                        Text(primarySolution.title)
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(12)
                }
                .disabled(isProcessing)
            }

            // Dismiss button
            Button(action: {
                Task {
                    await networkManager.handleHealthAlertAction(.dismiss)
                    // FIX #667: Only dismiss after handleHealthAlertAction completes
                    // This prevents race condition where onChange re-presents alert
                    isPresented = false
                }
            }) {
                Text("Remind Me Later")
                    .foregroundColor(.secondary)
            }
            .disabled(isProcessing)
        }
        .padding()
    }

    private func handleAction(_ action: NetworkManager.CriticalHealthAlert.Solution.ActionType) {
        isProcessing = true
        Task {
            switch action {
            case .clearHeaders:
                await networkManager.handleHealthAlertAction(.clearHeaders)
            case .syncHeaders:
                // FIX #411: Sync headers instead of clearing
                await networkManager.handleHealthAlertAction(.syncHeaders)
            case .repairDatabase:
                try? await walletManager.repairNotesAfterDownloadedTree(onProgress: { _, _, _ in })
            case .reconnectPeers:
                await networkManager.handleHealthAlertAction(.reconnectPeers)
            case .dismiss:
                break
            }
            await MainActor.run {
                isProcessing = false
                isPresented = false
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(WalletManager.shared)
        .environmentObject(NetworkManager.shared)
        .environmentObject(ThemeManager.shared)
}
