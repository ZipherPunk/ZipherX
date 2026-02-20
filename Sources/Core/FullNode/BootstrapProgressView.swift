import SwiftUI

#if os(macOS)

/// Progress view for bootstrap download and setup
struct BootstrapProgressView: View {
    @EnvironmentObject var themeManager: ThemeManager
    @StateObject private var bootstrapManager = BootstrapManager.shared
    @Environment(\.dismiss) private var dismiss

    // FIX #285: Daemon installation state
    @State private var showDaemonInstallPrompt = false
    @State private var showBuildInstructions = false
    @State private var installError: String?
    @State private var isInstalling = false

    private var theme: AppTheme { themeManager.currentTheme }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView

            Divider()
                .background(theme.borderColor)

            // Content
            ScrollView {
                VStack(spacing: 24) {
                    // Status icon
                    statusIcon

                    // Progress info
                    progressInfo

                    // Progress bar
                    progressBar

                    // Task list
                    taskList

                    // Details - FIX #312: Also show when elapsed time is available
                    if !bootstrapManager.downloadSpeed.isEmpty || !bootstrapManager.eta.isEmpty || !bootstrapManager.elapsedTime.isEmpty {
                        downloadStats
                    }
                }
                .padding(24)
            }

            Divider()
                .background(theme.borderColor)

