import SwiftUI
import LocalAuthentication

#if os(macOS)
import AppKit

/// Consolidated Full Node Settings View for wallet.dat mode
/// All daemon management, bootstrap, config, and wallet security in one place
struct FullNodeSettingsView: View {
    @EnvironmentObject var themeManager: ThemeManager
    @ObservedObject private var fullNodeManager = FullNodeManager.shared
    @ObservedObject private var bootstrapManager = BootstrapManager.shared
    @ObservedObject private var rpcClient = RPCClient.shared
    @Environment(\.dismiss) private var dismiss

    // State
    @State private var showingBootstrapSheet = false
    @State private var showingBootstrapConfirmation = false  // FIX #1453
    @State private var showingConfigEditor = false
    @State private var isStartingDaemon = false
    @State private var isStoppingDaemon = false
    @State private var operationError: String?

    // Backup state
    @State private var lastBackupDate: Date?
    @State private var isCreatingBackup = false
    @State private var backupSuccess: String?

    // Export / Import Private Key state
    @State private var showingExportSheet = false
    @State private var showingImportSheet = false
    @State private var exportAddresses: [WalletAddress] = []
    @State private var isLoadingExportAddresses = false
    @State private var selectedExportAddress: WalletAddress?
    @State private var exportedPrivateKey: String = ""
    @State private var isExporting = false
    @State private var showingExportedKeySheet = false
    @State private var exportCopiedFeedback = false
    @State private var importKeyText: String = ""
    @State private var importWithRescan: Bool = true
    @State private var isImporting = false
    @State private var importProgress: Double = 0
    @State private var importStatusMessage: String = ""
    @State private var importExportError: String?
    @State private var importExportSuccess: String?

    // Screenshot protection
    @AppStorage("screenshotProtectionEnabled") private var screenshotProtectionEnabled: Bool = true
    @State private var showDisableScreenshotWarning = false

    // FIX #1273: Auth settings state
    @State private var useFaceID = false
    @State private var usePINCode = false
    @State private var biometricAvailable = false
    @State private var selectedTimeout: TimeInterval = BiometricAuthManager.shared.authTimeout
    @State private var showPINSetup = false
    @State private var pinCode = ""
    @State private var confirmPIN = ""
    @State private var showPINText = false
    @State private var authErrorMessage: String?

    private var theme: AppTheme { themeManager.currentTheme }

    // MARK: - Daemon Status Helpers

    // FIX #1581: Include .starting — daemon is warming up after bootstrap, don't show "Start Daemon"
    private var isDaemonRunning: Bool {
        switch fullNodeManager.daemonStatus {
        case .running, .syncing, .starting:
            return true
        default:
            return false
        }
    }

    // FIX #1379: Daemon active = running, syncing, OR starting — backup not safe in any of these states
    private var isDaemonActive: Bool {
        switch fullNodeManager.daemonStatus {
        case .running, .syncing, .starting:
            return true
        default:
            return false
        }
    }

    private var isDaemonBusy: Bool {
        switch fullNodeManager.daemonStatus {
        case .starting, .syncing:
            return true
        default:
            break
        }
        switch bootstrapManager.status {
        case .startingDaemon, .syncingBlocks:
            return true
        default:
            return false
        }
    }

    private var daemonStatusText: String {
        switch fullNodeManager.daemonStatus {
        case .running:
            return "Running"
        case .syncing(let progress):
            return "Syncing (\(Int(progress * 100))%)"
        case .starting:
            return "Starting..."
        case .stopped:
            return "Stopped"
        case .notInstalled:
            return "Not Installed"
        case .installed:
            return "Installed (Not Running)"
        case .error(let msg):
            return "Error: \(msg)"
        case .unknown:
            return "Unknown"
        }
    }

