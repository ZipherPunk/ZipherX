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

    // FIX #1325: Static cache persists across SendView lifecycle.
    // When user closes Send window and reopens with same parameters,
    // reuse the prepared TX instead of regenerating Groth16 proofs (~25s).
    // Invalidated by: 2-minute timeout, parameter change, balance change, successful send.
    static var cached: PreparedTransaction? = nil
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
    @State private var hasAttemptedWitnessRepair = false  // FIX #750: Track if we've tried auto-repair
    @State private var isAddressValid = false
    @State private var isAddressTransparent = false
    @State private var isAddressSprout = false  // FIX #1455: Detect Sprout z-addresses
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
    @State private var preparationError: String? = nil  // FIX #1314: Show error when pre-verification fails
    @State private var proofCountdownTimer: Timer? = nil  // FIX #1326: Live countdown during proof generation
    @State private var preBuildStartTime: Date? = nil  // FIX #1327: Track pre-build start for elapsed timer

    // FIX #109: Debounce preparation to prevent multiple concurrent builds when typing
    @State private var preparationDebounceTask: Task<Void, Never>? = nil

    // FIX #210: Tor unavailable alert - offer to send without Tor
    @State private var showTorUnavailableAlert = false
    @State private var pendingSendWithoutTor = false

    // FIX #1270: Keyboard dismissal for iOS (decimalPad has no Done button)
    enum SendField: Hashable {
        case address, amount, memo
    }
    @FocusState private var focusedField: SendField?

    // FIX #565: Mempool verification pending warning (high peer acceptance but timeout)
    @State private var showMempoolVerificationPendingWarning = false
    @State private var mempoolVerificationPendingMessage = ""

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
                    } else if let error = preparationError, isValidInput {
                        // FIX #1314: Show error when pre-verification fails
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(theme.warningColor)
                            Text(error)
                                .font(theme.captionFont)
                                .foregroundColor(theme.warningColor)
                                .lineLimit(2)
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

                    // FIX #1141: Show corrupted witness warning
                    if walletManager.hasCorruptedWitnesses {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.shield.fill")
                                .foregroundColor(.red)
                            Text("\(walletManager.corruptedWitnessCount) corrupted witness\(walletManager.corruptedWitnessCount == 1 ? "" : "es") - Run Full Resync in Settings")
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
                    // FIX #1098: Also disable when balance integrity issue detected
                    // FIX #1139: Disable during pre-build phase - only enable when TX is ready
                    // FIX #1141: Also disable when witnesses are corrupted
                    // FIX #1314: Send enabled ONLY when transaction preparation succeeds
                    // Button stays disabled until pre-verification builds the zk-SNARK proof
                    .disabled(isSending || !isValidInput || preparedTransaction == nil || hasPendingTransaction || walletManager.isCatchingUp || walletManager.isRepairingHistory || networkManager.isFeatureBlocked(.send) || walletManager.balanceIntegrityIssue || walletManager.hasCorruptedWitnesses || walletManager.isGapFillingDelta)
                }
                .padding()
            }
            #if os(iOS)
            // FIX #1270: Tap outside text fields to dismiss keyboard
            .onTapGesture {
                focusedField = nil
            }
            #endif

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
                                // FIX #1360: TASK 12 — Use ClipboardManager with 60s expiry for txids
                                ClipboardManager.copyWithAutoExpiry(txId, seconds: 60)
                                #if os(iOS)
                                // Haptic feedback
                                let generator = UIImpactFeedbackGenerator(style: .medium)
                                generator.impactOccurred()
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
                    // FIX #1360: TASK 12 — Use ClipboardManager with 60s expiry for txids
                    ClipboardManager.copyWithAutoExpiry(failedTxId, seconds: 60)
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
        // FIX #565: Mempool verification pending alert (high peer acceptance but timeout)
        .alert(isPresented: $showMempoolVerificationPendingWarning) {
            Alert(
                title: Text("✅ Transaction Broadcast"),
                message: Text(mempoolVerificationPendingMessage),
                dismissButton: .default(Text("OK"))
            )
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
            // FIX #1258: Do NOT invalidate or re-prepare on memo change.
            // Pre-build happens once when amount is entered. Memo is included
            // at actual send time — if memo differs from prepared TX, the send
            // path falls through to performSendTransaction() which builds with
            // the final memo. This prevents a wasteful 2-4s Groth16 rebuild
            // every time the user types in the memo field.
        }
        .onAppear {
            // FIX #1327: Restore from static cache immediately when Send window opens.
            // Prevents re-triggering the full pre-build when the view is recreated.
            if preparedTransaction == nil,
               let cached = PreparedTransaction.cached,
               cached.isValid {
                preparedTransaction = cached
                print("⚡ FIX #1327: Restored cached TX on appear — no rebuild needed")
            }
        }
        .onDisappear {
            // FIX #1328: Cancel Rust-side proofs FIRST — Swift cancel doesn't stop OS threads
            ZipherXFFI.cancelProofGeneration()
            preparationTask?.cancel()
            preparationTask = nil
            proofCountdownTimer?.invalidate()  // FIX #1327: Clean up timer
            proofCountdownTimer = nil
            // VUL-U-002: Clear sensitive form data from memory on dismiss
            clearForm()
        }
        #if os(iOS)
        // FIX #1270: "Done" toolbar button for keyboards without a return key (decimalPad)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    focusedField = nil
                }
            }
        }
        #endif
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
                .focused($focusedField, equals: .address)
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
                        isAddressSprout = false
                    } else if newValue.hasPrefix("t1") || newValue.hasPrefix("t3") {
                        isAddressValid = false
                        isAddressTransparent = true
                        isAddressSprout = false
                    } else if newValue.hasPrefix("zc") {
                        // FIX #1455: Detect Sprout z-addresses (Base58Check, not Bech32)
                        isAddressValid = false
                        isAddressTransparent = false
                        isAddressSprout = true
                    } else if newValue.hasPrefix("zs1") && newValue.count >= 70 {
                        // Only call FFI for complete-looking addresses
                        isAddressTransparent = false
                        isAddressSprout = false
                        isAddressValid = walletManager.isValidZAddress(newValue)
                    } else {
                        isAddressValid = false
                        isAddressTransparent = false
                        isAddressSprout = false
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
    /// VUL-UI-004: Sanitize QR input — reject oversized/undersized, strip non-alphanumeric
    private func extractAddressFromQR(_ qrString: String) -> String {
        // VUL-UI-004: Reject obviously malformed QR codes
        let trimmed = qrString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 10, trimmed.count <= 500 else {
            return ""
        }

        var address: String
        // Handle zcash: URI format
        if trimmed.lowercased().hasPrefix("zcash:") {
            let withoutPrefix = String(trimmed.dropFirst(6))
            // Remove any query parameters
            if let questionMark = withoutPrefix.firstIndex(of: "?") {
                address = String(withoutPrefix[..<questionMark])
            } else {
                address = withoutPrefix
            }
        }
        // Handle zclassic: URI format
        else if trimmed.lowercased().hasPrefix("zclassic:") {
            let withoutPrefix = String(trimmed.dropFirst(9))
            if let questionMark = withoutPrefix.firstIndex(of: "?") {
                address = String(withoutPrefix[..<questionMark])
            } else {
                address = withoutPrefix
            }
        } else {
            // Plain address
            address = trimmed
        }

        // VUL-UI-004: Strip non-alphanumeric characters (Zclassic addresses are base58/bech32)
        address = String(address.filter { $0.isLetter || $0.isNumber })
        return address
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
        } else if isAddressSprout {
            // FIX #1455: Specific feedback for Sprout z-addresses
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(theme.warningColor)
                    Text("Sprout z-address (pre-Sapling) — not supported")
                        .foregroundColor(theme.warningColor)
                }
                .font(theme.captionFont)
                Text("ZipherX only supports Sapling shielded addresses (zs1...).")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(theme.textSecondary)
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
                    .focused($focusedField, equals: .amount)
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
                .focused($focusedField, equals: .memo)
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
        // VUL-UI-002: Reject negative amounts before Double conversion
        guard !normalizedAmount.contains("-"),
              let amountValue = Double(normalizedAmount),
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
        } else if walletManager.hasCorruptedWitnesses {
            // FIX #1141: Show witness corruption state
            return "Witness Error"
        } else if walletManager.balanceIntegrityIssue {
            // FIX #1098: Show balance issue state
            return "Balance Issue"
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
        } else if isPreparingTransaction {
            // FIX #1139: Show preparing state
            return "Preparing..."
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
            let torMode = TorManager.shared.mode
            let torConnected = TorManager.shared.connectionState.isConnected
            let socksPort = TorManager.shared.socksPort

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
        // VUL-UI-001: Re-validate address immediately before broadcast
        // Prevents sending to an address modified after initial validation (e.g., clipboard replace attack)
        guard walletManager.isValidZAddress(recipientAddress) else {
            errorMessage = "Invalid recipient address. Please verify and try again."
            showError = true
            return
        }

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
                    } else if broadcastResult.peerCount >= 5 {
                        // FIX #565: High peer acceptance (5+) but mempool verification timed out
                        // With 5+ peers accepting, broadcast LIKELY succeeded - this is a verification timeout, not a broadcast failure
                        // The transaction is being tracked as pending and will be confirmed when mined
                        print("✅ FIX #565: \(broadcastResult.peerCount) peers accepted - mempool verification timed out but broadcast likely succeeded")
                        print("✅ FIX #565: txId=\(broadcastedTxId) - tracking as pending, will confirm when mined")
                        // Set the warning alert flag - the success flow will continue below and show success screen
                        mempoolVerificationPendingMessage = """
                            ✅ Transaction Broadcast Successfully

                            Your transaction was accepted by \(broadcastResult.peerCount) peers and is being tracked as pending.

                            Note: Mempool verification timed out due to network conditions, but with \(broadcastResult.peerCount) peer acceptances, the transaction is likely propagating through the network.

                            🔒 YOUR FUNDS ARE SAFE
                            The transaction is being tracked and will confirm when mined.

                            💡 WHAT TO EXPECT:
                            • Check your balance in 2-3 minutes
                            • Transaction will appear in history once confirmed
                            • If not confirmed after 10 minutes, try sending again

                            📋 TXID:
                            \(broadcastedTxId)
                            """
                        // Alert will be shown after success screen
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            showMempoolVerificationPendingWarning = true
                        }
                    } else if broadcastResult.peerCount >= 2 {
                        // FIX #389 v2: Multiple peers accepted (2-4) but P2P mempool verification FAILED
                        // Lower peer acceptance counts are less reliable - verification timeout is more concerning
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

                // FIX #957: Start faster confirmation checking
                // Don't wait for the 30-second fetchNetworkStats interval
                // Check at 10s, 30s, and 60s for quicker Settlement feedback
                Task {
                    print("⏱️ FIX #957: Starting faster confirmation checks...")
                    for delay in [10, 30, 60] {
                        try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
                        print("⏱️ FIX #957: Confirmation check at \(delay)s...")
                        await networkManager.checkPendingOutgoingConfirmations()
                        // Stop if no more pending transactions
                        if networkManager.mempoolOutgoing == 0 {
                            print("⏱️ FIX #957: TX confirmed - stopping early checks")
                            break
                        }
                    }
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
            SendProgressStep(id: "prover", title: "Preparing secure transaction", status: .pending),
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
                let errorStr = error.localizedDescription.lowercased()

                // FIX #1137: CMU mismatch requires Full Resync (witness repair won't help)
                // This is a data integrity issue - stored CMU doesn't match computed CMU
                let isCMUMismatch = errorStr.contains("cmu") || errorStr.contains("note data integrity")

                if isCMUMismatch {
                    print("🚨 FIX #1137: CMU mismatch detected - triggering Full Resync...")
                    await MainActor.run {
                        if let currentIdx = sendProgress.firstIndex(where: { $0.status == .inProgress }) {
                            sendProgress[currentIdx].status = .inProgress
                            sendProgress[currentIdx].detail = "Auto-repairing note data..."
                        }
                    }

                    // Trigger Full Resync - this rebuilds all note data from scratch
                    do {
                        print("🔧 FIX #1137: Starting automatic Full Resync...")
                        try await walletManager.repairNotesAfterDownloadedTree(onProgress: { progress, height, total in
                            // Just log progress
                            print("🔧 FIX #1137: Full Resync progress: \(Int(progress * 100))%")
                        }, forceFullRescan: true)
                        print("✅ FIX #1137: Full Resync complete - note data rebuilt!")

                        // Retry the transaction after Full Resync
                        await MainActor.run {
                            isSending = false
                            sendProgress = []
                            hasAttemptedWitnessRepair = false
                        }

                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        await MainActor.run {
                            performSendTransaction()
                        }
                        return
                    } catch {
                        print("❌ FIX #1137: Full Resync failed: \(error)")
                        // Fall through to show error
                    }
                }

                // FIX #750: Auto-repair anchor mismatch and retry
                // If proof generation failed, it's likely corrupted witnesses
                let isProofError = errorStr.contains("proof") || errorStr.contains("anchor") ||
                                   errorStr.contains("witness") || errorStr.contains("merkle")

                if isProofError && !hasAttemptedWitnessRepair {
                    print("🔧 FIX #750: Proof generation failed - auto-repairing witnesses...")
                    await MainActor.run {
                        // Update UI to show repair in progress
                        if let currentIdx = sendProgress.firstIndex(where: { $0.status == .inProgress }) {
                            sendProgress[currentIdx].status = .inProgress
                            sendProgress[currentIdx].detail = "Auto-repairing witnesses..."
                        }
                    }

                    // Rebuild witnesses automatically
                    let fixed = await walletManager.fixAnchorMismatches()
                    print("🔧 FIX #750: Rebuilt \(fixed) witnesses - retrying transaction...")

                    await MainActor.run {
                        hasAttemptedWitnessRepair = true
                    }

                    // Retry the transaction
                    await MainActor.run {
                        isSending = false
                        sendProgress = []
                    }

                    // Small delay then retry
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    await MainActor.run {
                        performSendTransaction()
                    }
                    return
                }

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
                    // Reset repair flag for next send attempt
                    hasAttemptedWitnessRepair = false
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
            // FIX #1052: Handle BOTH pre-prover verification AND mempool verification
            // Pre-prover: WalletManager sends "verify" during witness update, tree validation
            // Mempool: NetworkManager sends "verify" during mempool checking
            if progress == 1.0 || detail?.contains("mempool") == true {
                // Mempool verified - show success!
                updateStepSync("broadcast", status: .completed, detail: detail ?? "In mempool - awaiting miners")
                // Show success screen now that mempool is verified
                if !txId.isEmpty {
                    showSuccess = true
                    isSending = false
                }
            } else if detail?.contains("witness") == true || detail?.contains("Witness") == true {
                // FIX #1052: Pre-prover witness verification - show on "prover" step
                updateStepSync("prover", status: .inProgress, detail: detail)
            } else if detail?.contains("notes") == true || detail?.contains("Notes") == true {
                // FIX #1052: Pre-prover notes verification - show on "prover" step
                updateStepSync("prover", status: .inProgress, detail: detail)
            } else if detail?.contains("tree") == true || detail?.contains("Tree") == true || detail?.contains("commitment") == true {
                // FIX #1052: Pre-prover tree validation - show on "prover" step
                updateStepSync("prover", status: .inProgress, detail: detail)
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
        // FIX #1328: Cancel Rust-side proofs BEFORE cancelling Swift task.
        // Swift Task.cancel() does NOT stop Rust's std::thread::scope() threads.
        // Without this, each close/reopen spawns new proof threads while old ones still run → 900% CPU.
        ZipherXFFI.cancelProofGeneration()
        preparationTask?.cancel()
        preparationTask = nil
        preparedTransaction = nil
        PreparedTransaction.cached = nil  // FIX #1325: Also clear persistent cache
        proofCountdownTimer?.invalidate()  // FIX #1327
        proofCountdownTimer = nil
        preBuildStartTime = nil  // FIX #1327
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

        // FIX #1325: Restore from persistent cache if view was recreated (closed + reopened).
        // The prepared TX (Groth16 proofs) is still valid if wallet state hasn't changed.
        // Saves ~25 seconds of proof generation for 27-spend "max" transactions.
        if preparedTransaction == nil,
           let cached = PreparedTransaction.cached,
           cached.isValid,
           cached.toAddress == recipientAddress,
           cached.amount == currentZatoshis,
           cached.memo == (memo.isEmpty ? nil : memo) {
            preparedTransaction = cached
            print("⚡ FIX #1325: Restored cached transaction — skipping proof generation!")
            return
        }

        // FIX #109: Cancel any existing debounce task (user is still typing)
        preparationDebounceTask?.cancel()

        // FIX #600: Reduced debounce from 1.5s to 0.3s for instant pre-build
        // Still prevents concurrent rebuilds but feels much faster
        preparationDebounceTask = Task {
            do {
                // Wait 0.3 seconds for user to finish typing
                try await Task.sleep(nanoseconds: 300_000_000)

                // After debounce, check if task was cancelled (user typed again)
                try Task.checkCancellation()

                // Now actually start preparation
                await MainActor.run {
                    // FIX #1328: Cancel Rust proofs BEFORE Swift task — OS threads ignore Task.cancel()
                    ZipherXFFI.cancelProofGeneration()
                    preparationTask?.cancel()

                    // Start new preparation
                    isPreparingTransaction = true
                    preparationProgress = "Initializing..."
                    preparationError = nil  // FIX #1314: Clear previous error
                    preBuildStartTime = Date()  // FIX #1327: Track start time
                    startPreBuildElapsedTimer()  // FIX #1327: Show elapsed time

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

            // FIX #600: Skip network check if already connected (99% of cases)
            // Only connect if explicitly disconnected
            if !networkManager.isConnected {
                await MainActor.run {
                    preparationProgress = "Connecting to network..."
                }
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
                cachedChainHeight: heightBeforePrep,  // FIX #600: Pass cached chain height to avoid multiple network calls
                onProgress: { step, detail, _ in
                    Task { @MainActor in
                        // FIX #1327: Show elapsed time with each step
                        let elapsed = self.preBuildStartTime.map { Int(Date().timeIntervalSince($0)) } ?? 0
                        let elapsedStr = elapsed > 0 ? " (\(elapsed)s)" : ""
                        switch step {
                        case "prover": self.preparationProgress = "Loading prover...\(elapsedStr)"
                        case "notes": self.preparationProgress = "Selecting notes...\(elapsedStr)"
                        case "tree": self.preparationProgress = (detail ?? "Loading tree...") + elapsedStr
                        case "witness": self.preparationProgress = "Validating witnesses...\(elapsedStr)"
                        case "proof":
                            self.preparationProgress = "Generating zk-SNARK...\(elapsedStr)"
                            // FIX #1326: Start live countdown timer for parallel proof generation
                            self.startProofCountdown()
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
                let prepared = PreparedTransaction(
                    rawTx: rawTx,
                    spentNullifier: spentNullifier,
                    toAddress: toAddress,
                    amount: zatoshis,
                    memo: memoText,
                    preparedAtHeight: heightBeforePrep,
                    preparedAt: Date()
                )
                self.preparedTransaction = prepared
                PreparedTransaction.cached = prepared  // FIX #1325: Persist across view lifecycle
                self.proofCountdownTimer?.invalidate()  // FIX #1326: Stop countdown
                self.proofCountdownTimer = nil
                let buildTime = self.preBuildStartTime.map { String(format: "%.1f", Date().timeIntervalSince($0)) } ?? "?"
                self.preBuildStartTime = nil  // FIX #1327
                self.isPreparingTransaction = false
                self.preparationProgress = ""
                print("⚡ Transaction prepared at height \(heightBeforePrep) in \(buildTime)s - ready for instant send!")
            }
        } catch is CancellationError {
            await MainActor.run {
                proofCountdownTimer?.invalidate()
                proofCountdownTimer = nil
                preBuildStartTime = nil  // FIX #1327
                isPreparingTransaction = false
                preparationProgress = ""
            }
        } catch {
            await MainActor.run {
                proofCountdownTimer?.invalidate()
                proofCountdownTimer = nil
                preBuildStartTime = nil  // FIX #1327
                isPreparingTransaction = false
                preparationProgress = ""
                // FIX #1314: Show error to user instead of silently failing
                let errorMsg = error.localizedDescription
                if errorMsg.contains("cancelled") || errorMsg.contains("Cancelled") || errorMsg.contains("Proof generation cancelled") {
                    // FIX #1328: Proof was cancelled by user action — not a real error
                    print("ℹ️ FIX #1328: Proof generation cancelled — cleaning up")
                } else if errorMsg.contains("Insufficient") {
                    preparationError = "Insufficient spendable balance — witnesses may need repair"
                } else if errorMsg.contains("Anchor not found") || errorMsg.contains("anchorNotOnChain") {
                    preparationError = "Witness anchors invalid — go to Settings → Repair Database"
                } else {
                    preparationError = "Transaction preparation failed: \(errorMsg)"
                }
                print("⚠️ Transaction preparation failed: \(errorMsg)")
            }
        }
    }

    // MARK: - FIX #1326: Groth16 Proof Countdown Timer

    /// Starts a live countdown timer that polls Rust's atomic progress counters.
    /// The timer fires every 300ms and displays: "Generating zk-SNARK... X/Y (≈Zs remaining)"
    /// Time estimate is based on ACTUAL observed proof rate, not hardcoded constants.
    private func startProofCountdown() {
        // Invalidate any existing timer
        proofCountdownTimer?.invalidate()

        let startTime = Date()
        var firstProofTime: Date? = nil  // When the first proof completes (for rate calculation)

        proofCountdownTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [self] timer in
            let total = ZipherXFFI.getProofTotal()
            let completed = ZipherXFFI.getProofCompleted()

            // Not started yet or already done
            guard total > 0 && completed < total else {
                if total > 0 && completed >= total {
                    self.preparationProgress = "Finalizing transaction..."
                    timer.invalidate()
                    self.proofCountdownTimer = nil
                }
                return
            }

            // Track when first proof completes (for measured rate)
            if completed > 0 && firstProofTime == nil {
                firstProofTime = Date()
            }

            // FIX #1364: Show percentage + estimated time remaining instead of note counts.
            // Displaying "3/5" reveals the number of notes being spent (privacy leak).
            let percent = Int(Double(completed) / Double(total) * 100)
            let remaining = total - completed
            var timeEstimate = ""

            if completed > 0, let firstTime = firstProofTime {
                // MEASURED rate: use actual time since first proof completed
                let elapsed = Date().timeIntervalSince(firstTime)
                if completed > 1 {
                    let secondsPerProof = elapsed / Double(completed - 1)
                    let remainingSeconds = Int(ceil(Double(remaining) * secondsPerProof))
                    timeEstimate = " — \(remainingSeconds)s remaining"
                } else {
                    // Only 1 proof done, use thread-based estimate for remaining
                    let threads = max(1, ZipherXFFI.getProofThreads())
                    let batchesRemaining = Int(ceil(Double(remaining) / Double(threads)))
                    let firstBatchTime = Date().timeIntervalSince(startTime)
                    let remainingSeconds = Int(ceil(Double(batchesRemaining) * firstBatchTime))
                    timeEstimate = " — \(remainingSeconds)s remaining"
                }
            } else {
                // No proofs done yet — estimate ~1s per proof, divided by thread count
                let threads = max(1, ZipherXFFI.getProofThreads())
                let batches = Int(ceil(Double(total) / Double(threads)))
                let estimatedTotal = batches  // ~1s per batch
                timeEstimate = " — \(estimatedTotal)s remaining"
            }

            self.preparationProgress = "Generating zk-SNARK \(percent)%\(timeEstimate)"
        }
    }

    // MARK: - FIX #1327: Pre-build elapsed timer

    /// Shows elapsed time during the pre-build steps (prover, tree, witnesses)
    /// before the Groth16 countdown takes over. Updates every 1s with "Step... (Xs)"
    private func startPreBuildElapsedTimer() {
        // Reuse the same proofCountdownTimer slot — proof countdown will replace it when proofs start
        proofCountdownTimer?.invalidate()

        proofCountdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [self] timer in
            // If proofs have started (total > 0), this timer is replaced by startProofCountdown
            let total = ZipherXFFI.getProofTotal()
            if total > 0 {
                timer.invalidate()
                return
            }

            guard let start = self.preBuildStartTime, self.isPreparingTransaction else {
                timer.invalidate()
                return
            }

            let elapsed = Int(Date().timeIntervalSince(start))
            if elapsed > 0 {
                // Append elapsed time to current step (don't overwrite the step name)
                let currentStep = self.preparationProgress.components(separatedBy: " (").first ?? self.preparationProgress
                if !currentStep.isEmpty {
                    self.preparationProgress = "\(currentStep) (\(elapsed)s)"
                }
            }
        }
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
