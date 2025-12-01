import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Macintosh System 7 Design System
enum System7Theme {
    // MARK: - Colors (1-bit inspired with some grays)
    static let black = Color.black
    static let white = Color.white
    static let gray = Color(white: 0.75)
    static let darkGray = Color(white: 0.5)
    static let lightGray = Color(white: 0.9)

    // MARK: - Typography
    static let chicagoFont = "Chicago"
    static let monacoFont = "Monaco"
    static let genevaFont = "Geneva"

    // System fonts (fallback to SF Mono for similar feel)
    static func systemFont(size: CGFloat) -> Font {
        .custom("Menlo", size: size)
    }

    static func titleFont(size: CGFloat = 12) -> Font {
        .system(size: size, weight: .bold, design: .monospaced)
    }

    static func bodyFont(size: CGFloat = 11) -> Font {
        .system(size: size, weight: .regular, design: .monospaced)
    }

    static func monoFont(size: CGFloat = 10) -> Font {
        .system(size: size, weight: .regular, design: .monospaced)
    }

    // MARK: - Desktop Pattern
    static var desktopPattern: some View {
        Canvas { context, size in
            // Classic Mac desktop pattern (diagonal lines)
            let patternSize: CGFloat = 4
            for x in stride(from: 0, to: size.width + patternSize, by: patternSize) {
                for y in stride(from: 0, to: size.height + patternSize, by: patternSize) {
                    if (Int(x / patternSize) + Int(y / patternSize)) % 2 == 0 {
                        context.fill(
                            Path(CGRect(x: x, y: y, width: patternSize / 2, height: patternSize / 2)),
                            with: .color(gray)
                        )
                    }
                }
            }
        }
        .background(lightGray)
    }

    // MARK: - Borders
    static func classicBorder(raised: Bool = true) -> some View {
        RoundedRectangle(cornerRadius: 0)
            .strokeBorder(
                LinearGradient(
                    colors: raised ? [white, darkGray] : [darkGray, white],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 2
            )
    }
}

// MARK: - View Extensions
extension View {
    func system7ButtonStyle(isPressed: Bool = false) -> some View {
        self
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isPressed ? System7Theme.darkGray : System7Theme.lightGray)
            .overlay(
                Rectangle()
                    .strokeBorder(
                        LinearGradient(
                            colors: isPressed
                                ? [System7Theme.darkGray, System7Theme.white]
                                : [System7Theme.white, System7Theme.darkGray],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 2
                    )
            )
            .overlay(
                Rectangle()
                    .stroke(System7Theme.black, lineWidth: 1)
            )
    }
}

// MARK: - Theme Protocol

/// Protocol defining all theme properties
protocol AppTheme {
    // MARK: - Identity
    var name: String { get }
    var identifier: String { get }

    // MARK: - Colors
    var backgroundColor: Color { get }
    var surfaceColor: Color { get }
    var primaryColor: Color { get }
    var secondaryColor: Color { get }
    var accentColor: Color { get }
    var textPrimary: Color { get }
    var textSecondary: Color { get }
    var borderColor: Color { get }
    var shadowColor: Color { get }

    // Button colors
    var buttonBackground: Color { get }
    var buttonText: Color { get }
    var buttonBorder: Color { get }
    var buttonHighlight: Color { get }
    var buttonShadow: Color { get }

    // Status colors
    var successColor: Color { get }
    var errorColor: Color { get }
    var warningColor: Color { get }

    // MARK: - Typography
    var titleFont: Font { get }
    var bodyFont: Font { get }
    var monoFont: Font { get }
    var captionFont: Font { get }

    // MARK: - Appearance
    var cornerRadius: CGFloat { get }
    var borderWidth: CGFloat { get }
    var usesGradients: Bool { get }
    var usesShadows: Bool { get }
    var hasRetroStyling: Bool { get }

    // MARK: - Window Style
    var windowTitleBarHeight: CGFloat { get }
    var windowHasStripes: Bool { get }

