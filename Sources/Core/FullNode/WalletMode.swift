import Foundation

/// Wallet operating mode - determines how ZipherX connects to the blockchain
public enum WalletMode: String, Codable, CaseIterable {
    /// Light mode - P2P network, bundled commitment tree, mobile-friendly
    /// Storage: ~50MB, Startup: Fast, Platform: iOS + macOS
    case light = "light"

    /// Full node mode - Local zclassicd daemon, full blockchain
    /// Storage: ~5GB, Startup: Requires sync, Platform: macOS only
    case fullNode = "fullNode"

    var displayName: String {
        switch self {
        case .light:
            return "ZipherX Light"
        case .fullNode:
            return "ZipherX Full Node"
        }
    }

    var description: String {
        switch self {
        case .light:
            return "Fast, mobile-friendly wallet using P2P network"
        case .fullNode:
            return "Full blockchain verification with local node"
        }
    }

    var icon: String {
        switch self {
        case .light:
            return "bolt.fill"
        case .fullNode:
            return "server.rack"
        }
    }

    var features: [String] {
        switch self {
        case .light:
            return [
                "Instant startup with bundled tree",
                "~50MB storage requirement",
                "P2P decentralized network",
                "Works on iOS and macOS",
                "Perfect for mobile use"
            ]
        case .fullNode:
            return [
                "Full blockchain verification",
                "Local zclassicd daemon",
                "Built-in block explorer",
                "~5GB storage requirement",
                "macOS only"
            ]
        }
    }

    var isAvailableOnCurrentPlatform: Bool {
        #if os(iOS)
        return self == .light
        #else
        return true
        #endif
    }

    var storageRequirement: String {
        switch self {
        case .light:
            return "~50 MB"
        case .fullNode:
            return "~5 GB"
        }
    }
}

/// Manages the current wallet mode and persistence
public class WalletModeManager: ObservableObject {
    public static let shared = WalletModeManager()

    private let userDefaultsKey = "walletMode"
    private let hasSelectedModeKey = "hasSelectedWalletMode"

    @Published public private(set) var currentMode: WalletMode
    @Published public private(set) var hasSelectedMode: Bool

    private init() {
        // Load saved mode or default to light
        if let savedMode = UserDefaults.standard.string(forKey: userDefaultsKey),
           let mode = WalletMode(rawValue: savedMode) {
            self.currentMode = mode
        } else {
            self.currentMode = .light
        }

        self.hasSelectedMode = UserDefaults.standard.bool(forKey: hasSelectedModeKey)
    }

    /// Set the wallet mode (called from mode selection UI)
    public func setMode(_ mode: WalletMode) {
        guard mode.isAvailableOnCurrentPlatform else {
            print("⚠️ Mode \(mode.displayName) is not available on this platform")
            return
        }

        currentMode = mode
        hasSelectedMode = true

        UserDefaults.standard.set(mode.rawValue, forKey: userDefaultsKey)
        UserDefaults.standard.set(true, forKey: hasSelectedModeKey)

        print("✅ Wallet mode set to: \(mode.displayName)")
    }

    /// Check if mode selection is needed (first launch)
    public var needsModeSelection: Bool {
        #if os(iOS)
        // iOS always uses light mode, no selection needed
        return false
        #else
        // macOS needs mode selection on first launch
        return !hasSelectedMode
        #endif
    }

    /// Reset mode selection (for testing or settings)
    public func resetModeSelection() {
        hasSelectedMode = false
        UserDefaults.standard.set(false, forKey: hasSelectedModeKey)
    }
}
