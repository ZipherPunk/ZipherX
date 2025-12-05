import SwiftUI

/// Privacy Score View - Shows current privacy score with breakdown
struct PrivacyScoreView: View {
    @EnvironmentObject private var themeManager: ThemeManager
    @EnvironmentObject private var walletManager: WalletManager
    @StateObject private var privacyManager = PrivacyScoreManager.shared
    @ObservedObject private var networkManager = NetworkManager.shared

    @State private var showHelp = false

    private var theme: AppTheme { themeManager.currentTheme }

    var body: some View {
        VStack(spacing: 16) {
            // Header
            HStack {
                Text("Privacy Score")
                    .font(theme.titleFont)
                    .foregroundColor(theme.textPrimary)

                Spacer()

                Button(action: { showHelp = true }) {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 16))
                        .foregroundColor(theme.textSecondary)
                }
                .buttonStyle(PlainButtonStyle())
            }

            // Main Score Display
            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    Text(privacyManager.scoreStatus.emoji)
                        .font(.system(size: 32))

                    Text("\(privacyManager.totalScore)")
                        .font(.system(size: 48, weight: .bold, design: .monospaced))
                        .foregroundColor(privacyManager.scoreStatus.color)

                    Text("/100")
                        .font(.system(size: 18, weight: .medium, design: .monospaced))
                        .foregroundColor(theme.textSecondary)
                }

                Text(privacyManager.scoreStatus.text)
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(privacyManager.scoreStatus.color)
            }
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity)
            .background(theme.surfaceColor)
            .cornerRadius(theme.cornerRadius)
            .overlay(
                RoundedRectangle(cornerRadius: theme.cornerRadius)
                    .stroke(privacyManager.scoreStatus.color.opacity(0.5), lineWidth: 2)
            )

            // Category Breakdown
            VStack(spacing: 12) {
                privacyCategoryRow(
                    label: "Fund Privacy",
                    score: privacyManager.fundPrivacyScore,
                    maxScore: PrivacyScoreManager.ScoreWeights.fundPrivacy,
                    description: "Percentage of shielded funds"
                )

                privacyCategoryRow(
                    label: "Encryption",
                    score: privacyManager.encryptionScore,
                    maxScore: PrivacyScoreManager.ScoreWeights.encryption,
                    description: "Database & key encryption"
                )

                privacyCategoryRow(
                    label: "Network",
                    score: privacyManager.networkScore,
                    maxScore: PrivacyScoreManager.ScoreWeights.network,
                    description: "P2P connections (Tor future)"
                )

                privacyCategoryRow(
                    label: "Operational",
                    score: privacyManager.operationalScore,
                    maxScore: PrivacyScoreManager.ScoreWeights.operational,
                    description: "Logging & backup status"
                )
            }
            .padding()
            .background(theme.surfaceColor)
            .cornerRadius(theme.cornerRadius)
            .overlay(
                RoundedRectangle(cornerRadius: theme.cornerRadius)
                    .stroke(theme.borderColor, lineWidth: 1)
            )

            // Recommendations (if any)
            if !privacyManager.recommendations.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "lightbulb.fill")
                            .foregroundColor(.yellow)
                        Text("Recommendations")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundColor(theme.textPrimary)
                    }

                    ForEach(privacyManager.recommendations) { rec in
                        HStack(alignment: .top, spacing: 8) {
                            Circle()
                                .fill(rec.priority.color)
                                .frame(width: 8, height: 8)
                                .padding(.top, 4)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(rec.recommendation)
                                    .font(theme.captionFont)
                                    .foregroundColor(theme.textPrimary)
                            }
                        }
                    }
                }
                .padding()
                .background(theme.warningColor.opacity(0.1))
                .cornerRadius(theme.cornerRadius)
                .overlay(
                    RoundedRectangle(cornerRadius: theme.cornerRadius)
                        .stroke(theme.warningColor.opacity(0.3), lineWidth: 1)
                )
            }
        }
        .padding()
        .onAppear {
            updateScore()
        }
        .onChange(of: walletManager.shieldedBalance) { _ in
            updateScore()
        }
        .sheet(isPresented: $showHelp) {
            privacyHelpView
        }
    }

    // MARK: - Category Row

    private func privacyCategoryRow(label: String, score: Int, maxScore: Int, description: String) -> some View {
        let percentage = maxScore > 0 ? Double(score) / Double(maxScore) : 0
        let emoji = PrivacyScoreManager.emojiForScore(score, maxScore: maxScore)
        let barColor = PrivacyScoreManager.colorForScore(score, maxScore: maxScore)

        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(emoji)
                    .font(.system(size: 12))

                Text(label)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(theme.textPrimary)

                Spacer()

                Text("\(score)/\(maxScore)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.textSecondary)
            }

            // Progress bar
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(theme.borderColor.opacity(0.3))
                        .frame(height: 6)
                        .cornerRadius(3)

                    Rectangle()
                        .fill(barColor)
                        .frame(width: geometry.size.width * percentage, height: 6)
                        .cornerRadius(3)
                }
            }
            .frame(height: 6)

            Text(description)
                .font(.system(size: 9))
                .foregroundColor(theme.textSecondary)
        }
    }

    // MARK: - Help View

    private var privacyHelpView: some View {
        ZStack {
            theme.backgroundColor.ignoresSafeArea()

            VStack(spacing: 16) {
                HStack {
                    Text("Privacy Score Calculation")
                        .font(theme.titleFont)
                        .foregroundColor(theme.textPrimary)

                    Spacer()

                    Button(action: { showHelp = false }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 24))
                            .foregroundColor(theme.textSecondary)
                    }
                    .buttonStyle(PlainButtonStyle())
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Your privacy score is calculated from 4 categories:")
                            .font(theme.bodyFont)
                            .foregroundColor(theme.textSecondary)

                        helpSection(
                            title: "Fund Privacy (0-35 points)",
                            description: "Measures what percentage of your funds are in shielded (z) addresses. 100% shielded = 35 points."
                        )

                        helpSection(
                            title: "Encryption (0-30 points)",
                            description: "Database encryption (15 points) + spending key encryption (15 points). Both should be enabled."
                        )

                        helpSection(
                            title: "Network (0-20 points)",
                            description: "P2P peer connections (up to 10 points). Tor support planned for future (additional 10 points)."
                        )

                        helpSection(
                            title: "Operational (0-15 points)",
                            description: "Debug logging disabled (10 points) + backup confirmed (5 points)."
                        )

                        // Cypherpunk quote
                        VStack(alignment: .leading, spacing: 8) {
                            Text("\"Privacy is necessary for an open society in the electronic age.\"")
                                .font(.system(size: 12, weight: .regular, design: .monospaced))
                                .italic()
                                .foregroundColor(theme.primaryColor)

                            Text("— A Cypherpunk's Manifesto, 1993")
                                .font(theme.captionFont)
                                .foregroundColor(theme.textSecondary)
                        }
                        .padding()
                        .background(theme.surfaceColor)
                        .cornerRadius(theme.cornerRadius)
                    }
                }

                Button(action: { showHelp = false }) {
                    Text("Got it")
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundColor(theme.backgroundColor)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(theme.primaryColor)
                        .cornerRadius(theme.cornerRadius)
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding()
        }
        #if os(macOS)
        .frame(minWidth: 400, minHeight: 500)
        #endif
    }

    private func helpSection(title: String, description: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(theme.textPrimary)

            Text(description)
                .font(theme.captionFont)
                .foregroundColor(theme.textSecondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surfaceColor)
        .cornerRadius(theme.cornerRadius)
    }

    // MARK: - Score Calculation

    private func updateScore() {
        // Get current state
        let isDebugEnabled = UserDefaults.standard.bool(forKey: "debugLoggingEnabled")
        let hasBackup = UserDefaults.standard.bool(forKey: "hasConfirmedBackup")
        let isDatabaseEncrypted = SQLCipherManager.shared.isSQLCipherAvailable
        let isKeyEncrypted = true // Always true in ZipherX (AES-GCM encrypted keys)

        privacyManager.calculateScore(
            shieldedBalance: Double(walletManager.shieldedBalance),
            transparentBalance: 0, // ZipherX is shielded-only for now
            isDatabaseEncrypted: isDatabaseEncrypted,
            isKeyEncrypted: isKeyEncrypted,
            peerCount: networkManager.connectedPeers,
            isDebugLoggingEnabled: isDebugEnabled,
            hasBackup: hasBackup
        )
    }
}

// MARK: - Compact Privacy Score View (for Balance screen)

struct CompactPrivacyScoreView: View {
    @EnvironmentObject private var themeManager: ThemeManager
    @StateObject private var privacyManager = PrivacyScoreManager.shared

    private var theme: AppTheme { themeManager.currentTheme }

    var body: some View {
        HStack(spacing: 6) {
            Text("Privacy:")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(theme.textSecondary)

            Text(privacyManager.scoreStatus.emoji)
                .font(.system(size: 12))

            Text("\(privacyManager.totalScore)%")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(privacyManager.scoreStatus.color)
        }
    }
}

#Preview {
    PrivacyScoreView()
        .environmentObject(ThemeManager.shared)
        .environmentObject(WalletManager.shared)
}
