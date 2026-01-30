import SwiftUI

#if os(macOS)

/// Main view for Full Node wallet.dat mode - System 7 themed
struct FullNodeWalletView: View {
    @EnvironmentObject var themeManager: ThemeManager
    @StateObject private var rpcWallet = RPCWalletOperations.shared

    @State private var selectedTab: WalletTab = .addresses
    @State private var isLoading = true
    @State private var errorMessage: String?

    @State private var zAddresses: [WalletAddress] = []
    @State private var tAddresses: [WalletAddress] = []
    @State private var totalBalance: (transparent: UInt64, private: UInt64, total: UInt64) = (0, 0, 0)
    @State private var syncStatus: (height: UInt64, synced: Bool) = (0, false)

    // FIX #286 v13: Detailed sync status
    @State private var detailedSync: RPCClient.DetailedSyncStatus? = nil
    @State private var syncPollingTask: Task<Void, Never>? = nil
    @State private var rpcUnavailableCount: Int = 0  // FIX #286 v14: Track consecutive RPC failures
    @State private var daemonBusyDetected: Bool = false  // FIX #286 v14: Daemon likely busy/rescanning
    // FIX #286 v15: Real rescan progress from debug.log
    @State private var debugLogRescanBlock: Int = 0
    @State private var debugLogRescanProgress: Double = 0
    @State private var debugLogLastUpdate: Date = Date.distantPast

    // FIX #286 v12: External rescan detection
    @State private var externalRescanDetected: Bool = false
    @State private var externalRescanProgress: Double = 0
    @State private var externalRescanDuration: Int = 0
    @State private var externalRescanSource: String = ""
    @State private var rescanCheckTask: Task<Void, Never>? = nil

    // FIX #286 v17: Pending transaction monitoring
    @State private var pendingOperations: [RPCClient.PendingOperation] = []
    @State private var pendingUnconfirmedBalance: (transparent: Double, private_: Double) = (0, 0)
    @State private var recentlyConfirmedTxid: String? = nil
    @State private var lastKnownTxids: Set<String> = []
    @State private var pendingTxMonitorTask: Task<Void, Never>? = nil

    @State private var showingSendSheet = false
    @State private var showingReceiveSheet = false
    @State private var showingHistorySheet = false

    // FIX #305: Prerequisites check state
    @State private var prerequisitesMissing = false
    @State private var prerequisitesMessage = ""

    private var theme: AppTheme { themeManager.currentTheme }

    // FIX #305: Check if Full Node prerequisites are met
    private func checkPrerequisites() -> (missing: Bool, message: String) {
        // Check 1: Is zclassicd installed?
        let daemonPaths = ["/usr/local/bin/zclassicd", "/opt/homebrew/bin/zclassicd"]
        let daemonInstalled = daemonPaths.contains { FileManager.default.fileExists(atPath: $0) }

        // Check 2: Is blockchain data present?
        let dataDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Zclassic")
        let blocksDir = dataDir.appendingPathComponent("blocks")
        let blockchainExists = FileManager.default.fileExists(atPath: blocksDir.path)

        // Check 3: Is zclassic.conf present?
        let configPath = dataDir.appendingPathComponent("zclassic.conf")
        let configExists = FileManager.default.fileExists(atPath: configPath.path)

        if !daemonInstalled {
            return (true, "Full Node daemon (zclassicd) is not installed.\n\nPlease install the Zclassic daemon first, or switch to ZipherX mode.")
        }

        if !blockchainExists {
            return (true, "Blockchain data not found.\n\nPlease switch to ZipherX mode → Settings → Install Bootstrap to download the blockchain, then return to wallet.dat mode.")
        }

        if !configExists {
            return (true, "Zclassic configuration file not found.\n\nPlease ensure zclassic.conf exists in ~/Library/Application Support/Zclassic/")
        }

        return (false, "")
    }

    // FIX #286 v13: Use blue instead of orange for better visibility
    private let statusBlue = Color(red: 0.2, green: 0.4, blue: 0.8)  // Readable blue color

    // FIX #286 v12: Enhanced sync status display with external rescan detection
    private var isRescanActive: Bool {
        (isImporting && importRescan) || externalRescanDetected
    }

    private var syncStatusText: String {
        // FIX #286 v14: Use detailed sync status when available
        if let sync = detailedSync {
            if sync.isRescanning {
                return "Rescanning..."
            } else if sync.isSyncing {
                return "Syncing..."
            }
        }

        // FIX #286 v14: Daemon busy (HTTP 500) - likely rescanning
        if daemonBusyDetected {
            return "Daemon Busy..."
        }

        if externalRescanDetected {
            return "Rescanning..."
        } else if isImporting && importRescan {
            return "Rescanning..."
        } else if isImporting {
            return "Importing..."
        } else if !syncStatus.synced {
            return "Syncing..."
        }
        return "Synced"
    }

    private var syncStatusColor: Color {
        // FIX #286 v14: Use detailed sync status when available
        if let sync = detailedSync {
            if sync.isRescanning || sync.isSyncing {
                return statusBlue
            }
        }

        // FIX #286 v14: Daemon busy
        if daemonBusyDetected {
            return statusBlue
        }

        if externalRescanDetected || (isImporting && importRescan) {
            return statusBlue
        } else if isImporting {
            return statusBlue
        } else if !syncStatus.synced {
            return statusBlue  // FIX #286 v13: Use blue instead of warning color
        }
        return theme.successColor
    }

    private var syncStatusTextColor: Color {
        // FIX #286 v14: Use detailed sync status when available
        if let sync = detailedSync, (sync.isRescanning || sync.isSyncing) {
            return statusBlue
        }
        // FIX #286 v14: Daemon busy
        if daemonBusyDetected {
            return statusBlue
        }
        if isImporting || externalRescanDetected || !syncStatus.synced {
            return statusBlue
        }
        return theme.textSecondary
    }

    // FIX #286 v12: Combined rescan progress (local or external)
    private var activeRescanProgress: Double {
        if isImporting && importRescan {
            return importProgress
        } else if externalRescanDetected {
            return externalRescanProgress
        }
        return 0
    }

    private var activeRescanDuration: Int {
        if isImporting && importRescan {
            return rescanElapsedSeconds
        } else if externalRescanDetected {
            return externalRescanDuration
        }
        return 0
    }

    // FIX #286 v5: Removed Settings from tabs - now uses gear icon in header
    enum WalletTab: String, CaseIterable {
        case addresses = "Addresses"
        case history = "History"
    }

    @State private var showingSettings = false

