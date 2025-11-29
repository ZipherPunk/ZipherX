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
    @State private var transactions: [TransactionHistoryItem] = []
    @State private var isLoadingHistory = true

    var body: some View {
        VStack(spacing: 16) {
            // Balance display
            balanceCard

            // Transaction history (compact)
            transactionHistorySection

            // Network status
            networkStatus

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
            // Load transaction history
            loadTransactionHistory()
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

    private var transactionHistorySection: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 10))
                Text("Recent Transactions")
                    .font(System7Theme.titleFont(size: 10))
                Spacer()
            }
            .foregroundColor(System7Theme.black)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

            Divider()
                .background(System7Theme.black)

            // Transaction list or empty state
            if isLoadingHistory {
                HStack {
                    ProgressView()
                        .scaleEffect(0.6)
                    Text("Loading...")
                        .font(System7Theme.bodyFont(size: 9))
                        .foregroundColor(System7Theme.darkGray)
                    Spacer()
                }
                .padding(8)
            } else if transactions.isEmpty {
                HStack {
                    Image(systemName: "doc.text")
                        .font(.system(size: 12))
                        .foregroundColor(System7Theme.darkGray)
                    Text("No transactions yet")
                        .font(System7Theme.bodyFont(size: 9))
                        .foregroundColor(System7Theme.darkGray)
                    Spacer()
                }
                .padding(8)
            } else {
                // Show up to 5 recent transactions
                VStack(spacing: 1) {
                    ForEach(transactions.prefix(5), id: \.txidString) { tx in
                        transactionRow(tx)
                    }
                }
            }
        }
        .background(System7Theme.lightGray)
        .overlay(
            Rectangle()
                .stroke(System7Theme.black, lineWidth: 1)
        )
    }

    private func transactionRow(_ tx: TransactionHistoryItem) -> some View {
        HStack(spacing: 8) {
            // Type icon
            Image(systemName: tx.type == .received ? "arrow.down.left" : "arrow.up.right")
                .font(.system(size: 10))
                .foregroundColor(tx.type == .received ? .green : .red)
                .frame(width: 16)

            // Amount
            Text("\(tx.type == .received ? "+" : "-")\(String(format: "%.4f", tx.valueInZCL))")
                .font(System7Theme.monoFont(size: 9))
                .foregroundColor(tx.type == .received ? .green : .red)

            Spacer()

            // Date/Time - prefer actual blockTime, fall back to estimated time
            Text(tx.dateString ?? estimatedDateString(for: tx.height))
                .font(System7Theme.bodyFont(size: 8))
                .foregroundColor(System7Theme.darkGray)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(System7Theme.white)
    }

    /// Estimate date/time from block height
    /// Zclassic has ~150 second block times (2.5 minutes)
    private func estimatedDateString(for height: UInt64) -> String {
        // Reference point: block 2,923,123 on November 28, 2025
        let referenceHeight: UInt64 = 2_923_123
        let referenceDate = Date(timeIntervalSince1970: 1764284400) // Nov 28, 2025 00:00 local

        let blockDifference = Int64(height) - Int64(referenceHeight)
        let secondsDifference = Double(blockDifference) * 150.0 // ~150 seconds per block

        let estimatedDate = referenceDate.addingTimeInterval(secondsDifference)

        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: estimatedDate)
    }

    private func loadTransactionHistory() {
        isLoadingHistory = true

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                // First, always try to populate from notes (it uses INSERT OR REPLACE so it's safe)
                print("📜 Populating transaction history from notes...")
                let populated = try WalletDatabase.shared.populateHistoryFromNotes()
                print("📜 Populate result: \(populated) entries")

                // Now fetch the history
                let items = try WalletDatabase.shared.getTransactionHistory(limit: 10)
                print("📜 getTransactionHistory returned \(items.count) items")

                // Debug: print first item if exists
                if let first = items.first {
                    print("📜 First tx: type=\(first.type), value=\(first.value), height=\(first.height), txid=\(first.txidString.prefix(16))...")
                }

                DispatchQueue.main.async {
                    self.transactions = items
                    self.isLoadingHistory = false
                    print("📜 UI updated with \(items.count) transactions")
                }
            } catch {
                print("❌ Failed to load transaction history: \(error)")
                DispatchQueue.main.async {
                    self.isLoadingHistory = false
                }
            }
        }
    }

    private var networkStatus: some View {
        VStack(spacing: 0) {
            // Connection status with more details
            HStack(spacing: 8) {
                // Animated connection indicator
                Circle()
                    .fill(connectionColor)
                    .frame(width: 8, height: 8)

                VStack(alignment: .leading, spacing: 1) {
                    Text(connectionStatusText)
                        .font(System7Theme.bodyFont(size: 10))
                        .foregroundColor(System7Theme.black)
                }

                Spacer()

                // Retry button when disconnected
                if !networkManager.isConnected && !isRefreshing {
                    Button(action: { retryConnection() }) {
                        Text("Retry")
                            .font(System7Theme.bodyFont(size: 9))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(System7Theme.lightGray)
                            .overlay(Rectangle().stroke(System7Theme.black, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
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

            // Simplified wallet status - just show current state
            Divider()
                .background(System7Theme.black)

            HStack {
                if walletManager.isSyncing {
                    ProgressView()
                        .scaleEffect(0.5)
                    Text("Syncing...")
                        .font(System7Theme.bodyFont(size: 9))
                        .foregroundColor(System7Theme.black)
                    Spacer()
                    if walletManager.syncProgress > 0 {
                        Text("\(Int(walletManager.syncProgress * 100))%")
                            .font(System7Theme.bodyFont(size: 9))
                            .foregroundColor(System7Theme.darkGray)
                    }
                } else if !networkManager.isConnected {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.red)
                        .font(.system(size: 10))
                    Text("Disconnected")
                        .font(System7Theme.bodyFont(size: 9))
                        .foregroundColor(.red)
                    Spacer()
                } else if networkManager.chainHeight > 0 && networkManager.walletHeight >= networkManager.chainHeight {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.system(size: 10))
                    Text("Synced")
                        .font(System7Theme.bodyFont(size: 9))
                        .foregroundColor(System7Theme.darkGray)
                    Spacer()
                } else {
                    Image(systemName: "clock")
                        .foregroundColor(.orange)
                        .font(.system(size: 10))
                    Text("Waiting to sync")
                        .font(System7Theme.bodyFont(size: 9))
                        .foregroundColor(System7Theme.darkGray)
                    Spacer()
                }
            }
            .padding(8)

            /* DISABLED: Detailed sync tasks list
            // Sync tasks list - always show when tasks exist or syncing
            if !walletManager.syncTasks.isEmpty || walletManager.isSyncing {
                Divider()
                    .background(System7Theme.black)

                VStack(spacing: 6) {
                    // Sync status header
                    if walletManager.isSyncing {
                        HStack {
                            ProgressView()
                                .scaleEffect(0.5)
                            Text("Syncing...")
                                .font(System7Theme.bodyFont(size: 9))
                                .foregroundColor(System7Theme.black)
                            Spacer()
                            if walletManager.syncProgress > 0 {
                                Text("\(Int(walletManager.syncProgress * 100))%")
                                    .font(System7Theme.bodyFont(size: 9))
                                    .foregroundColor(System7Theme.darkGray)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.top, 4)

                        // Overall progress bar
                        if walletManager.syncProgress > 0 {
                            GeometryReader { geometry in
                                ZStack(alignment: .leading) {
                                    Rectangle()
                                        .fill(System7Theme.white)
                                        .frame(height: 10)
                                        .overlay(Rectangle().stroke(System7Theme.black, lineWidth: 1))

                                    Rectangle()
                                        .fill(Color.blue.opacity(0.7))
                                        .frame(width: geometry.size.width * min(walletManager.syncProgress, 1.0), height: 8)
                                        .padding(.leading, 1)
                                        .padding(.top, 1)
                                }
                            }
                            .frame(height: 10)
                            .padding(.horizontal, 8)
                        }
                    }

                    // Individual tasks
                    ForEach(walletManager.syncTasks) { task in
                        syncTaskRow(task)
                    }
                }
                .padding(.vertical, 4)
            }

            // Show "synced" message when up to date
            if !walletManager.isSyncing && networkManager.chainHeight > 0 &&
               networkManager.walletHeight >= networkManager.chainHeight {
                Divider()
                    .background(System7Theme.black)

                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.system(size: 10))
                    Text("Wallet synced")
                        .font(System7Theme.bodyFont(size: 9))
                        .foregroundColor(System7Theme.darkGray)
                    Spacer()
                }
                .padding(8)
            }
            */
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

    // MARK: - Computed Properties

    private var connectionColor: Color {
        if networkManager.isConnected {
            return networkManager.connectedPeers >= 3 ? .green : .yellow
        } else if isRefreshing {
            return .orange
        } else {
            return .red
        }
    }

    private var connectionStatusText: String {
        if isRefreshing && !networkManager.isConnected {
            return "Connecting..."
        } else if networkManager.isConnected {
            let peerWord = networkManager.connectedPeers == 1 ? "peer" : "peers"
            return "Connected to \(networkManager.connectedPeers) \(peerWord)"
        } else {
            return "Disconnected"
        }
    }

    // MARK: - Actions

    private func retryConnection() {
        Task {
            do {
                try await networkManager.connect()
            } catch {
                print("Connection retry failed: \(error)")
            }
        }
    }

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
        // Don't refresh if already in progress or if a scan is running
        guard !isRefreshing else { return }
        guard !FilterScanner.isScanInProgress else { return }
        guard !walletManager.isSyncing else { return }

        Task { @MainActor in
            // Prevent concurrent refresh
            guard !isRefreshing else { return }
            guard !FilterScanner.isScanInProgress else { return }

            // Only fetch stats if already connected (don't auto-connect repeatedly)
            if networkManager.isConnected {
                // Fetch network stats (block height, difficulty, etc.)
                await networkManager.fetchNetworkStats()

                // Check for new blocks and scan them - but NOT if scan is already running
                if networkManager.chainHeight > networkManager.walletHeight &&
                   networkManager.chainHeight > 0 &&
                   !FilterScanner.isScanInProgress {
                    isRefreshing = true
                    do {
                        try await walletManager.refreshBalance()
                        // Reload transaction history after sync
                        loadTransactionHistory()
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
