import SwiftUI

struct ContentView: View {
    @EnvironmentObject var walletManager: WalletManager
    @EnvironmentObject var networkManager: NetworkManager
    @State private var selectedTab: Tab = .balance
    @State private var isFirstLaunch: Bool = false
    @State private var isInitialSync: Bool = true  // Track initial sync state

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
                        // Check if this is first launch (tree not yet cached)
                        isFirstLaunch = !walletManager.isTreeLoaded && walletManager.treeLoadProgress < 1.0

                        // Show connecting status immediately at app launch
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
                        // Wait for connection to stabilize
                        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 sec
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

                        // Clear connecting state after everything is done
                        await MainActor.run {
                            walletManager.setConnecting(false, status: nil)
                        }

                        // Mark initial sync as complete ONLY after everything finishes
                        await MainActor.run {
                            isInitialSync = false
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
        // Tree loading phase (0-30%)
        if !walletManager.isTreeLoaded {
            return walletManager.treeLoadProgress * 0.3
        }
        // Connecting phase (30-35%)
        if walletManager.isConnecting && !walletManager.isSyncing {
            return 0.32
        }
        // Sync phase (35-100%)
        if walletManager.isSyncing {
            return 0.35 + (walletManager.syncProgress * 0.65)
        }
        // Tree loaded, not syncing yet
        return 0.30
    }

    /// Combined status for all sync phases
    private var currentSyncStatus: String {
        // Tree loading
        if !walletManager.isTreeLoaded {
            return walletManager.treeLoadStatus.isEmpty ? "Loading commitment tree..." : walletManager.treeLoadStatus
        }
        // Connecting
        if walletManager.isConnecting {
            return "Connecting to network..."
        }
        // Syncing
        if walletManager.isSyncing {
            return walletManager.syncStatus
        }
        // Default
        return "Initializing..."
    }

    /// Combined task list including tree loading
    private var currentSyncTasks: [SyncTask] {
        var tasks: [SyncTask] = []

        // Add tree loading task if tree not loaded yet
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
            // Tree loaded - show completed
            tasks.append(SyncTask(id: "tree", title: "Load commitment tree", status: .completed))
        }

        // Add connecting task
        if walletManager.isConnecting && walletManager.syncTasks.isEmpty {
            tasks.append(SyncTask(id: "connect", title: "Connect to network", status: .inProgress))
        } else if walletManager.isTreeLoaded && walletManager.syncTasks.isEmpty {
            tasks.append(SyncTask(id: "connect", title: "Connect to network", status: .pending))
        }

        // Add sync tasks from WalletManager
        tasks.append(contentsOf: walletManager.syncTasks)

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
