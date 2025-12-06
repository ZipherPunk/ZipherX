import SwiftUI
import LocalAuthentication
import CryptoKit
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

// MARK: - PIN Security Helper
/// Secure PIN hashing using PBKDF2-like key derivation with rate limiting
enum PINSecurity {
    /// Fixed salt for PIN hashing (in production, use per-user random salt stored in Keychain)
    private static let pinSalt = "ZipherX_PIN_Salt_v1".data(using: .utf8)!

    /// Rate limiting constants
    private static let maxAttempts = 5
    private static let lockoutDuration: TimeInterval = 300 // 5 minutes

    /// UserDefaults keys for rate limiting
    private static let failedAttemptsKey = "pinFailedAttempts"
    private static let lockoutEndKey = "pinLockoutEnd"

    /// Hash PIN using SHA256 with salt (100,000 iterations simulated via multiple rounds)
    static func hashPIN(_ pin: String) -> String {
        guard let pinData = pin.data(using: .utf8) else { return "" }

        // Combine salt + PIN
        var combined = pinSalt
        combined.append(pinData)

        // Multiple rounds of hashing to slow down brute force
        var hash = SHA256.hash(data: combined)
        for _ in 0..<10000 {
            hash = SHA256.hash(data: Data(hash))
        }

        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    /// Check if PIN verification is currently locked out
    static func isLockedOut() -> Bool {
        let lockoutEnd = UserDefaults.standard.double(forKey: lockoutEndKey)
        if lockoutEnd > 0 && Date().timeIntervalSince1970 < lockoutEnd {
            return true
        }
        return false
    }

    /// Get remaining lockout time in seconds
    static func remainingLockoutTime() -> TimeInterval {
        let lockoutEnd = UserDefaults.standard.double(forKey: lockoutEndKey)
        let remaining = lockoutEnd - Date().timeIntervalSince1970
        return max(0, remaining)
    }

    /// Get number of failed attempts
    static func failedAttempts() -> Int {
        return UserDefaults.standard.integer(forKey: failedAttemptsKey)
    }

    /// Verify PIN against stored hash with rate limiting
    /// Returns: (success, isLocked, remainingAttempts)
    static func verifyPINWithRateLimit(_ pin: String, storedHash: String) -> (success: Bool, isLocked: Bool, remainingAttempts: Int) {
        // Check if locked out
        if isLockedOut() {
            return (false, true, 0)
        }

        // Verify PIN
        let success = hashPIN(pin) == storedHash

        if success {
            // Reset failed attempts on success
            UserDefaults.standard.set(0, forKey: failedAttemptsKey)
            UserDefaults.standard.removeObject(forKey: lockoutEndKey)
            return (true, false, maxAttempts)
        } else {
            // Increment failed attempts
            var attempts = UserDefaults.standard.integer(forKey: failedAttemptsKey)
            attempts += 1
            UserDefaults.standard.set(attempts, forKey: failedAttemptsKey)

            // Check if lockout should be triggered
            if attempts >= maxAttempts {
                let lockoutEnd = Date().timeIntervalSince1970 + lockoutDuration
                UserDefaults.standard.set(lockoutEnd, forKey: lockoutEndKey)
                print("⚠️ SECURITY: PIN lockout triggered after \(attempts) failed attempts")
                return (false, true, 0)
            }

            return (false, false, maxAttempts - attempts)
        }
    }

    /// Simple verify PIN (for backwards compatibility)
    static func verifyPIN(_ pin: String, storedHash: String) -> Bool {
        return hashPIN(pin) == storedHash
    }

    /// Reset lockout (for testing or admin purposes)
    static func resetLockout() {
        UserDefaults.standard.set(0, forKey: failedAttemptsKey)
        UserDefaults.standard.removeObject(forKey: lockoutEndKey)
    }
}

/// Settings View - Export keys, PIN code, Face ID setup
/// Themed design
struct SettingsView: View {
    @EnvironmentObject var walletManager: WalletManager
    @EnvironmentObject var networkManager: NetworkManager
    @State private var showExportAlert = false
    @State private var exportedKey = ""
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var useFaceID = false
    @State private var selectedTimeout: TimeInterval = BiometricAuthManager.shared.authTimeout
    @State private var usePINCode = false
    @State private var showPINSetup = false
    @State private var pinCode = ""
    @State private var confirmPIN = ""
    @State private var showPINText = false  // Toggle to show/hide PIN text
    @State private var biometricAvailable = false
    @State private var showRescanWarning = false
    @State private var showRescanProgress = false
    @State private var rescanProgress: Double = 0
    @State private var rescanCurrentHeight: UInt64 = 0
    @State private var rescanMaxHeight: UInt64 = 0
    @State private var rescanStartTime: Date?
    @State private var rescanElapsedTime: TimeInterval = 0
    @State private var rescanTimer: Timer?
    @State private var showQuickScan = false
    @State private var quickScanHeight = ""
    @State private var showFullRescanFromHeight = false
    @State private var fullRescanHeight = ""
    @State private var showRebuildWitnessesWarning = false
    @State private var showRepairNotesWarning = false
    @State private var showRecoverySuccess = false
    @State private var recoveryMessage = ""
    @State private var useP2POnly = UserDefaults.standard.bool(forKey: "useP2POnly")
    @State private var debugLoggingEnabled = DebugLogger.shared.isEnabled
    @State private var showDebugLogShare = false
    @State private var showLogExportWarning = false  // Privacy warning before export
    @State private var debugLogSize: String = "0 KB"

    // Banned peers management
    @State private var showBannedPeers = false
    @State private var bannedPeersList: [BannedPeer] = []
    @State private var selectedBannedPeers: Set<String> = []

    // Delete wallet
    @State private var showDeleteWalletWarning = false
    @State private var showDeleteWalletConfirm = false
    @State private var deleteConfirmText = ""

    // Peer export management
    @State private var showPeerExportSuccess = false
    @State private var peerExportCount = 0

    // Seed phrase info
    @State private var showSeedPhraseInfo = false

    @EnvironmentObject var themeManager: ThemeManager

    // Theme shortcut
    private var theme: AppTheme { themeManager.currentTheme }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                /* DISABLED: Appearance section - hide themes for now
                // Appearance section (themes)
                appearanceSection
                */

                #if os(macOS)
                // Wallet mode section (macOS only)
                walletModeSection
                #endif

                // Security section
                securitySection

                // Network section
                networkSection

                // Export section
                exportSection

                /* DISABLED: Debug logging section - hide for now
                // Debug section
                debugLoggingSection
                */

                /* DISABLED: Blockchain data section - hide for now
                // Rescan section
                rescanSection
                */

                // Note: Delete wallet is now in exportSection (Danger Zone)

                /* DISABLED: Debug tools section
                // Debug section (for testing header sync)
                debugSection
                */

