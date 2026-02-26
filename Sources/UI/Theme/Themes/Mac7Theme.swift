import SwiftUI

/// Classic Macintosh System 7 Theme
/// Inspired by the 1991 Mac OS with 1-bit aesthetic and Chicago font
struct Mac7Theme: AppTheme {
    // MARK: - Identity
    let name = "System 7"
    let identifier = "mac7"

    // MARK: - Colors
    let backgroundColor = Color(white: 0.75) // Classic Mac gray
    let surfaceColor = Color.white
    let primaryColor = Color.black
    let secondaryColor = Color(white: 0.5)
    let accentColor = Color.black
    let textPrimary = Color.black
    let textSecondary = Color(white: 0.3)
    let borderColor = Color.black
    let shadowColor = Color(white: 0.5)

    // Button colors - classic beveled look
    let buttonBackground = Color(white: 0.9)
    let buttonText = Color.black
    let buttonBorder = Color.black
    let buttonHighlight = Color.white
    let buttonShadow = Color(white: 0.5)

    // Status colors
    let successColor = Color.black // System 7 didn't have color feedback
    let errorColor = Color.black
    let warningColor = Color.black

    // MARK: - Typography
    var titleFont: Font { .system(size: 12, weight: .bold, design: .monospaced) }
    var bodyFont: Font { .system(size: 11, weight: .regular, design: .monospaced) }
    var monoFont: Font { .system(size: 10, weight: .regular, design: .monospaced) }
    var captionFont: Font { .system(size: 9, weight: .regular, design: .monospaced) }

    // MARK: - Appearance
    let cornerRadius: CGFloat = 0 // Sharp corners
    let borderWidth: CGFloat = 1
    let usesGradients = false
    let usesShadows = false
    let hasRetroStyling = true

    // MARK: - Window Style
    let windowTitleBarHeight: CGFloat = 20
    let windowHasStripes = true

    // MARK: - Progress Bar
    let progressBarHeight: CGFloat = 16
    let progressBarFill = Color.black
    let progressBarBackground = Color.white
}
