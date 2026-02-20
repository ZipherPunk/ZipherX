import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

/// Transaction History View - Displays sent/received transactions
/// Themed design
struct HistoryView: View {
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var networkManager: NetworkManager
    @State private var transactions: [TransactionHistoryItem] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var selectedTransaction: TransactionHistoryItem?

    private var theme: AppTheme { themeManager.currentTheme }

    var body: some View {
        VStack(spacing: 0) {
            // Content
            if isLoading {
                loadingView
            } else if let error = errorMessage {
                errorView(error)
            } else if transactions.isEmpty {
                emptyView
            } else {
                transactionList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.backgroundColor)
        .onAppear {
            loadTransactions()
        }
        // FIX #1438: Refresh when populateHistoryFromNotes completes or TX confirmed
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("transactionHistoryUpdated"))) { _ in
            print("📜 FIX #1438: HistoryView received transactionHistoryUpdated — reloading")
            loadTransactions()
        }
        .sheet(item: $selectedTransaction) { transaction in
            TransactionDetailView(transaction: transaction)
                .environmentObject(themeManager)
                .environmentObject(networkManager)
                #if os(macOS)
                .frame(minWidth: 500, idealWidth: 550, maxWidth: 600,
                       minHeight: 650, idealHeight: 700, maxHeight: 800)
                #endif
        }
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView()
            Text("Loading transactions...")
                .font(theme.bodyFont)
                .foregroundColor(theme.textSecondary)
            Spacer()
        }
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundColor(theme.textSecondary)
            Text(message)
                .font(theme.bodyFont)
                .foregroundColor(theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Spacer()
        }
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "doc.text")
                .font(.system(size: 32))
                .foregroundColor(theme.textSecondary)
            Text("No transactions yet")
                .font(theme.bodyFont)
                .foregroundColor(theme.textSecondary)
            Text("Transactions will appear here\nafter syncing")
                .font(theme.captionFont)
                .foregroundColor(theme.textSecondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
    }

    private var transactionList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(transactions, id: \.uniqueId) { transaction in
                    VStack(spacing: 0) {
                        transactionRow(transaction)

                        // Separator line between rows
                        Rectangle()
                            .fill(theme.borderColor)
                            .frame(height: 1)
                    }
                    // FIX #1367: Distinct orange background tint for self-send rows
                    .background(transaction.type == .selfSend ? Color.yellow.opacity(0.10) : Color.clear)
                    .onTapGesture {
                        selectedTransaction = transaction
                    }
                }
            }
        }
        .background(theme.backgroundColor)
        .onAppear {
            // FIX #1367 DEBUG: Log self-send items in the list
            let selfSends = transactions.filter { $0.type == .selfSend }
            if !selfSends.isEmpty {
                print("📜 FIX #1367: HistoryView has \(selfSends.count) self-send item(s): \(selfSends.map { "h=\($0.height)" })")
            } else {
                print("📜 FIX #1367: HistoryView has 0 self-send items! Types: \(Set(transactions.map { $0.type.rawValue }))")
            }
        }
    }

    // FIX #1367: Color for transaction type (green=received, red=sent, orange=self-send)
    private func txColor(_ type: TransactionType) -> Color {
        switch type {
        case .received: return theme.successColor
        case .selfSend: return .yellow  // FIX #1367: Yellow — matches fee display, distinct from red/green
        default: return theme.errorColor
        }
    }

    private func transactionRow(_ transaction: TransactionHistoryItem) -> some View {
        HStack(spacing: 12) {
            // Type icon — FIX #1367: Self-sends use circular arrows icon
            VStack {
                Image(systemName: transaction.type == .selfSend ? "arrow.2.squarepath" :
                      (transaction.type == .received ? "arrow.down.left" : "arrow.up.right"))
                    .font(.system(size: 16))
                    .foregroundColor(txColor(transaction.type))
            }
            .frame(width: 24)

            // Transaction details
            VStack(alignment: .leading, spacing: 3) {
                // Type and amount
                HStack {
                    Text(transaction.type == .selfSend ? "Self-Send" :
                         (transaction.type == .received ? "Received" : "Sent"))
                        .font(theme.bodyFont)
                        .foregroundColor(theme.textPrimary)

                    Spacer()

                    // FIX #1367: Self-sends show "Fee:" prefix since only the fee was spent
                    if transaction.type == .selfSend {
                        Text("Fee: \(String(format: "%.8f", transaction.valueInZCL)) ZCL")
                            .font(theme.titleFont)
                            .foregroundColor(txColor(transaction.type))
                    } else {
                        Text("\(transaction.type == .received ? "+" : "-")\(String(format: "%.8f", transaction.valueInZCL)) ZCL")
                            .font(theme.titleFont)
                            .foregroundColor(txColor(transaction.type))
                    }
                }

                // Date and height
                HStack {
                    if let dateString = transaction.dateString {
                        Text(dateString)
                            .font(theme.captionFont)
                            .foregroundColor(txColor(transaction.type))
                    }

                    Spacer()

                    Text("Block \(transaction.height)")
                        .font(theme.captionFont)
                        .foregroundColor(theme.textSecondary)
                }
            }

            // Disclosure indicator
            Image(systemName: "chevron.right")
                .font(.system(size: 10))
                .foregroundColor(theme.textSecondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(theme.surfaceColor)
    }

    // MARK: - Actions

    private func loadTransactions() {
        isLoading = true
        errorMessage = nil

        Task {
            do {
                // FIX #685: Use correct data source based on wallet source
                // - walletDat: Use RPC to get transactions from Full Node daemon
                // - zipherx: Use local database (Light mode)
                let walletSource = WalletModeManager.shared.walletSource

                #if os(macOS)
                if walletSource == .walletDat {
                    // Full Node mode with wallet.dat - fetch from RPC
                    print("📜 FIX #685: Loading transactions from Full Node RPC (wallet.dat)...")

                    // Get transactions from RPC (no limit - fetch ALL)
                    let rpcTxns = try await RPCWalletOperations.shared.getTransactionHistory(address: nil, limit: 10000)

                    // Convert RPC transactions to TransactionHistoryItem
                    let items = rpcTxns.compactMap { tx -> TransactionHistoryItem? in
                        // Convert txid hex string to Data (little-endian)
                        guard let txidData = Data(hex: tx.txid) else {
                            print("⚠️ FIX #685: Failed to convert txid: \(tx.txid)")
                            return nil
                        }

                        // Convert WalletTransactionType to TransactionType
                        // FIX #1367: Detect self-sends (address == "self") for orange display
                        let txType: TransactionType
                        if tx.type == .sent && tx.address == "self" {
                            txType = .selfSend
                        } else {
                            txType = tx.type == .sent ? .sent : .received
                        }

                        // Determine status based on confirmations
                        let status: TransactionStatus
                        if tx.confirmations == 0 {
                            status = .mempool
                        } else if tx.confirmations < 6 {
                            status = .confirming
                        } else {
                            status = .confirmed
                        }

                        // Get block time from timestamp (Unix timestamp in seconds)
                        let blockTime = UInt64(tx.timestamp.timeIntervalSince1970)

                        return TransactionHistoryItem(
                            txid: txidData,
                            height: tx.height ?? 0,
                            blockTime: blockTime,
                            type: txType,
                            value: tx.amount,
                            fee: tx.fee > 0 ? tx.fee : nil,
                            toAddress: tx.address.isEmpty ? nil : tx.address,
                            memo: tx.memo,
                            status: status,
                            confirmations: tx.confirmations
                        )
                    }

                    await MainActor.run {
                        self.transactions = items
                        self.isLoading = false
                    }
                } else {
                    // Light mode or ZipherX wallet - use local database
                    print("📜 FIX #685: Loading transactions from local database (ZipherX wallet)...")

                    // FIX #462: Skip populateHistoryFromNotes() during ANY database repair
                    // FIX #457 just rebuilt the history, don't undo it by re-inserting change TXs!
                    // Check isRepairingDatabase flag, not isRepairingHistory
                    let isRepairing = WalletManager.shared.isRepairingDatabase
                    if isRepairing {
                        print("📜 HistoryView: Skipping populateHistoryFromNotes (database repair in progress)")
                    } else {
                        // FIX #1415: Always call populateHistoryFromNotes() — not just when empty.
                        // Uses INSERT OR IGNORE so existing entries are preserved.
                        let populatedCount = try WalletDatabase.shared.populateHistoryFromNotes()
                        if populatedCount > 0 {
                            print("📜 FIX #1415: Populated \(populatedCount) new transaction history entries")
                        }
                    }

                    // FIX #129: Show ALL transactions (up to 1000) - was limit:100 which cut off older transactions
                    let items = try WalletDatabase.shared.getTransactionHistory(limit: 1000)

                    // DEBUG: Log loaded transactions summary
                    let sentCount = items.filter { $0.type == .sent }.count
                    let receivedCount = items.filter { $0.type == .received }.count
                    let selfSendCount = items.filter { $0.type == .selfSend }.count
                    let noTimestamp = items.filter { $0.blockTime == nil || $0.blockTime == 0 }.count
                    print("🕐 DEBUG HistoryView.loadTransactions: \(items.count) total — sent=\(sentCount), received=\(receivedCount), selfSend=\(selfSendCount), noTimestamp=\(noTimestamp)")
                    for item in items.prefix(10) {
                        print("🕐 DEBUG   type=\(item.type.rawValue), height=\(item.height), blockTime=\(item.blockTime ?? 0), value=\(item.value)")
                    }

                    // NOTE: Deduplication is now handled in SQL query (WalletDatabase.getTransactionHistory)
                    // The SQL uses rowid subquery to deduplicate while preserving ORDER BY block_height DESC
                    // No additional deduplication needed here - just use items directly to preserve order

                    await MainActor.run {
                        self.transactions = items
                        self.isLoading = false
                    }
                }
                #else
                // iOS - always use local database
                print("📜 FIX #685: Loading transactions from local database (iOS)...")

                // FIX #462: Skip populateHistoryFromNotes() during ANY database repair
                let isRepairing = WalletManager.shared.isRepairingDatabase
                if isRepairing {
                    print("📜 HistoryView: Skipping populateHistoryFromNotes (database repair in progress)")
                } else {
                    // FIX #1415: Always call populateHistoryFromNotes() — not just when empty.
                    // Uses INSERT OR IGNORE so existing entries are preserved.
                    // Without this: spends detected by FIX #1319 after first populate have no history.
                    let populatedCount = try WalletDatabase.shared.populateHistoryFromNotes()
                    if populatedCount > 0 {
                        print("📜 FIX #1415: Populated \(populatedCount) new transaction history entries")
                    }
                }

                let items = try WalletDatabase.shared.getTransactionHistory(limit: 1000)

                await MainActor.run {
                    self.transactions = items
                    self.isLoading = false
                }
                #endif
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }

}

// MARK: - Transaction Detail View

struct TransactionDetailView: View {
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var networkManager: NetworkManager
    @Environment(\.dismiss) private var dismiss

    let transaction: TransactionHistoryItem

    @State private var showCopied = false

    private var theme: AppTheme { themeManager.currentTheme }

    var body: some View {
        VStack(spacing: 0) {
            // Header with title and Done button
            HStack {
                Spacer()
                Text("Transaction Details")
                    .font(theme.titleFont)
                    .foregroundColor(theme.textPrimary)
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .foregroundColor(theme.primaryColor)
            }
            .padding()
            .background(theme.surfaceColor)

            Divider()

            ScrollView {
                VStack(spacing: 16) {
                    // Transaction type header
                    transactionHeader

                    // Amount card
                    amountCard

                    // Details card
                    detailsCard

                    // Txid with copy button
                    txidCard

                    // Memo card
                    if let memo = transaction.memo, !memo.isEmpty {
                        memoCard(memo)
                    }

                    Spacer()
                }
                .padding()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(theme.backgroundColor)
        .overlay(copiedToast)
        #if os(macOS)
        .frame(minWidth: 500, minHeight: 600)
        #endif
    }

    // FIX #1367: Color helper matching transactionRow
    private func txColor(_ type: TransactionType) -> Color {
        switch type {
        case .received: return theme.successColor
        case .selfSend: return .yellow  // FIX #1367: Yellow — matches fee display, distinct from red/green
        default: return theme.errorColor
        }
    }

    private var transactionHeader: some View {
        VStack(spacing: 8) {
            // Large icon — FIX #1367: Self-sends use circular arrows
            Image(systemName: transaction.type == .selfSend ? "arrow.triangle.2.circlepath.circle.fill" :
                  (transaction.type == .received ? "arrow.down.left.circle.fill" : "arrow.up.right.circle.fill"))
                .font(.system(size: 48))
                .foregroundColor(txColor(transaction.type))

            Text(transaction.type == .selfSend ? "Self-Send" :
                 (transaction.type == .received ? "Received" : "Sent"))
                .font(theme.titleFont)
                .foregroundColor(theme.textPrimary)

            // Confirmations
            if let confirmations = calculateConfirmations() {
                HStack(spacing: 4) {
                    // 0 conf = clock (pending), 1-5 = checkmark (mined), 6+ = shield (fully confirmed)
                    Image(systemName: confirmations == 0 ? "clock" : (confirmations >= 6 ? "checkmark.shield.fill" : "checkmark.circle.fill"))
                        .font(.system(size: 10))
                    Text(confirmations == 0 ? "Pending" : (confirmations >= 6 ? "Confirmed (\(confirmations))" : "\(confirmations) confirmation\(confirmations == 1 ? "" : "s")"))
                        .font(theme.captionFont)
                }
                .foregroundColor(confirmations == 0 ? theme.warningColor : theme.successColor)
            }
        }
        .padding()
    }

    private var amountCard: some View {
        VStack(spacing: 8) {
            // FIX #1367: Self-sends show "Fee:" prefix in orange
            if transaction.type == .selfSend {
                Text("Fee: ")
                    .font(.system(size: 14))
                    .foregroundColor(theme.warningColor)
                +
                Text(String(format: "%.8f", transaction.valueInZCL))
                    .font(.system(size: 28, weight: .bold, design: .monospaced))
                    .foregroundColor(theme.warningColor)
                +
                Text(" ZCL")
                    .font(theme.bodyFont)
                    .foregroundColor(theme.textSecondary)
            } else {
                Text(transaction.type == .received ? "+" : "-")
                    .font(.system(size: 14))
                    .foregroundColor(txColor(transaction.type))
                +
                Text(String(format: "%.8f", transaction.valueInZCL))
                    .font(.system(size: 28, weight: .bold, design: .monospaced))
                    .foregroundColor(txColor(transaction.type))
                +
                Text(" ZCL")
                    .font(theme.bodyFont)
                    .foregroundColor(theme.textSecondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(theme.surfaceColor)
        .overlay(
            RoundedRectangle(cornerRadius: theme.cornerRadius)
                .stroke(theme.borderColor, lineWidth: theme.borderWidth)
        )
        .cornerRadius(theme.cornerRadius)
    }

    private var detailsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Details")
                .font(theme.titleFont)
                .foregroundColor(theme.textPrimary)

            Divider()
                .background(theme.borderColor)

            // Block height
            detailRow("Block Height", "\(transaction.height)")

            // Date/Time
            if let dateString = transaction.dateString {
                detailRow("Date", dateString)
            } else {
                detailRow("Date", blockDateString(for: transaction))
            }

            // Value in zatoshis
            detailRow("Amount (zatoshis)", "\(transaction.value)")

            // Fee (if sent or self-send)
            if (transaction.type == .sent || transaction.type == .selfSend), let fee = transaction.feeInZCL {
                detailRow("Fee", "\(String(format: "%.8f", fee)) ZCL")
            }

            // FIX #1367: Self-send explanation
            if transaction.type == .selfSend {
                detailRow("Type", "Self-Send")
                detailRow("Info", "All funds returned to your wallet. Only the network fee was spent.")
            }

            // FIX #1268: Don't display recipient address for privacy (defense in depth).
            // Shielded TXs hide the recipient on-chain — displaying it locally undermines the privacy model.
            // Show "Shielded" instead, which is the whole point of z-addresses.
            if transaction.type == .sent {
                detailRow("To Address", "Shielded")
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surfaceColor)
        .overlay(
            RoundedRectangle(cornerRadius: theme.cornerRadius)
                .stroke(theme.borderColor, lineWidth: theme.borderWidth)
        )
        .cornerRadius(theme.cornerRadius)
    }

    private var txidCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Transaction ID")
                    .font(theme.titleFont)
                    .foregroundColor(theme.textPrimary)

                Spacer()

                Button(action: copyTxid) {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 12))
                        Text("Copy")
                            .font(theme.captionFont)
                    }
                    .foregroundColor(theme.primaryColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(theme.buttonBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: theme.cornerRadius)
                            .stroke(theme.borderColor, lineWidth: theme.borderWidth)
                    )
                    .cornerRadius(theme.cornerRadius)
                }
                .buttonStyle(PlainButtonStyle())
            }

            Divider()
                .background(theme.borderColor)

            // Full txid (scrollable if needed)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(transaction.txidString)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.textPrimary)
                    .textSelection(.enabled)
            }

            // Explorer link hint
            Text("Tap and hold to select, or use Copy button")
                .font(.system(size: 9))
                .foregroundColor(theme.textSecondary)
                .italic()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surfaceColor)
        .overlay(
            RoundedRectangle(cornerRadius: theme.cornerRadius)
                .stroke(theme.borderColor, lineWidth: theme.borderWidth)
        )
        .cornerRadius(theme.cornerRadius)
    }

    private func memoCard(_ memo: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Memo")
                .font(theme.titleFont)
                .foregroundColor(theme.textPrimary)

            Divider()
                .background(theme.borderColor)

            Text(memo)
                .font(theme.bodyFont)
                .foregroundColor(theme.textPrimary)
                .textSelection(.enabled)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surfaceColor)
        .overlay(
            RoundedRectangle(cornerRadius: theme.cornerRadius)
                .stroke(theme.borderColor, lineWidth: theme.borderWidth)
        )
        .cornerRadius(theme.cornerRadius)
    }

    private var copiedToast: some View {
        Group {
            if showCopied {
                VStack {
                    Spacer()

                    Text("Txid Copied!")
                        .font(theme.bodyFont)
                        .foregroundColor(theme.textPrimary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(theme.surfaceColor)
                        .overlay(
                            RoundedRectangle(cornerRadius: theme.cornerRadius)
                                .stroke(theme.borderColor, lineWidth: 2)
                        )
                        .cornerRadius(theme.cornerRadius)
                        .shadow(color: theme.shadowColor, radius: theme.usesShadows ? 5 : 0)

                    Spacer()
                        .frame(height: 40)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: showCopied)
    }

    // MARK: - Helper Functions

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(theme.captionFont)
                .foregroundColor(theme.textSecondary)
            Spacer()
            Text(value)
                .font(theme.monoFont)
                .foregroundColor(theme.textPrimary)
        }
    }

    private func calculateConfirmations() -> Int? {
        let chainHeight = networkManager.chainHeight
        guard chainHeight > 0 && transaction.height > 0 else { return nil }
        let confirmations = Int(chainHeight) - Int(transaction.height) + 1
        return max(0, confirmations)
    }

    /// Format the actual block timestamp for display
    /// Uses the real mined block time stored in the transaction, NOT an estimate
    /// Unified source: HeaderStore (headers table + block_times table from boost)
    // Cached DateFormatter — avoid per-call creation (ICU init is expensive)
    private static let mediumDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private func blockDateString(for transaction: TransactionHistoryItem) -> String {
        let formatter = Self.mediumDateFormatter

        // Priority 1: Use the real block timestamp if already stored in transaction
        if let blockTime = transaction.blockTime, blockTime > 0 {
            let date = Date(timeIntervalSince1970: TimeInterval(blockTime))
            print("🕐 DEBUG blockDateString: height=\(transaction.height), P1 blockTime=\(blockTime) → \(formatter.string(from: date))")
            return formatter.string(from: date)
        }

        // Priority 2: Use HeaderStore (UNIFIED SOURCE)
        // HeaderStore.getBlockTime() checks both:
        //   - Full headers table (from P2P sync)
        //   - block_times table (from boost file)
        if transaction.height > 0 {
            if let timestamp = try? HeaderStore.shared.getBlockTime(at: transaction.height) {
                let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
                print("🕐 DEBUG blockDateString: height=\(transaction.height), P2 HeaderStore=\(timestamp) → \(formatter.string(from: date))")
                return formatter.string(from: date)
            }
        }

        // Priority 3: Use BlockTimestampManager (in-memory cache from boost file)
        // This works even if HeaderStore database insert failed
        if transaction.height > 0 {
            if let timestamp = BlockTimestampManager.shared.getTimestamp(at: transaction.height) {
                let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
                return formatter.string(from: date)
            }
        }

        // Last resort: show "Syncing..." - NO FAKE ESTIMATES!
        // Real timestamp will appear after P2P header sync completes
        print("🕐 DEBUG blockDateString: height=\(transaction.height), blockTime=\(transaction.blockTime ?? 0) — ALL SOURCES FAILED → Syncing...")
        return "Syncing..."
    }

    private func copyTxid() {
        // FIX #1360: TASK 12 — Use ClipboardManager with 60s expiry for txids
        ClipboardManager.copyWithAutoExpiry(transaction.txidString, seconds: 60)

        withAnimation {
            showCopied = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation {
                showCopied = false
            }
        }
    }
}

// MARK: - Identifiable conformance for sheet presentation

extension TransactionHistoryItem: Identifiable {
    var id: String { uniqueId }
}

#Preview {
    HistoryView()
        .environmentObject(ThemeManager.shared)
        .environmentObject(NetworkManager.shared)
}
