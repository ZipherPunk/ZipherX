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

    // Cypherpunk mode sheet states
    @State private var showCypherpunkSettings = false
    @State private var showCypherpunkSend = false
    @State private var showCypherpunkReceive = false

    enum Tab {
        case balance, send, receive, settings
    }

    var body: some View {
        ZStack {
            // Themed background
            themeManager.currentTheme.backgroundColor
                .ignoresSafeArea()

            if walletManager.isWalletCreated {
                mainWalletView
                    .task {
                        print("DEBUGZIPHERX: 🚀 Task: Starting initial sync task...")

                        // Only run initial sync once
                        guard !hasCompletedInitialSync else {
                            print("DEBUGZIPHERX: 🚀 Task: Already completed, returning")
                            return
                        }

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

                            // After initial sync, show lock screen if biometric enabled
                            // This prompts Face ID on app launch
                            if biometricManager.isBiometricEnabled {
                                isShowingLockScreen = true
                            }

                            // Start inactivity timer now that sync is done
                            startInactivityTimer()
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

                // Floating sync progress indicator for BACKGROUND syncing
                // Shows when syncing after initial sync is complete (user can still use app)
                if !isInitialSync && walletManager.isSyncing {
                    floatingSyncIndicator
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
            showReceive: $showCypherpunkReceive
        )
        .sheet(isPresented: $showCypherpunkSettings) {
            NavigationView {
                SettingsView()
                    .navigationTitle("Settings")
                    #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                    #endif
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") {
                                showCypherpunkSettings = false
                            }
                            .foregroundColor(Color(red: 0, green: 1, blue: 0.25))
                        }
                    }
            }
            .navigationViewStyle(.stack)
            #if os(macOS)
            .frame(width: 500, height: 600)
            #endif
            .environmentObject(walletManager)
            .environmentObject(networkManager)
            .environmentObject(themeManager)
        }
        .sheet(isPresented: $showCypherpunkSend) {
            NavigationView {
                SendView()
                    .navigationTitle("Send ZCL")
                    #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                    #endif
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") {
                                showCypherpunkSend = false
                            }
                            .foregroundColor(Color(red: 0, green: 1, blue: 0.25))
                        }
                    }
            }
            .navigationViewStyle(.stack)
            #if os(macOS)
            .frame(width: 480, height: 550)
            #endif
            .environmentObject(walletManager)
            .environmentObject(networkManager)
            .environmentObject(themeManager)
        }
        .sheet(isPresented: $showCypherpunkReceive) {
            NavigationView {
                ReceiveView()
                    .navigationTitle("Receive ZCL")
                    #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                    #endif
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") {
                                showCypherpunkReceive = false
                            }
                            .foregroundColor(Color(red: 0, green: 1, blue: 0.25))
                        }
                    }
            }
            .navigationViewStyle(.stack)
            #if os(macOS)
            .frame(width: 420, height: 520)
            #endif
            .environmentObject(walletManager)
            .environmentObject(networkManager)
            .environmentObject(themeManager)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            recordUserActivity()
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
                            SendView()
                        case .receive:
                            ReceiveView()
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
}

#Preview {
    ContentView()
        .environmentObject(WalletManager.shared)
        .environmentObject(NetworkManager.shared)
        .environmentObject(ThemeManager.shared)
}