    // MARK: - Progress Bar
    var progressBarHeight: CGFloat { get }
    var progressBarFill: Color { get }
    var progressBarBackground: Color { get }
}

// MARK: - Theme Type Enum

enum ThemeType: String, CaseIterable, Identifiable {
    case mac7 = "mac7"
    case cypherpunk = "cypherpunk"
    case win95 = "win95"
    case modern = "modern"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .mac7: return "System 7"
        case .cypherpunk: return "Cypherpunk"
        case .win95: return "Windows 95"
        case .modern: return "Modern"
        }
    }

    var description: String {
        switch self {
        case .mac7: return "Classic Macintosh aesthetic"
        case .cypherpunk: return "Dark hacker terminal"
        case .win95: return "Retro Windows style"
        case .modern: return "Clean iOS design"
        }
    }

    var theme: AppTheme {
        switch self {
        case .mac7: return Mac7Theme()
        case .cypherpunk: return CypherpunkTheme()
        case .win95: return Win95Theme()
        case .modern: return ModernTheme()
        }
    }
}

// MARK: - Theme Manager

/// Manages the current app theme and persists selection
final class ThemeManager: ObservableObject {
    static let shared = ThemeManager()

    @Published private(set) var currentTheme: AppTheme
    @Published private(set) var currentThemeType: ThemeType

    private let userDefaultsKey = "selectedTheme"

    private init() {
        // Load saved theme or default to mac7
        let savedTheme = UserDefaults.standard.string(forKey: userDefaultsKey) ?? "mac7"
        let themeType = ThemeType(rawValue: savedTheme) ?? .mac7
        self.currentThemeType = themeType
        self.currentTheme = themeType.theme
    }

    func setTheme(_ type: ThemeType) {
        currentThemeType = type
        currentTheme = type.theme
        UserDefaults.standard.set(type.rawValue, forKey: userDefaultsKey)
    }
}

// MARK: - Mac7 Theme (System 7)

/// Classic Macintosh System 7 Theme
struct Mac7Theme: AppTheme {
    let name = "System 7"
    let identifier = "mac7"

    let backgroundColor = Color(white: 0.75)
    let surfaceColor = Color.white
    let primaryColor = Color.black
    let secondaryColor = Color(white: 0.5)
    let accentColor = Color.black
    let textPrimary = Color.black
    let textSecondary = Color(white: 0.3)
    let borderColor = Color.black
    let shadowColor = Color(white: 0.5)

    let buttonBackground = Color(white: 0.9)
    let buttonText = Color.black
    let buttonBorder = Color.black
    let buttonHighlight = Color.white
    let buttonShadow = Color(white: 0.5)

    let successColor = Color.black
    let errorColor = Color.black
    let warningColor = Color.black

    var titleFont: Font { .system(size: 12, weight: .bold, design: .monospaced) }
    var bodyFont: Font { .system(size: 11, weight: .regular, design: .monospaced) }
    var monoFont: Font { .system(size: 10, weight: .regular, design: .monospaced) }
    var captionFont: Font { .system(size: 9, weight: .regular, design: .monospaced) }

    let cornerRadius: CGFloat = 0
    let borderWidth: CGFloat = 1
    let usesGradients = false
    let usesShadows = false
    let hasRetroStyling = true

    let windowTitleBarHeight: CGFloat = 20
    let windowHasStripes = true

    let progressBarHeight: CGFloat = 16
    let progressBarFill = Color.black
    let progressBarBackground = Color.white
}

// MARK: - Cypherpunk Theme

/// Dark terminal hacker aesthetic
struct CypherpunkTheme: AppTheme {
    let name = "Cypherpunk"
    let identifier = "cypherpunk"

    private static let neonGreen = Color(red: 0, green: 1, blue: 0.25)
    private static let neonGreenDark = Color(red: 0, green: 0.7, blue: 0.15)
    private static let neonGreenDim = Color(red: 0, green: 0.4, blue: 0.1)
    private static let terminalBlack = Color(red: 0.02, green: 0.02, blue: 0.02)
    private static let terminalDark = Color(red: 0.05, green: 0.08, blue: 0.05)