                Spacer()
            }
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(themeManager.currentTheme.backgroundColor)
        .onAppear {
            checkBiometricAvailability()
        }
        .alert("Export Private Key", isPresented: $showExportAlert) {
            Button("Copy to Clipboard") {
                copyToClipboard(exportedKey)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your private key:\n\n\(exportedKey)\n\nKeep this safe! Anyone with this key can spend your funds.")
        }
        .alert("Error", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
        .alert("Funds Recovered!", isPresented: $showRecoverySuccess) {
            Button("Nice!", role: .cancel) {}
        } message: {
            Text(recoveryMessage)
        }
        .sheet(isPresented: $showPINSetup) {
            pinSetupSheet
                #if os(macOS)
                .frame(minWidth: 400, idealWidth: 450, minHeight: 350, idealHeight: 400)
                #endif
        }
        .alert("Full Blockchain Rescan", isPresented: $showRescanWarning) {
            Button("Cancel", role: .cancel) {}
            Button("Rescan", role: .destructive) {
                startFullRescan()
            }
        } message: {
            Text("WARNING: This will delete all cached data and rescan the entire blockchain from scratch.\n\nThis process can take 30-60 minutes and uses significant data.\n\nYour funds are safe - only cached data is deleted.\n\nDo you want to continue?")
        }
        .sheet(isPresented: $showRescanProgress) {
            rescanProgressView
                #if os(macOS)
                .frame(minWidth: 450, idealWidth: 500, minHeight: 300, idealHeight: 350)
                #endif
        }
        .alert("Quick Scan for Notes", isPresented: $showQuickScan) {
            TextField("Start Height", text: $quickScanHeight)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
            Button("Cancel", role: .cancel) {
                quickScanHeight = ""
            }
            Button("Scan") {
                if let height = UInt64(quickScanHeight) {
                    startQuickScan(from: height)
                }
                quickScanHeight = ""
            }
        } message: {
            Text("Enter block height to start scanning for notes.\n\nThis uses the bundled tree and only scans for YOUR notes.\n\nExample: 2918000")
        }
        .alert("Full Rescan from Height", isPresented: $showFullRescanFromHeight) {
            TextField("Start Height", text: $fullRescanHeight)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
            Button("Cancel", role: .cancel) {
                fullRescanHeight = ""
            }
            Button("Rescan") {
                if let height = UInt64(fullRescanHeight) {
                    startFullRescanFromHeight(height)
                }
                fullRescanHeight = ""
            }
        } message: {
            Text("Enter block height to start full rescan.\n\nThis rebuilds the commitment tree and creates proper witnesses so notes can be SPENT.\n\nExample: 2918000")
        }
        .alert("Rebuild Witnesses", isPresented: $showRebuildWitnessesWarning) {
            Button("Cancel", role: .cancel) {}
            Button("Rebuild", role: .destructive) {
                startRebuildWitnesses()
            }
        } message: {
            Text("This will rebuild witnesses from the bundled tree height.\n\nThis is needed after Quick Scan to make notes spendable.\n\nIt will take 5-15 minutes depending on blocks since bundled tree.\n\nDo you want to continue?")
        }
        .alert("Repair Notes (Fix Nullifiers)", isPresented: $showRepairNotesWarning) {
            Button("Cancel", role: .cancel) {}
            Button("Repair", role: .destructive) {
                startRepairNotes()
            }
        } message: {
            Text("This fixes incorrect balance by recalculating nullifiers for notes received after the bundled tree.\n\nUse this if:\n• Balance shows wrong amount\n• Spent notes still show as unspent\n• Notes discovered during quick scan have wrong nullifiers\n\nThis deletes and re-scans notes after height 2926122.\n\nDo you want to continue?")
        }
        .alert("DANGER - DELETE WALLET", isPresented: $showDeleteWalletWarning) {
            Button("Cancel - Keep Wallet", role: .cancel) {}
            Button("I Understand, Delete", role: .destructive) {
                showDeleteWalletConfirm = true
            }
        } message: {
            Text("!!! CRITICAL WARNING !!!\n\nThis will PERMANENTLY DELETE your wallet!\n\nYour PRIVATE KEY will be ERASED FOREVER.\nAll transaction history will be LOST.\nYour funds will be UNRECOVERABLE.\n\nHave you EXPORTED your private key?\nIf not, press Cancel NOW!\n\nTHIS CANNOT BE UNDONE!")
        }
        .alert("FINAL CONFIRMATION", isPresented: $showDeleteWalletConfirm) {
            TextField("Type DELETE to confirm", text: $deleteConfirmText)
            Button("CANCEL - KEEP MY WALLET", role: .cancel) {
                deleteConfirmText = ""
            }
            Button("DELETE FOREVER", role: .destructive) {
                if deleteConfirmText.uppercased() == "DELETE" {
                    performDeleteWallet()
                }
                deleteConfirmText = ""
            }
        } message: {
            Text("Type DELETE (in capital letters) to confirm.\n\nAfter this, your wallet is GONE FOREVER.\n\nNo recovery is possible without your private key backup!")
        }
        .alert("Seed Phrase Not Stored", isPresented: $showSeedPhraseInfo) {
            Button("I Understand", role: .cancel) {}
        } message: {
            Text("\"Privacy is necessary for an open society.\"\n\nFor maximum security, your 24-word seed phrase was shown ONLY during wallet creation and is NOT stored on this device.\n\nIf you didn't write it down, use \"Export Private Key\" above as your backup.\n\nYour private key can fully restore your wallet.")
        }
    }

    // MARK: - Wallet Mode Section (macOS only)

    #if os(macOS)
    @State private var showBootstrapSheet = false
    @State private var showModeChangeAlert = false

    private var walletModeSection: some View {
        let modeManager = WalletModeManager.shared
        let bootstrapManager = BootstrapManager.shared

        return VStack(spacing: 12) {
            // Section header
            HStack {
                Image(systemName: "server.rack")
                    .font(.system(size: 12))
                Text("Wallet Mode")
                    .font(theme.titleFont)
                Spacer()
            }
            .foregroundColor(theme.textPrimary)

            // Current mode display
            HStack {
                Image(systemName: modeManager.currentMode.icon)
                    .font(.system(size: 20))
                    .foregroundColor(theme.primaryColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(modeManager.currentMode.displayName)
                        .font(theme.bodyFont)
                        .foregroundColor(theme.textPrimary)
                    Text(modeManager.currentMode.description)
                        .font(theme.captionFont)
                        .foregroundColor(theme.textSecondary)
                }

                Spacer()

                // Mode indicator
                Text(modeManager.currentMode == .light ? "Active" : "Active")
                    .font(theme.captionFont)
                    .foregroundColor(theme.successColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(theme.successColor.opacity(0.2))
                    .cornerRadius(theme.cornerRadius)
            }
            .padding(12)
            .background(theme.surfaceColor)
            .overlay(
                Rectangle()
                    .stroke(theme.primaryColor.opacity(0.5), lineWidth: 1)
            )

            // Full Node specific options
            if modeManager.currentMode == .fullNode {
                // Full node status
                fullNodeStatusView(modeManager: modeManager)
            } else {
                // Switch to Full Node button
                Button(action: {
                    showModeChangeAlert = true
                }) {
                    HStack {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text("Switch to Full Node Mode")
                        Spacer()
                        Image(systemName: "chevron.right")
                    }
                    .font(theme.bodyFont)
                    .foregroundColor(theme.textPrimary)
                    .padding(12)
                    .background(theme.surfaceColor)
                    .overlay(
                        Rectangle()
                            .stroke(theme.textPrimary, lineWidth: 1)
                    )
                }
                .buttonStyle(PlainButtonStyle())
            }

            // Info text
            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                    .foregroundColor(.blue)
                    .font(.system(size: 12))

                Text(modeManager.currentMode == .light ?
                    "Light mode uses P2P network with bundled commitment tree for fast, mobile-friendly operation." :
                    "Full Node mode runs a local zclassicd daemon for complete blockchain verification.")
                    .font(theme.captionFont)
                    .foregroundColor(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
            .background(theme.surfaceColor)
            .overlay(
                Rectangle()
                    .stroke(theme.textPrimary.opacity(0.3), lineWidth: 1)
            )
        }
        .padding(12)
        .background(theme.backgroundColor)
        .overlay(
            Rectangle()
                .stroke(theme.textPrimary, lineWidth: 1)
        )
        .alert("Switch to Full Node Mode?", isPresented: $showModeChangeAlert) {
            Button("Cancel", role: .cancel) {}
            Button("I Understand, Switch") {
                modeManager.setMode(.fullNode)
                if bootstrapManager.needsBootstrap {
                    showBootstrapSheet = true
                }
            }
        } message: {
            Text("""
🔐 SECURITY NOTICE

Your private keys remain SECURE in ZipherX's encrypted storage.

• ZipherX will NOT use the daemon's wallet.dat
• Your spending key stays in Secure Enclave / encrypted keychain
• Send/receive continues through ZipherX wallet
• Full Node only provides trusted block height & verification

The daemon's wallet is NEVER accessed for signing.

⚠️ Requires ~5GB storage for blockchain data.
You can switch back to Light mode anytime.
""")
        }
        .sheet(isPresented: $showBootstrapSheet) {
            BootstrapProgressView()
                .environmentObject(themeManager)
                .frame(minWidth: 500, minHeight: 400)
        }
    }

    private func fullNodeStatusView(modeManager: WalletModeManager) -> some View {
        let rpcClient = RPCClient.shared

        return VStack(spacing: 8) {
            // Daemon connection status
            HStack {
                Circle()
                    .fill(rpcClient.isConnected ? Color.green : Color.red)
                    .frame(width: 8, height: 8)

                Text(rpcClient.isConnected ? "Daemon Connected" : "Daemon Offline")
                    .font(theme.bodyFont)
                    .foregroundColor(theme.textPrimary)

                Spacer()

                if rpcClient.isConnected {
                    Text("Block \(rpcClient.blockHeight)")
                        .font(theme.captionFont)
                        .foregroundColor(theme.textSecondary)
                }
            }
            .padding(10)
            .background(theme.surfaceColor)
            .overlay(
                Rectangle()
                    .stroke(rpcClient.isConnected ? Color.green.opacity(0.5) : Color.red.opacity(0.5), lineWidth: 1)
            )

            // Switch to Light mode button
            Button(action: {
                modeManager.setMode(.light)
            }) {
                HStack {
                    Image(systemName: "bolt.fill")
                    Text("Switch to Light Mode")
                    Spacer()
                    Image(systemName: "chevron.right")
                }
                .font(theme.bodyFont)
                .foregroundColor(theme.textPrimary)
                .padding(12)
                .background(theme.surfaceColor)
                .overlay(
                    Rectangle()
                        .stroke(theme.textPrimary, lineWidth: 1)
                )
            }
            .buttonStyle(PlainButtonStyle())
        }
    }
    #endif

    // MARK: - Appearance Section

    private var appearanceSection: some View {
        VStack(spacing: 12) {
            // Section header
            HStack {
                Image(systemName: "paintbrush")
                    .font(.system(size: 12))
                Text("Appearance")
                    .font(theme.titleFont)
                Spacer()
            }
            .foregroundColor(theme.textPrimary)

            // Theme selection grid
            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12)
            ], spacing: 12) {
                ForEach(ThemeType.allCases) { themeType in
                    ThemePreviewCard(
                        themeType: themeType,
                        isSelected: themeManager.currentThemeType == themeType,
                        action: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                themeManager.setTheme(themeType)
                            }
                        }
                    )
                    .environmentObject(themeManager)
                }
            }

