import SwiftUI

#if os(macOS)
import AppKit

/// Node Management View for Full Node mode
/// Allows users to manage their local zclassicd daemon
struct NodeManagementView: View {
    @EnvironmentObject var themeManager: ThemeManager
    @StateObject private var viewModel = NodeManagementViewModel()
    @ObservedObject private var fullNodeManager = FullNodeManager.shared
    @ObservedObject private var bootstrapManager = BootstrapManager.shared  // FIX #316: Watch bootstrap status
    @Environment(\.dismiss) private var dismiss

    private var theme: AppTheme { themeManager.currentTheme }

    /// Check if daemon is in a startup/syncing state (prevents duplicate starts)
    /// FIX #316: Also check if bootstrap is starting/syncing the daemon
    private var isDaemonBusy: Bool {
        // Check FullNodeManager status
        switch fullNodeManager.daemonStatus {
        case .starting, .syncing:
            return true
        default:
            break
        }

        // FIX #316: Check if bootstrap is starting or syncing the daemon
        switch bootstrapManager.status {
        case .startingDaemon, .syncingBlocks:
            return true
        default:
            break
        }

        return viewModel.isOperationInProgress
    }

    /// FIX #316: Check if daemon is actually running (from any source)
    private var isDaemonRunning: Bool {
        // Check FullNodeManager
        if fullNodeManager.daemonStatus.isRunning {
            return true
        }

        // Check if bootstrap completed with daemon running
        switch bootstrapManager.status {
        case .complete, .syncingBlocks:
            return true
        default:
            return false
        }
    }

