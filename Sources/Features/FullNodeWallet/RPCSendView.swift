import SwiftUI

#if os(macOS)

/// Send view for Full Node wallet.dat mode
struct RPCSendView: View {
    @EnvironmentObject var themeManager: ThemeManager
    @Environment(\.dismiss) private var dismiss
    @StateObject private var rpcWallet = RPCWalletOperations.shared

    let addresses: [WalletAddress]
    // FIX #286 v17: Callback when transaction is successfully sent
    var onSendSuccess: (() -> Void)?

    @State private var selectedFromAddress: WalletAddress?
    @State private var toAddress: String = ""
    @State private var amount: String = ""
    @State private var memo: String = ""

    @State private var isSending = false
    @State private var errorMessage: String?
    @State private var successTxid: String?

    @State private var showingConfirmation = false

    private var theme: AppTheme { themeManager.currentTheme }

    // FIX #286 v3: Show ALL addresses but sort by balance (highest first)
    // Don't filter - user needs to see all their addresses
    private var sortedAddresses: [WalletAddress] {
        addresses.sorted { $0.balance > $1.balance }
    }

    // Keep filter for send validation - can only send from addresses with balance
    private var addressesWithBalance: [WalletAddress] {
        addresses.filter { $0.balance > 0 }
    }

    // FIX #286: Validate receiver address (z or t address)
    private var isValidReceiverAddress: Bool {
        guard !toAddress.isEmpty else { return false }
        // Z-address validation (Sapling)
        if toAddress.hasPrefix("zs1") || toAddress.hasPrefix("zs") || toAddress.hasPrefix("zc") {
            // Sapling z-address should be 78 chars for zs1, or legacy format
            return toAddress.count >= 69
        }
        // T-address validation
        if toAddress.hasPrefix("t1") || toAddress.hasPrefix("t3") {
            // T-address should be 34-35 chars
            return toAddress.count >= 34 && toAddress.count <= 35
        }
        return false
    }

    // FIX #286: Error message for invalid address
    private var addressValidationError: String? {
        guard !toAddress.isEmpty else { return nil }
        if !isValidReceiverAddress {
            if toAddress.hasPrefix("zs") || toAddress.hasPrefix("zc") {
                return "Invalid z-address format"
            } else if toAddress.hasPrefix("t") {
                return "Invalid t-address format"
            } else {
                return "Address must start with 'zs1', 'zc', 't1', or 't3'"
            }
        }
        return nil
    }

    private var canSend: Bool {
        guard let from = selectedFromAddress else { return false }
        guard !toAddress.isEmpty else { return false }
        guard isValidReceiverAddress else { return false }  // FIX #286: Validate address
        guard let amountValue = Double(amount), amountValue > 0 else { return false }
        let amountZatoshis = UInt64(amountValue * 100_000_000)
        return amountZatoshis <= from.balance
    }

    private var isZToZ: Bool {
        guard let from = selectedFromAddress else { return false }
        return from.isShielded && (toAddress.hasPrefix("zs") || toAddress.hasPrefix("zc"))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Send ZCL")
                    .font(theme.titleFont)
                    .foregroundColor(theme.textPrimary)

                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(.plain)
                .foregroundColor(theme.primaryColor)
            }
            .padding()
            .background(theme.surfaceColor)

            Divider()
                .background(theme.borderColor)