            // Current theme info
            HStack(spacing: 8) {
                Image(systemName: themeIcon(for: themeManager.currentThemeType))
                    .foregroundColor(themeManager.currentTheme.primaryColor)
                    .font(.system(size: 12))

                Text("Active: \(themeManager.currentTheme.name)")
                    .font(theme.captionFont)
                    .foregroundColor(theme.textSecondary)

                Spacer()
            }
            .padding(8)
            .background(theme.surfaceColor)
            .overlay(
                Rectangle()
                    .stroke(themeManager.currentTheme.primaryColor.opacity(0.5), lineWidth: 1)
            )
        }
        .padding(12)
        .background(theme.backgroundColor)
        .overlay(
            Rectangle()
                .stroke(theme.textPrimary, lineWidth: 1)
        )
    }

    private func themeIcon(for type: ThemeType) -> String {
        switch type {
        case .mac7:
            return "desktopcomputer"
        case .cypherpunk:
            return "terminal"
        case .win95:
            return "pc"
        case .modern:
            return "iphone"
        }
    }

    // MARK: - Security Section

    private var securitySection: some View {
        VStack(spacing: 12) {
            // Section header
            HStack {
                Image(systemName: "lock.shield")
                    .font(.system(size: 12))
                Text("Security")
                    .font(theme.titleFont)
                Spacer()
            }
            .foregroundColor(theme.textPrimary)

            // Face ID / Touch ID toggle
            if biometricAvailable {
                HStack {
                    Image(systemName: getBiometricIcon())
                        .font(.system(size: 14))
                        .foregroundColor(theme.textPrimary)

                    Text(getBiometricName())
                        .font(theme.bodyFont)
                        .foregroundColor(theme.textPrimary)

                    Spacer()

                    Toggle("", isOn: $useFaceID)
                        .labelsHidden()
                        .onChange(of: useFaceID) { newValue in
                            if newValue {
                                authenticateWithBiometrics()
                            } else {
                                // Disable biometric auth
                                UserDefaults.standard.set(false, forKey: "useBiometricAuth")
                            }
                        }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(theme.surfaceColor)
                .overlay(
                    Rectangle()
                        .stroke(theme.textPrimary, lineWidth: 1)
                )

                // Inactivity timeout picker (only show if Face ID enabled)
                if useFaceID {
                    HStack {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 14))
                            .foregroundColor(theme.textPrimary)

                        Text("Lock after")
                            .font(theme.bodyFont)
                            .foregroundColor(theme.textPrimary)

                        Spacer()

                        Picker("", selection: $selectedTimeout) {
                            ForEach(BiometricAuthManager.timeoutOptions, id: \.seconds) { option in
                                Text(option.label).tag(option.seconds)
                            }
                        }
                        .pickerStyle(.menu)
                        .accentColor(theme.primaryColor)
                        .onChange(of: selectedTimeout) { newValue in
                            BiometricAuthManager.shared.setAuthTimeout(newValue)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(theme.surfaceColor)
                    .overlay(
                        Rectangle()
                            .stroke(theme.textPrimary, lineWidth: 1)
                    )

                    // Info text
                    Text("\(getBiometricName()) required: at app launch, when sending ZCL, and after \(BiometricAuthManager.shared.timeoutDisplayString) of inactivity")
                        .font(.system(size: 9))
                        .foregroundColor(theme.textSecondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                }
            }

            // PIN Code toggle
            HStack {
                Image(systemName: "number.square")
                    .font(.system(size: 14))
                    .foregroundColor(theme.textPrimary)

                Text("PIN Code")
                    .font(theme.bodyFont)
                    .foregroundColor(theme.textPrimary)

                Spacer()

                Toggle("", isOn: $usePINCode)
                    .labelsHidden()
                    .onChange(of: usePINCode) { newValue in
                        if newValue {
                            showPINSetup = true
                        } else {
                            // Clear PIN
                            UserDefaults.standard.removeObject(forKey: "walletPIN")
                        }
                    }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(theme.surfaceColor)
            .overlay(
                Rectangle()
                    .stroke(theme.textPrimary, lineWidth: 1)
            )

            // Database Encryption Status
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: "lock.doc")
                        .font(.system(size: 14))
                        .foregroundColor(theme.textPrimary)

                    Text("Database Encryption")
                        .font(theme.bodyFont)
                        .foregroundColor(theme.textPrimary)

                    Spacer()

                    HStack(spacing: 4) {
                        Image(systemName: SQLCipherManager.shared.isSQLCipherAvailable ? "checkmark.shield.fill" : "shield")
                            .font(.system(size: 12))
                            .foregroundColor(SQLCipherManager.shared.isSQLCipherAvailable ? .green : .orange)

                        Text(SQLCipherManager.shared.isSQLCipherAvailable ? "Full" : "Field-level")
                            .font(theme.captionFont)
                            .foregroundColor(SQLCipherManager.shared.isSQLCipherAvailable ? .green : .orange)
                    }
                }

                Text(SQLCipherManager.shared.isSQLCipherAvailable
                    ? "SQLCipher: AES-256 full database encryption"
                    : "iOS Data Protection + AES-GCM field encryption")
                    .font(theme.captionFont)
                    .foregroundColor(theme.textSecondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(theme.surfaceColor)
            .overlay(
                Rectangle()
                    .stroke(theme.textPrimary, lineWidth: 1)
            )

            // VUL-014: Key Rotation Policy
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: "key.horizontal.fill")
                        .font(.system(size: 14))
                        .foregroundColor(theme.textPrimary)

                    Text("Spending Key Age")
                        .font(theme.bodyFont)
                        .foregroundColor(theme.textPrimary)

                    Spacer()

                    if SecureKeyStorage.shared.shouldRecommendKeyRotation() {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 12))
                                .foregroundColor(.orange)
                            Text("Rotate Recommended")
                                .font(theme.captionFont)
                                .foregroundColor(.orange)
                        }
                    } else {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundColor(.green)
                            Text("Valid")
                                .font(theme.captionFont)
                                .foregroundColor(.green)
                        }
                    }
                }

                Text(SecureKeyStorage.shared.getKeyAgeMessage())
                    .font(theme.captionFont)
                    .foregroundColor(theme.textSecondary)

                if SecureKeyStorage.shared.shouldRecommendKeyRotation() {
                    Text("Security best practice: Create a new wallet and transfer funds annually")
                        .font(.system(size: 9))
                        .foregroundColor(.orange)
                        .padding(.top, 2)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(theme.surfaceColor)
            .overlay(
                Rectangle()
                    .stroke(SecureKeyStorage.shared.shouldRecommendKeyRotation() ? Color.orange : theme.textPrimary, lineWidth: 1)
            )
        }
        .padding(12)
        .background(theme.backgroundColor)
        .overlay(
            Rectangle()
                .stroke(theme.textPrimary, lineWidth: 1)
        )
    }

    // MARK: - Network Section

    private var networkSection: some View {
        VStack(spacing: 12) {
            // Section header
            HStack {
                Image(systemName: "network")
                    .font(.system(size: 12))
                Text("Network")
                    .font(theme.titleFont)
                Spacer()
            }
            .foregroundColor(theme.textPrimary)

            // P2P Only toggle - DEACTIVATED (feature not ready for release)
            if false {
                HStack {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 14))
                        .foregroundColor(theme.textPrimary)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("P2P Only Mode")
                            .font(theme.bodyFont)
                            .foregroundColor(theme.textPrimary)
                        Text("No centralized API fallback")
                            .font(theme.captionFont)
                            .foregroundColor(theme.textSecondary)
                    }

                    Spacer()

                    Toggle("", isOn: $useP2POnly)
                        .labelsHidden()
                        .onChange(of: useP2POnly) { newValue in
                            UserDefaults.standard.set(newValue, forKey: "useP2POnly")
                            // FilterScanner reads from UserDefaults on init
                            print("🌐 P2P Only Mode: \(newValue ? "ENABLED" : "disabled")")
                        }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(theme.surfaceColor)
                .overlay(
                    Rectangle()
                        .stroke(theme.textPrimary, lineWidth: 1)
                )

                // Info text
                HStack(spacing: 8) {
                    Image(systemName: useP2POnly ? "checkmark.shield.fill" : "info.circle")
                        .foregroundColor(useP2POnly ? .green : .blue)
                        .font(.system(size: 12))

                    Text(useP2POnly ?
                        "Maximum security: All data verified via decentralized P2P network with multi-peer consensus." :
                        "P2P first with InsightAPI fallback. Enable P2P-only for trustless operation.")
                        .font(theme.captionFont)
                        .foregroundColor(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .background(useP2POnly ? Color.green.opacity(0.1) : theme.surfaceColor)
                .overlay(
                    Rectangle()
                        .stroke(useP2POnly ? Color.green.opacity(0.5) : theme.textPrimary.opacity(0.3), lineWidth: 1)
                )
            }

            // Banned Peers button
            Button(action: {
                bannedPeersList = networkManager.getBannedPeers()
                print("🚫 Banned peers list: \(bannedPeersList.count) items")
                for peer in bannedPeersList {
                    print("  - \(peer.address): \(peer.reason.rawValue)")
                }
                selectedBannedPeers.removeAll()
                showBannedPeers = true
            }) {
                HStack {
                    Image(systemName: "person.crop.circle.badge.xmark")
                        .font(.system(size: 14))
                    Text("Banned Peers")
                        .font(theme.bodyFont)
                    Spacer()
                    Text("\(networkManager.bannedPeersCount)")
                        .font(theme.monoFont)
                        .foregroundColor(networkManager.bannedPeersCount > 0 ? .red : theme.textSecondary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10))
                        .foregroundColor(theme.textSecondary)
                }
                .foregroundColor(theme.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(theme.surfaceColor)
                .overlay(
                    Rectangle()
                        .stroke(theme.textPrimary, lineWidth: 1)
                )
            }

            // Export Reliable Peers button - DEACTIVATED (developer feature)
            if false {
                Button(action: {
                    exportReliablePeers()
                }) {
                    HStack {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 14))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Export Reliable Peers")
                                .font(theme.bodyFont)
                            Text("\(networkManager.reliablePeerCount) peers with >50% success")
                                .font(theme.captionFont)
                                .foregroundColor(theme.textSecondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10))
                            .foregroundColor(theme.textSecondary)
                    }
                    .foregroundColor(theme.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(networkManager.reliablePeerCount >= 100 ? Color.green.opacity(0.1) : theme.surfaceColor)
                    .overlay(
                        Rectangle()
                            .stroke(networkManager.reliablePeerCount >= 100 ? Color.green : theme.textPrimary, lineWidth: 1)
                    )
                }

                // Info text about peer export
                if networkManager.reliablePeerCount >= 100 {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.system(size: 12))
                        Text("100+ reliable peers ready for bundling!")
                            .font(theme.captionFont)
                            .foregroundColor(.green)
                    }
                    .padding(8)
                    .background(Color.green.opacity(0.1))
                    .overlay(
                        Rectangle()
                            .stroke(Color.green.opacity(0.5), lineWidth: 1)
                    )
                }
            }
        }
        .padding(12)
        .background(theme.backgroundColor)
        .overlay(
            Rectangle()
                .stroke(theme.textPrimary, lineWidth: 1)
        )
        .sheet(isPresented: $showBannedPeers) {
            bannedPeersSheet
                #if os(macOS)
                .frame(minWidth: 500, idealWidth: 600, maxWidth: 700,
                       minHeight: 400, idealHeight: 500, maxHeight: 600)
                #endif
        }
        .alert("Peers Exported!", isPresented: $showPeerExportSuccess) {
            Button("OK", role: .cancel) {}
        } message: {
            #if os(macOS)
            Text("Exported \(peerExportCount) reliable peers to Desktop/bundled_peers.json\n\nThis file can be added to Resources/ for faster sync on fresh installs.")
            #else
            Text("Exported \(peerExportCount) reliable peers to Documents/bundled_peers.json\n\nAccess via Files app → On My iPhone → ZipherX")
            #endif
        }
    }

    // MARK: - Danger Zone Section (Export Key, Reveal Seed, Delete Wallet)

    private var exportSection: some View {
        VStack(spacing: 16) {
            // Section header - DANGER ZONE
            HStack {
                Image(systemName: "exclamationmark.octagon.fill")
                    .font(.system(size: 14))
                Text("DANGER ZONE")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                Spacer()
            }
            .foregroundColor(.red)

            // Export Private Key
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "key.fill")
                        .font(.system(size: 11))
                    Text("Export Private Key")
                        .font(theme.bodyFont)
                }
                .foregroundColor(.orange)

                Text("Your spending key allows full access to your funds. Never share it!")
                    .font(theme.captionFont)
                    .foregroundColor(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button(action: { exportPrivateKey() }) {
                    HStack {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 11))
                        Text("Export Key")
                            .font(theme.bodyFont)
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.orange)
                    .overlay(
                        Rectangle()
                            .stroke(Color.orange.opacity(0.8), lineWidth: 1)
                    )
                }
            }
            .padding(10)
            .background(Color.orange.opacity(0.1))
            .overlay(
                Rectangle()
                    .stroke(Color.orange.opacity(0.3), lineWidth: 1)
            )

            // Reveal Seed Phrase - DEACTIVATED (seed not stored for privacy)
            if false && !walletManager.isImportedWallet {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "list.number")
                            .font(.system(size: 11))
                        Text("Seed Phrase")
                            .font(theme.bodyFont)
                    }
                    .foregroundColor(theme.primaryColor)

                    Text("Your 24-word seed phrase was shown during wallet creation.")
                        .font(theme.captionFont)
                        .foregroundColor(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Button(action: { showSeedPhraseInfo = true }) {
                        HStack {
                            Image(systemName: "eye")
                                .font(.system(size: 11))
                            Text("View Seed Phrase")
                                .font(theme.bodyFont)
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(theme.primaryColor)
                        .overlay(
                            Rectangle()
                                .stroke(theme.primaryColor.opacity(0.8), lineWidth: 1)
                        )
                    }
                }
                .padding(10)
                .background(theme.primaryColor.opacity(0.1))
                .overlay(
                    Rectangle()
                        .stroke(theme.primaryColor.opacity(0.3), lineWidth: 1)
                )
            }

            // Delete Wallet
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "trash.fill")
                        .font(.system(size: 11))
                    Text("Delete Wallet")
                        .font(theme.bodyFont)
                }
                .foregroundColor(.red)

                Text("Permanently delete this wallet. Your funds will be UNRECOVERABLE without your private key backup!")
                    .font(theme.captionFont)
                    .foregroundColor(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button(action: { showDeleteWalletWarning = true }) {
                    HStack {
                        Image(systemName: "trash.fill")
                            .font(.system(size: 11))
                        Text("Delete Wallet Forever")
                            .font(theme.bodyFont)
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.red)
                    .overlay(
                        Rectangle()
                            .stroke(Color.red.opacity(0.8), lineWidth: 1)
                    )
                }
            }
            .padding(10)
            .background(Color.red.opacity(0.1))
            .overlay(
                Rectangle()
                    .stroke(Color.red.opacity(0.3), lineWidth: 1)
            )
        }
        .padding(12)
        .background(theme.backgroundColor)
        .overlay(
            Rectangle()
                .stroke(Color.red.opacity(0.5), lineWidth: 2)
        )
    }

    // MARK: - Debug Logging Section

    private var debugLoggingSection: some View {
        VStack(spacing: 12) {
            // Section header
            HStack {
                Image(systemName: "ladybug")
                    .font(.system(size: 12))
                Text("Debug Logging")
                    .font(theme.titleFont)
                Spacer()
            }
            .foregroundColor(theme.textPrimary)

            // Debug toggle
            HStack {
                Image(systemName: "doc.text")
                    .font(.system(size: 14))
                    .foregroundColor(theme.textPrimary)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Enable Debug Log")
                        .font(theme.bodyFont)
                        .foregroundColor(theme.textPrimary)
                    Text("Log size: \(debugLogSize)")
                        .font(theme.captionFont)
                        .foregroundColor(theme.textSecondary)
                }

                Spacer()

                Toggle("", isOn: $debugLoggingEnabled)
                    .labelsHidden()
                    .onChange(of: debugLoggingEnabled) { newValue in
                        DebugLogger.shared.isEnabled = newValue
                        if newValue {
                            DebugLogger.shared.logSystemInfo()
                        }
                        updateDebugLogSize()
                    }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(theme.surfaceColor)
            .overlay(
                Rectangle()
                    .stroke(theme.textPrimary, lineWidth: 1)
            )

            // Export and Clear buttons
            HStack(spacing: 12) {
                // Export button - shows privacy warning first
                Button(action: {
                    showLogExportWarning = true
                }) {
                    HStack {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 12))
                        Text("Export Log")
                            .font(theme.bodyFont)
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.blue)
                    .overlay(
                        Rectangle()
                            .stroke(Color.blue.opacity(0.8), lineWidth: 2)
                    )
                }

                // Clear button
                Button(action: {
                    DebugLogger.shared.clearLog()
                    updateDebugLogSize()
                }) {
                    HStack {
                        Image(systemName: "trash")
                            .font(.system(size: 12))
                        Text("Clear")
                            .font(theme.bodyFont)
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.red)
                    .overlay(
                        Rectangle()
                            .stroke(Color.red.opacity(0.8), lineWidth: 2)
                    )
                }
            }

            // Info text
            Text("When enabled, all app logs are saved to debug.log file that you can export for troubleshooting.")
                .font(theme.captionFont)
                .foregroundColor(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
        }
        .padding(12)
        .background(theme.backgroundColor)
        .overlay(
            Rectangle()
                .stroke(theme.textPrimary, lineWidth: 1)
        )
        .onAppear {
            updateDebugLogSize()
        }
        .sheet(isPresented: $showDebugLogShare) {
            ShareSheet(activityItems: [DebugLogger.shared.getLogFileURL()])
        }
        .alert("Privacy Warning", isPresented: $showLogExportWarning) {
            Button("Cancel", role: .cancel) {}
            Button("Export Anyway") {
                showDebugLogShare = true
            }
        } message: {
            Text("Debug logs may contain sensitive information including:\n\n• Transaction IDs\n• Block heights\n• Peer IP addresses\n• Wallet addresses (partial)\n\nOnly share with trusted parties for debugging purposes.")
        }
    }

    private func updateDebugLogSize() {
        let size = DebugLogger.shared.getLogFileSize()
        if size < 1024 {
            debugLogSize = "\(size) B"
        } else if size < 1024 * 1024 {
            debugLogSize = String(format: "%.1f KB", Double(size) / 1024.0)
        } else {
            debugLogSize = String(format: "%.1f MB", Double(size) / (1024.0 * 1024.0))
        }
    }

    // MARK: - Rescan Section

    private var rescanSection: some View {
        VStack(spacing: 12) {
            // Section header
            HStack {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12))
                Text("Blockchain Data")
                    .font(theme.titleFont)
                Spacer()
            }
            .foregroundColor(theme.textPrimary)

            // Warning box
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                        .font(.system(size: 14))

                    Text("DANGER ZONE")
                        .font(theme.bodyFont)
                        .foregroundColor(.red)

                    Spacer()
                }

                Text("Full rescan rebuilds the commitment tree from scratch. Required if witnesses are invalid. This takes 30-60 minutes.")
                    .font(theme.captionFont)
                    .foregroundColor(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
            .background(Color.red.opacity(0.1))
            .overlay(
                Rectangle()
                    .stroke(Color.red.opacity(0.5), lineWidth: 1)
            )

            // Quick Scan button - BLUE (fast but notes not spendable)
            Button(action: {
                showQuickScan = true
            }) {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                    Text("Quick Scan (view only)")
                        .font(theme.bodyFont)
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Color.blue)
                .overlay(
                    Rectangle()
                        .stroke(Color.blue.opacity(0.8), lineWidth: 2)
                )
            }

            // Rebuild Witnesses button - GREEN (make notes spendable)
            Button(action: {
                showRebuildWitnessesWarning = true
            }) {
                HStack {
                    Image(systemName: "checkmark.shield")
                        .font(.system(size: 12))
                    Text("Rebuild Witnesses (for spending)")
                        .font(theme.bodyFont)
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Color.green)
                .overlay(
                    Rectangle()
                        .stroke(Color.green.opacity(0.8), lineWidth: 2)
                )
            }

            // Repair Notes button - PURPLE (fix nullifier issues)
            Button(action: {
                showRepairNotesWarning = true
            }) {
                HStack {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.system(size: 12))
                    Text("Repair Notes (fix balance)")
                        .font(theme.bodyFont)
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Color.purple)
                .overlay(
                    Rectangle()
                        .stroke(Color.purple.opacity(0.8), lineWidth: 2)
                )
            }

            // Full Rescan from Height button - ORANGE (spendable notes)
            Button(action: {
                showFullRescanFromHeight = true
            }) {
                HStack {
                    Image(systemName: "arrow.clockwise.circle")
                        .font(.system(size: 12))
                    Text("Full Rescan from Height")
                        .font(theme.bodyFont)
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Color.orange)
                .overlay(
                    Rectangle()
                        .stroke(Color.orange.opacity(0.8), lineWidth: 2)
                )
            }

            // Full Rescan button - RED (from scratch)
            Button(action: {
                showRescanWarning = true
            }) {
                HStack {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12))
                    Text("Full Rescan (from scratch)")
                        .font(theme.bodyFont)
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Color.red)
                .overlay(
                    Rectangle()
                        .stroke(Color.red.opacity(0.8), lineWidth: 2)
                )
            }
        }
        .padding(12)
        .background(theme.backgroundColor)
        .overlay(
            Rectangle()
                .stroke(theme.textPrimary, lineWidth: 1)
        )
    }

    // Note: Delete Wallet functionality is now part of exportSection (Danger Zone)

    private func performDeleteWallet() {
        do {
            // Delete the database file
            try WalletDatabase.shared.deleteDatabase()

            // Delete the wallet (clears keychain + UserDefaults)
            try walletManager.deleteWallet()

            // Clear additional UserDefaults
            let defaults = UserDefaults.standard
            defaults.removeObject(forKey: "wallet_created")
            defaults.removeObject(forKey: "wallet_imported")
            defaults.removeObject(forKey: "z_address")
            defaults.removeObject(forKey: "lastScannedHeight")
            defaults.removeObject(forKey: "lastScannedHash")
            defaults.synchronize()

            print("Wallet deleted successfully")
        } catch {
            errorMessage = "Failed to delete wallet: \(error.localizedDescription)"
            showError = true
        }
    }

    // MARK: - Rescan Progress View

    private var rescanProgressView: some View {
        VStack(spacing: 20) {
            Text("Full Blockchain Rescan")
                .font(theme.titleFont)
                .foregroundColor(theme.textPrimary)

            // Progress bar
            VStack(spacing: 8) {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(theme.surfaceColor)
                            .frame(height: 20)
                            .overlay(
                                Rectangle()
                                    .stroke(theme.textPrimary, lineWidth: 1)
                            )

                        Rectangle()
                            .fill(Color.blue)
                            .frame(width: geometry.size.width * rescanProgress, height: 18)
                            .offset(x: 1)
                    }
                }
                .frame(height: 20)

                Text("\(Int(rescanProgress * 100))%")
                    .font(theme.titleFont)
                    .foregroundColor(theme.textPrimary)
            }

            // Block progress
            VStack(spacing: 4) {
                HStack {
                    Text("Block:")
                        .font(theme.captionFont)
                        .foregroundColor(theme.textSecondary)
                    Spacer()
                    Text("\(rescanCurrentHeight) / \(rescanMaxHeight)")
                        .font(theme.captionFont)
                        .foregroundColor(theme.textPrimary)
                }

                HStack {
                    Text("Elapsed:")
                        .font(theme.captionFont)
                        .foregroundColor(theme.textSecondary)
                    Spacer()
                    Text(formatDuration(rescanElapsedTime))
                        .font(theme.captionFont)
                        .foregroundColor(theme.textPrimary)
                }

                HStack {
                    Text("Estimated:")
                        .font(theme.captionFont)
                        .foregroundColor(theme.textSecondary)
                    Spacer()
                    Text(estimatedTimeRemaining)
                        .font(theme.captionFont)
                        .foregroundColor(theme.textPrimary)
                }

                HStack {
                    Text("Tree Size:")
                        .font(theme.captionFont)
                        .foregroundColor(theme.textSecondary)
                    Spacer()
                    Text("\(ZipherXFFI.treeSize()) commitments")
                        .font(theme.captionFont)
                        .foregroundColor(theme.textPrimary)
                }
            }
            .padding(12)
            .background(theme.surfaceColor)
            .overlay(
                Rectangle()
                    .stroke(theme.textPrimary, lineWidth: 1)
            )

            // Status message
            if rescanProgress < 0 {
                // Error state
                VStack(spacing: 8) {
                    Text("Rescan failed!")
                        .font(theme.titleFont)
                        .foregroundColor(.red)
                    Text(errorMessage)
                        .font(theme.captionFont)
                        .foregroundColor(theme.textSecondary)
                        .multilineTextAlignment(.center)
                }
            } else {
                Text(rescanProgress >= 1.0 ? "Rescan complete!" : "Building commitment tree...")
                    .font(theme.captionFont)
                    .foregroundColor(rescanProgress >= 1.0 ? .green : theme.textSecondary)
            }

            if rescanProgress >= 1.0 || rescanProgress < 0 {
                Button(rescanProgress < 0 ? "Close" : "Done") {
                    showRescanProgress = false
                    rescanTimer?.invalidate()
                    rescanTimer = nil
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(rescanProgress < 0 ? Color.red : Color.blue)
                .foregroundColor(.white)
                .overlay(
                    Rectangle()
                        .stroke(theme.textPrimary, lineWidth: 1)
                )
            }
        }
        .padding(30)
        .background(theme.backgroundColor)
        .interactiveDismissDisabled(rescanProgress >= 0 && rescanProgress < 1.0)
    }

    private var estimatedTimeRemaining: String {
        guard rescanProgress > 0.01, rescanElapsedTime > 5 else {
            return "Calculating..."
        }

        let totalEstimate = rescanElapsedTime / rescanProgress
        let remaining = totalEstimate - rescanElapsedTime

        if remaining < 60 {
            return "< 1 minute"
        } else {
            return formatDuration(remaining)
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        let secs = Int(seconds) % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        } else {
            return String(format: "%d:%02d", minutes, secs)
        }
    }

    // MARK: - PIN Setup Sheet

    private var pinSetupSheet: some View {
        VStack(spacing: 20) {
            Text("Set PIN Code")
                .font(theme.titleFont)
                .foregroundColor(theme.textPrimary)

            VStack(spacing: 12) {
                // PIN entry with show/hide toggle
                HStack {
                    if showPINText {
                        TextField("Enter 4-6 digit PIN", text: $pinCode)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            #if os(iOS)
                            .keyboardType(.numberPad)
                            #endif
                    } else {
                        SecureField("Enter 4-6 digit PIN", text: $pinCode)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            #if os(iOS)
                            .keyboardType(.numberPad)
                            #endif
                    }

                    Button(action: { showPINText.toggle() }) {
                        Image(systemName: showPINText ? "eye.slash.fill" : "eye.fill")
                            .foregroundColor(theme.textSecondary)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                .frame(maxWidth: 250)

                // Confirm PIN with same visibility
                HStack {
                    if showPINText {
                        TextField("Confirm PIN", text: $confirmPIN)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            #if os(iOS)
                            .keyboardType(.numberPad)
                            #endif
                    } else {
                        SecureField("Confirm PIN", text: $confirmPIN)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            #if os(iOS)
                            .keyboardType(.numberPad)
                            #endif
                    }

                    // Spacer to align with first field's button
                    Image(systemName: "eye.fill")
                        .foregroundColor(.clear)
                }
                .frame(maxWidth: 250)
            }

            // Show PIN mismatch warning
            if !pinCode.isEmpty && !confirmPIN.isEmpty && pinCode != confirmPIN {
                Text("PINs do not match")
                    .font(theme.captionFont)
                    .foregroundColor(.red)
            }

            HStack(spacing: 12) {
                Button("Cancel") {
                    pinCode = ""
                    confirmPIN = ""
                    showPINText = false
                    usePINCode = false
                    showPINSetup = false
                }
                .foregroundColor(.red)

                Button("Save") {
                    savePIN()
                    showPINText = false
                }
                .disabled(pinCode.count < 4 || pinCode != confirmPIN)
            }
        }
        .padding(30)
        .background(theme.backgroundColor)
    }

    // MARK: - Banned Peers Sheet

    private var bannedPeersSheet: some View {
        VStack(spacing: 0) {
            // macOS header with Done button
            HStack {
                Text("Banned Peers")
                    .font(theme.titleFont)
                    .foregroundColor(theme.textPrimary)
                Spacer()
                Text("\(bannedPeersList.count) banned")
                    .font(theme.bodyFont)
                    .foregroundColor(bannedPeersList.isEmpty ? theme.textSecondary : .red)
                Spacer()
                Button("Done") {
                    showBannedPeers = false
                }
                .foregroundColor(theme.primaryColor)
            }
            .padding()
            .background(theme.surfaceColor)

            Divider()

            if bannedPeersList.isEmpty {
                // Empty state
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 40))
                        .foregroundColor(.green)
                    Text("No Banned Peers")
                        .font(theme.titleFont)
                        .foregroundColor(theme.textPrimary)
                    Text("All peers are currently allowed to connect.")
                        .font(theme.bodyFont)
                        .foregroundColor(theme.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(theme.surfaceColor)
            } else {
                // List of banned peers
                List {
                    ForEach(bannedPeersList, id: \.address) { peer in
                        BannedPeerRow(
                            peer: peer,
                            isSelected: selectedBannedPeers.contains(peer.address),
                            onToggle: {
                                if selectedBannedPeers.contains(peer.address) {
                                    selectedBannedPeers.remove(peer.address)
                                } else {
                                    selectedBannedPeers.insert(peer.address)
                                }
                            }
                        )
                        .environmentObject(themeManager)
                    }
                }
                .listStyle(PlainListStyle())
            }

            // Action buttons
            if !bannedPeersList.isEmpty {
                VStack(spacing: 8) {
                    // Unban selected
                    Button(action: {
                        for address in selectedBannedPeers {
                            networkManager.unbanPeer(address: address)
                        }
                        bannedPeersList = networkManager.getBannedPeers()
                        selectedBannedPeers.removeAll()
                    }) {
                        HStack {
                            Image(systemName: "checkmark.circle")
                            Text("Unban Selected (\(selectedBannedPeers.count))")
                        }
                        .font(theme.bodyFont)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(selectedBannedPeers.isEmpty ? Color.gray : Color.green)
                        .cornerRadius(4)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .disabled(selectedBannedPeers.isEmpty)

                    // Unban all
                    Button(action: {
                        networkManager.unbanAllPeers()
                        bannedPeersList = []
                        selectedBannedPeers.removeAll()
                    }) {
                        HStack {
                            Image(systemName: "arrow.uturn.backward")
                            Text("Unban All")
                        }
                        .font(theme.bodyFont)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.orange)
                        .cornerRadius(4)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                .padding()
                .background(theme.backgroundColor)
            }
        }
        .background(theme.backgroundColor)
    }

    // MARK: - Debug Section

    private var debugSection: some View {
        VStack(spacing: 12) {
            // Section header
            HStack {
                Image(systemName: "hammer")
                    .font(.system(size: 12))
                Text("Debug Tools")
                    .font(theme.titleFont)
                Spacer()
            }
            .foregroundColor(theme.textPrimary)

            // Recover Spent Notes button - for failed transaction recovery
            Button(action: {
                recoverSpentNotes()
            }) {
                HStack {
                    Image(systemName: "arrow.uturn.backward.circle")
                        .font(.system(size: 12))
                    Text("Recover Stuck Funds")
                        .font(theme.bodyFont)
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Color.green)
                .overlay(
                    Rectangle()
                        .stroke(Color.green.opacity(0.8), lineWidth: 2)
                )
            }

            Text("If a transaction failed but your balance shows 0, this will recover any stuck funds back to spendable.")
                .font(theme.captionFont)
                .foregroundColor(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)

            // Clear headers button
            Button(action: {
                clearHeaders()
            }) {
                HStack {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                    Text("Clear Block Headers")
                        .font(theme.bodyFont)
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Color.purple)
                .overlay(
                    Rectangle()
                        .stroke(Color.purple.opacity(0.8), lineWidth: 2)
                )
            }

            // Info text
            Text("Clears all cached block headers. Use this to test header sync progress bar. Headers will re-sync on next balance refresh.")
                .font(theme.captionFont)
                .foregroundColor(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
        }
        .padding(12)
        .background(theme.backgroundColor)
        .overlay(
            Rectangle()
                .stroke(theme.textPrimary, lineWidth: 1)
        )
    }

    // MARK: - Actions

    private func exportReliablePeers() {
        let jsonString = networkManager.exportReliablePeersForBundling()

        // Platform-specific save location
        #if os(macOS)
        let exportURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop")
            .appendingPathComponent("bundled_peers.json")
        #else
        // iOS: Save to Documents folder (can be accessed via Files app)
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let exportURL = documentsURL.appendingPathComponent("bundled_peers.json")
        #endif

        do {
            try jsonString.write(to: exportURL, atomically: true, encoding: .utf8)

            // Count peers from JSON
            if let data = jsonString.data(using: .utf8),
               let peers = try? JSONDecoder().decode([BundledPeer].self, from: data) {
                peerExportCount = peers.count
            }

            showPeerExportSuccess = true
            print("📡 Exported \(peerExportCount) reliable peers to \(exportURL.path)")
        } catch {
            errorMessage = "Failed to export peers: \(error.localizedDescription)"
            showError = true
        }
    }

    private func recoverSpentNotes() {
        Task {
            do {
                let recoveredCount = try await walletManager.forceRecoverAllSpentNotes()
                await MainActor.run {
                    if recoveredCount > 0 {
                        // Cypherpunk success messages
                        let messages = [
                            "Your shielded ZCL has been liberated from the void.\n\nThe blockchain never forgets, but it forgives.\n\n\(recoveredCount) note(s) restored to your control.",
                            "Zero-knowledge proofs don't lie.\n\nYour \(recoveredCount) note(s) were never truly lost - just temporarily displaced in the merkle tree of time.",
                            "Transaction reversed in the shadows.\n\n\(recoveredCount) shielded note(s) have returned to sender.\n\nPrivacy preserved. Funds restored.",
                            "The ciphertext remembers.\n\n\(recoveredCount) note(s) decrypted and recovered.\n\nYour keys, your coins.",
                            "Nullifier rejected. Notes reclaimed.\n\n\(recoveredCount) shielded output(s) back in your wallet.\n\nNot your keys? Not your problem anymore."
                        ]
                        recoveryMessage = messages.randomElement() ?? messages[0]
                        showRecoverySuccess = true
                    } else {
                        errorMessage = "No stuck funds found.\n\nIf your balance is still 0, try a full rescan from Settings."
                        showError = true
                    }
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Recovery failed: \(error.localizedDescription)"
                    showError = true
                }
            }
        }
    }

    private func clearHeaders() {
        do {
            try HeaderStore.shared.open()
            try HeaderStore.shared.clearAllHeaders()
            print("🗑️ Cleared all block headers")
            errorMessage = "Block headers cleared! Tap refresh to re-sync and see the progress bar."
            showError = true
        } catch {
            errorMessage = "Failed to clear headers: \(error.localizedDescription)"
            showError = true
        }
    }

    private func exportPrivateKey() {
        do {
            exportedKey = try walletManager.exportSpendingKey()
            showExportAlert = true
            // SECURITY: Never log private key operations
        } catch {
            errorMessage = "Failed to export key"
            showError = true
        }
    }

    private func checkBiometricAvailability() {
        let context = LAContext()
        var error: NSError?
        biometricAvailable = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)

        // Load saved preferences
        useFaceID = UserDefaults.standard.bool(forKey: "useBiometricAuth")
        usePINCode = UserDefaults.standard.string(forKey: "walletPIN") != nil
    }

    private func getBiometricName() -> String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)

        switch context.biometryType {
        case .faceID:
            return "Face ID"
        case .touchID:
            return "Touch ID"
        default:
            return "Biometric"
        }
    }

    private func getBiometricIcon() -> String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)

        switch context.biometryType {
        case .faceID:
            return "faceid"
        case .touchID:
            return "touchid"
        default:
            return "lock"
        }
    }

    private func authenticateWithBiometrics() {
        let context = LAContext()
        let reason = "Enable biometric authentication for ZipherX"

        context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { success, error in
            DispatchQueue.main.async {
                if success {
                    UserDefaults.standard.set(true, forKey: "useBiometricAuth")
                    useFaceID = true
                } else {
                    useFaceID = false
                    if let error = error {
                        errorMessage = error.localizedDescription
                        showError = true
                    }
                }
            }
        }
    }

    private func savePIN() {
        guard pinCode.count >= 4 && pinCode.count <= 6 else {
            errorMessage = "PIN must be 4-6 digits"
            showError = true
            return
        }

        guard pinCode == confirmPIN else {
            errorMessage = "PINs do not match"
            showError = true
            return
        }

        // SECURITY: Hash PIN with PBKDF2-like derivation before storing
        let hashedPIN = PINSecurity.hashPIN(pinCode)
        UserDefaults.standard.set(hashedPIN, forKey: "walletPIN")
        pinCode = ""
        confirmPIN = ""
        showPINSetup = false
    }

    private func startFullRescan() {
        // Reset progress state
        rescanProgress = 0
        rescanCurrentHeight = 0
        rescanMaxHeight = 0
        rescanStartTime = Date()
        rescanElapsedTime = 0

        // Show progress view
        showRescanProgress = true

        // Start elapsed time timer
        rescanTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            if let start = rescanStartTime {
                rescanElapsedTime = Date().timeIntervalSince(start)
            }
        }

        // Perform rescan in background
        Task {
            do {
                print("🔄 Starting full rescan...")

                try await walletManager.performFullRescan { progress, currentHeight, maxHeight in
                    Task { @MainActor in
                        rescanProgress = progress
                        rescanCurrentHeight = currentHeight
                        rescanMaxHeight = maxHeight
                    }
                }

                // Complete
                await MainActor.run {
                    rescanProgress = 1.0
                    print("✅ Full rescan complete!")
                }

            } catch {
                await MainActor.run {
                    rescanTimer?.invalidate()
                    rescanTimer = nil
                    // Keep progress sheet open but show error in it
                    errorMessage = "Rescan failed: \(error.localizedDescription)"
                    print("❌ Rescan error: \(error)")
                    // Set progress to -1 to indicate error state
                    rescanProgress = -1
                }
            }
        }
    }

    private func startRebuildWitnesses() {
        // Reset progress state
        rescanProgress = 0
        rescanCurrentHeight = 0
        rescanMaxHeight = 0
        rescanStartTime = Date()
        rescanElapsedTime = 0

        // Show progress view
        showRescanProgress = true

        // Start elapsed time timer
        rescanTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            if let start = rescanStartTime {
                rescanElapsedTime = Date().timeIntervalSince(start)
            }
        }

        // Perform rebuild in background
        Task {
            do {
                print("🔄 Starting witness rebuild...")

                try await walletManager.rebuildWitnessesForSpending { progress, currentHeight, maxHeight in
                    Task { @MainActor in
                        rescanProgress = progress
                        rescanCurrentHeight = currentHeight
                        rescanMaxHeight = maxHeight
                    }
                }

                // Complete
                await MainActor.run {
                    rescanProgress = 1.0
                    print("✅ Witness rebuild complete!")
                }

            } catch {
                await MainActor.run {
                    rescanTimer?.invalidate()
                    rescanTimer = nil
                    errorMessage = "Witness rebuild failed: \(error.localizedDescription)"
                    print("❌ Rebuild error: \(error)")
                    rescanProgress = -1
                }
            }
        }
    }

    private func startRepairNotes() {
        // Reset progress state
        rescanProgress = 0
        rescanCurrentHeight = 0
        rescanMaxHeight = 0
        rescanStartTime = Date()
        rescanElapsedTime = 0

        // Show progress view
        showRescanProgress = true

        // Start elapsed time timer
        rescanTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            if let start = rescanStartTime {
                rescanElapsedTime = Date().timeIntervalSince(start)
            }
        }

        // Perform note repair in background
        Task {
            do {
                print("🔧 Starting note repair...")

                try await walletManager.repairNotesAfterBundledTree { progress, currentHeight, maxHeight in
                    Task { @MainActor in
                        rescanProgress = progress
                        rescanCurrentHeight = currentHeight
                        rescanMaxHeight = maxHeight
                    }
                }

                // Complete
                await MainActor.run {
                    rescanProgress = 1.0
                    print("✅ Note repair complete!")
                }

            } catch {
                await MainActor.run {
                    rescanTimer?.invalidate()
                    rescanTimer = nil
                    errorMessage = "Note repair failed: \(error.localizedDescription)"
                    print("❌ Repair error: \(error)")
                    rescanProgress = -1
                }
            }
        }
    }

    private func startQuickScan(from startHeight: UInt64) {
        // Reset progress state
        rescanProgress = 0
        rescanCurrentHeight = startHeight
        rescanMaxHeight = 0
        rescanStartTime = Date()
        rescanElapsedTime = 0

        // Show progress view
        showRescanProgress = true

        // Start elapsed time timer
        rescanTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            if let start = rescanStartTime {
                rescanElapsedTime = Date().timeIntervalSince(start)
            }
        }

        // Perform quick scan in background
        Task {
            do {
                print("🔍 Starting quick scan from height \(startHeight)...")

                try await walletManager.performQuickScan(fromHeight: startHeight) { progress, currentHeight, maxHeight in
                    Task { @MainActor in
                        rescanProgress = progress
                        rescanCurrentHeight = currentHeight
                        rescanMaxHeight = maxHeight
                    }
                }

                // Complete
                await MainActor.run {
                    rescanProgress = 1.0
                    print("✅ Quick scan complete!")
                }

            } catch {
                await MainActor.run {
                    rescanTimer?.invalidate()
                    rescanTimer = nil
                    errorMessage = "Quick scan failed: \(error.localizedDescription)"
                    print("❌ Quick scan error: \(error)")
                    rescanProgress = -1
                }
            }
        }
    }

    private func startFullRescanFromHeight(_ startHeight: UInt64) {
        // Reset progress state
        rescanProgress = 0
        rescanCurrentHeight = startHeight
        rescanMaxHeight = 0
        rescanStartTime = Date()
        rescanElapsedTime = 0

        // Show progress view
        showRescanProgress = true

        // Start elapsed time timer
        rescanTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            if let start = rescanStartTime {
                rescanElapsedTime = Date().timeIntervalSince(start)
            }
        }

        // Perform full rescan from specified height in background
        Task {
            do {
                print("🔄 Starting full rescan from height \(startHeight)...")

                try await walletManager.performFullRescan(fromHeight: startHeight) { progress, currentHeight, maxHeight in
                    Task { @MainActor in
                        rescanProgress = progress
                        rescanCurrentHeight = currentHeight
                        rescanMaxHeight = maxHeight
                    }
                }

                // Complete
                await MainActor.run {
                    rescanProgress = 1.0
                    print("✅ Full rescan from height complete!")
                }

            } catch {
                await MainActor.run {
                    rescanTimer?.invalidate()
                    rescanTimer = nil
                    errorMessage = "Full rescan failed: \(error.localizedDescription)"
                    print("❌ Full rescan error: \(error)")
                    rescanProgress = -1
                }
            }
        }
    }

    // MARK: - Clipboard Helper

    private func copyToClipboard(_ string: String) {
        #if os(iOS)
        UIPasteboard.general.string = string
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #endif
    }
}

