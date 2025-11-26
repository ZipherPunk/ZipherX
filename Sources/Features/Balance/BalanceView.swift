import SwiftUI

/// Balance View - Displays shielded ZCL balance
/// Classic Macintosh System 7 design
struct BalanceView: View {
    @EnvironmentObject var walletManager: WalletManager
    @EnvironmentObject var networkManager: NetworkManager
    @State private var isRefreshing = false
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var refreshTimer: Timer?

    var body: some View {
        VStack(spacing: 16) {
            // Balance display
            balanceCard

            // Network status
            networkStatus

            // Rescan button - hidden but code kept for future key import feature
            // System7Button(title: "Rescan") {
            //     rescanBlockchain()
            // }
            // .disabled(true)
            // .opacity(0.5)

            Spacer()
        }
        .padding()
        .alert("Error", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
        .onAppear {
            // Start automatic refresh every 3 seconds
            startAutoRefresh()
        }
        .onDisappear {
            // Stop auto refresh when leaving view
            stopAutoRefresh()
        }
    }

    private var balanceCard: some View {
        VStack(spacing: 12) {
            // Main balance
            VStack(spacing: 4) {
                Text("Shielded Balance")
                    .font(System7Theme.bodyFont(size: 10))
                    .foregroundColor(System7Theme.darkGray)

                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(formatBalance(walletManager.shieldedBalance))
                        .font(System7Theme.titleFont(size: 24))
                        .foregroundColor(System7Theme.black)

                    Text("ZCL")
                        .font(System7Theme.bodyFont(size: 12))
                        .foregroundColor(System7Theme.darkGray)
                }
            }

            // Pending balance
            if walletManager.pendingBalance > 0 {
                HStack(spacing: 4) {
                    Text("Pending:")
                        .font(System7Theme.bodyFont(size: 10))
                        .foregroundColor(System7Theme.darkGray)

                    Text("+\(formatBalance(walletManager.pendingBalance)) ZCL")
                        .font(System7Theme.bodyFont(size: 10))
                        .foregroundColor(System7Theme.darkGray)
                }
            }

            // Privacy indicator
            HStack(spacing: 4) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 10))
                Text("Fully Shielded")
                    .font(System7Theme.bodyFont(size: 9))
            }
            .foregroundColor(System7Theme.black)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(System7Theme.lightGray)
            .overlay(
                Rectangle()
                    .stroke(System7Theme.black, lineWidth: 1)
            )
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(System7Theme.white)
        .overlay(
            Rectangle()
                .stroke(System7Theme.black, lineWidth: 1)
        )
        .overlay(
            // Raised effect
            Rectangle()
                .strokeBorder(
                    LinearGradient(
                        colors: [System7Theme.white, System7Theme.darkGray],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
                .padding(1)
        )
    }

    private var networkStatus: some View {
        VStack(spacing: 0) {
            // Connection status
            HStack(spacing: 8) {
                Circle()
                    .fill(networkManager.isConnected ? Color.green : Color.red)
                    .frame(width: 8, height: 8)

                Text(networkManager.isConnected
                    ? "Connected to \(networkManager.connectedPeers) peers"
                    : "Disconnected")
                    .font(System7Theme.bodyFont(size: 10))
                    .foregroundColor(System7Theme.darkGray)

                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

            // Network stats
            if networkManager.isConnected {
                Divider()
                    .background(System7Theme.black)

                VStack(alignment: .leading, spacing: 3) {
                    if networkManager.chainHeight > 0 {
                        // Node version
                        if !networkManager.peerVersion.isEmpty && networkManager.peerVersion != "Unknown" {
                            statRow("Node:", networkManager.peerVersion)
                        }

                        // Block height
                        statRow("Height:", "\(networkManager.walletHeight) / \(networkManager.chainHeight)")

                        // ZCL Price
                        if networkManager.zclPriceUSD > 0 {
                            statRow("ZCL Price:", String(format: "$%.4f", networkManager.zclPriceUSD))
                        }

                        // Last block tx count
                        if networkManager.lastBlockTxCount > 0 {
                            statRow("Last Block:", "\(networkManager.lastBlockTxCount) txns")
                        }

                        // Network difficulty
                        if networkManager.networkDifficulty > 0 {
                            statRow("Difficulty:", formatDifficulty(networkManager.networkDifficulty))
                        }
                    } else {
                        HStack {
                            ProgressView()
                                .scaleEffect(0.6)
                            Text("Loading stats...")
                                .font(System7Theme.bodyFont(size: 9))
                                .foregroundColor(System7Theme.darkGray)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }

            // Sync tasks list - always show when tasks exist
            if !walletManager.syncTasks.isEmpty {
                Divider()
                    .background(System7Theme.black)

                VStack(spacing: 4) {
                    ForEach(walletManager.syncTasks) { task in
                        syncTaskRow(task)
                    }
                }
                .padding(8)
            }
        }
        .background(System7Theme.lightGray)
        .overlay(
            Rectangle()
                .stroke(System7Theme.black, lineWidth: 1)
        )
    }

    private func syncTaskRow(_ task: SyncTask) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                // Status icon
                Group {
                    switch task.status {
                    case .pending:
                        Image(systemName: "circle")
                            .foregroundColor(System7Theme.darkGray)
                    case .inProgress:
                        ProgressView()
                            .scaleEffect(0.5)
                    case .completed:
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    case .failed:
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.red)
                    }
                }
                .frame(width: 16, height: 16)

                // Task title
                Text(task.title)
                    .font(System7Theme.bodyFont(size: 9))
                    .foregroundColor(task.status == .pending ? System7Theme.darkGray : System7Theme.black)

                Spacer()

                // Detail or error
                if let detail = task.detail {
                    Text(detail)
                        .font(System7Theme.bodyFont(size: 8))
                        .foregroundColor(System7Theme.darkGray)
                }

                if case .failed(let error) = task.status {
                    Text(error)
                        .font(System7Theme.bodyFont(size: 8))
                        .foregroundColor(.red)
                        .lineLimit(1)
                }
            }

            // Progress bar (if available)
            if let progress = task.progress, progress > 0 {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        // Background
                        Rectangle()
                            .fill(System7Theme.white)
                            .frame(height: 8)
                            .overlay(
                                Rectangle()
                                    .stroke(System7Theme.black, lineWidth: 1)
                            )

                        // Progress fill
                        Rectangle()
                            .fill(System7Theme.black)
                            .frame(width: geometry.size.width * min(progress, 1.0), height: 6)
                            .padding(.leading, 1)
                            .padding(.top, 1)

                        // Percentage text
                        Text("\(Int(progress * 100))%")
                            .font(System7Theme.bodyFont(size: 7))
                            .foregroundColor(progress > 0.5 ? System7Theme.white : System7Theme.black)
                            .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 8)
                .padding(.leading, 24) // Indent to align with title
            }
        }
    }

    // MARK: - Actions

    private func refreshBalance() {
        isRefreshing = true

        Task {
            do {
                // Connect if needed
                if !networkManager.isConnected {
                    try await networkManager.connect()
                }

                // Refresh balance
                try await walletManager.refreshBalance()
            } catch {
                DispatchQueue.main.async {
                    errorMessage = error.localizedDescription
                    showError = true
                }
            }

            DispatchQueue.main.async {
                isRefreshing = false
            }
        }
    }

    private func rescanBlockchain() {
        isRefreshing = true

        Task {
            do {
                // Connect if needed
                if !networkManager.isConnected {
                    try await networkManager.connect()
                }

                // Rescan from checkpoint
                try await walletManager.rescanBlockchain()
            } catch {
                DispatchQueue.main.async {
                    errorMessage = error.localizedDescription
                    showError = true
                }
            }

            DispatchQueue.main.async {
                isRefreshing = false
            }
        }
    }

    // MARK: - Auto Refresh

    private func startAutoRefresh() {
        // Stop any existing timer
        stopAutoRefresh()

        // Immediate refresh on appear
        autoRefreshTick()

        // Schedule refresh every 3 seconds
        DispatchQueue.main.async {
            self.refreshTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak walletManager, weak networkManager] _ in
                guard walletManager != nil, networkManager != nil else { return }
                self.autoRefreshTick()
            }
        }
    }

    private func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func autoRefreshTick() {
        // Don't refresh if already in progress
        guard !isRefreshing else { return }

        Task { @MainActor in
            // Prevent concurrent refresh
            guard !isRefreshing else { return }

            // Only fetch stats if already connected (don't auto-connect repeatedly)
            if networkManager.isConnected {
                // Fetch network stats (block height, difficulty, etc.)
                await networkManager.fetchNetworkStats()

                // Check for new blocks and scan them
                if networkManager.chainHeight > networkManager.walletHeight && networkManager.chainHeight > 0 {
                    isRefreshing = true
                    do {
                        try await walletManager.refreshBalance()
                    } catch {
                        // Silently fail on auto-refresh
                        print("⚠️ Auto-refresh failed: \(error.localizedDescription)")
                    }
                    isRefreshing = false
                }
            } else {
                // Try to connect once
                do {
                    try await networkManager.connect()
                } catch {
                    // Silently fail - will retry on next tick
                }
            }
        }
    }

    // MARK: - Formatting

    private func formatBalance(_ zatoshis: UInt64) -> String {
        let zcl = Double(zatoshis) / 100_000_000.0
        return String(format: "%.8f", zcl)
    }

    private func formatDifficulty(_ difficulty: Double) -> String {
        if difficulty >= 1_000_000_000 {
            return String(format: "%.2f G", difficulty / 1_000_000_000)
        } else if difficulty >= 1_000_000 {
            return String(format: "%.2f M", difficulty / 1_000_000)
        } else if difficulty >= 1_000 {
            return String(format: "%.2f K", difficulty / 1_000)
        } else {
            return String(format: "%.2f", difficulty)
        }
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(System7Theme.bodyFont(size: 9))
                .foregroundColor(System7Theme.darkGray)
            Text(value)
                .font(System7Theme.bodyFont(size: 9))
                .foregroundColor(System7Theme.black)
                .lineLimit(1)
            Spacer()
        }
    }
}

#Preview {
    BalanceView()
        .environmentObject(WalletManager.shared)
        .environmentObject(NetworkManager.shared)
}