            // Form
            ScrollView {
                VStack(spacing: 20) {
                    // From address picker
                    VStack(alignment: .leading, spacing: 8) {
                        Text("From")
                            .font(theme.captionFont)
                            .foregroundColor(theme.textSecondary)

                        Menu {
                            // FIX #286 v3: Show ALL addresses sorted by balance
                            // Note: macOS Menu doesn't support complex views, use simple Text
                            ForEach(sortedAddresses) { address in
                                Button(action: {
                                    selectedFromAddress = address
                                }) {
                                    // FIX #286 v3: Simple text format with balance indicator
                                    let icon = address.isShielded ? "🛡️" : "👁️"
                                    let addr = truncateAddress(address.address)
                                    let bal = formatBalance(address.balance)
                                    let noFunds = address.balance == 0 ? " ⚠️" : ""
                                    Text("\(icon) \(addr) — \(bal)\(noFunds)")
                                }
                            }

                            if sortedAddresses.isEmpty {
                                Text("No addresses found")
                            }
                        } label: {
                            HStack {
                                if let selected = selectedFromAddress {
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack {
                                            Image(systemName: selected.isShielded ? "shield.fill" : "eye.fill")
                                                .foregroundColor(theme.primaryColor)
                                            Text(truncateAddress(selected.address))
                                                .font(theme.monoFont)
                                                .foregroundColor(theme.textPrimary)
                                        }
                                        Text("Balance: \(formatBalance(selected.balance))")
                                            .font(theme.captionFont)
                                            .foregroundColor(theme.textSecondary)
                                    }
                                } else {
                                    Text("Select address...")
                                        .foregroundColor(theme.textSecondary)
                                }

                                Spacer()

                                Image(systemName: "chevron.down")
                                    .foregroundColor(theme.textSecondary)
                            }
                            .padding()
                            .background(theme.surfaceColor)
                            .cornerRadius(theme.cornerRadius)
                            .overlay(
                                RoundedRectangle(cornerRadius: theme.cornerRadius)
                                    .stroke(theme.borderColor, lineWidth: theme.borderWidth)
                            )
                        }

                        // FIX #286 v3: Warning if selected address has 0 balance
                        if let selected = selectedFromAddress, selected.balance == 0 {
                            HStack(spacing: 4) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 12))
                                Text("This address has no balance")
                                    .font(theme.captionFont)
                            }
                            .foregroundColor(theme.warningColor)
                        }
                    }

                    // To address
                    VStack(alignment: .leading, spacing: 8) {
                        Text("To")
                            .font(theme.captionFont)
                            .foregroundColor(theme.textSecondary)

                        TextField("Recipient address (z or t)", text: $toAddress)
                            .textFieldStyle(.plain)
                            .font(theme.monoFont)
                            .foregroundColor(theme.textPrimary)
                            .padding()
                            .background(theme.surfaceColor)
                            .cornerRadius(theme.cornerRadius)
                            .overlay(
                                RoundedRectangle(cornerRadius: theme.cornerRadius)
                                    .stroke(addressValidationError != nil ? theme.errorColor : theme.borderColor, lineWidth: theme.borderWidth)
                            )

                        // FIX #286: Show address validation error
                        if let validationError = addressValidationError {
                            HStack(spacing: 4) {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .font(.system(size: 12))
                                Text(validationError)
                                    .font(theme.captionFont)
                            }
                            .foregroundColor(theme.errorColor)
                        } else if isValidReceiverAddress {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 12))
                                Text(toAddress.hasPrefix("zs") || toAddress.hasPrefix("zc") ? "Valid z-address" : "Valid t-address")
                                    .font(theme.captionFont)
                            }
                            .foregroundColor(theme.successColor)
                        }
                    }

                    // Amount
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Amount")
                                .font(theme.captionFont)
                                .foregroundColor(theme.textSecondary)

                            Spacer()

                            if let from = selectedFromAddress {
                                Button("Max") {
                                    // Subtract fee (0.0001 ZCL)
                                    let maxAmount = max(0, Int64(from.balance) - 10000)
                                    amount = String(format: "%.8f", Double(maxAmount) / 100_000_000)
                                }
                                .font(theme.captionFont)
                                .foregroundColor(theme.primaryColor)
                            }
                        }

                        HStack {
                            TextField("0.00000000", text: $amount)
                                .textFieldStyle(.plain)
                                .font(theme.monoFont)
                                .foregroundColor(theme.textPrimary)
                                .padding()

                            Text("ZCL")
                                .font(theme.bodyFont)
                                .foregroundColor(theme.textSecondary)
                                .padding(.trailing)
                        }
                        .background(theme.surfaceColor)
                        .cornerRadius(theme.cornerRadius)
                        .overlay(
                            RoundedRectangle(cornerRadius: theme.cornerRadius)
                                .stroke(theme.borderColor, lineWidth: theme.borderWidth)
                        )
                    }

                    // Memo (only for z-to-z)
                    if isZToZ {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Memo (optional, encrypted)")
                                .font(theme.captionFont)
                                .foregroundColor(theme.textSecondary)

                            TextField("Private message...", text: $memo)
                                .textFieldStyle(.plain)
                                .font(theme.bodyFont)
                                .foregroundColor(theme.textPrimary)
                                .padding()
                                .background(theme.surfaceColor)
                                .cornerRadius(theme.cornerRadius)
                                .overlay(
                                    RoundedRectangle(cornerRadius: theme.cornerRadius)
                                        .stroke(theme.borderColor, lineWidth: theme.borderWidth)
                                )
                        }
                    }

                    // Fee info
                    HStack {
                        Text("Network Fee")
                            .font(theme.bodyFont)
                            .foregroundColor(theme.textSecondary)

                        Spacer()

                        Text("0.0001 ZCL")
                            .font(theme.monoFont)
                            .foregroundColor(theme.textPrimary)
                    }
                    .padding()
                    .background(theme.surfaceColor)
                    .cornerRadius(theme.cornerRadius)

                    // Error message
                    if let error = errorMessage {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(theme.errorColor)
                            Text(error)
                                .font(theme.bodyFont)
                                .foregroundColor(theme.errorColor)
                        }
                        .padding()
                        .background(theme.errorColor.opacity(0.1))
                        .cornerRadius(theme.cornerRadius)
                    }

                    // Success message
                    if let txid = successTxid {
                        VStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 40))
                                .foregroundColor(theme.successColor)

                            Text("Transaction Sent!")
                                .font(theme.titleFont)
                                .foregroundColor(theme.successColor)

                            Text("TxID: \(truncateTxid(txid))")
                                .font(theme.monoFont)
                                .foregroundColor(theme.textSecondary)

                            Button("Copy TxID") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(txid, forType: .string)
                            }
                            .buttonStyle(System7ButtonStyle())
                        }
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(theme.successColor.opacity(0.1))
                        .cornerRadius(theme.cornerRadius)
                    }
                }
                .padding()
            }

            Divider()
                .background(theme.borderColor)

            // Footer
            HStack {
                Spacer()

                if successTxid != nil {
                    Button("Done") {
                        dismiss()
                    }
                    .buttonStyle(System7ButtonStyle())
                } else {
                    Button(isSending ? "Sending..." : "Send") {
                        showingConfirmation = true
                    }
                    .buttonStyle(System7ButtonStyle())
                    .disabled(!canSend || isSending)
                }

                Spacer()
            }
            .padding()
            .background(theme.surfaceColor)
        }
        .frame(minWidth: 450, minHeight: 500)
        .background(theme.backgroundColor)
        // FIX #286 v17: Custom confirmation sheet that shows FULL addresses (not truncated)
        .sheet(isPresented: $showingConfirmation) {
            confirmationSheet
        }
    }

    // MARK: - FIX #286 v17: Confirmation Sheet with FULL Addresses

    private var confirmationSheet: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("⚠️ Confirm Transaction")
                    .font(theme.titleFont)
                    .foregroundColor(theme.warningColor)
                Spacer()
            }
            .padding()
            .background(theme.surfaceColor)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Amount section
                    VStack(alignment: .leading, spacing: 4) {
                        Text("AMOUNT")
                            .font(theme.captionFont)
                            .foregroundColor(theme.textSecondary)
                        Text("\(amount) ZCL")
                            .font(.system(size: 24, weight: .bold, design: .monospaced))
                            .foregroundColor(theme.primaryColor)
                    }

                    Divider()

                    // From address - FULL address shown
                    if let from = selectedFromAddress {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("FROM")
                                    .font(theme.captionFont)
                                    .foregroundColor(theme.textSecondary)
                                Spacer()
                                Image(systemName: from.isShielded ? "shield.fill" : "eye.fill")
                                    .foregroundColor(theme.primaryColor)
                                    .font(.system(size: 12))
                            }
                            // FIX #286 v17: Show FULL address - scrollable and selectable
                            Text(from.address)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(theme.textPrimary)
                                .textSelection(.enabled)
                                .padding(8)
                                .background(theme.backgroundColor)
                                .cornerRadius(4)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            Text("Balance: \(formatBalance(from.balance))")
                                .font(theme.captionFont)
                                .foregroundColor(theme.textSecondary)
                        }
                    }

                    Divider()

                    // To address - FULL address shown
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("TO")
                                .font(theme.captionFont)
                                .foregroundColor(theme.textSecondary)
                            Spacer()
                            let isZAddr = toAddress.hasPrefix("zs") || toAddress.hasPrefix("zc")
                            Image(systemName: isZAddr ? "shield.fill" : "eye.fill")
                                .foregroundColor(theme.primaryColor)
                                .font(.system(size: 12))
                        }
                        // FIX #286 v17: Show FULL address - scrollable and selectable
                        Text(toAddress)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(theme.textPrimary)
                            .textSelection(.enabled)
                            .padding(8)
                            .background(theme.backgroundColor)
                            .cornerRadius(4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Divider()

                    // Fee
                    HStack {
                        Text("Network Fee")
                            .font(theme.bodyFont)
                            .foregroundColor(theme.textSecondary)
                        Spacer()
                        Text("0.0001 ZCL")
                            .font(theme.monoFont)
                            .foregroundColor(theme.textPrimary)
                    }

                    // Total
                    HStack {
                        Text("Total")
                            .font(theme.titleFont)
                            .foregroundColor(theme.textPrimary)
                        Spacer()
                        if let amountValue = Double(amount) {
                            Text(String(format: "%.8f ZCL", amountValue + 0.0001))
                                .font(.system(size: 16, weight: .bold, design: .monospaced))
                                .foregroundColor(theme.errorColor)
                        }
                    }
                    .padding(.top, 8)

                    // Warning
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(theme.warningColor)
                        Text("This transaction cannot be reversed. Please verify all details.")
                            .font(theme.captionFont)
                            .foregroundColor(theme.warningColor)
                    }
                    .padding()
                    .background(theme.warningColor.opacity(0.1))
                    .cornerRadius(8)
                }
                .padding()
            }

            Divider()

            // Action buttons
            HStack(spacing: 16) {
                Button("Cancel") {
                    showingConfirmation = false
                }
                .buttonStyle(System7ButtonStyle())

                Spacer()

                Button(action: {
                    showingConfirmation = false
                    Task {
                        await sendTransaction()
                    }
                }) {
                    HStack {
                        Image(systemName: "arrow.up.circle.fill")
                        Text("Confirm Send")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(theme.primaryColor)
            }
            .padding()
            .background(theme.surfaceColor)
        }
        .frame(minWidth: 500, minHeight: 450)
        .background(theme.backgroundColor)
    }

    // MARK: - Actions

    private func sendTransaction() async {
        guard let from = selectedFromAddress,
              let amountValue = Double(amount) else { return }

        await MainActor.run {
            isSending = true
            errorMessage = nil
        }

        do {
            let amountZatoshis = UInt64(amountValue * 100_000_000)
            let txid: String

            if from.isShielded {
                txid = try await rpcWallet.sendFromZ(
                    from: from.address,
                    to: toAddress,
                    amount: amountZatoshis,
                    memo: memo.isEmpty ? nil : memo
                )
            } else {
                txid = try await rpcWallet.sendFromT(
                    from: from.address,
                    to: toAddress,
                    amount: amountZatoshis
                )
            }

            await MainActor.run {
                successTxid = txid
                isSending = false
                // FIX #286 v17: Notify parent view to refresh
                onSendSuccess?()
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
                isSending = false
            }
        }
    }

    // MARK: - Helpers

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

    private func truncateTxid(_ txid: String) -> String {
        if txid.count > 20 {
            return "\(txid.prefix(8))...\(txid.suffix(8))"
        }
        return txid
    }
}

#endif
