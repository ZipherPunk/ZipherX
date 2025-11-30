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
            LazyVStack(spacing: 1) {
                ForEach(transactions, id: \.txidString) { transaction in
                    transactionRow(transaction)
                        .onTapGesture {
                            selectedTransaction = transaction
                        }
                }
            }
            .padding(.vertical, 1)
        }
        .background(theme.borderColor)
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
                            .foregroundColor(theme.textSecondary)
                    }

                    Spacer()

                    Text("Block \(transaction.height)")
                        .font(theme.captionFont)
                        .foregroundColor(theme.textSecondary)
                }

                // Address preview (if available)
                if let address = transaction.toAddress {
                    Text(shortenAddress(address))
                        .font(theme.captionFont)
                        .foregroundColor(theme.textSecondary)
                        .lineLimit(1)
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
                var items = try WalletDatabase.shared.getTransactionHistory(limit: 100)

                // If history is empty, try to populate from existing notes
                if items.isEmpty {
                    print("📜 Transaction history empty, populating from existing notes...")
                    let count = try WalletDatabase.shared.populateHistoryFromNotes()
                    if count > 0 {
                        // Reload after populating
                        items = try WalletDatabase.shared.getTransactionHistory(limit: 100)
                    }
                }

                DispatchQueue.main.async {
                    self.transactions = items
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

    // MARK: - Helpers

    private func shortenAddress(_ address: String) -> String {
        guard address.count > 20 else { return address }
        let prefix = address.prefix(12)
        let suffix = address.suffix(8)
        return "\(prefix)...\(suffix)"
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
        NavigationView {
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
            .background(theme.backgroundColor)
            .navigationTitle("Transaction Details")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                    .foregroundColor(theme.primaryColor)
                }
            }
            .overlay(
                copiedToast
            )
        }
        #if os(iOS)
        .navigationViewStyle(.stack)
        #endif
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
                    Image(systemName: confirmations >= 6 ? "checkmark.shield.fill" : "clock")
                        .font(.system(size: 10))
                    Text(confirmations >= 6 ? "Confirmed (\(confirmations))" : "\(confirmations) confirmation\(confirmations == 1 ? "" : "s")")
                        .font(theme.captionFont)
                }
                .foregroundColor(confirmations >= 6 ? theme.successColor : theme.warningColor)
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
                detailRow("Date", estimatedDateString(for: transaction.height))
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

    private func estimatedDateString(for height: UInt64) -> String {
        let currentHeight = networkManager.chainHeight
        let currentDate = Date()

        if currentHeight == 0 {
            let referenceHeight: UInt64 = 2_926_100
            let referenceDate = Date(timeIntervalSince1970: 1732881600)
            let blockDifference = Int64(height) - Int64(referenceHeight)
            let secondsDifference = Double(blockDifference) * 150.0
            let estimatedDate = referenceDate.addingTimeInterval(secondsDifference)

            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            return formatter.string(from: estimatedDate)
        }

        let blockDifference = Int64(height) - Int64(currentHeight)
        let secondsDifference = Double(blockDifference) * 150.0
        let estimatedDate = currentDate.addingTimeInterval(secondsDifference)

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: estimatedDate)
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
    var id: String { txidString + String(value) }
}

#Preview {
    HistoryView()
        .environmentObject(ThemeManager.shared)
        .environmentObject(NetworkManager.shared)
}
