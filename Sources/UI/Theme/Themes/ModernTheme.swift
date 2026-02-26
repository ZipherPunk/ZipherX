import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

/// Modern iOS Theme
/// Clean, minimal design following Apple's Human Interface Guidelines
struct ModernTheme: AppTheme {
    // MARK: - Identity
    let name = "Modern"
    let identifier = "modern"

    // MARK: - Colors - Platform-adaptive
    #if os(macOS)
    private static let systemBackground = Color(NSColor.windowBackgroundColor)
    private static let secondarySystemBackground = Color(NSColor.controlBackgroundColor)
    private static let labelColor = Color(NSColor.labelColor)
    private static let secondaryLabelColor = Color(NSColor.secondaryLabelColor)
    #else
    private static let systemBackground = Color(UIColor.systemBackground)
    private static let secondarySystemBackground = Color(UIColor.secondarySystemBackground)
    private static let labelColor = Color(UIColor.label)
    private static let secondaryLabelColor = Color(UIColor.secondaryLabel)
    #endif

    // MARK: - Colors
    var backgroundColor: Color { ModernTheme.systemBackground }
    var surfaceColor: Color { ModernTheme.secondarySystemBackground }
    let primaryColor = Color.blue
    let secondaryColor = Color.gray
    let accentColor = Color.blue
    var textPrimary: Color { ModernTheme.labelColor }
    var textSecondary: Color { ModernTheme.secondaryLabelColor }
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