    private var daemonStatusColor: Color {
        switch fullNodeManager.daemonStatus {
        case .running:
            return .green
        case .syncing:
            return .orange
        case .starting:
            return .yellow
        case .stopped, .installed:
            return .gray
        case .notInstalled, .error, .unknown:
            return .red
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerSection

            Divider()
                .background(theme.borderColor)

            // Content
            ScrollView {
                VStack(spacing: 16) {
                    // 1. Switch Mode (at top for easy access)
                    switchModeSection

                    // 2. Daemon Control
                    daemonControlSection

                    // 3. Bootstrap Management
                    bootstrapSection

                    // 4. Configuration
                    configurationSection

                    // 5. Authentication & Lock
                    authenticationSection

                    // 6. Wallet Security
                    walletSecuritySection

                    // 7. Danger Zone (Export / Import Private Keys)
                    dangerZoneSection

                    // 8. Debug & Logs
                    debugSection
                }
                .padding()
            }
        }
        .frame(minWidth: 500, minHeight: 600)
        .background(theme.backgroundColor)
        .onAppear {
            checkBiometricAvailability()
        }
        .sheet(isPresented: $showingBootstrapSheet) {
            BootstrapProgressView()
                .environmentObject(themeManager)
        }
        // FIX #1453: Confirmation dialog before bootstrap download
        .alert("Install Bootstrap?", isPresented: $showingBootstrapConfirmation) {
            Button("Download Bootstrap", role: .destructive) {
                showingBootstrapSheet = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will download and extract blockchain data (~10 GB download, ~30 GB extracted).\n\nExisting blockchain data (blocks & chainstate) will be overwritten.\n\nMake sure you have backed up your wallet.dat and any important data before proceeding.")
        }
        .sheet(isPresented: $showingConfigEditor) {
            configEditorSheet
        }
        .sheet(isPresented: $showPINSetup) {
            pinSetupSheet
                .frame(minWidth: 400, idealWidth: 450, minHeight: 350, idealHeight: 400)
        }
        .sheet(isPresented: $showingExportSheet) {
            exportPrivateKeySheet
                .frame(minWidth: 450, idealWidth: 500, minHeight: 400, idealHeight: 500)
                .onDisappear {
                    exportedPrivateKey = ""
                    selectedExportAddress = nil
                    importExportError = nil
                }
        }
        .sheet(isPresented: $showingImportSheet) {
            importPrivateKeySheet
                .frame(minWidth: 450, idealWidth: 500, minHeight: 350, idealHeight: 400)
                .onDisappear {
                    importKeyText = ""
                    importExportError = nil
                    importExportSuccess = nil
                    importProgress = 0
                    importStatusMessage = ""
                }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Full Node Settings")
                    .font(theme.titleFont)
                    .foregroundColor(theme.textPrimary)
                Text("Manage daemon, bootstrap, and wallet.dat")
                    .font(theme.captionFont)
                    .foregroundColor(theme.textSecondary)
            }

            Spacer()

            Button("Done") {
                dismiss()
            }
            .buttonStyle(.plain)
            .foregroundColor(theme.primaryColor)
        }
        .padding()
        .background(theme.surfaceColor)
    }

    // MARK: - Daemon Control Section

