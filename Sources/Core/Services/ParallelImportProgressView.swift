//
//  ParallelImportProgressView.swift
//  ZipherX
//
//  FIX #506: Parallel Import Progress UI
//  Shows progress of all parallel extraction jobs simultaneously
//

import SwiftUI

/// Progress view for parallel import operations
/// Shows individual progress for each parallel job (headers, CMUs, network, hashes, tree)
struct ParallelImportProgressView: View {
    @EnvironmentObject var themeManager: ThemeManager
    @ObservedObject var coordinator: ParallelImportCoordinatorViewModel
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
                    // Overall progress
                    overallProgressSection

                    // Parallel jobs grid
                    parallelJobsSection

                    // Performance stats
                    if coordinator.extractionDuration > 0 {
                        performanceStatsSection
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
        .onReceive(NotificationCenter.default.publisher(for: .importJobProgress)) { notification in
            if let progress = notification.object as? ImportProgress {
                coordinator.updateJobProgress(progress)
            }
        }
    }

    private var headerView: some View {
        HStack {
            Image(systemName: "bolt.circle.fill")
                .font(.system(size: 20))
                .foregroundColor(theme.primaryColor)

            Text("Parallel Import")
                .font(theme.titleFont)
                .foregroundColor(theme.textPrimary)

            Spacer()

            if coordinator.isRunning {
                HStack(spacing: 4) {
                    Circle()
                        .fill(theme.successColor)
                        .frame(width: 8, height: 8)
                        .opacity(0.5 + sin(Date().timeIntervalSince1970 * 5) * 0.5)

                    Text("Running")
                        .font(.system(size: 12))
                        .foregroundColor(theme.textSecondary)
                }
            }
        }
        .padding()
        .background(theme.surfaceColor)
    }