    let backgroundColor = CypherpunkTheme.terminalBlack
    let surfaceColor = CypherpunkTheme.terminalDark
    let primaryColor = CypherpunkTheme.neonGreen
    let secondaryColor = CypherpunkTheme.neonGreenDark
    let accentColor = CypherpunkTheme.neonGreen
    let textPrimary = CypherpunkTheme.neonGreen
    let textSecondary = CypherpunkTheme.neonGreenDark
    let borderColor = CypherpunkTheme.neonGreenDim
    let shadowColor = CypherpunkTheme.neonGreen.opacity(0.3)

    let buttonBackground = CypherpunkTheme.terminalDark
    let buttonText = CypherpunkTheme.neonGreen
    let buttonBorder = CypherpunkTheme.neonGreenDim
    let buttonHighlight = CypherpunkTheme.neonGreen
    let buttonShadow = CypherpunkTheme.neonGreenDim

    let successColor = CypherpunkTheme.neonGreen
    let errorColor = Color.red
    let warningColor = Color.yellow

    var titleFont: Font { .system(size: 14, weight: .bold, design: .monospaced) }
    var bodyFont: Font { .system(size: 12, weight: .regular, design: .monospaced) }
    var monoFont: Font { .system(size: 11, weight: .regular, design: .monospaced) }
    var captionFont: Font { .system(size: 10, weight: .regular, design: .monospaced) }

    let cornerRadius: CGFloat = 0
    let borderWidth: CGFloat = 1
    let usesGradients = true
    let usesShadows = true
    let hasRetroStyling = false

    let windowTitleBarHeight: CGFloat = 24
    let windowHasStripes = false

    let progressBarHeight: CGFloat = 12
    var progressBarFill: Color { CypherpunkTheme.neonGreen }
    var progressBarBackground: Color { Color(red: 0, green: 0.15, blue: 0.05) }
}

// MARK: - Windows 95 Theme

/// Classic Microsoft Windows look
struct Win95Theme: AppTheme {
    let name = "Windows 95"
    let identifier = "win95"

    private static let win95Gray = Color(red: 0.75, green: 0.75, blue: 0.75)
    private static let win95DarkGray = Color(red: 0.5, green: 0.5, blue: 0.5)
    private static let win95Teal = Color(red: 0, green: 0.5, blue: 0.5)
    private static let win95Navy = Color(red: 0, green: 0, blue: 0.5)
    private static let win95White = Color.white
    private static let win95Black = Color.black

    let backgroundColor = Win95Theme.win95Teal
    let surfaceColor = Win95Theme.win95Gray
    let primaryColor = Win95Theme.win95Navy
    let secondaryColor = Win95Theme.win95DarkGray
    let accentColor = Win95Theme.win95Navy
    let textPrimary = Win95Theme.win95Black
    let textSecondary = Win95Theme.win95DarkGray
    let borderColor = Win95Theme.win95Black
    let shadowColor = Win95Theme.win95DarkGray

    let buttonBackground = Win95Theme.win95Gray
    let buttonText = Win95Theme.win95Black
    let buttonBorder = Win95Theme.win95Black
    let buttonHighlight = Win95Theme.win95White
    let buttonShadow = Win95Theme.win95DarkGray

    let successColor = Color.green
    let errorColor = Color.red
    let warningColor = Color.yellow

    var titleFont: Font { .system(size: 11, weight: .bold, design: .default) }
    var bodyFont: Font { .system(size: 11, weight: .regular, design: .default) }
    var monoFont: Font { .system(size: 10, weight: .regular, design: .monospaced) }
    var captionFont: Font { .system(size: 9, weight: .regular, design: .default) }

    let cornerRadius: CGFloat = 0
    let borderWidth: CGFloat = 2
    let usesGradients = false
    let usesShadows = false
    let hasRetroStyling = true

