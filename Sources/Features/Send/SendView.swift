import SwiftUI
import AVFoundation
import AudioToolbox
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

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

/// Pre-built transaction data for instant send
struct PreparedTransaction {
    let rawTx: Data
    let spentNullifier: Data
    let toAddress: String
    let amount: UInt64
    let memo: String?
    let preparedAtHeight: UInt64
    let preparedAt: Date

    /// Check if transaction is still valid (not stale)
    /// Transaction is valid if prepared within last 2 minutes
    var isValid: Bool {
        Date().timeIntervalSince(preparedAt) < 120.0
    }
}

/// Send View - Send shielded ZCL transactions (z-to-z only!)
/// Themed design
struct SendView: View {
    @EnvironmentObject var walletManager: WalletManager
    @EnvironmentObject var networkManager: NetworkManager
    @EnvironmentObject var themeManager: ThemeManager

    /// Optional callback when send completes successfully - used to navigate back to balance tab
    var onSendComplete: (() -> Void)? = nil

    // Theme shortcut
    private var theme: AppTheme { themeManager.currentTheme }

    @State private var recipientAddress = ""
    @State private var amount = ""
    @State private var memo = ""
    @State private var isSending = false
    @State private var showConfirmation = false
    @State private var showSuccess = false
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var failedTxId = ""  // FIX #218: Track TXID for failed transactions (for copying)
    @State private var txId = ""
    @State private var isAddressValid = false
    @State private var isAddressTransparent = false
    @State private var showQRScanner = false
    @State private var scannedAddress: String = ""

    // Progress tracking
    @State private var sendProgress: [SendProgressStep] = []
    @State private var currentStepIndex: Int = 0

    // Clearing celebration state (mempool verified)
    @State private var showClearingCelebration = false
    @State private var clearingTime: TimeInterval = 0

    // Settlement celebration state (transaction mined/confirmed)
    @State private var showSettlementCelebration = false
    @State private var settlementTime: TimeInterval = 0

    // INSTANT SEND: Pre-built transaction state
    @State private var preparedTransaction: PreparedTransaction? = nil
    @State private var isPreparingTransaction = false
    @State private var preparationTask: Task<Void, Never>? = nil
    @State private var preparationProgress: String = ""

    // FIX #109: Debounce preparation to prevent multiple concurrent builds when typing
    @State private var preparationDebounceTask: Task<Void, Never>? = nil

    // FIX #210: Tor unavailable alert - offer to send without Tor
    @State private var showTorUnavailableAlert = false
    @State private var pendingSendWithoutTor = false

    var body: some View {
        ZStack {
            ScrollView {
                VStack(spacing: 16) {
                    // Recipient address
                    addressField

                    // Amount
                    amountField

                    // Memo (optional)
                    memoField

                    // Available balance
                    availableBalance

                    // Pending transaction warning
                    if hasPendingTransaction {
                        HStack(spacing: 8) {
                            Image(systemName: "clock.arrow.circlepath")
                                .foregroundColor(theme.warningColor)
                            Text("Transaction pending - wait for confirmation")
                                .font(theme.captionFont)
                                .foregroundColor(theme.warningColor)
                        }
                        .padding(.vertical, 8)
                    }

                    // INSTANT SEND: Preparation status indicator
                    if isPreparingTransaction {
                        HStack(spacing: 8) {
                            ProgressView()
                                .scaleEffect(0.7)
                            Text(preparationProgress.isEmpty ? "Preparing transaction..." : preparationProgress)
                                .font(theme.captionFont)
                                .foregroundColor(theme.primaryColor)
                        }
                        .padding(.vertical, 4)
                    } else if preparedTransaction != nil && isValidInput {
                        HStack(spacing: 8) {
                            Image(systemName: "bolt.fill")
                                .foregroundColor(theme.successColor)
                            Text("Transaction ready - instant send enabled")
                                .font(theme.captionFont)
                                .foregroundColor(theme.successColor)
                        }
                        .padding(.vertical, 4)
                    }

                    // FIX #174: Show why SEND is disabled when pending transaction exists
                    if hasPendingTransaction, let message = pendingTransactionMessage {
                        HStack(spacing: 6) {
                            Image(systemName: "clock.fill")
                                .foregroundColor(theme.warningColor)
                            Text(message)
                                .font(theme.captionFont)
                                .foregroundColor(theme.warningColor)
                        }
                        .padding(.vertical, 4)
                    }

                    // FIX #270: Show warning for external wallet spend (but don't disable SEND - cypherpunk ethos)
                    if hasExternalWalletSpend {
                        VStack(spacing: 4) {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                                Text("External wallet activity detected!")
                                    .font(theme.captionFont)
                                    .foregroundColor(.orange)
                            }
                            Text("Verify your balance is correct before sending. Move funds if needed.")
                                .font(.system(size: 10))
                                .foregroundColor(.orange.opacity(0.8))
                                .multilineTextAlignment(.center)
                        }
                        .padding(.vertical, 4)
                    }

                    // FIX #242: Show catch-up warning when wallet is syncing after returning from background
                    if walletManager.isCatchingUp {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .foregroundColor(.orange)
                            Text("Wallet syncing - \(walletManager.blocksBehind) blocks behind")
                                .font(theme.captionFont)
                                .foregroundColor(.orange)
                        }
                        .padding(.vertical, 4)
                    }

                    // FIX #410: Show blocked feature warning
                    if networkManager.isFeatureBlocked(.send) {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.red)
                            Text(networkManager.transactionBlockedReason ?? "Send temporarily disabled")
                                .font(theme.captionFont)
                                .foregroundColor(.red)
                        }
                        .padding(.vertical, 4)
                    }

