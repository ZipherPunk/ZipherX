import SwiftUI

struct ContentView: View {
    @EnvironmentObject var walletManager: WalletManager
    @EnvironmentObject var networkManager: NetworkManager
    @State private var selectedTab: Tab = .balance
    @State private var isFirstLaunch: Bool = false

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

                        // Connect first, then fetch stats
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
                            do {
                                try await walletManager.refreshBalance()
                            } catch {
                                print("⚠️ Auto-sync failed: \(error.localizedDescription)")
                            }
                        }
                    }

                // Tree loading overlay (shown during first launch)
                if !walletManager.isTreeLoaded && walletManager.treeLoadProgress > 0 {
                    CypherpunkLoadingView(
                        progress: walletManager.treeLoadProgress,
                        status: walletManager.treeLoadStatus,
                        isFirstLaunch: isFirstLaunch
                    )
                    .transition(.opacity)
                }

                // Sync overlay (shown during blockchain sync after tree is loaded)
                if walletManager.isTreeLoaded && walletManager.isSyncing {
                    CypherpunkSyncView(
                        progress: walletManager.syncProgress,
                        status: walletManager.syncStatus
                    )
                    .transition(.opacity)
                }
            } else {
                WalletSetupView()
            }
        }
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
