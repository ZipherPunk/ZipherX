import SwiftUI

/// Cypherpunk Theme - Dark terminal hacker aesthetic
/// Inspired by Matrix, terminal UIs, and the cypherpunk movement
struct CypherpunkTheme: AppTheme {
    // MARK: - Identity
    let name = "Cypherpunk"
    let identifier = "cypherpunk"

    // MARK: - Neon Colors
    private static let neonGreen = Color(red: 0, green: 1, blue: 0.25)
    private static let neonGreenDark = Color(red: 0, green: 0.7, blue: 0.15)
    private static let neonGreenDim = Color(red: 0, green: 0.4, blue: 0.1)
    private static let terminalBlack = Color(red: 0.02, green: 0.02, blue: 0.02)
    private static let terminalDark = Color(red: 0.05, green: 0.08, blue: 0.05)

    // MARK: - Colors
    let backgroundColor = CypherpunkTheme.terminalBlack
    let surfaceColor = CypherpunkTheme.terminalDark
    let primaryColor = CypherpunkTheme.neonGreen
    let secondaryColor = CypherpunkTheme.neonGreenDark
    let accentColor = CypherpunkTheme.neonGreen
    let textPrimary = CypherpunkTheme.neonGreen
    let textSecondary = CypherpunkTheme.neonGreenDark
    let borderColor = CypherpunkTheme.neonGreenDim
    let shadowColor = CypherpunkTheme.neonGreen.opacity(0.3)

    // Button colors
    let buttonBackground = CypherpunkTheme.terminalDark
    let buttonText = CypherpunkTheme.neonGreen
    let buttonBorder = CypherpunkTheme.neonGreenDim
    let buttonHighlight = CypherpunkTheme.neonGreen
    let buttonShadow = CypherpunkTheme.neonGreenDim

    // Status colors
    let successColor = CypherpunkTheme.neonGreen
    let errorColor = Color.red
    let warningColor = Color.yellow

    // MARK: - Typography
    var titleFont: Font { .system(size: 14, weight: .bold, design: .monospaced) }
    var bodyFont: Font { .system(size: 12, weight: .regular, design: .monospaced) }
    var monoFont: Font { .system(size: 11, weight: .regular, design: .monospaced) }
    var captionFont: Font { .system(size: 10, weight: .regular, design: .monospaced) }

    // MARK: - Appearance
    let cornerRadius: CGFloat = 0 // Sharp terminal look
    let borderWidth: CGFloat = 1
    let usesGradients = true // Neon gradients
    let usesShadows = true // Glow effects
    let hasRetroStyling = false

    // MARK: - Window Style
    let windowTitleBarHeight: CGFloat = 24
    let windowHasStripes = false

    // MARK: - Progress Bar
    let progressBarHeight: CGFloat = 12
    var progressBarFill: Color { CypherpunkTheme.neonGreen }
    var progressBarBackground: Color { Color(red: 0, green: 0.15, blue: 0.05) }
}