            // Footer
            footerView
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.backgroundColor)
        .onAppear {
            // FIX #1458: Auto-start on idle, and auto-retry on error/cancelled (when sheet re-opens)
            switch bootstrapManager.status {
            case .idle, .error, .cancelled:
                Task {
                    await bootstrapManager.startBootstrap()
                }
            default:
                break
            }
        }
    }

    private var headerView: some View {
        HStack {
            Image(systemName: "server.rack")
                .font(.system(size: 20))
                .foregroundColor(theme.primaryColor)

            Text("Full Node Setup")
                .font(theme.titleFont)
                .foregroundColor(theme.textPrimary)

            Spacer()
        }
        .padding()
        .background(theme.surfaceColor)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch bootstrapManager.status {
        case .complete:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundColor(theme.successColor)
        case .completeNeedsDaemon:
            // FIX #285: Bootstrap done but daemon not installed
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 64))
                .foregroundColor(theme.warningColor)
        case .completeDaemonStopped:
            // FIX #285: Bootstrap done, daemon exists but not running
            Image(systemName: "checkmark.circle.badge.xmark")
                .font(.system(size: 64))
                .foregroundColor(theme.warningColor)
        case .syncingBlocks:
            // FIX #285: Syncing remaining blocks
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 64))
                .foregroundColor(theme.primaryColor)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 64))
                .foregroundColor(theme.errorColor)
        case .cancelled:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 64))
                .foregroundColor(theme.warningColor)
        default:
            // Animated progress indicator
            ZStack {
                Circle()
                    .stroke(theme.borderColor, lineWidth: 4)
                    .frame(width: 64, height: 64)

                Circle()
                    .trim(from: 0, to: bootstrapManager.progress)
                    .stroke(theme.primaryColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .frame(width: 64, height: 64)
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.3), value: bootstrapManager.progress)

                Image(systemName: statusSystemImage)
                    .font(.system(size: 24))
                    .foregroundColor(theme.primaryColor)
            }
        }
    }

    private var statusSystemImage: String {
        switch bootstrapManager.status {
        case .checkingRelease:
            return "magnifyingglass"
        case .downloading:
            return "arrow.down.circle"
        case .verifying:
            return "checkmark.shield"
        case .combining:  // FIX #312
            return "doc.on.doc"
        case .extracting:
            return "archivebox"
        case .configuringDaemon:
            return "gearshape"
        case .downloadingParams:
            return "key"
        case .startingDaemon:  // FIX #312
            return "play.circle"
        default:
            return "server.rack"
        }
    }

    private var progressInfo: some View {
        VStack(spacing: 8) {
            Text(bootstrapManager.currentTask)
                .font(theme.bodyFont)
                .foregroundColor(theme.textPrimary)
                .multilineTextAlignment(.center)

            Text("\(Int(bootstrapManager.progress * 100))%")
                .font(.system(size: 32, weight: .bold, design: .monospaced))
                .foregroundColor(theme.primaryColor)
        }
    }

    private var progressBar: some View {
        // FIX #1459: Use ThemedProgressBar for consistent theme colors across all themes
        ThemedProgressBar(progress: bootstrapManager.progress)
            .padding(.horizontal, 40)
    }

    private var taskList: some View {
        VStack(alignment: .leading, spacing: 8) {
            // FIX #317: Show elapsed time for each task
            taskRow("Check for latest bootstrap", statusFor(.checkingRelease), elapsedTime: bootstrapManager.taskElapsedTimes["checkingRelease"])

            // FIX #312: Show parts progress during download
            if case .downloading = bootstrapManager.status {
                taskRowWithProgress("Download blockchain data (\(bootstrapManager.currentPart)/\(bootstrapManager.totalParts) parts)",
                                    .inProgress, bootstrapManager.progress * 2)  // Download is 0-50%
            } else {
                taskRow("Download blockchain data", statusFor(.downloading), elapsedTime: bootstrapManager.taskElapsedTimes["downloading"])
            }

            taskRow("Verify checksums", statusFor(.verifying), elapsedTime: bootstrapManager.taskElapsedTimes["verifying"])
            taskRow("Combine parts", statusFor(.combining), elapsedTime: bootstrapManager.taskElapsedTimes["combining"])  // FIX #312: Added combining step
            taskRow("Extract to data directory", statusFor(.extracting), elapsedTime: bootstrapManager.taskElapsedTimes["extracting"])
            taskRow("Configure zclassicd", statusFor(.configuringDaemon), elapsedTime: bootstrapManager.taskElapsedTimes["configuringDaemon"])
            taskRow("Download Sapling params", statusFor(.downloadingParams), elapsedTime: bootstrapManager.taskElapsedTimes["downloadingParams"])
            taskRow("Start daemon", statusFor(.startingDaemon), elapsedTime: bootstrapManager.taskElapsedTimes["startingDaemon"])

            // FIX #285: Show sync task if syncing remaining blocks
            if case .syncingBlocks(let progress, _) = bootstrapManager.status {
                taskRowWithProgress("Sync remaining blocks", .inProgress, progress)
            } else if bootstrapManager.blocksDelta > 0 {
                taskRow("Sync remaining blocks", .pending, elapsedTime: bootstrapManager.taskElapsedTimes["syncingBlocks"])
            }
        }
        .padding()
        .background(theme.surfaceColor)
        .overlay(
            RoundedRectangle(cornerRadius: theme.cornerRadius)
                .stroke(theme.borderColor, lineWidth: 1)
        )
        .cornerRadius(theme.cornerRadius)
    }

    // FIX #285: Task row with progress percentage
    private func taskRowWithProgress(_ title: String, _ status: TaskStatus, _ progress: Double) -> some View {
        HStack(spacing: 12) {
            ProgressView()
                .scaleEffect(0.6)
                .frame(width: 16, height: 16)

            Text(title)
                .font(theme.bodyFont)
                .foregroundColor(theme.textPrimary)

            Spacer()

            Text("\(Int(progress * 100))%")
                .font(theme.monoFont)
                .foregroundColor(theme.primaryColor)
        }
    }

    // FIX #317: Added elapsedTime parameter to show task duration
    private func taskRow(_ title: String, _ status: TaskStatus, elapsedTime: String? = nil) -> some View {
        HStack(spacing: 12) {
            // Status icon
            Group {
                switch status {
                case .pending:
                    Circle()
                        .stroke(theme.borderColor, lineWidth: 2)
                        .frame(width: 16, height: 16)
                case .inProgress:
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 16, height: 16)
                case .completed:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(theme.successColor)
                        .frame(width: 16, height: 16)
                case .failed:
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(theme.errorColor)
                        .frame(width: 16, height: 16)
                }
            }

            Text(title)
                .font(theme.bodyFont)
                .foregroundColor(status == .inProgress ? theme.textPrimary : theme.textSecondary)

            Spacer()

            // FIX #317: Show elapsed time for completed tasks
            if let elapsed = elapsedTime, status == .completed {
                Text(elapsed)
                    .font(theme.monoFont)
                    .foregroundColor(theme.textSecondary)
            }
        }
    }

    private enum TaskStatus {
        case pending, inProgress, completed, failed
    }

    private func statusFor(_ checkStatus: BootstrapManager.BootstrapStatus) -> TaskStatus {
        // FIX #285 + FIX #312: Updated order to include combining and startingDaemon
        let order: [BootstrapManager.BootstrapStatus] = [
            .checkingRelease, .downloading, .verifying, .combining, .extracting, .configuringDaemon, .downloadingParams, .startingDaemon
        ]

        // FIX #1458: Handle error/cancelled states using lastStepBeforeError
        if case .error = bootstrapManager.status,
           let lastStep = bootstrapManager.lastStepBeforeError {
            guard let checkIndex = order.firstIndex(where: { $0 == checkStatus }),
                  let failedIndex = order.firstIndex(where: { statusMatches($0, lastStep) }) else {
                return .pending
            }
            if checkIndex < failedIndex { return .completed }
            if checkIndex == failedIndex { return .failed }
            return .pending
        }

        guard let checkIndex = order.firstIndex(where: { $0 == checkStatus }),
              let currentIndex = order.firstIndex(where: { statusMatches($0, bootstrapManager.status) }) else {
            // FIX #285: Handle completion states - all tasks before them are complete
            if case .complete = bootstrapManager.status { return .completed }
            if case .completeNeedsDaemon = bootstrapManager.status { return .completed }
            if case .completeDaemonStopped = bootstrapManager.status { return .completed }
            if case .syncingBlocks = bootstrapManager.status { return .completed }
            return .pending
        }

        if statusMatches(checkStatus, bootstrapManager.status) {
            return .inProgress
        } else if checkIndex < currentIndex {
            return .completed
        } else {
            return .pending
        }
    }

    private func statusMatches(_ a: BootstrapManager.BootstrapStatus, _ b: BootstrapManager.BootstrapStatus) -> Bool {
        switch (a, b) {
        case (.checkingRelease, .checkingRelease),
             (.downloading, .downloading),
             (.verifying, .verifying),
             (.combining, .combining),  // FIX #312
             (.extracting, .extracting),
             (.configuringDaemon, .configuringDaemon),
             (.downloadingParams, .downloadingParams),
             (.startingDaemon, .startingDaemon),
             (.complete, .complete),
             (.completeNeedsDaemon, .completeNeedsDaemon),
             (.completeDaemonStopped, .completeDaemonStopped),
             (.idle, .idle),
             (.cancelled, .cancelled):
            return true
        case (.error, .error):
            return true
        case (.syncingBlocks, .syncingBlocks):
            return true
        default:
            return false
        }
    }

    private var downloadStats: some View {
        HStack(spacing: 24) {
            // FIX #312: Elapsed time
            if !bootstrapManager.elapsedTime.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "timer")
                        .font(.system(size: 10))
                    Text("Elapsed: \(bootstrapManager.elapsedTime)")
                        .font(theme.monoFont)
                }
                .foregroundColor(theme.textSecondary)
            }

            if !bootstrapManager.downloadSpeed.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 10))
                    Text(bootstrapManager.downloadSpeed)
                        .font(theme.monoFont)
                }
                .foregroundColor(theme.textSecondary)
            }

            if !bootstrapManager.eta.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.system(size: 10))
                    Text("ETA: \(bootstrapManager.eta)")
                        .font(theme.monoFont)
                }
                .foregroundColor(theme.textSecondary)
            }
        }
    }

    private var footerView: some View {
        VStack(spacing: 12) {
            // FIX #285: Daemon installation options
            if case .completeNeedsDaemon = bootstrapManager.status {
                daemonInstallOptions
            }

            // FIX #285: Sync progress info
            if case .syncingBlocks(let progress, let eta) = bootstrapManager.status {
                HStack(spacing: 16) {
                    Text("Syncing: \(Int(progress * 100))%")
                        .font(theme.monoFont)
                        .foregroundColor(theme.textPrimary)
                    Text("ETA: \(eta)")
                        .font(theme.monoFont)
                        .foregroundColor(theme.textSecondary)
                    Text("\(bootstrapManager.blocksDelta) blocks remaining")
                        .font(theme.monoFont)
                        .foregroundColor(theme.textSecondary)
                }
            }

            HStack {
                // Cancel button
                if case .complete = bootstrapManager.status {
                    // Done - show close button
                } else if case .completeNeedsDaemon = bootstrapManager.status {
                    // Show close button
                } else if case .completeDaemonStopped = bootstrapManager.status {
                    // Show close button
                } else if case .error = bootstrapManager.status {
                    Button("Retry") {
                        Task {
                            await bootstrapManager.startBootstrap()
                        }
                    }
                    .buttonStyle(PlainButtonStyle())
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(theme.primaryColor)
                    .foregroundColor(theme.textPrimary)
                    .cornerRadius(theme.cornerRadius)
                } else {
                    Button("Cancel") {
                        bootstrapManager.cancel()
                    }
                    .buttonStyle(PlainButtonStyle())
                    .foregroundColor(theme.errorColor)
                }

                Spacer()

                // Close/Done button
                if case .complete = bootstrapManager.status {
                    Button("Done") {
                        dismiss()
                    }
                    .buttonStyle(PlainButtonStyle())
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(theme.successColor)
                    .foregroundColor(.white)
                    .cornerRadius(theme.cornerRadius)
                } else if case .completeNeedsDaemon = bootstrapManager.status {
                    Button("Close") {
                        dismiss()
                    }
                    .buttonStyle(PlainButtonStyle())
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(theme.warningColor)
                    .foregroundColor(.white)
                    .cornerRadius(theme.cornerRadius)
                } else if case .completeDaemonStopped = bootstrapManager.status {
                    Button("Done") {
                        dismiss()
                    }
                    .buttonStyle(PlainButtonStyle())
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(theme.successColor)
                    .foregroundColor(.white)
                    .cornerRadius(theme.cornerRadius)
                } else if case .cancelled = bootstrapManager.status {
                    Button("Close") {
                        dismiss()
                    }
                    .buttonStyle(PlainButtonStyle())
                    .foregroundColor(theme.textSecondary)
                } else if case .error = bootstrapManager.status {
                    Button("Close") {
                        dismiss()
                    }
                    .buttonStyle(PlainButtonStyle())
                    .foregroundColor(theme.textSecondary)
                }
            }
        }
        .padding()
        .background(theme.surfaceColor)
        .alert("Install Daemon", isPresented: $showDaemonInstallPrompt) {
            Button("Install from Bundle") {
                installDaemonFromBundle()
            }
            Button("Build Yourself") {
                showBuildInstructions = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("ZipherX can install the Zclassic daemon binaries (zclassicd, zclassic-cli, zclassic-tx) to /usr/local/bin.\n\nThis requires write access to /usr/local/bin.\n\nAlternatively, you can build the daemon yourself from source.")
        }
        .sheet(isPresented: $showBuildInstructions) {
            buildInstructionsSheet
        }
    }

    // MARK: - FIX #285: Daemon Installation UI

    private var daemonInstallOptions: some View {
        VStack(spacing: 8) {
            Text("⚠️ Daemon Not Installed")
                .font(theme.titleFont)
                .foregroundColor(theme.warningColor)

            Text("The zclassicd daemon was not found at /usr/local/bin")
                .font(theme.bodyFont)
                .foregroundColor(theme.textSecondary)

            HStack(spacing: 12) {
                if bootstrapManager.hasBundledDaemon {
                    Button("Install Bundled Daemon") {
                        showDaemonInstallPrompt = true
                    }
                    .buttonStyle(PlainButtonStyle())
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(theme.primaryColor)
                    .foregroundColor(.white)
                    .cornerRadius(theme.cornerRadius)
                }

                Button("Build Instructions") {
                    showBuildInstructions = true
                }
                .buttonStyle(PlainButtonStyle())
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(theme.surfaceColor)
                .foregroundColor(theme.textPrimary)
                .overlay(
                    RoundedRectangle(cornerRadius: theme.cornerRadius)
                        .stroke(theme.borderColor, lineWidth: 1)
                )
            }

            if let error = installError {
                Text(error)
                    .font(theme.captionFont)
                    .foregroundColor(theme.errorColor)
            }
        }
        .padding()
        .background(theme.surfaceColor.opacity(0.5))
        .cornerRadius(theme.cornerRadius)
    }

    private func installDaemonFromBundle() {
        isInstalling = true
        installError = nil

        Task {
            do {
                let success = try await bootstrapManager.installBundledDaemon()
                if success {
                    // Retry starting the daemon
                    await MainActor.run {
                        isInstalling = false
                    }
                    // Restart bootstrap process from daemon start step
                    try await FullNodeManager.shared.startDaemon()
                    await bootstrapManager.reset()
                    await bootstrapManager.startBootstrap()
                }
            } catch {
                await MainActor.run {
                    isInstalling = false
                    installError = error.localizedDescription
                }
            }
        }
    }

    private var buildInstructionsSheet: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Build Zclassic Daemon")
                    .font(theme.titleFont)
                    .foregroundColor(theme.textPrimary)
                Spacer()
                Button("Close") {
                    showBuildInstructions = false
                }
                .foregroundColor(theme.primaryColor)
            }
            .padding()
            .background(theme.surfaceColor)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Build from Source (macOS)")
                        .font(theme.titleFont)
                        .foregroundColor(theme.textPrimary)

                    Text("""
                    1. Install dependencies:
                       brew install autoconf automake libtool pkgconfig boost openssl coreutils

                    2. Clone the repository:
                       git clone https://github.com/AnotherZAP/zclassic.git
                       cd zclassic

                    3. Build:
                       ./zcutil/build.sh -j$(sysctl -n hw.ncpu)

                    4. Install binaries:
                       sudo cp src/zclassicd /usr/local/bin/
                       sudo cp src/zclassic-cli /usr/local/bin/
                       sudo cp src/zclassic-tx /usr/local/bin/

                    5. Return to ZipherX and start the daemon.
                    """)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(theme.textSecondary)

                    Divider()

                    Text("Build from Source (Linux)")
                        .font(theme.titleFont)
                        .foregroundColor(theme.textPrimary)

                    Text("""
                    1. Install dependencies:
                       sudo apt-get install build-essential pkg-config libc6-dev m4 g++-multilib
                       autoconf libtool ncurses-dev unzip git python python-zmq zlib1g-dev
                       wget bsdmainutils automake curl

                    2. Clone and build:
                       git clone https://github.com/AnotherZAP/zclassic.git
                       cd zclassic
                       ./zcutil/build.sh -j$(nproc)

                    3. Install binaries:
                       sudo cp src/zclassicd /usr/local/bin/
                       sudo cp src/zclassic-cli /usr/local/bin/
                       sudo cp src/zclassic-tx /usr/local/bin/
                    """)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(theme.textSecondary)

                    Divider()

                    Text("Windows")
                        .font(theme.titleFont)
                        .foregroundColor(theme.textPrimary)

                    Text("""
                    For Windows, use WSL2 with Ubuntu and follow the Linux instructions,
                    or download pre-built binaries from:
                    https://github.com/AnotherZAP/zclassic/releases
                    """)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(theme.textSecondary)
                }
                .padding()
            }
        }
        .frame(width: 600, height: 500)
        .background(theme.backgroundColor)
    }
}

#Preview {
    BootstrapProgressView()
        .environmentObject(ThemeManager.shared)
        .frame(width: 500, height: 500)
}

#endif
