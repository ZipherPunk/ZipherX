import SwiftUI

/// Send View - Send shielded ZCL transactions (z-to-z only!)
/// Classic Macintosh System 7 design
struct SendView: View {
    @EnvironmentObject var walletManager: WalletManager
    @EnvironmentObject var networkManager: NetworkManager

    @State private var recipientAddress = ""
    @State private var amount = ""
    @State private var memo = ""
    @State private var isSending = false
    @State private var showConfirmation = false
    @State private var showSuccess = false
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var txId = ""
    @State private var isAddressValid = false
    @State private var isAddressTransparent = false

    var body: some View {
        VStack(spacing: 16) {
            // Recipient address
            addressField

            // Amount
            amountField

            // Memo (optional)
            memoField

            // Available balance
            availableBalance

            // Send button
            System7Button(title: isSending ? "Sending..." : "Send ZCL") {
                validateAndConfirm()
            }
            .disabled(isSending || !isValidInput)

            Spacer()
        }
        .padding()
        .alert("Confirm Transaction", isPresented: $showConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Send") {
                sendTransaction()
            }
        } message: {
            Text("Send \(amount) ZCL to:\n\(recipientAddress.prefix(20))...?")
        }
        .alert("Transaction Sent!", isPresented: $showSuccess) {
            Button("OK") {
                clearForm()
            }
        } message: {
            Text("TX ID: \(txId.prefix(16))...")
        }
        .alert("Error", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }

    private var addressField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Recipient Address (z-address only)")
                .font(System7Theme.bodyFont(size: 10))
                .foregroundColor(System7Theme.darkGray)

            TextField("zc...", text: $recipientAddress)
                .font(System7Theme.bodyFont(size: 11))
                .autocapitalization(.none)
                .disableAutocorrection(true)
                .padding(8)
                .background(System7Theme.white)
                .overlay(
                    Rectangle()
                        .stroke(addressBorderColor, lineWidth: 1)
                )
                .overlay(
                    Rectangle()
                        .strokeBorder(
                            LinearGradient(
                                colors: [System7Theme.darkGray, System7Theme.white],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                        .padding(1)
                )
                .onChange(of: recipientAddress) { newValue in
                    // Validate on change but only call FFI when address looks complete
                    if newValue.isEmpty {
                        isAddressValid = false
                        isAddressTransparent = false
                    } else if newValue.hasPrefix("t1") || newValue.hasPrefix("t3") {
                        isAddressValid = false
                        isAddressTransparent = true
                    } else if newValue.hasPrefix("zs1") && newValue.count >= 70 {
                        // Only call FFI for complete-looking addresses
                        isAddressTransparent = false
                        isAddressValid = walletManager.isValidZAddress(newValue)
                    } else {
                        isAddressValid = false
                        isAddressTransparent = false
                    }
                }

            // Address validation feedback
            if !recipientAddress.isEmpty {
                addressValidationText
            }
        }
    }

    private var addressBorderColor: Color {
        if recipientAddress.isEmpty {
            return System7Theme.black
        } else if isAddressTransparent {
            return .red
        } else if isAddressValid {
            return .green
        } else {
            return .orange
        }
    }