    let windowTitleBarHeight: CGFloat = 18
    let windowHasStripes = false

    let progressBarHeight: CGFloat = 16
    let progressBarFill = Win95Theme.win95Navy
    let progressBarBackground = Win95Theme.win95White
}

// MARK: - Modern Theme (iOS)

/// Clean, minimal design following Apple's HIG
struct ModernTheme: AppTheme {
    let name = "Modern"
    let identifier = "modern"

    #if os(iOS)
    var backgroundColor: Color { Color(UIColor.systemBackground) }
    var surfaceColor: Color { Color(UIColor.secondarySystemBackground) }
    #else
    var backgroundColor: Color { Color(NSColor.windowBackgroundColor) }
    var surfaceColor: Color { Color(NSColor.controlBackgroundColor) }
    #endif
    let primaryColor = Color.blue
    let secondaryColor = Color.gray
    let accentColor = Color.blue
    #if os(iOS)
    var textPrimary: Color { Color(UIColor.label) }
    var textSecondary: Color { Color(UIColor.secondaryLabel) }
    #else
    var textPrimary: Color { Color(NSColor.labelColor) }
    var textSecondary: Color { Color(NSColor.secondaryLabelColor) }
    #endif
    let borderColor = Color.gray.opacity(0.3)
    let shadowColor = Color.black.opacity(0.1)

    let buttonBackground = Color.blue
    let buttonText = Color.white
    let buttonBorder = Color.clear
    let buttonHighlight = Color.blue.opacity(0.8)
    let buttonShadow = Color.black.opacity(0.1)

    let successColor = Color.green
    let errorColor = Color.red
    let warningColor = Color.orange

    var titleFont: Font { .system(size: 17, weight: .semibold, design: .default) }
    var bodyFont: Font { .system(size: 15, weight: .regular, design: .default) }
    var monoFont: Font { .system(size: 13, weight: .regular, design: .monospaced) }
    var captionFont: Font { .system(size: 12, weight: .regular, design: .default) }

    let cornerRadius: CGFloat = 12
    let borderWidth: CGFloat = 0.5
    let usesGradients = true
    let usesShadows = true
    let hasRetroStyling = false

    let windowTitleBarHeight: CGFloat = 0
    let windowHasStripes = false

    let progressBarHeight: CGFloat = 8
    let progressBarFill = Color.blue
    var progressBarBackground: Color { Color.gray.opacity(0.2) }
}

// MARK: - Theme Preview Card

struct ThemePreviewCard: View {
    @EnvironmentObject var themeManager: ThemeManager
    let themeType: ThemeType
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                // Preview thumbnail
                themePreview(for: themeType)
                    .frame(height: 60)
                    .cornerRadius(4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(isSelected ? Color.blue : Color.gray.opacity(0.3), lineWidth: isSelected ? 2 : 1)
                    )

                // Theme name
                Text(themeType.displayName)
                    .font(.system(size: 11, weight: isSelected ? .bold : .regular))
                    .foregroundColor(isSelected ? .blue : .primary)
            }
        }
        .buttonStyle(PlainButtonStyle())
    }

    @ViewBuilder
    private func themePreview(for type: ThemeType) -> some View {
        let theme = type.theme

        ZStack {
            // Background
            Rectangle()
                .fill(theme.backgroundColor)

            // Window preview
            VStack(spacing: 0) {
                // Title bar
                Rectangle()
                    .fill(theme.surfaceColor)
                    .frame(height: 8)
                    .overlay(
                        Rectangle()
                            .stroke(theme.borderColor, lineWidth: 0.5)
                    )

                // Content
                Rectangle()
                    .fill(theme.surfaceColor)

                // Button preview
                HStack {
                    RoundedRectangle(cornerRadius: theme.cornerRadius / 4)
                        .fill(theme.primaryColor)
                        .frame(width: 30, height: 8)
                }
                .padding(4)
            }
            .padding(8)
        }
    }
}
