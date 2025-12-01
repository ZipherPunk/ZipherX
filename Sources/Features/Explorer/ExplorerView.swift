import SwiftUI

/// Blockchain Explorer View - Search blocks, transactions, and addresses
struct ExplorerView: View {
    @EnvironmentObject var themeManager: ThemeManager
    @StateObject private var viewModel = ExplorerViewModel()

    private var theme: AppTheme { themeManager.currentTheme }

    var body: some View {
        VStack(spacing: 0) {
            // Search bar
            searchBar

            Divider()
                .background(theme.borderColor)

            // Content
            if viewModel.isLoading {
                loadingView
            } else if let error = viewModel.errorMessage {
                errorView(error)
            } else if let result = viewModel.searchResult {
                resultView(result)
            } else {
                placeholderView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.backgroundColor)
    }

    private var searchBar: some View {
        HStack(spacing: 12) {
            // Search field
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(theme.textSecondary)

                TextField("Search block, transaction, or address...", text: $viewModel.searchQuery)
                    .textFieldStyle(PlainTextFieldStyle())
                    .font(theme.bodyFont)
                    .foregroundColor(theme.textPrimary)
                    .onSubmit {
                        viewModel.search()
                    }

                if !viewModel.searchQuery.isEmpty {
                    Button(action: {
                        viewModel.searchQuery = ""
                        viewModel.searchResult = nil
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(theme.textSecondary)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .padding(10)
            .background(theme.surfaceColor)
            .overlay(
                RoundedRectangle(cornerRadius: theme.cornerRadius)
                    .stroke(theme.borderColor, lineWidth: theme.borderWidth)
            )
            .cornerRadius(theme.cornerRadius)

            // Search button
            Button(action: { viewModel.search() }) {
                Text("Search")
                    .font(theme.bodyFont)
                    .foregroundColor(theme.textPrimary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(theme.primaryColor)
                    .cornerRadius(theme.cornerRadius)
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(viewModel.searchQuery.isEmpty)
        }
        .padding()
        .background(theme.surfaceColor)
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView()
            Text("Searching...")
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
                .foregroundColor(theme.warningColor)
            Text(message)
                .font(theme.bodyFont)
                .foregroundColor(theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Spacer()
        }
    }

    private var placeholderView: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "magnifyingglass")
                .font(.system(size: 48))
                .foregroundColor(theme.textSecondary.opacity(0.5))

            Text("Blockchain Explorer")
                .font(theme.titleFont)
                .foregroundColor(theme.textPrimary)

            Text("Search for blocks, transactions, or addresses")
                .font(theme.bodyFont)
                .foregroundColor(theme.textSecondary)

            // Quick links
            VStack(spacing: 8) {
                Text("Examples:")
                    .font(theme.captionFont)
                    .foregroundColor(theme.textSecondary)

                HStack(spacing: 12) {
                    quickLinkButton("Block 100000", "100000")
                    quickLinkButton("Latest Block", "latest")
                }
            }
            .padding(.top, 16)

            Spacer()
        }
    }

    private func quickLinkButton(_ title: String, _ query: String) -> some View {
        Button(action: {
            viewModel.searchQuery = query
            viewModel.search()
        }) {
            Text(title)
                .font(theme.captionFont)
                .foregroundColor(theme.primaryColor)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(theme.surfaceColor)
                .overlay(
                    RoundedRectangle(cornerRadius: theme.cornerRadius)
                        .stroke(theme.borderColor, lineWidth: 1)
                )
                .cornerRadius(theme.cornerRadius)
        }
        .buttonStyle(PlainButtonStyle())
    }

    @ViewBuilder
    private func resultView(_ result: ExplorerResult) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch result {
                case .block(let block):
                    blockDetailView(block)
                case .transaction(let tx):
                    transactionDetailView(tx)
                case .address(let address):
                    addressDetailView(address)
                }
            }
            .padding()
        }
    }

    // MARK: - Block Detail

