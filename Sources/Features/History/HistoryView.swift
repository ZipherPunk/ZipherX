import SwiftUI

/// Transaction History View - Displays sent/received transactions
/// Classic Macintosh System 7 design
struct HistoryView: View {
    @State private var transactions: [TransactionHistoryItem] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var selectedTransaction: TransactionHistoryItem?

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
        .onAppear {
            loadTransactions()
        }
        .sheet(item: $selectedTransaction) { transaction in
            TransactionDetailView(transaction: transaction)
        }
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView()
            Text("Loading transactions...")
                .font(System7Theme.bodyFont(size: 11))
                .foregroundColor(System7Theme.darkGray)
            Spacer()
        }
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundColor(System7Theme.darkGray)
            Text(message)
                .font(System7Theme.bodyFont(size: 11))
                .foregroundColor(System7Theme.darkGray)
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
                .foregroundColor(System7Theme.darkGray)
            Text("No transactions yet")
                .font(System7Theme.bodyFont(size: 12))
                .foregroundColor(System7Theme.darkGray)
            Text("Transactions will appear here\nafter syncing")
                .font(System7Theme.bodyFont(size: 10))
                .foregroundColor(System7Theme.darkGray)
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
        .background(System7Theme.darkGray)
    }

    private func transactionRow(_ transaction: TransactionHistoryItem) -> some View {
        HStack(spacing: 12) {
            // Type icon
            VStack {
                Image(systemName: transaction.type == .received ? "arrow.down.left" : "arrow.up.right")
                    .font(.system(size: 16))
                    .foregroundColor(transaction.type == .received ? .green : .red)
            }
            .frame(width: 24)

            // Transaction details
            VStack(alignment: .leading, spacing: 3) {
                // Type and amount
                HStack {
                    Text(transaction.type == .received ? "Received" : "Sent")
                        .font(System7Theme.bodyFont(size: 11))
                        .foregroundColor(System7Theme.black)

                    Spacer()

                    Text("\(transaction.type == .received ? "+" : "-")\(String(format: "%.8f", transaction.valueInZCL)) ZCL")
                        .font(System7Theme.titleFont(size: 11))
                        .foregroundColor(transaction.type == .received ? .green : .red)
                }

                // Date and height
                HStack {
                    if let dateString = transaction.dateString {
                        Text(dateString)
                            .font(System7Theme.bodyFont(size: 9))
                            .foregroundColor(System7Theme.darkGray)
                    }

                    Spacer()

                    Text("Block \(transaction.height)")
                        .font(System7Theme.bodyFont(size: 9))
                        .foregroundColor(System7Theme.darkGray)
                }

                // Address preview (if available)
                if let address = transaction.toAddress {
                    Text(shortenAddress(address))
                        .font(System7Theme.bodyFont(size: 9))
                        .foregroundColor(System7Theme.darkGray)
                        .lineLimit(1)
                }
            }

            // Disclosure indicator
            Image(systemName: "chevron.right")
                .font(.system(size: 10))
                .foregroundColor(System7Theme.darkGray)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(System7Theme.white)
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
    let transaction: TransactionHistoryItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack {
                Button(action: { dismiss() }) {
                    Text("Done")
                        .font(System7Theme.bodyFont(size: 12))
                        .foregroundColor(System7Theme.black)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(System7Theme.white)
                        .overlay(
                            Rectangle()
                                .stroke(System7Theme.black, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)

                Spacer()

                Text("Transaction Details")
                    .font(System7Theme.titleFont(size: 14))
                    .foregroundColor(System7Theme.black)

                Spacer()

                Color.clear.frame(width: 50, height: 24)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(System7Theme.lightGray)
            .overlay(
                Rectangle()
                    .stroke(System7Theme.black, lineWidth: 1)
            )

            // Content
            ScrollView {
                VStack(spacing: 16) {
                    // Amount card
                    amountCard

                    // Details card
                    detailsCard

                    // Memo card
                    if let memo = transaction.memo, !memo.isEmpty {
                        memoCard(memo)
                    }
                }
                .padding()
            }
        }
        .background(System7Theme.lightGray)
    }

    private var amountCard: some View {
        VStack(spacing: 8) {
            // Type icon
            Image(systemName: transaction.type == .received ? "arrow.down.left.circle.fill" : "arrow.up.right.circle.fill")
                .font(.system(size: 40))
                .foregroundColor(transaction.type == .received ? .green : .red)

            // Amount
            Text("\(transaction.type == .received ? "+" : "-")\(String(format: "%.8f", transaction.valueInZCL)) ZCL")
                .font(System7Theme.titleFont(size: 20))
                .foregroundColor(System7Theme.black)

            // Type label
            Text(transaction.type == .received ? "Received" : "Sent")
                .font(System7Theme.bodyFont(size: 12))
                .foregroundColor(System7Theme.darkGray)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(System7Theme.white)
        .overlay(
            Rectangle()
                .stroke(System7Theme.black, lineWidth: 1)
        )
    }

    private var detailsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Date
            if let dateString = transaction.dateString {
                detailRow("Date:", dateString)
            }

            // Block height
            detailRow("Block:", "\(transaction.height)")

            // Fee (if sent)
            if transaction.type == .sent, let fee = transaction.feeInZCL {
                detailRow("Fee:", "\(String(format: "%.8f", fee)) ZCL")
            }

            // Address (if available)
            if let address = transaction.toAddress {
                VStack(alignment: .leading, spacing: 4) {
                    Text("To Address:")
                        .font(System7Theme.bodyFont(size: 10))
                        .foregroundColor(System7Theme.darkGray)
                    Text(address)
                        .font(System7Theme.monoFont(size: 9))
                        .foregroundColor(System7Theme.black)
                        .textSelection(.enabled)
                }
                .padding(.top, 4)
            }

            // Transaction ID
            VStack(alignment: .leading, spacing: 4) {
                Text("Transaction ID:")
                    .font(System7Theme.bodyFont(size: 10))
                    .foregroundColor(System7Theme.darkGray)
                Text(transaction.txidString)
                    .font(System7Theme.monoFont(size: 8))
                    .foregroundColor(System7Theme.black)
                    .textSelection(.enabled)
                    .lineLimit(2)
            }
            .padding(.top, 4)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(System7Theme.white)
        .overlay(
            Rectangle()
                .stroke(System7Theme.black, lineWidth: 1)
        )
    }

    private func memoCard(_ memo: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Memo:")
                .font(System7Theme.bodyFont(size: 10))
                .foregroundColor(System7Theme.darkGray)

            Text(memo)
                .font(System7Theme.bodyFont(size: 11))
                .foregroundColor(System7Theme.black)
                .textSelection(.enabled)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(System7Theme.white)
        .overlay(
            Rectangle()
                .stroke(System7Theme.black, lineWidth: 1)
        )
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(System7Theme.bodyFont(size: 10))
                .foregroundColor(System7Theme.darkGray)
            Spacer()
            Text(value)
                .font(System7Theme.bodyFont(size: 10))
                .foregroundColor(System7Theme.black)
        }
    }
}

// MARK: - Identifiable conformance for sheet presentation

extension TransactionHistoryItem: Identifiable {
    var id: String { txidString + String(value) }
}

#Preview {
    HistoryView()
}