    private var daemonControlSection: some View {
        settingsCard(title: "Daemon Control", icon: "server.rack") {
            VStack(alignment: .leading, spacing: 12) {
                // Status indicator
                HStack {
                    Circle()
                        .fill(daemonStatusColor)
                        .frame(width: 10, height: 10)
                    Text(daemonStatusText)
                        .font(theme.bodyFont)
                        .foregroundColor(theme.textPrimary)

                    Spacer()

                    if fullNodeManager.daemonBlockHeight > 0 {
                        Text("Block \(fullNodeManager.daemonBlockHeight)")
                            .font(theme.monoFont)
                            .foregroundColor(theme.textSecondary)
                    }
                }

                // Control buttons
                HStack(spacing: 12) {
                    if isDaemonRunning {
                        // FIX #1581: Show "Warming up..." spinner when daemon is starting
                        if case .starting = fullNodeManager.daemonStatus {
                            HStack {
                                ProgressView()
                                    .scaleEffect(0.7)
                                Text("Warming up...")
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.orange.opacity(0.1))
                            .cornerRadius(6)
                            .foregroundColor(.orange)
                        } else {
                        Button(action: stopDaemon) {
                            HStack {
                                if isStoppingDaemon {
                                    ProgressView()
                                        .scaleEffect(0.7)
                                } else {
                                    Image(systemName: "stop.fill")
                                }
                                Text("Stop Daemon")
                            }
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.red.opacity(0.1))
                        .cornerRadius(6)
                        .foregroundColor(.red)
                        .disabled(isStoppingDaemon || isDaemonBusy)
                        }
                    } else {
                        Button(action: startDaemon) {
                            HStack {
                                if isStartingDaemon || isDaemonBusy {
                                    ProgressView()
                                        .scaleEffect(0.7)
                                } else {
                                    Image(systemName: "play.fill")
                                }
                                Text("Start Daemon")
                            }
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(theme.primaryColor.opacity(0.1))
                        .cornerRadius(6)
                        .foregroundColor(theme.primaryColor)
                        .disabled(isStartingDaemon || isDaemonBusy)
                    }

                    // Refresh status
                    Button(action: { fullNodeManager.checkNodeStatus() }) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(theme.textSecondary)
                }

                if let error = operationError {
                    Text(error)
                        .font(theme.captionFont)
                        .foregroundColor(.red)
                }
            }
        }
    }

    // MARK: - Bootstrap Section

    private var bootstrapSection: some View {
        settingsCard(title: "Bootstrap", icon: "arrow.down.circle") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Download pre-synced blockchain data for faster setup.")
                    .font(theme.captionFont)
                    .foregroundColor(theme.textSecondary)

                HStack(spacing: 12) {
                    // FIX #1453: Show confirmation before starting bootstrap
                    Button(action: { showingBootstrapConfirmation = true }) {
                        HStack {
                            Image(systemName: "square.and.arrow.down")
                            Text("Install Bootstrap")
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(theme.primaryColor.opacity(0.1))
                    .cornerRadius(6)
                    .foregroundColor(theme.primaryColor)
                    .disabled(isDaemonRunning)

                    if isDaemonRunning {
                        Text("(Stop daemon first)")
                            .font(theme.captionFont)
                            .foregroundColor(.orange)
                    }
                }

                // Backup wallet.dat before bootstrap
                Button(action: backupWalletDat) {
                    HStack {
                        if isCreatingBackup {
                            ProgressView()
                                .scaleEffect(0.7)
                        } else {
                            Image(systemName: "doc.on.doc")
                        }
                        Text("Backup wallet.dat")
                    }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.blue.opacity(0.1))
                .cornerRadius(6)
                .foregroundColor(.blue)
                .disabled(isCreatingBackup || isDaemonActive)

                // FIX #1379: Warn user backup requires daemon to be stopped
                if isDaemonActive {
                    Text("(Stop daemon first)")
                        .font(theme.captionFont)
                        .foregroundColor(.orange)
                }

                if let success = backupSuccess {
                    Text(success)
                        .font(theme.captionFont)
                        .foregroundColor(.green)
                }
            }
        }
    }

    // MARK: - Configuration Section

    private var configurationSection: some View {
        settingsCard(title: "Configuration", icon: "doc.text") {
            VStack(alignment: .leading, spacing: 12) {
                // Quick stats
                HStack {
                    VStack(alignment: .leading) {
                        Text("Network")
                            .font(theme.captionFont)
                            .foregroundColor(theme.textSecondary)
                        Text("Port 8033")
                            .font(theme.monoFont)
                            .foregroundColor(theme.textPrimary)
                    }

                    Spacer()

                    VStack(alignment: .leading) {
                        Text("RPC")
                            .font(theme.captionFont)
                            .foregroundColor(theme.textSecondary)
                        Text("Port 8023")
                            .font(theme.monoFont)
                            .foregroundColor(theme.textPrimary)
                    }

                    Spacer()

                    VStack(alignment: .leading) {
                        Text("Peers")
                            .font(theme.captionFont)
                            .foregroundColor(theme.textSecondary)
                        Text("\(rpcClient.peerCount)")
                            .font(theme.monoFont)
                            .foregroundColor(theme.textPrimary)
                    }
                }

                Button(action: { showingConfigEditor = true }) {
                    HStack {
                        Image(systemName: "pencil")
                        Text("Edit Configuration")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundColor(theme.textSecondary)
                    }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(theme.surfaceColor)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.black.opacity(0.6), lineWidth: 1)
                )
                .cornerRadius(6)
                .foregroundColor(theme.primaryColor)

                // Open config in external editor
                Button(action: openConfigInEditor) {
                    HStack {
                        Image(systemName: "doc.text.magnifyingglass")
                        Text("Open in Text Editor")
                    }
                }
                .buttonStyle(.plain)
                .foregroundColor(theme.textSecondary)
                .font(theme.captionFont)
            }
        }
    }

    // MARK: - FIX #1273: Authentication & Lock Section

