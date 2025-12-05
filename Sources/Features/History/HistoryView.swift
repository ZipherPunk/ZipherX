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
                    .onTapGesture {
                        selectedTransaction = transaction
                    }
                }
            }
        }
        .background(theme.backgroundColor)
    }

    private func transactionRow(_ transaction: TransactionHistoryItem) -> some View {
        HStack(spacing: 12) {
            // Type icon
            VStack {
                Image(systemName: transaction.type == .received ? "arrow.down.left" : "arrow.up.right")
                    .font(.system(size: 16))
                    .foregroundColor(transaction.type == .received ? theme.successColor : theme.errorColor)
            }
            .frame(width: 24)

            // Transaction details
            VStack(alignment: .leading, spacing: 3) {
                // Type and amount
                HStack {
                    Text(transaction.type == .received ? "Received" : "Sent")
                        .font(theme.bodyFont)
                        .foregroundColor(theme.textPrimary)

                    Spacer()

                    Text("\(transaction.type == .received ? "+" : "-")\(String(format: "%.8f", transaction.valueInZCL)) ZCL")
                        .font(theme.titleFont)
                        .foregroundColor(transaction.type == .received ? theme.successColor : theme.errorColor)
                }

                // Date and height
                HStack {
                    if let dateString = transaction.dateString {
                        Text(dateString)
                            .font(theme.captionFont)
                            // Red for sent, green for received
                            .foregroundColor(transaction.type == .received ? theme.successColor : theme.errorColor)
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

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                // ALWAYS populate from notes to ensure SENT transactions are generated
                // The populateHistoryFromNotes() function clears and rebuilds,
                // which is necessary to correctly calculate SENT entries from spent notes
                let populatedCount = try WalletDatabase.shared.populateHistoryFromNotes()
                if populatedCount > 0 {
                    print("📜 Populated \(populatedCount) transaction history entries (received + sent)")
                }

                let items = try WalletDatabase.shared.getTransactionHistory(limit: 100)

                // Deduplicate by type+value+height (same transaction shouldn't appear twice)
                var seen = Set<String>()
                let deduped = items.filter { item in
                    let key = "\(item.type.rawValue)_\(item.value)_\(item.height)"
                    if seen.contains(key) { return false }
                    seen.insert(key)
                    return true
                }

                DispatchQueue.main.async {
                    self.transactions = deduped
                    self.isLoading = false
                }
            } catch {
                DispatchQueue.main.async {
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

    private var transactionHeader: some View {
        VStack(spacing: 8) {
            // Large icon
            Image(systemName: transaction.type == .received ? "arrow.down.left.circle.fill" : "arrow.up.right.circle.fill")
                .font(.system(size: 48))
                .foregroundColor(transaction.type == .received ? theme.successColor : theme.errorColor)

            Text(transaction.type == .received ? "Received" : "Sent")
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
            Text(transaction.type == .received ? "+" : "-")
                .font(.system(size: 14))
                .foregroundColor(transaction.type == .received ? theme.successColor : theme.errorColor)
            +
            Text(String(format: "%.8f", transaction.valueInZCL))
                .font(.system(size: 28, weight: .bold, design: .monospaced))
                .foregroundColor(transaction.type == .received ? theme.successColor : theme.errorColor)
            +
            Text(" ZCL")
                .font(theme.bodyFont)
                .foregroundColor(theme.textSecondary)
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

            // Fee (if sent)
            if transaction.type == .sent, let fee = transaction.feeInZCL {
                detailRow("Fee", "\(String(format: "%.8f", fee)) ZCL")
            }

            // Address (if available)
            if let address = transaction.toAddress {
                VStack(alignment: .leading, spacing: 4) {
                    Text("To Address")
                        .font(theme.captionFont)
                        .foregroundColor(theme.textSecondary)
                    Text(address)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(theme.textPrimary)
                        .textSelection(.enabled)
                }
                .padding(.top, 4)
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
    private func blockDateString(for transaction: TransactionHistoryItem) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short

        // Use the real block timestamp if available
        if let blockTime = transaction.blockTime, blockTime > 0 {
            let date = Date(timeIntervalSince1970: TimeInterval(blockTime))
            return formatter.string(from: date)
        }

        // Fallback 1: Try BlockTimestampManager (uses bundled block_timestamps.bin + runtime cache)
        if transaction.height > 0 {
            if let timestamp = BlockTimestampManager.shared.getTimestamp(at: transaction.height) {
                let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
                return formatter.string(from: date)
            }
        }

        // Fallback 2: Try HeaderStore directly
        if transaction.height > 0 {
            if let header = try? HeaderStore.shared.getHeader(at: transaction.height) {
                let date = Date(timeIntervalSince1970: TimeInterval(header.time))
                return formatter.string(from: date)
            }
        }

        // Last resort: show "Unknown" instead of fake estimate
        return "Unknown"
    }

    private func copyTxid() {
        #if os(iOS)
        UIPasteboard.general.string = transaction.txidString
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transaction.txidString, forType: .string)
        #endif

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