    var body: some View {
        VStack(spacing: 0) {
            // Menu bar
            System7MenuBar()

            // FIX #305: Prerequisites warning banner
            if prerequisitesMissing {
                prerequisitesWarningBanner
            }

            // Main content
            VStack(spacing: 0) {
                // Balance header
                balanceHeader

                // Tab bar
                tabBar

                // Content based on tab
                Group {
                    switch selectedTab {
                    case .addresses:
                        addressListContent
                    case .history:
                        transactionHistoryContent
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(theme.backgroundColor)
            .opacity(prerequisitesMissing ? 0.5 : 1.0)  // FIX #305: Dim content when prerequisites missing
            .disabled(prerequisitesMissing)  // FIX #305: Disable interactions when prerequisites missing

            // Footer with actions
            actionFooter
        }
        .background(theme.backgroundColor)
        .task {
            // FIX #305: Check prerequisites FIRST before loading wallet data
            let prereqCheck = checkPrerequisites()
            await MainActor.run {
                prerequisitesMissing = prereqCheck.missing
                prerequisitesMessage = prereqCheck.message
            }

            // Only load wallet data if prerequisites are met
            if !prereqCheck.missing {
                await loadWalletData()
                // FIX #286 v12: Check for external rescan on startup
                await checkExternalRescanStatus()
            }
        }
        .onAppear {
            // FIX #305: Recheck prerequisites on appear (in case user went to settings and came back)
            let prereqCheck = checkPrerequisites()
            prerequisitesMissing = prereqCheck.missing
            prerequisitesMessage = prereqCheck.message

            // FIX #286 v12: Start polling for external rescans
            if !prerequisitesMissing {
                startRescanStatusPolling()
                // FIX #286 v17: Start pending transaction monitoring
                startPendingTxMonitoring()
            }
        }
        .onDisappear {
            // FIX #286 v12: Stop polling when view disappears
            stopRescanStatusPolling()
            // FIX #286 v17: Stop pending TX monitoring
            stopPendingTxMonitoring()
        }
        .sheet(isPresented: $showingSendSheet) {
            RPCSendView(addresses: zAddresses + tAddresses, onSendSuccess: {
                // FIX #286 v17: Refresh wallet data after successful send
                Task {
                    print("📊 FIX #286 v17: Transaction sent - refreshing wallet data")
                    await loadWalletData()
                }
            })
            .environmentObject(themeManager)
        }
        .sheet(isPresented: $showingReceiveSheet) {
            receiveSheet
        }
        // FIX #286 v5: Settings sheet - now uses consolidated FullNodeSettingsView
        .sheet(isPresented: $showingSettings) {
            FullNodeSettingsView()
                .environmentObject(themeManager)
        }
    }

    // MARK: - Balance Header

    private var balanceHeader: some View {
        VStack(spacing: 8) {
            // Total balance
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Total Balance")
                        .font(theme.captionFont)
                        .foregroundColor(theme.textSecondary)

                    Text(formatBalance(totalBalance.total))
                        .font(.system(size: 28, weight: .bold, design: .monospaced))
                        .foregroundColor(theme.textPrimary)
                }

                Spacer()

                // FIX #286 v13: Enhanced sync status with detailed info
                VStack(alignment: .trailing, spacing: 4) {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(syncStatusColor)
                            .frame(width: 8, height: 8)
                        Text(syncStatusText)
                            .font(theme.captionFont)
                            .foregroundColor(syncStatusTextColor)
                    }
                    // FIX #286 v15: Show blocks/headers or debug.log progress
                    if let sync = detailedSync, sync.isSyncing || sync.isRescanning {
                        Text("\(sync.blocks)/\(sync.headers)")
                            .font(theme.monoFont)
                            .foregroundColor(statusBlue)
                    } else if daemonBusyDetected && debugLogRescanProgress > 0 {
                        // FIX #286 v15: Show real progress from debug.log
                        Text("\(Int(debugLogRescanProgress * 100))%")
                            .font(theme.monoFont)
                            .foregroundColor(statusBlue)
                    } else if daemonBusyDetected {
                        Text("Busy...")
                            .font(theme.monoFont)
                            .foregroundColor(statusBlue)
                    } else {
                        Text("Block \(syncStatus.height)")
                            .font(theme.monoFont)
                            .foregroundColor(theme.textSecondary)
                    }
                }

                // FIX #286 v5: Settings gear icon (like ZipherX mode)
                Button(action: { showingSettings = true }) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 20))
                        .foregroundColor(theme.primaryColor)
                }
                .buttonStyle(.plain)
                .padding(.leading, 8)
            }
            .padding()
            .background(theme.surfaceColor)
            .cornerRadius(theme.cornerRadius)

            // FIX #286 v12: Rescan progress banner (local import or external rescan)
            if isRescanActive {
                rescanProgressBanner
            }

            // FIX #286 v17: Pending transaction banner
            if hasPendingTransactions {
                pendingTransactionBanner
            }

            // FIX #286 v17: Recently confirmed transaction notification
            if let txid = recentlyConfirmedTxid {
                confirmedTransactionBanner(txid: txid)
            }

            // Balance breakdown
            HStack(spacing: 16) {
                balanceCard(title: "Shielded (Z)", amount: totalBalance.private, icon: "shield.fill")
                balanceCard(title: "Transparent (T)", amount: totalBalance.transparent, icon: "eye.fill")
            }
            .padding(.horizontal)
        }
        .padding()
        .background(theme.backgroundColor)
    }

    // FIX #305: Prerequisites warning banner
    private var prerequisitesWarningBanner: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 32))
                    .foregroundColor(.orange)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Full Node Not Ready")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.orange)

                    Text(prerequisitesMessage)
                        .font(theme.bodyFont)
                        .foregroundColor(theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()
            }

            // Action button to switch to ZipherX mode
            Button(action: {
                showingSettings = false
                WalletModeManager.shared.setWalletSource(.zipherx)
            }) {
                HStack {
                    Image(systemName: "arrow.left.circle.fill")
                    Text("Switch to ZipherX Mode")
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(theme.primaryColor)
                .cornerRadius(8)
            }
            .buttonStyle(.plain)
        }
        .padding()
        .background(Color.orange.opacity(0.15))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange, lineWidth: 2)
        )
        .cornerRadius(8)
        .padding()
    }

    // FIX #286 v12: Rescan progress banner for main view (local or external)
    private var rescanProgressBanner: some View {
        let progress = activeRescanProgress
        let duration = activeRescanDuration
        let sourceText = externalRescanDetected ? "External rescan detected" : "Rescan in Progress"
        let sourceDetail = externalRescanDetected
            ? "Started via CLI or another app"
            : "Wallet sync paused during rescan"

        return VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundColor(statusBlue)
                    .rotationEffect(.degrees(Double(duration % 360)))
                    .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: duration)

                VStack(alignment: .leading, spacing: 2) {
                    Text(sourceText)
                        .font(theme.captionFont)
                        .fontWeight(.semibold)
                        .foregroundColor(statusBlue)

                    Text(sourceDetail)
                        .font(.system(size: 10))
                        .foregroundColor(theme.textSecondary)
                }

                Spacer()

                // Progress percentage
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(statusBlue)
            }

            // Progress bar
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .accentColor(statusBlue)

            // Time info
            HStack {
                Text("Elapsed: \(formatDuration(duration))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(theme.textSecondary)

                Spacer()

                if progress > 0.15 {
                    let remaining = estimateRemainingTimeForProgress(progress, elapsed: duration)
                    Text("ETA: \(formatDuration(remaining))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(statusBlue)
                }
            }
        }
        .padding()
        .background(statusBlue.opacity(0.1))
        .cornerRadius(theme.cornerRadius)
        .overlay(
            RoundedRectangle(cornerRadius: theme.cornerRadius)
                .stroke(statusBlue.opacity(0.5), lineWidth: 1)
        )
        .padding(.horizontal)
    }

    // FIX #286 v17: Check if we have pending transactions
    // FIX #861: Only consider truly pending operations (not completed/failed)
    private var hasPendingTransactions: Bool {
        // Filter for operations that are still executing or queued (not success/failed)
        let trulyPendingOps = pendingOperations.filter { op in
            op.status == "executing" || op.status == "queued"
        }
        return !trulyPendingOps.isEmpty ||
        pendingUnconfirmedBalance.transparent != 0 ||
        pendingUnconfirmedBalance.private_ != 0
    }

    // FIX #861: Get only truly pending operations for display
    private var trulyPendingOperations: [RPCClient.PendingOperation] {
        pendingOperations.filter { op in
            op.status == "executing" || op.status == "queued"
        }
    }

    // FIX #286 v17: Pending transaction banner
    private var pendingTransactionBanner: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                // Animated spinner
                ProgressView()
                    .scaleEffect(0.8)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Transaction Pending")
                        .font(theme.captionFont)
                        .fontWeight(.semibold)
                        .foregroundColor(statusBlue)

                    // FIX #861: Use trulyPendingOperations instead of all operations
                    if !trulyPendingOperations.isEmpty {
                        let op = trulyPendingOperations.first!
                        Text("Operation: \(op.status)")
                            .font(.system(size: 10))
                            .foregroundColor(theme.textSecondary)
                    } else if pendingUnconfirmedBalance.transparent != 0 || pendingUnconfirmedBalance.private_ != 0 {
                        Text("Waiting for confirmation...")
                            .font(.system(size: 10))
                            .foregroundColor(theme.textSecondary)
                    }
                }

                Spacer()

                // Show pending balance change
                VStack(alignment: .trailing, spacing: 2) {
                    if pendingUnconfirmedBalance.private_ != 0 {
                        let sign = pendingUnconfirmedBalance.private_ > 0 ? "+" : ""
                        Text("\(sign)\(String(format: "%.8f", pendingUnconfirmedBalance.private_)) ZCL")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundColor(pendingUnconfirmedBalance.private_ > 0 ? theme.successColor : theme.errorColor)
                    }
                    if pendingUnconfirmedBalance.transparent != 0 {
                        let sign = pendingUnconfirmedBalance.transparent > 0 ? "+" : ""
                        Text("\(sign)\(String(format: "%.8f", pendingUnconfirmedBalance.transparent)) ZCL (T)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(pendingUnconfirmedBalance.transparent > 0 ? theme.successColor : theme.errorColor)
                    }
                }
            }
        }
        .padding()
        .background(statusBlue.opacity(0.1))
        .cornerRadius(theme.cornerRadius)
        .overlay(
            RoundedRectangle(cornerRadius: theme.cornerRadius)
                .stroke(statusBlue.opacity(0.5), lineWidth: 1)
        )
        .padding(.horizontal)
    }

    // FIX #286 v17: Recently confirmed transaction notification
    private func confirmedTransactionBanner(txid: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(theme.successColor)
                .font(.system(size: 20))

            VStack(alignment: .leading, spacing: 2) {
                Text("Transaction Confirmed!")
                    .font(theme.captionFont)
                    .fontWeight(.semibold)
                    .foregroundColor(theme.successColor)

                Text("TxID: \(txid.prefix(8))...\(txid.suffix(8))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(theme.textSecondary)
            }

            Spacer()

            Button(action: {
                recentlyConfirmedTxid = nil
            }) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(theme.textSecondary)
            }
            .buttonStyle(.plain)
        }
        .padding()
        .background(theme.successColor.opacity(0.1))
        .cornerRadius(theme.cornerRadius)
        .overlay(
            RoundedRectangle(cornerRadius: theme.cornerRadius)
                .stroke(theme.successColor.opacity(0.5), lineWidth: 1)
        )
        .padding(.horizontal)
        .onAppear {
            // Auto-dismiss after 10 seconds
            Task {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                await MainActor.run {
                    if recentlyConfirmedTxid == txid {
                        recentlyConfirmedTxid = nil
                    }
                }
            }
        }
    }

    private func balanceCard(title: String, amount: UInt64, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(theme.primaryColor)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(theme.captionFont)
                    .foregroundColor(theme.textSecondary)
                Text(formatBalance(amount))
                    .font(theme.monoFont)
                    .foregroundColor(theme.textPrimary)
            }

            Spacer()
        }
        .padding(12)
        .background(theme.surfaceColor)
        .cornerRadius(theme.cornerRadius)
        .overlay(
            RoundedRectangle(cornerRadius: theme.cornerRadius)
                .stroke(theme.borderColor, lineWidth: theme.borderWidth)
        )
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(WalletTab.allCases, id: \.self) { tab in
                System7TabButton(
                    title: tab.rawValue,
                    isSelected: selectedTab == tab
                ) {
                    selectedTab = tab
                }
            }
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(theme.surfaceColor)
        .overlay(
            Rectangle()
                .frame(height: theme.borderWidth)
                .foregroundColor(theme.borderColor),
            alignment: .bottom
        )
    }

    // MARK: - Address List

    // FIX #286 v8: Filter out 0 balance addresses by default
    @State private var showEmptyAddresses = false

    private var addressListContent: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Toggle for showing empty addresses
                HStack {
                    Spacer()
                    Toggle("Show empty addresses", isOn: $showEmptyAddresses)
                        .font(theme.captionFont)
                        .toggleStyle(.checkbox)
                }

                // Z-Addresses section (filtered)
                let filteredZ = showEmptyAddresses ? zAddresses : zAddresses.filter { $0.balance > 0 }
                addressSection(title: "Shielded Addresses (Z)", addresses: filteredZ, isShielded: true, totalCount: zAddresses.count)

                // T-Addresses section (filtered)
                let filteredT = showEmptyAddresses ? tAddresses : tAddresses.filter { $0.balance > 0 }
                addressSection(title: "Transparent Addresses (T)", addresses: filteredT, isShielded: false, totalCount: tAddresses.count)
            }
            .padding()
        }
    }

    private func addressSection(title: String, addresses: [WalletAddress], isShielded: Bool, totalCount: Int = 0) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                // FIX #286 v8: Show count of addresses with balance / total
                Text(title)
                    .font(theme.titleFont)
                    .foregroundColor(theme.textPrimary)

                if !showEmptyAddresses && totalCount > addresses.count {
                    Text("(\(addresses.count)/\(totalCount))")
                        .font(theme.captionFont)
                        .foregroundColor(theme.textSecondary)
                }

                Spacer()

                Button(action: {
                    Task {
                        await createAddress(shielded: isShielded)
                    }
                }) {
                    Label("New", systemImage: "plus.circle")
                        .font(theme.bodyFont)
                        .foregroundColor(theme.primaryColor)
                }
                .buttonStyle(.plain)
            }

            if addresses.isEmpty && totalCount == 0 {
                Text("No addresses yet")
                    .font(theme.bodyFont)
                    .foregroundColor(theme.textSecondary)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(theme.surfaceColor)
                    .cornerRadius(theme.cornerRadius)
            } else if addresses.isEmpty {
                Text("No addresses with balance")
                    .font(theme.bodyFont)
                    .foregroundColor(theme.textSecondary)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(theme.surfaceColor)
                    .cornerRadius(theme.cornerRadius)
            } else {
                ForEach(addresses) { address in
                    addressRow(address)
                }
            }
        }
    }

    private func addressRow(_ address: WalletAddress) -> some View {
        HStack {
            // Address type icon
            Image(systemName: address.isShielded ? "shield.fill" : "eye.fill")
                .foregroundColor(theme.primaryColor)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 4) {
                Text(truncateAddress(address.address))
                    .font(theme.monoFont)
                    .foregroundColor(theme.textPrimary)
                    .textSelection(.enabled)

                Text(formatBalance(address.balance))
                    .font(theme.captionFont)
                    .foregroundColor(theme.textSecondary)
            }

            Spacer()

            // Copy button
            Button {
                copyToClipboard(address.address)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 14))
                    .foregroundColor(theme.primaryColor)
                    .padding(8)
                    .background(theme.backgroundColor)
                    .cornerRadius(4)
            }
            .buttonStyle(PlainButtonStyle())
            .help("Copy address to clipboard")
        }
        .padding()
        .background(theme.surfaceColor)
        .cornerRadius(theme.cornerRadius)
        .overlay(
            RoundedRectangle(cornerRadius: theme.cornerRadius)
                .stroke(theme.borderColor, lineWidth: theme.borderWidth)
        )
    }

    // MARK: - Transaction History

    private var transactionHistoryContent: some View {
        RPCTransactionHistoryView()
            .environmentObject(themeManager)
    }

    // MARK: - Settings

    // FIX #286 v5: Settings as a sheet instead of a tab
    private var settingsSheet: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Settings")
                    .font(theme.titleFont)
                    .foregroundColor(theme.textPrimary)

                Spacer()

                Button("Done") {
                    showingSettings = false
                }
                .buttonStyle(.plain)
                .foregroundColor(theme.primaryColor)
            }
            .padding()
            .background(theme.surfaceColor)

            Divider()
                .background(theme.borderColor)

            // Settings content
            ScrollView {
                VStack(spacing: 16) {
                    // Wallet info
                    settingsCard(title: "Wallet Mode") {
                        HStack {
                            Image(systemName: "externaldrive.fill")
                                .foregroundColor(theme.primaryColor)
                            Text("Full Node wallet.dat")
                                .font(theme.bodyFont)
                                .foregroundColor(theme.textPrimary)
                            Spacer()
                        }
                    }

                    // Switch to ZipherX wallet
                    settingsCard(title: "Switch Wallet") {
                        Button(action: {
                            showingSettings = false
                            WalletModeManager.shared.setWalletSource(.zipherx)
                        }) {
                            HStack {
                                Image(systemName: "arrow.left.circle")
                                Text("Switch to ZipherX Wallet")
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundColor(theme.textSecondary)
                            }
                            .font(theme.bodyFont)
                            .foregroundColor(theme.primaryColor)
                        }
                        .buttonStyle(.plain)
                    }

                    // Refresh
                    settingsCard(title: "Wallet Actions") {
                        Button(action: {
                            Task {
                                await loadWalletData()
                            }
                        }) {
                            HStack {
                                Image(systemName: "arrow.clockwise")
                                Text("Refresh Wallet Data")
                                Spacer()
                            }
                            .font(theme.bodyFont)
                            .foregroundColor(theme.primaryColor)
                        }
                        .buttonStyle(.plain)
                    }

                    // FIX #286 v8: Danger Zone for Import/Export Private Keys
                    dangerZoneCard
                }
                .padding()
            }
        }
        .frame(minWidth: 400, minHeight: 300)
        .background(theme.backgroundColor)
        .sheet(isPresented: $showingExportPK) {
            exportPrivateKeySheet
        }
        .sheet(isPresented: $showingImportPK) {
            importPrivateKeySheet
        }
    }

    // FIX #286 v8: State for Danger Zone
    @State private var showingExportPK = false
    @State private var showingImportPK = false
    @State private var selectedExportAddress: WalletAddress?
    @State private var exportedPrivateKey: String = ""
    @State private var importPrivateKey: String = ""
    @State private var importRescan: Bool = true
    @State private var isExporting = false
    @State private var isImporting = false
    @State private var importExportError: String?
    @State private var importSuccess: String?

    // Addresses with balance > 0 for export
    private var addressesWithBalance: [WalletAddress] {
        (zAddresses + tAddresses).filter { $0.balance > 0 }.sorted { $0.balance > $1.balance }
    }

    // FIX #286 v9: Darker red color for better visibility
    private let dangerRed = Color(red: 0.8, green: 0.1, blue: 0.1)

    private var dangerZoneCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(dangerRed)
                Text("Danger Zone")
                    .font(theme.titleFont)
                    .foregroundColor(dangerRed)
            }

            VStack(spacing: 12) {
                // Export Private Key
                Button(action: { showingExportPK = true }) {
                    HStack {
                        Image(systemName: "key.fill")
                        Text("Export Private Key")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundColor(theme.textSecondary)
                    }
                    .font(theme.bodyFont)
                    .foregroundColor(dangerRed)  // FIX #286 v9: Use darker red instead of orange
                }
                .buttonStyle(.plain)

                Divider()

                // Import Private Key
                Button(action: { showingImportPK = true }) {
                    HStack {
                        Image(systemName: "square.and.arrow.down")
                        Text("Import Private Key")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundColor(theme.textSecondary)
                    }
                    .font(theme.bodyFont)
                    .foregroundColor(dangerRed)  // FIX #286 v9: Use darker red instead of orange
                }
                .buttonStyle(.plain)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(dangerRed.opacity(0.05))
            .cornerRadius(theme.cornerRadius)
            .overlay(
                RoundedRectangle(cornerRadius: theme.cornerRadius)
                    .stroke(dangerRed.opacity(0.3), lineWidth: theme.borderWidth)
            )
        }
    }

    // MARK: - Export Private Key Sheet

    private var exportPrivateKeySheet: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Export Private Key")
                    .font(theme.titleFont)
                    .foregroundColor(theme.textPrimary)
                Spacer()
                Button("Close") {
                    showingExportPK = false
                    exportedPrivateKey = ""
                    selectedExportAddress = nil
                }
                .buttonStyle(.plain)
                .foregroundColor(theme.primaryColor)
            }
            .padding()
            .background(theme.surfaceColor)

            Divider()

            ScrollView {
                VStack(spacing: 16) {
                    // Warning - FIX #286 v9: Use darker red
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(dangerRed)
                        Text("Never share your private key with anyone!")
                            .font(theme.bodyFont)
                            .foregroundColor(dangerRed)
                    }
                    .padding()
                    .background(dangerRed.opacity(0.1))
                    .cornerRadius(8)

                    // Address selection
                    Text("Select address to export:")
                        .font(theme.bodyFont)
                        .foregroundColor(theme.textPrimary)

                    ForEach(addressesWithBalance) { address in
                        Button(action: { selectedExportAddress = address }) {
                            HStack {
                                Image(systemName: address.isShielded ? "shield.fill" : "eye.fill")
                                    .foregroundColor(address.isShielded ? theme.primaryColor : dangerRed)
                                VStack(alignment: .leading) {
                                    // FIX #286 v9: Use black font color for addresses
                                    Text(truncateAddress(address.address))
                                        .font(theme.monoFont)
                                        .foregroundColor(.black)
                                    Text(formatBalance(address.balance))
                                        .font(theme.captionFont)
                                        .foregroundColor(.gray)
                                }
                                Spacer()
                                if selectedExportAddress?.id == address.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(theme.successColor)
                                }
                            }
                            .padding()
                            .background(selectedExportAddress?.id == address.id ? theme.primaryColor.opacity(0.1) : theme.surfaceColor)
                            .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                    }

                    if addressesWithBalance.isEmpty {
                        Text("No addresses with balance to export")
                            .font(theme.bodyFont)
                            .foregroundColor(theme.textSecondary)
                    }

                    // Export button - FIX #286 v9: Use darker red
                    if selectedExportAddress != nil {
                        Button(action: { Task { await exportPrivateKey() } }) {
                            HStack {
                                if isExporting {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                }
                                Text("Export Private Key")
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(dangerRed)
                            .foregroundColor(.white)
                            .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                        .disabled(isExporting)
                    }

                    // Exported key display
                    if !exportedPrivateKey.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Private Key:")
                                .font(theme.captionFont)
                                .foregroundColor(theme.textSecondary)

                            Text(exportedPrivateKey)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(theme.textPrimary)
                                .padding()
                                .background(theme.surfaceColor)
                                .cornerRadius(4)
                                .textSelection(.enabled)

                            Button(action: { copyToClipboard(exportedPrivateKey) }) {
                                Label("Copy to Clipboard", systemImage: "doc.on.doc")
                            }
                            .buttonStyle(System7ButtonStyle())
                        }
                    }

                    if let error = importExportError {
                        Text(error)
                            .font(theme.bodyFont)
                            .foregroundColor(.red)
                    }
                }
                .padding()
            }
        }
        .frame(minWidth: 450, minHeight: 400)
        .background(theme.backgroundColor)
    }

    // MARK: - Import Private Key Sheet

    // FIX #286 v9: Import progress tracking
    @State private var importProgress: Double = 0
    @State private var importStatusMessage: String = ""
    // FIX #286 v11: Enhanced rescan tracking with ETA
    @State private var rescanStartTime: Date? = nil
    @State private var rescanElapsedSeconds: Int = 0
    @State private var rescanEstimatedTotalSeconds: Int = 7200  // Default 2 hours estimate

    // FIX #286 v9: Validate private key format
    private var isValidPrivateKey: Bool {
        let key = importPrivateKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return false }

        // Z-address spending key (starts with "secret-extended-key")
        if key.hasPrefix("secret-extended-key") {
            return key.count > 50
        }

        // T-address WIF private key (starts with 5, K, or L for mainnet)
        if key.hasPrefix("5") || key.hasPrefix("K") || key.hasPrefix("L") {
            return key.count >= 51 && key.count <= 52
        }

        return false
    }

    private var keyTypeDescription: String {
        let key = importPrivateKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty { return "" }

        if key.hasPrefix("secret-extended-key") {
            return "✅ Z-address (shielded) spending key detected"
        } else if key.hasPrefix("5") || key.hasPrefix("K") || key.hasPrefix("L") {
            return "✅ T-address (transparent) private key detected"
        } else {
            return "❌ Invalid key format. Z-keys start with 'secret-extended-key', T-keys start with '5', 'K', or 'L'"
        }
    }

    private var importPrivateKeySheet: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Import Private Key")
                    .font(theme.titleFont)
                    .foregroundColor(theme.textPrimary)
                Spacer()
                Button("Close") {
                    showingImportPK = false
                    importPrivateKey = ""
                    importSuccess = nil
                    importExportError = nil
                    importProgress = 0
                    importStatusMessage = ""
                }
                .buttonStyle(.plain)
                .foregroundColor(theme.primaryColor)
                .disabled(isImporting)
            }
            .padding()
            .background(theme.surfaceColor)

            Divider()

            ScrollView {
                VStack(spacing: 16) {
                    // Info
                    HStack {
                        Image(systemName: "info.circle.fill")
                            .foregroundColor(theme.primaryColor)
                        Text("Import a Z or T private key")
                            .font(theme.bodyFont)
                            .foregroundColor(theme.textPrimary)
                    }
                    .padding()
                    .background(theme.primaryColor.opacity(0.1))
                    .cornerRadius(8)

                    // Private key input
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Private Key:")
                            .font(theme.captionFont)
                            .foregroundColor(theme.textSecondary)

                        TextEditor(text: $importPrivateKey)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(height: 80)
                            .padding(4)
                            .background(theme.surfaceColor)
                            .cornerRadius(4)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(isValidPrivateKey ? Color.green : (importPrivateKey.isEmpty ? theme.borderColor : Color.red), lineWidth: 1)
                            )
                            .disabled(isImporting)

                        // FIX #286 v9: Key validation feedback
                        if !importPrivateKey.isEmpty {
                            Text(keyTypeDescription)
                                .font(theme.captionFont)
                                .foregroundColor(isValidPrivateKey ? .green : .red)
                        }
                    }

                    // Rescan option
                    Toggle("Rescan blockchain (required to find transactions)", isOn: $importRescan)
                        .font(theme.bodyFont)
                        .toggleStyle(.checkbox)
                        .disabled(isImporting)

                    if importRescan {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(statusBlue)
                            Text("Rescan can take several hours depending on blockchain size")
                                .font(theme.captionFont)
                                .foregroundColor(statusBlue)
                        }
                    }

                    // FIX #286 v11: Enhanced progress display during import/rescan
                    if isImporting {
                        VStack(spacing: 12) {
                            // Progress bar with percentage
                            VStack(spacing: 4) {
                                HStack {
                                    Text("Progress")
                                        .font(theme.captionFont)
                                        .foregroundColor(theme.textSecondary)
                                    Spacer()
                                    Text("\(Int(importProgress * 100))%")
                                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                                        .foregroundColor(theme.primaryColor)
                                }

                                ProgressView(value: importProgress)
                                    .progressViewStyle(.linear)
                                    .accentColor(theme.primaryColor)
                            }

                            // Status message
                            HStack {
                                if importRescan && importProgress > 0.1 {
                                    Image(systemName: "arrow.triangle.2.circlepath")
                                        .foregroundColor(statusBlue)
                                }
                                Text(importStatusMessage)
                                    .font(theme.captionFont)
                                    .foregroundColor(theme.textSecondary)
                                Spacer()
                            }

                            // FIX #286 v11: ETA display for rescan
                            if importRescan && rescanElapsedSeconds > 10 {
                                Divider()

                                VStack(spacing: 8) {
                                    // Elapsed time
                                    HStack {
                                        Text("Elapsed:")
                                            .font(theme.captionFont)
                                            .foregroundColor(theme.textSecondary)
                                        Spacer()
                                        Text(formatDuration(rescanElapsedSeconds))
                                            .font(.system(size: 12, design: .monospaced))
                                            .foregroundColor(theme.textPrimary)
                                    }

                                    // Estimated remaining time
                                    if importProgress > 0.15 {
                                        let remaining = estimateRemainingTime()
                                        HStack {
                                            Text("Estimated remaining:")
                                                .font(theme.captionFont)
                                                .foregroundColor(theme.textSecondary)
                                            Spacer()
                                            Text(formatDuration(remaining))
                                                .font(.system(size: 12, design: .monospaced))
                                                .foregroundColor(statusBlue)
                                        }
                                    }
                                }

                                // Warning about sync waiting
                                HStack(spacing: 6) {
                                    Image(systemName: "clock.badge.exclamationmark")
                                        .foregroundColor(statusBlue)
                                    Text("Wallet sync is paused during rescan")
                                        .font(.system(size: 10))
                                        .foregroundColor(statusBlue)
                                }
                                .padding(.top, 4)
                            }
                        }
                        .padding()
                        .background(theme.surfaceColor)
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(importRescan ? statusBlue.opacity(0.5) : theme.borderColor, lineWidth: 1)
                        )
                    }

                    // Import button - FIX #286 v9: Only enable if key is valid
                    Button(action: { Task { await importKey() } }) {
                        HStack {
                            if isImporting {
                                ProgressView()
                                    .scaleEffect(0.8)
                            }
                            Text(isImporting ? "Importing..." : "Import Private Key")
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(!isValidPrivateKey || isImporting ? Color.gray : theme.primaryColor)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                    .disabled(!isValidPrivateKey || isImporting)

                    if let success = importSuccess {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text(success)
                                .font(theme.bodyFont)
                                .foregroundColor(.green)
                        }
                    }

                    if let error = importExportError {
                        HStack {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.red)
                            Text(error)
                                .font(theme.bodyFont)
                                .foregroundColor(.red)
                        }
                    }
                }
                .padding()
            }
        }
        .frame(minWidth: 450, minHeight: 400)
        .background(theme.backgroundColor)
    }

    // MARK: - Import/Export Actions

    private func exportPrivateKey() async {
        guard let address = selectedExportAddress else { return }

        await MainActor.run {
            isExporting = true
            importExportError = nil
            exportedPrivateKey = ""
        }

        do {
            let pk = try await RPCClient.shared.exportPrivateKey(address.address)
            await MainActor.run {
                exportedPrivateKey = pk
                isExporting = false
            }
        } catch {
            await MainActor.run {
                importExportError = error.localizedDescription
                isExporting = false
            }
        }
    }

    private func importKey() async {
        let key = importPrivateKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }

        // FIX #286 v11: Track rescan start time
        let startTime = Date()

        await MainActor.run {
            isImporting = true
            importExportError = nil
            importSuccess = nil
            importProgress = 0
            importStatusMessage = "Starting import..."
            rescanStartTime = startTime
            rescanElapsedSeconds = 0
        }

        // FIX #286 v11: Start timer to update elapsed time every second
        let timerTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)  // 1 second
                await MainActor.run {
                    if isImporting, let start = rescanStartTime {
                        rescanElapsedSeconds = Int(Date().timeIntervalSince(start))
                    }
                }
            }
        }

        do {
            // FIX #286 v9: Use progress callback for import with rescan
            let address = try await RPCClient.shared.importPrivateKey(key, rescan: importRescan) { progress, message in
                Task { @MainActor in
                    self.importProgress = progress
                    self.importStatusMessage = message
                }
            }

            // Stop the timer
            timerTask.cancel()

            await MainActor.run {
                importSuccess = "Imported: \(address)"
                importPrivateKey = ""
                isImporting = false
                importProgress = 1.0
                importStatusMessage = "Import complete!"
                rescanStartTime = nil
            }
            // Reload wallet data
            await loadWalletData()
        } catch {
            // Stop the timer
            timerTask.cancel()

            await MainActor.run {
                importExportError = error.localizedDescription
                isImporting = false
                importProgress = 0
                importStatusMessage = ""
                rescanStartTime = nil
                rescanElapsedSeconds = 0
            }
        }
    }

    private func settingsCard(title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(theme.captionFont)
                .foregroundColor(theme.textSecondary)

            content()
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.surfaceColor)
                .cornerRadius(theme.cornerRadius)
                .overlay(
                    RoundedRectangle(cornerRadius: theme.cornerRadius)
                        .stroke(theme.borderColor, lineWidth: theme.borderWidth)
                )
        }
    }

    // MARK: - Action Footer

    // FIX #286 v14: Disable actions during sync/rescan (including daemon busy)
    private var actionsDisabled: Bool {
        // Check detailed sync status first (more accurate)
        if let sync = detailedSync, (sync.isSyncing || sync.isRescanning) {
            return true
        }
        // FIX #286 v14: Daemon busy (HTTP 500) means likely rescanning
        if daemonBusyDetected {
            return true
        }
        return isImporting || !syncStatus.synced || isLoading || externalRescanDetected
    }

    private var actionFooter: some View {
        VStack(spacing: 0) {
            // FIX #286 v14: Show detailed sync status or daemon busy indicator
            if let sync = detailedSync, (sync.isSyncing || sync.isRescanning || actionsDisabled) && !isLoading {
                detailedSyncStatusBar(sync)
            } else if daemonBusyDetected && !isLoading {
                // FIX #286 v14: Daemon is busy (HTTP 500) - show rescan indicator
                daemonBusyStatusBar
            } else if actionsDisabled && !isLoading {
                // Fallback to simple message if detailed sync not available
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(statusBlue)
                    Text(actionsDisabledReason)
                        .font(.system(size: 10))
                        .foregroundColor(statusBlue)
                }
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .background(statusBlue.opacity(0.1))
            }

            HStack(spacing: 16) {
                Spacer()

                Button(action: { showingReceiveSheet = true }) {
                    Label("Receive", systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(System7ButtonStyle())
                .disabled(actionsDisabled)
                .opacity(actionsDisabled ? 0.5 : 1.0)

                Button(action: { showingSendSheet = true }) {
                    Label("Send", systemImage: "arrow.up.circle.fill")
                }
                .buttonStyle(System7ButtonStyle())
                .disabled(actionsDisabled)
                .opacity(actionsDisabled ? 0.5 : 1.0)

                Spacer()
            }
            .padding()
            .background(theme.surfaceColor)
            .overlay(
                Rectangle()
                    .frame(height: theme.borderWidth)
                    .foregroundColor(theme.borderColor),
                alignment: .top
            )
        }
    }

    // FIX #286 v13: Detailed sync status bar with progress and ETA
    private func detailedSyncStatusBar(_ sync: RPCClient.DetailedSyncStatus) -> some View {
        VStack(spacing: 8) {
            // Top row: Status message and connections
            HStack {
                // Icon based on status
                if sync.isRescanning {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .foregroundColor(statusBlue)
                } else if sync.isSyncing {
                    Image(systemName: "arrow.down.circle")
                        .foregroundColor(statusBlue)
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(theme.successColor)
                }

                Text(sync.statusMessage)
                    .font(theme.captionFont)
                    .foregroundColor(sync.isSyncing || sync.isRescanning ? statusBlue : theme.textPrimary)

                Spacer()

                // Connections indicator
                HStack(spacing: 4) {
                    Image(systemName: "network")
                        .font(.system(size: 10))
                    Text("\(sync.connections) peers")
                        .font(.system(size: 10))
                }
                .foregroundColor(sync.connections > 0 ? theme.textSecondary : theme.errorColor)
            }

            // Progress bar (only show when syncing or rescanning)
            if sync.isSyncing || sync.isRescanning {
                VStack(spacing: 4) {
                    // Progress bar
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            // Background
                            RoundedRectangle(cornerRadius: 4)
                                .fill(theme.borderColor)
                                .frame(height: 8)

                            // Progress fill
                            RoundedRectangle(cornerRadius: 4)
                                .fill(statusBlue)
                                .frame(width: max(0, geometry.size.width * sync.progress), height: 8)
                        }
                    }
                    .frame(height: 8)

                    // Block info row
                    HStack {
                        // Block numbers
                        if sync.isRescanning {
                            Text("Block \(sync.rescanBlock) / \(sync.headers)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(theme.textSecondary)
                        } else {
                            Text("Block \(sync.blocks) / \(sync.headers)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(theme.textSecondary)
                        }

                        Spacer()

                        // Percentage
                        Text("\(Int(sync.progress * 100))%")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(statusBlue)

                        // ETA estimate (if progress > 15%)
                        if sync.progress > 0.15 {
                            Text("•")
                                .foregroundColor(theme.textSecondary)

                            let blocksRemaining = sync.headers - (sync.isRescanning ? sync.rescanBlock : sync.blocks)
                            // Rough estimate: ~100 blocks per minute for sync, ~50 for rescan
                            let blocksPerMin = sync.isRescanning ? 50 : 100
                            let etaMins = max(1, blocksRemaining / blocksPerMin)
                            let etaStr = etaMins >= 60 ? "\(etaMins / 60)h \(etaMins % 60)m" : "\(etaMins)m"

                            Text("ETA: \(etaStr)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(statusBlue)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(statusBlue.opacity(0.08))
    }

    // FIX #286 v16: Daemon busy status bar with known 65% bug warning
    private var daemonBusyStatusBar: some View {
        // Check if we have real progress from debug.log (updated within last 2 minutes)
        let hasRealProgress = debugLogRescanProgress > 0 && debugLogLastUpdate.timeIntervalSinceNow > -120
        // FIX #286 v16: Progress stalled (was tracking but stopped updating)
        let progressStalled = debugLogRescanProgress >= 0.60 && debugLogLastUpdate.timeIntervalSinceNow < -120
        // Time since progress stopped updating
        let stalledMinutes = progressStalled ? Int(-debugLogLastUpdate.timeIntervalSinceNow / 60) : 0

        return VStack(spacing: 8) {
            // Top row: Status message
            HStack {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundColor(statusBlue)

                VStack(alignment: .leading, spacing: 2) {
                    if progressStalled {
                        // FIX #286 v16: Progress stalled at ~65% (known bug)
                        Text("Finishing Rescan...")
                            .font(theme.captionFont)
                            .fontWeight(.semibold)
                            .foregroundColor(statusBlue)
                    } else if hasRealProgress {
                        Text("Rescanning Blockchain")
                            .font(theme.captionFont)
                            .fontWeight(.semibold)
                            .foregroundColor(statusBlue)
                    } else {
                        Text("Daemon Busy - Likely Rescanning")
                            .font(theme.captionFont)
                            .fontWeight(.semibold)
                            .foregroundColor(statusBlue)
                    }

                    Text("RPC unavailable - wallet operations paused")
                        .font(.system(size: 10))
                        .foregroundColor(theme.textSecondary)
                }

                Spacer()

                // FIX #286 v16: Show percentage or "Finishing" indicator
                if progressStalled {
                    Text("~\(stalledMinutes)m")
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundColor(statusBlue)
                } else if hasRealProgress {
                    Text("\(Int(debugLogRescanProgress * 100))%")
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundColor(statusBlue)
                } else {
                    Text("\(rpcUnavailableCount)x")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(statusBlue)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(statusBlue.opacity(0.2))
                        .cornerRadius(4)
                }
            }

            // FIX #286 v16: Warning about known 65% bug
            if hasRealProgress && debugLogRescanProgress >= 0.58 && !progressStalled {
                HStack(spacing: 4) {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(theme.warningColor)
                    Text("Known Zclassic bug: Progress display stops at ~65% but rescan continues")
                        .font(.system(size: 9))
                        .foregroundColor(theme.warningColor)
                }
            }

            // Progress bar
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // Background
                    RoundedRectangle(cornerRadius: 4)
                        .fill(theme.borderColor)
                        .frame(height: 8)

                    // FIX #286 v16: Progress bar with stalled state
                    if progressStalled {
                        // Indeterminate "finishing" animation
                        RoundedRectangle(cornerRadius: 4)
                            .fill(statusBlue.opacity(0.5))
                            .frame(width: geometry.size.width * 0.65, height: 8)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(statusBlue)
                            .frame(width: geometry.size.width * 0.15, height: 8)
                            .offset(x: geometry.size.width * 0.65 + geometry.size.width * 0.1 * CGFloat(stalledMinutes % 3))
                    } else if hasRealProgress {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(statusBlue)
                            .frame(width: max(0, geometry.size.width * debugLogRescanProgress), height: 8)
                    } else {
                        // Indeterminate animation
                        RoundedRectangle(cornerRadius: 4)
                            .fill(statusBlue)
                            .frame(width: geometry.size.width * 0.3, height: 8)
                            .offset(x: geometry.size.width * CGFloat(rpcUnavailableCount % 3) * 0.35)
                    }
                }
            }
            .frame(height: 8)

            // Block info row
            HStack {
                if progressStalled {
                    // FIX #286 v16: Show elapsed time since progress stalled
                    Text("Last reported: Block \(debugLogRescanBlock.formatted()) (\(Int(debugLogRescanProgress * 100))%)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(theme.textSecondary)

                    Spacer()

                    // Estimate: ~35% remaining takes ~same time as first 65%
                    // So if we're at 65% after X minutes of stall, ETA ~= X * (35/elapsed_since_stall)
                    let estimatedRemainingMins = max(0, 30 - stalledMinutes)  // Rough estimate: ~30 more minutes after stall
                    if estimatedRemainingMins > 0 {
                        Text("ETA: ~\(estimatedRemainingMins)m")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(statusBlue)
                    } else {
                        Text("Almost done...")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(statusBlue)
                    }
                } else if hasRealProgress {
                    Text("Block \(debugLogRescanBlock.formatted())")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(theme.textSecondary)

                    Spacer()

                    // ETA estimate based on progress
                    if debugLogRescanProgress > 0.1 {
                        let remaining = (1.0 - debugLogRescanProgress) / debugLogRescanProgress
                        // Assume ~1 hour elapsed per 10% (rough estimate based on log pattern)
                        let etaMins = Int(remaining * 60)
                        let etaStr = etaMins >= 60 ? "\(etaMins / 60)h \(etaMins % 60)m" : "\(etaMins)m"
                        Text("ETA: ~\(etaStr)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(statusBlue)
                    }
                } else {
                    Text("Rescan may take several hours")
                        .font(.system(size: 10))
                        .foregroundColor(theme.textSecondary)

                    Spacer()

                    Text("Checking debug.log...")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(statusBlue)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(statusBlue.opacity(0.08))
    }

    // FIX #286 v14: Reason why actions are disabled (with detailed sync info)
    private var actionsDisabledReason: String {
        // Use detailed sync message if available
        if let sync = detailedSync {
            if sync.isRescanning {
                return sync.statusMessage
            } else if sync.isSyncing {
                return sync.statusMessage
            }
        }

        // FIX #286 v14: Daemon busy (HTTP 500)
        if daemonBusyDetected {
            return "Daemon busy (likely rescanning) - RPC unavailable"
        }

        if externalRescanDetected {
            return "External rescan in progress - please wait (\(Int(externalRescanProgress * 100))%)"
        } else if isImporting && importRescan {
            return "Rescan in progress - please wait"
        } else if isImporting {
            return "Import in progress - please wait"
        } else if !syncStatus.synced {
            return "Wallet syncing - please wait for sync to complete"
        } else if isLoading {
            return "Loading wallet data..."
        }
        return ""
    }

    // MARK: - Receive Sheet

    private var receiveSheet: some View {
        VStack(spacing: 16) {
            Text("Receive Address")
                .font(theme.titleFont)
                .foregroundColor(theme.textPrimary)

            if let firstZ = zAddresses.first {
                VStack(spacing: 8) {
                    Text("Shielded Address (Z)")
                        .font(theme.captionFont)
                        .foregroundColor(theme.textSecondary)

                    Text(firstZ.address)
                        .font(theme.monoFont)
                        .foregroundColor(theme.textPrimary)
                        .padding()
                        .background(theme.surfaceColor)
                        .cornerRadius(theme.cornerRadius)
                        .textSelection(.enabled)

                    Button("Copy") {
                        copyToClipboard(firstZ.address)
                    }
                    .buttonStyle(System7ButtonStyle())
                }
            }

            if let firstT = tAddresses.first {
                VStack(spacing: 8) {
                    Text("Transparent Address (T)")
                        .font(theme.captionFont)
                        .foregroundColor(theme.textSecondary)

                    Text(firstT.address)
                        .font(theme.monoFont)
                        .foregroundColor(theme.textPrimary)
                        .padding()
                        .background(theme.surfaceColor)
                        .cornerRadius(theme.cornerRadius)
                        .textSelection(.enabled)

                    Button("Copy") {
                        copyToClipboard(firstT.address)
                    }
                    .buttonStyle(System7ButtonStyle())
                }
            }

            Spacer()

            Button("Done") {
                showingReceiveSheet = false
            }
            .buttonStyle(System7ButtonStyle())
        }
        .padding()
        .frame(minWidth: 400, minHeight: 300)
        .background(theme.backgroundColor)
    }

    // MARK: - Helpers

    private func loadWalletData() async {
        isLoading = true
        errorMessage = nil

        do {
            try await rpcWallet.connect()

            async let z = rpcWallet.listZAddresses()
            async let t = rpcWallet.listTAddresses()
            async let balance = rpcWallet.getTotalBalance()
            async let status = rpcWallet.getSyncStatus()

            let (zResult, tResult, balanceResult, statusResult) = try await (z, t, balance, status)

            await MainActor.run {
                zAddresses = zResult
                tAddresses = tResult
                totalBalance = balanceResult
                syncStatus = statusResult
                isLoading = false
            }
        } catch {
            print("❌ FIX #286 v3: FullNodeWalletView error: \(error.localizedDescription)")
            await MainActor.run {
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }

    private func createAddress(shielded: Bool) async {
        do {
            if shielded {
                let address = try await rpcWallet.createZAddress()
                print("Created z-address: \(address)")
            } else {
                let address = try await rpcWallet.createTAddress()
                print("Created t-address: \(address)")
            }
            await loadWalletData()
        } catch {
            print("Failed to create address: \(error)")
        }
    }

    private func formatBalance(_ zatoshis: UInt64) -> String {
        let zcl = Double(zatoshis) / 100_000_000.0
        return String(format: "%.8f ZCL", zcl)
    }

    private func truncateAddress(_ address: String) -> String {
        if address.count > 20 {
            return "\(address.prefix(10))...\(address.suffix(8))"
        }
        return address
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - FIX #286 v11: Rescan Time Helpers

    /// Format duration in human-readable format (e.g., "1h 23m 45s")
    private func formatDuration(_ seconds: Int) -> String {
        if seconds < 60 {
            return "\(seconds)s"
        } else if seconds < 3600 {
            let mins = seconds / 60
            let secs = seconds % 60
            return "\(mins)m \(secs)s"
        } else {
            let hours = seconds / 3600
            let mins = (seconds % 3600) / 60
            let secs = seconds % 60
            if hours > 0 {
                return "\(hours)h \(mins)m \(secs)s"
            }
            return "\(mins)m \(secs)s"
        }
    }

    /// Estimate remaining time based on elapsed time and progress
    private func estimateRemainingTime() -> Int {
        guard importProgress > 0.1, rescanElapsedSeconds > 10 else {
            return rescanEstimatedTotalSeconds
        }

        // Calculate rate: elapsed / progress = total estimated time
        let estimatedTotal = Double(rescanElapsedSeconds) / importProgress
        let remaining = Int(estimatedTotal) - rescanElapsedSeconds

        return max(0, remaining)
    }

    /// FIX #286 v12: Estimate remaining time with custom progress/elapsed values
    private func estimateRemainingTimeForProgress(_ progress: Double, elapsed: Int) -> Int {
        guard progress > 0.1, elapsed > 10 else {
            return 7200  // Default 2 hours
        }

        let estimatedTotal = Double(elapsed) / progress
        let remaining = Int(estimatedTotal) - elapsed

        return max(0, remaining)
    }

    // MARK: - FIX #286 v12: External Rescan Detection

    /// Start polling for external rescan status AND detailed sync status
    private func startRescanStatusPolling() {
        // Cancel any existing tasks
        rescanCheckTask?.cancel()
        syncPollingTask?.cancel()

        // FIX #286 v13: Start sync polling task for detailed status
        syncPollingTask = Task {
            while !Task.isCancelled {
                await updateDetailedSyncStatus()
                // Poll every 3 seconds for sync status
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }

        rescanCheckTask = Task {
            while !Task.isCancelled {
                await checkExternalRescanStatus()

                // Poll every 5 seconds
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    // FIX #286 v14: Update detailed sync status from RPC with HTTP 500 detection
    private func updateDetailedSyncStatus() async {
        do {
            let status = try await RPCClient.shared.getDetailedSyncStatus()
            await MainActor.run {
                detailedSync = status
                rpcUnavailableCount = 0  // Reset on success
                daemonBusyDetected = false
            }
        } catch {
            // FIX #286 v14: Track consecutive HTTP 500 errors - likely daemon rescanning
            let errorMsg = error.localizedDescription
            if errorMsg.contains("HTTP 500") || errorMsg.contains("500") {
                await MainActor.run {
                    rpcUnavailableCount += 1
                    // After 3+ consecutive failures, assume daemon is busy with rescan
                    if rpcUnavailableCount >= 3 {
                        daemonBusyDetected = true
                        print("📊 FIX #286 v14: Daemon busy detected after \(rpcUnavailableCount) HTTP 500 errors - likely rescanning")
                        // FIX #286 v15: Try to get real progress from debug.log
                        parseDebugLogForRescanProgress()
                    }
                }
            }
            print("📊 FIX #286 v14: DetailedSyncStatus poll error: \(errorMsg)")
        }
    }

    // FIX #286 v15: Parse debug.log for real rescan progress
    // Format: "Still rescanning. At block 2168578. Progress=0.522371"
    private func parseDebugLogForRescanProgress() {
        let debugLogPath = NSString(string: "~/Library/Application Support/Zclassic/debug.log").expandingTildeInPath

        guard FileManager.default.fileExists(atPath: debugLogPath) else {
            print("📊 FIX #286 v15: debug.log not found at \(debugLogPath)")
            return
        }

        do {
            // Read last 10KB of file (enough to find recent rescan line)
            let fileURL = URL(fileURLWithPath: debugLogPath)
            let fileHandle = try FileHandle(forReadingFrom: fileURL)
            let fileSize = try fileHandle.seekToEnd()

            // Seek to last 10KB
            let readSize: UInt64 = min(fileSize, 10240)
            try fileHandle.seek(toOffset: fileSize - readSize)
            let data = fileHandle.readData(ofLength: Int(readSize))
            fileHandle.closeFile()

            guard let content = String(data: data, encoding: .utf8) else { return }

            // Find the last "Still rescanning" line
            let lines = content.components(separatedBy: "\n").reversed()
            for line in lines {
                if line.contains("Still rescanning") {
                    // Parse: "Still rescanning. At block 2168578. Progress=0.522371"
                    if let blockRange = line.range(of: "At block "),
                       let progressRange = line.range(of: "Progress=") {
                        let blockStart = line[blockRange.upperBound...]
                        if let blockEnd = blockStart.firstIndex(of: ".") {
                            let blockStr = String(blockStart[..<blockEnd])
                            if let block = Int(blockStr) {
                                debugLogRescanBlock = block
                            }
                        }

                        let progressStr = String(line[progressRange.upperBound...])
                        if let progress = Double(progressStr) {
                            debugLogRescanProgress = progress
                        }

                        debugLogLastUpdate = Date()
                        print("📊 FIX #286 v15: Parsed debug.log - Block \(debugLogRescanBlock), Progress \(Int(debugLogRescanProgress * 100))%")
                        return
                    }
                }
            }
        } catch {
            print("📊 FIX #286 v15: Error reading debug.log: \(error.localizedDescription)")
        }
    }

    /// Stop polling for rescan status
    private func stopRescanStatusPolling() {
        rescanCheckTask?.cancel()
        rescanCheckTask = nil
        syncPollingTask?.cancel()
        syncPollingTask = nil
    }

    // MARK: - FIX #286 v17: Pending Transaction Monitoring

    /// Start monitoring for pending transactions and unconfirmed balances
    private func startPendingTxMonitoring() {
        pendingTxMonitorTask?.cancel()

        pendingTxMonitorTask = Task {
            while !Task.isCancelled {
                await checkPendingTransactions()
                // Poll every 5 seconds
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    /// Stop pending transaction monitoring
    private func stopPendingTxMonitoring() {
        pendingTxMonitorTask?.cancel()
        pendingTxMonitorTask = nil
    }

    /// Check for pending operations and unconfirmed balances
    private func checkPendingTransactions() async {
        // Skip if daemon is busy
        guard !daemonBusyDetected else { return }

        do {
            // 1. Check for pending z_sendmany operations
            let operations = try await RPCClient.shared.getPendingOperations()

            // 2. Check for unconfirmed balance
            let unconfirmed = try await RPCClient.shared.getUnconfirmedBalance()

            // 3. Detect newly completed operations by comparing with previous state
            let previousOpids = Set(pendingOperations.map { $0.opid })
            let currentOpids = Set(operations.map { $0.opid })

            // Find completed operations (were pending, now gone or success)
            let completedOps = pendingOperations.filter { op in
                !currentOpids.contains(op.opid) || operations.first { $0.opid == op.opid }?.status == "success"
            }

            await MainActor.run {
                pendingOperations = operations
                pendingUnconfirmedBalance = unconfirmed

                // If an operation just completed, mark for notification
                for completedOp in completedOps {
                    if let txid = completedOp.txid {
                        print("📊 FIX #286 v17: Operation completed - txid: \(txid.prefix(16))...")
                    }
                }
            }

            // 4. Check if pending balance changed to 0 (transaction confirmed)
            let hadPendingBefore = hasPendingTransactions
            let hasPendingNow = !operations.isEmpty || unconfirmed.transparent != 0 || unconfirmed.private_ != 0

            if hadPendingBefore && !hasPendingNow {
                print("📊 FIX #286 v17: All pending transactions confirmed - refreshing wallet data")
                await loadWalletData()
            }

            // 5. Check for newly confirmed transactions by monitoring z_listreceivedbyaddress changes
            await checkForNewConfirmedTransactions()

        } catch {
            // Silently ignore poll errors
        }
    }

    /// Check for newly confirmed transactions by comparing with last known state
    private func checkForNewConfirmedTransactions() async {
        do {
            // Get all recent transactions
            let txs = try await RPCClient.shared.getAllWalletTransactions(limit: 20)
            let currentTxids = Set(txs.map { $0.txid })

            // Find new txids we haven't seen before
            let newTxids = currentTxids.subtracting(lastKnownTxids)

            if !newTxids.isEmpty && !lastKnownTxids.isEmpty {
                // We have new transactions! Check if any are confirmed
                for newTxid in newTxids {
                    if let tx = txs.first(where: { $0.txid == newTxid }),
                       tx.confirmations >= 1 {
                        // New confirmed transaction detected
                        await MainActor.run {
                            recentlyConfirmedTxid = newTxid
                        }
                        // Refresh wallet data to update balance
                        await loadWalletData()
                        break
                    }
                }
            }

            await MainActor.run {
                lastKnownTxids = currentTxids
            }
        } catch {
            // Ignore errors - this is just for notification
        }
    }

    /// Check for external rescan via RPC
    private func checkExternalRescanStatus() async {
        // Don't check if we're already doing a local import
        guard !isImporting else { return }

        do {
            let status = try await RPCClient.shared.getRescanStatus()

            await MainActor.run {
                if status.isScanning {
                    externalRescanDetected = true
                    externalRescanProgress = status.progress
                    externalRescanDuration = status.duration
                    externalRescanSource = status.source
                    print("📊 FIX #286 v12: External rescan detected - source: \(status.source), progress: \(Int(status.progress * 100))%")
                } else if externalRescanDetected {
                    // Rescan finished - reload wallet data
                    print("📊 FIX #286 v12: External rescan completed!")
                    externalRescanDetected = false
                    externalRescanProgress = 0
                    externalRescanDuration = 0
                    externalRescanSource = ""

                    // Reload wallet data to get updated balances
                    Task {
                        await loadWalletData()
                    }
                }
            }
        } catch {
            // Ignore errors during status check
            print("📊 FIX #286 v12: Rescan status check failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - System 7 Button Style

struct System7ButtonStyle: ButtonStyle {
    @EnvironmentObject var themeManager: ThemeManager

    func makeBody(configuration: Configuration) -> some View {
        let theme = themeManager.currentTheme

        configuration.label
            .font(theme.bodyFont)
            .foregroundColor(configuration.isPressed ? theme.textSecondary : theme.textPrimary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(configuration.isPressed ? theme.backgroundColor : theme.surfaceColor)
            .cornerRadius(theme.cornerRadius)
            .overlay(
                RoundedRectangle(cornerRadius: theme.cornerRadius)
                    .stroke(theme.borderColor, lineWidth: theme.borderWidth)
            )
            .shadow(color: configuration.isPressed ? .clear : theme.shadowColor, radius: theme.usesShadows ? 2 : 0)
    }
}

#endif