                    // Send button
                    System7Button(title: sendButtonTitle) {
                        validateAndConfirm()
                    }
                    // FIX #242: Also disable during catch-up sync
                    // FIX #360: Also disable during database repair
                    // FIX #410: Also disable when health check blocks send
                    .disabled(isSending || !isValidInput || hasPendingTransaction || walletManager.isCatchingUp || walletManager.isRepairingHistory || networkManager.isFeatureBlocked(.send))
                }
                .padding()
            }

            // Progress overlay when sending
            if isSending {
                sendProgressOverlay
            }

            // Success overlay - displayed OVER everything when showSuccess is true
            // Using overlay instead of sheet to avoid nested sheet issues on macOS
            if showSuccess {
                // Cypherpunk-style success screen with dark background and green fluo
                ZStack {
                    Color.black.ignoresSafeArea()

                    VStack(spacing: 20) {
                        // Glowing checkmark
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 60))
                            .foregroundColor(NeonColors.progressFillEnd) // Bright fluo green
                            .shadow(color: NeonColors.progressFillEnd.opacity(0.8), radius: 20)

                        // Title changes based on transaction state: Broadcast → Cleared → Mined
                        if showSettlementCelebration {
                            // MINED - Transaction confirmed in a block
                            HStack(spacing: 8) {
                                Text("⛏️")
                                    .font(.system(size: 24))
                                Text("MINED!")
                                    .font(.system(size: 18, weight: .bold, design: .monospaced))
                                    .foregroundColor(Color.orange)
                            }
                            .shadow(color: Color.orange.opacity(0.5), radius: 5)

                            Text("Transaction confirmed in \(String(format: "%.0f", settlementTime))s")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(Color.orange.opacity(0.7))
                                .multilineTextAlignment(.center)
                                .padding(.horizontal)

                            Text("\"Proof of work complete. Your transaction is now immutable.\"")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(Color.orange.opacity(0.5))
                                .italic()
                                .multilineTextAlignment(.center)
                                .padding(.horizontal)
                        } else if showClearingCelebration {
                            // CLEARED - Transaction verified in mempool
                            HStack(spacing: 8) {
                                Text("🏦")
                                    .font(.system(size: 24))
                                Text("CLEARED!")
                                    .font(.system(size: 18, weight: .bold, design: .monospaced))
                                    .foregroundColor(Color.cyan)
                            }
                            .shadow(color: Color.cyan.opacity(0.5), radius: 5)

                            Text("Transaction verified in mempool in \(String(format: "%.1f", clearingTime))s")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(Color.cyan.opacity(0.7))
                                .multilineTextAlignment(.center)
                                .padding(.horizontal)
                        } else {
                            // BROADCAST - Peers accepted, waiting for mempool
                            Text("TRANSACTION BROADCAST")
                                .font(.system(size: 18, weight: .bold, design: .monospaced))
                                .foregroundColor(NeonColors.progressFillEnd)
                                .shadow(color: NeonColors.progressFillEnd.opacity(0.5), radius: 5)

                            Text("Your shielded transaction has been sent to the network.")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(Color.green.opacity(0.7))
                                .multilineTextAlignment(.center)
                                .padding(.horizontal)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("TXID:")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(Color.green.opacity(0.6))

                            Text(txId)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(NeonColors.progressFillEnd) // Fluo green
                                .padding(12)
                                .frame(maxWidth: .infinity)
                                .background(Color.green.opacity(0.1))
                                .overlay(
                                    Rectangle()
                                        .stroke(NeonColors.progressFillEnd.opacity(0.5), lineWidth: 1)
                                )
                                .lineLimit(2)
                                .minimumScaleFactor(0.7)
                        }
                        .padding(.horizontal, 20)

                        HStack(spacing: 16) {
                            // Copy button - cypherpunk style
                            Button(action: {
                                #if os(iOS)
                                UIPasteboard.general.string = txId
                                // Haptic feedback
                                let generator = UIImpactFeedbackGenerator(style: .medium)
                                generator.impactOccurred()
                                #elseif os(macOS)
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(txId, forType: .string)
                                #endif
                            }) {
                                HStack {
                                    Image(systemName: "doc.on.doc")
                                    Text("COPY TXID")
                                }
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .foregroundColor(.black)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 10)
                                .background(NeonColors.progressFillEnd)
                                .cornerRadius(4)
                            }

                            // Done button - navigates back to balance tab
                            Button(action: {
                                showSuccess = false
                                clearForm()
                                // Navigate back to main screen (balance tab) after overlay closes
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    onSendComplete?()
                                }
                            }) {
                                Text("DONE")
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                    .foregroundColor(NeonColors.progressFillEnd)
                                    .padding(.horizontal, 20)
                                    .padding(.vertical, 10)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 4)
                                            .stroke(NeonColors.progressFillEnd, lineWidth: 1)
                                    )
                            }
                        }
                        .padding(.top, 10)

                        // Cypherpunk quote
                        Text("\"Privacy is necessary for an open society.\"")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(Color.green.opacity(0.3))
                            .italic()
                            .padding(.top, 10)
                    }
                    .padding(30)
                }
            } // end if showSuccess
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.backgroundColor)
        .alert("Confirm Transaction", isPresented: $showConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Send") {
                sendTransaction()
            }
        } message: {
            Text("Send \(amount) ZCL to:\n\(recipientAddress.prefix(20))...?")
        }
        // FIX #218: Enhanced error alert with Copy TXID button for mempool rejections
        // FIX #232: Error messages now include "Why" and "What to do" explanations
        .alert("Transaction Issue", isPresented: $showError) {
            if !failedTxId.isEmpty {
                Button("Copy TXID") {
                    #if os(iOS)
                    UIPasteboard.general.string = failedTxId
                    #elseif os(macOS)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(failedTxId, forType: .string)
                    #endif
                }
            }
            Button("OK", role: .cancel) {
                failedTxId = ""  // Clear after dismissing
            }
        } message: {
            Text(enhanceErrorMessage(errorMessage))
        }
        // FIX #210: Tor unavailable alert - offer to send without Tor
        .alert("Tor Connection Issue", isPresented: $showTorUnavailableAlert) {
            Button("Wait for Tor", role: .cancel) {
                pendingSendWithoutTor = false
            }
            Button("Send without Tor") {
                pendingSendWithoutTor = true
                // Temporarily disable Tor for this send
                Task {
                    await TorManager.shared.temporarilyBypassTor()
                    await MainActor.run {
                        proceedWithSend()
                    }
                }
            }
        } message: {
            Text("Tor is enabled but not running. Your transaction cannot be broadcast anonymously.\n\nSend without Tor? Your IP may be visible to peers.")
        }
        .onChange(of: networkManager.outgoingClearingTrigger) { _ in
            // Sender's tx verified in mempool - show Clearing celebration!
            if let cleared = networkManager.justClearedOutgoing, showSuccess {
                clearingTime = cleared.clearingTime
                withAnimation {
                    showClearingCelebration = true
                }
                print("🏦 CLEARING! Send confirmed in mempool after \(String(format: "%.1f", cleared.clearingTime))s")
                // Clear trigger after handling
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    networkManager.justClearedOutgoing = nil
                }
            }
        }
        .onChange(of: networkManager.settlementCelebrationTrigger) { _ in
            // Sender's tx mined in a block - show Settlement celebration!
            if let confirmed = networkManager.justConfirmedTx, showSuccess, confirmed.isOutgoing {
                settlementTime = confirmed.settlementTime ?? 0
                withAnimation {
                    showSettlementCelebration = true
                }
                print("⛏️ MINED! Transaction confirmed after \(String(format: "%.0f", settlementTime))s")
                // Clear trigger after handling
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    networkManager.justConfirmedTx = nil
                }
            }
        }
        // INSTANT SEND: Trigger transaction preparation when input becomes valid
        .onChange(of: recipientAddress) { _ in
            triggerPreparationIfNeeded()
        }
        .onChange(of: amount) { _ in
            triggerPreparationIfNeeded()
        }
        .onChange(of: memo) { _ in
            // Only re-prepare if we already have a prepared tx
            if preparedTransaction != nil {
                invalidatePreparedTransaction()
                triggerPreparationIfNeeded()
            }
        }
        .onDisappear {
            // Cancel any ongoing preparation when view disappears
            preparationTask?.cancel()
            preparationTask = nil
        }
    }

    private var addressField: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Recipient Address (z-address only)")
                    .font(theme.captionFont)
                    .foregroundColor(theme.textSecondary)

                Spacer()

                #if os(iOS)
                // QR Code scanner button (iOS only)
                Button(action: {
                    showQRScanner = true
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "qrcode.viewfinder")
                            .font(.system(size: 12))
                        Text("Scan")
                            .font(theme.captionFont)
                    }
                    .foregroundColor(theme.buttonText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(theme.buttonBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: theme.cornerRadius)
                            .stroke(theme.borderColor, lineWidth: theme.borderWidth)
                    )
                    .cornerRadius(theme.cornerRadius)
                }
                .buttonStyle(.plain)
                #endif
            }

            TextField("zs1...", text: $recipientAddress)
                .font(theme.bodyFont)
                .foregroundColor(theme.textPrimary)
                #if os(iOS)
                .autocapitalization(.none)
                #endif
                .disableAutocorrection(true)
                .padding(8)
                .background(theme.surfaceColor)
                .overlay(
                    RoundedRectangle(cornerRadius: theme.cornerRadius)
                        .stroke(addressBorderColor, lineWidth: theme.borderWidth)
                )
                .cornerRadius(theme.cornerRadius)
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
        #if os(iOS)
        .sheet(isPresented: $showQRScanner, onDismiss: {
            // Apply scanned address after sheet dismisses
            if !scannedAddress.isEmpty {
                recipientAddress = scannedAddress
                scannedAddress = ""
            }
        }) {
            QRScannerView { scannedCode in
                // Store scanned address and dismiss
                if let code = scannedCode {
                    let address = extractAddressFromQR(code)
                    print("📷 QR scanned: \(address)")
                    scannedAddress = address
                }
                showQRScanner = false
            }
        }
        #endif
    }

    /// Extract address from QR code string (handles zcash: URIs and plain addresses)
    private func extractAddressFromQR(_ qrString: String) -> String {
        // Handle zcash: URI format
        if qrString.lowercased().hasPrefix("zcash:") {
            let withoutPrefix = String(qrString.dropFirst(6))
            // Remove any query parameters
            if let questionMark = withoutPrefix.firstIndex(of: "?") {
                return String(withoutPrefix[..<questionMark])
            }
            return withoutPrefix
        }
        // Handle zclassic: URI format
        if qrString.lowercased().hasPrefix("zclassic:") {
            let withoutPrefix = String(qrString.dropFirst(9))
            if let questionMark = withoutPrefix.firstIndex(of: "?") {
                return String(withoutPrefix[..<questionMark])
            }
            return withoutPrefix
        }
        // Plain address
        return qrString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var addressBorderColor: Color {
        if recipientAddress.isEmpty {
            return theme.borderColor
        } else if isAddressTransparent {
            return theme.errorColor
        } else if isAddressValid {
            return theme.successColor
        } else {
            return theme.warningColor
        }
    }

    @ViewBuilder
    private var addressValidationText: some View {
        if isAddressTransparent {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: "shield.slash")
                        .foregroundColor(theme.warningColor)
                    Text("Transparent addresses not yet supported")
                        .foregroundColor(theme.warningColor)
                }
                .font(theme.captionFont)
                Text("\"Privacy is a right, not a feature.\" — ZipherX is shielded-only.")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(theme.textSecondary)
                    .italic()
            }
        } else if isAddressValid {
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(theme.successColor)
                Text("Valid shielded address")
                    .foregroundColor(theme.successColor)
            }
            .font(theme.captionFont)
        } else {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(theme.warningColor)
                Text("Invalid address format")
                    .foregroundColor(theme.warningColor)
            }
            .font(theme.captionFont)
        }
    }

    private var amountField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Amount (ZCL)")
                .font(theme.captionFont)
                .foregroundColor(theme.textSecondary)

            HStack {
                TextField("0.00000000", text: $amount)
                    .font(theme.bodyFont)
                    .foregroundColor(theme.textPrimary)
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
                    .padding(8)
                    .background(theme.surfaceColor)
                    .overlay(
                        RoundedRectangle(cornerRadius: theme.cornerRadius)
                            .stroke(theme.borderColor, lineWidth: theme.borderWidth)
                    )
                    .cornerRadius(theme.cornerRadius)

                // Max button
                Button(action: setMaxAmount) {
                    Text("Max")
                        .font(theme.captionFont)
                        .foregroundColor(theme.buttonText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                }
                .background(theme.buttonBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: theme.cornerRadius)
                        .stroke(theme.borderColor, lineWidth: theme.borderWidth)
                )
                .cornerRadius(theme.cornerRadius)
            }

            // Fee notice
            Text("Network fee: 0.0001 ZCL")
                .font(theme.captionFont)
                .foregroundColor(theme.textSecondary)
        }
    }

    private var memoField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Encrypted Memo (optional)")
                .font(theme.captionFont)
                .foregroundColor(theme.textSecondary)

            TextField("Private message...", text: $memo)
                .font(theme.bodyFont)
                .foregroundColor(theme.textPrimary)
                .padding(8)
                .background(theme.surfaceColor)
                .overlay(
                    RoundedRectangle(cornerRadius: theme.cornerRadius)
                        .stroke(theme.borderColor, lineWidth: theme.borderWidth)
                )
                .cornerRadius(theme.cornerRadius)

            Text("Memo is encrypted end-to-end")
                .font(theme.captionFont)
                .foregroundColor(theme.textSecondary)
        }
    }

    private var availableBalance: some View {
        HStack {
            Text("Available:")
                .font(theme.captionFont)
                .foregroundColor(theme.textSecondary)

            Spacer()

            Text("\(formatBalance(walletManager.shieldedBalance)) ZCL")
                .font(theme.captionFont)
                .foregroundColor(theme.textPrimary)
        }
        .padding(8)
        .background(theme.surfaceColor)
        .overlay(
            RoundedRectangle(cornerRadius: theme.cornerRadius)
                .stroke(theme.borderColor, lineWidth: theme.borderWidth)
        )
        .cornerRadius(theme.cornerRadius)
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

        // SECURITY: Prevent integer overflow - max ~184 billion ZCL (UInt64.max / 100_000_000)
        // In practice, total supply is 21 million, so 100 million is a safe upper bound
        let maxZCL: Double = 100_000_000.0  // 100 million ZCL
        guard amountValue <= maxZCL else {
            return false
        }

        // Check sufficient funds
        // Use round() to avoid floating-point precision loss (e.g., 0.0012 becoming 0.00119999...)
        let zatoshis = UInt64(round(amountValue * 100_000_000))
        let fee: UInt64 = 10000
        return zatoshis + fee <= walletManager.shieldedBalance
    }

    /// Check if there's a pending outgoing transaction that hasn't confirmed yet
    /// FIX #270: Cypherpunk ethos - Don't disable SEND for external wallet spends
    /// External spends just show a warning, user can still choose to send
    private var hasPendingTransaction: Bool {
        // FIX #301: Only disable SEND for OUR pending transactions, NOT external wallet spends
        // External spends show a warning but user must be able to quickly move remaining funds
        if networkManager.hasOurPendingOutgoing {
            return true  // Disable SEND only for OUR pending transactions
        }
        // Check both mempoolOutgoing and lastSendTimestamp with pending balance
        if networkManager.mempoolOutgoing > 0 {
            return true
        }
        // Also check if we sent recently and balance hasn't stabilized
        if let lastSend = walletManager.lastSendTimestamp,
           Date().timeIntervalSince(lastSend) < 300.0, // 5 minutes window
           walletManager.pendingBalance > 0 {
            return true
        }
        return false
    }

    /// FIX #270: Check if there's an external wallet spend to show warning
    private var hasExternalWalletSpend: Bool {
        return networkManager.externalWalletSpendDetected != nil
    }

    /// FIX #301: Reason why SEND is disabled (for user display)
    /// Only shown for OUR pending transactions, not external wallet spends
    private var pendingTransactionMessage: String? {
        // FIX #301: Only show blocking message for OUR pending transactions
        if networkManager.hasOurPendingOutgoing {
            return networkManager.pendingTransactionReason ?? "Awaiting confirmation for your transaction"
        }
        if networkManager.mempoolOutgoing > 0 && networkManager.externalWalletSpendDetected == nil {
            return "Awaiting confirmation for your transaction"
        }
        if let lastSend = walletManager.lastSendTimestamp,
           Date().timeIntervalSince(lastSend) < 300.0,
           walletManager.pendingBalance > 0 {
            return "Previous transaction not yet confirmed"
        }
        return nil
    }

    /// Dynamic button title based on state
    private var sendButtonTitle: String {
        if isSending {
            return "Sending..."
        } else if networkManager.isFeatureBlocked(.send) {
            // FIX #410: Show blocked state
            return "Unavailable"
        } else if walletManager.isRepairingHistory {
            // FIX #360: Show repair state
            return "Repairing..."
        } else if walletManager.isCatchingUp {
            // FIX #242: Show syncing state
            return "Syncing..."
        } else if hasPendingTransaction {
            return "Pending..."
        } else {
            return "Send ZCL"
        }
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
            errorMessage = "Transparent addresses (t-addresses) are not yet supported. ZipherX prioritizes privacy — only shielded z-addresses are currently available.\n\n\"Privacy is necessary for an open society.\" — A Cypherpunk's Manifesto"
            showError = true
            return
        }

        showConfirmation = true
    }

    private func sendTransaction() {
        // FIX #210: Check if Tor mode is enabled but Tor isn't running
        Task {
            let torMode = await TorManager.shared.mode
            let torConnected = await TorManager.shared.connectionState.isConnected
            let socksPort = await TorManager.shared.socksPort

            if torMode == .enabled && (!torConnected || socksPort == 0) {
                // Tor is enabled but not running - show alert
                await MainActor.run {
                    print("⚠️ FIX #210: Tor enabled but not running - showing alert")
                    showTorUnavailableAlert = true
                }
                return
            }

            // Tor is fine or disabled - proceed with send
            await MainActor.run {
                proceedWithSend()
            }
        }
    }

    /// Actually proceed with the send (after Tor check passed or user chose to bypass)
    private func proceedWithSend() {
        // Require Face ID / Touch ID authentication before sending
        let normalizedAmount = amount.replacingOccurrences(of: ",", with: ".")
        // Use round() to avoid floating-point precision loss
        let zatoshis = UInt64(round((Double(normalizedAmount) ?? 0) * 100_000_000))

        BiometricAuthManager.shared.authenticateForSend(amount: zatoshis) { [self] success, error in
            if success {
                // INSTANT SEND: Check if we have a valid prepared transaction
                if let prepared = preparedTransaction,
                   prepared.isValid,
                   prepared.toAddress == recipientAddress,
                   prepared.amount == zatoshis,
                   prepared.memo == (memo.isEmpty ? nil : memo) {
                    // Use prepared transaction with block height check
                    performInstantSend(prepared: prepared)
                } else {
                    // Fall back to normal send (no prepared tx available)
                    performSendTransaction()
                }
            } else {
                errorMessage = "Authentication required to send transaction"
                showError = true
            }
        }
    }

    /// Instant send using pre-built transaction (with block height verification)
    private func performInstantSend(prepared: PreparedTransaction) {
        isSending = true

        // Show minimal progress (only broadcast step since tx is already built)
        sendProgress = [
            SendProgressStep(id: "validate", title: "Verifying block height", status: .inProgress),
            SendProgressStep(id: "broadcast", title: "Broadcasting & verifying", status: .pending)
        ]

        Task {
            do {
                // CRITICAL: Check if block height changed since preparation
                let currentHeight: UInt64
                do {
                    currentHeight = try await networkManager.getChainHeight()
                } catch {
                    currentHeight = networkManager.chainHeight
                }

                if currentHeight != prepared.preparedAtHeight {
                    // Block height changed! Transaction might be stale
                    // The witness/anchor could be invalid for the new chain state
                    await MainActor.run {
                        print("⚠️ Block height changed: \(prepared.preparedAtHeight) → \(currentHeight)")
                        // Show warning but still try to broadcast
                        // The network will reject if the anchor is invalid
                        sendProgress[0].status = .completed
                        sendProgress[0].detail = "Height changed: \(prepared.preparedAtHeight)→\(currentHeight)"
                    }
                } else {
                    await MainActor.run {
                        sendProgress[0].status = .completed
                        sendProgress[0].detail = "Height verified: \(currentHeight)"
                    }
                }

                await MainActor.run {
                    sendProgress[1].status = .inProgress
                }

                // Record last send timestamp
                await MainActor.run {
                    walletManager.recordSendTimestamp()
                }

                // Broadcast the prepared transaction
                let networkMgr = NetworkManager.shared
                let broadcastResult = try await networkMgr.broadcastTransactionWithProgress(prepared.rawTx, amount: prepared.amount) { phase, detail, progress in
                    Task { @MainActor in
                        self.handleProgressUpdate(step: phase, detail: detail, progress: progress)
                    }
                }

                // VUL-002: Extract txId from BroadcastResult
                let broadcastedTxId = broadcastResult.txId

                // VUL-002 + FIX #245 + FIX #349: Handle mempool verification with peer acceptance fallback
                // FIX #349: If peers EXPLICITLY rejected, do NOT fallback to peer acceptance!
                // If peers accepted but mempool check timed out, record TX anyway
                if !broadcastResult.mempoolVerified {
                    if broadcastResult.rejectCount > 0 {
                        // FIX #349: Peers EXPLICITLY rejected - this is NOT a slow network issue!
                        print("🚨 FIX #349 SendView: \(broadcastResult.rejectCount) peers REJECTED transaction!")
                        print("🚨 FIX #349 SendView: txId=\(broadcastedTxId), accepts=\(broadcastResult.peerCount), rejects=\(broadcastResult.rejectCount)")
                        throw WalletError.transactionFailed("""
                            🚨 TRANSACTION REJECTED 🚨

                            Your transaction was explicitly rejected by \(broadcastResult.rejectCount) network peer(s). This typically means:
                            • The transaction anchor is invalid (blockchain state changed)
                            • A previous transaction already spent these notes
                            • Network consensus rejected the proof

                            🔒 YOUR FUNDS ARE SAFE
                            No transaction was recorded in your wallet.

                            💡 WHAT TO DO:
                            Go to Settings → Repair Database, then try again.

                            📋 TXID (for reference):
                            \(broadcastedTxId)

                            "Privacy is necessary for an open society."
                            — A Cypherpunk's Manifesto
                            """)
                    } else if broadcastResult.peerCount >= 2 {
                        // FIX #389 v2: Multiple peers accepted but P2P mempool verification FAILED
                        // This is a critical error - peers ACK'd but TX is NOT in network mempool
                        // DO NOT trust peer ACKs - they may have dropped the TX after acknowledging
                        print("🚨 FIX #389 v2 SendView: \(broadcastResult.peerCount) peers accepted but TX NOT in mempool!")
                        print("🚨 FIX #389 v2 SendView: txId=\(broadcastedTxId) - broadcast may have failed despite peer ACKs")
                        throw WalletError.transactionFailed("""
                            ⚠️ BROADCAST NOT CONFIRMED ⚠️

                            Your transaction was accepted by \(broadcastResult.peerCount) peers but could NOT be verified in the network mempool.

                            Peers may have acknowledged your transaction but dropped it before adding to their mempool. This can happen due to:
                            • Network propagation issues
                            • Peers with full mempools
                            • Temporary network congestion

                            🔒 YOUR FUNDS ARE SAFE
                            No transaction was recorded in your wallet.

                            💡 WHAT TO DO:
                            Wait 1-2 minutes, check your balance. If unchanged, try sending again.

                            📋 TXID (for reference):
                            \(broadcastedTxId)

                            "Privacy is necessary for an open society in the electronic age."
                            — A Cypherpunk's Manifesto
                            """)
                    } else if broadcastResult.peerCount == 1 {
                        // FIX #389: Only 1 peer accepted AND mempool verification failed
                        // Single peer may have ACK'd but not actually propagated the TX
                        print("🚨 FIX #389 SendView: Only 1 peer accepted but TX NOT found in network!")
                        print("🚨 FIX #389 SendView: txId=\(broadcastedTxId) - single peer acceptance is NOT reliable")
                        throw WalletError.transactionFailed("""
                            ⚠️ BROADCAST UNCONFIRMED ⚠️

                            Your transaction was accepted by 1 peer but could NOT be verified in the network mempool. This may indicate:
                            • The peer acknowledged but dropped the transaction
                            • Network propagation issues
                            • The transaction may not have been broadcast successfully

                            🔒 YOUR FUNDS ARE SAFE
                            No transaction was recorded in your wallet.

                            💡 WHAT TO DO:
                            Wait a few minutes and check your balance. If unchanged, try sending again.

                            📋 TXID (for reference):
                            \(broadcastedTxId)

                            "We the Cypherpunks are dedicated to building anonymous systems."
                            — A Cypherpunk's Manifesto
                            """)
                    } else {
                        // NO peers accepted AND mempool failed - true rejection
                        print("🚨 VUL-002 SendView: MEMPOOL REJECTED - Not writing to database!")
                        print("🚨 VUL-002 SendView: txId=\(broadcastedTxId), peers=\(broadcastResult.peerCount), mempool=false")
                        // FIX #218: Cypherpunk-styled warning with TXID for reference
                        throw WalletError.transactionFailed("""
                            ⚡ MEMPOOL REJECTION ⚡

                            The network nodes did not propagate your transaction to their mempools. This can happen during network congestion or peer instability.

                            🔒 YOUR FUNDS ARE SAFE
                            No transaction was recorded in your wallet.

                            📋 TXID (for reference):
                            \(broadcastedTxId)

                            "We cannot expect governments, corporations, or other large, faceless organizations to grant us privacy. We must defend our own privacy."
                            — A Cypherpunk's Manifesto
                            """)
                    }
                }

                if broadcastResult.mempoolVerified {
                    print("✅ VUL-002 SendView: Mempool VERIFIED - TX will be recorded on confirmation")
                } else {
                    print("✅ FIX #245 SendView: Peers accepted TX - will be recorded on confirmation")
                }

                // FIX #350: Track as pending outgoing with FULL info for database write on CONFIRMATION
                // DO NOT write to database here - only when TX is confirmed in a block!
                let pendingFee: UInt64 = 10_000
                let pendingTx = PendingOutgoingTx(
                    txid: broadcastedTxId,
                    amount: prepared.amount,
                    fee: pendingFee,
                    toAddress: prepared.toAddress,
                    memo: prepared.memo,
                    hashedNullifier: prepared.spentNullifier,
                    rawTxData: prepared.rawTx,
                    timestamp: Date()
                )
                await networkMgr.trackPendingOutgoingFull(pendingTx)
                print("📤 FIX #350: TX tracked as pending - database write DEFERRED until confirmation")

                // Send notification
                NotificationManager.shared.notifySent(amount: prepared.amount, txid: broadcastedTxId, memo: prepared.memo)

                await MainActor.run {
                    self.txId = broadcastedTxId
                    showSuccess = true
                    isSending = false
                    sendProgress = []
                    // Clear prepared transaction after successful send
                    invalidatePreparedTransaction()
                }

                print("⚡ INSTANT SEND complete! Txid: \(broadcastedTxId)")

                // FIX #210: Restore Tor after transaction completes
                await TorManager.shared.restoreAfterSingleTxBypass()

                // Refresh balance in background
                Task {
                    try? await walletManager.refreshBalance()
                }
            } catch {
                // If broadcast fails (e.g., stale anchor), fall back to normal send
                await MainActor.run {
                    print("⚠️ Instant send failed: \(error.localizedDescription)")
                    // Clear prepared transaction
                    invalidatePreparedTransaction()
                }

                // Check if it's likely an anchor mismatch (transaction rejected)
                let errorStr = error.localizedDescription.lowercased()
                if errorStr.contains("rejected") || errorStr.contains("invalid") || errorStr.contains("anchor") {
                    // Rebuild and retry
                    await MainActor.run {
                        sendProgress = []
                        isSending = false
                    }
                    // Start normal send flow (will rebuild transaction)
                    await MainActor.run {
                        performSendTransaction()
                    }
                } else {
                    await MainActor.run {
                        errorMessage = error.localizedDescription
                        // FIX #218: Extract TXID from error message for copy button
                        failedTxId = extractTxIdFromError(error.localizedDescription)
                        showError = true
                        isSending = false
                    }
                    // FIX #210: Restore Tor after transaction fails
                    await TorManager.shared.restoreAfterSingleTxBypass()
                }
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
            SendProgressStep(id: "broadcast", title: "Broadcasting & verifying", status: .pending)
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
                // Use round() to avoid floating-point precision loss (e.g., 0.0012 -> 119999 instead of 120000)
                let zatoshis = UInt64(round(amountValue * 100_000_000))

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

                // FIX #210: Restore Tor after transaction completes
                await TorManager.shared.restoreAfterSingleTxBypass()
            } catch {
                await MainActor.run {
                    // Mark current step as failed
                    if let currentIdx = sendProgress.firstIndex(where: { $0.status == .inProgress }) {
                        sendProgress[currentIdx].status = .failed(error.localizedDescription)
                    }
                    errorMessage = error.localizedDescription
                    // FIX #218: Extract TXID from error message for copy button
                    failedTxId = extractTxIdFromError(error.localizedDescription)
                    showError = true
                    isSending = false
                }

                // FIX #210: Restore Tor after transaction fails
                await TorManager.shared.restoreAfterSingleTxBypass()
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
            // Witness step can have sub-progress for rebuilding (fetching blocks)
            if let p = progress, p < 1.0 {
                updateStepSync("witness", status: .inProgress, detail: detail, progress: p)
            } else {
                updateStepSync("witness", status: .completed)
                updateStepSync("proof", status: .inProgress, detail: "This may take 30-60 seconds...")
            }
        case "proof":
            updateStepSync("proof", status: .completed)
            updateStepSync("broadcast", status: .inProgress)
        case "peers":
            // CRITICAL FIX: Do NOT show success immediately on peer accept!
            // Peers may accept into local mempool but reject during validation.
            // Wait for mempool verification (sendShieldedWithProgress returns) before showing success.
            // Just extract and store txid for later use, but DON'T show success yet.
            if let detail = detail, let txidRange = detail.range(of: "[txid:") {
                let afterTxid = detail[txidRange.upperBound...]
                if let endBracket = afterTxid.firstIndex(of: "]") {
                    let extractedTxid = String(afterTxid[..<endBracket])
                    // Store txid for later (will be used when send completes successfully)
                    if txId.isEmpty && !extractedTxid.isEmpty {
                        txId = extractedTxid
                        print("📋 Txid received from peer accept: \(extractedTxid.prefix(16))... (waiting for mempool verification)")
                    }
                }
            }
            // Update broadcast step progress (but don't show success yet!)
            updateStepSync("broadcast", status: .inProgress, detail: detail?.replacingOccurrences(of: #"\s*\[txid:[^\]]+\]"#, with: "", options: .regularExpression), progress: progress)
        case "verify":
            // FIX #118: Handle mempool verification phase
            // NetworkManager sends "verify" phase during mempool checking
            if progress == 1.0 || detail?.contains("mempool") == true {
                // Mempool verified - show success!
                updateStepSync("broadcast", status: .completed, detail: detail ?? "In mempool - awaiting miners")
                // Show success screen now that mempool is verified
                if !txId.isEmpty {
                    showSuccess = true
                    isSending = false
                }
            } else {
                // Still verifying
                updateStepSync("broadcast", status: .inProgress, detail: detail, progress: progress)
            }
        case "error":
            // CRITICAL: Handle broadcast error - transaction was rejected!
            let errorDetail = detail ?? "Transaction rejected by network"
            updateStepSync("broadcast", status: .failed(errorDetail), detail: errorDetail)
            errorMessage = errorDetail
            // FIX #218: Extract TXID from error message for copy button
            failedTxId = extractTxIdFromError(errorDetail)
            showError = true
            isSending = false
        case "broadcast":
            // Broadcast step has sub-progress for peer propagation and verification
            if let p = progress, p < 1.0 {
                updateStepSync("broadcast", status: .inProgress, detail: detail, progress: p)
            } else if progress == 1.0 || detail?.contains("Confirmed") == true {
                updateStepSync("broadcast", status: .completed, detail: "Transaction confirmed!")
            } else {
                updateStepSync("broadcast", status: .inProgress, detail: detail)
            }
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
        invalidatePreparedTransaction()
    }

    // FIX #218: Extract TXID from error message (64-character hex string after "TXID")
    private func extractTxIdFromError(_ message: String) -> String {
        // Look for patterns like "TXID (for reference):\n" followed by a 64-char hex
        let txidPatterns = [
            "TXID \\(for reference\\):\\s*([a-fA-F0-9]{64})",
            "txid[:\\s]+([a-fA-F0-9]{64})",
            "([a-fA-F0-9]{64})"  // Fallback: any 64-char hex string
        ]

        for pattern in txidPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: message, options: [], range: NSRange(message.startIndex..., in: message)),
               let range = Range(match.range(at: 1), in: message) {
                return String(message[range])
            }
        }
        return ""
    }

    // MARK: - FIX #232: Error Explanation Helper

    /// Enhance error messages with explanations and suggested actions
    private func enhanceErrorMessage(_ message: String) -> String {
        let lowerMessage = message.lowercased()

        // Transaction rejected by mempool
        if lowerMessage.contains("mempool") || lowerMessage.contains("rejected") {
            return """
            \(message)

            Why: The network rejected your transaction. This can happen if:
            • Another transaction spent your notes first
            • Network congestion caused a timeout
            • The transaction was malformed

            What to do: Wait a few minutes and try again. Your funds are safe.
            """
        }

        // Insufficient funds
        if lowerMessage.contains("insufficient") || lowerMessage.contains("not enough") {
            return """
            \(message)

            Why: You don't have enough confirmed ZCL for this amount plus the network fee (0.0001 ZCL).

            What to do: Wait for pending transactions to confirm, or reduce the amount.
            """
        }

        // Witness/anchor mismatch
        if lowerMessage.contains("witness") || lowerMessage.contains("anchor") || lowerMessage.contains("merkle") {
            return """
            \(message)

            Why: The cryptographic proof couldn't be generated. This usually means the blockchain state changed while building the transaction.

            What to do: Go to Settings → Repair Database, then try again.
            """
        }

        // Network/peer issues
        if lowerMessage.contains("peer") || lowerMessage.contains("network") || lowerMessage.contains("connection") || lowerMessage.contains("timeout") {
            return """
            \(message)

            Why: Could not connect to enough peers to broadcast your transaction securely.

            What to do: Check your internet connection and wait for peer connections (shown in status bar).
            """
        }

        // Proof generation failure
        if lowerMessage.contains("proof") || lowerMessage.contains("groth16") || lowerMessage.contains("zk-snark") {
            return """
            \(message)

            Why: The zero-knowledge proof generation failed. This is rare and usually indicates corrupted wallet state.

            What to do: Go to Settings → Repair Database → Full Rescan.
            """
        }

        // Authentication required
        if lowerMessage.contains("authentication") || lowerMessage.contains("biometric") {
            return """
            \(message)

            Why: Face ID / Touch ID is required to authorize transactions for your security.

            What to do: Authenticate with Face ID, Touch ID, or your device passcode.
            """
        }

        // Default: return original message
        return message
    }

    // MARK: - Instant Send Preparation Functions

    /// Invalidate any prepared transaction
    private func invalidatePreparedTransaction() {
        // FIX #109: Also cancel debounce task
        preparationDebounceTask?.cancel()
        preparationDebounceTask = nil
        preparationTask?.cancel()
        preparationTask = nil
        preparedTransaction = nil
        isPreparingTransaction = false
        preparationProgress = ""
    }

    /// Check if we should trigger transaction preparation
    /// FIX #109: Added 1.5s debounce to prevent multiple concurrent builds when user is typing
    private func triggerPreparationIfNeeded() {
        // Only prepare if input is valid
        guard isValidInput && !isSending && !hasPendingTransaction else {
            // If input became invalid, cancel preparation
            if !isValidInput && isPreparingTransaction {
                invalidatePreparedTransaction()
            }
            // Also cancel debounce task
            preparationDebounceTask?.cancel()
            preparationDebounceTask = nil
            return
        }

        // Check if we already have a valid prepared transaction for this input
        if let prepared = preparedTransaction,
           prepared.isValid,
           prepared.toAddress == recipientAddress,
           prepared.amount == currentZatoshis,
           prepared.memo == (memo.isEmpty ? nil : memo) {
            // Already prepared and valid
            return
        }

        // FIX #109: Cancel any existing debounce task (user is still typing)
        preparationDebounceTask?.cancel()

        // FIX #109: Debounce - wait 1.5 seconds after user stops typing before preparing
        // This prevents launching multiple concurrent witness rebuilds which cancel each other
        preparationDebounceTask = Task {
            do {
                // Wait 1.5 seconds for user to finish typing
                try await Task.sleep(nanoseconds: 1_500_000_000)

                // After debounce, check if task was cancelled (user typed again)
                try Task.checkCancellation()

                // Now actually start preparation
                await MainActor.run {
                    // Cancel any existing preparation
                    preparationTask?.cancel()

                    // Start new preparation
                    isPreparingTransaction = true
                    preparationProgress = "Initializing..."

                    preparationTask = Task {
                        await prepareTransaction()
                    }
                }
            } catch {
                // Task was cancelled (user typed again) - this is normal, ignore
            }
        }
    }

    /// Current amount in zatoshis
    private var currentZatoshis: UInt64 {
        let normalizedAmount = amount.replacingOccurrences(of: ",", with: ".")
        guard let amountValue = Double(normalizedAmount) else { return 0 }
        return UInt64(round(amountValue * 100_000_000))
    }

    /// Prepare transaction in background (build zk-SNARK proof)
    private func prepareTransaction() async {
        do {
            // Get current chain height BEFORE building
            let heightBeforePrep: UInt64
            do {
                heightBeforePrep = try await networkManager.getChainHeight()
            } catch {
                heightBeforePrep = networkManager.chainHeight
            }

            await MainActor.run {
                preparationProgress = "Connecting to network..."
            }

            // Ensure network connection
            if !networkManager.isConnected {
                try await networkManager.connect()
            }

            // Check for cancellation
            try Task.checkCancellation()

            await MainActor.run {
                preparationProgress = "Loading prover..."
            }

            // Get the values we need for preparation
            let toAddress = recipientAddress
            let zatoshis = currentZatoshis
            let memoText = memo.isEmpty ? nil : memo

            // Get spending key
            let secureStorage = SecureKeyStorage()
            let secureKey = try secureStorage.retrieveSpendingKeySecure()

            await MainActor.run {
                preparationProgress = "Building transaction..."
            }

            // Build the transaction
            let txBuilder = TransactionBuilder()
            let (rawTx, spentNullifier) = try await txBuilder.buildShieldedTransactionWithProgress(
                from: walletManager.zAddress,
                to: toAddress,
                amount: zatoshis,
                memo: memoText,
                spendingKey: secureKey.data,
                onProgress: { step, detail, _ in
                    Task { @MainActor in
                        switch step {
                        case "prover": self.preparationProgress = "Prover ready"
                        case "notes": self.preparationProgress = "Notes selected"
                        case "tree": self.preparationProgress = detail ?? "Loading tree..."
                        case "witness": self.preparationProgress = "Building witness..."
                        case "proof": self.preparationProgress = "Generating zk-SNARK..."
                        default: break
                        }
                    }
                }
            )

            // Zero spending key immediately
            secureKey.zero()

            // Check for cancellation
            try Task.checkCancellation()

            // Store prepared transaction
            await MainActor.run {
                self.preparedTransaction = PreparedTransaction(
                    rawTx: rawTx,
                    spentNullifier: spentNullifier,
                    toAddress: toAddress,
                    amount: zatoshis,
                    memo: memoText,
                    preparedAtHeight: heightBeforePrep,
                    preparedAt: Date()
                )
                self.isPreparingTransaction = false
                self.preparationProgress = ""
                print("⚡ Transaction prepared at height \(heightBeforePrep) - ready for instant send!")
            }
        } catch is CancellationError {
            await MainActor.run {
                isPreparingTransaction = false
                preparationProgress = ""
            }
        } catch {
            await MainActor.run {
                isPreparingTransaction = false
                preparationProgress = ""
                // Don't show error - just silently fail preparation
                // User can still send normally
                print("⚠️ Transaction preparation failed: \(error.localizedDescription)")
            }
        }
    }

    private func copyToClipboard(_ string: String) {
        #if os(iOS)
        UIPasteboard.general.string = string
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #endif
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
                            .foregroundColor(theme.textSecondary)
                    case .inProgress:
                        ProgressView()
                            .scaleEffect(0.6)
                    case .completed:
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(theme.successColor)
                    case .failed:
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(theme.errorColor)
                    }
                }
                .frame(width: 16, height: 16)

                // Step title
                Text(step.title)
                    .font(theme.captionFont)
                    .foregroundColor(step.status == .pending ? theme.textSecondary : theme.textPrimary)

                Spacer()

                // Detail text
                if let detail = step.detail {
                    Text(detail)
                        .font(theme.captionFont)
                        .foregroundColor(theme.textSecondary)
                        .lineLimit(1)
                }
            }

            // Progress bar for tree loading
            if let progress = step.progress, progress > 0 && step.status == .inProgress {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: theme.cornerRadius)
                            .fill(theme.surfaceColor)
                            .frame(height: 8)
                            .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius).stroke(theme.borderColor, lineWidth: theme.borderWidth))

                        RoundedRectangle(cornerRadius: theme.cornerRadius)
                            .fill(theme.primaryColor)
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
                    .font(theme.captionFont)
                    .foregroundColor(theme.errorColor)
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
        .environmentObject(ThemeManager.shared)
}

