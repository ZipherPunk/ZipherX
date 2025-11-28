import SwiftUI
import LocalAuthentication

/// Settings View - Export keys, PIN code, Face ID setup
/// Classic Macintosh System 7 design
struct SettingsView: View {
    @EnvironmentObject var walletManager: WalletManager
    @State private var showExportAlert = false
    @State private var exportedKey = ""
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var useFaceID = false
    @State private var usePINCode = false
    @State private var showPINSetup = false
    @State private var pinCode = ""
    @State private var confirmPIN = ""
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
    @State private var showHistory = false
    @State private var showRebuildWitnessesWarning = false
    @State private var showRecoverySuccess = false
    @State private var recoveryMessage = ""
    @State private var useP2POnly = UserDefaults.standard.bool(forKey: "useP2POnly")
    @State private var debugLoggingEnabled = DebugLogger.shared.isEnabled
    @State private var showDebugLogShare = false
    @State private var debugLogSize: String = "0 KB"

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // History section
                historySection

                // Security section
                securitySection

                // Network section
                networkSection

                // Export section
                exportSection

                // Debug section
                debugLoggingSection

                /* DISABLED: Blockchain data section
                // Rescan section
                rescanSection
                */

                /* DISABLED: Debug tools section
                // Debug section (for testing header sync)
                debugSection
                */

