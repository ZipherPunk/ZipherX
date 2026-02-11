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
    @State private var showingConfigEditor = false
    @State private var isStartingDaemon = false
    @State private var isStoppingDaemon = false
    @State private var operationError: String?

    // Backup state
    @State private var lastBackupDate: Date?
    @State private var isCreatingBackup = false
    @State private var backupSuccess: String?

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

    private var isDaemonRunning: Bool {
        switch fullNodeManager.daemonStatus {
        case .running, .syncing:
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

                    // 7. Debug & Logs
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
        .sheet(isPresented: $showingConfigEditor) {
            configEditorSheet
        }
        .sheet(isPresented: $showPINSetup) {
            pinSetupSheet
                .frame(minWidth: 400, idealWidth: 450, minHeight: 350, idealHeight: 400)
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
                    Button(action: { showingBootstrapSheet = true }) {
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
                .disabled(isCreatingBackup)

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
            }
        }
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
        usePINCode = UserDefaults.standard.string(forKey: "walletPIN") != nil
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
        let hashedPIN = PINSecurity.hashPIN(pinCode)
        UserDefaults.standard.set(hashedPIN, forKey: "walletPIN")
        pinCode = ""
        confirmPIN = ""
        showPINSetup = false
    }
}

#endif
