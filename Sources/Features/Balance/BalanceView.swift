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
    @ObservedObject private var torManager = TorManager.shared
    #if os(macOS)
    @ObservedObject private var fullNodeManager = FullNodeManager.shared
    #endif
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

    // Settlement celebration state (for confirmed transactions)
    @State private var showSettlementCelebration = false
    @State private var settlementTxAmount: Double = 0
    @State private var settlementTxId: String = ""
    @State private var settlementIsOutgoing: Bool = true
    @State private var settlementClearingTime: TimeInterval? = nil
    @State private var settlementTime: TimeInterval? = nil

    // Clearing celebration state (for mempool/unconfirmed tx)
    @State private var showClearingCelebration = false
    @State private var clearingTxAmount: Double = 0
    @State private var clearingTxId: String = ""
    @State private var clearingTime: TimeInterval? = nil
    @State private var clearingIsOutgoing: Bool = false  // true for sender, false for receiver

    // Blinking state for "Synced" indicator when syncing in progress
    @State private var syncedTextVisible: Bool = true
    private let blinkTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    // Theme shortcut
    private var theme: AppTheme { themeManager.currentTheme }

    var body: some View {
        let _ = print("📜 BALANCEVIEW: body being rendered")
        ZStack {
            VStack(spacing: 16) {
                // TOP LEFT: Compact Tor/Privacy status indicator
                topLeftTorIndicator

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

            // Settlement celebration overlay (for confirmed transactions)
            if showSettlementCelebration {
                SettlementCelebrationView(
                    isShowing: $showSettlementCelebration,
                    amount: settlementTxAmount,
                    txid: settlementTxId,
                    isOutgoing: settlementIsOutgoing,
                    clearingTime: settlementClearingTime,
                    settlementTime: settlementTime
                )
                .transition(.opacity)
                .zIndex(101)
            }

            // Clearing celebration overlay (for mempool/unconfirmed transactions)
            if showClearingCelebration {
                ClearingCelebrationView(
                    isShowing: $showClearingCelebration,
                    amount: clearingTxAmount,
                    txid: clearingTxId,
                    clearingTime: clearingTime,
                    isOutgoing: clearingIsOutgoing
                )
                .transition(.opacity)
                .zIndex(102)
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

            // Check for pending Clearing celebration (receiver incoming mempool)
            if let mempool = networkManager.justDetectedIncomingMempool {
                print("📜 BALANCEVIEW: Found pending Clearing celebration on appear - triggering now!")
                clearingTxId = mempool.txid
                clearingTxAmount = Double(mempool.amount) / 100_000_000.0
                clearingTime = mempool.clearingTime
                clearingIsOutgoing = false  // Receiver side
                withAnimation {
                    showClearingCelebration = true
                }
                print("🏦 CLEARING (onAppear)! Incoming \(clearingTxAmount) ZCL in tx \(mempool.txid.prefix(12))...")

                // Clear the trigger after handling
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    networkManager.justDetectedIncomingMempool = nil
                }
            }

            // Check for pending Clearing celebration (sender outgoing mempool verified)
            if let cleared = networkManager.justClearedOutgoing {
                print("📜 BALANCEVIEW: Found pending sender Clearing celebration on appear - triggering now!")
                clearingTxId = cleared.txid
                clearingTxAmount = Double(cleared.amount) / 100_000_000.0
                clearingTime = cleared.clearingTime
                clearingIsOutgoing = true  // Sender side
                withAnimation {
                    showClearingCelebration = true
                }
                print("🏦 CLEARING (onAppear)! Sent \(clearingTxAmount) ZCL in \(String(format: "%.1f", cleared.clearingTime))s")

                // Clear the trigger after handling
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    networkManager.justClearedOutgoing = nil
                }
            }

            // Also check for pending Settlement celebration
            if let confirmed = networkManager.justConfirmedTx {
                print("📜 BALANCEVIEW: Found pending Settlement celebration on appear - triggering now!")
                settlementTxId = confirmed.txid
                settlementTxAmount = Double(confirmed.amount) / 100_000_000.0
                settlementIsOutgoing = confirmed.isOutgoing
                settlementClearingTime = confirmed.clearingTime
                settlementTime = confirmed.settlementTime
                withAnimation {
                    showSettlementCelebration = true
                }
                print("⛏️ SETTLEMENT (onAppear)! \(settlementIsOutgoing ? "Sent" : "Received") \(settlementTxAmount) ZCL")

                // When outgoing tx is confirmed, clear balance tracking
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

                // Method 1a: Check two-phase tracking (INSTANT detection)
                // If pendingBroadcastAmount > 0, we just sent and this is almost certainly change
                if networkManager.pendingBroadcastAmount > 0 {
                    isLikelyChangeOutput = true
                    print("💰 Change detection (pendingBroadcast): instant outgoing pending - suppressing fireworks")
                }

                // Method 1b: Check if there's a pending outgoing transaction (LEGACY)
                // If mempoolOutgoing > 0, we just sent and this is almost certainly change
                if !isLikelyChangeOutput && networkManager.mempoolOutgoing > 0 {
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
                    print("💰 Balance increased by \(Double(increase) / 100_000_000.0) ZCL (change output - no celebration)")
                    // Change output detected means our tx was mined!
                    // Clear tracking after a brief delay to ensure UI is stable
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        // Only clear if still pending (confirmation handler might have cleared already)
                        if networkManager.pendingBroadcastAmount > 0 || networkManager.mempoolOutgoing > 0 {
                            print("💰 Change detected - clearing pending state (tx mined)")
                            networkManager.clearPendingBroadcast()
                            networkManager.clearAllPendingOutgoing()
                            walletManager.clearBalanceBeforeLastSend()
                        }
                    }
                } else {
                    // Real incoming transaction detected!
                    // Don't show fireworks - the Settlement celebration will be shown via justConfirmedTx
                    // or Clearing celebration via justDetectedIncomingMempool
                    print("📥 Received \(Double(increase) / 100_000_000.0) ZCL (celebration will be triggered by confirmation/mempool handler)")
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
            // SAFETY: Clear pending states if stale (tx was mined but tracking wasn't cleared)
            if newPendingBalance == 0 && (networkManager.pendingBroadcastAmount > 0 || networkManager.mempoolOutgoing > 0) {
                print("💰 pendingBalance=0 but pending tracking active - clearing stale pending state")
                networkManager.clearPendingBroadcast()
                networkManager.clearAllPendingOutgoing()
                walletManager.clearBalanceBeforeLastSend()
            }
        }
        .onChange(of: networkManager.settlementCelebrationTrigger) { _ in
            // Transaction was confirmed - show Settlement celebration!
            // Using trigger counter instead of optional txid for reliable SwiftUI observation
            if let confirmed = networkManager.justConfirmedTx {
                settlementTxId = confirmed.txid
                settlementTxAmount = Double(confirmed.amount) / 100_000_000.0
                settlementIsOutgoing = confirmed.isOutgoing
                settlementClearingTime = confirmed.clearingTime
                settlementTime = confirmed.settlementTime
                withAnimation {
                    showSettlementCelebration = true
                }
                print("⛏️ SETTLEMENT (BalanceView)! \(settlementIsOutgoing ? "Sent" : "Received") \(settlementTxAmount) ZCL in \(String(format: "%.1f", confirmed.settlementTime ?? 0))s")

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
        .onChange(of: networkManager.mempoolIncomingCelebrationTrigger) { _ in
            // Incoming ZCL detected in mempool - show Clearing celebration!
            if let mempool = networkManager.justDetectedIncomingMempool {
                clearingTxId = mempool.txid
                clearingTxAmount = Double(mempool.amount) / 100_000_000.0
                clearingTime = mempool.clearingTime
                clearingIsOutgoing = false  // Receiver side
                withAnimation {
                    showClearingCelebration = true
                }
                print("🏦 CLEARING! Incoming \(clearingTxAmount) ZCL in tx \(mempool.txid.prefix(12))...")

                // Clear the trigger after handling
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    networkManager.justDetectedIncomingMempool = nil
                }
            }
        }
        .onChange(of: networkManager.outgoingClearingTrigger) { _ in
            // Sender's tx verified in mempool - show Clearing celebration!
            if let cleared = networkManager.justClearedOutgoing {
                clearingTxId = cleared.txid
                clearingTxAmount = Double(cleared.amount) / 100_000_000.0
                clearingTime = cleared.clearingTime
                clearingIsOutgoing = true  // Sender side
                withAnimation {
                    showClearingCelebration = true
                }
                print("🏦 CLEARING! Sent \(clearingTxAmount) ZCL in \(String(format: "%.1f", cleared.clearingTime))s")

                // Clear the trigger after handling
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    networkManager.justClearedOutgoing = nil
                }
            }
        }
        .onReceive(blinkTimer) { _ in
            // Toggle visibility for blinking effect when syncing
            if walletManager.isSyncing {
                syncedTextVisible.toggle()
            } else {
                syncedTextVisible = true  // Always visible when not syncing
            }
        }
    }

    /// Calculate the effective balance to display during pending transactions
    /// This prevents confusing balance fluctuations when change output is being detected
    private var effectiveDisplayBalance: UInt64 {
        // Two-phase tracking: Use pendingBroadcastAmount for INSTANT display
        // This is set immediately when first peer accepts (before mempoolOutgoing)
        if networkManager.pendingBroadcastAmount > 0, let beforeSend = walletManager.balanceBeforeLastSend {
            // Expected balance = what we had before sending - what we sent
            // NOTE: pendingBroadcastAmount is the SEND amount (no fee), add fee for accurate deduction
            let totalDeduction = networkManager.pendingBroadcastAmount + 10_000 // amount + fee
            let expected = beforeSend >= totalDeduction ? beforeSend - totalDeduction : 0
            print("💰 effectiveDisplayBalance (instant): beforeSend=\(beforeSend) - amount=\(networkManager.pendingBroadcastAmount) - fee=10000 = \(expected)")
            return expected
        }

        // Legacy fallback: If there's a pending outgoing transaction (mempoolOutgoing set by trackPendingOutgoing)
        if networkManager.mempoolOutgoing > 0, let beforeSend = walletManager.balanceBeforeLastSend {
            // Expected balance = what we had before sending - what we sent (including fees)
            let expected = beforeSend >= networkManager.mempoolOutgoing ? beforeSend - networkManager.mempoolOutgoing : 0
            print("💰 effectiveDisplayBalance (legacy): beforeSend=\(beforeSend) - outgoing=\(networkManager.mempoolOutgoing) = \(expected) (raw=\(walletManager.shieldedBalance))")
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
        // Define isLikelyChange at outer scope so it's accessible throughout balanceCard
        // Suppress conditions:
        // 1. Change from our own send (pendingBroadcastAmount > 0 OR mempoolOutgoing > 0 or sent recently)
        // 2. Transaction already mined (pendingBalance > 0 means it's in a block now, OR justConfirmedTx is set)
        let isLikelyChange = networkManager.pendingBroadcastAmount > 0 ||
            networkManager.mempoolOutgoing > 0 ||
            (walletManager.lastSendTimestamp != nil && Date().timeIntervalSince(walletManager.lastSendTimestamp!) < 120.0)
        // alreadyMined: true if note is in block (0 conf) OR if we just received a confirmation notification
        let alreadyMined = walletManager.pendingBalance > 0 ||
            (networkManager.justConfirmedTx != nil && !networkManager.justConfirmedTx!.isOutgoing)

        return VStack(spacing: 12) {
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

                // Debug: Always log the balance card state
                let _ = {
                    let mempoolIn = networkManager.mempoolIncoming
                    let mempoolOut = networkManager.mempoolOutgoing
                    let pending = walletManager.pendingBalance
                    let lastSend = walletManager.lastSendTimestamp
                    let lastSendAgo = lastSend != nil ? Date().timeIntervalSince(lastSend!) : -1
                    let justConfirmed = networkManager.justConfirmedTx
                    let pendingBroadcast = networkManager.pendingBroadcastAmount
                    let isMempoolVerified = networkManager.isMempoolVerified

                    print("📊 BALANCE CARD STATE:")
                    print("   pendingBroadcast=\(pendingBroadcast) (\(Double(pendingBroadcast)/100_000_000) ZCL), isMempoolVerified=\(isMempoolVerified)")
                    print("   mempoolIncoming=\(mempoolIn) (\(Double(mempoolIn)/100_000_000) ZCL)")
                    print("   mempoolOutgoing=\(mempoolOut) (\(Double(mempoolOut)/100_000_000) ZCL)")
                    print("   pendingBalance=\(pending) (\(Double(pending)/100_000_000) ZCL)")
                    print("   justConfirmedTx=\(justConfirmed != nil ? "\(justConfirmed!.txid.prefix(12))... isOutgoing=\(justConfirmed!.isOutgoing)" : "nil")")
                    print("   isLikelyChange=\(isLikelyChange), alreadyMined=\(alreadyMined)")
                    print("   lastSendTimestamp=\(lastSend?.description ?? "nil"), ago=\(Int(lastSendAgo))s")

                    // What will be displayed:
                    let hasPendingOut = pendingBroadcast > 0 || mempoolOut > 0
                    if mempoolIn > 0 && !isLikelyChange && !alreadyMined && !hasPendingOut {
                        print("   >>> DISPLAYING: GREEN mempool incoming +\(Double(mempoolIn)/100_000_000) ZCL (awaiting confirmation)")
                    } else if mempoolIn > 0 && alreadyMined {
                        print("   >>> HIDING mempool incoming: tx already mined (alreadyMined=true)")
                    } else if mempoolIn > 0 && hasPendingOut {
                        print("   >>> HIDING mempool incoming: have pending outgoing (likely change detection issue)")
                    }
                    if pendingBroadcast > 0 {
                        let status = isMempoolVerified ? "in mempool, waiting for miners" : "awaiting confirmation"
                        print("   >>> DISPLAYING: ORANGE outgoing -\(Double(pendingBroadcast)/100_000_000) ZCL (\(status))")
                    } else if mempoolOut > 0 {
                        print("   >>> DISPLAYING: ORANGE outgoing -\(Double(mempoolOut)/100_000_000) ZCL (in mempool)")
                    } else if pending > 0 && !isLikelyChange {
                        print("   >>> DISPLAYING: GREEN pending +\(Double(pending)/100_000_000) ZCL (0 confirmations)")
                    } else if pending > 0 && isLikelyChange {
                        print("   >>> SUPPRESSING: Change output \(Double(pending)/100_000_000) ZCL (isLikelyChange=true)")
                    }
                }()

                // INCOMING mempool indicator
                // CRITICAL: Hide when we have ANY pending outgoing tx (change could be misdetected as incoming)
                let hasPendingOutgoing = networkManager.pendingBroadcastAmount > 0 || networkManager.mempoolOutgoing > 0
                if networkManager.mempoolIncoming > 0 && !isLikelyChange && !alreadyMined && !hasPendingOutgoing {
                    HStack(spacing: 4) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 10))
                        Text("+\(formatBalance(networkManager.mempoolIncoming)) ZCL")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                        Text("in mempool")
                            .font(.system(size: 9, design: .monospaced))
                            .italic()
                    }
                    .foregroundColor(theme.successColor)  // GREEN for incoming
                }
            }

            // PENDING indicator - shows notes with 0 confirmations (just mined)
            // For RECEIVER: shows incoming that was just mined
            // For SENDER: Two-phase tracking for instant UI:
            //   Phase 1: pendingBroadcastAmount > 0 (first peer accepted) → "awaiting confirmation"
            //   Phase 2: isMempoolVerified = true → "in mempool, waiting for miners"
            //   Legacy: mempoolOutgoing > 0 (fallback)
            if networkManager.pendingBroadcastAmount > 0 {
                // SENDER: Two-phase pending display (INSTANT on first peer accept!)
                let displayAmount = networkManager.pendingBroadcastAmount
                HStack(spacing: 4) {
                    Image(systemName: networkManager.isMempoolVerified ? "hourglass" : "clock.arrow.circlepath")
                        .font(.system(size: 10))
                    Text("-\(formatBalance(displayAmount)) ZCL")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                    if networkManager.isMempoolVerified {
                        Text("in mempool, waiting for miners")
                            .font(.system(size: 9, design: .monospaced))
                            .italic()
                    } else {
                        Text("awaiting confirmation")
                            .font(.system(size: 9, design: .monospaced))
                            .italic()
                    }
                }
                .foregroundColor(theme.warningColor)
            } else if networkManager.mempoolOutgoing > 0 {
                // SENDER: Legacy fallback - transaction in mempool (trackPendingOutgoing was called)
                // Display amount WITHOUT fee (subtract 10000 zatoshis = 0.0001 ZCL)
                let displayAmount = networkManager.mempoolOutgoing > 10_000 ? networkManager.mempoolOutgoing - 10_000 : networkManager.mempoolOutgoing
                HStack(spacing: 4) {
                    Image(systemName: "hourglass")
                        .font(.system(size: 10))
                    Text("-\(formatBalance(displayAmount)) ZCL")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                    Text("in mempool, waiting for miners")
                        .font(.system(size: 9, design: .monospaced))
                        .italic()
                }
                .foregroundColor(theme.warningColor)
            } else if walletManager.pendingBalance > 0 && !isLikelyChange {
                // RECEIVER ONLY: Transaction mined but 0 confirmations (GREEN - it's incoming!)
                // CRITICAL: Suppress on sender side when pendingBalance is actually change output
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 10))
                    Text("+\(formatBalance(walletManager.pendingBalance)) ZCL")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                    Text("0 confirmations")
                        .font(.system(size: 9, design: .monospaced))
                        .italic()
                }
                .foregroundColor(theme.successColor)  // GREEN for incoming (mined but 0 conf)
            } else if walletManager.pendingBalance > 0 && isLikelyChange {
                // SENDER: Change output coming back - show cypherpunk message
                HStack(spacing: 4) {
                    Image(systemName: "arrow.uturn.backward.circle")
                        .font(.system(size: 10))
                    Text("+\(formatBalance(walletManager.pendingBalance)) ZCL")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                    Text("change returning")
                        .font(.system(size: 9, design: .monospaced))
                        .italic()
                }
                .foregroundColor(theme.accentColor)  // Different color for change
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
                VStack(spacing: 0) {
                    ForEach(visibleTransactions.prefix(5), id: \.uniqueId) { tx in
                        VStack(spacing: 0) {
                            transactionRow(tx)
                            // Separator line between rows
                            Rectangle()
                                .fill(theme.borderColor)
                                .frame(height: 1)
                        }
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
                        Text(tx.dateString ?? realBlockDateString(for: tx.height))
                            .font(theme.captionFont)
                            // Red for sent, green for received
                            .foregroundColor(txColor(for: tx.type))
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

    /// Get real block timestamp from HeaderStore
    /// NEVER estimate - only use actual blockchain timestamps!
    private func realBlockDateString(for height: UInt64) -> String {
        // Get real timestamp from HeaderStore (contains blockchain unix timestamps)
        if height > 0 {
            if let blockTime = try? HeaderStore.shared.getBlockTime(at: height) {
                let date = Date(timeIntervalSince1970: TimeInterval(blockTime))
                let formatter = DateFormatter()
                formatter.dateStyle = .short
                formatter.timeStyle = .short
                return formatter.string(from: date)
            }
        }

        // No real timestamp available - show "Syncing..." instead of fake date
        return "Syncing..."
    }

    private func loadTransactionHistory() {
        isLoadingHistory = true
        print("📜 TXHIST: loadTransactionHistory() CALLED")

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                // ALWAYS populate from notes to ensure SENT transactions are generated
                // The populateHistoryFromNotes() function clears and rebuilds,
                // which is necessary to correctly calculate SENT entries from spent notes
                print("📜 TXHIST: Populating history from notes...")
                let populated = try WalletDatabase.shared.populateHistoryFromNotes()
                print("📜 TXHIST: Populate result: \(populated) entries (received + sent)")

                // Now fetch the history
                let items = try WalletDatabase.shared.getTransactionHistory(limit: 10)
                print("📜 TXHIST: getTransactionHistory returned \(items.count) items")

                // Deduplicate by type+value+height (same transaction shouldn't appear twice)
                var seen = Set<String>()
                let deduped = items.filter { item in
                    let key = "\(item.type.rawValue)_\(item.value)_\(item.height)"
                    if seen.contains(key) { return false }
                    seen.insert(key)
                    return true
                }

                // Debug: print first item if exists
                if let first = deduped.first {
                    let txidShort = String(first.txidString.prefix(12))
                    print("📜 TXHIST: First tx: type=\(first.type), value=\(first.value)zat, height=\(first.height), txid=\(txidShort)")
                } else {
                    print("📜 TXHIST: No transactions in history!")
                }

                DispatchQueue.main.async {
                    print("📜 TXHIST: Main thread - setting transactions array to \(deduped.count) items")
                    self.transactions = deduped
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
            // Note: Mode indicator merged into topLeftTorIndicator - ONE LINE for all info

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
                    // Blockchain is synced - check if we need to blink (syncing in progress)
                    let isSyncing = walletManager.isSyncing
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(theme.successColor)
                        .font(.system(size: 10))
                        .opacity(isSyncing ? (syncedTextVisible ? 1.0 : 0.3) : 1.0)
                    Text("Synced")
                        .font(theme.captionFont)
                        .foregroundColor(theme.textSecondary)
                        .opacity(isSyncing ? (syncedTextVisible ? 1.0 : 0.3) : 1.0)
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

    // MARK: - Top Left Tor Indicator

    /// MATRIX NEON GREEN color
    private var matrixGreen: Color { Color(red: 0.0, green: 1.0, blue: 0.0) }

    /// Compact Tor/Privacy status indicator at top left corner - includes peer count
    private var topLeftTorIndicator: some View {
        HStack(spacing: 8) {
            // Privacy/Tor status with colored pill - MATRIX STYLE - ALL ON ONE LINE
            HStack(spacing: 6) {
                if torManager.connectionState.isConnected {
                    // Tor connected - MATRIX NEON GREEN
                    Text("🧅")
                        .font(.system(size: 14))
                    Text("TOR")
                        .font(.system(size: 12, weight: .black, design: .monospaced))
                        .foregroundColor(matrixGreen)
                        .shadow(color: matrixGreen.opacity(0.9), radius: 6, x: 0, y: 0)
                } else if torManager.mode == .enabled {
                    // Tor enabled but connecting
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 14, height: 14)
                    Text("TOR...")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(.orange)
                } else {
                    // P2P mode (no Tor) - still MATRIX GREEN
                    Image(systemName: "network")
                        .font(.system(size: 12))
                        .foregroundColor(matrixGreen)
                        .shadow(color: matrixGreen.opacity(0.8), radius: 4, x: 0, y: 0)
                    Text("P2P")
                        .font(.system(size: 12, weight: .black, design: .monospaced))
                        .foregroundColor(matrixGreen)
                        .shadow(color: matrixGreen.opacity(0.9), radius: 6, x: 0, y: 0)
                }

                // Separator - MATRIX GREEN
                Text("·")
                    .font(.system(size: 14, weight: .black, design: .monospaced))
                    .foregroundColor(matrixGreen)
                    .shadow(color: matrixGreen.opacity(0.8), radius: 4, x: 0, y: 0)

                // Peer count with onion peers - MATRIX GREEN
                if networkManager.isConnected {
                    let peerCount = networkManager.connectedPeers
                    let onionCount = networkManager.onionConnectedPeersCount
                    let peerWord = peerCount == 1 ? "peer" : "peers"
                    let warning = peerCount < 3 ? " ⚠️" : ""

                    Text("\(peerCount) \(peerWord)")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(peerCount < 3 ? .red : matrixGreen)
                        .shadow(color: peerCount < 3 ? .clear : matrixGreen.opacity(0.8), radius: 4, x: 0, y: 0)

                    // Show onion count if any - MATRIX GREEN GLOW
                    if onionCount > 0 {
                        Text("+\(onionCount)🧅")
                            .font(.system(size: 12, weight: .black, design: .monospaced))
                            .foregroundColor(matrixGreen)
                            .shadow(color: matrixGreen.opacity(0.9), radius: 6, x: 0, y: 0)
                    }

                    if !warning.isEmpty {
                        Text(warning)
                            .font(.system(size: 10))
                    }

                    // macOS: Add mode + block height on same line
                    #if os(macOS)
                    Text("·")
                        .font(.system(size: 14, weight: .black, design: .monospaced))
                        .foregroundColor(matrixGreen)
                        .shadow(color: matrixGreen.opacity(0.8), radius: 4, x: 0, y: 0)

                    // Mode with animated heart for healthy full node
                    if WalletModeManager.shared.currentMode == .fullNode {
                        if isDaemonHealthy {
                            Image(systemName: "heart.fill")
                                .foregroundColor(matrixGreen)
                                .font(.system(size: 12))
                                .scaleEffect(heartScale)
                                .animation(.easeInOut(duration: 0.5), value: heartScale)
                                .onAppear { startHeartbeat() }
                                .onDisappear { stopHeartbeat() }
                        } else {
                            Image(systemName: "server.rack")
                                .foregroundColor(.orange)
                                .font(.system(size: 10))
                        }
                        Text("FULL")
                            .font(.system(size: 12, weight: .black, design: .monospaced))
                            .foregroundColor(isDaemonHealthy ? matrixGreen : .orange)
                            .shadow(color: isDaemonHealthy ? matrixGreen.opacity(0.8) : .clear, radius: 4, x: 0, y: 0)

                        // Block height
                        if fullNodeManager.daemonStatus.isRunning {
                            Text("·\(fullNodeManager.daemonBlockHeight)")
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundColor(matrixGreen.opacity(0.8))
                        } else {
                            Text("·\(fullNodeManager.daemonStatus.displayText)")
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundColor(.orange)
                        }

                        // Tor restart warning
                        if torManager.connectionState.isConnected && daemonNeedsTorRestart {
                            Text("⚠️")
                                .font(.system(size: 10))
                        }
                    } else {
                        Image(systemName: "bolt.fill")
                            .foregroundColor(matrixGreen)
                            .font(.system(size: 10))
                        Text("LIGHT")
                            .font(.system(size: 12, weight: .black, design: .monospaced))
                            .foregroundColor(matrixGreen)
                            .shadow(color: matrixGreen.opacity(0.8), radius: 4, x: 0, y: 0)
                    }
                    #endif
                } else if isRefreshing {
                    Text("Connecting...")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(.orange)
                } else {
                    Text("Disconnected")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(.red)
                }
            }
            .fixedSize(horizontal: true, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black.opacity(0.7))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(matrixGreen.opacity(0.8), lineWidth: 1)
                            .shadow(color: matrixGreen.opacity(0.6), radius: 4, x: 0, y: 0)
                    )
            )

            // Retry button when disconnected
            if !networkManager.isConnected && !isRefreshing {
                Button(action: { retryConnection() }) {
                    Text("Retry")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.red.opacity(0.2))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(Color.red.opacity(0.5), lineWidth: 1)
                                )
                        )
                        .foregroundColor(.red)
                }
                .buttonStyle(.plain)
            }

            Spacer()
        }
    }

    // MARK: - macOS Mode Helpers (used by topLeftTorIndicator)

    #if os(macOS)
    // Animated heart state for healthy daemon
    @State private var heartScale: CGFloat = 1.0
    @State private var heartTimer: Timer?

    /// Whether the Full Node daemon is healthy (running with peers)
    private var isDaemonHealthy: Bool {
        WalletModeManager.shared.currentMode == .fullNode &&
        fullNodeManager.daemonStatus.isRunning &&
        RPCClient.shared.peerCount > 0
    }

    /// Whether daemon needs restart to use Tor
    /// Uses FullNodeManager.needsTorRestart which tracks Tor proxy config changes
    private var daemonNeedsTorRestart: Bool {
        fullNodeManager.needsTorRestart
    }

    /// Start the heartbeat animation
    private func startHeartbeat() {
        heartTimer?.invalidate()
        heartTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { _ in
            withAnimation(.easeInOut(duration: 0.3)) {
                heartScale = 1.2
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                withAnimation(.easeInOut(duration: 0.3)) {
                    heartScale = 1.0
                }
            }
        }
    }

    /// Stop the heartbeat animation
    private func stopHeartbeat() {
        heartTimer?.invalidate()
        heartTimer = nil
    }

    private var modeIndicatorColor: Color {
        if WalletModeManager.shared.currentMode == .fullNode {
            // Neon green when daemon is running and has peers (fully connected)
            // Bright fluorescent green (#00FF40) for visibility
            if fullNodeManager.daemonStatus.isRunning {
                // Check if connected to network (has connections)
                let peerCount = RPCClient.shared.peerCount
                if peerCount > 0 {
                    // Full Node running + connected = neon/fluo green
                    return Color(red: 0, green: 1, blue: 0.25)  // Bright neon green like iOS sync view
                } else {
                    // Running but not connected to peers yet
                    return .orange
                }
            } else {
                return .orange
            }
        }
        return .blue
    }
    #endif

    // MARK: - iOS Privacy Indicator

    #if os(iOS)
    /// iOS privacy indicator - shows privacy level (Tor/Onion vs P2P)
    private var privacyIndicator: some View {
        HStack(spacing: 6) {
            // Mode icon (always Light on iOS)
            Image(systemName: "bolt.fill")
                .foregroundColor(.blue)
                .font(.system(size: 10))

            Text("LIGHT MODE")
                .font(theme.captionFont)
                .fontWeight(.medium)
                .foregroundColor(.blue)

            Text("•")
                .foregroundColor(theme.textSecondary)

            // Privacy icon
            if torManager.connectionState.isConnected {
                Text("🧅")
                    .font(.system(size: 10))
            } else if torManager.mode == .enabled {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 12, height: 12)
            } else {
                Image(systemName: "network")
                    .foregroundColor(iOSPrivacyColor)
                    .font(.system(size: 10))
            }

            // Privacy text
            Text(iOSPrivacyText)
                .font(theme.captionFont)
                .fontWeight(.medium)
                .foregroundColor(iOSPrivacyColor)

            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(iOSPrivacyColor.opacity(0.1))
    }

    private var iOSPrivacyText: String {
        if torManager.connectionState.isConnected {
            // Show Tor peer counts like macOS version
            let torCount = networkManager.torConnectedPeersCount
            let onionCount = networkManager.onionConnectedPeersCount
            if torCount > 0 || onionCount > 0 {
                return "\(torCount) via Tor" + (onionCount > 0 ? " + \(onionCount) .onion" : "")
            } else {
                return "FULL PRIVACY"
            }
        } else if torManager.mode == .enabled {
            return "Connecting..."
        } else {
            return "PARTIAL PRIVACY"
        }
    }

    private var iOSPrivacyColor: Color {
        if torManager.connectionState.isConnected {
            return Color(red: 0.6, green: 0.3, blue: 0.9)  // Purple for Tor
        } else if torManager.mode == .enabled {
            return .orange
        } else {
            return .yellow
        }
    }
    #endif

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
        HStack(spacing: 4) {
            Text(label)
                .font(theme.captionFont)
                .foregroundColor(theme.textSecondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Text(value)
                .font(theme.captionFont)
                .foregroundColor(theme.textPrimary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }
}

#Preview {
    BalanceView()
        .environmentObject(WalletManager.shared)
        .environmentObject(NetworkManager.shared)
        .environmentObject(ThemeManager.shared)
}
