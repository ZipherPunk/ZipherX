import SwiftUI

/// Windows 95 Theme
/// Classic Microsoft Windows look with teal, gray, and beveled buttons
struct Win95Theme: AppTheme {
    // MARK: - Identity
    let name = "Windows 95"
    let identifier = "win95"

    // MARK: - Classic Windows Colors
    private static let win95Gray = Color(red: 0.75, green: 0.75, blue: 0.75) // #C0C0C0
    private static let win95DarkGray = Color(red: 0.5, green: 0.5, blue: 0.5) // #808080
    private static let win95LightGray = Color(red: 0.87, green: 0.87, blue: 0.87) // #DFDFDF
    private static let win95Teal = Color(red: 0, green: 0.5, blue: 0.5) // #008080
    private static let win95Navy = Color(red: 0, green: 0, blue: 0.5) // #000080
    private static let win95White = Color.white
    private static let win95Black = Color.black

    // MARK: - Colors
    let backgroundColor = Win95Theme.win95Teal // Classic teal desktop
    let surfaceColor = Win95Theme.win95Gray
    let primaryColor = Win95Theme.win95Navy
    let secondaryColor = Win95Theme.win95DarkGray
    let accentColor = Win95Theme.win95Navy
    let textPrimary = Win95Theme.win95Black
    let textSecondary = Win95Theme.win95DarkGray
    let borderColor = Win95Theme.win95Black
    let shadowColor = Win95Theme.win95DarkGray

    // Button colors - classic 3D beveled look
    let buttonBackground = Win95Theme.win95Gray
    let buttonText = Win95Theme.win95Black
    let buttonBorder = Win95Theme.win95Black
    let buttonHighlight = Win95Theme.win95White
    let buttonShadow = Win95Theme.win95DarkGray

    // Status colors
    let successColor = Color.green
    let errorColor = Color.red
    let warningColor = Color.yellow

    // MARK: - Typography - MS Sans Serif style
    var titleFont: Font { .system(size: 11, weight: .bold, design: .default) }
    var bodyFont: Font { .system(size: 11, weight: .regular, design: .default) }
    var monoFont: Font { .system(size: 10, weight: .regular, design: .monospaced) }
    var captionFont: Font { .system(size: 9, weight: .regular, design: .default) }

    // MARK: - Appearance
    let cornerRadius: CGFloat = 0 // Sharp corners
    let borderWidth: CGFloat = 2 // Thicker beveled borders
    let usesGradients = false
    let usesShadows = false
    let hasRetroStyling = true

    // MARK: - Window Style
    let windowTitleBarHeight: CGFloat = 18
    let windowHasStripes = false

    // MARK: - Progress Bar
    let progressBarHeight: CGFloat = 16
    let progressBarFill = Win95Theme.win95Navy
    let progressBarBackground = Win95Theme.win95White
}