    private func blockDetailView(_ block: BlockInfo) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                Image(systemName: "cube.fill")
                    .foregroundColor(theme.primaryColor)
                Text("Block #\(block.height)")
                    .font(theme.titleFont)
                    .foregroundColor(theme.textPrimary)
            }

            Divider().background(theme.borderColor)

            // Details
            detailCard {
                detailRow("Hash", block.hash, copyable: true)
                detailRow("Height", "\(block.height)")
                detailRow("Time", block.timeFormatted)
                detailRow("Transactions", "\(block.txCount)")
                detailRow("Size", "\(block.size) bytes")
                if let merkleRoot = block.merkleRoot {
                    detailRow("Merkle Root", merkleRoot, copyable: true)
                }
                if let previousHash = block.previousHash {
                    detailRow("Previous Block", previousHash, copyable: true)
                }
            }

            // Transaction list
            if !block.transactions.isEmpty {
                Text("Transactions")
                    .font(theme.titleFont)
                    .foregroundColor(theme.textPrimary)

                ForEach(block.transactions.prefix(10), id: \.self) { txid in
                    Button(action: {
                        viewModel.searchQuery = txid
                        viewModel.search()
                    }) {
                        HStack {
                            Text(shortenHash(txid))
                                .font(theme.monoFont)
                                .foregroundColor(theme.primaryColor)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundColor(theme.textSecondary)
                        }
                        .padding(10)
                        .background(theme.surfaceColor)
                        .cornerRadius(theme.cornerRadius)
                    }
                    .buttonStyle(PlainButtonStyle())
                }

                if block.transactions.count > 10 {
                    Text("+ \(block.transactions.count - 10) more transactions")
                        .font(theme.captionFont)
                        .foregroundColor(theme.textSecondary)
                }
            }
        }
    }

    // MARK: - Transaction Detail

    private func transactionDetailView(_ tx: TransactionInfo) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                Image(systemName: "arrow.left.arrow.right")
                    .foregroundColor(theme.primaryColor)
                Text("Transaction")
                    .font(theme.titleFont)
                    .foregroundColor(theme.textPrimary)
            }

            Divider().background(theme.borderColor)

            // Details
            detailCard {
                detailRow("TXID", tx.txid, copyable: true)
                if let blockHeight = tx.blockHeight {
                    detailRow("Block", "\(blockHeight)")
                }
                detailRow("Confirmations", "\(tx.confirmations)")
                if let time = tx.timeFormatted {
                    detailRow("Time", time)
                }
                detailRow("Size", "\(tx.size) bytes")
            }

            // Shielded info
            if tx.shieldedSpends > 0 || tx.shieldedOutputs > 0 {
                detailCard {
                    HStack {
                        Image(systemName: "lock.shield")
                            .foregroundColor(theme.successColor)
                        Text("Shielded Transaction")
                            .font(theme.bodyFont)
                            .foregroundColor(theme.textPrimary)
                    }

                    if tx.shieldedSpends > 0 {
                        detailRow("Shielded Inputs", "\(tx.shieldedSpends)")
                    }
                    if tx.shieldedOutputs > 0 {
                        detailRow("Shielded Outputs", "\(tx.shieldedOutputs)")
                    }

                    Text("Note: Shielded values are private")
                        .font(theme.captionFont)
                        .foregroundColor(theme.textSecondary)
                        .italic()
                }
            }

            // Transparent inputs/outputs (if any)
            if !tx.transparentInputs.isEmpty {
                Text("Transparent Inputs")
                    .font(theme.bodyFont)
                    .foregroundColor(theme.textPrimary)

                ForEach(tx.transparentInputs, id: \.address) { input in
                    HStack {
                        Text(shortenAddress(input.address))
                            .font(theme.monoFont)
                            .foregroundColor(theme.textPrimary)
                        Spacer()
                        Text("\(String(format: "%.8f", input.value)) ZCL")
                            .font(theme.monoFont)
                            .foregroundColor(theme.errorColor)
                    }
                    .padding(8)
                    .background(theme.surfaceColor)
                    .cornerRadius(theme.cornerRadius)
                }
            }

            if !tx.transparentOutputs.isEmpty {
                Text("Transparent Outputs")
                    .font(theme.bodyFont)
                    .foregroundColor(theme.textPrimary)

                ForEach(tx.transparentOutputs, id: \.address) { output in
                    HStack {
                        Text(shortenAddress(output.address))
                            .font(theme.monoFont)
                            .foregroundColor(theme.textPrimary)
                        Spacer()
                        Text("\(String(format: "%.8f", output.value)) ZCL")
                            .font(theme.monoFont)
                            .foregroundColor(theme.successColor)
                    }
                    .padding(8)
                    .background(theme.surfaceColor)
                    .cornerRadius(theme.cornerRadius)
                }
            }
        }
    }

    // MARK: - Address Detail

    private func addressDetailView(_ address: AddressInfo) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                Image(systemName: address.isShielded ? "lock.shield" : "person.circle")
                    .foregroundColor(address.isShielded ? theme.successColor : theme.primaryColor)
                Text(address.isShielded ? "Shielded Address" : "Transparent Address")
                    .font(theme.titleFont)
                    .foregroundColor(theme.textPrimary)
            }

            Divider().background(theme.borderColor)

            // Address
            detailCard {
                detailRow("Address", address.address, copyable: true)
            }

            // Balance/Privacy info
            if address.isShielded {
                // Privacy notice for shielded addresses
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "eye.slash")
                            .foregroundColor(theme.successColor)
                        Text("Privacy Protected")
                            .font(theme.bodyFont)
                            .foregroundColor(theme.textPrimary)
                    }

                    Text("\"Privacy is necessary for an open society in the electronic age.\"")
                        .font(theme.captionFont)
                        .foregroundColor(theme.textSecondary)
                        .italic()

                    Text("— A Cypherpunk's Manifesto")
                        .font(theme.captionFont)
                        .foregroundColor(theme.textSecondary)

                    Text("Shielded address balances and transactions are hidden from prying eyes. This is by design.")
                        .font(theme.captionFont)
                        .foregroundColor(theme.textSecondary)
                        .padding(.top, 4)
                }
                .padding()
                .background(theme.surfaceColor)
                .overlay(
                    RoundedRectangle(cornerRadius: theme.cornerRadius)
                        .stroke(theme.successColor.opacity(0.5), lineWidth: 1)
                )
                .cornerRadius(theme.cornerRadius)
            } else {
                // Transparent address - show balance
                detailCard {
                    if let balance = address.balance {
                        detailRow("Balance", "\(String(format: "%.8f", balance)) ZCL")
                    }
                    if let received = address.totalReceived {
                        detailRow("Total Received", "\(String(format: "%.8f", received)) ZCL")
                    }
                    if let txCount = address.transactionCount {
                        detailRow("Transactions", "\(txCount)")
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func detailCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            content()
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

    private func detailRow(_ label: String, _ value: String, copyable: Bool = false) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(theme.captionFont)
                .foregroundColor(theme.textSecondary)
                .frame(width: 120, alignment: .leading)

            if copyable {
                Button(action: { copyToClipboard(value) }) {
                    Text(value)
                        .font(theme.monoFont)
                        .foregroundColor(theme.primaryColor)
                        .lineLimit(2)
                }
                .buttonStyle(PlainButtonStyle())
            } else {
                Text(value)
                    .font(theme.monoFont)
                    .foregroundColor(theme.textPrimary)
            }

            Spacer()
        }
    }

    private func shortenHash(_ hash: String) -> String {
        guard hash.count > 20 else { return hash }
        return "\(hash.prefix(10))...\(hash.suffix(10))"
    }

    private func shortenAddress(_ address: String) -> String {
        guard address.count > 20 else { return address }
        return "\(address.prefix(12))...\(address.suffix(8))"
    }

    private func copyToClipboard(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

// MARK: - Preview

#Preview {
    ExplorerView()
        .environmentObject(ThemeManager.shared)
        .frame(width: 600, height: 800)
}