                Spacer()
            }
            .padding()
        }
        .onAppear {
            checkBiometricAvailability()
        }
        .alert("Export Private Key", isPresented: $showExportAlert) {
            Button("Copy to Clipboard") {
                UIPasteboard.general.string = exportedKey
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
        }
        .alert("Quick Scan for Notes", isPresented: $showQuickScan) {
            TextField("Start Height", text: $quickScanHeight)
                .keyboardType(.numberPad)
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
                .keyboardType(.numberPad)
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
        .sheet(isPresented: $showHistory) {
            HistoryView()
        }
    }

    // MARK: - History Section

    private var historySection: some View {
        VStack(spacing: 12) {
            // Section header
            HStack {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 12))
                Text("Transaction History")
                    .font(System7Theme.titleFont(size: 12))
                Spacer()
            }
            .foregroundColor(System7Theme.black)

            // History button
            Button(action: {
                showHistory = true
            }) {
                HStack {
                    Image(systemName: "list.bullet.rectangle")
                        .font(.system(size: 12))
                    Text("View History")
                        .font(System7Theme.titleFont(size: 11))
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
        }
        .padding(12)
        .background(System7Theme.lightGray)
        .overlay(
            Rectangle()
                .stroke(System7Theme.black, lineWidth: 1)
        )
    }

    // MARK: - Security Section

    private var securitySection: some View {
        VStack(spacing: 12) {
            // Section header
            HStack {
                Image(systemName: "lock.shield")
                    .font(.system(size: 12))
                Text("Security")
                    .font(System7Theme.titleFont(size: 12))
                Spacer()
            }
            .foregroundColor(System7Theme.black)

            // Face ID / Touch ID toggle
            if biometricAvailable {
                HStack {
                    Image(systemName: getBiometricIcon())
                        .font(.system(size: 14))
                        .foregroundColor(System7Theme.black)

                    Text(getBiometricName())
                        .font(System7Theme.bodyFont(size: 11))
                        .foregroundColor(System7Theme.black)

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
                .background(System7Theme.white)
                .overlay(
                    Rectangle()
                        .stroke(System7Theme.black, lineWidth: 1)
                )
            }

            // PIN Code toggle
            HStack {
                Image(systemName: "number.square")
                    .font(.system(size: 14))
                    .foregroundColor(System7Theme.black)

                Text("PIN Code")
                    .font(System7Theme.bodyFont(size: 11))
                    .foregroundColor(System7Theme.black)

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
            .background(System7Theme.white)
            .overlay(
                Rectangle()
                    .stroke(System7Theme.black, lineWidth: 1)
            )
        }
        .padding(12)
        .background(System7Theme.lightGray)
        .overlay(
            Rectangle()
                .stroke(System7Theme.black, lineWidth: 1)
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
                    .font(System7Theme.titleFont(size: 12))
                Spacer()
            }
            .foregroundColor(System7Theme.black)

            // P2P Only toggle
            HStack {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 14))
                    .foregroundColor(System7Theme.black)

                VStack(alignment: .leading, spacing: 2) {
                    Text("P2P Only Mode")
                        .font(System7Theme.bodyFont(size: 11))
                        .foregroundColor(System7Theme.black)
                    Text("No centralized API fallback")
                        .font(System7Theme.bodyFont(size: 9))
                        .foregroundColor(System7Theme.darkGray)
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
            .background(System7Theme.white)
            .overlay(
                Rectangle()
                    .stroke(System7Theme.black, lineWidth: 1)
            )

            // Info text
            HStack(spacing: 8) {
                Image(systemName: useP2POnly ? "checkmark.shield.fill" : "info.circle")
                    .foregroundColor(useP2POnly ? .green : .blue)
                    .font(.system(size: 12))

                Text(useP2POnly ?
                    "Maximum security: All data verified via decentralized P2P network with multi-peer consensus." :
                    "P2P first with InsightAPI fallback. Enable P2P-only for trustless operation.")
                    .font(System7Theme.bodyFont(size: 9))
                    .foregroundColor(System7Theme.darkGray)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
            .background(useP2POnly ? Color.green.opacity(0.1) : System7Theme.white)
            .overlay(
                Rectangle()
                    .stroke(useP2POnly ? Color.green.opacity(0.5) : System7Theme.black.opacity(0.3), lineWidth: 1)
            )
        }
        .padding(12)
        .background(System7Theme.lightGray)
        .overlay(
            Rectangle()
                .stroke(System7Theme.black, lineWidth: 1)
        )
    }

    // MARK: - Export Section

    private var exportSection: some View {
        VStack(spacing: 12) {
            // Section header
            HStack {
                Image(systemName: "key")
                    .font(.system(size: 12))
                Text("Backup")
                    .font(System7Theme.titleFont(size: 12))
                Spacer()
            }
            .foregroundColor(System7Theme.black)

            // Warning
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .font(.system(size: 12))

                Text("Never share your private key. Store it securely offline.")
                    .font(System7Theme.bodyFont(size: 9))
                    .foregroundColor(System7Theme.darkGray)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
            .background(System7Theme.white)
            .overlay(
                Rectangle()
                    .stroke(Color.orange.opacity(0.5), lineWidth: 1)
            )

            // Export button
            System7Button(title: "Export Private Key") {
                exportPrivateKey()
            }
        }
        .padding(12)
        .background(System7Theme.lightGray)
        .overlay(
            Rectangle()
                .stroke(System7Theme.black, lineWidth: 1)
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
                    .font(System7Theme.titleFont(size: 12))
                Spacer()
            }
            .foregroundColor(System7Theme.black)

            // Debug toggle
            HStack {
                Image(systemName: "doc.text")
                    .font(.system(size: 14))
                    .foregroundColor(System7Theme.black)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Enable Debug Log")
                        .font(System7Theme.bodyFont(size: 11))
                        .foregroundColor(System7Theme.black)
                    Text("Log size: \(debugLogSize)")
                        .font(System7Theme.bodyFont(size: 9))
                        .foregroundColor(System7Theme.darkGray)
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
            .background(System7Theme.white)
            .overlay(
                Rectangle()
                    .stroke(System7Theme.black, lineWidth: 1)
            )

            // Export and Clear buttons
            HStack(spacing: 12) {
                // Export button
                Button(action: {
                    showDebugLogShare = true
                }) {
                    HStack {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 12))
                        Text("Export Log")
                            .font(System7Theme.titleFont(size: 11))
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
                            .font(System7Theme.titleFont(size: 11))
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
                .font(System7Theme.bodyFont(size: 9))
                .foregroundColor(System7Theme.darkGray)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
        }
        .padding(12)
        .background(System7Theme.lightGray)
        .overlay(
            Rectangle()
                .stroke(System7Theme.black, lineWidth: 1)
        )
        .onAppear {
            updateDebugLogSize()
        }
        .sheet(isPresented: $showDebugLogShare) {
            ShareSheet(activityItems: [DebugLogger.shared.getLogFileURL()])
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
                    .font(System7Theme.titleFont(size: 12))
                Spacer()
            }
            .foregroundColor(System7Theme.black)

            // Warning box
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                        .font(.system(size: 14))

                    Text("DANGER ZONE")
                        .font(System7Theme.titleFont(size: 10))
                        .foregroundColor(.red)

                    Spacer()
                }

                Text("Full rescan rebuilds the commitment tree from scratch. Required if witnesses are invalid. This takes 30-60 minutes.")
                    .font(System7Theme.bodyFont(size: 9))
                    .foregroundColor(System7Theme.darkGray)
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
                        .font(System7Theme.titleFont(size: 11))
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
                        .font(System7Theme.titleFont(size: 11))
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

            // Full Rescan from Height button - ORANGE (spendable notes)
            Button(action: {
                showFullRescanFromHeight = true
            }) {
                HStack {
                    Image(systemName: "arrow.clockwise.circle")
                        .font(.system(size: 12))
                    Text("Full Rescan from Height")
                        .font(System7Theme.titleFont(size: 11))
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
                        .font(System7Theme.titleFont(size: 11))
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
        .background(System7Theme.lightGray)
        .overlay(
            Rectangle()
                .stroke(System7Theme.black, lineWidth: 1)
        )
    }

    // MARK: - Rescan Progress View

    private var rescanProgressView: some View {
        VStack(spacing: 20) {
            Text("Full Blockchain Rescan")
                .font(System7Theme.titleFont(size: 16))
                .foregroundColor(System7Theme.black)

            // Progress bar
            VStack(spacing: 8) {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(System7Theme.white)
                            .frame(height: 20)
                            .overlay(
                                Rectangle()
                                    .stroke(System7Theme.black, lineWidth: 1)
                            )

                        Rectangle()
                            .fill(Color.blue)
                            .frame(width: geometry.size.width * rescanProgress, height: 18)
                            .offset(x: 1)
                    }
                }
                .frame(height: 20)

                Text("\(Int(rescanProgress * 100))%")
                    .font(System7Theme.titleFont(size: 14))
                    .foregroundColor(System7Theme.black)
            }

            // Block progress
            VStack(spacing: 4) {
                HStack {
                    Text("Block:")
                        .font(System7Theme.bodyFont(size: 10))
                        .foregroundColor(System7Theme.darkGray)
                    Spacer()
                    Text("\(rescanCurrentHeight) / \(rescanMaxHeight)")
                        .font(System7Theme.bodyFont(size: 10))
                        .foregroundColor(System7Theme.black)
                }

                HStack {
                    Text("Elapsed:")
                        .font(System7Theme.bodyFont(size: 10))
                        .foregroundColor(System7Theme.darkGray)
                    Spacer()
                    Text(formatDuration(rescanElapsedTime))
                        .font(System7Theme.bodyFont(size: 10))
                        .foregroundColor(System7Theme.black)
                }

                HStack {
                    Text("Estimated:")
                        .font(System7Theme.bodyFont(size: 10))
                        .foregroundColor(System7Theme.darkGray)
                    Spacer()
                    Text(estimatedTimeRemaining)
                        .font(System7Theme.bodyFont(size: 10))
                        .foregroundColor(System7Theme.black)
                }

                HStack {
                    Text("Tree Size:")
                        .font(System7Theme.bodyFont(size: 10))
                        .foregroundColor(System7Theme.darkGray)
                    Spacer()
                    Text("\(ZipherXFFI.treeSize()) commitments")
                        .font(System7Theme.bodyFont(size: 10))
                        .foregroundColor(System7Theme.black)
                }
            }
            .padding(12)
            .background(System7Theme.white)
            .overlay(
                Rectangle()
                    .stroke(System7Theme.black, lineWidth: 1)
            )

            // Status message
            if rescanProgress < 0 {
                // Error state
                VStack(spacing: 8) {
                    Text("Rescan failed!")
                        .font(System7Theme.titleFont(size: 12))
                        .foregroundColor(.red)
                    Text(errorMessage)
                        .font(System7Theme.bodyFont(size: 9))
                        .foregroundColor(System7Theme.darkGray)
                        .multilineTextAlignment(.center)
                }
            } else {
                Text(rescanProgress >= 1.0 ? "Rescan complete!" : "Building commitment tree...")
                    .font(System7Theme.bodyFont(size: 10))
                    .foregroundColor(rescanProgress >= 1.0 ? .green : System7Theme.darkGray)
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
                        .stroke(System7Theme.black, lineWidth: 1)
                )
            }
        }
        .padding(30)
        .background(System7Theme.lightGray)
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
                .font(System7Theme.titleFont(size: 16))
                .foregroundColor(System7Theme.black)

            VStack(spacing: 12) {
                SecureField("Enter 4-6 digit PIN", text: $pinCode)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .keyboardType(.numberPad)
                    .frame(maxWidth: 200)

                SecureField("Confirm PIN", text: $confirmPIN)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .keyboardType(.numberPad)
                    .frame(maxWidth: 200)
            }

            HStack(spacing: 12) {
                Button("Cancel") {
                    pinCode = ""
                    confirmPIN = ""
                    usePINCode = false
                    showPINSetup = false
                }
                .foregroundColor(.red)

                Button("Save") {
                    savePIN()
                }
                .disabled(pinCode.count < 4 || pinCode != confirmPIN)
            }
        }
        .padding(30)
        .background(System7Theme.lightGray)
    }

    // MARK: - Debug Section

    private var debugSection: some View {
        VStack(spacing: 12) {
            // Section header
            HStack {
                Image(systemName: "hammer")
                    .font(.system(size: 12))
                Text("Debug Tools")
                    .font(System7Theme.titleFont(size: 12))
                Spacer()
            }
            .foregroundColor(System7Theme.black)

            // Recover Spent Notes button - for failed transaction recovery
            Button(action: {
                recoverSpentNotes()
            }) {
                HStack {
                    Image(systemName: "arrow.uturn.backward.circle")
                        .font(.system(size: 12))
                    Text("Recover Stuck Funds")
                        .font(System7Theme.titleFont(size: 11))
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
                .font(System7Theme.bodyFont(size: 9))
                .foregroundColor(System7Theme.darkGray)
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
                        .font(System7Theme.titleFont(size: 11))
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
                .font(System7Theme.bodyFont(size: 9))
                .foregroundColor(System7Theme.darkGray)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
        }
        .padding(12)
        .background(System7Theme.lightGray)
        .overlay(
            Rectangle()
                .stroke(System7Theme.black, lineWidth: 1)
        )
    }

    // MARK: - Actions

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

        // Save PIN (in production, hash this!)
        UserDefaults.standard.set(pinCode, forKey: "walletPIN")
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

#Preview {
    SettingsView()
        .environmentObject(WalletManager.shared)
}