// MARK: - Share Sheet

#if os(iOS)
struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    var applicationActivities: [UIActivity]? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(
            activityItems: activityItems,
            applicationActivities: applicationActivities
        )
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#elseif os(macOS)
struct ShareSheet: View {
    let activityItems: [Any]

    var body: some View {
        VStack(spacing: 16) {
            Text("Share Log File")
                .font(.headline)

            if let url = activityItems.first as? URL {
                Text(url.lastPathComponent)
                    .font(.caption)
                    .foregroundColor(.secondary)

                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.path, forType: .string)
                }

                Button("Open in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
        }
        .padding()
        .frame(minWidth: 300)
    }
}
#endif

// MARK: - Banned Peer Row

struct BannedPeerRow: View {
    @EnvironmentObject var themeManager: ThemeManager
    let peer: BannedPeer
    let isSelected: Bool
    let onToggle: () -> Void

    private var theme: AppTheme { themeManager.currentTheme }

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 12) {
                // Selection indicator
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isSelected ? .green : .gray)
                    .font(.system(size: 20))

                // Peer info
                VStack(alignment: .leading, spacing: 4) {
                    Text(peer.address)
                        .font(theme.monoFont)
                        .foregroundColor(theme.textPrimary)

                    HStack(spacing: 8) {
                        // Ban reason
                        Text(peer.reason.rawValue)
                            .font(theme.captionFont)
                            .foregroundColor(.red)

                        // Time remaining
                        Text("• \(timeRemaining)")
                            .font(theme.captionFont)
                            .foregroundColor(theme.textSecondary)
                    }
                }

                Spacer()
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(PlainButtonStyle())
    }

    private var timeRemaining: String {
        let expiresAt = peer.banTime.addingTimeInterval(peer.banDuration)
        let remaining = expiresAt.timeIntervalSinceNow

        if remaining <= 0 {
            return "Expired"
        }

        let hours = Int(remaining / 3600)
        let minutes = Int((remaining.truncatingRemainder(dividingBy: 3600)) / 60)

        if hours > 0 {
            return "\(hours)h \(minutes)m left"
        } else {
            return "\(minutes)m left"
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(WalletManager.shared)
        .environmentObject(NetworkManager.shared)
        .environmentObject(ThemeManager.shared)
}
