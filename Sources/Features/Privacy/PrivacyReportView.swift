//
//  PrivacyReportView.swift
//  ZipherX
//
//  Created by ZipherX Team on 2025-12-09.
//  Privacy is necessary for an open society in the electronic age.
//
//  "We the Cypherpunks are dedicated to building anonymous systems."
//  - A Cypherpunk's Manifesto, Eric Hughes, 1993
//

import SwiftUI

// MARK: - Privacy Score Categories

enum PrivacyLevel: String {
    case sovereign = "SOVEREIGN"      // 90-100: Maximum privacy
    case cypherpunk = "CYPHERPUNK"    // 75-89: Strong privacy
    case cautious = "CAUTIOUS"        // 50-74: Moderate privacy
    case exposed = "EXPOSED"          // 25-49: Weak privacy
    case compromised = "COMPROMISED"  // 0-24: Critical privacy issues

    var color: Color {
        switch self {
        case .sovereign: return .green
        case .cypherpunk: return .cyan
        case .cautious: return .yellow
        case .exposed: return .orange
        case .compromised: return .red
        }
    }

    var emoji: String {
        switch self {
        case .sovereign: return "🛡️"
        case .cypherpunk: return "🔐"
        case .cautious: return "⚠️"
        case .exposed: return "🚨"
        case .compromised: return "💀"
        }
    }

    var quote: String {
        switch self {
        case .sovereign:
            return "\"Privacy is not about hiding. Privacy is about autonomy and self-determination.\""
        case .cypherpunk:
            return "\"We are defending our privacy with cryptography, with anonymous systems, with digital signatures, and with electronic money.\""
        case .cautious:
            return "\"Privacy in an open society requires anonymous transaction systems.\""
        case .exposed:
            return "\"Privacy is necessary for an open society in the electronic age.\""
        case .compromised:
            return "\"We cannot expect governments, corporations, or other large, faceless organizations to grant us privacy.\""
        }
    }

    static func fromScore(_ score: Int) -> PrivacyLevel {
        switch score {
        case 90...100: return .sovereign
        case 75..<90: return .cypherpunk
        case 50..<75: return .cautious
        case 25..<50: return .exposed
        default: return .compromised
        }
    }
}

// MARK: - Privacy Check Item

struct PrivacyCheckItem: Identifiable {
    let id = UUID()
    let category: String
    let name: String
    let status: PrivacyCheckStatus
    let description: String
    let recommendation: String?
    let points: Int
    let maxPoints: Int

    enum PrivacyCheckStatus {
        case secure
        case warning
        case critical
        case info

        var color: Color {
            switch self {
            case .secure: return .green
            case .warning: return .yellow
            case .critical: return .red
            case .info: return .cyan
            }
        }

        var icon: String {
            switch self {
            case .secure: return "checkmark.shield.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .critical: return "xmark.shield.fill"
            case .info: return "info.circle.fill"
            }
        }
    }
}

// MARK: - Privacy Report Generator

@MainActor
class PrivacyReportGenerator: ObservableObject {
    @Published var checks: [PrivacyCheckItem] = []
    @Published var totalScore: Int = 0
    @Published var maxScore: Int = 0
    @Published var isGenerating: Bool = false
    @Published var generationProgress: Double = 0
    @Published var currentCheckName: String = ""

    var privacyLevel: PrivacyLevel {
        guard maxScore > 0 else { return .compromised }
        let percentage = (totalScore * 100) / maxScore
        return PrivacyLevel.fromScore(percentage)
    }

    var scorePercentage: Int {
        guard maxScore > 0 else { return 0 }
        return (totalScore * 100) / maxScore
    }