    /// FIX #316: Get status text when daemon is busy
    private var daemonBusyStatusText: String {
        // Check bootstrap status first (more specific)
        switch bootstrapManager.status {
        case .startingDaemon:
            return "Starting daemon..."
        case .syncingBlocks(let progress, _):
            return "Syncing blocks (\(Int(progress * 100))%)..."
        default:
            break
        }

        // Check FullNodeManager status
        switch fullNodeManager.daemonStatus {
        case .starting:
            return "Starting daemon..."
        case .syncing(let progress):
            return "Syncing (\(Int(progress * 100))%)..."
        default:
            break
        }

        // Fallback
        return "Daemon busy..."
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Header
                headerSection

                // FIX #306: Prerequisites warning section (shows only when something is missing)
                if !viewModel.prerequisitesStatus.allMet {
                    prerequisitesWarningSection
                }

                // Daemon Status & Control
                daemonControlSection

                // Node Info (with N/A values when prerequisites missing)
                nodeInfoSection

                // Bootstrap Management
                bootstrapSection

                // Backup Management
                backupSection

                // Configuration Editor
                configurationSection

                // Wallet Security Check
                walletSecuritySection

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
            // FIX #320: Always refresh prerequisites and state on appear
            viewModel.checkPrerequisites()
            viewModel.refresh()
        }
        // FIX #320: Refresh when bootstrap status changes
        .onChange(of: bootstrapManager.status) { newStatus in
            // Refresh when bootstrap completes or changes
            switch newStatus {
            case .complete, .completeNeedsDaemon, .completeDaemonStopped, .syncingBlocks:
                viewModel.checkPrerequisites()
                viewModel.refresh()
            default:
                break
            }
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

    // MARK: - Prerequisites Warning Section (FIX #306)

    private var prerequisitesWarningSection: some View {
        VStack(spacing: 12) {
            sectionHeader(icon: "exclamationmark.triangle.fill", title: "PREREQUISITES MISSING")

            VStack(alignment: .leading, spacing: 12) {
                Text("The following components are required to run a Full Node:")
                    .font(theme.bodyFont)
                    .foregroundColor(theme.textPrimary)

                ForEach(viewModel.prerequisitesStatus.missingItems, id: \.self) { item in
                    HStack(spacing: 8) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.red)
                            .font(.system(size: 14))
                        Text(item)
                            .font(theme.captionFont)
                            .foregroundColor(.red)
                    }
                }

                Divider()

                // Show what IS installed (green checkmarks)
                if viewModel.prerequisitesStatus.daemonInstalled {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.system(size: 14))
                        Text("Zclassic daemon (zclassicd)")
                            .font(theme.captionFont)
                            .foregroundColor(.green)
                    }
                }
                if viewModel.prerequisitesStatus.blockchainExists {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.system(size: 14))
                        Text("Blockchain data")
                            .font(theme.captionFont)
                            .foregroundColor(.green)
                    }
                }
                if viewModel.prerequisitesStatus.zcashParamsExist {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.system(size: 14))
                        Text("Zcash parameters")
                            .font(theme.captionFont)
                            .foregroundColor(.green)
                    }
                }
                if viewModel.prerequisitesStatus.zstdInstalled {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.system(size: 14))
                        Text("zstd")
                            .font(theme.captionFont)
                            .foregroundColor(.green)
                    }
                }

                Divider()

                // Installation instructions
                VStack(alignment: .leading, spacing: 8) {
                    Text("How to Install:")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(theme.textPrimary)

                    if !viewModel.prerequisitesStatus.zstdInstalled {
                        // zstd must be installed first (required for bootstrap)
                        installInstructionRow(
                            title: "Step 1 - Install zstd (required):",
                            command: "brew install zstd"
                        )
                        installInstructionRow(
                            title: "Step 2 - Install everything else:",
                            command: "Use 'Install Fresh Bootstrap' button below"
                        )
                    } else {
                        // zstd is installed, bootstrap will handle everything
                        installInstructionRow(
                            title: "One-click install:",
                            command: "Use 'Install Fresh Bootstrap' button below"
                        )
                        Text("This will automatically install the daemon, Zcash parameters, and blockchain data.")
                            .font(.system(size: 10))
                            .foregroundColor(theme.textSecondary)
                            .padding(.top, 4)
                    }
                }
                .padding(10)
                .background(theme.backgroundColor)
                .cornerRadius(6)
            }
            .padding(12)
            .background(Color.orange.opacity(0.1))
            .overlay(Rectangle().stroke(Color.orange, lineWidth: 2))
        }
    }

    private func installInstructionRow(title: String, command: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(theme.captionFont)
                .foregroundColor(theme.textSecondary)
            Text(command)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(theme.primaryColor)
        }
    }

    // MARK: - Daemon Control

    private var daemonControlSection: some View {
        VStack(spacing: 12) {
            sectionHeader(icon: "power", title: "DAEMON CONTROL")

            HStack(spacing: 16) {
                // Status indicator - uses persistent FullNodeManager status
                HStack(spacing: 8) {
                    Circle()
                        .fill(daemonStatusColor)
                        .frame(width: 12, height: 12)

                    Text(daemonStatusText)
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundColor(daemonStatusColor)
                }

                Spacer()

                // Control buttons - disabled when daemon is busy (starting/syncing)
                // FIX #316: Show warning if daemon not installed instead of Start button
                // FIX #316: Also handle bootstrap starting daemon
                if !viewModel.prerequisitesStatus.daemonInstalled {
                    // No daemon installed - show warning
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text("Daemon not installed")
                            .font(theme.bodyFont)
                            .foregroundColor(.orange)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.orange.opacity(0.15))
                    .cornerRadius(theme.cornerRadius)
                } else if isDaemonBusy {
                    // FIX #316: Daemon is starting/syncing - show status
                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text(daemonBusyStatusText)
                            .font(theme.bodyFont)
                            .foregroundColor(theme.textSecondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(theme.surfaceColor)
                    .cornerRadius(theme.cornerRadius)
                } else if isDaemonRunning {
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
                    .disabled(isDaemonBusy)
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
                        .background(isDaemonBusy ? Color.gray : Color.green)
                        .cornerRadius(theme.cornerRadius)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .disabled(isDaemonBusy)
                }
            }
            .padding(12)
            .background(theme.surfaceColor)
            .overlay(Rectangle().stroke(theme.textPrimary.opacity(0.3), lineWidth: 1))

            // Operation status with progress bar - shows from ViewModel OR FullNodeManager
            if viewModel.isOperationInProgress || isSyncingFromManager {
                VStack(spacing: 8) {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text(currentOperationStatus)
                            .font(theme.captionFont)
                            .foregroundColor(theme.textSecondary)
                        Spacer()
                        Text("\(Int(currentOperationProgress * 100))%")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundColor(theme.accentColor)
                    }

                    // Progress bar
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            // Background
                            RoundedRectangle(cornerRadius: 4)
                                .fill(theme.surfaceColor)
                                .frame(height: 8)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4)
                                        .stroke(theme.textPrimary.opacity(0.3), lineWidth: 1)
                                )

                            // Progress fill
                            RoundedRectangle(cornerRadius: 4)
                                .fill(
                                    LinearGradient(
                                        colors: [theme.accentColor, theme.accentColor.opacity(0.7)],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(width: geometry.size.width * currentOperationProgress, height: 8)
                                .animation(.easeInOut(duration: 0.3), value: currentOperationProgress)
                        }
                    }
                    .frame(height: 8)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(theme.backgroundColor.opacity(0.5))
                .overlay(Rectangle().stroke(theme.accentColor.opacity(0.3), lineWidth: 1))
            }
        }
    }

    // MARK: - Daemon Status Helpers

    /// Color for daemon status indicator
    private var daemonStatusColor: Color {
        switch fullNodeManager.daemonStatus {
        case .running:
            return .green
        case .syncing:
            return .orange
        case .starting:
            return .yellow
        case .error:
            return .red
        default:
            return .red
        }
    }

    /// Text for daemon status indicator
    private var daemonStatusText: String {
        switch fullNodeManager.daemonStatus {
        case .running:
            return "RUNNING"
        case .syncing(let progress):
            return "SYNCING (\(Int(progress * 100))%)"
        case .starting:
            return "STARTING..."
        case .stopped, .installed:
            return "STOPPED"
        case .error(let msg):
            return "ERROR: \(msg.prefix(20))"
        default:
            return "STOPPED"
        }
    }

    /// Check if FullNodeManager is syncing (but ViewModel isn't tracking it)
    private var isSyncingFromManager: Bool {
        switch fullNodeManager.daemonStatus {
        case .starting, .syncing:
            return true
        default:
            return false
        }
    }

    /// Current operation status - prefers ViewModel, falls back to FullNodeManager
    private var currentOperationStatus: String {
        if viewModel.isOperationInProgress && !viewModel.operationStatus.isEmpty {
            return viewModel.operationStatus
        }
        switch fullNodeManager.daemonStatus {
        case .starting:
            return "Starting daemon..."
        case .syncing(let progress):
            return "Syncing blockchain... \(Int(progress * 100))% (block \(fullNodeManager.daemonBlockHeight))"
        default:
            return viewModel.operationStatus
        }
    }

    /// Current operation progress - prefers ViewModel, falls back to FullNodeManager
    private var currentOperationProgress: Double {
        if viewModel.isOperationInProgress && viewModel.operationProgress > 0 {
            return viewModel.operationProgress
        }
        switch fullNodeManager.daemonStatus {
        case .starting:
            return 0.2
        case .syncing(let progress):
            // Map sync progress (0-1) to progress bar (0.3-0.95)
            return 0.3 + (progress * 0.65)
        default:
            return viewModel.operationProgress
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
        // FIX #276: Show bootstrap progress sheet
        .sheet(isPresented: $viewModel.showBootstrapProgress) {
            BootstrapProgressView()
                .environmentObject(themeManager)
                .frame(minWidth: 500, minHeight: 400)
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

    // MARK: - Configuration Section

    private var configurationSection: some View {
        VStack(spacing: 12) {
            sectionHeader(icon: "doc.text", title: "CONFIGURATION EDITOR")

            VStack(spacing: 12) {
                // Warning banner
                if viewModel.configHasUnsavedChanges {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text("Unsaved changes - restart daemon to apply")
                            .font(theme.captionFont)
                            .foregroundColor(.orange)
                        Spacer()
                    }
                    .padding(8)
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(4)
                }

                // Network Settings Group
                configGroupHeader(title: "Network")
                configRow(key: "port", label: "P2P Port", value: $viewModel.configPort, description: "Port for P2P connections")
                configRow(key: "maxconnections", label: "Max Connections", value: $viewModel.configMaxConnections, description: "Maximum peer connections")
                configToggleRow(key: "listen", label: "Accept Connections", isOn: $viewModel.configListen, description: "Allow incoming P2P connections")

                Divider()

                // RPC Settings Group
                configGroupHeader(title: "RPC Server")
                configToggleRow(key: "server", label: "Enable RPC", isOn: $viewModel.configServer, description: "Enable JSON-RPC server")
                configRow(key: "rpcport", label: "RPC Port", value: $viewModel.configRpcPort, description: "Port for RPC connections")
                configRow(key: "rpcthreads", label: "RPC Threads", value: $viewModel.configRpcThreads, description: "Number of RPC worker threads")

                Divider()

                // Performance Settings Group
                configGroupHeader(title: "Performance")
                configRow(key: "dbcache", label: "DB Cache (MB)", value: $viewModel.configDbCache, description: "Database cache size in megabytes")
                configRow(key: "par", label: "Script Threads", value: $viewModel.configPar, description: "Parallel script verification threads")
                configToggleRow(key: "txindex", label: "Transaction Index", isOn: $viewModel.configTxIndex, description: "Maintain full tx index (required for address lookup)")

                Divider()

                // Privacy Settings Group
                configGroupHeader(title: "Privacy & Security")
                configToggleRow(key: "listenonion", label: "Listen on Tor", isOn: $viewModel.configListenOnion, description: "Accept connections via Tor network")
                configToggleRow(key: "gen", label: "Mining Enabled", isOn: $viewModel.configGen, description: "Enable CPU mining (not recommended)")

                Divider()

                // Debug Settings Group
                configGroupHeader(title: "Debugging")
                configToggleRow(key: "debug", label: "Debug Logging", isOn: $viewModel.configDebug, description: "Enable verbose debug.log output")

                Divider()

                // Action buttons
                HStack(spacing: 12) {
                    Button(action: { viewModel.reloadConfig() }) {
                        HStack {
                            Image(systemName: "arrow.clockwise")
                            Text("Reload")
                        }
                        .font(theme.captionFont)
                        .foregroundColor(theme.textSecondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .overlay(Rectangle().stroke(theme.textSecondary.opacity(0.5), lineWidth: 1))
                    }
                    .buttonStyle(PlainButtonStyle())

                    Button(action: { viewModel.saveConfig() }) {
                        HStack {
                            Image(systemName: "checkmark.circle")
                            Text("Save Changes")
                        }
                        .font(theme.captionFont)
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(viewModel.configHasUnsavedChanges ? theme.primaryColor : theme.textSecondary.opacity(0.5))
                        .cornerRadius(theme.cornerRadius)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .disabled(!viewModel.configHasUnsavedChanges)

                    Spacer()

                    Button(action: { viewModel.openConfigInEditor() }) {
                        HStack {
                            Image(systemName: "doc.text.magnifyingglass")
                            Text("Open in Editor")
                        }
                        .font(theme.captionFont)
                        .foregroundColor(theme.primaryColor)
                    }
                    .buttonStyle(PlainButtonStyle())
                }

                // Config file location
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                        .font(.system(size: 10))
                    Text(FullNodeManager.configPath.path)
                        .font(.system(size: 10, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .foregroundColor(theme.textSecondary)
            }
            .padding(12)
            .background(theme.surfaceColor)
            .overlay(Rectangle().stroke(theme.textPrimary.opacity(0.3), lineWidth: 1))
        }
    }

    private func configGroupHeader(title: String) -> some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(theme.primaryColor)
            Spacer()
        }
        .padding(.top, 4)
    }

    private func configRow(key: String, label: String, value: Binding<String>, description: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(theme.bodyFont)
                    .foregroundColor(theme.textPrimary)
                Text(description)
                    .font(.system(size: 10))
                    .foregroundColor(theme.textSecondary)
            }

            Spacer()

            TextField("", text: value)
                .textFieldStyle(PlainTextFieldStyle())
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(theme.textPrimary)
                .frame(width: 100)
                .padding(6)
                .background(theme.backgroundColor)
                .overlay(Rectangle().stroke(theme.textSecondary.opacity(0.3), lineWidth: 1))
                .onChange(of: value.wrappedValue) { _ in
                    viewModel.markConfigChanged()
                }
        }
        .padding(.vertical, 4)
    }

    private func configToggleRow(key: String, label: String, isOn: Binding<Bool>, description: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(theme.bodyFont)
                    .foregroundColor(theme.textPrimary)
                Text(description)
                    .font(.system(size: 10))
                    .foregroundColor(theme.textSecondary)
            }

            Spacer()

            Toggle("", isOn: isOn)
                .toggleStyle(SwitchToggleStyle(tint: theme.primaryColor))
                .onChange(of: isOn.wrappedValue) { _ in
                    viewModel.markConfigChanged()
                }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Wallet Security Section

    private var walletSecuritySection: some View {
        VStack(spacing: 12) {
            sectionHeader(icon: "lock.shield.fill", title: "WALLET SECURITY")

            VStack(spacing: 12) {
                // wallet.dat status
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Image(systemName: viewModel.walletDatExists ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundColor(viewModel.walletDatExists ? .green : .red)
                            Text("wallet.dat")
                                .font(theme.bodyFont)
                                .foregroundColor(theme.textPrimary)
                        }

                        if viewModel.walletDatExists {
                            Text("Size: \(viewModel.walletDatSize) • Modified: \(viewModel.walletDatAge)")
                                .font(theme.captionFont)
                                .foregroundColor(theme.textSecondary)
                        } else {
                            Text("No wallet file found")
                                .font(theme.captionFont)
                                .foregroundColor(.orange)
                        }
                    }

                    Spacer()

                    if viewModel.walletDatExists {
                        // Encryption status badge
                        HStack(spacing: 4) {
                            Image(systemName: viewModel.isWalletEncrypted ? "lock.fill" : "lock.open.fill")
                            Text(viewModel.isWalletEncrypted ? "ENCRYPTED" : "UNENCRYPTED")
                        }
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(viewModel.isWalletEncrypted ? .green : .red)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(viewModel.isWalletEncrypted ? Color.green.opacity(0.2) : Color.red.opacity(0.2))
                        .cornerRadius(4)
                    }
                }

                // Security warnings
                if !viewModel.walletSecurityWarnings.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(viewModel.walletSecurityWarnings, id: \.self) { warning in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                                    .font(.system(size: 12))
                                Text(warning)
                                    .font(theme.captionFont)
                                    .foregroundColor(.orange)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(10)
                    .background(Color.orange.opacity(0.1))
                    .overlay(Rectangle().stroke(Color.orange.opacity(0.3), lineWidth: 1))
                }

                // Security recommendations
                VStack(alignment: .leading, spacing: 8) {
                    Text("Security Checklist:")
                        .font(theme.captionFont)
                        .fontWeight(.bold)
                        .foregroundColor(theme.textPrimary)

                    securityCheckItem(
                        passed: viewModel.walletDatExists,
                        text: "wallet.dat exists"
                    )
                    securityCheckItem(
                        passed: viewModel.isWalletEncrypted,
                        text: "Wallet is encrypted"
                    )
                    securityCheckItem(
                        passed: viewModel.hasRecentBackup,
                        text: "Recent backup (< 7 days)"
                    )
                    securityCheckItem(
                        passed: viewModel.walletDatAgeDays < 365,
                        text: "Wallet file not too old"
                    )
                }
                .padding(8)
                .background(theme.backgroundColor)
                .cornerRadius(4)

                Divider()

                // Actions
                HStack(spacing: 12) {
                    if viewModel.walletDatExists && !viewModel.isWalletEncrypted {
                        Button(action: { viewModel.showEncryptWalletAlert = true }) {
                            HStack {
                                Image(systemName: "lock.fill")
                                Text("Encrypt Wallet")
                            }
                            .font(theme.captionFont)
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.red)
                            .cornerRadius(theme.cornerRadius)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }

                    Button(action: { viewModel.backupWalletDat() }) {
                        HStack {
                            Image(systemName: "square.and.arrow.down")
                            Text("Backup Now")
                        }
                        .font(theme.captionFont)
                        .foregroundColor(theme.primaryColor)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .overlay(Rectangle().stroke(theme.primaryColor, lineWidth: 1))
                    }
                    .buttonStyle(PlainButtonStyle())
                    .disabled(!viewModel.walletDatExists)

                    Spacer()

                    Button(action: { viewModel.refreshWalletSecurity() }) {
                        HStack {
                            Image(systemName: "arrow.clockwise")
                            Text("Refresh")
                        }
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
        .alert("⚠️ Wallet Encryption - Experimental", isPresented: $viewModel.showEncryptWalletAlert) {
            Button("I Understand", role: .cancel) {}
        } message: {
            Text("""
            ╔═══════════════════════════════════════════════╗
            ║  "Privacy is necessary for an open society   ║
            ║   in the electronic age."                    ║
            ║        — A Cypherpunk's Manifesto, 1993      ║
            ╚═══════════════════════════════════════════════╝

            🔧 DEVELOPMENT STATUS:

            Wallet encryption via encryptwallet RPC is currently experimental and NOT fully tested with Zclassic shielded (z-addresses).

            Known limitations:
            • z_sendmany may fail with encrypted wallets
            • z-address key encryption is complex
            • Passphrase recovery is IMPOSSIBLE

            RECOMMENDATION:
            For now, protect your wallet.dat by:
            1. Storing it on an encrypted disk
            2. Using FileVault (macOS)
            3. Keeping secure offline backups

            Full wallet encryption support for z-addresses is planned for a future release.

            "We the Cypherpunks are dedicated to building anonymous systems."
            """)
        }
    }

    private func securityCheckItem(passed: Bool, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: passed ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundColor(passed ? .green : .red)
                .font(.system(size: 12))
            Text(text)
                .font(theme.captionFont)
                .foregroundColor(passed ? theme.textSecondary : .orange)
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
    // FIX #320: Reference to bootstrap manager to check daemon status
    private let bootstrapManager = BootstrapManager.shared

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
    @Published var operationProgress: Double = 0.0  // 0.0 to 1.0
    @Published var showBootstrapConfirm = false
    @Published var showBootstrapProgress = false  // FIX #276: Show progress view

    // FIX #306: Prerequisites check state
    @Published var prerequisitesStatus: PrerequisitesStatus = PrerequisitesStatus()

    struct PrerequisitesStatus {
        var daemonInstalled: Bool = false
        var blockchainExists: Bool = false
        var zcashParamsExist: Bool = false
        var zstdInstalled: Bool = false
        var configExists: Bool = false

        var allMet: Bool {
            daemonInstalled && blockchainExists && zcashParamsExist && zstdInstalled
        }

        var missingItems: [String] {
            var items: [String] = []
            if !daemonInstalled { items.append("Zclassic daemon (zclassicd)") }
            if !blockchainExists { items.append("Blockchain data") }
            if !zcashParamsExist { items.append("Zcash parameters (sapling-spend.params, sapling-output.params)") }
            if !zstdInstalled { items.append("zstd (required for bootstrap)") }
            return items
        }
    }

    // Configuration Editor properties
    @Published var configHasUnsavedChanges = false
    @Published var configPort = "8033"
    @Published var configMaxConnections = "125"
    @Published var configListen = true
    @Published var configServer = true
    @Published var configRpcPort = "8023"
    @Published var configRpcThreads = "48"
    @Published var configDbCache = "4096"
    @Published var configPar = "8"
    @Published var configTxIndex = true
    @Published var configListenOnion = true
    @Published var configGen = false
    @Published var configDebug = false

    // Wallet Security properties
    @Published var walletDatSize = "Unknown"
    @Published var walletDatAge = "Unknown"
    @Published var walletDatAgeDays: Int = 0
    @Published var isWalletEncrypted = false
    @Published var hasRecentBackup = false
    @Published var walletSecurityWarnings: [String] = []
    @Published var showEncryptWalletAlert = false

    private var originalConfig: [String: String] = [:]
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
        loadConfig()
        refreshWalletSecurity()
        checkPrerequisites()  // FIX #306: Check prerequisites on init
    }

    func refresh() {
        checkPrerequisites()  // FIX #306: Check prerequisites on every refresh
        Task {
            await refreshAsync()
        }
    }

    // FIX #306: Check all Full Node prerequisites
    func checkPrerequisites() {
        var status = PrerequisitesStatus()

        // Check 1: Is zclassicd installed?
        let daemonPaths = ["/usr/local/bin/zclassicd", "/opt/homebrew/bin/zclassicd"]
        status.daemonInstalled = daemonPaths.contains { FileManager.default.fileExists(atPath: $0) }

        // Check 2: Is blockchain data present?
        let dataDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Zclassic")
        let blocksDir = dataDir.appendingPathComponent("blocks")
        status.blockchainExists = FileManager.default.fileExists(atPath: blocksDir.path)

        // Check 3: Is zclassic.conf present?
        let configPath = dataDir.appendingPathComponent("zclassic.conf")
        status.configExists = FileManager.default.fileExists(atPath: configPath.path)

        // Check 4: Are Zcash params present?
        let paramsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ZcashParams")
        let spendParams = paramsDir.appendingPathComponent("sapling-spend.params")
        let outputParams = paramsDir.appendingPathComponent("sapling-output.params")
        status.zcashParamsExist = FileManager.default.fileExists(atPath: spendParams.path) &&
                                   FileManager.default.fileExists(atPath: outputParams.path)

        // Check 5: Is zstd installed?
        let zstdPaths = ["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd", "/usr/bin/zstd"]
        status.zstdInstalled = zstdPaths.contains { FileManager.default.fileExists(atPath: $0) }

        prerequisitesStatus = status

        // FIX #315: Removed verbose logging
    }

    // FIX #320: Check if zclassicd process is actually running (not just RPC)
    func isZclassicdProcessRunning() -> Bool {
        let task = Process()
        task.launchPath = "/usr/bin/pgrep"
        task.arguments = ["-x", "zclassicd"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func refreshAsync() async {
        // First, tell FullNodeManager to refresh its status
        fullNodeManager.checkNodeStatus()

        // FIX #320: Also check prerequisites on every refresh
        checkPrerequisites()

        // Wait briefly for the status check to complete
        try? await Task.sleep(nanoseconds: 500_000_000) // 500ms

        // Get blockchain size from FullNodeManager
        blockchainSize = fullNodeManager.blockchainSize

        // Check wallet.dat
        walletDatExists = FileManager.default.fileExists(atPath: FullNodeManager.walletPath.path)

        // FIX #320: Check if process is running first
        let processRunning = isZclassicdProcessRunning()

        // Try to load RPC config and check connection directly
        do {
            try RPCClient.shared.loadConfig()
            let connected = await RPCClient.shared.checkConnection()
            // FIX #320: Daemon is running if RPC works OR if process exists
            isDaemonRunning = connected || processRunning

            if connected {
                // Get blockchain info (has verificationprogress)
                do {
                    let blockchainInfo = try await RPCClient.shared.getBlockchainInfo()

                    // Block height from getblockchaininfo
                    if let blocks = blockchainInfo["blocks"] as? Int {
                        blockHeight = UInt64(blocks)
                        // blockHeight updated
                    }

                    // Sync progress from getblockchaininfo
                    // verificationprogress can be < 1.0 during initial block download (IBD)
                    // but for a fully synced node with all blocks, we check if it's close to 1.0
                    // Also check if headers == blocks (fully synced)
                    let headers = blockchainInfo["headers"] as? Int ?? 0
                    let blocks = blockchainInfo["blocks"] as? Int ?? 0

                    if headers > 0 && blocks > 0 && headers == blocks {
                        // All blocks downloaded - fully synced
                        syncProgress = 1.0
                        // syncProgress = 1.0
                    } else if let progress = blockchainInfo["verificationprogress"] as? Double {
                        // Still syncing/verifying - use verification progress
                        syncProgress = progress
                        // syncProgress updated
                    } else {
                        syncProgress = 1.0 // Assume fully synced if no progress reported
                    }
                } catch {
                    // getblockchaininfo failed, trying getinfo
                    // Fallback to getinfo
                    let info = try await RPCClient.shared.getInfoDict()
                    if let blocks = info["blocks"] as? Int {
                        blockHeight = UInt64(blocks)
                    }
                    syncProgress = 1.0
                }

                // Get network info (has connections)
                do {
                    let networkInfo = try await RPCClient.shared.getNetworkInfo()

                    // Connection count from getnetworkinfo
                    if let connections = networkInfo["connections"] as? Int {
                        connectionCount = connections
                        // connections updated
                    } else {
                        connectionCount = 0
                    }
                } catch {
                    // getnetworkinfo failed, trying getinfo
                    // Fallback to getinfo for connections
                    do {
                        let info = try await RPCClient.shared.getInfoDict()
                        if let connections = info["connections"] as? Int {
                            connectionCount = connections
                        }
                    } catch {
                        connectionCount = 0
                    }
                }
            } else {
                // Daemon not running
                blockHeight = 0
                syncProgress = 0
                connectionCount = 0
            }
        } catch {
            // RPC error - but daemon might still be running (just starting up)
            // FIX #320: Check process status even if RPC fails
            isDaemonRunning = processRunning
            if !processRunning {
                blockHeight = 0
                syncProgress = 0
                connectionCount = 0
            }
        }

        // Get version (if installed)
        if fullNodeManager.isDaemonInstalledAtPath {
            daemonVersion = await fullNodeManager.getDaemonVersion()
        } else {
            daemonVersion = nil
        }

        // Load recent errors from debug.log
        loadRecentErrors()
    }

    func startDaemon() {
        // GUARD: Prevent starting if daemon is already starting/syncing/running
        switch fullNodeManager.daemonStatus {
        case .starting:
            // Daemon is already starting
            return
        case .syncing(let progress):
            // Daemon is syncing
            return
        case .running:
            // Daemon is already running
            return
        default:
            break
        }

        // FIX #320: Also check if bootstrap is running/completed with daemon
        switch bootstrapManager.status {
        case .startingDaemon, .syncingBlocks, .complete:
            print("⚠️ FIX #320: Daemon already started by bootstrap - ignoring start request")
            return
        default:
            break
        }

        // FIX #320: Check if zclassicd process is actually running
        if isZclassicdProcessRunning() {
            print("⚠️ FIX #320: zclassicd process already running - ignoring start request")
            return
        }

        // Also check if an operation is already in progress
        guard !isOperationInProgress else {
            // Operation already in progress
            return
        }

        isOperationInProgress = true
        operationProgress = 0.0
        operationStatus = "Initializing..."

        Task {
            do {
                // Step 1: Check prerequisites
                await MainActor.run {
                    operationProgress = 0.05
                    operationStatus = "Checking configuration..."
                }
                try await Task.sleep(nanoseconds: 300_000_000)

                // Step 2: Start daemon process
                await MainActor.run {
                    operationProgress = 0.1
                    operationStatus = "Launching zclassicd..."
                }

                // Launch daemon
                let process = Process()
                process.executableURL = FullNodeManager.daemonPath
                process.arguments = ["-daemon"]
                try process.run()

                // Step 3: Wait for RPC to become available
                await MainActor.run {
                    operationProgress = 0.15
                    operationStatus = "Waiting for RPC interface..."
                }

                var connected = false
                for i in 1...30 {
                    try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second

                    // Update progress (0.15 to 0.3 during RPC connection)
                    let progress = 0.15 + (Double(i) / 30.0) * 0.15
                    await MainActor.run {
                        operationProgress = min(progress, 0.3)
                        operationStatus = "Connecting to daemon... (\(i)s)"
                    }

                    if await RPCClient.shared.checkConnection() {
                        connected = true
                        break
                    }
                }

                if !connected {
                    throw FullNodeError.startupTimeout
                }

                // Step 4: Wait for daemon to be FULLY SYNCED (100%)
                await MainActor.run {
                    operationProgress = 0.3
                    operationStatus = "Waiting for blockchain to load..."
                }

                // Poll sync status every 2 seconds, up to 10 minutes
                for attempt in 1...300 {
                    do {
                        let info = try await RPCClient.shared.getBlockchainInfo()

                        // Get sync progress and block info
                        let headers = info["headers"] as? Int ?? 0
                        let blocks = info["blocks"] as? Int ?? 0

                        // Note: Zclassic doesn't have initialblockdownload field
                        // verificationprogress is unreliable (can be 65% even when fully synced)
                        // The only reliable check is blocks == headers

                        // Calculate true sync progress based on blocks/headers ratio
                        let trueSyncProgress: Double
                        if headers > 0 {
                            trueSyncProgress = Double(blocks) / Double(headers)
                        } else {
                            let verificationProgress = info["verificationprogress"] as? Double ?? 0.0
                            trueSyncProgress = verificationProgress
                        }

                        // Update UI with sync progress
                        // Progress bar: 0.3 to 0.95 based on true sync progress
                        let displayProgress = 0.3 + (trueSyncProgress * 0.65)
                        let syncPercent = Int(trueSyncProgress * 100)

                        await MainActor.run {
                            operationProgress = min(displayProgress, 0.95)
                            blockHeight = UInt64(blocks)
                            syncProgress = trueSyncProgress

                            if headers == 0 {
                                // No headers yet - still loading index
                                operationStatus = "Loading block index..."
                            } else if blocks < headers {
                                // Still downloading/verifying blocks
                                operationStatus = "Syncing blockchain... \(syncPercent)% (block \(blocks)/\(headers))"
                            } else {
                                // blocks == headers - synced
                                operationStatus = "Finalizing..."
                            }
                        }

                        // Log progress every 30 seconds (15 attempts × 2s)
                        if attempt % 15 == 0 {
                            // Daemon sync progress logged every 30s
                        }

                        // Check if fully synced: headers > 0 AND blocks == headers
                        let isFullySynced = headers > 0 && headers == blocks

                        if isFullySynced {
                            // FULLY SYNCED!
                            await MainActor.run {
                                operationProgress = 0.98
                                operationStatus = "Blockchain fully synced!"
                                syncProgress = 1.0
                            }
                            try await Task.sleep(nanoseconds: 500_000_000)
                            break
                        }

                    } catch {
                        // Error checking sync - might still be loading block index
                        // Error checking sync status
                        await MainActor.run {
                            operationStatus = "Loading block index..."
                        }
                    }

                    try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
                }

                // Step 5: Complete - daemon is fully synced and ready!
                await MainActor.run {
                    operationProgress = 1.0
                    operationStatus = "Daemon fully synced and ready!"
                    isDaemonRunning = true
                    syncProgress = 1.0
                }
                try await Task.sleep(nanoseconds: 1_000_000_000)

                await MainActor.run {
                    isOperationInProgress = false
                    operationStatus = ""
                    operationProgress = 0.0
                }
                refresh()

            } catch {
                await MainActor.run {
                    isOperationInProgress = false
                    operationStatus = ""
                    operationProgress = 0.0
                    recentErrors.insert("Failed to start daemon: \(error.localizedDescription)", at: 0)
                }
            }
        }
    }

    func stopDaemon() {
        isOperationInProgress = true
        operationProgress = 0.0
        operationStatus = "Initiating shutdown..."

        Task {
            do {
                // Step 1: Send stop command
                await MainActor.run {
                    operationProgress = 0.1
                    operationStatus = "Sending stop signal..."
                }

                // Use zclassic-cli stop
                let process = Process()
                process.executableURL = FullNodeManager.cliPath
                process.arguments = ["stop"]
                try process.run()
                process.waitUntilExit()

                await MainActor.run {
                    operationProgress = 0.2
                    operationStatus = "Waiting for daemon to shutdown..."
                }

                // Step 2: Wait for daemon to stop (with progress)
                var stopped = false
                for i in 1...30 {
                    try await Task.sleep(nanoseconds: 1_000_000_000)

                    // Update progress (0.2 to 0.9 over 30 seconds)
                    let progress = 0.2 + (Double(i) / 30.0) * 0.7
                    await MainActor.run {
                        operationProgress = min(progress, 0.9)
                        operationStatus = "Shutting down... (\(i)s)"
                    }

                    if !(await RPCClient.shared.checkConnection()) {
                        stopped = true
                        break
                    }
                }

                // Step 3: Verify shutdown
                await MainActor.run {
                    operationProgress = 0.95
                    operationStatus = "Verifying shutdown..."
                }
                try await Task.sleep(nanoseconds: 500_000_000)

                // Step 4: Complete
                await MainActor.run {
                    operationProgress = 1.0
                    operationStatus = stopped ? "Daemon stopped successfully!" : "Shutdown complete"
                    isDaemonRunning = false
                }
                try await Task.sleep(nanoseconds: 500_000_000)

                await MainActor.run {
                    isOperationInProgress = false
                    operationStatus = ""
                    operationProgress = 0.0
                }

            } catch {
                await MainActor.run {
                    isOperationInProgress = false
                    operationStatus = ""
                    operationProgress = 0.0
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
                    // Backed up wallet.dat
                }

                // 3. Start bootstrap download via BootstrapManager
                await MainActor.run {
                    operationStatus = "Starting bootstrap download..."
                    isOperationInProgress = false
                    // FIX #276: Show the bootstrap progress view
                    showBootstrapProgress = true
                }

                // FIX #276: Actually start the bootstrap download
                await BootstrapManager.shared.startBootstrap()

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
            // Failed to update config
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

    // MARK: - Configuration Management

    func loadConfig() {
        let configPath = FullNodeManager.configPath
        guard FileManager.default.fileExists(atPath: configPath.path) else { return }

        do {
            let config = try String(contentsOf: configPath, encoding: .utf8)
            var configDict: [String: String] = [:]

            for line in config.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

                if let equalIndex = trimmed.firstIndex(of: "=") {
                    let key = String(trimmed[..<equalIndex]).trimmingCharacters(in: .whitespaces)
                    let value = String(trimmed[trimmed.index(after: equalIndex)...]).trimmingCharacters(in: .whitespaces)
                    configDict[key] = value
                }
            }

            // Store original for change detection
            originalConfig = configDict

            // Load into UI properties
            configPort = configDict["port"] ?? "8033"
            configMaxConnections = configDict["maxconnections"] ?? "125"
            configListen = configDict["listen"] != "0"
            configServer = configDict["server"] != "0"
            configRpcPort = configDict["rpcport"] ?? "8023"
            configRpcThreads = configDict["rpcthreads"] ?? "4"
            configDbCache = configDict["dbcache"] ?? "450"
            configPar = configDict["par"] ?? "-1"
            configTxIndex = configDict["txindex"] == "1"
            configListenOnion = configDict["listenonion"] != "0"
            configGen = configDict["gen"] == "1"
            configDebug = configDict["debug"] == "1"

            configHasUnsavedChanges = false
        } catch {
            // Failed to load config
        }
    }

    func reloadConfig() {
        loadConfig()
    }

    func markConfigChanged() {
        // Check if any values differ from original
        let currentValues: [String: String] = [
            "port": configPort,
            "maxconnections": configMaxConnections,
            "listen": configListen ? "1" : "0",
            "server": configServer ? "1" : "0",
            "rpcport": configRpcPort,
            "rpcthreads": configRpcThreads,
            "dbcache": configDbCache,
            "par": configPar,
            "txindex": configTxIndex ? "1" : "0",
            "listenonion": configListenOnion ? "1" : "0",
            "gen": configGen ? "1" : "0",
            "debug": configDebug ? "1" : "0"
        ]

        configHasUnsavedChanges = currentValues.contains { key, value in
            originalConfig[key] != value
        }
    }

    func saveConfig() {
        let configPath = FullNodeManager.configPath
        guard FileManager.default.fileExists(atPath: configPath.path) else { return }

        do {
            // Create backup before saving
            let backupDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("ZipherX_Backups")
                .appendingPathComponent("configs")

            try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)

            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyyMMdd_HHmmss"
            let timestamp = dateFormatter.string(from: Date())

            let backupPath = backupDir.appendingPathComponent("zclassic_\(timestamp).conf")
            try FileManager.default.copyItem(at: configPath, to: backupPath)
            // Config backup saved

            // Read existing config
            var config = try String(contentsOf: configPath, encoding: .utf8)
            var lines = config.components(separatedBy: "\n")

            // Helper to update or add a setting
            func updateSetting(_ key: String, _ value: String) {
                var found = false
                for i in 0..<lines.count {
                    let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("\(key)=") || trimmed.hasPrefix("# \(key)=") {
                        lines[i] = "\(key)=\(value)"
                        found = true
                        break
                    }
                }
                if !found {
                    // Add at the end before any addnode entries
                    var insertIndex = lines.count
                    for i in 0..<lines.count {
                        if lines[i].hasPrefix("addnode=") {
                            insertIndex = i
                            break
                        }
                    }
                    lines.insert("\(key)=\(value)", at: insertIndex)
                }
            }

            // Update all settings
            updateSetting("port", configPort)
            updateSetting("maxconnections", configMaxConnections)
            updateSetting("listen", configListen ? "1" : "0")
            updateSetting("server", configServer ? "1" : "0")
            updateSetting("rpcport", configRpcPort)
            updateSetting("rpcthreads", configRpcThreads)
            updateSetting("dbcache", configDbCache)
            updateSetting("par", configPar)
            updateSetting("txindex", configTxIndex ? "1" : "0")
            updateSetting("listenonion", configListenOnion ? "1" : "0")
            updateSetting("gen", configGen ? "1" : "0")
            updateSetting("debug", configDebug ? "1" : "0")
            // IMPORTANT: Zclassic requires debuglogfile=1 to actually write to debug.log
            // (disabled by default for privacy in Zclassic source)
            updateSetting("debuglogfile", configDebug ? "1" : "0")

            config = lines.joined(separator: "\n")
            try config.write(to: configPath, atomically: true, encoding: .utf8)

            // Update original values
            loadConfig()
            configHasUnsavedChanges = false

            // Show restart notification if daemon is running
            if isDaemonRunning {
                let alert = NSAlert()
                alert.messageText = "Configuration Saved"
                alert.informativeText = """
                Configuration changes have been saved.

                ⚠️ Restart the daemon for changes to take effect.

                Backup saved to:
                \(backupPath.path)
                """
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }

        } catch {
            recentErrors.insert("Failed to save config: \(error.localizedDescription)", at: 0)
        }
    }

    func openConfigInEditor() {
        NSWorkspace.shared.open(FullNodeManager.configPath)
    }

    // MARK: - Wallet Security

    func refreshWalletSecurity() {
        let walletPath = FullNodeManager.walletPath

        // Check if wallet.dat exists
        walletDatExists = FileManager.default.fileExists(atPath: walletPath.path)

        if walletDatExists {
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: walletPath.path)

                // Get file size
                if let size = attributes[.size] as? UInt64 {
                    walletDatSize = formatBytes(size)
                }

                // Get modification date
                if let modDate = attributes[.modificationDate] as? Date {
                    let formatter = RelativeDateTimeFormatter()
                    formatter.unitsStyle = .full
                    walletDatAge = formatter.localizedString(for: modDate, relativeTo: Date())

                    // Calculate days since modification
                    walletDatAgeDays = Calendar.current.dateComponents([.day], from: modDate, to: Date()).day ?? 0
                }

                // Check encryption status by looking for specific patterns in file header
                // Note: This is a heuristic - encrypted wallet.dat files have different structure
                checkWalletEncryption()

                // Check for recent backups
                checkForRecentBackups()

                // Generate security warnings
                generateSecurityWarnings()

            } catch {
                // Failed to get wallet.dat attributes
            }
        } else {
            walletDatSize = "N/A"
            walletDatAge = "N/A"
            walletDatAgeDays = 0
            isWalletEncrypted = false
            hasRecentBackup = false
            walletSecurityWarnings = ["No wallet.dat found - create or restore a wallet"]
        }
    }

    private func checkWalletEncryption() {
        // Query RPC if daemon is running
        if isDaemonRunning {
            Task {
                do {
                    let info = try await RPCClient.shared.getInfoDict()
                    // If "unlocked_until" key exists, wallet is encrypted
                    if info["unlocked_until"] != nil {
                        await MainActor.run {
                            isWalletEncrypted = true
                        }
                    } else {
                        // getInfoDict doesn't have wallet info, so just check if we got a response
                        // If daemon responds, assume wallet exists but encryption status unknown
                        // Use file-based heuristic as fallback
                        await MainActor.run {
                            checkWalletEncryptionFromFile()
                        }
                    }
                } catch {
                    // If RPC fails, try to detect from file
                    await MainActor.run {
                        checkWalletEncryptionFromFile()
                    }
                }
            }
        } else {
            checkWalletEncryptionFromFile()
        }
    }

    private func checkWalletEncryptionFromFile() {
        // When daemon is not running, check file header
        // BDB files have specific magic bytes, encrypted ones have different structure
        let walletPath = FullNodeManager.walletPath
        if let data = FileManager.default.contents(atPath: walletPath.path),
           data.count > 16 {
            // Check for encryption marker in Berkeley DB file
            // This is a heuristic - encrypted wallets typically have "encrypted" string
            let headerData = data.prefix(1024)
            if let headerString = String(data: headerData, encoding: .utf8),
               headerString.contains("encrypted") || headerString.contains("crypt") {
                isWalletEncrypted = true
            } else {
                isWalletEncrypted = false
            }
        } else {
            isWalletEncrypted = false
        }
    }

    private func checkForRecentBackups() {
        let backupDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("ZipherX_Backups")

        guard FileManager.default.fileExists(atPath: backupDir.path) else {
            hasRecentBackup = false
            return
        }

        do {
            let contents = try FileManager.default.contentsOfDirectory(at: backupDir, includingPropertiesForKeys: [URLResourceKey.contentModificationDateKey])
            let walletBackups = contents.filter { $0.lastPathComponent.hasPrefix("wallet_") && $0.pathExtension == "dat" }

            // Check if any backup is less than 7 days old
            let sevenDaysAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()

            for backup in walletBackups {
                let resourceValues = try backup.resourceValues(forKeys: [URLResourceKey.contentModificationDateKey])
                if let modDate = resourceValues.contentModificationDate,
                   modDate > sevenDaysAgo {
                    hasRecentBackup = true
                    return
                }
            }
            hasRecentBackup = false
        } catch {
            hasRecentBackup = false
        }
    }

    private func generateSecurityWarnings() {
        walletSecurityWarnings.removeAll()

        if !walletDatExists {
            walletSecurityWarnings.append("No wallet.dat found")
            return
        }

        if !isWalletEncrypted {
            walletSecurityWarnings.append("⚠️ CRITICAL: Your wallet is NOT encrypted! Anyone with access to this computer can steal your funds.")
        }

        if !hasRecentBackup {
            walletSecurityWarnings.append("No recent backup found. Consider backing up your wallet.dat regularly.")
        }

        if walletDatAgeDays > 365 {
            walletSecurityWarnings.append("Wallet file is over 1 year old. Consider creating a new wallet and transferring funds.")
        }

        if walletDatAgeDays > 30 && !hasRecentBackup {
            walletSecurityWarnings.append("Wallet has changed in the last month but no backup exists. Create a backup now!")
        }
    }

    func showEncryptInstructions() {
        // Copy command to clipboard
        let command = "zclassic-cli encryptwallet \"YOUR_PASSPHRASE_HERE\""
        // FIX #1360: TASK 12 — Use ClipboardManager with 60s expiry for commands
        ClipboardManager.copyWithAutoExpiry(command, seconds: 60)

        // Show terminal with instructions
        let script = """
        tell application "Terminal"
            activate
            do script "echo '=== WALLET ENCRYPTION ===' && echo '' && echo 'IMPORTANT: Make a backup of wallet.dat BEFORE encrypting!' && echo '' && echo 'Run this command (replace YOUR_PASSPHRASE_HERE with a strong passphrase):' && echo '' && echo 'zclassic-cli encryptwallet \"YOUR_PASSPHRASE_HERE\"' && echo '' && echo 'The command has been copied to your clipboard.' && echo 'The daemon will shut down after encryption.'"
        end tell
        """

        var error: NSDictionary?
        if let scriptObject = NSAppleScript(source: script) {
            scriptObject.executeAndReturnError(&error)
        }
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}

#endif
