import SwiftUI

#if os(macOS)

/// Progress view for bootstrap download and setup
struct BootstrapProgressView: View {
    @EnvironmentObject var themeManager: ThemeManager
    @StateObject private var bootstrapManager = BootstrapManager.shared
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

                    // Details
                    if !bootstrapManager.downloadSpeed.isEmpty || !bootstrapManager.eta.isEmpty {
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
            if case .idle = bootstrapManager.status {
                Task {
                    await bootstrapManager.startBootstrap()
                }
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
        case .extracting:
            return "archivebox"
        case .configuringDaemon:
            return "gearshape"
        case .downloadingParams:
            return "key"
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
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // Background
                RoundedRectangle(cornerRadius: 4)
                    .fill(theme.borderColor)
                    .frame(height: 8)

                // Progress
                RoundedRectangle(cornerRadius: 4)
                    .fill(theme.primaryColor)
                    .frame(width: geometry.size.width * bootstrapManager.progress, height: 8)
                    .animation(.linear(duration: 0.3), value: bootstrapManager.progress)
            }
        }
        .frame(height: 8)
        .padding(.horizontal, 40)
    }

    private var taskList: some View {
        VStack(alignment: .leading, spacing: 8) {
            taskRow("Check for latest bootstrap", statusFor(.checkingRelease))
            taskRow("Download blockchain data", statusFor(.downloading))
            taskRow("Verify checksum", statusFor(.verifying))
            taskRow("Extract to data directory", statusFor(.extracting))
            taskRow("Configure zclassicd", statusFor(.configuringDaemon))
            taskRow("Download Sapling params", statusFor(.downloadingParams))
        }
        .padding()
        .background(theme.surfaceColor)
        .overlay(
            RoundedRectangle(cornerRadius: theme.cornerRadius)
                .stroke(theme.borderColor, lineWidth: 1)
        )
        .cornerRadius(theme.cornerRadius)
    }

    private func taskRow(_ title: String, _ status: TaskStatus) -> some View {
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
        }
    }

    private enum TaskStatus {
        case pending, inProgress, completed, failed
    }

    private func statusFor(_ checkStatus: BootstrapManager.BootstrapStatus) -> TaskStatus {
        let order: [BootstrapManager.BootstrapStatus] = [
            .checkingRelease, .downloading, .verifying, .extracting, .configuringDaemon, .downloadingParams
        ]

        guard let checkIndex = order.firstIndex(where: { $0 == checkStatus }),
              let currentIndex = order.firstIndex(where: { statusMatches($0, bootstrapManager.status) }) else {
            return .pending
        }

        if statusMatches(checkStatus, bootstrapManager.status) {
            if case .error = bootstrapManager.status {
                return .failed
            }
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
             (.extracting, .extracting),
             (.configuringDaemon, .configuringDaemon),
             (.downloadingParams, .downloadingParams),
             (.complete, .complete),
             (.idle, .idle),
             (.cancelled, .cancelled):
            return true
        case (.error, .error):
            return true
        default:
            return false
        }
    }

    private var downloadStats: some View {
        HStack(spacing: 24) {
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
        HStack {
            // Cancel button
            if case .complete = bootstrapManager.status {
                // Done - show close button
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
        .padding()
        .background(theme.surfaceColor)
    }
}

#Preview {
    BootstrapProgressView()
        .environmentObject(ThemeManager.shared)
        .frame(width: 500, height: 500)
}

#endif
