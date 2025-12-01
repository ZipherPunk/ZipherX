import SwiftUI

/// Cypherpunk Theme - Dark terminal hacker aesthetic
/// macOS: Bitcoin Orange (desktop full-node style)
/// iOS: Neon Green (Matrix terminal style)
struct CypherpunkTheme: AppTheme {
    // MARK: - Identity
    let name = "Cypherpunk"
    let identifier = "cypherpunk"

    // MARK: - Platform-specific Colors
    #if os(macOS)
    // NEON FLUO Orange palette for macOS (bright like the neon green, Bitcoin-inspired)
    private static let primaryAccent = Color(red: 1.0, green: 0.4, blue: 0.0)       // Bright neon orange
    private static let primaryAccentDark = Color(red: 0.8, green: 0.3, blue: 0.0)   // Dark neon orange
    private static let primaryAccentDim = Color(red: 0.5, green: 0.2, blue: 0.0)    // Dim orange
    private static let terminalBlack = Color(red: 0.02, green: 0.02, blue: 0.02)
    private static let terminalDark = Color(red: 0.06, green: 0.04, blue: 0.02)     // Slight orange tint
    #else
    // Neon Green palette for iOS (Matrix style)
    private static let primaryAccent = Color(red: 0, green: 1, blue: 0.25)
    private static let primaryAccentDark = Color(red: 0, green: 0.7, blue: 0.15)
    private static let primaryAccentDim = Color(red: 0, green: 0.4, blue: 0.1)
    private static let terminalBlack = Color(red: 0.02, green: 0.02, blue: 0.02)
    private static let terminalDark = Color(red: 0.05, green: 0.08, blue: 0.05)
    #endif

    // MARK: - Colors
    let backgroundColor = CypherpunkTheme.terminalBlack
    let surfaceColor = CypherpunkTheme.terminalDark
    let primaryColor = CypherpunkTheme.primaryAccent
    let secondaryColor = CypherpunkTheme.primaryAccentDark
    let accentColor = CypherpunkTheme.primaryAccent
    let textPrimary = CypherpunkTheme.primaryAccent
    let textSecondary = CypherpunkTheme.primaryAccentDark
    let borderColor = CypherpunkTheme.primaryAccentDim
    let shadowColor = CypherpunkTheme.primaryAccent.opacity(0.3)

    // Button colors
    let buttonBackground = CypherpunkTheme.terminalDark
    let buttonText = CypherpunkTheme.primaryAccent
    let buttonBorder = CypherpunkTheme.primaryAccentDim
    let buttonHighlight = CypherpunkTheme.primaryAccent
    let buttonShadow = CypherpunkTheme.primaryAccentDim

    // Status colors
    #if os(macOS)
    let successColor = Color(red: 0.2, green: 0.8, blue: 0.2)  // Green for success on orange theme
    #else
    let successColor = CypherpunkTheme.primaryAccent  // Neon green IS success on iOS
    #endif
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
    #if os(macOS)
    var progressBarBackground: Color { Color(red: 0.15, green: 0.1, blue: 0.02) }  // Dark orange tint
    #else
    var progressBarBackground: Color { Color(red: 0, green: 0.15, blue: 0.05) }    // Dark green tint
    #endif
}
