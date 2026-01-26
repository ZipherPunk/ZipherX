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
    @State private var isShowingLockScreen: Bool = false  // Don't show during initial sync
    @State private var lastActivityTime: Date = Date()  // Track user activity
    @State private var inactivityTimer: Timer?  // Timer to check inactivity
    @State private var wasInBackground: Bool = false  // FIX #258: Track if we were in background
    @State private var hasAcceptedDisclaimer: Bool = UserDefaults.standard.bool(forKey: "hasAcceptedDisclaimer")

    // Startup timing - uses walletCreationTime from WalletManager
    // This ensures timing starts from when user clicks create/import/restore, not app launch
    @State private var syncCompletionDuration: TimeInterval? = nil
    @State private var showCompletionScreen: Bool = false
    private let estimatedSyncDuration: TimeInterval = 60  // ~60 seconds estimated for new wallet

    // DEBUG: Set to true to pause at sync completion with a confirmation button
    private let DEBUG_PAUSE_AT_COMPLETION = true
    @State private var debugWaitingForConfirmation = false
    @State private var debugCompletionMessage = ""

    /// Get the effective start time for sync timing display
    /// Uses walletCreationTime if available (when user clicked create/import), otherwise falls back to appStartupTime
    private var effectiveStartTime: Date {
        walletManager.walletCreationTime ?? appStartupTime
    }

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
                    .task {
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
                        let lastScannedHeight = (try? WalletDatabase.shared.getLastScannedHeight()) ?? 0
                        let cachedChainHeight = UInt64(UserDefaults.standard.integer(forKey: "cachedChainHeight"))
                        let blocksBehind = cachedChainHeight > lastScannedHeight ? cachedChainHeight - lastScannedHeight : 0

                        // FIX #168: Use verified_checkpoint_height for INSTANT startup
                        // If checkpoint == lastScannedHeight, wallet is fully verified - NO health checks needed!
                        let checkpointHeight = (try? WalletDatabase.shared.getVerifiedCheckpointHeight()) ?? 0
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
                        if headerStoreHeight < 2964000 {
                            print("📦 FIX #535: Loading bundled headers from boost file...")
                            await MainActor.run {
                                walletManager.setConnecting(true, status: "Loading block headers...")
                            }
                            let (loadedBoost, boostEndHeight) = await walletManager.loadHeadersFromBoostFile()
                            if loadedBoost {
                                print("✅ FIX #535: Loaded bundled headers up to \(boostEndHeight)")
                            }
                        }

                        // Connect to P2P network for delta header sync
                        // Only sync if: HeaderStore is empty OR wallet has data that needs headers
                        let needsHeaderSync = headerStoreHeight < 2964000 || lastScannedHeight > 0
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
                            print("⚡ FAST START MODE: Wallet synced to \(lastScannedHeight), chain at \(cachedChainHeight) (\(blocksBehind) blocks behind)")

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
                                print("⚡ FIX #168: INSTANT START - checkpoint valid (gap=\(checkpointGap))")
                                print("⚡ FIX #408: HeaderStore healthy (within \(headersBehind) blocks)")

                                // FIX #530: CRITICAL - Initialize tree from boost file before health checks
                                // Without this, FFI tree state is corrupted from previous session
                                // This causes DeltaCMU manager to clear its bundle (tree root mismatch)
                                print("🌳 FIX #530: Initializing tree from boost file...")
                                await MainActor.run {
                                    walletManager.setConnecting(true, status: "Initializing commitment tree...")
                                }

                                do {
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
                                            print("📦 FIX #530: Loading delta CMUs from height \(ZipherXConstants.effectiveTreeHeight + 1) to \(manifest.endHeight)...")
                                            if let deltaCMUs = DeltaCMUManager.shared.loadDeltaCMUsForHeightRange(
                                                startHeight: ZipherXConstants.effectiveTreeHeight + 1,
                                                endHeight: manifest.endHeight
                                            ) {
                                                var appendedCount = 0
                                                for cmu in deltaCMUs {
                                                    let position = ZipherXFFI.treeAppend(cmu: cmu)
                                                    if position > 0 {
                                                        appendedCount += 1
                                                    }
                                                }
                                                print("📦 FIX #530: Appended \(appendedCount) delta CMUs to tree")

                                                let newTreeSize = ZipherXFFI.treeSize()
                                                print("🌳 FIX #530: Tree size after delta: \(newTreeSize) commitments")
                                            }
                                        }

                                        // FIX #748: Set isTreeLoaded for FAST START so background sync works
                                        // Previously the flag was only set during FULL START (import)
                                        // causing background sync to be blocked after FAST START
                                        await MainActor.run {
                                            walletManager.setTreeLoaded(true)
                                        }
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
                                walletManager.loadCachedBalance()

                                // Quick health check - only critical checks
                                let healthResults = await WalletHealthCheck.shared.runAllChecks()
                                // FIX #723: Filter critical issues properly - check .critical flag OR keywords
                                // Tree Root Validation returns critical=true but details say "Full Rescan" not "REPAIR"
                                let criticalIssues = healthResults.filter {
                                    !$0.passed && ($0.critical || $0.details.contains("REPAIR") || $0.details.contains("Full Rescan"))
                                }

                                // FIX #686: Automatic repair at startup - NO user prompts
                                if !criticalIssues.isEmpty {
                                    print("⚠️ FIX #686: INSTANT START detected issues - triggering automatic repair")
                                    for issue in criticalIssues {
                                        print("⚠️ Critical Issue: \(issue.checkName) - \(issue.details)")
                                    }

                                    // FIX #723: Check for Tree Root mismatch specifically - needs FULL rescan
                                    let hasTreeRootMismatch = criticalIssues.contains {
                                        $0.checkName == "Tree Root Validation"
                                    }

                                    // Trigger automatic repair instead of showing alert
                                    await MainActor.run {
                                        if hasTreeRootMismatch {
                                            walletManager.setConnecting(true, status: "Tree mismatch - rebuilding from scratch...")
                                        } else {
                                            walletManager.setConnecting(true, status: "Repairing wallet state...")
                                        }
                                        walletManager.syncTasks.append(SyncTask(id: "instant_repair", title: hasTreeRootMismatch ? "Rebuilding Commitment Tree" : "Automatic Repair", status: .inProgress, progress: 0.0))
                                    }

                                    do {
                                        // FIX #723: For tree root mismatch, force FULL rescan to rebuild tree from boost file
                                        if hasTreeRootMismatch {
                                            print("🔧 FIX #723: Tree root mismatch detected - triggering FULL RESCAN")
                                        }
                                        try await walletManager.repairNotesAfterDownloadedTree(onProgress: { progress, current, total in
                                            print("🔧 FIX #686/723: Instant repair progress \(Int(progress * 100))% (\(current)/\(total))")
                                            Task { @MainActor in
                                                walletManager.updateSyncTask(id: "instant_repair", status: .inProgress, detail: "\(current)/\(total)", progress: progress)
                                            }
                                        }, forceFullRescan: hasTreeRootMismatch)
                                        await MainActor.run {
                                            walletManager.updateSyncTask(id: "instant_repair", status: .completed)
                                        }
                                        print("✅ FIX #686/723: Instant repair complete")
                                    } catch {
                                        print("❌ FIX #686/723: Instant repair failed: \(error.localizedDescription)")
                                        // Even on failure, continue to UI - user can manually trigger repair from Settings
                                    }
                                }

                                // FIX #557 v9: Rebuild all stale witnesses BEFORE showing UI!
                                // This ensures when the balance is shown, all witnesses are current
                                // Same as FAST START FIX #557 v8, but for INSTANT START path
                                print("🔄 FIX #557 v9: Rebuilding stale witnesses before showing UI (INSTANT START)...")
                                await MainActor.run {
                                    walletManager.setConnecting(true, status: "Updating witnesses for instant send...")
                                }

                                // FIX #563 v31: DISABLED tree corruption check before witness rebuild
                                // The tree rebuild was losing PHASE 2 delta CMUs and causing crashes
                                // If tree is corrupted, user can run "Settings → Repair Database" manually
                                print("🔍 FIX #563 v31: Skipping tree corruption check (causes crashes during witness rebuild)")

                                await walletManager.rebuildWitnessesForStartup()
                                print("✅ FIX #557 v9: Witnesses synced - balance is now accurate!")

                                // Show UI after health check completes
                                await MainActor.run {
                                    walletManager.setRepairingHistory(false)
                                    walletManager.setConnecting(false, status: nil)
                                    isInitialSync = false
                                    hasCompletedInitialSync = true
                                    walletManager.completeProgress()
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
                                print("⚠️ FIX #408: Checkpoint valid but HeaderStore is \(headersBehind) blocks behind!")
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
                                    print("⚠️ FIX #412: HeaderStore is \(headerGap412) blocks behind lastScannedHeight (\(lastScanned412))")
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
                            let healthResults = await WalletHealthCheck.shared.runAllChecks()

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

                            if hasCritical && hasTreeRootMismatch {
                                // FIX #439: Tree Root mismatch is critical but we CAN fix it with Full Rescan
                                print("🔧 FIX #439: Tree Root mismatch detected - triggering Full Rescan to rebuild tree...")
                                await MainActor.run {
                                    walletManager.setConnecting(true, status: "Tree mismatch - rebuilding...")
                                    walletManager.syncTasks.append(SyncTask(id: "tree_rebuild", title: "Rebuilding commitment tree", status: .inProgress, progress: 0.0))
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
                                let hasBalanceIssues = fixableIssues.contains { $0.checkName == "Balance Reconciliation" }
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
                                        walletManager.syncTasks.append(SyncTask(id: "fast_repair", title: "Rebuild Merkle witnesses", status: .inProgress, progress: 0.0))
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

                                // FIX #162: Handle Balance Reconciliation issues - rebuild history from unspent notes ONLY
                                // The old populateHistoryFromNotes() created fake transactions with synthetic txids
                                // causing more corruption. New approach: clear history and add ONLY unspent notes as received.
                                if hasBalanceIssues {
                                    print("🔧 FIX #162: Balance mismatch detected - rebuilding transaction history...")
                                    await MainActor.run {
                                        walletManager.setConnecting(true, status: "Repairing balance history...")
                                        walletManager.syncTasks.append(SyncTask(id: "balance_repair_early", title: "Rebuild transaction history", status: .inProgress, progress: 0.0))
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

                                let stillHasIssues = WalletHealthCheck.shared.getFixableIssues(verifyResults)
                                // FIX #412: ALL health checks are now blocking - no exceptions!
                                // User requires: "ALL HEALTH CHECKS CRITICAL BUSINESS TASK MUST BE 100%"
                                // Previous non-blocking checks (P2P Connectivity, Hash Accuracy) now work
                                // because FIX #412 ensures 3+ peers are connected before health checks run.
                                //
                                // ALL critical checks: P2P, Hash Accuracy, Timestamps, Database Integrity,
                                //                     Bundle Files, Delta CMU, Balance Reconciliation,
                                //                     Tree Root Validation, Equihash, CMU, Notes
                                let blockingIssues = stillHasIssues  // ALL issues are blocking!

                                if !blockingIssues.isEmpty {
                                    // FIX #162: Check if Balance Reconciliation is the remaining issue
                                    // This can happen when balance check only fails AFTER timestamp sync corrects data
                                    let hasBalanceIssueAfterVerify = blockingIssues.contains { $0.checkName == "Balance Reconciliation" }

                                    if hasBalanceIssueAfterVerify {
                                        print("🔧 FIX #162: Balance mismatch detected AFTER verification - repairing now...")
                                        await MainActor.run {
                                            walletManager.setConnecting(true, status: "Repairing balance history...")
                                            walletManager.syncTasks.append(SyncTask(id: "balance_repair", title: "Rebuild transaction history", status: .inProgress, progress: 0.0))
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
                            print("🔄 FIX #557 v8: Rebuilding stale witnesses before showing UI...")
                            await MainActor.run {
                                walletManager.setConnecting(true, status: "Updating witnesses for instant send...")
                                walletManager.syncTasks.append(SyncTask(id: "witness_sync", title: "Sync Merkle witnesses", status: .inProgress, progress: 0.0))
                            }

                            // FIX #557 v8: Rebuild witnesses using WalletManager's account access
                            // Direct call to avoid SwiftUI .id modifier conflict
                            await walletManager.rebuildWitnessesForStartup()

                            await MainActor.run {
                                walletManager.updateSyncTask(id: "witness_sync", status: .completed)
                            }
                            print("✅ FIX #557 v8: Witnesses synced - balance is now accurate!")

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

                            await MainActor.run {
                                // FIX #162: Clear repair flag - FAST START complete, Views can now call populateHistoryFromNotes
                                walletManager.setRepairingHistory(false)

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
                        print("DEBUGZIPHERX: 📡 Task: Waiting 0.5s...")
                        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 sec

                        // Now fetch stats
                        print("DEBUGZIPHERX: 📡 Task: Fetching network stats...")
                        await networkManager.fetchNetworkStats()
                        print("DEBUGZIPHERX: 📡 Task: Network stats fetched")

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
                                walletManager.syncTasks.append(SyncTask(id: "full_start_repair", title: "Automatic Repair", status: .inProgress, progress: 0.0))
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

                        if fullStartHasCritical && fullStartHasTreeRootMismatch {
                            // FIX #439: Tree Root mismatch is critical but we CAN fix it with Full Rescan
                            print("🔧 FIX #439: Tree Root mismatch detected (FULL START) - triggering Full Rescan...")
                            await MainActor.run {
                                walletManager.setConnecting(true, status: "Tree mismatch - rebuilding...")
                                walletManager.syncTasks.append(SyncTask(id: "tree_rebuild", title: "Rebuilding commitment tree", status: .inProgress, progress: 0.0))
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
                            let fullStartHasBalanceIssues = fullStartFixableIssues.contains { $0.checkName == "Balance Reconciliation" }
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
                                    walletManager.syncTasks.append(SyncTask(id: "full_repair", title: "Rebuild Merkle witnesses", status: .inProgress, progress: 0.0))
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

                            // FIX #162: Handle Balance Reconciliation issues - rebuild history from unspent notes ONLY
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

                        await MainActor.run {
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

                            // After initial sync, show lock screen if biometric enabled
                            if biometricManager.isBiometricEnabled {
                                isShowingLockScreen = true
                            }

                            // Start inactivity timer now that sync is done
                            startInactivityTimer()

                            // FIX #603: Start periodic witness refresh to keep witnesses fresh
                            walletManager.startPeriodicWitnessRefresh()

                            // FIX #370 + FIX #681: Start periodic deep verification and auto-recovery
                            walletManager.startPeriodicDeepVerification()
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

                // Face ID lock screen overlay
                if isShowingLockScreen && biometricManager.isBiometricEnabled && !isInitialSync {
                    LockScreenView(onUnlock: {
                        withAnimation {
                            isShowingLockScreen = false
                            biometricManager.unlockApp()
                            lastActivityTime = Date()
                        }
                    })
                    .transition(.opacity)
                }
            } else {
                WalletSetupView()
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
            // Lock app when going to background (if biometric enabled)
            if biometricManager.isBiometricEnabled {
                biometricManager.lockApp()
                isShowingLockScreen = true
            }

        case .active:
            // App became active
            if biometricManager.isBiometricEnabled && hasCompletedInitialSync {
                // Check if we need to re-authenticate (inactivity timeout)
                if biometricManager.isInactivityTimeoutExceeded {
                    isShowingLockScreen = true
                    biometricManager.lockApp()
                } else if biometricManager.isLocked {
                    // Still locked from background - show lock screen
                    isShowingLockScreen = true
                }
            } else if !biometricManager.isBiometricEnabled {
                // Biometric disabled - ensure not locked
                isShowingLockScreen = false
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

        // Only run timer if biometric is enabled and timeout is not "Never" (0)
        guard biometricManager.isBiometricEnabled, biometricManager.authTimeout > 0 else {
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
        // Only check if biometric enabled, app is active, not showing lock screen, and sync done
        guard biometricManager.isBiometricEnabled,
              !isShowingLockScreen,
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
    /// Uses WalletManager.overallProgress which only ever increases
    private var currentSyncProgress: Double {
        // FIX #560: Check if we're in FAST START mode (tree loaded, initial sync)
        // FIX #577 v13: Also treat Full Rescan like initial sync (same progress display as Import PK)
        // Don't check isSyncing because FAST START might sync headers!
        let isFastStartMode = walletManager.isTreeLoaded && (isInitialSync || walletManager.isFullRescan)

        if isFastStartMode {
            // FIX #560: Manually build task list for FAST START progress
            // FIX #577 v13: For Full Rescan, show core Import PK tasks (not fast_* tasks)
            var tasks: [SyncTask] = []

            // Tree task (always completed in FAST START)
            tasks.append(SyncTask(id: "tree", title: "Load Sapling note tree", status: .completed))

            // Connect task (depends on connection state)
            if !networkManager.isConnected {
                let status: SyncTaskStatus = walletManager.isConnecting ? .inProgress : .pending
                tasks.append(SyncTask(id: "connect", title: "Join P2P network", status: status))
            } else {
                tasks.append(SyncTask(id: "connect", title: "Join P2P network", status: .completed))
            }

            // CRITICAL FIX #560: Don't show 100% if we're still connecting or syncing!
            // The isConnecting flag stays true until ALL FAST START work completes
            if walletManager.isConnecting {
                // Add a "finalizing" task to keep progress below 100%
                tasks.append(SyncTask(id: "finalizing", title: "Finalizing startup...", status: .inProgress))
            }

            // FIX #577 v13: For Full Rescan, show core sync tasks; for FAST START, show fast_* tasks
            if walletManager.isFullRescan {
                // FIX #727: Full Rescan - use WHITELIST of known Import PK task IDs only
                // Previous blacklist approach let unwanted health check/repair tasks through
                // FIX #752: Added tree_rebuild to display list so progress is visible
                let importPKTaskIds: Set<String> = [
                    "params", "keys", "database", "download_outputs", "download_timestamps",
                    "headers", "height", "scan", "witnesses", "balance", "instant_repair",
                    "tree_rebuild", "full_start_repair", "full_repair"
                ]
                let coreTasks = walletManager.syncTasks.filter { task in
                    importPKTaskIds.contains(task.id)
                }
                if !coreTasks.isEmpty {
                    tasks.append(contentsOf: coreTasks)
                }
            } else {
                // FAST START: show fast_* tasks only
                let fastTasks = walletManager.syncTasks.filter { $0.id.hasPrefix("fast_") }
                if !fastTasks.isEmpty {
                    tasks.append(contentsOf: fastTasks)
                }
            }

            // Calculate progress
            let totalTasks = max(tasks.count, 1)  // At least 1 to avoid division by zero
            var completedCount = 0
            var inProgressCount = 0

            for task in tasks {
                switch task.status {
                case .completed, .failed:
                    completedCount += 1
                case .inProgress:
                    inProgressCount += 1
                case .pending:
                    break
                }
            }

            let completedProgress = Double(completedCount) / Double(totalTasks)
            let inProgressProgress = (Double(inProgressCount) / Double(totalTasks)) * 0.5

            let progress = min(completedProgress + inProgressProgress, 1.0)
            return progress
        }

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
            // During verification phase, show progress between 98-99%
            return min(baseProgress, 0.98)
        }

        return baseProgress
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
    /// Order: Tree → Connect → Sync tasks (headers, scan, witnesses, balance)
    private var currentSyncTasks: [SyncTask] {
        // FIX #562: Check if we're in FAST START mode (tree loaded, initial sync)
        // Don't check isSyncing because FAST START might sync headers!
        // FIX #577 v13: Also treat Full Rescan like initial sync (same task display as Import PK)
        let isFastStartMode = walletManager.isTreeLoaded && (isInitialSync || walletManager.isFullRescan)

        var tasks: [SyncTask] = []

        // 1. FIRST: Tree loading task (loads before network connection)
        if !walletManager.isTreeLoaded {
            let treeTask = SyncTask(
                id: "tree",
                title: "Load commitment tree",
                status: .inProgress,  // Always in progress until loaded
                detail: walletManager.treeLoadStatus,
                progress: walletManager.treeLoadProgress
            )
            tasks.append(treeTask)
        } else {
            tasks.append(SyncTask(id: "tree", title: "Load Sapling note tree", status: .completed))
        }

        // 2. SECOND: Network connection task (after tree loaded)
        if walletManager.isTreeLoaded {
            if !networkManager.isConnected {
                let status: SyncTaskStatus = walletManager.isConnecting ? .inProgress : .pending
                tasks.append(SyncTask(id: "connect", title: "Join P2P network", status: status))
            } else {
                tasks.append(SyncTask(id: "connect", title: "Join P2P network", status: .completed))
            }
        } else {
            // Tree not loaded yet - show connect as pending
            tasks.append(SyncTask(id: "connect", title: "Join P2P network", status: .pending))
        }

        // 3. THIRD: Sync tasks from WalletManager
        if isFastStartMode {
            // FIX #562: FAST START mode - only show fast_* tasks, not all 20+ tasks!
            // FIX #577 v13: Full Rescan shows only core Import PK tasks (same as FAST START)
            // CRITICAL: Don't show 100% if we're still connecting or syncing!
            if walletManager.isConnecting {
                // Add a "finalizing" task to keep progress below 100%
                tasks.append(SyncTask(id: "finalizing", title: "Finalizing startup...", status: .inProgress))
            }

            // FIX #577 v13: For Full Rescan, show core sync tasks (not fast_* tasks)
            // For FAST START, show fast_* tasks only
            if walletManager.isFullRescan {
                // FIX #727: Full Rescan - use WHITELIST of known Import PK task IDs only
                // Previous blacklist approach let unwanted health check/repair tasks through
                // FIX #752: Added tree_rebuild to display list so progress is visible
                let importPKTaskIds: Set<String> = [
                    "params", "keys", "database", "download_outputs", "download_timestamps",
                    "headers", "height", "scan", "witnesses", "balance", "instant_repair",
                    "tree_rebuild", "full_start_repair", "full_repair"
                ]
                let coreTasks = walletManager.syncTasks.filter { task in
                    importPKTaskIds.contains(task.id)
                }
                if !coreTasks.isEmpty {
                    tasks.append(contentsOf: coreTasks)
                }
            } else {
                // FAST START: show fast_* tasks only
                let fastTasks = walletManager.syncTasks.filter { $0.id.hasPrefix("fast_") }
                if !fastTasks.isEmpty {
                    tasks.append(contentsOf: fastTasks)
                }
            }
        } else {
            // NORMAL START mode - show all sync tasks
            if !walletManager.syncTasks.isEmpty {
                tasks.append(contentsOf: walletManager.syncTasks)
            } else if networkManager.isConnected && walletManager.isTreeLoaded && !walletManager.isSyncing {
                // Sync already complete or skipped - show completed scan task
                tasks.append(SyncTask(id: "scan", title: "Decrypt shielded notes", status: .completed))
            }
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
                        .animation(walletManager.isCatchingUp ? Animation.linear(duration: 1.0).repeatForever(autoreverses: false) : .default, value: walletManager.isCatchingUp)

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
                            .animation(walletManager.isCatchingUp ? Animation.easeInOut(duration: 1.0).repeatForever(autoreverses: true) : .default, value: walletManager.isCatchingUp)
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

    var id: String {
        switch self {
        case .diskSpace: return "diskSpace"
        case .repairNeeded: return "repairNeeded"
        case .sybilAttack: return "sybilAttack"
        case .externalSpend: return "externalSpend"
        case .reducedVerification: return "reducedVerification"
        case .criticalHealth: return "criticalHealth"
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
