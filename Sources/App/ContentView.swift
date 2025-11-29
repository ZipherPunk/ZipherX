import SwiftUI

struct ContentView: View {
    @EnvironmentObject var walletManager: WalletManager
    @EnvironmentObject var networkManager: NetworkManager
    @State private var selectedTab: Tab = .balance
    @State private var isFirstLaunch: Bool = false
    @State private var isInitialSync: Bool = true  // Track initial sync state
    @State private var hasCompletedInitialSync: Bool = false  // Prevent re-running

    enum Tab {
        case balance, send, receive, settings
    }

    var body: some View {
        ZStack {
            // Classic Mac desktop pattern background
            System7Theme.desktopPattern
                .ignoresSafeArea()

            if walletManager.isWalletCreated {
                mainWalletView
                    .task {
                        // Only run initial sync once
                        guard !hasCompletedInitialSync else { return }

                        // Check if this is first launch (tree not yet cached)
                        isFirstLaunch = !walletManager.isTreeLoaded && walletManager.treeLoadProgress < 1.0

                        // Trigger tree loading if not already loaded
                        // This handles the case where wallet was just created/imported
                        if !walletManager.isTreeLoaded {
                            await walletManager.ensureTreeLoaded()
                        }

                        // WAIT for tree to load before proceeding with network operations
                        while !walletManager.isTreeLoaded {
                            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                        }

                        // Show connecting status after tree is loaded
                        await MainActor.run {
                            walletManager.setConnecting(true, status: "Connecting to network...")
                        }

                        // Connect if needed
                        if !networkManager.isConnected {
                            do {
                                try await networkManager.connect()
                            } catch {
                                print("⚠️ Auto-connect failed: \(error.localizedDescription)")
                            }
                        }
                        // Brief pause for UI feedback
                        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 sec
                        // Now fetch stats
                        await networkManager.fetchNetworkStats()

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
                        var syncWaitCount = 0
                        let maxSyncWait = 300 // 30 seconds max wait for height sync
                        while networkManager.chainHeight > 0 &&
                              networkManager.walletHeight < networkManager.chainHeight &&
                              syncWaitCount < maxSyncWait {
                            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                            syncWaitCount += 1
                            // Re-fetch stats periodically to update heights
                            if syncWaitCount % 20 == 0 {
                                await networkManager.fetchNetworkStats()
                            }
                        }

                        // CATCH-UP: Check for blocks that arrived during setup
                        // Re-fetch current chain height and sync any new blocks
                        await networkManager.fetchNetworkStats()
                        let currentChainHeight = networkManager.chainHeight
                        let currentWalletHeight = networkManager.walletHeight

                        // Only catch-up if wallet is actually synced (walletHeight > 0)
                        // and there are just a few missed blocks (not the entire chain)
                        if currentWalletHeight > 0 && currentChainHeight > currentWalletHeight {
                            let missedBlocks = currentChainHeight - currentWalletHeight
                            // Sanity check: should only be a few blocks, not thousands
                            guard missedBlocks < 100 else {
                                print("⚠️ Catch-up skipped: \(missedBlocks) blocks seems wrong (wallet not synced?)")
                                await MainActor.run {
                                    walletManager.setConnecting(false, status: nil)
                                    isInitialSync = false
                                    hasCompletedInitialSync = true
                                }
                                return
                            }
                            print("🔄 Catch-up: \(missedBlocks) new block(s) arrived during setup")

                            await MainActor.run {
                                walletManager.setConnecting(true, status: "Catching up \(missedBlocks) new block(s)...")
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

                        // Brief pause to show completion
                        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 sec

                        // Mark initial sync as complete ONLY after everything finishes
                        await MainActor.run {
                            isInitialSync = false
                            hasCompletedInitialSync = true
                        }
                    }

                // SINGLE cypherpunk overlay for ALL initial sync phases
                // Shows during: tree loading, connecting, syncing - until initial sync complete
                if isInitialSync {
                    CypherpunkSyncView(
                        progress: currentSyncProgress,
                        status: currentSyncStatus,
                        tasks: currentSyncTasks
                    )
                    .transition(.opacity)
                }
            } else {
                WalletSetupView()
            }
        }
    }

    /// Combined progress for all sync phases
    private var currentSyncProgress: Double {
        // Connecting phase (0-10%) - comes first now
        if !networkManager.isConnected {
            return walletManager.isConnecting ? 0.05 : 0.0
        }

        // Tree loading phase (10-40%)
        if !walletManager.isTreeLoaded {
            return 0.10 + (walletManager.treeLoadProgress * 0.30)
        }

        // Sync phase (40-95%)
        // Check if still syncing OR tasks exist and not all completed
        let allTasksCompleted = !walletManager.syncTasks.isEmpty && walletManager.syncTasks.allSatisfy {
            if case .completed = $0.status { return true }
            if case .failed = $0.status { return true }
            return false
        }

        if walletManager.isSyncing || (!walletManager.syncTasks.isEmpty && !allTasksCompleted) {
            // Check if balance task is completed
            let balanceCompleted = walletManager.syncTasks.contains {
                $0.id == "balance" && $0.status == .completed
            }
            if balanceCompleted {
                return 0.98
            }
            return 0.40 + (walletManager.syncProgress * 0.55)
        }

        // Finalizing phase (95-100%) - only if we're truly done
        if walletManager.isTreeLoaded && networkManager.isConnected && !isInitialSync {
            return 1.0
        }

        // Still waiting for sync to start
        return 0.40
    }

    /// Combined status for all sync phases
    private var currentSyncStatus: String {
        // Connecting (first step now)
        if !networkManager.isConnected {
            return walletManager.isConnecting ? "Connecting to network..." : "Waiting for network..."
        }
        // Tree loading
        if !walletManager.isTreeLoaded {
            return walletManager.treeLoadStatus.isEmpty ? "Loading commitment tree..." : walletManager.treeLoadStatus
        }
        // Syncing (includes waiting for sync to start)
        // Only show sync status if still syncing or tasks not all completed
        let statusAllTasksCompleted = !walletManager.syncTasks.isEmpty && walletManager.syncTasks.allSatisfy {
            if case .completed = $0.status { return true }
            if case .failed = $0.status { return true }
            return false
        }

        if walletManager.isSyncing || (!walletManager.syncTasks.isEmpty && !statusAllTasksCompleted) {
            if walletManager.syncStatus.isEmpty {
                return "Starting blockchain sync..."
            }
            return walletManager.syncStatus
        }
        // Tree loaded, network connected, sync complete
        if walletManager.isTreeLoaded && networkManager.isConnected && !isInitialSync {
            return "Ready!"
        }
        // All tasks completed - show ready message
        if statusAllTasksCompleted {
            return "Finalizing..."
        }
        // Waiting for sync to start
        return "Preparing sync..."
    }

    /// Combined task list including tree loading
    /// Order: Connect → Tree → Sync tasks (headers, scan, witnesses, balance)
    private var currentSyncTasks: [SyncTask] {
        var tasks: [SyncTask] = []

        // 1. FIRST: Network connection task
        if !networkManager.isConnected {
            let status: SyncTaskStatus = walletManager.isConnecting ? .inProgress : .pending
            tasks.append(SyncTask(id: "connect", title: "Connect to network", status: status))
        } else {
            tasks.append(SyncTask(id: "connect", title: "Connect to network", status: .completed))
        }

        // 2. SECOND: Tree loading task
        if !walletManager.isTreeLoaded {
            let treeTask = SyncTask(
                id: "tree",
                title: "Load commitment tree",
                status: walletManager.treeLoadProgress > 0 ? .inProgress : .pending,
                detail: walletManager.treeLoadStatus,
                progress: walletManager.treeLoadProgress
            )
            tasks.append(treeTask)
        } else {
            tasks.append(SyncTask(id: "tree", title: "Load commitment tree", status: .completed))
        }

        // 3. THIRD: Sync tasks from WalletManager (headers, scan, witnesses, balance)
        if !walletManager.syncTasks.isEmpty {
            tasks.append(contentsOf: walletManager.syncTasks)
        } else if networkManager.isConnected && walletManager.isTreeLoaded && !walletManager.isSyncing {
            // Sync already complete or skipped - show completed scan task
            tasks.append(SyncTask(id: "scan", title: "Scan blockchain", status: .completed))
        }

        return tasks
    }

    private var mainWalletView: some View {
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
                        }
                        System7TabButton(title: "Send", isSelected: selectedTab == .send) {
                            selectedTab = .send
                        }
                        System7TabButton(title: "Receive", isSelected: selectedTab == .receive) {
                            selectedTab = .receive
                        }
                        System7TabButton(title: "Settings", isSelected: selectedTab == .settings) {
                            selectedTab = .settings
                        }
                    }
                    .padding(.horizontal)

                    // Content
                    Group {
                        switch selectedTab {
                        case .balance:
                            BalanceView()
                        case .send:
                            SendView()
                        case .receive:
                            ReceiveView()
                        case .settings:
                            SettingsView()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .padding()
            }
            .padding()
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(WalletManager.shared)
        .environmentObject(NetworkManager.shared)
}