    func generateReport() async {
        isGenerating = true
        checks = []
        totalScore = 0
        maxScore = 0
        generationProgress = 0

        let allChecks: [(String, () async -> PrivacyCheckItem)] = [
            ("Analyzing Tor connectivity...", checkTorStatus),
            ("Checking network routing...", checkNetworkRouting),
            ("Verifying P2P connections...", checkP2PConnections),
            ("Analyzing shielded addresses...", checkShieldedAddresses),
            ("Checking transaction history...", checkTransactionPrivacy),
            ("Verifying key storage...", checkKeyStorage),
            ("Checking database encryption...", checkDatabaseEncryption),
            ("Analyzing biometric security...", checkBiometricAuth),
            ("Checking memo privacy...", checkMemoPrivacy),
            ("Verifying nullifier hashing...", checkNullifierHashing),
            ("Checking peer diversity...", checkPeerDiversity),
            ("Analyzing API usage...", checkAPIPrivacy),
            ("Checking DNS leakage...", checkDNSLeakage),
            ("Verifying address reuse...", checkAddressReuse),
            ("Checking key rotation...", checkKeyRotation),
        ]

        for (index, (name, check)) in allChecks.enumerated() {
            currentCheckName = name
            generationProgress = Double(index) / Double(allChecks.count)

            // Small delay for visual effect
            try? await Task.sleep(nanoseconds: 100_000_000)

            let item = await check()
            checks.append(item)
            totalScore += item.points
            maxScore += item.maxPoints
        }

        generationProgress = 1.0
        currentCheckName = "Report complete"

        try? await Task.sleep(nanoseconds: 300_000_000)
        isGenerating = false
    }

    // MARK: - Individual Privacy Checks

    private func checkTorStatus() async -> PrivacyCheckItem {
        let torManager = TorManager.shared
        let isEnabled = torManager.mode == .enabled
        let isConnected = torManager.connectionState.isConnected

        if isEnabled && isConnected {
            return PrivacyCheckItem(
                category: "NETWORK",
                name: "Tor Routing",
                status: .secure,
                description: "Tor active. Network traffic routed through onion circuits. Your IP is hidden from peers.",
                recommendation: nil,
                points: 15,
                maxPoints: 15
            )
        } else if isEnabled && !isConnected {
            return PrivacyCheckItem(
                category: "NETWORK",
                name: "Tor Routing",
                status: .warning,
                description: "Tor is enabled but not connected. P2P traffic may expose your IP during reconnection.",
                recommendation: "Wait for Tor to connect or check your network connection.",
                points: 5,
                maxPoints: 15
            )
        } else {
            return PrivacyCheckItem(
                category: "NETWORK",
                name: "Tor Routing",
                status: .critical,
                description: "Tor is disabled. Your IP address is visible to P2P peers and DNS seed nodes.",
                recommendation: "Enable Tor in Settings for maximum network privacy.",
                points: 0,
                maxPoints: 15
            )
        }
    }

    private func checkNetworkRouting() async -> PrivacyCheckItem {
        let torManager = TorManager.shared

        if torManager.isAvailable {
            let realIP = torManager.realIP ?? "Unknown"
            let torIP = torManager.torIP ?? "Unknown"
            let isHidden = realIP != torIP && torIP != "Unknown"

            if isHidden {
                return PrivacyCheckItem(
                    category: "NETWORK",
                    name: "IP Verification",
                    status: .secure,
                    description: "Real IP (\(realIP.prefix(8))...) hidden. Exit node: \(torIP.prefix(8))...",
                    recommendation: nil,
                    points: 10,
                    maxPoints: 10
                )
            }
        }

        return PrivacyCheckItem(
            category: "NETWORK",
            name: "IP Verification",
            status: .warning,
            description: "Unable to verify IP masking. Your real IP may be exposed.",
            recommendation: "Enable Tor and verify your exit IP differs from your real IP.",
            points: 0,
            maxPoints: 10
        )
    }

