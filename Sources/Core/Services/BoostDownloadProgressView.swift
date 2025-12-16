import SwiftUI

/// Progress view for boost file (CMU bundle) download during wallet setup/import
/// Shows download progress, speed, ETA similar to BootstrapProgressView
struct BoostDownloadProgressView: View {
    @EnvironmentObject var themeManager: ThemeManager
    @ObservedObject var walletManager: WalletManager
    @Environment(\.dismiss) private var dismiss

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

                    // Download stats
                    if !walletManager.boostDownloadSpeed.isEmpty || !walletManager.boostETA.isEmpty {
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
    }

    private var headerView: some View {
        HStack {
            Image(systemName: "tree.circle.fill")
                .font(.system(size: 20))
                .foregroundColor(theme.primaryColor)

            Text("Downloading Privacy Data")
                .font(theme.titleFont)
                .foregroundColor(theme.textPrimary)

            Spacer()
        }
        .padding()
        .background(theme.surfaceColor)
    }

    @ViewBuilder
    private var statusIcon: some View {
        let progress = walletManager.treeLoadProgress

        if progress >= 1.0 {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundColor(theme.successColor)
        } else if walletManager.treeLoadStatus.lowercased().contains("failed") {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 64))
                .foregroundColor(theme.errorColor)
        } else {
            // Animated progress indicator
            ZStack {
                Circle()
                    .stroke(theme.borderColor, lineWidth: 4)
                    .frame(width: 64, height: 64)

                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(theme.primaryColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .frame(width: 64, height: 64)
                    .rotationEffect(.degrees(-90))

                Text("\(Int(progress * 100))%")
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .foregroundColor(theme.textPrimary)
            }
        }
    }

    private var progressInfo: some View {
        VStack(spacing: 8) {
            Text(walletManager.treeLoadStatus.isEmpty ? "Preparing..." : walletManager.treeLoadStatus)
                .font(theme.bodyFont)
                .foregroundColor(theme.textPrimary)
                .multilineTextAlignment(.center)

            if walletManager.boostFileSize > 0 {
                Text(ByteCountFormatter.string(fromByteCount: walletManager.boostFileSize, countStyle: .file))
                    .font(theme.captionFont)
                    .foregroundColor(theme.textSecondary)
            }
        }
    }

    private var progressBar: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(theme.borderColor)
                    .frame(height: 8)
                    .cornerRadius(4)

                Rectangle()
                    .fill(
                        LinearGradient(
                            gradient: Gradient(colors: [theme.primaryColor, theme.successColor]),
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: geometry.size.width * min(walletManager.treeLoadProgress, 1.0), height: 8)
                    .cornerRadius(4)
            }
        }
        .frame(height: 8)
    }

    private var taskList: some View {
        VStack(alignment: .leading, spacing: 12) {
            taskRow("Check for updates", statusFor(step: 0))
            taskRow("Download privacy data", statusFor(step: 1))
            taskRow("Verify integrity", statusFor(step: 2))
            taskRow("Load commitment tree", statusFor(step: 3))
            taskRow("Initialize wallet", statusFor(step: 4))
        }
        .padding()
        .background(theme.surfaceColor)
        .cornerRadius(theme.cornerRadius)
    }

    private func taskRow(_ title: String, _ status: TaskStatus) -> some View {
        HStack(spacing: 12) {
            Group {
                switch status {
                case .pending:
                    Circle()
                        .stroke(theme.borderColor, lineWidth: 1)
                        .frame(width: 16, height: 16)
                case .inProgress:
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 16, height: 16)
                case .completed:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(theme.successColor)
                        .font(.system(size: 16))
                case .failed:
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(theme.errorColor)
                        .font(.system(size: 16))
                }
            }

            Text(title)
                .font(theme.bodyFont)
                .foregroundColor(statusTextColor(status))

            Spacer()
        }
    }

    private enum TaskStatus {
        case pending, inProgress, completed, failed
    }

    private func statusFor(step: Int) -> TaskStatus {
        let progress = walletManager.treeLoadProgress
        let status = walletManager.treeLoadStatus.lowercased()

        // Map progress to steps:
        // 0-10%: Check for updates
        // 10-30%: Download
        // 30-50%: Verify
        // 50-80%: Load tree
        // 80-100%: Initialize

        if status.contains("failed") {
            if step == currentStep(progress) { return .failed }
            if step < currentStep(progress) { return .completed }
            return .pending
        }

        if progress >= 1.0 { return .completed }

        let currentStepIndex = currentStep(progress)
        if step < currentStepIndex { return .completed }
        if step == currentStepIndex { return .inProgress }
        return .pending
    }

    private func currentStep(_ progress: Double) -> Int {
        if progress < 0.1 { return 0 }
        if progress < 0.3 { return 1 }
        if progress < 0.5 { return 2 }
        if progress < 0.8 { return 3 }
        return 4
    }

    private func statusTextColor(_ status: TaskStatus) -> Color {
        switch status {
        case .pending: return theme.textSecondary
        case .inProgress: return theme.textPrimary
        case .completed: return theme.successColor
        case .failed: return theme.errorColor
        }
    }

    private var downloadStats: some View {
        HStack(spacing: 24) {
            if !walletManager.boostDownloadSpeed.isEmpty {
                VStack(alignment: .center, spacing: 4) {
                    Text("Speed")
                        .font(theme.captionFont)
                        .foregroundColor(theme.textSecondary)
                    Text(walletManager.boostDownloadSpeed)
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .foregroundColor(theme.textPrimary)
                }
            }

            if !walletManager.boostETA.isEmpty {
                VStack(alignment: .center, spacing: 4) {
                    Text("ETA")
                        .font(theme.captionFont)
                        .foregroundColor(theme.textSecondary)
                    Text(walletManager.boostETA)
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .foregroundColor(theme.textPrimary)
                }
            }
        }
        .padding()
        .background(theme.surfaceColor)
        .cornerRadius(theme.cornerRadius)
    }

    private var footerView: some View {
        HStack {
            Spacer()

            if walletManager.treeLoadProgress >= 1.0 {
                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            } else if walletManager.treeLoadStatus.lowercased().contains("failed") {
                Button("Retry") {
                    Task {
                        await walletManager.loadCommitmentTree()
                    }
                }
                .buttonStyle(.borderedProminent)

                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(.bordered)
            }

            Spacer()
        }
        .padding()
        .background(theme.surfaceColor)
    }
}

#Preview {
    BoostDownloadProgressView(walletManager: WalletManager.shared)
        .environmentObject(ThemeManager.shared)
        .frame(width: 500, height: 500)
}
