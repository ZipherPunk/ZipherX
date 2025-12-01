import SwiftUI

/// Modern iOS Theme
/// Clean, minimal design following Apple's Human Interface Guidelines
struct ModernTheme: AppTheme {
    // MARK: - Identity
    let name = "Modern"
    let identifier = "modern"

    // MARK: - Colors - iOS-inspired
    private static let iosBackground = Color(UIColor.systemBackground)
    private static let iosSurface = Color(UIColor.secondarySystemBackground)
    private static let iosPrimary = Color.blue
    private static let iosSecondary = Color(UIColor.secondaryLabel)
    private static let iosText = Color(UIColor.label)
    private static let iosTextSecondary = Color(UIColor.secondaryLabel)

    // MARK: - Colors
    var backgroundColor: Color { ModernTheme.iosBackground }
    var surfaceColor: Color { ModernTheme.iosSurface }
    let primaryColor = Color.blue
    let secondaryColor = Color.gray
    let accentColor = Color.blue
    var textPrimary: Color { ModernTheme.iosText }
    var textSecondary: Color { ModernTheme.iosTextSecondary }
    let borderColor = Color.gray.opacity(0.3)
    let shadowColor = Color.black.opacity(0.1)

    // Button colors - iOS style
    let buttonBackground = Color.blue
    let buttonText = Color.white
    let buttonBorder = Color.clear
    let buttonHighlight = Color.blue.opacity(0.8)
    let buttonShadow = Color.black.opacity(0.1)

    // Status colors
    let successColor = Color.green
    let errorColor = Color.red
    let warningColor = Color.orange

    // MARK: - Typography - SF Pro style
    var titleFont: Font { .system(size: 17, weight: .semibold, design: .default) }
    var bodyFont: Font { .system(size: 15, weight: .regular, design: .default) }
    var monoFont: Font { .system(size: 13, weight: .regular, design: .monospaced) }
    var captionFont: Font { .system(size: 12, weight: .regular, design: .default) }

    // MARK: - Appearance
    let cornerRadius: CGFloat = 12 // Rounded corners
    let borderWidth: CGFloat = 0.5
    let usesGradients = true
    let usesShadows = true
    let hasRetroStyling = false

    // MARK: - Window Style (not really used in modern)
    let windowTitleBarHeight: CGFloat = 0
    let windowHasStripes = false

    // MARK: - Progress Bar
    let progressBarHeight: CGFloat = 8
    let progressBarFill = Color.blue
    var progressBarBackground: Color { Color.gray.opacity(0.2) }
}