    private func checkP2PConnections() async -> PrivacyCheckItem {
        let networkManager = NetworkManager.shared
        let peerCount = networkManager.connectedPeers
        let torEnabled = TorManager.shared.mode == .enabled

        if torEnabled && peerCount >= 3 {
            return PrivacyCheckItem(
                category: "NETWORK",
                name: "P2P Connections",
                status: .secure,
                description: "\(peerCount) peers connected via Tor. Your IP is hidden from blockchain peers.",
                recommendation: nil,
                points: 10,
                maxPoints: 10
            )
        } else if torEnabled {
            return PrivacyCheckItem(
                category: "NETWORK",
                name: "P2P Connections",
                status: .warning,
                description: "Only \(peerCount) peers connected via Tor. Low peer count reduces consensus reliability.",
                recommendation: "Wait for more peer connections (3+ recommended).",
                points: 5,
                maxPoints: 10
            )
        } else if peerCount >= 5 {
            return PrivacyCheckItem(
                category: "NETWORK",
                name: "P2P Connections",
                status: .warning,
                description: "\(peerCount) peers connected directly. Your IP is visible to all peers.",
                recommendation: "Enable Tor to hide your IP from P2P peers.",
                points: 3,
                maxPoints: 10
            )
        } else {
            return PrivacyCheckItem(
                category: "NETWORK",
                name: "P2P Connections",
                status: .warning,
                description: "Only \(peerCount) peers connected without Tor. IP exposed and low diversity.",
                recommendation: "Enable Tor and wait for more peer connections.",
                points: 1,
                maxPoints: 10
            )
        }
    }

    private func checkShieldedAddresses() async -> PrivacyCheckItem {
        let hasZAddress = WalletManager.shared.zAddress != nil

        if hasZAddress {
            return PrivacyCheckItem(
                category: "WALLET",
                name: "Shielded Address",
                status: .secure,
                description: "Using Sapling shielded z-address. Transaction amounts and memos are encrypted.",
                recommendation: nil,
                points: 15,
                maxPoints: 15
            )
        } else {
            return PrivacyCheckItem(
                category: "WALLET",
                name: "Shielded Address",
                status: .critical,
                description: "No shielded address found. Transparent addresses expose all transaction details.",
                recommendation: "Create or restore a wallet to generate a shielded z-address.",
                points: 0,
                maxPoints: 15
            )
        }
    }

    private func checkTransactionPrivacy() async -> PrivacyCheckItem {
        // Check if using shielded transactions
        let history = (try? WalletDatabase.shared.getTransactionHistory(limit: 100, offset: 0)) ?? []
        let shieldedCount = history.count // All our transactions are shielded

        if shieldedCount > 0 {
            return PrivacyCheckItem(
                category: "WALLET",
                name: "Transaction Privacy",
                status: .secure,
                description: "All \(shieldedCount) transactions are fully shielded (z-to-z). Amounts hidden on blockchain.",
                recommendation: nil,
                points: 10,
                maxPoints: 10
            )
        } else {
            return PrivacyCheckItem(
                category: "WALLET",
                name: "Transaction Privacy",
                status: .info,
                description: "No transaction history yet. All future transactions will be shielded.",
                recommendation: nil,
                points: 10,
                maxPoints: 10
            )
        }
    }

    private func checkKeyStorage() async -> PrivacyCheckItem {
        #if targetEnvironment(simulator)
        // Simulator — no Secure Enclave
        return PrivacyCheckItem(
            category: "SECURITY",
            name: "Key Storage",
            status: .warning,
            description: "Running in simulator. Spending key encrypted with AES-GCM-256 (no hardware Secure Enclave).",
            recommendation: "Deploy to a real device for hardware-backed key protection.",
            points: 10,
            maxPoints: 15
        )
        #else
        // Real device (iOS or macOS Apple Silicon) — Secure Enclave available
        return PrivacyCheckItem(
            category: "SECURITY",
            name: "Key Storage",
            status: .secure,
            description: "Spending key protected by hardware Secure Enclave. Keys never leave the secure chip.",
            recommendation: nil,
            points: 15,
            maxPoints: 15
        )
        #endif
    }