    private var authenticationSection: some View {
        settingsCard(title: "Authentication & Lock", icon: "lock.fill") {
            VStack(alignment: .leading, spacing: 12) {
                // Security warning when neither Face ID nor PIN is enabled
                if !useFaceID && !usePINCode {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 16))
                            .foregroundColor(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("SECURITY RECOMMENDED")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(.orange)
                            Text("Enable \(biometricAvailable ? getBiometricName() + " or " : "")PIN Code to protect your wallet.")
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
                            Menu {
                                ForEach(BiometricAuthManager.timeoutOptions, id: \.seconds) { option in
                                    Button(action: {
                                        selectedTimeout = option.seconds
                                        BiometricAuthManager.shared.setAuthTimeout(option.seconds)
                                    }) {
                                        if option.seconds == selectedTimeout {
                                            Label(option.label, systemImage: "checkmark")
                                        } else {
                                            Text(option.label)
                                        }
                                    }
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Text(BiometricAuthManager.shared.timeoutDisplayString)
                                        .font(theme.bodyFont)
                                        .foregroundColor(theme.primaryColor)
                                    Image(systemName: "chevron.up.chevron.down")
                                        .font(.system(size: 10))
                                        .foregroundColor(theme.primaryColor)
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
                                PINSecurity.deletePINHash()  // VUL-STOR-002
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

                if let error = authErrorMessage {
                    Text(error)
                        .font(theme.captionFont)
                        .foregroundColor(.red)
                        .padding(.horizontal, 12)
                }
            }
        }
    }

    // MARK: - Wallet Security Section

    private var walletSecuritySection: some View {
        settingsCard(title: "Wallet Security", icon: "lock.shield") {
            VStack(alignment: .leading, spacing: 12) {
                // Encryption status
                HStack {
                    Image(systemName: walletIsEncrypted ? "checkmark.shield.fill" : "exclamationmark.shield")
                        .foregroundColor(walletIsEncrypted ? .green : .orange)
                    Text(walletIsEncrypted ? "wallet.dat is encrypted" : "wallet.dat is NOT encrypted")
                        .font(theme.bodyFont)
                        .foregroundColor(theme.textPrimary)
                }

                if !walletIsEncrypted {
                    Text("⚠️ Your wallet is not encrypted. Anyone with access to your computer can steal your funds.")
                        .font(theme.captionFont)
                        .foregroundColor(.orange)
                        .padding(8)
                        .background(Color.orange.opacity(0.1))
                        .cornerRadius(6)
                }

                // Wallet.dat info
                if let size = walletDatSize {
                    HStack {
                        Text("Size:")
                            .foregroundColor(theme.textSecondary)
                        Text(size)
                            .foregroundColor(theme.textPrimary)
                    }
                    .font(theme.captionFont)
                }

                Divider()

                // Screenshot Protection Toggle
                HStack {
                    Image(systemName: "camera.fill")
                        .foregroundColor(theme.textPrimary)

                    Text("Screenshot Protection")
                        .font(theme.bodyFont)
                        .foregroundColor(theme.textPrimary)

                    Spacer()

                    Toggle("", isOn: Binding(
                        get: { screenshotProtectionEnabled },
                        set: { newValue in
                            if !newValue {
                                showDisableScreenshotWarning = true
                            } else {
                                screenshotProtectionEnabled = true
                            }
                        }
                    ))
                    .labelsHidden()
                }

                Text(screenshotProtectionEnabled
                    ? "Screenshots and screen sharing are blocked."
                    : "Protection disabled — screenshots and screen sharing are allowed.")
                    .font(theme.captionFont)
                    .foregroundColor(screenshotProtectionEnabled ? theme.textSecondary : .orange)
            }
        }
        .alert("Disable Screenshot Protection?", isPresented: $showDisableScreenshotWarning) {
            Button("Disable", role: .destructive) {
                screenshotProtectionEnabled = false
            }
            Button("Keep Enabled", role: .cancel) { }
        } message: {
            Text("WARNING: Disabling screenshot protection allows screenshots and screen sharing to capture your wallet balances, addresses, and transaction history.\n\nThis is a security risk. Only disable temporarily if you need to take a screenshot.")
        }
    }

    // MARK: - Danger Zone (Export / Import Private Keys)

    private let dangerRed = Color(red: 0.8, green: 0.1, blue: 0.1)

    private var dangerZoneSection: some View {
        settingsCard(title: "Danger Zone", icon: "exclamationmark.triangle.fill") {
            VStack(alignment: .leading, spacing: 12) {
                // Export Private Key
                Button(action: {
                    isLoadingExportAddresses = true
                    Task {
                        await loadExportAddresses()
                        isLoadingExportAddresses = false
                        showingExportSheet = true
                    }
                }) {
                    HStack {
                        if isLoadingExportAddresses {
                            ProgressView()
                                .scaleEffect(0.7)
                            Text("Loading addresses...")
                        } else {
                            Image(systemName: "key.fill")
                            Text("Export Private Key")
                        }
                        Spacer()
                        if !isLoadingExportAddresses {
                            Image(systemName: "chevron.right")
                                .foregroundColor(.black.opacity(0.5))
                        }
                    }
                    .font(theme.bodyFont)
                    .foregroundColor(.black)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(isLoadingExportAddresses ? dangerRed.opacity(0.4) : dangerRed.opacity(0.8))
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .disabled(isLoadingExportAddresses)

                // Import Private Key
                Button(action: {
                    showingImportSheet = true
                }) {
                    HStack {
                        Image(systemName: "square.and.arrow.down")
                        Text("Import Private Key")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundColor(.black.opacity(0.5))
                    }
                    .font(theme.bodyFont)
                    .foregroundColor(.black)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(dangerRed.opacity(0.8))
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func loadExportAddresses() async {
        do {
            let rpc = RPCWalletOperations.shared
            try await rpc.connect()
            async let z = rpc.listZAddresses()
            async let t = rpc.listTAddresses()
            let (zResult, tResult) = try await (z, t)
            await MainActor.run {
                exportAddresses = (zResult + tResult).sorted { $0.balance > $1.balance }
            }
        } catch {
            await MainActor.run {
                importExportError = "Failed to load addresses: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Export Private Key Sheet

    private var exportPrivateKeySheet: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Export Private Key")
                    .font(theme.titleFont)
                    .foregroundColor(theme.textPrimary)
                Spacer()
                Button("Close") {
                    showingExportSheet = false
                }
                .buttonStyle(.plain)
                .foregroundColor(theme.primaryColor)
            }
            .padding()
            .background(theme.surfaceColor)

            Divider()

            ScrollView {
                VStack(spacing: 16) {
                    // Warning
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(dangerRed)
                        Text("Never share your private key with anyone!")
                            .font(theme.bodyFont)
                            .foregroundColor(dangerRed)
                    }
                    .padding()
                    .background(dangerRed.opacity(0.1))
                    .cornerRadius(8)

                    if let error = importExportError {
                        Text(error)
                            .font(theme.captionFont)
                            .foregroundColor(dangerRed)
                    }

                    // Address selection
                    Text("Select address to export:")
                        .font(theme.bodyFont)
                        .foregroundColor(theme.textPrimary)

                    ForEach(exportAddresses) { address in
                        Button(action: { selectedExportAddress = address }) {
                            HStack {
                                Image(systemName: address.isShielded ? "shield.fill" : "eye.fill")
                                    .foregroundColor(address.isShielded ? theme.primaryColor : dangerRed)
                                VStack(alignment: .leading) {
                                    Text(truncateAddr(address.address))
                                        .font(theme.monoFont)
                                        .foregroundColor(theme.textPrimary)
                                    Text(formatZatoshis(address.balance))
                                        .font(theme.captionFont)
                                        .foregroundColor(theme.textSecondary)
                                }
                                Spacer()
                                if selectedExportAddress?.id == address.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.green)
                                }
                            }
                            .padding(10)
                            .background(selectedExportAddress?.id == address.id ? theme.primaryColor.opacity(0.1) : theme.surfaceColor)
                            .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                    }

                    if exportAddresses.isEmpty {
                        Text("No addresses found")
                            .font(theme.bodyFont)
                            .foregroundColor(theme.textSecondary)
                    }

                    // Export button
                    if selectedExportAddress != nil {
                        Button(action: { Task { await performExport() } }) {
                            HStack {
                                if isExporting {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                }
                                Text("Export Private Key")
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(dangerRed)
                            .foregroundColor(.white)
                            .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                        .disabled(isExporting)
                    }
                }
                .padding()
            }
        }
        .background(theme.backgroundColor)
        .sheet(isPresented: $showingExportedKeySheet) {
            exportedKeyDisplaySheet
                .onDisappear {
                    exportedPrivateKey = ""
                    exportCopiedFeedback = false
                }
        }
    }

    // MARK: - Exported Key Display Sheet

    private var exportedKeyDisplaySheet: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "key.fill")
                    .foregroundColor(dangerRed)
                Text("Private Key")
                    .font(theme.titleFont)
                    .foregroundColor(theme.textPrimary)
                Spacer()
                Button("Close") {
                    showingExportedKeySheet = false
                }
                .buttonStyle(.plain)
                .foregroundColor(theme.primaryColor)
            }
            .padding()
            .background(theme.surfaceColor)

            Divider()

            VStack(spacing: 20) {
                Spacer()

                // Warning
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(dangerRed)
                    Text("Never share this key with anyone!")
                        .font(theme.bodyFont)
                        .foregroundColor(dangerRed)
                }

                // Key display — truncated for safety
                let displayKey = String(exportedPrivateKey.prefix(8)) + "..." + String(exportedPrivateKey.suffix(8))
                Text(displayKey)
                    .font(.system(size: 18, weight: .medium, design: .monospaced))
                    .foregroundColor(theme.textPrimary)
                    .padding(16)
                    .frame(maxWidth: .infinity)
                    .background(theme.surfaceColor)
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(theme.borderColor, lineWidth: 1)
                    )

                // Copy button with feedback
                Button(action: {
                    ClipboardManager.copyWithAutoExpiry(exportedPrivateKey, seconds: 10)
                    exportCopiedFeedback = true
                    // Auto-hide after 2 seconds
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        exportCopiedFeedback = false
                    }
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: exportCopiedFeedback ? "checkmark" : "doc.on.doc")
                        Text(exportCopiedFeedback ? "Copied!" : "Copy to Clipboard")
                    }
                    .font(theme.bodyFont.weight(.medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(exportCopiedFeedback ? Color(red: 0.0, green: 0.5, blue: 0.9) : theme.primaryColor)
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)

                if exportCopiedFeedback {
                    Text("Auto-clears from clipboard in 10 seconds")
                        .font(theme.captionFont)
                        .foregroundColor(theme.textSecondary)
                }

                Spacer()
            }
            .padding(24)
        }
        .frame(minWidth: 400, idealWidth: 450, minHeight: 300, idealHeight: 350)
        .background(theme.backgroundColor)
    }

    // MARK: - Import Private Key Sheet

    private var importPrivateKeySheet: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Import Private Key")
                    .font(theme.titleFont)
                    .foregroundColor(theme.textPrimary)
                Spacer()
                Button("Close") {
                    showingImportSheet = false
                }
                .buttonStyle(.plain)
                .foregroundColor(theme.primaryColor)
            }
            .padding()
            .background(theme.surfaceColor)

