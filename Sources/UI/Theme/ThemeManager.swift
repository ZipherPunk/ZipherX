import SwiftUI
import Combine

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
        // Load saved theme or default to cypherpunk
        let savedTheme = UserDefaults.standard.string(forKey: userDefaultsKey) ?? "cypherpunk"
        let themeType = ThemeType(rawValue: savedTheme) ?? .cypherpunk
        self.currentThemeType = themeType
        self.currentTheme = themeType.theme
    }

    func setTheme(_ type: ThemeType) {
        currentThemeType = type
        currentTheme = type.theme
        UserDefaults.standard.set(type.rawValue, forKey: userDefaultsKey)
    }
}

// MARK: - Environment Key

struct ThemeKey: EnvironmentKey {
    static let defaultValue: AppTheme = CypherpunkTheme()
}

extension EnvironmentValues {
    var theme: AppTheme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

// MARK: - View Extension

extension View {
    func themed() -> some View {
        self.environmentObject(ThemeManager.shared)
    }
}
