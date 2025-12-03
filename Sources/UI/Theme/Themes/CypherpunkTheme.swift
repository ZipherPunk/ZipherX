import SwiftUI

/// Cypherpunk Theme - Dark terminal hacker aesthetic
/// macOS: Bitcoin Orange (desktop full-node style)
/// iOS: Neon Green (Matrix terminal style)
struct CypherpunkTheme: AppTheme {
    // MARK: - Identity
    let name = "Cypherpunk"
    let identifier = "cypherpunk"

    // MARK: - Platform Detection
    #if os(macOS)
    private static let isMacOS = true
    #else
    private static let isMacOS = false
    #endif

    // MARK: - macOS Orange Colors
    private static let orangePrimary = Color(red: 1.0, green: 0.4, blue: 0.0)
    private static let orangePrimaryDark = Color(red: 0.8, green: 0.3, blue: 0.0)
    private static let orangePrimaryDim = Color(red: 0.5, green: 0.2, blue: 0.0)
    private static let orangeTerminalDark = Color(red: 0.06, green: 0.04, blue: 0.02)
    private static let orangeProgressBg = Color(red: 0.15, green: 0.1, blue: 0.02)

    // MARK: - iOS Green Colors
    private static let greenPrimary = Color(red: 0, green: 1, blue: 0.25)
    private static let greenPrimaryDark = Color(red: 0, green: 0.7, blue: 0.15)
    private static let greenPrimaryDim = Color(red: 0, green: 0.4, blue: 0.1)
    private static let greenTerminalDark = Color(red: 0.05, green: 0.08, blue: 0.05)
    private static let greenProgressBg = Color(red: 0, green: 0.15, blue: 0.05)

    // MARK: - Shared Colors
    private static let terminalBlack = Color(red: 0.02, green: 0.02, blue: 0.02)

    // MARK: - Platform-selected Colors
    private static var primaryAccent: Color { isMacOS ? orangePrimary : greenPrimary }
    private static var primaryAccentDark: Color { isMacOS ? orangePrimaryDark : greenPrimaryDark }
    private static var primaryAccentDim: Color { isMacOS ? orangePrimaryDim : greenPrimaryDim }
    private static var terminalDark: Color { isMacOS ? orangeTerminalDark : greenTerminalDark }

    // MARK: - Colors
    let backgroundColor = CypherpunkTheme.terminalBlack
    var surfaceColor: Color { CypherpunkTheme.terminalDark }
    var primaryColor: Color { CypherpunkTheme.primaryAccent }
    var secondaryColor: Color { CypherpunkTheme.primaryAccentDark }
    var accentColor: Color { CypherpunkTheme.primaryAccent }
    var textPrimary: Color { CypherpunkTheme.primaryAccent }
    var textSecondary: Color { CypherpunkTheme.primaryAccentDark }
    var borderColor: Color { CypherpunkTheme.primaryAccentDim }
    var shadowColor: Color { CypherpunkTheme.primaryAccent.opacity(0.3) }

    // Button colors
    var buttonBackground: Color { CypherpunkTheme.terminalDark }
    var buttonText: Color { CypherpunkTheme.primaryAccent }
    var buttonBorder: Color { CypherpunkTheme.primaryAccentDim }
    var buttonHighlight: Color { CypherpunkTheme.primaryAccent }
    var buttonShadow: Color { CypherpunkTheme.primaryAccentDim }

    // Status colors
    var successColor: Color { CypherpunkTheme.isMacOS ? Color(red: 0.2, green: 0.8, blue: 0.2) : CypherpunkTheme.primaryAccent }
    let errorColor = Color.red
    let warningColor = Color.yellow

    // MARK: - Typography (larger on macOS for desktop readability)
    #if os(macOS)
    var titleFont: Font { .system(size: 18, weight: .bold, design: .monospaced) }
    var bodyFont: Font { .system(size: 14, weight: .regular, design: .monospaced) }
    var monoFont: Font { .system(size: 13, weight: .regular, design: .monospaced) }
    var captionFont: Font { .system(size: 12, weight: .regular, design: .monospaced) }
    #else
    var titleFont: Font { .system(size: 14, weight: .bold, design: .monospaced) }
    var bodyFont: Font { .system(size: 12, weight: .regular, design: .monospaced) }
    var monoFont: Font { .system(size: 11, weight: .regular, design: .monospaced) }
    var captionFont: Font { .system(size: 10, weight: .regular, design: .monospaced) }
    #endif

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
    var progressBarFill: Color { CypherpunkTheme.primaryAccent }
    var progressBarBackground: Color { CypherpunkTheme.isMacOS ? CypherpunkTheme.orangeProgressBg : CypherpunkTheme.greenProgressBg }
}