            Divider()

            VStack(spacing: 16) {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(dangerRed)
                    Text("Importing a key will add it to your wallet.dat")
                        .font(theme.bodyFont)
                        .foregroundColor(dangerRed)
                }
                .padding()
                .background(dangerRed.opacity(0.1))
                .cornerRadius(8)

                if let error = importExportError {
                    Text(error)
                        .font(theme.captionFont)
                        .foregroundColor(dangerRed)
                }

                if let success = importExportSuccess {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 18))
                        Text(success)
                            .font(theme.bodyFont)
                            .fontWeight(.semibold)
                    }
                    .foregroundColor(.white)
                    .padding(12)
                    .frame(maxWidth: .infinity)
                    .background(Color(red: 0.0, green: 0.5, blue: 0.9))
                    .cornerRadius(8)
                }

                TextField("Paste private key here...", text: $importKeyText)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .font(theme.monoFont)

                Toggle("Rescan blockchain after import", isOn: $importWithRescan)
                    .font(theme.bodyFont)
                    .foregroundColor(theme.textPrimary)

                if importWithRescan {
                    Text("Rescan will find all transactions for this key. This may take several minutes.")
                        .font(theme.captionFont)
                        .foregroundColor(theme.textSecondary)
                }

                if isImporting {
                    VStack(spacing: 8) {
                        ProgressView(value: importProgress)
                        Text(importStatusMessage)
                            .font(theme.captionFont)
                            .foregroundColor(theme.textSecondary)
                    }
                }

                Button(action: { Task { await performImport() } }) {
                    HStack {
                        if isImporting {
                            ProgressView()
                                .scaleEffect(0.8)
                        }
                        Text("Import Private Key")
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(importKeyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isImporting ? Color.gray : dangerRed)
                    .foregroundColor(.white)
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .disabled(importKeyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isImporting)

                Spacer()
            }
            .padding()
        }
        .background(theme.backgroundColor)
    }

    // MARK: - Export / Import Actions

    private func performExport() async {
        guard let address = selectedExportAddress else { return }

        // Biometric auth gate
        let authResult = await withCheckedContinuation { continuation in
            BiometricAuthManager.shared.authenticateForKeyExport { success, _ in
                continuation.resume(returning: success)
            }
        }
        guard authResult else { return }

        await MainActor.run {
            isExporting = true
            importExportError = nil
            exportedPrivateKey = ""
        }

        do {
            let pk = try await RPCClient.shared.exportPrivateKey(address.address)
            await MainActor.run {
                exportedPrivateKey = pk
                isExporting = false
                exportCopiedFeedback = false
                showingExportedKeySheet = true
            }
        } catch {
            await MainActor.run {
                importExportError = error.localizedDescription
                isExporting = false
            }
        }
    }

    private func performImport() async {
        let key = importKeyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }

        await MainActor.run {
            isImporting = true
            importExportError = nil
            importExportSuccess = nil
            importProgress = 0
            importStatusMessage = "Starting import..."
        }

        do {
            let address = try await RPCClient.shared.importPrivateKey(key, rescan: importWithRescan) { progress, message in
                Task { @MainActor in
                    self.importProgress = progress
                    self.importStatusMessage = message
                }
            }
            await MainActor.run {
                importExportSuccess = "Imported: \(address)"
                importKeyText = ""
                isImporting = false
            }
        } catch {
            await MainActor.run {
                importExportError = error.localizedDescription
                isImporting = false
            }
        }
    }

    private func truncateAddr(_ addr: String) -> String {
        guard addr.count > 20 else { return addr }
        return String(addr.prefix(10)) + "..." + String(addr.suffix(8))
    }

    private func formatZatoshis(_ zatoshis: UInt64) -> String {
        let zcl = Double(zatoshis) / 100_000_000.0
        return String(format: "%.8f ZCL", zcl)
    }

    // MARK: - Debug Section

    private var debugSection: some View {
        settingsCard(title: "Debug & Logs", icon: "ladybug") {
            VStack(alignment: .leading, spacing: 12) {
                // Debug level selection
                HStack(spacing: 12) {
                    // Label on the left
                    Text("Debug Level")
                        .font(theme.bodyFont)
                        .foregroundColor(theme.textPrimary)

                    Spacer()

                    // Current value + dropdown button
                    Menu {
                        ForEach(FullNodeManager.DaemonDebugLevel.allCases, id: \.self) { level in
                            Button(action: {
                                fullNodeManager.daemonDebugLevel = level
                            }) {
                                HStack {
                                    Text(level.displayName)
                                    if level == fullNodeManager.daemonDebugLevel {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(fullNodeManager.daemonDebugLevel.displayName)
                                .font(theme.monoFont)
                                .foregroundColor(theme.textPrimary)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 10))
                                .foregroundColor(theme.textSecondary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(theme.backgroundColor)
                        .overlay(
                            Rectangle()
                                .stroke(theme.borderColor, lineWidth: 1)
                        )
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(theme.surfaceColor)
                .overlay(
                    Rectangle()
                        .stroke(theme.borderColor, lineWidth: 1)
                )

                // Description of selected level
                Text(fullNodeManager.daemonDebugLevel.description)
                    .font(theme.bodyFont)
                    .foregroundColor(theme.textPrimary.opacity(0.7))
                    .padding(.horizontal, 12)

                // Restart warning
                if fullNodeManager.daemonStatus.isRunning {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                        Text("Restart daemon to apply changes")
                            .font(theme.captionFont)
                    }
                    .foregroundColor(.orange)
                }

                Divider()
                    .background(theme.textSecondary.opacity(0.3))

                // Open debug.log
                Button(action: openDebugLog) {
                    HStack {
                        Image(systemName: "doc.text")
                        Text("Open debug.log")
                    }
                }
                .buttonStyle(.plain)
                .foregroundColor(theme.primaryColor)
            }
        }
    }

    // MARK: - Switch Mode Section

    private var switchModeSection: some View {
        settingsCard(title: "Switch Wallet Mode", icon: "arrow.left.arrow.right") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Switch to ZipherX's lightweight P2P wallet (no daemon required).")
                    .font(theme.captionFont)
                    .foregroundColor(theme.textSecondary)

                Button(action: switchToZipherX) {
                    HStack {
                        Image(systemName: "arrow.left.circle")
                        Text("Switch to ZipherX Wallet")
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.blue.opacity(0.1))
                .cornerRadius(6)
                .foregroundColor(.blue)
            }
        }
    }

    // MARK: - Config Editor Sheet

    private var configEditorSheet: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Edit Configuration")
                    .font(theme.titleFont)
                    .foregroundColor(theme.textPrimary)

                Spacer()

                Button("Done") {
                    showingConfigEditor = false
                }
                .buttonStyle(.plain)
                .foregroundColor(theme.primaryColor)
            }
            .padding()
            .background(theme.surfaceColor)

            Divider()

            // Import NodeManagementView's config editor content
            NodeManagementView()
                .environmentObject(themeManager)
        }
        .frame(minWidth: 600, minHeight: 700)
        .background(theme.backgroundColor)
    }

    // MARK: - Helper Views

    private func settingsCard<Content: View>(title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(theme.primaryColor)
                Text(title)
                    .font(theme.titleFont)
                    .foregroundColor(theme.textPrimary)
            }

            content()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surfaceColor)
        .cornerRadius(theme.cornerRadius)
        .overlay(
            RoundedRectangle(cornerRadius: theme.cornerRadius)
                .stroke(theme.borderColor, lineWidth: theme.borderWidth)
        )
    }

    // MARK: - Actions

    private func startDaemon() {
        isStartingDaemon = true
        operationError = nil

        Task {
            do {
                try await fullNodeManager.startDaemon()
                await MainActor.run {
                    isStartingDaemon = false
                }
            } catch {
                await MainActor.run {
                    isStartingDaemon = false
                    operationError = error.localizedDescription
                }
            }
        }
    }

    private func stopDaemon() {
        isStoppingDaemon = true
        operationError = nil

        Task {
            do {
                // Use zclassic-cli stop
                let process = Process()
                process.executableURL = FullNodeManager.cliPath
                process.arguments = ["stop"]
                try process.run()
                process.waitUntilExit()

                // Wait for daemon to stop
                for _ in 1...15 {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    if !fullNodeManager.daemonStatus.isRunning {
                        break
                    }
                }

                await MainActor.run {
                    isStoppingDaemon = false
                    fullNodeManager.checkNodeStatus()
                }
            } catch {
                await MainActor.run {
                    isStoppingDaemon = false
                    operationError = "Failed to stop daemon: \(error.localizedDescription)"
                }
            }
        }
    }

    private func backupWalletDat() {
        // FIX #1379: Safety check — never backup while daemon is running or starting
        if isDaemonActive {
            operationError = "Cannot backup wallet.dat while daemon is running. Stop the daemon first."
            return
        }

        isCreatingBackup = true
        backupSuccess = nil

        Task {
            let dataDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Zclassic")
            let walletPath = dataDir.appendingPathComponent("wallet.dat")

            guard FileManager.default.fileExists(atPath: walletPath.path) else {
                await MainActor.run {
                    isCreatingBackup = false
                    operationError = "wallet.dat not found"
                }
                return
            }

            // Create backup directory
            let backupDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("ZipherX_Backups")
            try? FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)

            // Create timestamped backup
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            let timestamp = formatter.string(from: Date())
            let backupPath = backupDir.appendingPathComponent("wallet_\(timestamp).dat")

            do {
                try FileManager.default.copyItem(at: walletPath, to: backupPath)
                await MainActor.run {
                    isCreatingBackup = false
                    backupSuccess = "Backup saved to ~/ZipherX_Backups/"
                    lastBackupDate = Date()
                }
            } catch {
                await MainActor.run {
                    isCreatingBackup = false
                    operationError = "Backup failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func openConfigInEditor() {
        let configPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Zclassic/zclassic.conf")
        NSWorkspace.shared.open(configPath)
    }

    private func openDebugLog() {
        let logPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Zclassic/debug.log")
        NSWorkspace.shared.open(logPath)
    }

    private func switchToZipherX() {
        dismiss()
        WalletModeManager.shared.setWalletSource(.zipherx)
    }

    // MARK: - Computed Properties

    private var walletIsEncrypted: Bool {
        // Check wallet.dat encryption status via file header heuristic
        let dataDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Zclassic")
        let walletPath = dataDir.appendingPathComponent("wallet.dat")

        guard FileManager.default.fileExists(atPath: walletPath.path),
              let data = try? Data(contentsOf: walletPath, options: .mappedIfSafe),
              data.count > 16 else {
            return false
        }

        // Encrypted wallets have specific magic bytes
        // This is a heuristic - check for BDB magic or encrypted header
        let header = [UInt8](data.prefix(16))
        // Berkeley DB magic: 0x00053162 at offset 12
        let hasBdbMagic = header.count >= 16 &&
            header[12] == 0x62 && header[13] == 0x31 &&
            header[14] == 0x05 && header[15] == 0x00

        return !hasBdbMagic  // If no BDB magic, likely encrypted
    }

    private var walletDatSize: String? {
        let dataDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Zclassic")
        let walletPath = dataDir.appendingPathComponent("wallet.dat")

        guard let attrs = try? FileManager.default.attributesOfItem(atPath: walletPath.path),
              let size = attrs[.size] as? UInt64 else {
            return nil
        }

        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(size))
    }

    // MARK: - FIX #1273: PIN Setup Sheet

    private var pinSetupSheet: some View {
        VStack(spacing: 20) {
            Text("Set PIN Code")
                .font(theme.titleFont)
                .foregroundColor(theme.textPrimary)

            VStack(spacing: 12) {
                HStack {
                    if showPINText {
                        TextField("Enter 4-6 digit PIN", text: $pinCode)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                    } else {
                        SecureField("Enter 4-6 digit PIN", text: $pinCode)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                    }
                    Button(action: { showPINText.toggle() }) {
                        Image(systemName: showPINText ? "eye.slash.fill" : "eye.fill")
                            .foregroundColor(theme.textSecondary)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                .frame(maxWidth: 250)

                HStack {
                    if showPINText {
                        TextField("Confirm PIN", text: $confirmPIN)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                    } else {
                        SecureField("Confirm PIN", text: $confirmPIN)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                    }
                    Image(systemName: "eye.fill")
                        .foregroundColor(.clear)
                }
                .frame(maxWidth: 250)
            }

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

                Button("Save PIN") {
                    savePIN()
                }
                .disabled(pinCode.count < 4 || pinCode != confirmPIN)
            }
        }
        .padding(30)
        .background(theme.backgroundColor)
    }

    // MARK: - FIX #1273: Auth Helper Functions

    private func checkBiometricAvailability() {
        let context = LAContext()
        var error: NSError?
        biometricAvailable = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        useFaceID = UserDefaults.standard.bool(forKey: "useBiometricAuth")
        usePINCode = PINSecurity.hasPIN()  // VUL-STOR-002
        // FIX #1438: Reload timeout from persisted value (same as SettingsView FIX #1346)
        selectedTimeout = BiometricAuthManager.shared.authTimeout
    }

    private func getBiometricName() -> String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        default: return "Biometric"
        }
    }

    private func getBiometricIcon() -> String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID: return "faceid"
        case .touchID: return "touchid"
        default: return "lock"
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
                        authErrorMessage = error.localizedDescription
                    }
                }
            }
        }
    }

    private func savePIN() {
        guard pinCode.count >= 4 && pinCode.count <= 6 else {
            authErrorMessage = "PIN must be 4-6 digits"
            return
        }
        guard pinCode == confirmPIN else {
            authErrorMessage = "PINs do not match"
            return
        }
        /// VUL-U-004: Generate per-user random salt (same as SettingsView)
        let salt = PINSecurity.generateSalt()
        PINSecurity.storePINSalt(salt)
        let hashedPIN = PINSecurity.hashPIN(pinCode, salt: salt)
        PINSecurity.storePINHash(hashedPIN)  // VUL-STOR-002
        pinCode = ""
        confirmPIN = ""
        showPINSetup = false
    }
}

#endif
