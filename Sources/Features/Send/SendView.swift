import SwiftUI

/// Transaction sending progress step
struct SendProgressStep: Identifiable {
    let id: String
    let title: String
    var status: SendProgressStatus
    var detail: String?
    var progress: Double? // 0.0 to 1.0 for sub-progress
}

enum SendProgressStatus: Equatable {
    case pending
    case inProgress
    case completed
    case failed(String)
}

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

    // Progress tracking
    @State private var sendProgress: [SendProgressStep] = []
    @State private var currentStepIndex: Int = 0

    var body: some View {
        ZStack {
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

            // Progress overlay when sending
            if isSending {
                sendProgressOverlay
            }
        }
        .alert("Confirm Transaction", isPresented: $showConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Send") {
                sendTransaction()
            }
        } message: {
            Text("Send \(amount) ZCL to:\n\(recipientAddress.prefix(20))...?")
        }
        .sheet(isPresented: $showSuccess) {
            VStack(spacing: 16) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 50))
                    .foregroundColor(.green)

                Text("Transaction Sent!")
                    .font(System7Theme.titleFont(size: 16))

                VStack(alignment: .leading, spacing: 8) {
                    Text("Transaction ID:")
                        .font(System7Theme.bodyFont(size: 10))
                        .foregroundColor(System7Theme.darkGray)

                    Text(txId)
                        .font(System7Theme.monoFont(size: 9))
                        .padding(8)
                        .background(System7Theme.white)
                        .overlay(
                            Rectangle()
                                .stroke(System7Theme.black, lineWidth: 1)
                        )
                        .lineLimit(3)
                }
                .padding(.horizontal)

                HStack(spacing: 12) {
                    Button(action: {
                        UIPasteboard.general.string = txId
                    }) {
                        HStack {
                            Image(systemName: "doc.on.doc")
                            Text("Copy TxID")
                        }
                        .font(System7Theme.bodyFont(size: 11))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                    }
                    .background(System7Theme.lightGray)
                    .overlay(
                        Rectangle()
                            .stroke(System7Theme.black, lineWidth: 1)
                    )

                    Button(action: {
                        showSuccess = false
                        clearForm()
                    }) {
                        Text("Done")
                            .font(System7Theme.bodyFont(size: 11))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                    }
                    .background(System7Theme.lightGray)
                    .overlay(
                        Rectangle()
                            .stroke(System7Theme.black, lineWidth: 1)
                    )
                }
            }
            .padding(24)
            .background(System7Theme.lightGray)
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
        // Require Face ID / Touch ID authentication before sending
        let normalizedAmount = amount.replacingOccurrences(of: ",", with: ".")
        let zatoshis = UInt64((Double(normalizedAmount) ?? 0) * 100_000_000)

        BiometricAuthManager.shared.authenticateForSend(amount: zatoshis) { [self] success, error in
            if success {
                performSendTransaction()
            } else {
                errorMessage = "Authentication required to send transaction"
                showError = true
            }
        }
    }

    private func performSendTransaction() {
        isSending = true

        // Initialize progress steps with cypherpunk-friendly names
        sendProgress = [
            SendProgressStep(id: "validate", title: "Verifying privacy shield", status: .pending),
            SendProgressStep(id: "prover", title: "Activating Groth16 prover", status: .pending),
            SendProgressStep(id: "notes", title: "Selecting shielded notes", status: .pending),
            SendProgressStep(id: "tree", title: "Loading commitment tree", status: .pending, detail: "1M+ secrets"),
            SendProgressStep(id: "witness", title: "Building merkle witness", status: .pending),
            SendProgressStep(id: "proof", title: "Generating zk-SNARK proof", status: .pending),
            SendProgressStep(id: "broadcast", title: "Broadcasting to network", status: .pending)
        ]
        currentStepIndex = 0

        Task {
            do {
                // Step 1: Validate & Connect
                await updateStep("validate", status: .inProgress)
                if !networkManager.isConnected {
                    try await networkManager.connect()
                }
                await updateStep("validate", status: .completed)

                // Parse amount
                let normalizedAmount = amount.replacingOccurrences(of: ",", with: ".")
                guard let amountValue = Double(normalizedAmount) else {
                    throw WalletError.invalidAddress("Invalid amount")
                }
                let zatoshis = UInt64(amountValue * 100_000_000)

                // Step 2-6: Building transaction (handled by TransactionBuilder with callbacks)
                await updateStep("prover", status: .inProgress)

                // Send with progress callback
                let id = try await walletManager.sendShieldedWithProgress(
                    to: recipientAddress,
                    amount: zatoshis,
                    memo: memo.isEmpty ? nil : memo,
                    onProgress: { step, detail, progress in
                        Task { @MainActor in
                            self.handleProgressUpdate(step: step, detail: detail, progress: progress)
                        }
                    }
                )

                await MainActor.run {
                    txId = id
                    showSuccess = true
                    isSending = false
                    sendProgress = []
                }
            } catch {
                await MainActor.run {
                    // Mark current step as failed
                    if let currentIdx = sendProgress.firstIndex(where: { $0.status == .inProgress }) {
                        sendProgress[currentIdx].status = .failed(error.localizedDescription)
                    }
                    errorMessage = error.localizedDescription
                    showError = true
                    isSending = false
                }
            }
        }
    }

    @MainActor
    private func handleProgressUpdate(step: String, detail: String?, progress: Double?) {
        switch step {
        case "prover":
            updateStepSync("prover", status: .completed)
            updateStepSync("notes", status: .inProgress)
        case "notes":
            updateStepSync("notes", status: .completed)
            updateStepSync("tree", status: .inProgress, detail: detail)
        case "tree":
            if let p = progress, p < 1.0 {
                updateStepSync("tree", status: .inProgress, detail: detail, progress: p)
            } else {
                updateStepSync("tree", status: .completed)
                updateStepSync("witness", status: .inProgress)
            }
        case "witness":
            updateStepSync("witness", status: .completed)
            updateStepSync("proof", status: .inProgress, detail: "This may take 30-60 seconds...")
        case "proof":
            updateStepSync("proof", status: .completed)
            updateStepSync("broadcast", status: .inProgress)
        case "broadcast":
            updateStepSync("broadcast", status: .completed)
        default:
            break
        }
    }

    @MainActor
    private func updateStepSync(_ id: String, status: SendProgressStatus, detail: String? = nil, progress: Double? = nil) {
        if let index = sendProgress.firstIndex(where: { $0.id == id }) {
            sendProgress[index].status = status
            if let detail = detail {
                sendProgress[index].detail = detail
            }
            if let progress = progress {
                sendProgress[index].progress = progress
            }
        }
    }

    private func updateStep(_ id: String, status: SendProgressStatus, detail: String? = nil) async {
        await MainActor.run {
            updateStepSync(id, status: status, detail: detail)
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

    // MARK: - Progress Overlay

    private var sendProgressOverlay: some View {
        CypherpunkTxProgressView(
            steps: sendProgress,
            currentStep: sendProgress.first(where: { $0.status == .inProgress })?.id ?? "validate"
        )
    }

    private func progressStepRow(_ step: SendProgressStep) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                // Status icon
                Group {
                    switch step.status {
                    case .pending:
                        Image(systemName: "circle")
                            .foregroundColor(System7Theme.darkGray)
                    case .inProgress:
                        ProgressView()
                            .scaleEffect(0.6)
                    case .completed:
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    case .failed:
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.red)
                    }
                }
                .frame(width: 16, height: 16)

                // Step title
                Text(step.title)
                    .font(System7Theme.bodyFont(size: 10))
                    .foregroundColor(step.status == .pending ? System7Theme.darkGray : System7Theme.black)

                Spacer()

                // Detail text
                if let detail = step.detail {
                    Text(detail)
                        .font(System7Theme.bodyFont(size: 9))
                        .foregroundColor(System7Theme.darkGray)
                        .lineLimit(1)
                }
            }

            // Progress bar for tree loading
            if let progress = step.progress, progress > 0 && step.status == .inProgress {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(System7Theme.white)
                            .frame(height: 8)
                            .overlay(Rectangle().stroke(System7Theme.black, lineWidth: 1))

                        Rectangle()
                            .fill(Color.blue.opacity(0.7))
                            .frame(width: geometry.size.width * min(progress, 1.0), height: 6)
                            .padding(.leading, 1)
                            .padding(.top, 1)
                    }
                }
                .frame(height: 8)
                .padding(.leading, 24)
            }

            // Error message
            if case .failed(let error) = step.status {
                Text(error)
                    .font(System7Theme.bodyFont(size: 8))
                    .foregroundColor(.red)
                    .lineLimit(2)
                    .padding(.leading, 24)
            }
        }
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
