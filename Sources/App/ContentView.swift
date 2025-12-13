import SwiftUI

struct ContentView: View {
    @EnvironmentObject var walletManager: WalletManager
    @EnvironmentObject var networkManager: NetworkManager
    @EnvironmentObject var themeManager: ThemeManager
    @StateObject private var biometricManager = BiometricAuthManager.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab: Tab = .balance
    @State private var isFirstLaunch: Bool = false
    @State private var isInitialSync: Bool = true  // Track initial sync state
    @State private var hasCompletedInitialSync: Bool = false  // Prevent re-running
    @State private var isShowingLockScreen: Bool = false  // Don't show during initial sync
    @State private var lastActivityTime: Date = Date()  // Track user activity
    @State private var inactivityTimer: Timer?  // Timer to check inactivity

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

    enum Tab {
        case balance, send, receive, chat, settings
    }

    var body: some View {
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

                        // Fast start if: already synced (within 50 blocks) AND has cached data AND cache is not stale
                        let isFastStart = lastScannedHeight > 0 && cachedChainHeight > 0 && blocksBehind <= 50 && !cacheIsStale

                        if isFastStart {
                            print("⚡ FAST START MODE: Wallet synced to \(lastScannedHeight), chain at \(cachedChainHeight) (\(blocksBehind) blocks behind)")

                            // ================================================================
                            // FIX #168: CHECKPOINT-BASED INSTANT START
                            // If checkpoint is valid (within 10 blocks of lastScanned), wallet
                            // state is fully verified - skip ALL blocking operations!
                            // ================================================================
                            if isCheckpointValid {
                                print("⚡ FIX #168: INSTANT START - checkpoint valid (gap=\(checkpointGap))")
                                print("⚡ FIX #168: Skipping peer wait, header sync, and health checks!")

                                // Load cached balance immediately
                                walletManager.loadCachedBalance()

                                // Show UI INSTANTLY - no tasks, no waiting
                                await MainActor.run {
                                    walletManager.setRepairingHistory(false)
                                    walletManager.setConnecting(false, status: nil)
                                    isInitialSync = false
                                    hasCompletedInitialSync = true
                                    walletManager.completeProgress()
                                }

                                print("⚡ FIX #168: INSTANT START COMPLETE in <1 second!")

                                // Start network and background sync asynchronously (non-blocking)
                                Task {
                                    do {
                                        try await networkManager.connect()
                                        networkManager.enableBackgroundProcesses()
                                        await networkManager.fetchNetworkStats()
                                    } catch {
                                        print("⚠️ FIX #168: Background connect error: \(error.localizedDescription)")
                                        networkManager.enableBackgroundProcesses()
                                    }
                                }
                                return  // EXIT - UI is now showing!
                            }

                            // ================================================================
                            // REGULAR FAST START (checkpoint gap > 10 blocks)
                            // Need to verify wallet state before showing UI
                            // ================================================================
                            print("📍 FIX #168: Checkpoint gap >\(checkpointGap) - running verification...")

                            // FIX #162: Set flag to prevent Views from calling populateHistoryFromNotes()
                            // during FAST START - it would undo any repairs we make
                            walletManager.setRepairingHistory(true)

                            // Initialize FAST START tasks for UI display
                            // Note: Use unique IDs (fast_*) to avoid conflict with currentSyncTasks computed property
                            // which adds its own "tree" and "connect" tasks
                            await MainActor.run {
                                walletManager.syncTasks = [
                                    SyncTask(id: "fast_balance", title: "Retrieve cached balance", status: .inProgress),
                                    SyncTask(id: "fast_peers", title: "Verify peer consensus", status: .pending),
                                    SyncTask(id: "fast_headers", title: "Sync block timestamps", status: .pending),
                                    SyncTask(id: "fast_health", title: "Validate wallet health", status: .pending)
                                ]
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
                            let needsHeaderSync = earliestNeedingTimestamp != nil

                            if needsHeaderSync {
                                print("⚠️ FIX #147: Transactions need timestamps - running header sync BEFORE showing UI")
                                print("⚠️ FIX #147: Earliest height needing timestamp: \(earliestNeedingTimestamp ?? 0)")

                                // Connect to network first (needed for header sync)
                                await MainActor.run {
                                    walletManager.setConnecting(true, status: "Connecting for header sync...")
                                }

                                do {
                                    try await networkManager.connect()

                                    // Wait for at least 3 peers (required for header consensus)
                                    var peerWait = 0
                                    let maxPeerWait = 300 // 30 seconds max
                                    while networkManager.connectedPeers < 3 && peerWait < maxPeerWait {
                                        try await Task.sleep(nanoseconds: 100_000_000) // 100ms
                                        peerWait += 1
                                        // FIX #154: Update task progress every 100ms
                                        let peerProgress = min(Double(networkManager.connectedPeers) / 3.0, 1.0)
                                        await MainActor.run {
                                            walletManager.updateSyncTask(id: "fast_peers", status: .inProgress, detail: "\(networkManager.connectedPeers)/3 peers", progress: peerProgress)
                                        }
                                    }

                                    // Update task: peers connected
                                    await MainActor.run {
                                        walletManager.updateSyncTask(id: "fast_peers", status: .completed)
                                        walletManager.updateSyncTask(id: "fast_headers", status: .inProgress)
                                    }

                                    // Run header sync WITH progress visible to user
                                    // This uses the floatingHeaderSyncIndicator in ContentView
                                    await walletManager.ensureHeaderTimestamps()

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

                                // FIX #120/FIX #167: Connect in background - DON'T block FAST START
                                // Health checks work without peers (just report "partial" for P2P check)
                                // User gets instant access to wallet, network connects asynchronously
                                await MainActor.run {
                                    walletManager.updateSyncTask(id: "fast_peers", status: .inProgress, detail: "Background connect...")
                                }

                                // FIX #167: Start connection in background - don't wait
                                Task {
                                    do {
                                        try await networkManager.connect()
                                        print("✅ FIX #167: Background network connection started")
                                    } catch {
                                        print("⚠️ FIX #167: Background connection failed: \(error.localizedDescription)")
                                    }
                                }

                                // FIX #167: Brief 2-second wait for any fast peers, then proceed
                                var peerWait = 0
                                let maxPeerWait = 20 // Only 2 seconds max (was 30 seconds!)
                                while networkManager.connectedPeers < 1 && peerWait < maxPeerWait {
                                    try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                                    peerWait += 1
                                }

                                print("✅ FIX #167: FAST START proceeding with \(networkManager.connectedPeers) peers (waited \(peerWait * 100)ms)")

                                await MainActor.run {
                                    walletManager.updateSyncTask(id: "fast_peers", status: .completed, detail: "\(networkManager.connectedPeers) peers")
                                    walletManager.updateSyncTask(id: "fast_headers", status: .completed)
                                }
                            }

                            // FIX #167: INSTANT FAST START - Show UI immediately, health checks in background
                            // User gets instant wallet access with cached balance
                            // Health checks run asynchronously and notify only if critical issues found
                            await MainActor.run {
                                walletManager.updateSyncTask(id: "fast_health", status: .completed, detail: "Background check")
                            }

                            // FIX #167: SKIP blocking health checks entirely for instant startup
                            // Health checks will run in background after UI is shown
                            // Critical issues will show an alert, but user can still see their balance
                            let skipBlockingHealthChecks = true  // FIX #167: Enable instant startup

                            if skipBlockingHealthChecks {
                                print("⚡ FIX #167: INSTANT FAST START - skipping blocking health checks")
                                print("⚡ Health checks will run in background after UI is shown")

                                // Mark initial sync as complete NOW - show UI immediately!
                                print("⚡ FAST START COMPLETE: UI ready! (health checks in background)")

                                await MainActor.run {
                                    walletManager.setRepairingHistory(false)
                                    walletManager.setConnecting(false, status: nil)
                                    isInitialSync = false
                                    hasCompletedInitialSync = true
                                    walletManager.completeProgress()
                                }

                                // FIX #167: Run health checks in BACKGROUND Task (non-blocking)
                                Task {
                                    // Wait a moment for UI to stabilize
                                    try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds

                                    print("🔍 FIX #167: Starting background health checks...")
                                    let healthResults = await WalletHealthCheck.shared.runAllChecks()
                                    WalletHealthCheck.shared.printSummary(healthResults)

                                    let hasCritical = WalletHealthCheck.shared.hasCriticalFailures(healthResults)
                                    if hasCritical {
                                        print("❌ FIX #167: Critical health issue detected in background!")
                                        // Could show an alert here if needed
                                    }

                                    // FIX #164 v4: Check for repair needed (checkpoint gap)
                                    let repairNeededCheck = healthResults.first {
                                        $0.checkName == "Checkpoint Sync" && !$0.passed && $0.details.contains("REPAIR NEEDED")
                                    }
                                    if let repair = repairNeededCheck {
                                        print("⚠️ FIX #167: Repair needed detected in background")
                                        await MainActor.run {
                                            repairNeededReason = repair.details
                                            showRepairNeededAlert = true
                                        }
                                    }

                                    print("✅ FIX #167: Background health checks complete")
                                }

                                // Start background sync for any missed blocks (non-blocking)
                                networkManager.suppressBackgroundSync = false
                                Task {
                                    do {
                                        try await networkManager.connect()
                                        networkManager.enableBackgroundProcesses()
                                        await networkManager.fetchNetworkStats()
                                    } catch {
                                        print("⚠️ Background connect error: \(error.localizedDescription)")
                                        networkManager.enableBackgroundProcesses()
                                    }
                                }
                                return  // Exit FAST START - UI is now shown
                            }

                            // OLD PATH (kept for reference but not used with skipBlockingHealthChecks = true)
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
                            if let repair = repairNeededCheck {
                                print("⚠️ FIX #164 v4: Repair needed detected - will show alert to user")
                                await MainActor.run {
                                    repairNeededReason = repair.details
                                    showRepairNeededAlert = true
                                }
                            }

                            // FIX #120 DEBUG: Log what we found
                            print("🔍 FIX #120 DEBUG: hasCritical=\(hasCritical), fixableIssues.count=\(fixableIssues.count)")
                            for issue in fixableIssues {
                                print("🔍 FIX #120 DEBUG: Fixable issue: \(issue.checkName)")
                            }

                            if hasCritical {
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

                                // FIX #120: Handle Timestamp issues OR Hash issues (both need header sync)
                                if hasTimestampIssues || hasHashIssues {
                                    print("🔧 FIX #120: Syncing headers and timestamps...")
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
                                // FIX #120: Filter out non-blocking issues that shouldn't prevent app startup:
                                // - P2P Connectivity: Expected to fail initially, will connect in background
                                // - Hash Accuracy: Requires P2P peers which may not be connected yet
                                // FIX #162: Balance Reconciliation is now CRITICAL - if notes don't match history,
                                // it means transaction data is corrupted and user sees wrong info
                                // Critical blocking issues: Timestamps, Database Integrity, Bundle Files, Delta CMU, Balance Reconciliation
                                let nonBlockingChecks = ["P2P Connectivity", "Hash Accuracy"]
                                let blockingIssues = stillHasIssues.filter { !nonBlockingChecks.contains($0.checkName) }

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
                                        let finalBlocking = finalIssues.filter { !nonBlockingChecks.contains($0.checkName) }

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
                                    print("✅ FAST START: All critical issues fixed!")
                                    // Log non-blocking issues that still exist (informational only)
                                    let nonBlockingRemaining = stillHasIssues.filter { nonBlockingChecks.contains($0.checkName) }
                                    if !nonBlockingRemaining.isEmpty {
                                        print("ℹ️ Non-blocking issues (will resolve in background):")
                                        for issue in nonBlockingRemaining {
                                            print("ℹ️   \(issue.checkName): \(issue.details)")
                                        }
                                    }
                                }
                            } else {
                                print("✅ FAST START: All health checks passed!")
                            }

                            // Mark initial sync as complete - NOW safe because all checks passed or were fixed
                            print("⚡ FAST START COMPLETE: UI ready!")

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
                        if let repair = fullStartRepairNeededCheck {
                            print("⚠️ FIX #164 v4: Repair needed detected (FULL START) - will show alert to user")
                            await MainActor.run {
                                repairNeededReason = repair.details
                                showRepairNeededAlert = true
                            }
                        }

                        if fullStartHasCritical {
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

                            // FIX #120: Handle Timestamp issues OR Hash issues (both need header sync)
                            if fullStartHasTimestampIssues || fullStartHasHashIssues {
                                print("🔧 FIX #120: Syncing headers and timestamps...")
                                await MainActor.run {
                                    walletManager.setConnecting(true, status: "Syncing headers...")
                                }
                                await walletManager.ensureHeaderTimestamps()
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
                            if !fullStartStillHasIssues.isEmpty {
                                print("⚠️ FULL START: Some issues remain after repair - proceeding anyway")
                            } else {
                                print("✅ FULL START: All issues fixed!")
                            }
                        } else {
                            print("✅ FULL START: All health checks passed!")
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
                if isInitialSync {
                    CypherpunkSyncView(
                        progress: currentSyncProgress,
                        status: currentSyncStatus,
                        tasks: currentSyncTasks,
                        startTime: effectiveStartTime,  // Use wallet creation time for accurate duration
                        estimatedDuration: estimatedSyncDuration,
                        isComplete: showCompletionScreen,
                        completionDuration: syncCompletionDuration,
                        onEnterWallet: {
                            // User clicked the enter button
                            withAnimation(.easeOut(duration: 0.3)) {
                                isInitialSync = false
                                hasCompletedInitialSync = true
                                showCompletionScreen = false
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
                        },
                        onStopSync: {
                            // User clicked STOP - cancel sync and go to main wallet
                            walletManager.stopSync()
                            withAnimation(.easeOut(duration: 0.3)) {
                                isInitialSync = false
                                hasCompletedInitialSync = true
                                showCompletionScreen = false
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
        // FIX #154: Check if we're in FAST START mode (tasks have fast_ prefix)
        let isFastStartMode = walletManager.syncTasks.contains { $0.id.hasPrefix("fast_") }

        if isFastStartMode {
            // FIX #154: Compute progress from FAST START task completion
            // Use currentSyncTasks which includes tree + connect + fast_* tasks (6 total)
            let allTasks = currentSyncTasks
            let totalTasks = allTasks.count
            guard totalTasks > 0 else { return 0.0 }

            var completedCount = 0
            var inProgressCount = 0

            for task in allTasks {
                switch task.status {
                case .completed, .failed:
                    completedCount += 1
                case .inProgress:
                    inProgressCount += 1
                case .pending:
                    break
                }
            }

            // Each completed task contributes proportionally, in-progress = 50% credit
            let completedProgress = Double(completedCount) / Double(totalTasks)
            let inProgressProgress = (Double(inProgressCount) / Double(totalTasks)) * 0.5

            let progress = min(completedProgress + inProgressProgress, 1.0)
            print("🔍 FIX #154: FAST START progress = \(Int(progress * 100))% (completed=\(completedCount), inProgress=\(inProgressCount), total=\(totalTasks))")
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
        if walletManager.isTreeLoaded && networkManager.isConnected && !isInitialSync {
            return "Ready!"
        }
        // Waiting for sync to start
        return "Preparing sync..."
    }

    /// Combined task list including tree loading
    /// Order: Tree → Connect → Sync tasks (headers, scan, witnesses, balance)
    private var currentSyncTasks: [SyncTask] {
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

        // 3. THIRD: Sync tasks from WalletManager (headers, scan, witnesses, balance)
        if !walletManager.syncTasks.isEmpty {
            tasks.append(contentsOf: walletManager.syncTasks)
        } else if networkManager.isConnected && walletManager.isTreeLoaded && !walletManager.isSyncing {
            // Sync already complete or skipped - show completed scan task
            tasks.append(SyncTask(id: "scan", title: "Decrypt shielded notes", status: .completed))
        }

        return tasks
    }

    /// Check if current theme is Cypherpunk
    private var isCypherpunkTheme: Bool {
        themeManager.currentThemeType == .cypherpunk
    }

    private var mainWalletView: some View {
        Group {
            if isCypherpunkTheme {
                // Cypherpunk theme: Single-screen layout with balance, buttons, history
                cypherpunkWalletView
            } else {
                // Classic themes: Tab-based layout
                classicWalletView
            }
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
            .frame(width: 500, height: 600)
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
            .frame(width: 480, height: 550)
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
            .frame(width: 420, height: 520)
            #endif
            .environmentObject(walletManager)
            .environmentObject(networkManager)
            .environmentObject(themeManager)
        }
        .sheet(isPresented: $showCypherpunkChat) {
            ZStack(alignment: .topTrailing) {
                ChatView()

                // Close button overlay
                Button(action: { showCypherpunkChat = false }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 24))
                        .foregroundColor(NeonColors.primary.opacity(0.8))
                        .background(Color.black.opacity(0.5))
                        .clipShape(Circle())
                }
                .buttonStyle(PlainButtonStyle())
                .padding(.top, 8)
                .padding(.trailing, 8)
            }
            .background(Color.black)
            #if os(macOS)
            .frame(width: 700, height: 600)
            #endif
            .environmentObject(walletManager)
            .environmentObject(networkManager)
            .environmentObject(themeManager)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            recordUserActivity()
        }
        .alert("Insufficient Disk Space", isPresented: $showInsufficientDiskSpaceAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("ZipherX requires approximately 750 MB of free space to download blockchain data.\n\nAvailable: \(availableDiskSpace)\n\nPlease free up some space and restart the app.")
        }
        // FIX #164: Repair needed alert - shown when blocks were skipped and spent notes may be missed
        .alert("⚠️ Database Repair Recommended", isPresented: $showRepairNeededAlert) {
            Button("Later", role: .cancel) { }
            Button("Open Settings") {
                // Navigate to settings tab
                selectedTab = .settings
                showCypherpunkSettings = true
            }
        } message: {
            Text("Your wallet may show an incorrect balance.\n\n\(repairNeededReason)\n\nTo fix this:\n1. Go to Settings\n2. Tap 'Repair Database'\n3. Wait for repair to complete\n\nNote: Tor will be temporarily disabled during repair for faster scanning.\n\nSend is disabled until repair is complete to prevent errors.")
        }
        // FIX #175: Sybil attack alert
        .alert("🚨 Security Alert: Sybil Attack Detected", isPresented: $showSybilAttackAlert) {
            Button("OK", role: .cancel) {
                networkManager.clearSybilAttackAlert()
            }
        } message: {
            if let alert = networkManager.sybilVersionAttackAlert {
                Text("Detected \(alert.attackerCount) suspicious peer(s) reporting fake blockchain data.\n\n\(alert.bypassedTor ? "Tor has been temporarily bypassed to connect directly to trusted peers." : "Malicious peers have been banned.")\n\nYour funds are safe. The wallet is using verified peer consensus.\n\n\"Privacy is necessary for an open society in the electronic age.\"\n— A Cypherpunk's Manifesto")
            } else {
                Text("Suspicious network activity detected. Malicious peers have been blocked.")
            }
        }
        // FIX #174: External wallet spend alert
        .alert("⚠️ External Wallet Activity Detected", isPresented: $showExternalWalletSpendAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            if let spend = networkManager.externalWalletSpendDetected {
                let zcl = Double(spend.amount) / 100_000_000.0
                Text("Another wallet is spending your funds!\n\nAmount: \(String(format: "%.8f", zcl)) ZCL\nTxID: \(spend.txid.prefix(16))...\n\nThis transaction was NOT initiated by ZipherX. If you did not authorize this, your private key may be compromised.\n\nSend is temporarily disabled until this transaction confirms.")
            } else {
                Text("External wallet activity detected on your address.")
            }
        }
        // FIX #175: Watch for Sybil attack alerts
        .onChange(of: networkManager.sybilVersionAttackAlert != nil) { hasAlert in
            if hasAlert {
                showSybilAttackAlert = true
            }
        }
        // FIX #174: Watch for external wallet spend detection
        .onChange(of: networkManager.externalWalletSpendDetected != nil) { hasSpend in
            if hasSpend {
                showExternalWalletSpendAlert = true
            }
        }
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
                            ChatView()
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
}

#Preview {
    ContentView()
        .environmentObject(WalletManager.shared)
        .environmentObject(NetworkManager.shared)
        .environmentObject(ThemeManager.shared)
}
