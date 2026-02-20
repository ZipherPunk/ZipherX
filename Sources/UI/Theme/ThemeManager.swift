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

    /// The theme saved before wallet.dat mode auto-switched
    private var savedThemeBeforeWalletDat: ThemeType?

    private let userDefaultsKey = "selectedTheme"
    private var walletSourceObserver: NSObjectProtocol?

    /// Key for storing the user's preferred theme (before wallet.dat auto-switch)
    private let preferredThemeKey = "preferredTheme"

    private init() {
        // Load saved theme or default to cypherpunk
        let savedTheme = UserDefaults.standard.string(forKey: userDefaultsKey) ?? "cypherpunk"
        let themeType = ThemeType(rawValue: savedTheme) ?? .cypherpunk
        self.currentThemeType = themeType
        self.currentTheme = themeType.theme

        print("🎨 FIX #286 v3: ThemeManager init - loaded theme: \(themeType.displayName)")

        // FIX #286: Load user's preferred theme (the theme they chose, not the auto-switched one)
        if let preferredTheme = UserDefaults.standard.string(forKey: preferredThemeKey),
           let preferred = ThemeType(rawValue: preferredTheme) {
            self.savedThemeBeforeWalletDat = preferred
            print("🎨 FIX #286 v3: Loaded saved preferred theme: \(preferred.displayName)")
        } else {
            print("🎨 FIX #286 v3: No saved preferred theme found")
        }

        // Listen for wallet source changes
        setupWalletSourceBinding()
    }

    deinit {
        if let observer = walletSourceObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func setTheme(_ type: ThemeType) {
        currentThemeType = type
        currentTheme = type.theme
        UserDefaults.standard.set(type.rawValue, forKey: userDefaultsKey)
    }

    // MARK: - Wallet Source Theme Binding

    private func setupWalletSourceBinding() {
        walletSourceObserver = NotificationCenter.default.addObserver(
            forName: .walletSourceDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self,
                  let source = notification.userInfo?["source"] as? WalletSource else { return }

            self.bindThemeToWalletSource(source)
        }
    }

    /// Bind theme to wallet source - auto-switch to System 7 for wallet.dat mode
    func bindThemeToWalletSource(_ source: WalletSource) {
        print("🎨 FIX #286 v3: bindThemeToWalletSource called with source=\(source.rawValue)")
        print("🎨 FIX #286 v3: Current state: currentThemeType=\(currentThemeType.rawValue), savedThemeBeforeWalletDat=\(savedThemeBeforeWalletDat?.rawValue ?? "nil")")

        switch source {
        case .zipherx:
            // FIX #286: Restore previous theme if we switched for wallet.dat
            if let savedTheme = savedThemeBeforeWalletDat {
                print("🎨 FIX #286 v3: Restoring theme to: \(savedTheme.displayName)")
                setTheme(savedTheme)
                // Clear saved and persist
                savedThemeBeforeWalletDat = nil
                UserDefaults.standard.removeObject(forKey: preferredThemeKey)
            } else if currentThemeType == .mac7 {
                // FIX #286 v3: If we're on System 7 but no saved theme, go to cypherpunk
                // This handles the case where app was restarted in wallet.dat mode then switched back
                print("🎨 FIX #286 v3: On System 7 but no saved theme, switching to Cypherpunk")
                setTheme(.cypherpunk)
            } else {
                // Already on a non-System 7 theme, keep it
                print("🎨 FIX #286 v3: Already on \(currentThemeType.displayName), keeping current theme")
            }

        case .walletDat:
            // Only switch if not already on System 7
            if currentThemeType != .mac7 {
                // FIX #286: Save current theme before switching
                savedThemeBeforeWalletDat = currentThemeType
                // Persist the preferred theme so we can restore it after app restart
                UserDefaults.standard.set(currentThemeType.rawValue, forKey: preferredThemeKey)
                print("🎨 FIX #286 v3: Auto-switching to System 7 for wallet.dat mode (saving: \(currentThemeType.displayName))")
                setTheme(.mac7)
            } else {
                print("🎨 FIX #286 v3: Already on System 7 for wallet.dat mode")
            }
        }
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
