import SwiftUI

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
                    // 1. Daemon Control
                    daemonControlSection

                    // 2. Bootstrap Management
                    bootstrapSection

                    // 3. Configuration
                    configurationSection

                    // 4. Wallet Security
                    walletSecuritySection

                    // 5. Debug & Logs
                    debugSection

                    // 6. Switch Mode
                    switchModeSection
                }
                .padding()
            }
        }
        .frame(minWidth: 500, minHeight: 600)
        .background(theme.backgroundColor)
        .sheet(isPresented: $showingBootstrapSheet) {
            BootstrapProgressView()
                .environmentObject(themeManager)
        }
        .sheet(isPresented: $showingConfigEditor) {
            configEditorSheet
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
                // FIX #884: Improved debug level picker with clear visual design
                VStack(alignment: .leading, spacing: 8) {
                    Text("Daemon Debug Level")
                        .font(theme.bodyFont.bold())
                        .foregroundColor(theme.textPrimary)

                    // Picker with clear dropdown indicator
                    HStack {
                        Picker("Select debug level", selection: $fullNodeManager.daemonDebugLevel) {
                            ForEach(FullNodeManager.DaemonDebugLevel.allCases, id: \.self) { level in
                                Text(level.displayName).tag(level)
                            }
                        }
                        .pickerStyle(.menu)
                        .tint(theme.accentColor)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(theme.surfaceColor.opacity(0.5))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(theme.accentColor.opacity(0.5), lineWidth: 1)
                                )
                        )

                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption)
                            .foregroundColor(theme.textSecondary)
                    }

                    // Description of selected level
                    Text(fullNodeManager.daemonDebugLevel.description)
                        .font(theme.captionFont)
                        .foregroundColor(theme.textSecondary)
                        .padding(.top, 2)

                    // Restart warning
                    if fullNodeManager.daemonStatus.isRunning {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption)
                            Text("Restart daemon to apply changes")
                                .font(theme.captionFont)
                        }
                        .foregroundColor(.orange)
                        .padding(.top, 4)
                    }
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
}

#endif