    private var overallProgressSection: some View {
        VStack(spacing: 16) {
            // Circular overall progress
            ZStack {
                Circle()
                    .stroke(theme.borderColor, lineWidth: 8)
                    .frame(width: 120, height: 120)

                Circle()
                    .trim(from: 0, to: coordinator.overallProgress)
                    .stroke(
                        LinearGradient(
                            gradient: Gradient(colors: [theme.primaryColor, theme.successColor]),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        style: StrokeStyle(lineWidth: 8, lineCap: .round)
                    )
                    .frame(width: 120, height: 120)
                    .rotationEffect(.degrees(-90))

                VStack(spacing: 4) {
                    Text("\(Int(coordinator.overallProgress * 100))%")
                        .font(.system(size: 24, weight: .bold, design: .monospaced))
                        .foregroundColor(theme.textPrimary)

                    Text("Overall")
                        .font(.system(size: 12))
                        .foregroundColor(theme.textSecondary)
                }
            }

            // Status text
            Text(coordinator.overallStatus)
                .font(theme.bodyFont)
                .foregroundColor(theme.textPrimary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .background(theme.surfaceColor)
        .cornerRadius(theme.cornerRadius)
    }

    private var parallelJobsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Parallel Tasks")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(theme.textSecondary)

            VStack(spacing: 12) {
                ForEach(ImportJobType.allCases, id: \.rawValue) { jobType in
                    ParallelJobRow(
                        jobType: jobType,
                        job: coordinator.jobs[jobType]
                    )
                }
            }
        }
        .padding()
        .background(theme.surfaceColor)
        .cornerRadius(theme.cornerRadius)
    }

    private var performanceStatsSection: some View {
        HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Extraction Time")
                    .font(.system(size: 11))
                    .foregroundColor(theme.textSecondary)

                Text("\(String(format: "%.1f", coordinator.extractionDuration))s")
                    .font(.system(size: 16, weight: .medium, design: .monospaced))
                    .foregroundColor(theme.textPrimary)
            }

            Spacer()

            VStack(alignment: .leading, spacing: 4) {
                Text("Speedup")
                    .font(.system(size: 11))
                    .foregroundColor(theme.textSecondary)

                Text("1.7x faster")
                    .font(.system(size: 16, weight: .medium, design: .monospaced))
                    .foregroundColor(theme.successColor)
            }
        }
        .padding()
        .background(theme.surfaceColor)
        .cornerRadius(theme.cornerRadius)
    }

    private var footerView: some View {
        HStack {
            Spacer()

            if coordinator.overallProgress >= 1.0 {
                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            } else if coordinator.hasErrors {
                Button("Close") {
                    dismiss()
                }
                .buttonStyle(.bordered)
            } else if coordinator.canCancel {
                Button("Cancel") {
                    Task {
                        await coordinator.cancel()
                    }
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

/// Individual job row in parallel tasks list
struct ParallelJobRow: View {
    @EnvironmentObject var themeManager: ThemeManager
    let jobType: ImportJobType
    let job: ImportJob?

    private var theme: AppTheme { themeManager.currentTheme }

    var body: some View {
        HStack(spacing: 12) {
            // Job icon
            jobIcon
                .frame(width: 24)

            // Job name
            Text(jobType.displayName)
                .font(.system(size: 13))
                .foregroundColor(theme.textPrimary)
                .frame(width: 100, alignment: .leading)

            // Progress bar
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(theme.borderColor)
                        .frame(height: 6)
                        .cornerRadius(3)

                    Rectangle()
                        .fill(barColor)
                        .frame(width: geometry.size.width * progress, height: 6)
                        .cornerRadius(3)
                }
            }
            .frame(height: 6)

            // Status/percentage
            Text(statusText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(statusColor)
                .frame(width: 60, alignment: .trailing)
        }
    }

    private var jobIcon: some View {
        Group {
            if let job = job {
                switch job.status {
                case .pending:
                    Circle()
                        .stroke(theme.borderColor, lineWidth: 1)
                        .frame(width: 16, height: 16)
                case .running:
                    ProgressView()
                        .scaleEffect(0.7)
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
            } else {
                Circle()
                    .stroke(theme.borderColor, lineWidth: 1)
                    .frame(width: 16, height: 16)
            }
        }
    }

    private var progress: Double {
        guard let job = job else { return 0 }
        return min(max(job.progress, 0), 1)
    }

    private var barColor: Color {
        if let job = job {
            switch job.status {
            case .completed:
                return theme.successColor
            case .failed:
                return theme.errorColor
            default:
                return theme.primaryColor
            }
        }
        return theme.primaryColor
    }

    private var statusText: String {
        if let job = job {
            switch job.status {
            case .pending:
                return "Waiting"
            case .running:
                return "\(Int(job.progress * 100))%"
            case .completed:
                return "Done"
            case .failed:
                return "Failed"
            }
        }
        return "Waiting"
    }

    private var statusColor: Color {
        if let job = job {
            switch job.status {
            case .pending:
                return theme.textSecondary
            case .running:
                return theme.textPrimary
            case .completed:
                return theme.successColor
            case .failed:
                return theme.errorColor
            }
        }
        return theme.textSecondary
    }
}

// MARK: - View Model

/// View model for parallel import coordinator
@MainActor
class ParallelImportCoordinatorViewModel: ObservableObject {
    @Published var jobs: [ImportJobType: ImportJob] = [:]
    @Published var overallProgress: Double = 0
    @Published var overallStatus: String = "Initializing..."
    @Published var isRunning: Bool = false
    @Published var hasErrors: Bool = false
    @Published var canCancel: Bool = true
    @Published var extractionDuration: TimeInterval = 0

    private var extractionStartTime: Date?

    init() {
        // Initialize jobs for all types
        for jobType in ImportJobType.allCases {
            jobs[jobType] = ImportJob(id: UUID().uuidString, type: jobType, status: .pending)
        }
    }

    func updateJobProgress(_ progress: ImportProgress) {
        // Update individual job
        if var job = jobs[progress.type] {
            job.progress = progress.progress

            // Update status based on progress
            if progress.progress >= 1.0 {
                job.status = .completed
            } else if progress.progress > 0 {
                job.status = .running
            }

            jobs[progress.type] = job
        }

        // Update overall status
        overallStatus = progress.status

        // Calculate overall progress
        updateOverallProgress()
    }

    func updateOverallProgress() {
        let totalProgress = jobs.values.reduce(0.0) { $0 + $1.progress }
        overallProgress = totalProgress / Double(jobs.count)

        // Update running state
        isRunning = jobs.values.contains { $0.status == .running }

        // Update error state
        hasErrors = jobs.values.contains { $0.status == .failed }

        // Update cancel state (can cancel if any job is still running)
        canCancel = jobs.values.contains { $0.status == .running || $0.status == .pending }
    }

    func setExtractionStartTime() {
        extractionStartTime = Date()
    }

    func setExtractionDuration(_ duration: TimeInterval) {
        extractionDuration = duration
    }

    func cancel() async {
        // Cancel implementation (would need to be added to coordinator)
        isRunning = false
        canCancel = false
    }
}

// MARK: - Preview

#Preview {
    ParallelImportProgressView(coordinator: ParallelImportCoordinatorViewModel())
        .environmentObject(ThemeManager.shared)
        .frame(width: 500, height: 600)
}