// MARK: - QR Scanner View (iOS only)

#if os(iOS)
/// Camera-based QR code scanner view
struct QRScannerView: UIViewControllerRepresentable {
    let onCodeScanned: (String?) -> Void

    func makeUIViewController(context: Context) -> QRScannerViewController {
        let controller = QRScannerViewController()
        controller.onCodeScanned = onCodeScanned
        return controller
    }

    func updateUIViewController(_ uiViewController: QRScannerViewController, context: Context) {}
}

/// UIKit view controller for QR scanning
class QRScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var captureSession: AVCaptureSession?
    var previewLayer: AVCaptureVideoPreviewLayer?
    var onCodeScanned: ((String?) -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupCamera()
        setupUI()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.captureSession?.startRunning()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        captureSession?.stopRunning()
    }

    private func setupCamera() {
        captureSession = AVCaptureSession()

        guard let videoCaptureDevice = AVCaptureDevice.default(for: .video) else {
            showError("No camera available")
            return
        }

        let videoInput: AVCaptureDeviceInput

        do {
            videoInput = try AVCaptureDeviceInput(device: videoCaptureDevice)
        } catch {
            showError("Camera access denied")
            return
        }

        if captureSession?.canAddInput(videoInput) == true {
            captureSession?.addInput(videoInput)
        } else {
            showError("Could not add camera input")
            return
        }

        let metadataOutput = AVCaptureMetadataOutput()

        if captureSession?.canAddOutput(metadataOutput) == true {
            captureSession?.addOutput(metadataOutput)
            metadataOutput.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
            metadataOutput.metadataObjectTypes = [.qr]
        } else {
            showError("Could not add metadata output")
            return
        }

        previewLayer = AVCaptureVideoPreviewLayer(session: captureSession!)
        previewLayer?.frame = view.layer.bounds
        previewLayer?.videoGravity = .resizeAspectFill
        view.layer.addSublayer(previewLayer!)
    }

    private func setupUI() {
        // Add scanning frame overlay
        let overlayView = UIView()
        overlayView.backgroundColor = .clear
        overlayView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(overlayView)

        NSLayoutConstraint.activate([
            overlayView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            overlayView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            overlayView.widthAnchor.constraint(equalToConstant: 250),
            overlayView.heightAnchor.constraint(equalToConstant: 250)
        ])

        overlayView.layer.borderColor = UIColor.white.cgColor
        overlayView.layer.borderWidth = 2
        overlayView.layer.cornerRadius = 12

        // Add close button
        let closeButton = UIButton(type: .system)
        closeButton.setTitle("Cancel", for: .normal)
        closeButton.setTitleColor(.white, for: .normal)
        closeButton.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        closeButton.layer.cornerRadius = 8
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        view.addSubview(closeButton)

        NSLayoutConstraint.activate([
            closeButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -30),
            closeButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 120),
            closeButton.heightAnchor.constraint(equalToConstant: 44)
        ])

        // Add instruction label
        let label = UILabel()
        label.text = "Scan QR Code"
        label.textColor = .white
        label.font = UIFont.systemFont(ofSize: 16, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)

        NSLayoutConstraint.activate([
            label.bottomAnchor.constraint(equalTo: overlayView.topAnchor, constant: -20),
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor)
        ])
    }

    @objc private func closeTapped() {
        onCodeScanned?(nil)
    }

    private func showError(_ message: String) {
        let label = UILabel()
        label.text = message
        label.textColor = .white
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    // MARK: - AVCaptureMetadataOutputObjectsDelegate

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        captureSession?.stopRunning()

        if let metadataObject = metadataObjects.first,
           let readableObject = metadataObject as? AVMetadataMachineReadableCodeObject,
           let stringValue = readableObject.stringValue {
            AudioServicesPlaySystemSound(SystemSoundID(kSystemSoundID_Vibrate))
            onCodeScanned?(stringValue)
        } else {
            onCodeScanned?(nil)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.layer.bounds
    }
}
#endif
