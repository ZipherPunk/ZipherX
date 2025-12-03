import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

/// Balance View - Displays shielded ZCL balance
/// Themed design
struct BalanceView: View {
    @EnvironmentObject var walletManager: WalletManager
    @EnvironmentObject var networkManager: NetworkManager
    @EnvironmentObject var themeManager: ThemeManager
    @State private var isRefreshing = false
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var refreshTimer: Timer?
    @State private var transactions: [TransactionHistoryItem] = []
    @State private var isLoadingHistory = true
    @State private var selectedTransaction: TransactionHistoryItem? = nil
    @State private var showTransactionDetail = false

    // Fireworks state
    @State private var showFireworks = false
    @State private var fireworksAmount: Double = 0
    @State private var previousBalance: UInt64 = 0

    // Mined celebration state
    @State private var showMinedCelebration = false
    @State private var minedTxAmount: Double = 0
    @State private var minedTxId: String = ""
    @State private var minedIsOutgoing: Bool = true

    // Theme shortcut
    private var theme: AppTheme { themeManager.currentTheme }

    var body: some View {
        let _ = print("📜 BALANCEVIEW: body being rendered")
        ZStack {
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

            // Fireworks overlay (for incoming transactions)
            if showFireworks {
                FireworksView(isShowing: $showFireworks, amount: fireworksAmount)
                    .transition(.opacity)
                    .zIndex(100)
            }

            // Mined celebration overlay (for confirmed transactions)
            if showMinedCelebration {
                MinedCelebrationView(
                    isShowing: $showMinedCelebration,
                    amount: minedTxAmount,
                    txid: minedTxId,
                    isOutgoing: minedIsOutgoing
                )
                .transition(.opacity)
                .zIndex(101)
            }
        }
        .background(themeManager.currentTheme.backgroundColor)
        .alert("Error", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
        .sheet(isPresented: $showTransactionDetail) {
            if let tx = selectedTransaction {
                TransactionDetailView(transaction: tx)
                    .environmentObject(themeManager)
                    .environmentObject(networkManager)
                    #if os(macOS)
                    .frame(minWidth: 500, idealWidth: 550, minHeight: 500, idealHeight: 600)
                    #endif
            }
        }
        .onAppear {
            print("📜 BALANCEVIEW: onAppear TRIGGERED")
            // Initialize previous balance
            previousBalance = walletManager.shieldedBalance
            // Start automatic refresh every 3 seconds
            startAutoRefresh()
            // Load transaction history
            loadTransactionHistory()
        }
        .onDisappear {
            // Stop auto refresh when leaving view
            stopAutoRefresh()
        }
        .onChange(of: walletManager.shieldedBalance) { newValue in
            // Balance changed - reload transaction history
            if newValue != previousBalance {
                loadTransactionHistory()
            }

            // Detect incoming ZCL - balance increased!
            // IMPORTANT: Suppress fireworks for change outputs from our own sends
            if newValue > previousBalance && previousBalance > 0 {
                let increase = newValue - previousBalance

                // Check if this is likely a change output from a recent send
                // Use MULTIPLE criteria to be conservative (any TRUE = suppress fireworks)
                var isLikelyChangeOutput = false

                // Method 1: Check if there's a pending outgoing transaction (MOST RELIABLE)
                // If mempoolOutgoing > 0, we just sent and this is almost certainly change
                if networkManager.mempoolOutgoing > 0 {
                    isLikelyChangeOutput = true
                    print("💰 Change detection (mempoolOutgoing): outgoing pending - suppressing fireworks")
                }

                // Method 2: Time-based - any send in last 120 seconds means this might be change
                if !isLikelyChangeOutput, let lastSend = walletManager.lastSendTimestamp {
                    let timeSinceSend = Date().timeIntervalSince(lastSend)
                    if timeSinceSend < 120.0 {
                        isLikelyChangeOutput = true
                        print("💰 Change detection (time): sent \(Int(timeSinceSend))s ago - suppressing fireworks")
                    }
                }

                // Method 3: Balance comparison - if new balance <= what we had before sending
                if !isLikelyChangeOutput, let balanceBeforeSend = walletManager.balanceBeforeLastSend {
                    if newValue <= balanceBeforeSend {
                        isLikelyChangeOutput = true
                        print("💰 Change detection (balance): newBalance=\(newValue) <= balanceBeforeSend=\(balanceBeforeSend)")
                    }
                }

                if isLikelyChangeOutput {
                    print("💰 Balance increased by \(Double(increase) / 100_000_000.0) ZCL (change output - no fireworks)")
                    // Change output detected means our tx was mined!
                    // Clear tracking after a brief delay to ensure UI is stable
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        // Only clear if still pending (confirmation handler might have cleared already)
                        if networkManager.mempoolOutgoing > 0 {
                            print("💰 Change detected - clearing pending state (tx mined)")
                            networkManager.clearAllPendingOutgoing()
                            walletManager.clearBalanceBeforeLastSend()
                        }
                    }
                } else {
                    fireworksAmount = Double(increase) / 100_000_000.0 // Convert zatoshis to ZCL
                    withAnimation {
                        showFireworks = true
                    }
                    print("🎆 FIREWORKS! Received \(fireworksAmount) ZCL!")
                    // Clear tracking after real incoming is processed
                    walletManager.clearBalanceBeforeLastSend()
                }
            }
            previousBalance = newValue
        }
        .onChange(of: walletManager.transactionHistoryVersion) { _ in
            // Transaction sent - reload history immediately
            print("📜 Transaction history version changed - reloading")
            loadTransactionHistory()
        }
        .onChange(of: walletManager.pendingBalance) { newPendingBalance in
            // When pendingBalance drops to 0, it means our notes got confirmed (1+ confirmations)
            // SAFETY: Clear mempoolOutgoing if it's stale (tx was mined but mempoolOutgoing wasn't cleared)
            if newPendingBalance == 0 && networkManager.mempoolOutgoing > 0 {
                print("💰 pendingBalance=0 but mempoolOutgoing=\(networkManager.mempoolOutgoing) - clearing stale pending state")
                networkManager.clearAllPendingOutgoing()
                walletManager.clearBalanceBeforeLastSend()
            }
        }
        .onChange(of: networkManager.justConfirmedTx?.txid) { txid in
            // Transaction was mined - show celebration!
            if let txid = txid, let confirmed = networkManager.justConfirmedTx {
                minedTxId = txid
                minedTxAmount = Double(confirmed.amount) / 100_000_000.0
                minedIsOutgoing = confirmed.isOutgoing
                withAnimation {
                    showMinedCelebration = true
                }
                print("⛏️ MINED CELEBRATION! \(minedIsOutgoing ? "Sent" : "Received") \(minedTxAmount) ZCL")

                // When outgoing tx is confirmed, clear balance tracking
                // This happens AFTER change output is detected and added to balance
                if confirmed.isOutgoing {
                    print("💰 Outgoing tx confirmed - clearing balance tracking")
                    walletManager.clearBalanceBeforeLastSend()
                }

                // Clear the trigger after handling
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    networkManager.justConfirmedTx = nil
                }
            }
        }
    }

    /// Calculate the effective balance to display during pending transactions
    /// This prevents confusing balance fluctuations when change output is being detected
    private var effectiveDisplayBalance: UInt64 {
        // If there's a pending outgoing transaction, use balanceBeforeLastSend - outgoing amount
        // This shows the user the expected final balance rather than confusing intermediate states
        if networkManager.mempoolOutgoing > 0, let beforeSend = walletManager.balanceBeforeLastSend {
            // Expected balance = what we had before sending - what we sent (including fees)
            let expected = beforeSend >= networkManager.mempoolOutgoing ? beforeSend - networkManager.mempoolOutgoing : 0
            print("💰 effectiveDisplayBalance: beforeSend=\(beforeSend) - outgoing=\(networkManager.mempoolOutgoing) = \(expected) (raw=\(walletManager.shieldedBalance))")
            return expected
        }

        // Also use balanceBeforeLastSend during the 120-second send window even if mempoolOutgoing is 0
        // This handles the case where change came back but pending wasn't properly tracked
        if let beforeSend = walletManager.balanceBeforeLastSend,
           let lastSend = walletManager.lastSendTimestamp,
           Date().timeIntervalSince(lastSend) < 120.0 {
            print("💰 effectiveDisplayBalance: Using beforeSend=\(beforeSend) during send window (raw=\(walletManager.shieldedBalance))")
            // We don't have mempoolOutgoing, so just show the raw balance but log it
        }

        return walletManager.shieldedBalance
    }

    private var balanceCard: some View {
        VStack(spacing: 12) {
            // Main balance
            VStack(spacing: 4) {
                Text("Shielded Balance")
                    .font(theme.captionFont)
                    .foregroundColor(theme.textSecondary)

                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(formatBalance(effectiveDisplayBalance))
                        .font(.system(size: 24, weight: .bold, design: theme.hasRetroStyling ? .monospaced : .default))
                        .foregroundColor(theme.textPrimary)

                    Text("ZCL")
                        .font(theme.bodyFont)
                        .foregroundColor(theme.textSecondary)
                }

                // RECEIVER SIDE: Show pending INCOMING amount right below balance
                if networkManager.mempoolIncoming > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 10))
                        Text("+\(formatBalance(networkManager.mempoolIncoming)) ZCL")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                        Text("incoming")
                            .font(.system(size: 10, design: .monospaced))
                            .italic()
                    }
                    .foregroundColor(theme.successColor)
                }
            }

            // UNIFIED Pending indicator - shows OUTGOING in mempool OR notes with 0 confirmations
            // Priority: mempoolOutgoing (tx not yet mined) > pendingBalance (mined but 0 conf)
            if networkManager.mempoolOutgoing > 0 {
                // Transaction in mempool - not yet mined
                HStack(spacing: 4) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 10))
                    Text("-\(formatBalance(networkManager.mempoolOutgoing)) ZCL")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                    Text("awaiting confirmation")
                        .font(.system(size: 9, design: .monospaced))
                        .italic()
                }
                .foregroundColor(theme.warningColor)
            } else if walletManager.pendingBalance > 0 {
                // Transaction mined but 0 confirmations (change not yet spendable)
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 10))
                    Text("+\(formatBalance(walletManager.pendingBalance)) ZCL")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                    Text("pending")
                        .font(.system(size: 9, design: .monospaced))
                        .italic()
                }
                .foregroundColor(theme.textSecondary)
            }

            // Privacy indicator
            HStack(spacing: 4) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 10))
                Text("Fully Shielded")
                    .font(theme.captionFont)
            }
            .foregroundColor(theme.textPrimary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(theme.backgroundColor)
            .overlay(
                RoundedRectangle(cornerRadius: theme.cornerRadius)
                    .stroke(theme.borderColor, lineWidth: theme.borderWidth)
            )
            .cornerRadius(theme.cornerRadius)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(theme.surfaceColor)
        .overlay(
            RoundedRectangle(cornerRadius: theme.cornerRadius)
                .stroke(theme.borderColor, lineWidth: theme.borderWidth)
        )
        .cornerRadius(theme.cornerRadius)
        .shadow(color: theme.shadowColor, radius: theme.usesShadows ? 3 : 0)
    }

    private var transactionHistorySection: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 10))
                Text("Recent Transactions")
                    .font(theme.titleFont)
                Spacer()
            }
            .foregroundColor(theme.textPrimary)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

            Divider()
                .background(theme.borderColor)

            // Transaction list or empty state
            if isLoadingHistory {
                HStack {
                    ProgressView()
                        .scaleEffect(0.6)
                    Text("Loading...")
                        .font(theme.captionFont)
                        .foregroundColor(theme.textSecondary)
                    Spacer()
                }
                .padding(8)
                .onAppear { print("📜 TXHIST VIEW: Showing loading state") }
            } else if transactions.isEmpty {
                let _ = print("📜 TXHIST VIEW: Empty state - transactions.count=\(transactions.count), isLoadingHistory=\(isLoadingHistory)")
                HStack {
                    Image(systemName: "doc.text")
                        .font(.system(size: 12))
                        .foregroundColor(theme.textSecondary)
                    Text("No transactions yet")
                        .font(theme.captionFont)
                        .foregroundColor(theme.textSecondary)
                    Spacer()
                }
                .padding(8)
            } else {
                // Transaction history shows ONLY confirmed sent/received transactions
                // Filter out:
                // 1. Change transactions - internal, user doesn't need to see
                // 2. ALL pending transactions - they're shown in the pending section below balance
                let visibleTransactions = transactions.filter { tx in
                    // Always filter out change type
                    if tx.type == .change { return false }

                    // Filter out ALL pending transactions - only show confirmed
                    if tx.isPending {
                        print("📜 Hiding pending tx from history: \(tx.txidString.prefix(12))... type=\(tx.type)")
                        return false
                    }

                    return true
                }
                let _ = print("📜 TXHIST VIEW: Showing \(visibleTransactions.count) of \(transactions.count) transactions (hidden: change + all pending)")
                // Show up to 5 recent transactions (excluding change)
                VStack(spacing: 1) {
                    ForEach(visibleTransactions.prefix(5), id: \.uniqueId) { tx in
                        transactionRow(tx)
                    }
                }

                // Show warning if history doesn't match balance
                if let mismatchInfo = historyBalanceMismatch {
                    Divider()
                        .background(theme.borderColor)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 10))
                            Text("Incomplete History")
                                .font(theme.captionFont)
                                .fontWeight(.medium)
                        }
                        .foregroundColor(theme.warningColor)

                        Text(mismatchInfo.message)
                            .font(.system(size: 9))
                            .foregroundColor(theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(8)
                    .background(theme.warningColor.opacity(0.1))
                }
            }
        }
        .background(theme.surfaceColor)
        .overlay(
            RoundedRectangle(cornerRadius: theme.cornerRadius)
                .stroke(theme.borderColor, lineWidth: theme.borderWidth)
        )
        .cornerRadius(theme.cornerRadius)
    }

    /// Check if transaction history sum matches the displayed balance
    private var historyBalanceMismatch: (message: String, difference: Int64)? {
        guard !transactions.isEmpty else { return nil }

        // Calculate balance from history (excluding change which is internal)
        let totalReceived = transactions
            .filter { $0.type == .received }
            .reduce(0) { $0 + Int64($1.value) }

        let totalSent = transactions
            .filter { $0.type == .sent }
            .reduce(0) { $0 + Int64($1.value) }

        let historyBalance = totalReceived - totalSent
        let actualBalance = Int64(walletManager.shieldedBalance)
        let difference = actualBalance - historyBalance

        // Allow small tolerance for fees/rounding (10000 zatoshis = 0.0001 ZCL)
        if abs(difference) > 10000 {
            let diffZCL = Double(abs(difference)) / 100_000_000.0
            let scanHeight = (try? WalletDatabase.shared.getLastScannedHeight()) ?? 0

            if difference > 0 {
                // Balance is higher than history suggests - missing RECEIVED transactions
                return (
                    message: "History shows \(String(format: "%.4f", diffZCL)) ZCL less than balance. Some transactions before block \(scanHeight) may be missing. Use Settings → Quick Scan to find older transactions.",
                    difference: difference
                )
            } else {
                // Balance is lower than history suggests - missing SENT transactions
                return (
                    message: "History shows \(String(format: "%.4f", diffZCL)) ZCL more than balance. Some outgoing transactions may not be recorded. Use Settings → Full Rescan if needed.",
                    difference: difference
                )
            }
        }

        return nil
    }

    private func transactionRow(_ tx: TransactionHistoryItem) -> some View {
        Button(action: {
            selectedTransaction = tx
            showTransactionDetail = true
        }) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    // Type icon with pending indicator
                    ZStack {
                        Image(systemName: txIcon(for: tx.type))
                            .font(.system(size: 10))
                            .foregroundColor(tx.isPending ? theme.warningColor : txColor(for: tx.type))
                            .frame(width: 16)

                        // Pulsing dot for pending transactions
                        if tx.isPending {
                            Circle()
                                .fill(theme.warningColor)
                                .frame(width: 6, height: 6)
                                .offset(x: 6, y: -4)
                        }
                    }

                    // Amount
                    Text("\(tx.type == .sent ? "-" : "+")\(String(format: "%.8f", tx.valueInZCL))")
                        .font(theme.monoFont)
                        .foregroundColor(tx.isPending ? theme.warningColor : txColor(for: tx.type))

                    Spacer()

                    // Status or Date/Time
                    if tx.isPending {
                        Text(tx.statusString)
                            .font(theme.captionFont)
                            .foregroundColor(theme.warningColor)
                    } else {
                        Text(tx.dateString ?? estimatedDateString(for: tx.height))
                            .font(theme.captionFont)
                            .foregroundColor(theme.textSecondary)
                    }
                }

                // Txid preview (truncated) with confirmations
                HStack {
                    Text(truncatedTxid(tx.txidString))
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundColor(theme.textSecondary)

                    if tx.status == .confirmed && tx.confirmations > 0 {
                        Text("(\(tx.confirmations) conf.)")
                            .font(.system(size: 7, design: .monospaced))
                            .foregroundColor(theme.textSecondary.opacity(0.7))
                    }
                }
                .padding(.leading, 24)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tx.isPending ? theme.warningColor.opacity(0.1) : theme.surfaceColor)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }

    /// Truncate txid for display: first 8 + ... + last 8 characters
    private func truncatedTxid(_ txid: String) -> String {
        guard txid.count > 20 else { return txid }
        let prefix = txid.prefix(8)
        let suffix = txid.suffix(8)
        return "\(prefix)...\(suffix)"
    }

    /// Estimate date/time from block height
    /// Zclassic has ~150 second block times (2.5 minutes)
    private func estimatedDateString(for height: UInt64) -> String {
        // Use current time and current chain height as reference for accurate estimation
        // This avoids stale reference points that drift over time
        let currentHeight = networkManager.chainHeight
        let currentDate = Date()

        // If we don't have chain height yet, use a recent known reference
        if currentHeight == 0 {
            // Fallback: block 2,926,100 on November 29, 2025 ~12:00 UTC
            let referenceHeight: UInt64 = 2_926_100
            let referenceDate = Date(timeIntervalSince1970: 1764072000) // Nov 25, 2025 12:00 UTC

            let blockDifference = Int64(height) - Int64(referenceHeight)
            let secondsDifference = Double(blockDifference) * 150.0
            let estimatedDate = referenceDate.addingTimeInterval(secondsDifference)

            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            return formatter.string(from: estimatedDate)
        }

        // Calculate based on current chain tip (most accurate)
        let blockDifference = Int64(height) - Int64(currentHeight)
        let secondsDifference = Double(blockDifference) * 150.0 // ~150 seconds per block

        let estimatedDate = currentDate.addingTimeInterval(secondsDifference)

        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: estimatedDate)
    }

    private func loadTransactionHistory() {
        isLoadingHistory = true
        print("📜 TXHIST: loadTransactionHistory() CALLED")

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                // Check if history is empty - only populate from notes if needed
                // This avoids the CLEAR + rebuild cycle that causes change to briefly appear
                let existingCount = try WalletDatabase.shared.getTransactionCount()
                if existingCount == 0 {
                    print("📜 TXHIST: History empty, populating from notes...")
                    let populated = try WalletDatabase.shared.populateHistoryFromNotes()
                    print("📜 TXHIST: Populate result: \(populated) entries")
                } else {
                    print("📜 TXHIST: History has \(existingCount) entries, skipping populate")
                }

                // Now fetch the history
                let items = try WalletDatabase.shared.getTransactionHistory(limit: 10)
                print("📜 TXHIST: getTransactionHistory returned \(items.count) items")

                // Debug: print first item if exists
                if let first = items.first {
                    let txidShort = String(first.txidString.prefix(12))
                    print("📜 TXHIST: First tx: type=\(first.type), value=\(first.value)zat, height=\(first.height), txid=\(txidShort)")
                } else {
                    print("📜 TXHIST: No transactions in history!")
                }

                DispatchQueue.main.async {
                    print("📜 TXHIST: Main thread - setting transactions array to \(items.count) items")
                    self.transactions = items
                    self.isLoadingHistory = false
                    print("📜 TXHIST: Main thread - isLoadingHistory=false, transactions.count=\(self.transactions.count)")
                }
            } catch {
                print("📜 TXHIST ERROR: Failed to load transaction history: \(error)")
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
                        .font(theme.bodyFont)
                        .foregroundColor(connectionTextColor)
                }

                Spacer()

                // Retry button when disconnected
                if !networkManager.isConnected && !isRefreshing {
                    Button(action: { retryConnection() }) {
                        Text("Retry")
                            .font(theme.captionFont)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(theme.buttonBackground)
                            .foregroundColor(theme.buttonText)
                            .overlay(
                                RoundedRectangle(cornerRadius: theme.cornerRadius)
                                    .stroke(theme.borderColor, lineWidth: theme.borderWidth)
                            )
                            .cornerRadius(theme.cornerRadius)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

            // Network stats
            if networkManager.isConnected {
                Divider()
                    .background(theme.borderColor)

                VStack(alignment: .leading, spacing: 3) {
                    if networkManager.chainHeight > 0 {
                        // Node version
                        if !networkManager.peerVersion.isEmpty && networkManager.peerVersion != "Unknown" {
                            statRow("Node:", networkManager.peerVersion)
                        }

                        // Block height
                        statRow("Height:", "\(networkManager.walletHeight) / \(networkManager.chainHeight)")

                        // ZCL Price
                        if networkManager.zclPriceFailed {
                            statRow("ZCL Price:", "N/A")
                        } else if networkManager.zclPriceUSD > 0 {
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
                                .font(theme.captionFont)
                                .foregroundColor(theme.textSecondary)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }

            // Simplified wallet status - just show current state
            Divider()
                .background(theme.borderColor)

            HStack {
                if walletManager.isSyncing {
                    ProgressView()
                        .scaleEffect(0.5)
                    Text("Syncing...")
                        .font(theme.captionFont)
                        .foregroundColor(theme.textPrimary)
                    Spacer()
                    if walletManager.syncProgress > 0 {
                        Text("\(Int(walletManager.syncProgress * 100))%")
                            .font(theme.captionFont)
                            .foregroundColor(theme.textSecondary)
                    }
                } else if !networkManager.isConnected {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(theme.errorColor)
                        .font(.system(size: 10))
                    Text("Disconnected")
                        .font(theme.captionFont)
                        .foregroundColor(theme.errorColor)
                    Spacer()
                } else if networkManager.chainHeight > 0 && networkManager.walletHeight >= networkManager.chainHeight {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(theme.successColor)
                        .font(.system(size: 10))
                    Text("Synced")
                        .font(theme.captionFont)
                        .foregroundColor(theme.textSecondary)
                    Spacer()
                } else {
                    Image(systemName: "clock")
                        .foregroundColor(theme.warningColor)
                        .font(.system(size: 10))
                    Text("Waiting to sync")
                        .font(theme.captionFont)
                        .foregroundColor(theme.textSecondary)
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
        .background(theme.surfaceColor)
        .overlay(
            RoundedRectangle(cornerRadius: theme.cornerRadius)
                .stroke(theme.borderColor, lineWidth: theme.borderWidth)
        )
        .cornerRadius(theme.cornerRadius)
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
            // RED if less than 3 peers (insufficient for trustless operation)
            return networkManager.connectedPeers >= 3 ? .green : .red
        } else if isRefreshing {
            return .orange
        } else {
            return .red
        }
    }

    /// Text color for connection status - RED when peers < 3
    private var connectionTextColor: Color {
        if networkManager.isConnected && networkManager.connectedPeers < 3 {
            return theme.errorColor
        }
        return theme.textPrimary
    }

    private var connectionStatusText: String {
        if isRefreshing && !networkManager.isConnected {
            return "Connecting..."
        } else if networkManager.isConnected {
            let peerWord = networkManager.connectedPeers == 1 ? "peer" : "peers"
            let warning = networkManager.connectedPeers < 3 ? " ⚠️" : ""
            return "Connected to \(networkManager.connectedPeers) \(peerWord)\(warning) (\(networkManager.knownAddressCount) known)"
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
                // This will automatically trigger backgroundSyncToHeight() if needed
                await networkManager.fetchNetworkStats()

                // Reload transaction history periodically
                // (backgroundSyncToHeight updates balance automatically)
                loadTransactionHistory()
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

    // MARK: - Transaction Display Helpers

    /// Returns the appropriate SF Symbol icon for each transaction type
    private func txIcon(for type: TransactionType) -> String {
        switch type {
        case .sent:
            return "arrow.up.circle.fill"
        case .received:
            return "arrow.down.circle.fill"
        case .change:
            return "arrow.triangle.2.circlepath"
        }
    }

    /// Returns the appropriate color for each transaction type
    private func txColor(for type: TransactionType) -> Color {
        switch type {
        case .sent:
            return theme.errorColor
        case .received:
            return theme.successColor
        case .change:
            return theme.textSecondary
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
                .font(theme.captionFont)
                .foregroundColor(theme.textSecondary)
            Text(value)
                .font(theme.captionFont)
                .foregroundColor(theme.textPrimary)
                .lineLimit(1)
            Spacer()
        }
    }
}

#Preview {
    BalanceView()
        .environmentObject(WalletManager.shared)
        .environmentObject(NetworkManager.shared)
        .environmentObject(ThemeManager.shared)
}
