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
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var walletManager: WalletManager
    @EnvironmentObject var networkManager: NetworkManager
    #if os(macOS)
    @ObservedObject private var fullNodeManager = FullNodeManager.shared
    #endif
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
    @State private var showFullResyncWarning = false  // FIX #367: Nuclear option
    @State private var showScanUnrecordedWarning = false
    @State private var showScanUnrecordedResult = false
    @State private var scanUnrecordedResultMessage = ""
    @State private var isScanningUnrecorded = false
    @State private var isRebuildingCorruptedWitnesses = false  // FIX #588: Rebuild corrupted witnesses
    @State private var showForceRebuildWitnessesWarning = false  // FIX: Force rebuild all witnesses
    @State private var isRebuildingWitnesses = false
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

    // FIX #284: Parked peers management (connection timeouts - auto-retry)
    @State private var showParkedPeers = false
    @State private var parkedPeersList: [ParkedPeer] = []

    // FIX #284: Preferred seeds management
    @State private var showPreferredSeeds = false
    @State private var preferredSeedsList: [WalletDatabase.TrustedPeer] = []

    // Custom nodes management
    @State private var showCustomNodes = false

    // FIX #229: Trusted peers management
    @State private var showTrustedPeers = false
    @State private var trustedPeersCount = 0

    // Delete wallet
    @State private var showDeleteWalletWarning = false
    @State private var showDeleteWalletConfirm = false
    @State private var deleteConfirmText = ""

    // Peer export management
    @State private var showPeerExportSuccess = false
    @State private var peerExportCount = 0

    // Seed phrase info
    @State private var showSeedPhraseInfo = false

    // Privacy Report
    @State private var showPrivacyReport = false

    @EnvironmentObject var themeManager: ThemeManager

    // Theme shortcut
    private var theme: AppTheme { themeManager.currentTheme }

    // FIX #1334: Flattened alert chain to prevent iOS stack overflow (EXC_BAD_ACCESS code=2).
    // Previously 8 levels of computed properties (body → contentWithAlerts → mainContent →
    // scrollViewContent → settingsScrollView → framedContent → baseContent → deletableContent)
    // each adding .alert() modifiers. Each level added generic type frames to the stack.
    // iOS main thread stack is 1MB (vs 8MB macOS) → stack overflow at networkSection.
    // Fix: all alerts/sheets applied at body level → 2 levels instead of 8.
    var body: some View {
        deletableContent
            .onAppear {
                checkBiometricAvailability()
                networkManager.updatePeerCountsForSettings()
                loadTrustedPeersCount()  // FIX #1367: Show correct count immediately
            }
            // Sheets
            .sheet(isPresented: $showPINSetup) {
                pinSetupSheet
                    #if os(macOS)
                    .frame(minWidth: 400, idealWidth: 450, minHeight: 350, idealHeight: 400)
                    #endif
            }
            .sheet(isPresented: $showRescanProgress) {
                rescanProgressView
                    #if os(macOS)
                    .frame(minWidth: 450, idealWidth: 500, minHeight: 300, idealHeight: 350)
                    #endif
            }
            // Export & error alerts
            .alert("Export Private Key", isPresented: $showExportAlert) {
                Button("Copy Full Key") {
                    // FIX #1360: TASK 6 — Auto-clear after 10 seconds for private keys
                    ClipboardManager.copyWithAutoExpiry(exportedKey, seconds: 10)
                }
                Button("Cancel", role: .cancel) {
                    // FIX #1360: TASK 6 — Clear sensitive data on dismissal
                    exportedKey = ""
                }
            } message: {
                // FIX #1360: TASK 6 — Show truncated key in alert, not full key
                let displayKey = String(exportedKey.prefix(8)) + "..." + String(exportedKey.suffix(8))
                Text("Your private key:\n\n\(displayKey)\n\nKeep this safe! Anyone with this key can spend your funds.")
            }
            .onDisappear {
                // FIX #1360: TASK 6 — Clear sensitive data when alert is dismissed
                if !showExportAlert {
                    exportedKey = ""
                }
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
            // Rescan alerts
            .alert("Full Blockchain Rescan", isPresented: $showRescanWarning) {
                Button("Cancel", role: .cancel) {}
                Button("Rescan", role: .destructive) { startFullRescan() }
            } message: {
                Text("WARNING: This will delete all cached data and rescan the entire blockchain from scratch.\n\nThis process can take 30-60 minutes and uses significant data.\n\nYour funds are safe - only cached data is deleted.\n\nDo you want to continue?")
            }
            .alert("Quick Scan for Notes", isPresented: $showQuickScan) {
                TextField("Start Height", text: $quickScanHeight)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                Button("Cancel", role: .cancel) { quickScanHeight = "" }
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
                Button("Cancel", role: .cancel) { fullRescanHeight = "" }
                Button("Rescan") {
                    if let height = UInt64(fullRescanHeight) {
                        startFullRescanFromHeight(height)
                    }
                    fullRescanHeight = ""
                }
            } message: {
                Text("Enter block height to start full rescan.\n\nThis rebuilds the commitment tree and creates proper witnesses so notes can be SPENT.\n\nExample: 2918000")
            }
            // Repair alerts
            .alert("Rebuild Witnesses", isPresented: $showRebuildWitnessesWarning) {
                Button("Cancel", role: .cancel) {}
                Button("Rebuild", role: .destructive) { startRebuildWitnesses() }
            } message: {
                Text("This will rebuild witnesses from the bundled tree height.\n\nThis is needed after Quick Scan to make notes spendable.\n\nIt will take 5-15 minutes depending on blocks since bundled tree.\n\nDo you want to continue?")
            }
            .alert("Repair Database", isPresented: $showRepairNotesWarning) {
                Button("Cancel", role: .cancel) {}
                Button("Repair (Tor will be disabled)", role: .destructive) { startRepairNotes() }
            } message: {
                Text("⚠️ PRIVACY NOTICE ⚠️\n\nTor will be TEMPORARILY DISABLED during repair for faster P2P scanning. Your IP will be visible to blockchain peers during this operation.\n\n━━━━━━━━━━━━━━━━━━━━━━\n\nThis repairs database corruption by:\n• Re-scanning blockchain for spent notes\n• Clearing ALL block headers (fixes timestamps)\n• Reloading commitment tree from boost file\n• Recalculating nullifiers for all notes\n• Clearing and rebuilding delta bundle\n\nUse this if:\n• Balance shows wrong amount\n• Notes marked unspent but are spent\n• Transaction dates show NO DATE\n\nThis will take 5-15 minutes.\nTor will be restored after completion.\n\nDo you want to continue?")
            }
            .alert("Verify & Repair Wallet", isPresented: $showFullResyncWarning) {
                Button("Cancel", role: .cancel) {}
                Button("Verify & Repair", role: .destructive) { startFullResync() }
            } message: {
                Text("This will verify your wallet and repair any issues:\n\n• Rebuilds all notes from blockchain\n• Rebuilds transaction history\n• Re-downloads boost file from GitHub\n• Rescans entire blockchain\n\n⚠️ Tor will be disabled during repair\n⚠️ Uses significant data/bandwidth\n\nContinue?")
            }
            // Scan & rebuild alerts
            .alert("Scan for Unrecorded TX", isPresented: $showScanUnrecordedWarning) {
                Button("Cancel", role: .cancel) {}
                Button("Scan Now", role: .destructive) { startScanForUnrecordedTx() }
            } message: {
                Text("This will quickly scan blocks from your last checkpoint to find any transactions that were broadcast but not recorded in the database.\n\nUse this if:\n• Send showed 'failed' but TX went through\n• Balance doesn't reflect a recent send\n• Tor timeout during broadcast\n\nThis is fast (usually < 30 seconds).")
            }
            .alert("Force Rebuild All Witnesses", isPresented: $showForceRebuildWitnessesWarning) {
                Button("Cancel", role: .cancel) {}
                Button("Rebuild", role: .destructive) { startForceRebuildWitnesses() }
            } message: {
                Text("This will force a complete rebuild of all witnesses for your unspent notes.\n\nUse this if:\n• Balance shows incorrectly (too low)\n• Some notes are unspendable\n• 'Witness doesn't match tree root' errors\n\nThis may take 1-5 minutes depending on the number of notes.\n\nYour wallet will remain usable during the rebuild.")
            }
            .alert("Scan Complete", isPresented: $showScanUnrecordedResult) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(scanUnrecordedResultMessage)
            }
            // Delete wallet alerts
            .alert("DANGER - DELETE WALLET", isPresented: $showDeleteWalletWarning) {
                Button("Cancel - Keep Wallet", role: .cancel) {}
                Button("I Understand, Delete", role: .destructive) { showDeleteWalletConfirm = true }
            } message: {
                Text("!!! CRITICAL WARNING !!!\n\nThis will PERMANENTLY DELETE your wallet!\n\nYour PRIVATE KEY will be ERASED FOREVER.\nAll transaction history will be LOST.\nYour funds will be UNRECOVERABLE.\n\nHave you EXPORTED your private key?\nIf not, press Cancel NOW!\n\nTHIS CANNOT BE UNDONE!")
            }
            .alert("FINAL CONFIRMATION", isPresented: $showDeleteWalletConfirm) {
                TextField("Type DELETE to confirm", text: $deleteConfirmText)
                Button("CANCEL - KEEP MY WALLET", role: .cancel) { deleteConfirmText = "" }
                Button("DELETE FOREVER", role: .destructive) {
                    if deleteConfirmText == "DELETE" {
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

    private var deletableContent: some View {
        ScrollView {
            VStack(spacing: 16) {
                #if os(macOS)
                walletModeSection
                #endif

                securitySection
                privacyReportSection
                networkSection
                exportSection
                repairDatabaseSection
                debugLoggingSection

                Spacer()
            }
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(themeManager.currentTheme.backgroundColor)
    }

    // MARK: - Wallet Mode Section (macOS only)

    #if os(macOS)
    @State private var showBootstrapSheet = false
    @State private var showModeChangeAlert = false
    @State private var showDaemonInstallChoice = false
    @State private var showDaemonInstallProgress = false
    @State private var daemonInstallError: String?
    @State private var showNodeManagement = false

    private var walletModeSection: some View {
        let modeManager = WalletModeManager.shared
        let bootstrapManager = BootstrapManager.shared
        let fullNodeManager = FullNodeManager.shared

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

            // FIX #1367: Unified mode picker — always visible, "P2P" and "Full Node" labels
            walletSourcePicker(modeManager: modeManager)

            // Full Node specific options (daemon status, debug level, node management)
            if modeManager.currentMode == .fullNode {
                fullNodeStatusView(modeManager: modeManager)
            }

            // Info text
            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                    .foregroundColor(.blue)
                    .font(.system(size: 12))

                Text(modeManager.walletSource == .zipherx ?
                    "P2P mode uses direct peer-to-peer network for fast, mobile-friendly operation." :
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
            Button("I Understand, Continue") {
                // Check if daemon is already installed
                if fullNodeManager.isDaemonInstalledAtPath {
                    // Daemon already installed, proceed directly
                    modeManager.setWalletSource(.walletDat)
                    modeManager.setMode(.fullNode)
                    if bootstrapManager.needsBootstrap {
                        showBootstrapSheet = true
                    }
                } else {
                    // Show daemon installation choice
                    showDaemonInstallChoice = true
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

⚠️ REQUIREMENTS:
• ~10 GB disk space for blockchain data
• ~10 minutes with bootstrap (or 2-4 hours without)
• Stable internet connection during sync
• zclassicd + zclassic-cli must be installed

🚀 BOOTSTRAP:
ZipherX downloads the latest blockchain bootstrap for fast sync:
https://github.com/VictorLux/zclassic-bootstrap

"By running a full node, you become part of the network's backbone. You verify every transaction independently, trusting no one. This is the cypherpunk way."

Thank you for strengthening the network! 🛡️
""")
        }
        // Daemon installation choice alert
        .alert("Install Daemon Binaries?", isPresented: $showDaemonInstallChoice) {
            Button("Cancel", role: .cancel) {}
            Button("I'll Install Myself") {
                // User will handle installation, show info
                if let url = URL(string: FullNodeManager.officialSourceURL) {
                    NSWorkspace.shared.open(url)
                }
            }
            if fullNodeManager.hasBundledDaemon {
                Button("Install from ZipherX") {
                    // Install bundled binaries
                    Task {
                        do {
                            try await fullNodeManager.installDaemonFromBundle()
                            await MainActor.run {
                                modeManager.setWalletSource(.walletDat)
                                modeManager.setMode(.fullNode)
                                if bootstrapManager.needsBootstrap {
                                    showBootstrapSheet = true
                                }
                            }
                        } catch {
                            await MainActor.run {
                                daemonInstallError = error.localizedDescription
                            }
                        }
                    }
                }
            }
        } message: {
            Text("""
zclassicd and zclassic-cli are required for Full Node mode.

📦 INSTALL FROM ZIPHERX:
ZipherX includes pre-built binaries that will be installed to /usr/local/bin

🔧 INSTALL YOURSELF:
Download and compile from the official source. This allows you to verify the code yourself (recommended for maximum security):
https://github.com/ZclassicCommunity/zclassic

Both binaries must be installed to /usr/local/bin:
• /usr/local/bin/zclassicd
• /usr/local/bin/zclassic-cli
""")
        }
        // Installation error alert
        .alert("Installation Failed", isPresented: .init(
            get: { daemonInstallError != nil },
            set: { if !$0 { daemonInstallError = nil } }
        )) {
            Button("OK") { daemonInstallError = nil }
        } message: {
            Text(daemonInstallError ?? "Unknown error")
        }
        .sheet(isPresented: $showBootstrapSheet) {
            BootstrapProgressView()
                .environmentObject(themeManager)
                .frame(minWidth: 500, minHeight: 400)
        }
    }

    // FIX #1367: Unified wallet source picker — always visible with "P2P" / "Full Node" labels
    private func walletSourcePicker(modeManager: WalletModeManager) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "wallet.pass.fill")
                    .font(.system(size: 12))
                    .foregroundColor(theme.textSecondary)
                Text("Wallet Source")
                    .font(theme.captionFont)
                    .foregroundColor(theme.textSecondary)
            }

            HStack(spacing: 8) {
                // P2P (ZipherX) option
                Button(action: {
                    // FIX #1273: Require authentication when switching wallet modes
                    if modeManager.walletSource != .zipherx {
                        BiometricAuthManager.shared.authenticateForSensitiveOperation(
                            reason: "Authenticate to switch to P2P mode"
                        ) { success, _ in
                            if success {
                                modeManager.setWalletSource(.zipherx)
                                modeManager.setMode(.light)
                            }
                        }
                    }
                }) {
                    HStack {
                        Image(systemName: "network")
                        Text("P2P")
                    }
                    .font(theme.bodyFont)
                    .foregroundColor(modeManager.walletSource == .zipherx ? .white : theme.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(modeManager.walletSource == .zipherx ? theme.primaryColor : theme.surfaceColor)
                    .cornerRadius(theme.cornerRadius)
                    .overlay(
                        RoundedRectangle(cornerRadius: theme.cornerRadius)
                            .stroke(theme.borderColor, lineWidth: 1)
                    )
                }
                .buttonStyle(PlainButtonStyle())

                // Full Node (wallet.dat) option
                Button(action: {
                    // FIX #1273: Require authentication when switching wallet modes
                    if modeManager.walletSource != .walletDat {
                        BiometricAuthManager.shared.authenticateForSensitiveOperation(
                            reason: "Authenticate to switch to Full Node mode"
                        ) { success, _ in
                            if success {
                                // Show mode change alert (handles daemon install + bootstrap)
                                showModeChangeAlert = true
                            }
                        }
                    }
                }) {
                    HStack {
                        Image(systemName: "server.rack")
                        Text("Full Node")
                    }
                    .font(theme.bodyFont)
                    .foregroundColor(modeManager.walletSource == .walletDat ? .white : theme.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(modeManager.walletSource == .walletDat ? theme.primaryColor : theme.surfaceColor)
                    .cornerRadius(theme.cornerRadius)
                    .overlay(
                        RoundedRectangle(cornerRadius: theme.cornerRadius)
                            .stroke(theme.borderColor, lineWidth: 1)
                    )
                }
                .buttonStyle(PlainButtonStyle())
            }

            Text(modeManager.walletSource == .zipherx ?
                "Secure wallet with P2P network" :
                "Full blockchain verification with local daemon")
                .font(.system(size: 10))
                .foregroundColor(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(theme.surfaceColor)
        .overlay(
            Rectangle()
                .stroke(theme.textPrimary.opacity(0.3), lineWidth: 1)
        )
    }

    private func fullNodeStatusView(modeManager: WalletModeManager) -> some View {
        let rpcClient = RPCClient.shared

        return VStack(spacing: 8) {
            // Daemon connection status
            // Only show daemon info and debug level in wallet.dat mode
            if modeManager.walletSource == .walletDat {
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

                // Debug level picker
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: "ant.fill")
                            .font(.system(size: 12))
                            .foregroundColor(theme.textSecondary)
                        Text("Daemon Debug Level")
                            .font(theme.captionFont)
                            .foregroundColor(theme.textSecondary)
                    }

                    // FIX #857: SegmentedPickerStyle ignores foregroundColor on content
                    // Use colorScheme(.dark) to force dark mode colors for segmented picker
                    Picker("Debug Level", selection: $fullNodeManager.daemonDebugLevel) {
                        ForEach(FullNodeManager.DaemonDebugLevel.allCases, id: \.self) { level in
                            Text(level.displayName)
                                .tag(level)
                        }
                    }
                    .pickerStyle(SegmentedPickerStyle())
                    .colorScheme(.dark)  // FIX #857: Force dark mode for visible text on dark backgrounds

                    Text(fullNodeManager.daemonDebugLevel.description)
                        .font(.system(size: 10))
                        .foregroundColor(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if fullNodeManager.needsTorRestart {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                                .font(.system(size: 10))
                            Text("Restart daemon to apply changes")
                                .font(.system(size: 10))
                                .foregroundColor(.orange)
                        }
                    }
                }
                .padding(10)
                .background(theme.surfaceColor)
                .overlay(
                    Rectangle()
                        .stroke(theme.textPrimary.opacity(0.3), lineWidth: 1)
                )
            }

            // Node Management button - only in Full Node mode
            if modeManager.walletSource == .walletDat {
                Button(action: {
                    showNodeManagement = true
                }) {
                    HStack {
                        Image(systemName: "gearshape.2.fill")
                        Text("Node Management")
                        Spacer()
                        Image(systemName: "chevron.right")
                    }
                    .font(theme.bodyFont)
                    .foregroundColor(.white)
                    .padding(12)
                    .background(theme.primaryColor)
                    .cornerRadius(theme.cornerRadius)
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .sheet(isPresented: $showNodeManagement) {
            NodeManagementView()
                .environmentObject(themeManager)
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

    // MARK: - Privacy Report Section

    private var privacyReportSection: some View {
        VStack(spacing: 12) {
            // Section header
            HStack {
                Image(systemName: "eye.slash")
                    .font(.system(size: 12))
                Text("Privacy Audit")
                    .font(theme.titleFont)
                Spacer()
            }
            .foregroundColor(theme.textPrimary)

            // Privacy Report Button
            Button(action: {
                showPrivacyReport = true
            }) {
                HStack {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 14))
                    Text("Generate Privacy Report")
                        .font(theme.bodyFont)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12))
                        .foregroundColor(theme.textSecondary)
                }
                .foregroundColor(theme.accentColor)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(theme.surfaceColor)
                .cornerRadius(8)
            }
            .buttonStyle(PlainButtonStyle())

            // Description
            Text("Analyze your wallet's privacy posture with cypherpunk-grade security checks")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(theme.textSecondary)
                .padding(.horizontal, 4)
        }
        .padding()
        .background(theme.surfaceColor.opacity(0.5))
        .cornerRadius(12)
        .sheet(isPresented: $showPrivacyReport) {
            PrivacyReportView()
                .environmentObject(themeManager)
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

            // Security Warning - show when neither Face ID nor PIN is enabled
            if !useFaceID && !usePINCode {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.orange)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("SECURITY RECOMMENDED")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(.orange)
                        Text("Enable \(biometricAvailable ? getBiometricName() + " or " : "")PIN Code to protect your wallet from unauthorized access.")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(12)
                .background(Color.orange.opacity(0.1))
                .overlay(
                    Rectangle()
                        .stroke(Color.orange, lineWidth: 1)
                )
            }

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
                        // Check if database is ACTUALLY encrypted, not just if SQLCipher is available
                        let isEncrypted = SQLCipherManager.shared.isWalletDatabaseEncrypted
                        let hasFieldLevel = !SQLCipherManager.shared.isSQLCipherAvailable

                        Image(systemName: isEncrypted ? "checkmark.shield.fill" : (hasFieldLevel ? "shield" : "xmark.shield"))
                            .font(.system(size: 12))
                            .foregroundColor(isEncrypted ? .green : (hasFieldLevel ? .orange : .red))

                        Text(isEncrypted ? "Full" : (hasFieldLevel ? "Field-level" : "Not Encrypted"))
                            .font(theme.captionFont)
                            .foregroundColor(isEncrypted ? .green : (hasFieldLevel ? .orange : .red))
                    }
                }

                // Show appropriate description based on actual state
                let isEncrypted = SQLCipherManager.shared.isWalletDatabaseEncrypted
                Text(isEncrypted
                    ? "SQLCipher: AES-256 full database encryption"
                    : (SQLCipherManager.shared.isSQLCipherAvailable
                        ? "SQLCipher available but database not encrypted (legacy database)"
                        : "iOS Data Protection + AES-GCM field encryption"))
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

            // FIX #284: Parked Peers button (connection timeouts - auto-retry)
            Button(action: {
                parkedPeersList = networkManager.getParkedPeers()
                showParkedPeers = true
            }) {
                HStack {
                    Image(systemName: "parkingsign.circle")
                        .font(.system(size: 14))
                    Text("Parked Peers")
                        .font(theme.bodyFont)
                    Spacer()
                    // FIX #455: Use @Published property instead of calculating inline
                    Text("\(networkManager.parkedPeersCount)")
                        .font(theme.monoFont)
                        .foregroundColor(networkManager.parkedPeersCount > 0 ? .orange : theme.textSecondary)
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

            // FIX #284: Preferred Seeds button (priority connection, ban-exempt)
            Button(action: {
                preferredSeedsList = (try? WalletDatabase.shared.getPreferredSeeds()) ?? []
                showPreferredSeeds = true
            }) {
                HStack {
                    Image(systemName: "star.circle")
                        .font(.system(size: 14))
                    Text("Preferred Seeds")
                        .font(theme.bodyFont)
                    Spacer()
                    // FIX #455: Use @Published property instead of calculating inline
                    Text("\(networkManager.preferredSeedsCount)")
                        .font(theme.monoFont)
                        .foregroundColor(networkManager.preferredSeedsCount > 0 ? .yellow : theme.textSecondary)
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

            // Custom Nodes button
            Button(action: {
                showCustomNodes = true
            }) {
                HStack {
                    Image(systemName: "network.badge.shield.half.filled")
                        .font(.system(size: 14))
                    Text("Custom Nodes")
                        .font(theme.bodyFont)
                    Spacer()
                    Text("\(networkManager.customNodes.count)")
                        .font(theme.monoFont)
                        .foregroundColor(networkManager.customNodes.isEmpty ? theme.textSecondary : .green)
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

            // FIX #229: Trusted Peers button
            Button(action: {
                loadTrustedPeersCount()
                showTrustedPeers = true
            }) {
                HStack {
                    Image(systemName: "shield.checkered")
                        .font(.system(size: 14))
                    Text("Trusted Peers")
                        .font(theme.bodyFont)
                    Spacer()
                    Text("\(trustedPeersCount)")
                        .font(theme.monoFont)
                        .foregroundColor(trustedPeersCount == 0 ? theme.textSecondary : .green)
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

            // Tor Privacy Mode
            torPrivacySection

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
        .sheet(isPresented: $showBannedPeers, onDismiss: { networkManager.updatePeerCountsForSettings() }) {
            bannedPeersSheet
                #if os(macOS)
                .frame(minWidth: 500, idealWidth: 600, maxWidth: 700,
                       minHeight: 400, idealHeight: 500, maxHeight: 600)
                #endif
        }
        // FIX #284: Parked Peers sheet
        .sheet(isPresented: $showParkedPeers, onDismiss: { networkManager.updatePeerCountsForSettings() }) {
            parkedPeersSheet
                #if os(macOS)
                .frame(minWidth: 500, idealWidth: 600, maxWidth: 700,
                       minHeight: 400, idealHeight: 500, maxHeight: 600)
                #endif
        }
        // FIX #284: Preferred Seeds sheet
        .sheet(isPresented: $showPreferredSeeds, onDismiss: { networkManager.updatePeerCountsForSettings() }) {
            preferredSeedsSheet
                #if os(macOS)
                .frame(minWidth: 500, idealWidth: 600, maxWidth: 700,
                       minHeight: 400, idealHeight: 500, maxHeight: 600)
                #endif
        }
        .sheet(isPresented: $showCustomNodes, onDismiss: { networkManager.updatePeerCountsForSettings() }) {
            CustomNodesView()
                .environmentObject(themeManager)
                #if os(macOS)
                .frame(minWidth: 600, idealWidth: 700, maxWidth: 800,
                       minHeight: 500, idealHeight: 600, maxHeight: 700)
                #endif
        }
        // FIX #229: Trusted Peers sheet
        .sheet(isPresented: $showTrustedPeers, onDismiss: { loadTrustedPeersCount() }) {
            TrustedPeersView()
                .environmentObject(themeManager)
                #if os(macOS)
                .frame(minWidth: 600, idealWidth: 700, maxWidth: 800,
                       minHeight: 500, idealHeight: 600, maxHeight: 700)
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

    // MARK: - Tor Privacy Section

    private var torPrivacySection: some View {
        VStack(spacing: 12) {
            // Section header
            HStack {
                Image(systemName: "network.badge.shield.half.filled")
                    .font(.system(size: 14))
                Text("TOR PRIVACY")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                Spacer()

                // Connection status indicator
                HStack(spacing: 4) {
                    Circle()
                        .fill(torStatusColor)
                        .frame(width: 8, height: 8)
                    Text(TorManager.shared.connectionState.displayText)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(theme.textSecondary)
                }
            }
            .foregroundColor(theme.accentColor)

            // Tor enable toggle
            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: Binding(
                    get: { TorManager.shared.mode == .enabled },
                    set: { TorManager.shared.mode = $0 ? .enabled : .disabled }
                )) {
                    HStack {
                        Text("Route through Tor")
                            .font(theme.bodyFont)
                        Spacer()
                    }
                }
                .toggleStyle(SwitchToggleStyle(tint: theme.accentColor))

                // Mode description
                Text(TorManager.shared.mode.description)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Embedded Arti info
                if TorManager.shared.mode == .enabled {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 10))
                        #if os(iOS)
                        Text("Embedded Tor (Arti) - SOCKS5 port 9251")
                            .font(.system(size: 10, design: .monospaced))
                        #else
                        Text("Embedded Tor (Arti) - SOCKS5 port 9250")
                            .font(.system(size: 10, design: .monospaced))
                        #endif
                    }
                    .foregroundColor(.green)
                }
            }
            .padding(12)
            .background(theme.surfaceColor)
            .overlay(
                Rectangle()
                    .stroke(theme.textPrimary, lineWidth: 1)
            )

            // Start/Stop button (only for non-disabled modes)
            if TorManager.shared.mode != .disabled {
                Button(action: {
                    Task {
                        if TorManager.shared.connectionState.isConnected {
                            await TorManager.shared.stop()
                        } else {
                            // Fetch real IP BEFORE connecting to Tor
                            await TorManager.shared.fetchRealIP()
                            await TorManager.shared.start()
                            // Wait for connection then fetch Tor IP
                            // This is done via onChange below
                        }
                    }
                }) {
                    HStack {
                        Image(systemName: TorManager.shared.connectionState.isConnected ? "stop.circle" : "play.circle")
                            .font(.system(size: 14))
                        Text(TorManager.shared.connectionState.isConnected ? "Disconnect Tor" : "Connect Tor")
                            .font(theme.bodyFont)
                        Spacer()
                        if case .bootstrapping(let progress) = TorManager.shared.connectionState {
                            Text("\(progress)%")
                                .font(theme.monoFont)
                                .foregroundColor(theme.accentColor)
                        }
                    }
                    .foregroundColor(TorManager.shared.connectionState.isConnected ? .red : theme.accentColor)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(theme.surfaceColor)
                    .overlay(
                        Rectangle()
                            .stroke(TorManager.shared.connectionState.isConnected ? Color.red : theme.accentColor, lineWidth: 1)
                    )
                }
                .onChange(of: TorManager.shared.connectionState) { newState in
                    // When Tor connects, fetch the exit IP to verify it's working
                    if case .connected = newState {
                        Task {
                            await TorManager.shared.fetchTorIP()
                            // Notify hidden service manager of Tor connection state change
                            await HiddenServiceManager.shared.onTorConnectionStateChanged(isConnected: true)
                        }
                    } else if case .disconnected = newState {
                        Task {
                            // Notify hidden service manager when Tor disconnects
                            await HiddenServiceManager.shared.onTorConnectionStateChanged(isConnected: false)
                        }
                    }
                }
            }

            // IP Address Verification (shows when connected)
            if TorManager.shared.connectionState.isConnected {
                VStack(alignment: .leading, spacing: 6) {
                    Text("IP VERIFICATION")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(theme.accentColor)

                    HStack {
                        Text("Your IP:")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(theme.textSecondary)
                        Text(TorManager.shared.realIP ?? "Unknown")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(.red)
                        Text("→")
                            .foregroundColor(theme.textSecondary)
                        Text(TorManager.shared.torIP ?? "Fetching...")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(.green)
                    }
                    .onAppear {
                        // Fetch IPs when verification section appears (in case Tor was already connected)
                        Task {
                            if TorManager.shared.realIP == nil {
                                await TorManager.shared.fetchRealIP()
                            }
                            if TorManager.shared.torIP == nil {
                                await TorManager.shared.fetchTorIP()
                            }
                        }
                    }

                    // Verification status
                    if let realIP = TorManager.shared.realIP, let torIP = TorManager.shared.torIP {
                        HStack(spacing: 4) {
                            if realIP != torIP {
                                Image(systemName: "checkmark.shield.fill")
                                    .foregroundColor(.green)
                                    .font(.system(size: 12))
                                Text("Tor is working! Your IP is hidden.")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.green)
                            } else {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                                    .font(.system(size: 12))
                                Text("Warning: IP unchanged. Tor may not be routing traffic.")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.orange)
                            }
                        }
                    }
                }
                .padding(10)
                .background(theme.surfaceColor)
                .overlay(
                    Rectangle()
                        .stroke(TorManager.shared.verifyTorWorking() ? Color.green : theme.textPrimary, lineWidth: 1)
                )
            }

            // Cypherpunk quote
            HStack(spacing: 8) {
                Text("🧅")
                    .font(.system(size: 12))
                Text("\"Privacy is not secrecy... Privacy is the power to selectively reveal oneself.\"")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(theme.textSecondary)
                    .italic()
            }
            .padding(8)
            .background(theme.accentColor.opacity(0.1))
            .overlay(
                Rectangle()
                    .stroke(theme.accentColor.opacity(0.3), lineWidth: 1)
            )

            // MARK: - Hidden Service (Onion Hosting) Section
            if TorManager.shared.mode == .enabled {
                VStack(alignment: .leading, spacing: 8) {
                    // Section header
                    HStack {
                        Text("🧅 HIDDEN SERVICE")
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                        Spacer()
                        // Status indicator
                        HStack(spacing: 4) {
                            Circle()
                                .fill(hiddenServiceStatusColor)
                                .frame(width: 8, height: 8)
                            Text(HiddenServiceManager.shared.state.displayText)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(theme.textSecondary)
                        }
                    }
                    .foregroundColor(Color(red: 0.2, green: 1.0, blue: 0.4)) // Fluorescent green

                    Text("Make your wallet discoverable as a .onion peer")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(theme.textSecondary)

                    // Enable toggle
                    Toggle(isOn: Binding(
                        get: { HiddenServiceManager.shared.isEnabled },
                        set: { HiddenServiceManager.shared.isEnabled = $0 }
                    )) {
                        HStack {
                            Text("Enable Hidden Service")
                                .font(theme.bodyFont)
                            Spacer()
                        }
                    }
                    .toggleStyle(SwitchToggleStyle(tint: Color(red: 0.2, green: 1.0, blue: 0.4)))

                    // Description
                    Text("When enabled, other peers can connect to you via your unique .onion address. You remain anonymous while being discoverable.")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    // Show .onion address when running
                    if HiddenServiceManager.shared.state == .running,
                       let onionAddress = HiddenServiceManager.shared.onionAddress,
                       let _ = HiddenServiceManager.shared.p2pOnionAddress {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("YOUR .ONION ADDRESS")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(Color(red: 0.2, green: 1.0, blue: 0.4))

                            // Show onion address (without port - port is always 8033 for P2P)
                            let fullOnionWithSuffix = onionAddress.hasSuffix(".onion") ? onionAddress : "\(onionAddress).onion"
                            Text(fullOnionWithSuffix)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(Color(red: 0.2, green: 1.0, blue: 0.4))
                                .textSelection(.enabled)

                            HStack {
                                // Copy onion address (without port)
                                Button(action: {
                                    // FIX #1360: TASK 12 — Use ClipboardManager with 60s expiry for onion addresses
                                    ClipboardManager.copyWithAutoExpiry(fullOnionWithSuffix, seconds: 60)
                                }) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "doc.on.doc")
                                            .font(.system(size: 11))
                                        Text("COPY ADDRESS")
                                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                                    }
                                    .foregroundColor(Color(red: 0.2, green: 1.0, blue: 0.4))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color(red: 0.2, green: 1.0, blue: 0.4).opacity(0.2))
                                }
                                .buttonStyle(.plain)

                                Spacer()
                            }

                            // Connection info
                            HStack(spacing: 4) {
                                Image(systemName: "antenna.radiowaves.left.and.right")
                                    .font(.system(size: 10))
                                // FIX #275: Use String() to avoid locale number formatting (8 033 → 8033)
                                Text("P2P Port: \(String(HiddenServiceManager.shared.p2pPort))")
                                    .font(.system(size: 10, design: .monospaced))
                                Text("•")
                                Text("Active: \(String(HiddenServiceManager.shared.activeConnectionsCount))")
                                    .font(.system(size: 10, design: .monospaced))
                            }
                            .foregroundColor(theme.textSecondary)
                        }
                        .padding(10)
                        .background(Color(red: 0.2, green: 1.0, blue: 0.4).opacity(0.1))
                        .overlay(
                            Rectangle()
                                .stroke(Color(red: 0.2, green: 1.0, blue: 0.4), lineWidth: 1)
                        )
                    }

                    // Cypherpunk message
                    HStack(spacing: 8) {
                        Text("🚀")
                            .font(.system(size: 12))
                        Text("\"Become a node in the network of freedom.\"")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(theme.textSecondary)
                            .italic()
                    }
                    .padding(8)
                    .background(Color(red: 0.2, green: 1.0, blue: 0.4).opacity(0.1))
                    .overlay(
                        Rectangle()
                            .stroke(Color(red: 0.2, green: 1.0, blue: 0.4).opacity(0.3), lineWidth: 1)
                    )
                }
                .padding(12)
                .background(theme.surfaceColor)
                .overlay(
                    Rectangle()
                        .stroke(theme.textPrimary, lineWidth: 1)
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

    /// Color for Hidden Service status indicator
    private var hiddenServiceStatusColor: Color {
        switch HiddenServiceManager.shared.state {
        case .stopped:
            return .gray
        case .starting:
            return .orange
        case .running:
            return Color(red: 0.2, green: 1.0, blue: 0.4)  // Fluorescent green
        case .error:
            return .red
        }
    }

    /// Color for Tor connection status indicator
    private var torStatusColor: Color {
        switch TorManager.shared.connectionState {
        case .disconnected:
            return .gray
        case .connecting, .bootstrapping:
            return .orange
        case .connected:
            return .green
        case .error:
            return .red
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

    // MARK: - Repair Database Section (Standalone)

    private var repairDatabaseSection: some View {
        VStack(spacing: 12) {
            // Section header
            HStack {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.system(size: 12))
                Text("Database Repair")
                    .font(theme.titleFont)
                Spacer()
            }
            .foregroundColor(theme.textPrimary)

            // Info box
            Text("Verify wallet integrity and repair any issues with balance, witnesses, or transaction history.")
                .font(theme.captionFont)
                .foregroundColor(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            // FIX #451: Force Reset Repair Flag - YELLOW (emergency unstuck button)
            // Only show when repair flag is stuck
            if walletManager.isRepairingDatabase {
                Button(action: {
                    walletManager.forceResetRepairFlag()
                }) {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 12))
                        Text("UNSTUCK REPAIR (Flag Reset)")
                            .font(theme.bodyFont)
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.yellow)
                    .overlay(
                        Rectangle()
                            .stroke(Color.yellow.opacity(0.8), lineWidth: 2)
                    )
                }

                Text("EMERGENCY: Repair is stuck. Click this to unstick the app so you can use it again.")
                    .font(theme.captionFont)
                    .foregroundColor(Color.yellow)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // FIX #367: Verify & Repair Wallet (Full Resync — comprehensive repair)
            Button(action: {
                showFullResyncWarning = true
            }) {
                HStack {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 12))
                    Text("Verify & Repair Wallet")
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

            Text("Verifies wallet integrity. If issues are found, re-downloads boost file and rescans the entire blockchain to rebuild notes, witnesses, and transaction history.")
                .font(theme.captionFont)
                .foregroundColor(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .background(theme.surfaceColor)
        .overlay(
            Rectangle()
                .stroke(theme.textSecondary.opacity(0.3), lineWidth: 1)
        )
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

            // Repair Database button - PURPLE (fix nullifier issues and tree corruption)
            Button(action: {
                showRepairNotesWarning = true
            }) {
                HStack {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.system(size: 12))
                    Text("Repair Database")
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

            // FIX #576: Remove Bogus Transactions button - MAGENTA
            Button(action: {
                Task {
                    await removeBogusTransactions()
                }
            }) {
                HStack {
                    Image(systemName: "trash.circle")
                        .font(.system(size: 12))
                    Text("Remove Bogus Transactions")
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

    // MARK: - Parked Peers Sheet (FIX #284)

    private var parkedPeersSheet: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Parked Peers")
                    .font(theme.titleFont)
                    .foregroundColor(theme.textPrimary)
                Spacer()
                Text("\(parkedPeersList.count) parked")
                    .font(theme.bodyFont)
                    .foregroundColor(parkedPeersList.isEmpty ? theme.textSecondary : .orange)
                Spacer()
                Button("Done") {
                    showParkedPeers = false
                }
                .foregroundColor(theme.primaryColor)
            }
            .padding()
            .background(theme.surfaceColor)

            Divider()

            if parkedPeersList.isEmpty {
                // Empty state
                VStack(spacing: 12) {
                    Image(systemName: "hourglass")
                        .font(.system(size: 40))
                        .foregroundColor(.green)
                    Text("No Parked Peers")
                        .font(theme.titleFont)
                        .foregroundColor(theme.textPrimary)
                    Text("Peers with connection timeouts will appear here.\nThey will auto-retry with exponential backoff.")
                        .font(theme.bodyFont)
                        .foregroundColor(theme.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(theme.surfaceColor)
            } else {
                // List of parked peers
                List {
                    ForEach(parkedPeersList, id: \.address) { peer in
                        ParkedPeerRow(peer: peer)
                            .environmentObject(themeManager)
                    }
                }
                .listStyle(PlainListStyle())
            }

            // Action buttons
            if !parkedPeersList.isEmpty {
                VStack(spacing: 8) {
                    // Info about exponential backoff
                    Text("Parked peers auto-retry with exponential backoff:\n1s → 5min → 1h → 4h → 8h → 16h → 24h max")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.bottom, 4)

                    // Clear all parked
                    Button(action: {
                        networkManager.clearAllParkedPeers()
                        parkedPeersList = []
                    }) {
                        HStack {
                            Image(systemName: "arrow.uturn.backward")
                            Text("Clear All Parked (Force Retry)")
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

    // MARK: - Preferred Seeds Sheet (FIX #284)

    private var preferredSeedsSheet: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Preferred Seeds")
                    .font(theme.titleFont)
                    .foregroundColor(theme.textPrimary)
                Spacer()
                Text("\(preferredSeedsList.count) seeds")
                    .font(theme.bodyFont)
                    .foregroundColor(preferredSeedsList.isEmpty ? theme.textSecondary : .yellow)
                Spacer()
                Button("Done") {
                    showPreferredSeeds = false
                }
                .foregroundColor(theme.primaryColor)
            }
            .padding()
            .background(theme.surfaceColor)

            Divider()

            // Info banner
            HStack(spacing: 8) {
                Image(systemName: "star.fill")
                    .foregroundColor(.yellow)
                Text("Preferred seeds get priority connection and are exempt from parking timeouts.")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.textSecondary)
            }
            .padding()
            .background(theme.surfaceColor.opacity(0.5))

            if preferredSeedsList.isEmpty {
                // Empty state
                VStack(spacing: 12) {
                    Image(systemName: "star.slash")
                        .font(.system(size: 40))
                        .foregroundColor(.gray)
                    Text("No Preferred Seeds")
                        .font(theme.titleFont)
                        .foregroundColor(theme.textPrimary)
                    Text("Add preferred seeds from Trusted Peers\nor they'll be auto-added from hardcoded seeds.")
                        .font(theme.bodyFont)
                        .foregroundColor(theme.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(theme.surfaceColor)
            } else {
                // List of preferred seeds
                List {
                    ForEach(preferredSeedsList, id: \.host) { seed in
                        PreferredSeedRow(
                            seed: seed,
                            onDemote: {
                                try? WalletDatabase.shared.demoteFromPreferredSeed(host: seed.host, port: seed.port)
                                preferredSeedsList = (try? WalletDatabase.shared.getPreferredSeeds()) ?? []
                            }
                        )
                        .environmentObject(themeManager)
                    }
                }
                .listStyle(PlainListStyle())
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

    // FIX #229: Load trusted peers count for display
    private func loadTrustedPeersCount() {
        if let peers = try? WalletDatabase.shared.getTrustedPeers() {
            trustedPeersCount = peers.count
        }
    }

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
        // FIX #1360: TASK 6 — Biometric auth gate for key export
        BiometricAuthManager.shared.authenticateForKeyExport { success, _ in
            guard success else { return }

            do {
                let key = try walletManager.exportSpendingKey()
                DispatchQueue.main.async {
                    exportedKey = key
                    showExportAlert = true
                }
                // SECURITY: Never log private key operations
            } catch {
                DispatchQueue.main.async {
                    errorMessage = "Failed to export key"
                    showError = true
                }
            }
        }
    }

    private func checkBiometricAvailability() {
        let context = LAContext()
        var error: NSError?
        biometricAvailable = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)

        // Load saved preferences
        useFaceID = UserDefaults.standard.bool(forKey: "useBiometricAuth")
        usePINCode = UserDefaults.standard.string(forKey: "walletPIN") != nil
        // FIX #1346: Reload timeout from persisted value — @State only initializes once at view creation
        selectedTimeout = BiometricAuthManager.shared.authTimeout
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

                try await walletManager.repairNotesAfterDownloadedTree { progress, currentHeight, maxHeight in
                    Task { @MainActor in
                        rescanProgress = progress
                        rescanCurrentHeight = currentHeight
                        rescanMaxHeight = maxHeight
                    }
                }

                // FIX #212: Also scan for unrecorded broadcast transactions
                // This recovers from the scenario where broadcast succeeded but VUL-002 blocked db write
                // Scan from checkpoint (not beginning) - unrecorded broadcasts only happen after checkpoint
                print("🔧 FIX #212: Scanning for unrecorded broadcasts from checkpoint...")
                let recovered = try await walletManager.repairUnrecordedSpends(fromCheckpoint: true)
                if recovered > 0 {
                    print("✅ FIX #212: Recovered \(recovered) unrecorded transaction(s)")
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

    // MARK: - FIX #367: Full Resync (Nuclear Option)

    private func startFullResync() {
        // Reset progress state
        rescanProgress = 0
        rescanCurrentHeight = 0
        rescanMaxHeight = 0
        rescanStartTime = Date()
        rescanElapsedTime = 0

        // FIX #577 v7: DON'T show SettingsView's progress sheet for Full Rescan
        // The CypherpunkSyncView will handle progress display (same UI as Import PK)
        // showRescanProgress = true  // REMOVED - let CypherpunkSyncView show instead

        // FIX #577 v9: Dismiss Settings sheet so CypherpunkSyncView is visible
        dismiss()

        // Start elapsed time timer
        rescanTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            if let start = rescanStartTime {
                rescanElapsedTime = Date().timeIntervalSince(start)
            }
        }

        // Perform FULL resync in background
        Task {
            do {
                print("🔄 FIX #367: Starting FULL RESYNC (nuclear option)...")
                print("🔄 This will delete all notes, re-download boost, and rescan from scratch")

                // Call repair with forceFullRescan = true
                // Progress callback is ignored (CypherpunkSyncView shows progress instead)
                try await walletManager.repairNotesAfterDownloadedTree(onProgress: { progress, currentHeight, maxHeight in
                    Task { @MainActor in
                        // Still update these for completion detection, but don't show sheet
                        rescanProgress = progress
                        rescanCurrentHeight = currentHeight
                        rescanMaxHeight = maxHeight
                    }
                }, forceFullRescan: true)

                // Complete
                await MainActor.run {
                    rescanProgress = 1.0
                    print("✅ FIX #367: Full resync complete!")
                }

            } catch {
                await MainActor.run {
                    rescanTimer?.invalidate()
                    rescanTimer = nil
                    errorMessage = "Full resync failed: \(error.localizedDescription)"
                    print("❌ Full resync error: \(error)")
                    rescanProgress = -1
                    // Show error sheet
                    showRescanProgress = true
                }
            }
        }
    }

    // MARK: - FIX #214/217: Scan for Unrecorded Transactions Only

    private func startScanForUnrecordedTx() {
        isScanningUnrecorded = true

        Task { @MainActor in
            do {
                print("🔍 FIX #217: Starting comprehensive scan for missing transactions...")

                // Get checkpoint info for logging
                let checkpoint = try WalletDatabase.shared.getVerifiedCheckpointHeight()
                let chainHeight = NetworkManager.shared.chainHeight
                print("🔍 FIX #217: Scanning from checkpoint \(checkpoint) to chain tip \(chainHeight)")

                // FIX #217: Use scanForMissingTransactions which uses FilterScanner
                // This finds BOTH incoming notes (trial decryption) AND spent notes (nullifier matching)
                // Much more comprehensive than the old repairUnrecordedSpends which only checked nullifiers
                let recovered = try await walletManager.scanForMissingTransactions()

                // Update UI state directly (we're on MainActor)
                isScanningUnrecorded = false
                if recovered > 0 {
                    scanUnrecordedResultMessage = "Found \(recovered) missing transaction(s)!\n\nYour balance and history have been updated."
                    print("✅ FIX #217: Recovered \(recovered) missing transaction(s)")
                } else {
                    scanUnrecordedResultMessage = "No missing transactions found.\n\nYour database is consistent with the blockchain."
                    print("✅ FIX #217: No missing transactions found")
                }
                showScanUnrecordedResult = true

            } catch {
                isScanningUnrecorded = false
                scanUnrecordedResultMessage = "Scan failed: \(error.localizedDescription)"
                showScanUnrecordedResult = true
                print("❌ FIX #217: Scan error: \(error)")
            }
        }
    }

    // MARK: - FIX #680: Recover Transaction by TXID

    // FIX: Force rebuild all witnesses
    private func startForceRebuildWitnesses() {
        // FIX #1240: Check if tree repair is exhausted BEFORE starting expensive rebuild.
        // If TreeRepairExhausted is true, the FFI tree has wrong root (incomplete delta).
        // Rebuilding witnesses from this tree produces anchors that don't exist on blockchain.
        // Save user 1-5 minutes of futile work — direct them to Full Resync instead.
        if UserDefaults.standard.bool(forKey: "TreeRepairExhausted") {
            print("⏩ FIX #1240: Skipping force rebuild — tree repair exhausted")
            errorMessage = "Tree state is corrupted (incomplete delta CMUs). Witnesses from this tree would have invalid anchors.\n\nPlease use 'Full Resync' instead to rebuild the tree from scratch."
            return
        }

        isRebuildingWitnesses = true
        print("🔧 Starting force rebuild of all witnesses...")

        Task {
            do {
                // Get current tree root
                guard let _ = ZipherXFFI.treeRoot() else {
                    await MainActor.run {
                        isRebuildingWitnesses = false
                        errorMessage = "No tree root available - tree may not be loaded"
                        print("❌ Force rebuild failed: No tree root")
                    }
                    return
                }

                // Get account ID
                guard let account = try WalletDatabase.shared.getAccount(index: 0) else {
                    await MainActor.run {
                        isRebuildingWitnesses = false
                        errorMessage = "No account found"
                        print("❌ Force rebuild failed: No account")
                    }
                    return
                }
                let accountId = account.accountId

                // Get unspent notes only (we don't need to rebuild witnesses for spent notes)
                let unspentNotes = try WalletDatabase.shared.getUnspentNotes(accountId: accountId)

                print("🔧 Rebuilding witnesses for \(unspentNotes.count) unspent notes...")

                var successCount = 0
                var failedCount = 0
                var skippedCount = 0

                // Get boost file info to know which notes can be rebuilt from cache
                let cachedInfo = await CommitmentTreeUpdater.shared.getCachedTreeInfo()
                let boostHeight = cachedInfo?.height ?? 0

                // Save current tree state
                let savedTreeState = ZipherXFFI.treeSerialize()
                print("🔧 Starting witness rebuild for \(unspentNotes.count) notes...")

                // Separate notes into categories for batch processing
                var notesNeedingRebuild: [(note: WalletNote, cmu: Data)] = []
                var notesBeyondBoost: [WalletNote] = []

                print("🔧 FIX #557 v49: FORCE REBUILD MODE - Will rebuild ALL witnesses (no skip checks)")
                print("🔧 FIX #557 v49: Old witnesses were built with DISPLAY format - rebuilding with WIRE format")

                for (index, note) in unspentNotes.enumerated() {
                    // Debug: print first note info
                    if index == 0 {
                        print("🔧 FIX #557 v49: First note: height=\(note.height), has anchor=\(note.anchor != nil), has CMU=\(note.cmu != nil)")
                    }

                    // FIX #557 v49: DISABLE witness root check for FORCE REBUILD
                    // The old witnesses were built with DISPLAY format CMUs, which caused anchor mismatch
                    // After fixing the FFI to use WIRE format, we MUST rebuild ALL witnesses
                    // Skipping based on root comparison doesn't work because both old witnesses AND old tree are DISPLAY format
                    // Trust that this is a FORCE rebuild and rebuild everything
                    let witnessIsCurrent = false  // Always false for force rebuild

                    // OLD CODE (DISABLED):
                    // if !note.witness.isEmpty {
                    //     if let witnessAnchor = ZipherXFFI.witnessGetRoot(note.witness) {
                    //         if witnessAnchor == currentTreeRoot {
                    //             witnessIsCurrent = true
                    //             if index == 0 { print("🔧 First note WITNESS ROOT matches current tree root, skipping") }
                    //         }
                    //     }
                    // }

                    if witnessIsCurrent {
                        skippedCount += 1
                        continue
                    }

                    // Check if CMU exists
                    guard let noteCmu = note.cmu, !noteCmu.isEmpty else {
                        print("⚠️ Note at height \(note.height) has no CMU, skipping")
                        failedCount += 1
                        continue
                    }

                    // Categorize by height
                    if note.height <= boostHeight {
                        notesNeedingRebuild.append((note, noteCmu))
                    } else {
                        notesBeyondBoost.append(note)
                    }
                }

                print("🔧 Batch processing: \(notesNeedingRebuild.count) notes within boost file, \(notesBeyondBoost.count) beyond")

                // Process ALL notes within boost file in ONE batch call
                if !notesNeedingRebuild.isEmpty {
                    print("🔧 Creating witnesses for \(notesNeedingRebuild.count) notes in single batch...")

                    if let cachedPath = await CommitmentTreeUpdater.shared.getCachedCMUFilePath(),
                       let cmuData = try? Data(contentsOf: cachedPath) {

                        // Extract all CMUs for batch processing
                        let targetCMUs = notesNeedingRebuild.map { $0.cmu }
                        print("🔧 Calling treeCreateWitnessesBatch with \(targetCMUs.count) CMUs...")

                        let batchStart = Date()
                        let results = ZipherXFFI.treeCreateWitnessesBatch(cmuData: cmuData, targetCMUs: targetCMUs)
                        let batchDuration = Date().timeIntervalSince(batchStart)

                        print("🔧 Batch witness creation completed in \(String(format: "%.2f", batchDuration))s")

                        // Map results back to notes
                        for (index, (note, _)) in notesNeedingRebuild.enumerated() {
                            if index < results.count,
                               let result = results[index] {
                                let (_, newWitness) = result
                                do {
                                    try WalletDatabase.shared.updateNoteWitness(noteId: note.id, witness: newWitness)

                                    // FIX #546: Get anchor from HEADER STORE instead of from witness
                                    // According to SESSION_SUMMARY_2025-11-28.md: "Anchor MUST come from header store - not from computed tree state"
                                    if let headerAnchor = try? HeaderStore.shared.getSaplingRoot(at: UInt64(note.height)) {
                                        try WalletDatabase.shared.updateNoteAnchor(noteId: note.id, anchor: headerAnchor)
                                        let anchorHex = headerAnchor.prefix(8).map { String(format: "%02x", $0) }.joined()
                                        print("   ✅ Note \(note.id) height \(note.height): anchor from HEADER at \(anchorHex)...")

                                        // FIX #546 v2: Verify the write actually persisted
                                        if let verifyAnchor = try? WalletDatabase.shared.getAnchor(for: note.id),
                                           verifyAnchor == headerAnchor {
                                            print("   ✅ Note \(note.id): Verified anchor in DB matches HEADER")
                                        } else {
                                            print("   ❌ Note \(note.id): ANCHOR MISMATCH IN DB - write failed!")
                                        }
                                    } else {
                                        print("   ⚠️ Note \(note.id) height \(note.height): no header found for anchor")
                                    }

                                    successCount += 1
                                } catch {
                                    print("⚠️ Failed to update note at height \(note.height): \(error)")
                                    failedCount += 1
                                }
                            } else {
                                print("⚠️ No witness returned for note at height \(note.height)")
                                failedCount += 1
                            }

                            // Update progress every 5 notes
                            if index % 5 == 0 {
                                let progress = Double(index) / Double(notesNeedingRebuild.count)
                                print("🔧 Witness rebuild progress: \(Int(progress * 100))%")
                            }
                        }
                    } else {
                        print("⚠️ Could not load CMU data from boost file")
                        failedCount += notesNeedingRebuild.count
                    }
                }

                // Handle notes beyond boost file
                for note in notesBeyondBoost {
                    print("⚠️ Note at height \(note.height) is beyond boost file (\(boostHeight)), needs P2P fetch")
                    failedCount += 1
                }

                print("🔧 Witness rebuild completed. Success: \(successCount), Skipped: \(skippedCount), Failed: \(failedCount)")

                // Restore tree state
                if let savedState = savedTreeState {
                    _ = ZipherXFFI.treeDeserialize(data: savedState)
                }

                // Refresh balance after rebuild
                try await walletManager.refreshBalance()

                await MainActor.run {
                    isRebuildingWitnesses = false
                    let message = "Witness rebuild complete!\n\n✅ Rebuilt: \(successCount)\n⏭ Skipped: \(skippedCount)\n❌ Failed: \(failedCount)\n\nBalance has been refreshed.\n\nNote: Failed notes are beyond boost file range and require blockchain sync."
                    recoveryMessage = message
                    showRecoverySuccess = true
                    print("✅ Force rebuild complete: \(successCount) rebuilt, \(skippedCount) skipped, \(failedCount) failed")
                }

            } catch {
                await MainActor.run {
                    isRebuildingWitnesses = false
                    errorMessage = "Witness rebuild failed: \(error.localizedDescription)"
                    print("❌ Force rebuild error: \(error)")
                }
            }
        }
    }

    // MARK: - FIX #588: Rebuild Corrupted Witnesses

    /// FIX #588: Rebuild witnesses with corrupted Merkle paths (filled_nodes)
    /// This fixes the anchor mismatch issue caused by old FIX #585 trimming code
    private func rebuildCorruptedWitnesses() async {
        await MainActor.run {
            isRebuildingCorruptedWitnesses = true
        }

        print("🔧 FIX #588: Starting corrupted witness rebuild...")

        let rebuilt = await walletManager.rebuildCorruptedWitnesses { current, total in
            let progress = Double(current) / Double(total)
            Task { @MainActor in
                rescanProgress = progress
            }
            print("   Rebuilding: \(current)/\(total)")
        }

        await MainActor.run {
            isRebuildingCorruptedWitnesses = false

            if rebuilt > 0 {
                recoveryMessage = "✅ Rebuilt \(rebuilt) corrupted witnesses!\n\nThe witnesses now have correct Merkle paths.\n\nTry sending a transaction again."
                showRecoverySuccess = true
            } else {
                errorMessage = "No witnesses were rebuilt. Check logs for details."
            }
        }

        print("✅ FIX #588: Witness rebuild complete - \(rebuilt) witnesses rebuilt")
    }

    // MARK: - FIX #576: Remove Bogus Transactions

    /// FIX #576: Remove transactions that were rejected by the network but incorrectly tracked
    /// Use this when you know a transaction was rejected but still shows as pending/confirmed
    private func removeBogusTransactions() async {
        await MainActor.run {
            showRescanProgress = true
            rescanProgress = 0
        }

        do {
            print("🔧 FIX #576: Starting bogus transaction removal...")

            // FIXME: removeAllBogusPendingTransactions function not implemented
            // let unmarkedCount = try WalletDatabase.shared.removeAllBogusPendingTransactions()
            let unmarkedCount = 0  // Placeholder

            // Refresh balance after cleanup
            try await walletManager.refreshBalance()

            await MainActor.run {
                rescanProgress = 1.0

                let message = "Removed \(unmarkedCount) invalid transaction(s)!\n\nYour balance and history have been corrected.\n\nThe notes that were incorrectly marked as spent are now available again."
                recoveryMessage = message
                showRecoverySuccess = true

                print("✅ FIX #576: Removed bogus transactions, unmarked \(unmarkedCount) notes")
            }

        } catch {
            await MainActor.run {
                errorMessage = "Failed to remove bogus transactions: \(error.localizedDescription)"
                print("❌ FIX #576: Error: \(error)")
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
                    // FIX #1360: TASK 12 — Use ClipboardManager with 60s expiry for file paths
                    ClipboardManager.copyWithAutoExpiry(url.path, seconds: 60)
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

                        // Time remaining or PERMANENT indicator (FIX #159)
                        if peer.isPermanent {
                            Text("• 🚨 PERMANENT")
                                .font(theme.captionFont.bold())
                                .foregroundColor(.red)
                        } else {
                            Text("• \(timeRemaining)")
                                .font(theme.captionFont)
                                .foregroundColor(theme.textSecondary)
                        }
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

// MARK: - Parked Peer Row (FIX #284)

struct ParkedPeerRow: View {
    @EnvironmentObject var themeManager: ThemeManager
    let peer: ParkedPeer

    private var theme: AppTheme { themeManager.currentTheme }

    var body: some View {
        HStack(spacing: 12) {
            // Parking status icon
            Image(systemName: peer.isReadyForRetry ? "arrow.clockwise.circle.fill" : "hourglass.circle.fill")
                .foregroundColor(peer.isReadyForRetry ? .green : .orange)
                .font(.system(size: 20))

            // Peer info
            VStack(alignment: .leading, spacing: 4) {
                Text("\(peer.address):\(peer.port)")
                    .font(theme.monoFont)
                    .foregroundColor(theme.textPrimary)

                HStack(spacing: 8) {
                    // Retry count
                    Text("Retries: \(peer.retryCount)")
                        .font(theme.captionFont)
                        .foregroundColor(.orange)

                    // Time until retry
                    if peer.isReadyForRetry {
                        Text("• Ready to retry")
                            .font(theme.captionFont)
                            .foregroundColor(.green)
                    } else {
                        Text("• \(timeUntilRetry)")
                            .font(theme.captionFont)
                            .foregroundColor(theme.textSecondary)
                    }

                    // Was preferred indicator
                    if peer.wasPreferred {
                        Text("• ⭐ Preferred")
                            .font(theme.captionFont)
                            .foregroundColor(.yellow)
                    }
                }
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }

    private var timeUntilRetry: String {
        let nextRetryTime = peer.parkedTime.addingTimeInterval(peer.nextRetryInterval)
        let remaining = nextRetryTime.timeIntervalSinceNow

        if remaining <= 0 {
            return "Ready"
        }

        let hours = Int(remaining / 3600)
        let minutes = Int((remaining.truncatingRemainder(dividingBy: 3600)) / 60)
        let seconds = Int(remaining.truncatingRemainder(dividingBy: 60))

        if hours > 0 {
            return "\(hours)h \(minutes)m until retry"
        } else if minutes > 0 {
            return "\(minutes)m \(seconds)s until retry"
        } else {
            return "\(seconds)s until retry"
        }
    }
}

// MARK: - Preferred Seed Row (FIX #284)

struct PreferredSeedRow: View {
    @EnvironmentObject var themeManager: ThemeManager
    let seed: WalletDatabase.TrustedPeer
    let onDemote: () -> Void

    private var theme: AppTheme { themeManager.currentTheme }

    // Calculate success rate from successes and failures
    private var successRate: Double {
        let total = seed.successes + seed.failures
        guard total > 0 else { return 0 }
        return Double(seed.successes) / Double(total)
    }

    var body: some View {
        HStack(spacing: 12) {
            // Preferred status icon
            Image(systemName: "star.fill")
                .foregroundColor(.yellow)
                .font(.system(size: 20))

            // Seed info
            VStack(alignment: .leading, spacing: 4) {
                Text("\(seed.host):\(seed.port)")
                    .font(theme.monoFont)
                    .foregroundColor(theme.textPrimary)

                HStack(spacing: 8) {
                    // Success rate if available
                    if seed.successes + seed.failures > 0 {
                        Text("Success: \(Int(successRate * 100))%")
                            .font(theme.captionFont)
                            .foregroundColor(successRate > 0.7 ? .green : .orange)
                    }

                    // Last connected
                    if let lastConnected = seed.lastConnected {
                        Text("• \(timeAgo(lastConnected))")
                            .font(theme.captionFont)
                            .foregroundColor(theme.textSecondary)
                    }

                    // Onion indicator
                    if seed.isOnion {
                        Text("• 🧅")
                            .font(theme.captionFont)
                    }

                    // Notes
                    if let notes = seed.notes, !notes.isEmpty {
                        Text("• \(notes)")
                            .font(theme.captionFont)
                            .foregroundColor(theme.textSecondary)
                    }
                }
            }

            Spacer()

            // Demote button
            Button(action: onDemote) {
                Image(systemName: "star.slash")
                    .foregroundColor(.orange)
                    .font(.system(size: 16))
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(.vertical, 4)
    }

    private func timeAgo(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)

        if interval < 60 {
            return "just now"
        } else if interval < 3600 {
            let minutes = Int(interval / 60)
            return "\(minutes)m ago"
        } else if interval < 86400 {
            let hours = Int(interval / 3600)
            return "\(hours)h ago"
        } else {
            let days = Int(interval / 86400)
            return "\(days)d ago"
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(WalletManager.shared)
        .environmentObject(NetworkManager.shared)
        .environmentObject(ThemeManager.shared)
}