    @ViewBuilder
    private var addressValidationText: some View {
        if isAddressTransparent {
            HStack(spacing: 4) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.red)
                Text("t-addresses not allowed! ZipherX is z-only.")
                    .foregroundColor(.red)
            }
            .font(System7Theme.bodyFont(size: 9))
        } else if isAddressValid {
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text("Valid shielded address")
                    .foregroundColor(.green)
            }
            .font(System7Theme.bodyFont(size: 9))
        } else {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text("Invalid address format")
                    .foregroundColor(.orange)
            }
            .font(System7Theme.bodyFont(size: 9))
        }
    }

    private var amountField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Amount (ZCL)")
                .font(System7Theme.bodyFont(size: 10))
                .foregroundColor(System7Theme.darkGray)

            HStack {
                TextField("0.00000000", text: $amount)
                    .font(System7Theme.bodyFont(size: 11))
                    .keyboardType(.decimalPad)
                    .padding(8)
                    .background(System7Theme.white)
                    .overlay(
                        Rectangle()
                            .stroke(System7Theme.black, lineWidth: 1)
                    )
                    .overlay(
                        Rectangle()
                            .strokeBorder(
                                LinearGradient(
                                    colors: [System7Theme.darkGray, System7Theme.white],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                            .padding(1)
                    )

                // Max button
                Button(action: setMaxAmount) {
                    Text("Max")
                        .font(System7Theme.bodyFont(size: 9))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                }
                .background(System7Theme.lightGray)
                .overlay(
                    Rectangle()
                        .stroke(System7Theme.black, lineWidth: 1)
                )
            }

            // Fee notice
            Text("Network fee: 0.0001 ZCL")
                .font(System7Theme.bodyFont(size: 9))
                .foregroundColor(System7Theme.darkGray)
        }
    }

    private var memoField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Encrypted Memo (optional)")
                .font(System7Theme.bodyFont(size: 10))
                .foregroundColor(System7Theme.darkGray)

            TextField("Private message...", text: $memo)
                .font(System7Theme.bodyFont(size: 11))
                .padding(8)
                .background(System7Theme.white)
                .overlay(
                    Rectangle()
                        .stroke(System7Theme.black, lineWidth: 1)
                )
                .overlay(
                    Rectangle()
                        .strokeBorder(
                            LinearGradient(
                                colors: [System7Theme.darkGray, System7Theme.white],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                        .padding(1)
                )

            Text("Memo is encrypted end-to-end")
                .font(System7Theme.bodyFont(size: 9))
                .foregroundColor(System7Theme.darkGray)
        }
    }

    private var availableBalance: some View {
        HStack {
            Text("Available:")
                .font(System7Theme.bodyFont(size: 10))
                .foregroundColor(System7Theme.darkGray)

            Spacer()

            Text("\(formatBalance(walletManager.shieldedBalance)) ZCL")
                .font(System7Theme.bodyFont(size: 10))
                .foregroundColor(System7Theme.black)
        }
        .padding(8)
        .background(System7Theme.lightGray)
        .overlay(
            Rectangle()
                .stroke(System7Theme.black, lineWidth: 1)
        )
    }

    // MARK: - Validation

    private var isValidInput: Bool {
        guard !recipientAddress.isEmpty,
              !amount.isEmpty,
              isAddressValid,
              !isAddressTransparent else {
            return false
        }

        // Handle both comma and period as decimal separator
        let normalizedAmount = amount.replacingOccurrences(of: ",", with: ".")
        guard let amountValue = Double(normalizedAmount),
              amountValue > 0 else {
            return false
        }

        // Check sufficient funds
        let zatoshis = UInt64(amountValue * 100_000_000)
        let fee: UInt64 = 10000
        return zatoshis + fee <= walletManager.shieldedBalance
    }

    // MARK: - Actions

    private func validateAndConfirm() {
        // Additional validation
        guard isAddressValid else {
            errorMessage = "Invalid z-address. ZipherX only supports shielded addresses."
            showError = true
            return
        }

        guard !isAddressTransparent else {
            errorMessage = "t-addresses are not supported! ZipherX is fully shielded (z-addresses only)."
            showError = true
            return
        }

        showConfirmation = true
    }

    private func sendTransaction() {
        isSending = true

        Task {
            do {
                // Connect if needed
                if !networkManager.isConnected {
                    try await networkManager.connect()
                }

                // Parse amount (handle both comma and period as decimal separator)
                let normalizedAmount = amount.replacingOccurrences(of: ",", with: ".")
                guard let amountValue = Double(normalizedAmount) else {
                    throw WalletError.invalidAddress("Invalid amount")
                }
                let zatoshis = UInt64(amountValue * 100_000_000)

                // Send
                let id = try await walletManager.sendShielded(
                    to: recipientAddress,
                    amount: zatoshis,
                    memo: memo.isEmpty ? nil : memo
                )

                DispatchQueue.main.async {
                    txId = id
                    showSuccess = true
                    isSending = false
                }
            } catch {
                DispatchQueue.main.async {
                    errorMessage = error.localizedDescription
                    showError = true
                    isSending = false
                }
            }
        }
    }

    private func setMaxAmount() {
        let fee: UInt64 = 10000
        if walletManager.shieldedBalance > fee {
            let maxAmount = walletManager.shieldedBalance - fee
            amount = formatBalance(maxAmount)
        } else {
            amount = "0.00000000"
        }
    }

    private func clearForm() {
        recipientAddress = ""
        amount = ""
        memo = ""
    }

    // MARK: - Formatting

    private func formatBalance(_ zatoshis: UInt64) -> String {
        let zcl = Double(zatoshis) / 100_000_000.0
        return String(format: "%.8f", zcl)
    }
}

#Preview {
    SendView()
        .environmentObject(WalletManager.shared)
        .environmentObject(NetworkManager.shared)
}