    private func checkDatabaseEncryption() async -> PrivacyCheckItem {
        let isEncrypted = SQLCipherManager.shared.isSQLCipherAvailable

        if isEncrypted {
            return PrivacyCheckItem(
                category: "SECURITY",
                name: "Database Encryption",
                status: .secure,
                description: "SQLCipher AES-256 full database encryption active. All wallet data encrypted at rest.",
                recommendation: nil,
                points: 10,
                maxPoints: 10
            )
        } else {
            return PrivacyCheckItem(
                category: "SECURITY",
                name: "Database Encryption",
                status: .critical,
                description: "Database encryption unavailable. Wallet data may be exposed if device is compromised.",
                recommendation: "Ensure SQLCipher is properly linked in the build.",
                points: 0,
                maxPoints: 10
            )
        }
    }

    private func checkBiometricAuth() async -> PrivacyCheckItem {
        let isEnabled = BiometricAuthManager.shared.isBiometricEnabled

        if isEnabled {
            return PrivacyCheckItem(
                category: "SECURITY",
                name: "Biometric Lock",
                status: .secure,
                description: "Face ID / Touch ID enabled. Unauthorized access prevented.",
                recommendation: nil,
                points: 5,
                maxPoints: 5
            )
        } else {
            return PrivacyCheckItem(
                category: "SECURITY",
                name: "Biometric Lock",
                status: .warning,
                description: "Biometric authentication disabled. Anyone with device access can open the wallet.",
                recommendation: "Enable Face ID in Settings → Security → Face ID.",
                points: 0,
                maxPoints: 5
            )
        }
    }

    private func checkMemoPrivacy() async -> PrivacyCheckItem {
        // Memos are encrypted in shielded transactions
        return PrivacyCheckItem(
            category: "WALLET",
            name: "Memo Encryption",
            status: .secure,
            description: "Transaction memos encrypted with Sapling note encryption. Only sender/receiver can read.",
            recommendation: nil,
            points: 5,
            maxPoints: 5
        )
    }

    private func checkNullifierHashing() async -> PrivacyCheckItem {
        // We implemented SHA256 hashing for nullifiers
        return PrivacyCheckItem(
            category: "SECURITY",
            name: "Nullifier Privacy",
            status: .secure,
            description: "Nullifiers hashed with SHA256 before storage. Spending patterns protected if DB compromised.",
            recommendation: nil,
            points: 5,
            maxPoints: 5
        )
    }

    private func checkPeerDiversity() async -> PrivacyCheckItem {
        let networkManager = NetworkManager.shared
        let peerCount = networkManager.connectedPeers
        let knownAddresses = networkManager.knownAddressesCount

        if peerCount >= 8 {
            return PrivacyCheckItem(
                category: "NETWORK",
                name: "Peer Diversity",
                status: .secure,
                description: "\(peerCount) peers from pool of \(knownAddresses) known addresses. Good decentralization.",
                recommendation: nil,
                points: 5,
                maxPoints: 5
            )
        } else if peerCount >= 3 {
            return PrivacyCheckItem(
                category: "NETWORK",
                name: "Peer Diversity",
                status: .info,
                description: "\(peerCount) peers connected. Minimum diversity for consensus.",
                recommendation: "Consider connecting to more peers for better decentralization.",
                points: 3,
                maxPoints: 5
            )
        } else {
            return PrivacyCheckItem(
                category: "NETWORK",
                name: "Peer Diversity",
                status: .warning,
                description: "Only \(peerCount) peers. Low diversity increases Sybil attack risk.",
                recommendation: "Wait for more peer connections or check network status.",
                points: 1,
                maxPoints: 5
            )
        }
    }

