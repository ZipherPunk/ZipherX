import SwiftUI

#if os(macOS)
import AppKit

/// Node Management View for Full Node mode
/// Allows users to manage their local zclassicd daemon
struct NodeManagementView: View {
    @EnvironmentObject var themeManager: ThemeManager
    @StateObject private var viewModel = NodeManagementViewModel()
    @Environment(\.dismiss) private var dismiss

    private var theme: AppTheme { themeManager.currentTheme }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Header
                headerSection

                // Daemon Status & Control
                daemonControlSection

                // Node Info
                nodeInfoSection

                // Bootstrap Management
                bootstrapSection

                // Backup Management
                backupSection

                // Privacy Settings
                privacySection

                // Error Log
                errorLogSection

                Spacer(minLength: 20)
            }
            .padding(20)
        }
        .frame(minWidth: 600, minHeight: 700)
        .background(theme.backgroundColor)
        .onAppear {
            viewModel.refresh()
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("⚙️ NODE MANAGEMENT")
                    .font(.system(size: 24, weight: .bold, design: .monospaced))
                    .foregroundColor(theme.textPrimary)

                Text("\"Don't trust, verify.\" - Bitcoin Proverb")
                    .font(theme.captionFont)
                    .foregroundColor(theme.textSecondary)
                    .italic()
            }

            Spacer()

            Button(action: { dismiss() }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 24))
                    .foregroundColor(theme.textSecondary)
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(.bottom, 10)
    }

    // MARK: - Daemon Control

    private var daemonControlSection: some View {
        VStack(spacing: 12) {
            sectionHeader(icon: "power", title: "DAEMON CONTROL")

            HStack(spacing: 16) {
                // Status indicator
                HStack(spacing: 8) {
                    Circle()
                        .fill(viewModel.isDaemonRunning ? Color.green : Color.red)
                        .frame(width: 12, height: 12)

                    Text(viewModel.isDaemonRunning ? "RUNNING" : "STOPPED")
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundColor(viewModel.isDaemonRunning ? .green : .red)
                }

                Spacer()

                // Control buttons
                if viewModel.isDaemonRunning {
                    Button(action: { viewModel.stopDaemon() }) {
                        HStack {
                            Image(systemName: "stop.fill")
                            Text("Stop Daemon")
                        }
                        .font(theme.bodyFont)
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.red)
                        .cornerRadius(theme.cornerRadius)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .disabled(viewModel.isOperationInProgress)
                } else {
                    Button(action: { viewModel.startDaemon() }) {
                        HStack {
                            Image(systemName: "play.fill")
                            Text("Start Daemon")
                        }
                        .font(theme.bodyFont)
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.green)
                        .cornerRadius(theme.cornerRadius)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .disabled(viewModel.isOperationInProgress)
                }
            }
            .padding(12)
            .background(theme.surfaceColor)
            .overlay(Rectangle().stroke(theme.textPrimary.opacity(0.3), lineWidth: 1))

            // Operation status
            if viewModel.isOperationInProgress {
                HStack {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text(viewModel.operationStatus)
                        .font(theme.captionFont)
                        .foregroundColor(theme.textSecondary)
                }
            }
        }
    }

    // MARK: - Node Info

    private var nodeInfoSection: some View {
        VStack(spacing: 12) {
            sectionHeader(icon: "info.circle", title: "NODE INFORMATION")

            VStack(spacing: 8) {
                infoRow(label: "Version", value: viewModel.daemonVersion ?? "Unknown")
                infoRow(label: "Block Height", value: viewModel.blockHeight > 0 ? "\(viewModel.blockHeight)" : "N/A")
                infoRow(label: "Connections", value: "\(viewModel.connectionCount)")
                infoRow(label: "Sync Progress", value: viewModel.syncProgress < 1.0 ? "\(Int(viewModel.syncProgress * 100))%" : "100% ✓")
                infoRow(label: "Data Directory", value: FullNodeManager.dataDir.path)
                infoRow(label: "Blockchain Size", value: viewModel.blockchainSize)

                // Privacy Score
                HStack {
                    Text("Privacy Score")
                        .font(theme.bodyFont)
                        .foregroundColor(theme.textSecondary)
                    Spacer()
                    privacyScoreBadge
                }
                .padding(.vertical, 4)
            }
            .padding(12)
            .background(theme.surfaceColor)
            .overlay(Rectangle().stroke(theme.textPrimary.opacity(0.3), lineWidth: 1))

            // Refresh button
            Button(action: { viewModel.refresh() }) {
                HStack {
                    Image(systemName: "arrow.clockwise")
                    Text("Refresh")
                }
                .font(theme.captionFont)
                .foregroundColor(theme.primaryColor)
            }
            .buttonStyle(PlainButtonStyle())
        }
    }

    private var privacyScoreBadge: some View {
        let score = viewModel.privacyScore
        let color: Color = score >= 80 ? .green : score >= 50 ? .orange : .red
        let label = score >= 80 ? "HIGH" : score >= 50 ? "MEDIUM" : "LOW"

        return HStack(spacing: 4) {
            Text("\(score)%")
                .font(.system(size: 14, weight: .bold, design: .monospaced))
            Text(label)
                .font(.system(size: 10, weight: .bold))
        }
        .foregroundColor(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.2))
        .cornerRadius(4)
    }

    // MARK: - Bootstrap Section

    private var bootstrapSection: some View {
        VStack(spacing: 12) {
            sectionHeader(icon: "arrow.down.circle", title: "BOOTSTRAP MANAGEMENT")

            VStack(spacing: 12) {
                Text("Download a pre-synced blockchain to skip the multi-hour initial sync.")
                    .font(theme.captionFont)
                    .foregroundColor(theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 12) {
                    Button(action: { viewModel.showBootstrapConfirm = true }) {
                        HStack {
                            Image(systemName: "arrow.down.doc.fill")
                            Text("Install Fresh Bootstrap")
                        }
                        .font(theme.bodyFont)
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(theme.primaryColor)
                        .cornerRadius(theme.cornerRadius)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .disabled(viewModel.isDaemonRunning)

                    if viewModel.isDaemonRunning {
                        Text("⚠️ Stop daemon first")
                            .font(theme.captionFont)
                            .foregroundColor(.orange)
                    }
                }

                // Bootstrap source info
                HStack(spacing: 4) {
                    Image(systemName: "link")
                        .font(.system(size: 10))
                    Text("Source: github.com/VictorLux/zclassic-bootstrap")
                        .font(.system(size: 10, design: .monospaced))
                }
                .foregroundColor(theme.textSecondary)
            }
            .padding(12)
            .background(theme.surfaceColor)
            .overlay(Rectangle().stroke(theme.textPrimary.opacity(0.3), lineWidth: 1))
        }
        .alert("Install Fresh Bootstrap?", isPresented: $viewModel.showBootstrapConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Backup & Install") {
                viewModel.installBootstrapWithBackup()
            }
        } message: {
            Text("""
This will:
1. Backup your current blockchain data
2. Backup wallet.dat (if exists)
3. Download fresh bootstrap (~3 GB)
4. Extract and replace blockchain data

Your wallet.dat backup will be saved to:
~/ZipherX_Backups/

Continue?
""")
        }
    }

    // MARK: - Backup Section

    private var backupSection: some View {
        VStack(spacing: 12) {
            sectionHeader(icon: "externaldrive.badge.checkmark", title: "BACKUP MANAGEMENT")

            VStack(spacing: 12) {
                // wallet.dat backup
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("wallet.dat")
                            .font(theme.bodyFont)
                            .foregroundColor(theme.textPrimary)
                        Text(viewModel.walletDatExists ? "File exists" : "Not found")
                            .font(theme.captionFont)
                            .foregroundColor(viewModel.walletDatExists ? .green : .orange)
                    }

                    Spacer()

                    Button(action: { viewModel.backupWalletDat() }) {
                        HStack {
                            Image(systemName: "square.and.arrow.down")
                            Text("Backup")
                        }
                        .font(theme.captionFont)
                        .foregroundColor(theme.primaryColor)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .overlay(Rectangle().stroke(theme.primaryColor, lineWidth: 1))
                    }
                    .buttonStyle(PlainButtonStyle())
                    .disabled(!viewModel.walletDatExists)
                }

                Divider()

                // Blockchain data backup
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Blockchain Data")
                            .font(theme.bodyFont)
                            .foregroundColor(theme.textPrimary)
                        Text(viewModel.blockchainSize)
                            .font(theme.captionFont)
                            .foregroundColor(theme.textSecondary)
                    }

                    Spacer()

                    Button(action: { viewModel.backupBlockchainData() }) {
                        HStack {
                            Image(systemName: "square.and.arrow.down")
                            Text("Backup")
                        }
                        .font(theme.captionFont)
                        .foregroundColor(theme.primaryColor)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .overlay(Rectangle().stroke(theme.primaryColor, lineWidth: 1))
                    }
                    .buttonStyle(PlainButtonStyle())
                }

                // Backup location
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                        .font(.system(size: 10))
                    Text("Backups saved to: ~/ZipherX_Backups/")
                        .font(.system(size: 10, design: .monospaced))

                    Spacer()

                    Button(action: { viewModel.openBackupFolder() }) {
                        Text("Open")
                            .font(.system(size: 10))
                            .foregroundColor(theme.primaryColor)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                .foregroundColor(theme.textSecondary)
            }
            .padding(12)
            .background(theme.surfaceColor)
            .overlay(Rectangle().stroke(theme.textPrimary.opacity(0.3), lineWidth: 1))
        }
    }

    // MARK: - Privacy Section

    private var privacySection: some View {
        VStack(spacing: 12) {
            sectionHeader(icon: "lock.shield", title: "PRIVACY SETTINGS")

            VStack(spacing: 12) {
                // Tor/Onion toggle
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("🧅 Tor/Onion Network")
                                .font(theme.bodyFont)
                                .foregroundColor(theme.textPrimary)

                            if viewModel.isTorEnabled {
                                Text("ACTIVE")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.green)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.green.opacity(0.2))
                                    .cornerRadius(4)
                            }
                        }
                        Text("Route all connections through Tor for maximum privacy")
                            .font(theme.captionFont)
                            .foregroundColor(theme.textSecondary)
                    }

                    Spacer()

                    Toggle("", isOn: $viewModel.isTorEnabled)
                        .toggleStyle(SwitchToggleStyle(tint: .green))
                        .onChange(of: viewModel.isTorEnabled) { newValue in
                            viewModel.setTorEnabled(newValue)
                        }
                }

                Divider()

                // Listen toggle
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Accept Incoming Connections")
                            .font(theme.bodyFont)
                            .foregroundColor(theme.textPrimary)
                        Text("Help the network by allowing other nodes to connect")
                            .font(theme.captionFont)
                            .foregroundColor(theme.textSecondary)
                    }

                    Spacer()

                    Toggle("", isOn: $viewModel.isListening)
                        .toggleStyle(SwitchToggleStyle(tint: theme.primaryColor))
                        .onChange(of: viewModel.isListening) { newValue in
                            viewModel.setListening(newValue)
                        }
                }

                Divider()

                // Privacy recommendations
                VStack(alignment: .leading, spacing: 8) {
                    Text("Privacy Recommendations:")
                        .font(theme.captionFont)
                        .fontWeight(.bold)
                        .foregroundColor(theme.textPrimary)

                    privacyRecommendation(
                        enabled: viewModel.isTorEnabled,
                        text: "Use Tor for network privacy"
                    )
                    privacyRecommendation(
                        enabled: !viewModel.isListening,
                        text: "Disable incoming connections to hide your IP"
                    )
                    privacyRecommendation(
                        enabled: true, // ZipherX always uses shielded
                        text: "Use shielded addresses (ZipherX default)"
                    )
                }
                .padding(8)
                .background(theme.backgroundColor)
                .cornerRadius(4)
            }
            .padding(12)
            .background(theme.surfaceColor)
            .overlay(Rectangle().stroke(theme.textPrimary.opacity(0.3), lineWidth: 1))
        }
    }

    private func privacyRecommendation(enabled: Bool, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: enabled ? "checkmark.circle.fill" : "circle")
                .foregroundColor(enabled ? .green : .gray)
                .font(.system(size: 12))
            Text(text)
                .font(theme.captionFont)
                .foregroundColor(theme.textSecondary)
        }
    }

    // MARK: - Error Log Section

    private var errorLogSection: some View {
        VStack(spacing: 12) {
            sectionHeader(icon: "exclamationmark.triangle", title: "ERROR LOG")

            VStack(spacing: 8) {
                if viewModel.recentErrors.isEmpty {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("No recent errors")
                            .font(theme.bodyFont)
                            .foregroundColor(theme.textSecondary)
                    }
                    .padding(20)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(viewModel.recentErrors, id: \.self) { error in
                                Text(error)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.red)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 100)
                }

                HStack {
                    Button(action: { viewModel.openDebugLog() }) {
                        HStack {
                            Image(systemName: "doc.text")
                            Text("Open Full Log")
                        }
                        .font(theme.captionFont)
                        .foregroundColor(theme.primaryColor)
                    }
                    .buttonStyle(PlainButtonStyle())

                    Spacer()

                    Button(action: { viewModel.clearErrors() }) {
                        Text("Clear")
                            .font(theme.captionFont)
                            .foregroundColor(theme.textSecondary)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .padding(12)
            .background(theme.surfaceColor)
            .overlay(Rectangle().stroke(theme.textPrimary.opacity(0.3), lineWidth: 1))
        }
    }

    // MARK: - Helpers

    private func sectionHeader(icon: String, title: String) -> some View {
        HStack {
            Image(systemName: icon)
                .font(.system(size: 12))
            Text(title)
                .font(.system(size: 14, weight: .bold, design: .monospaced))
            Spacer()
        }
        .foregroundColor(theme.textPrimary)
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(theme.bodyFont)
                .foregroundColor(theme.textSecondary)
            Spacer()
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - View Model

@MainActor
class NodeManagementViewModel: ObservableObject {
    @Published var isDaemonRunning = false
    @Published var daemonVersion: String?
    @Published var blockHeight: UInt64 = 0
    @Published var connectionCount: Int = 0
    @Published var syncProgress: Double = 0
    @Published var blockchainSize: String = "Calculating..."
    @Published var walletDatExists = false
    @Published var isTorEnabled = false
    @Published var isListening = true
    @Published var recentErrors: [String] = []
    @Published var isOperationInProgress = false
    @Published var operationStatus = ""
    @Published var showBootstrapConfirm = false

    private let fullNodeManager = FullNodeManager.shared

    var privacyScore: Int {
        var score = 50 // Base score for running full node
        if isTorEnabled { score += 30 }
        if !isListening { score += 10 }
        // ZipherX always uses shielded = +10
        score += 10
        return min(100, score)
    }

    init() {
        loadSettings()
    }

    func refresh() {
        Task {
            await refreshAsync()
        }
    }

    private func refreshAsync() async {
        // Check daemon status
        isDaemonRunning = fullNodeManager.daemonStatus.isRunning
        blockHeight = fullNodeManager.daemonBlockHeight
        syncProgress = fullNodeManager.daemonSyncProgress

        // Get version
        daemonVersion = await fullNodeManager.getDaemonVersion()

        // Get blockchain size
        blockchainSize = fullNodeManager.blockchainSize

        // Check wallet.dat
        walletDatExists = FileManager.default.fileExists(atPath: FullNodeManager.walletPath.path)

        // Get connection count from RPC
        if isDaemonRunning {
            do {
                let info = try await RPCClient.shared.getInfoDict()
                connectionCount = info["connections"] as? Int ?? 0
            } catch {
                connectionCount = 0
            }
        }

        // Load recent errors from debug.log
        loadRecentErrors()
    }

    func startDaemon() {
        isOperationInProgress = true
        operationStatus = "Starting daemon..."

        Task {
            do {
                try await fullNodeManager.startDaemon()
                await MainActor.run {
                    isDaemonRunning = true
                    isOperationInProgress = false
                    operationStatus = ""
                }
                refresh()
            } catch {
                await MainActor.run {
                    isOperationInProgress = false
                    operationStatus = ""
                    recentErrors.insert("Failed to start daemon: \(error.localizedDescription)", at: 0)
                }
            }
        }
    }

    func stopDaemon() {
        isOperationInProgress = true
        operationStatus = "Stopping daemon..."

        Task {
            do {
                // Use zclassic-cli stop
                let process = Process()
                process.executableURL = FullNodeManager.cliPath
                process.arguments = ["stop"]
                try process.run()
                process.waitUntilExit()

                // Wait for daemon to stop
                for _ in 1...30 {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    if !(await RPCClient.shared.checkConnection()) {
                        break
                    }
                }

                await MainActor.run {
                    isDaemonRunning = false
                    isOperationInProgress = false
                    operationStatus = ""
                }
            } catch {
                await MainActor.run {
                    isOperationInProgress = false
                    operationStatus = ""
                    recentErrors.insert("Failed to stop daemon: \(error.localizedDescription)", at: 0)
                }
            }
        }
    }

    func backupWalletDat() {
        let backupDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("ZipherX_Backups")

        do {
            try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)

            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyyMMdd_HHmmss"
            let timestamp = dateFormatter.string(from: Date())

            let backupPath = backupDir.appendingPathComponent("wallet_\(timestamp).dat")
            try FileManager.default.copyItem(at: FullNodeManager.walletPath, to: backupPath)

            // Show in Finder
            NSWorkspace.shared.selectFile(backupPath.path, inFileViewerRootedAtPath: backupDir.path)
        } catch {
            recentErrors.insert("Backup failed: \(error.localizedDescription)", at: 0)
        }
    }

    func backupBlockchainData() {
        // This would be a large operation - show info instead
        let alert = NSAlert()
        alert.messageText = "Backup Blockchain Data"
        alert.informativeText = """
        The blockchain data is located at:
        \(FullNodeManager.dataDir.path)

        Size: \(blockchainSize)

        To backup, stop the daemon and copy the entire ZClassic folder.
        """
        alert.addButton(withTitle: "Open Folder")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: FullNodeManager.dataDir.path)
        }
    }

    func installBootstrapWithBackup() {
        isOperationInProgress = true
        operationStatus = "Preparing bootstrap installation..."

        Task {
            // 1. Create backup directory
            let backupDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("ZipherX_Backups")

            do {
                try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)

                // 2. Backup wallet.dat if exists
                if walletDatExists {
                    await MainActor.run {
                        operationStatus = "Backing up wallet.dat..."
                    }

                    let dateFormatter = DateFormatter()
                    dateFormatter.dateFormat = "yyyyMMdd_HHmmss"
                    let timestamp = dateFormatter.string(from: Date())

                    let walletBackup = backupDir.appendingPathComponent("wallet_\(timestamp).dat")
                    try FileManager.default.copyItem(at: FullNodeManager.walletPath, to: walletBackup)
                    print("✅ Backed up wallet.dat to \(walletBackup.path)")
                }

                // 3. Start bootstrap download via BootstrapManager
                await MainActor.run {
                    operationStatus = "Starting bootstrap download..."
                    isOperationInProgress = false
                }

                // Open bootstrap sheet
                // Note: This would need to be connected to the BootstrapProgressView

            } catch {
                await MainActor.run {
                    isOperationInProgress = false
                    operationStatus = ""
                    recentErrors.insert("Bootstrap failed: \(error.localizedDescription)", at: 0)
                }
            }
        }
    }

    func openBackupFolder() {
        let backupDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("ZipherX_Backups")

        if !FileManager.default.fileExists(atPath: backupDir.path) {
            try? FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
        }

        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: backupDir.path)
    }

    func setTorEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "fullNodeTorEnabled")

        // Update zclassic.conf
        updateConfigSetting("proxy", value: enabled ? "127.0.0.1:9050" : nil)
        updateConfigSetting("listen", value: enabled ? "0" : "1")

        if isDaemonRunning {
            // Notify user to restart
            let alert = NSAlert()
            alert.messageText = "Restart Required"
            alert.informativeText = "Please restart the daemon for Tor settings to take effect."
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    func setListening(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "fullNodeListening")
        updateConfigSetting("listen", value: enabled ? "1" : "0")

        if isDaemonRunning {
            let alert = NSAlert()
            alert.messageText = "Restart Required"
            alert.informativeText = "Please restart the daemon for network settings to take effect."
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    private func updateConfigSetting(_ key: String, value: String?) {
        let configPath = FullNodeManager.configPath
        guard FileManager.default.fileExists(atPath: configPath.path) else { return }

        do {
            var config = try String(contentsOf: configPath, encoding: .utf8)
            var lines = config.components(separatedBy: "\n")

            // Find and update/remove the setting
            var found = false
            for i in 0..<lines.count {
                if lines[i].hasPrefix("\(key)=") {
                    if let value = value {
                        lines[i] = "\(key)=\(value)"
                    } else {
                        lines[i] = "# \(lines[i])" // Comment out
                    }
                    found = true
                    break
                }
            }

            // Add if not found
            if !found, let value = value {
                lines.append("\(key)=\(value)")
            }

            config = lines.joined(separator: "\n")
            try config.write(to: configPath, atomically: true, encoding: .utf8)
        } catch {
            print("⚠️ Failed to update config: \(error)")
        }
    }

    private func loadSettings() {
        isTorEnabled = UserDefaults.standard.bool(forKey: "fullNodeTorEnabled")
        isListening = UserDefaults.standard.object(forKey: "fullNodeListening") as? Bool ?? true
    }

    private func loadRecentErrors() {
        let debugLogPath = FullNodeManager.dataDir.appendingPathComponent("debug.log")
        guard FileManager.default.fileExists(atPath: debugLogPath.path) else { return }

        do {
            let log = try String(contentsOf: debugLogPath, encoding: .utf8)
            let lines = log.components(separatedBy: "\n")

            // Get last 100 lines and filter for errors
            recentErrors = lines.suffix(100)
                .filter { $0.lowercased().contains("error") || $0.lowercased().contains("warning") }
                .suffix(10)
                .reversed()
                .map { String($0) }
        } catch {
            // Ignore
        }
    }

    func openDebugLog() {
        let debugLogPath = FullNodeManager.dataDir.appendingPathComponent("debug.log")
        NSWorkspace.shared.open(debugLogPath)
    }

    func clearErrors() {
        recentErrors.removeAll()
    }
}

#endif
