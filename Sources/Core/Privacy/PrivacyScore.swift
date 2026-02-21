import Foundation
import SwiftUI

/// Privacy Score Calculator for ZipherX
/// Calculates a privacy score (0-100) based on various factors
public class PrivacyScoreManager: ObservableObject {
    public static let shared = PrivacyScoreManager()

    // MARK: - Published Properties

    @Published public private(set) var totalScore: Int = 0
    @Published public private(set) var fundPrivacyScore: Int = 0
    @Published public private(set) var encryptionScore: Int = 0
    @Published public private(set) var networkScore: Int = 0
    @Published public private(set) var operationalScore: Int = 0

    // MARK: - Score Thresholds

    /// Maximum points for each category
    public struct ScoreWeights {
        static let fundPrivacy = 35      // How much of your funds are shielded
        static let encryption = 30       // Database encryption, key storage
        static let network = 20          // P2P connections, Tor (future)
        static let operational = 15      // Debug logging, backup status
    }

    private init() {}

    // MARK: - Score Calculation

    /// Calculate privacy score based on current wallet state
    /// Call this whenever balance or settings change
    @MainActor
    public func calculateScore(
        shieldedBalance: Double,
        transparentBalance: Double,
        isDatabaseEncrypted: Bool,
        isKeyEncrypted: Bool,
        peerCount: Int,
        isDebugLoggingEnabled: Bool,
        hasBackup: Bool,
        isTorEnabled: Bool = false
    ) {
        let total = shieldedBalance + transparentBalance

        // 1. Fund Privacy Score (0-35 points)
        // All shielded = 35 points, all transparent = 0 points
        if total > 0 {
            if transparentBalance > 0 {
                let shieldedRatio = shieldedBalance / total
                fundPrivacyScore = Int(shieldedRatio * Double(ScoreWeights.fundPrivacy))
            } else {
                fundPrivacyScore = ScoreWeights.fundPrivacy // All shielded
            }
        } else {
            fundPrivacyScore = ScoreWeights.fundPrivacy // No funds = no privacy issue
        }

        // 2. Encryption Score (0-30 points)
        // Database encryption: 15 points
        // Key encryption: 15 points
        var encScore = 0
        if isDatabaseEncrypted {
            encScore += 15
        }
        if isKeyEncrypted {
            encScore += 15
        }
        encryptionScore = encScore

        // 3. Network Score (0-20 points)
        // P2P connections: up to 10 points (1 point per peer, max 10)
        // Tor routing: 10 points
        var netScore = 0
        netScore += min(peerCount, 10) // Up to 10 points for peer count
        if isTorEnabled {
            netScore += 10 // Tor routing active
        }
        networkScore = netScore

        // 4. Operational Score (0-15 points)
        // Debug logging disabled: 10 points
        // Backup confirmed: 5 points
        var opScore = 0
        if !isDebugLoggingEnabled {
            opScore += 10
        }
        if hasBackup {
            opScore += 5
        }
        operationalScore = opScore

        // Total Score
        totalScore = fundPrivacyScore + encryptionScore + networkScore + operationalScore
    }

    // MARK: - Score Status

    /// Get status emoji and text based on score
    public var scoreStatus: (emoji: String, text: String, color: Color) {
        if totalScore >= 90 {
            return ("🟢", "EXCELLENT", .green)
        } else if totalScore >= 70 {
            return ("🟡", "GOOD", .yellow)
        } else if totalScore >= 50 {
            return ("🟠", "MODERATE", .orange)
        } else {
            return ("🔴", "POOR", .red)
        }
    }

    /// Get color for a specific score value
    public static func colorForScore(_ score: Int, maxScore: Int) -> Color {
        let percentage = maxScore > 0 ? Double(score) / Double(maxScore) * 100 : 0
        if percentage >= 90 {
            return .green
        } else if percentage >= 70 {
            return .yellow
        } else if percentage >= 50 {
            return .orange
        } else {
            return .red
        }
    }

    /// Get emoji for a specific score value
    public static func emojiForScore(_ score: Int, maxScore: Int) -> String {
        let percentage = maxScore > 0 ? Double(score) / Double(maxScore) * 100 : 0
        if percentage >= 90 {
            return "🟢"
        } else if percentage >= 70 {
            return "🟡"
        } else if percentage >= 50 {
            return "🟠"
        } else {
            return "🔴"
        }
    }

    // MARK: - Recommendations

    /// Get privacy improvement recommendations
    public var recommendations: [PrivacyRecommendation] {
        var recs: [PrivacyRecommendation] = []

        // Fund privacy
        if fundPrivacyScore < ScoreWeights.fundPrivacy {
            recs.append(PrivacyRecommendation(
                category: "Fund Privacy",
                issue: "Some funds in transparent addresses",
                recommendation: "Shield all funds to z-addresses for maximum privacy",
                priority: .high
            ))
        }

        // Encryption
        if encryptionScore < 15 {
            recs.append(PrivacyRecommendation(
                category: "Database Encryption",
                issue: "Database not fully encrypted",
                recommendation: "Ensure SQLCipher is enabled for full database encryption",
                priority: .critical
            ))
        }

        // Network
        if networkScore < 10 {
            recs.append(PrivacyRecommendation(
                category: "Network Privacy",
                issue: "Limited peer connections",
                recommendation: "Connect to more peers for better network privacy",
                priority: .medium
            ))
        }

        // Operational
        if operationalScore < 10 {
            recs.append(PrivacyRecommendation(
                category: "Debug Logging",
                issue: "Debug logging is enabled",
                recommendation: "Disable debug logging to prevent sensitive data leaks",
                priority: .high
            ))
        }

        return recs
    }
}

/// A privacy improvement recommendation
public struct PrivacyRecommendation: Identifiable {
    public let id = UUID()
    public let category: String
    public let issue: String
    public let recommendation: String
    public let priority: Priority

    public enum Priority: String {
        case critical = "Critical"
        case high = "High"
        case medium = "Medium"
        case low = "Low"

        var color: Color {
            switch self {
            case .critical: return .red
            case .high: return .orange
            case .medium: return .yellow
            case .low: return .green
            }
        }
    }
}