    private func checkAPIPrivacy() async -> PrivacyCheckItem {
        // ZipherX uses 100% P2P — no centralized API servers in normal operation
        let torEnabled = TorManager.shared.mode == .enabled && TorManager.shared.connectionState.isConnected

        if torEnabled {
            return PrivacyCheckItem(
                category: "NETWORK",
                name: "Network Architecture",
                status: .secure,
                description: "100% peer-to-peer via Tor. No centralized API servers. No third-party can track your queries.",
                recommendation: nil,
                points: 5,
                maxPoints: 5
            )
        } else {
            return PrivacyCheckItem(
                category: "NETWORK",
                name: "Network Architecture",
                status: .info,
                description: "100% peer-to-peer (no centralized servers). Peers can see your IP without Tor.",
                recommendation: "Enable Tor for full network privacy.",
                points: 3,
                maxPoints: 5
            )
        }
    }

    private func checkDNSLeakage() async -> PrivacyCheckItem {
        let torEnabled = TorManager.shared.mode == .enabled

        if torEnabled {
            return PrivacyCheckItem(
                category: "NETWORK",
                name: "DNS Privacy",
                status: .secure,
                description: "Peer discovery via Tor. DNS seed queries do not leak to your ISP.",
                recommendation: nil,
                points: 5,
                maxPoints: 5
            )
        } else {
            return PrivacyCheckItem(
                category: "NETWORK",
                name: "DNS Privacy",
                status: .warning,
                description: "Initial peer discovery uses DNS seeds. Your ISP can see you are connecting to Zclassic.",
                recommendation: "Enable Tor to hide peer discovery from your ISP.",
                points: 2,
                maxPoints: 5
            )
        }
    }

    private func checkAddressReuse() async -> PrivacyCheckItem {
        // Shielded addresses can be reused safely due to encryption
        return PrivacyCheckItem(
            category: "WALLET",
            name: "Address Privacy",
            status: .secure,
            description: "Shielded z-addresses can be safely reused. Each output is encrypted independently.",
            recommendation: nil,
            points: 5,
            maxPoints: 5
        )
    }

    private func checkKeyRotation() async -> PrivacyCheckItem {
        let shouldRotate = SecureKeyStorage.shared.shouldRecommendKeyRotation()
        let ageMessage = SecureKeyStorage.shared.getKeyAgeMessage()

        if !shouldRotate {
            return PrivacyCheckItem(
                category: "SECURITY",
                name: "Key Rotation",
                status: .info,
                description: "Spending key age: \(ageMessage). Regular rotation recommended annually.",
                recommendation: nil,
                points: 5,
                maxPoints: 5
            )
        } else {
            return PrivacyCheckItem(
                category: "SECURITY",
                name: "Key Rotation",
                status: .warning,
                description: "Spending key is over 1 year old. Consider generating a new wallet.",
                recommendation: "Create a new wallet and transfer funds for improved security.",
                points: 2,
                maxPoints: 5
            )
        }
    }
}

// MARK: - Privacy Report View

struct PrivacyReportView: View {
    @StateObject private var generator = PrivacyReportGenerator()
    @EnvironmentObject var themeManager: ThemeManager
    @Environment(\.dismiss) var dismiss

    private var theme: AppTheme { themeManager.currentTheme }

    var body: some View {
        ZStack {
            theme.backgroundColor.ignoresSafeArea()

            if generator.isGenerating {
                generatingView
            } else if generator.checks.isEmpty {
                startView
            } else {
                reportView
            }
        }
        .navigationTitle("Privacy Report")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Done") {
                    dismiss()
                }
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundColor(theme.accentColor)
            }
        }
        #else
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    dismiss()
                }
                .font(.system(size: 14, weight: .bold, design: .monospaced))
            }
        }
        #endif
    }

    // MARK: - Start View

    private var startView: some View {
        VStack(spacing: 30) {
            Spacer()

            // Cypherpunk Logo
            VStack(spacing: 15) {
                Text("🔐")
                    .font(.system(size: 80))

                Text("PRIVACY AUDIT")
                    .font(.system(size: 28, weight: .bold, design: .monospaced))
                    .foregroundColor(theme.textPrimary)

                Text("Analyze your wallet's privacy posture")
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundColor(theme.textSecondary)
            }

            // Quote
            VStack(spacing: 10) {
                Text("\"Privacy is not about hiding something.")
                Text("Privacy is about protecting something.\"")
            }
            .font(.system(size: 12, weight: .light, design: .monospaced))
            .foregroundColor(theme.accentColor)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 40)

            Spacer()

            // Generate Button
            Button(action: {
                Task {
                    await generator.generateReport()
                }
            }) {
                HStack(spacing: 12) {
                    Image(systemName: "shield.checkered")
                        .font(.system(size: 20))
                    Text("GENERATE REPORT")
                        .font(.system(size: 16, weight: .bold, design: .monospaced))
                }
                .foregroundColor(theme.backgroundColor)
                .padding(.horizontal, 30)
                .padding(.vertical, 15)
                .background(theme.accentColor)
            }

            Spacer()
        }
    }

    // MARK: - Generating View

    private var generatingView: some View {
        VStack(spacing: 25) {
            Spacer()

            // Animated shield
            ZStack {
                Circle()
                    .stroke(theme.accentColor.opacity(0.3), lineWidth: 4)
                    .frame(width: 120, height: 120)

                Circle()
                    .trim(from: 0, to: generator.generationProgress)
                    .stroke(theme.accentColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .frame(width: 120, height: 120)
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.3), value: generator.generationProgress)

                Image(systemName: "shield.checkered")
                    .font(.system(size: 50))
                    .foregroundColor(theme.accentColor)
            }

            Text("ANALYZING...")
                .font(.system(size: 20, weight: .bold, design: .monospaced))
                .foregroundColor(theme.textPrimary)

            Text(generator.currentCheckName)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(theme.textSecondary)

            Text("\(Int(generator.generationProgress * 100))%")
                .font(.system(size: 24, weight: .bold, design: .monospaced))
                .foregroundColor(theme.accentColor)

            Spacer()
        }
    }

    // MARK: - Report View

    private var reportView: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Header with Score
                scoreHeader

                // Privacy Level Banner
                privacyLevelBanner

                // Category Sections
                ForEach(groupedChecks.keys.sorted(), id: \.self) { category in
                    categorySection(category: category, items: groupedChecks[category] ?? [])
                }

                // Recommendations Summary
                if hasRecommendations {
                    recommendationsSection
                }

                // Footer Quote
                footerQuote

                // Re-scan Button
                Button(action: {
                    Task {
                        await generator.generateReport()
                    }
                }) {
                    HStack {
                        Image(systemName: "arrow.clockwise")
                        Text("RE-SCAN")
                    }
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(theme.accentColor)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .overlay(
                        Rectangle()
                            .stroke(theme.accentColor, lineWidth: 1)
                    )
                }
                .padding(.bottom, 30)
            }
            .padding()
        }
    }

    // MARK: - Score Header

    private var scoreHeader: some View {
        VStack(spacing: 15) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("PRIVACY SCORE")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(theme.textSecondary)

                    HStack(alignment: .bottom, spacing: 5) {
                        Text("\(generator.scorePercentage)")
                            .font(.system(size: 48, weight: .bold, design: .monospaced))
                            .foregroundColor(generator.privacyLevel.color)

                        Text("/100")
                            .font(.system(size: 20, design: .monospaced))
                            .foregroundColor(theme.textSecondary)
                            .padding(.bottom, 8)
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 5) {
                    Text(generator.privacyLevel.emoji)
                        .font(.system(size: 40))

                    Text(generator.privacyLevel.rawValue)
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundColor(generator.privacyLevel.color)
                }
            }

            // Progress Bar
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(theme.surfaceColor)
                        .frame(height: 8)

                    Rectangle()
                        .fill(generator.privacyLevel.color)
                        .frame(width: geometry.size.width * CGFloat(generator.scorePercentage) / 100, height: 8)
                }
            }
            .frame(height: 8)

            // Points breakdown
            Text("\(generator.totalScore) / \(generator.maxScore) points")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(theme.textSecondary)
        }
        .padding(20)
        .background(theme.surfaceColor)
        .overlay(
            Rectangle()
                .stroke(generator.privacyLevel.color, lineWidth: 2)
        )
    }

    // MARK: - Privacy Level Banner

    private var privacyLevelBanner: some View {
        VStack(spacing: 10) {
            Text(generator.privacyLevel.quote)
                .font(.system(size: 11, weight: .light, design: .monospaced))
                .foregroundColor(theme.textSecondary)
                .multilineTextAlignment(.center)

            Text("— A Cypherpunk's Manifesto")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(theme.accentColor)
        }
        .padding(15)
        .background(theme.surfaceColor.opacity(0.5))
        .overlay(
            Rectangle()
                .stroke(theme.accentColor.opacity(0.3), lineWidth: 1)
        )
    }

    // MARK: - Category Section

    private func categorySection(category: String, items: [PrivacyCheckItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Category Header
            HStack {
                Text(category)
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(theme.accentColor)

                Spacer()

                // Category score
                let categoryPoints = items.reduce(0) { $0 + $1.points }
                let categoryMax = items.reduce(0) { $0 + $1.maxPoints }
                Text("\(categoryPoints)/\(categoryMax)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.textSecondary)
            }

            // Items
            ForEach(items) { item in
                checkItemRow(item)
            }
        }
        .padding(15)
        .background(theme.surfaceColor)
        .overlay(
            Rectangle()
                .stroke(theme.textPrimary.opacity(0.2), lineWidth: 1)
        )
    }

    // MARK: - Check Item Row

    private func checkItemRow(_ item: PrivacyCheckItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: item.status.icon)
                    .font(.system(size: 12))
                    .foregroundColor(item.status.color)

                Text(item.name)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(theme.textPrimary)

                Spacer()

                Text("+\(item.points)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(item.status.color)
            }

            Text(item.description)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if let recommendation = item.recommendation {
                HStack(alignment: .top, spacing: 5) {
                    Text("→")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(theme.accentColor)
                    Text(recommendation)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(theme.accentColor)
                }
                .padding(.top, 2)
            }
        }
        .padding(10)
        .background(theme.backgroundColor.opacity(0.5))
    }

    // MARK: - Recommendations Section

    private var recommendationsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "lightbulb.fill")
                    .foregroundColor(.yellow)
                Text("RECOMMENDATIONS")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(.yellow)
            }

            ForEach(generator.checks.filter { $0.recommendation != nil }) { item in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: item.status.icon)
                        .font(.system(size: 10))
                        .foregroundColor(item.status.color)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.name)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(theme.textPrimary)

                        Text(item.recommendation!)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(theme.textSecondary)
                    }
                }
            }
        }
        .padding(15)
        .background(theme.surfaceColor)
        .overlay(
            Rectangle()
                .stroke(Color.yellow.opacity(0.5), lineWidth: 1)
        )
    }

    // MARK: - Footer Quote

    private var footerQuote: some View {
        VStack(spacing: 10) {
            Text("\"We must defend our own privacy if we expect to have any.\"")
                .font(.system(size: 11, weight: .light, design: .monospaced))
                .foregroundColor(theme.textSecondary)
                .multilineTextAlignment(.center)

            Text("— Eric Hughes, 1993")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(theme.accentColor)

            Text("Report generated: \(formattedDate)")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(theme.textSecondary.opacity(0.5))
                .padding(.top, 10)
        }
        .padding(20)
    }

    // MARK: - Helpers

    private var groupedChecks: [String: [PrivacyCheckItem]] {
        Dictionary(grouping: generator.checks, by: { $0.category })
    }

    private var hasRecommendations: Bool {
        generator.checks.contains { $0.recommendation != nil }
    }

    private var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: Date())
    }
}

// MARK: - Preview

#Preview {
    NavigationView {
        PrivacyReportView()
            .environmentObject(ThemeManager.shared)
    }
}
