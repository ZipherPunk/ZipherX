import Foundation

/// Wallet source - determines which wallet to use for operations
public enum WalletSource: String, Codable, CaseIterable {
    /// ZipherX's own wallet (SecureKeyStorage + WalletDatabase)
    /// Works in both Light and Full Node modes
    case zipherx = "zipherx"

    /// Full node's wallet.dat via RPC
    /// Only available in Full Node mode, uses daemon for all operations
    case walletDat = "walletDat"

    var displayName: String {
        switch self {
        case .zipherx:
            return "ZipherX Wallet"
        case .walletDat:
            return "Full Node wallet.dat"
        }
    }

    var description: String {
        switch self {
        case .zipherx:
            return "Secure wallet with keys stored in Keychain"
        case .walletDat:
            return "Use daemon's wallet.dat for all operations"
        }
    }

    var icon: String {
        switch self {
        case .zipherx:
            return "shield.fill"
        case .walletDat:
            return "externaldrive.fill"
        }
    }

    var features: [String] {
        switch self {
        case .zipherx:
            return [
                "Keys stored in Secure Enclave",
                "Works offline with P2P",
                "Single z-address focus",
                "Modern UI experience"
            ]
        case .walletDat:
            return [
                "Multiple z-addresses",
                "Transparent (t) addresses",
                "RPC-based operations",
                "Classic Mac 7 UI"
            ]
        }
    }
}

/// Wallet operating mode - determines how ZipherX connects to the blockchain
public enum WalletMode: String, Codable, CaseIterable {
    /// Light mode - P2P network, bundled commitment tree, mobile-friendly
    /// Storage: ~1.5GB, Startup: Fast, Platform: iOS + macOS
    case light = "light"

    /// Full node mode - Local zclassicd daemon, full blockchain
    /// Storage: ~15GB, Startup: Requires sync, Platform: macOS only
    case fullNode = "fullNode"

    var displayName: String {
        switch self {
        case .light:
            return "ZipherX"
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
                "~1.5 GB storage requirement",
                "P2P decentralized network",
                "Works on iOS and macOS",
                "Perfect for mobile use"
            ]
        case .fullNode:
            return [
                "Full blockchain verification",
                "Local zclassicd daemon",
                "Built-in block explorer",
                "~15 GB storage requirement",
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
            return "~1.5 GB"
        case .fullNode:
            return "~15 GB"
        }
    }
}

/// Manages the current wallet mode and persistence
public class WalletModeManager: ObservableObject {
    public static let shared = WalletModeManager()

    private let userDefaultsKey = "walletMode"
    private let walletSourceKey = "walletSource"
    private let hasSelectedModeKey = "hasSelectedWalletMode"

    @Published public private(set) var currentMode: WalletMode
    @Published public private(set) var walletSource: WalletSource
    @Published public private(set) var hasSelectedMode: Bool
    @Published public private(set) var daemonDetected: Bool = false

    /// True when using Full Node mode with wallet.dat source
    public var isUsingWalletDat: Bool {
        return currentMode == .fullNode && walletSource == .walletDat
    }

    private init() {
        // Default to light mode and ZipherX wallet
        self.currentMode = .light
        self.walletSource = .zipherx
        self.hasSelectedMode = UserDefaults.standard.bool(forKey: hasSelectedModeKey)

        // If user already selected a mode, load it
        if hasSelectedMode,
           let savedMode = UserDefaults.standard.string(forKey: userDefaultsKey),
           let mode = WalletMode(rawValue: savedMode) {
            self.currentMode = mode
        }

        // Load wallet source
        if let savedSource = UserDefaults.standard.string(forKey: walletSourceKey),
           let source = WalletSource(rawValue: savedSource) {
            self.walletSource = source
        }

        // FIX #286 v3: Post notification on startup so ThemeManager can bind
        // Use async to ensure ThemeManager has been initialized first
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            print("🔄 FIX #286 v3: WalletModeManager posting initial source notification: \(self.walletSource.displayName)")
            NotificationCenter.default.post(
                name: .walletSourceDidChange,
                object: nil,
                userInfo: ["source": self.walletSource]
            )
        }
    }

    /// Check if a zclassicd daemon is running (call this at startup)
    /// Returns true if daemon detected and user hasn't selected a mode yet
    public func checkForRunningDaemon() async -> Bool {
        #if os(macOS)
        // Only check on macOS
        guard !hasSelectedMode else {
            print("🔄 WalletMode: User already selected mode, skipping daemon detection")
            return false
        }

        print("🔍 WalletMode: Checking for running zclassicd daemon...")

        // Try to load config and connect
        do {
            try RPCClient.shared.loadConfig()
            let connected = await RPCClient.shared.checkConnection()

            if connected {
                print("✅ WalletMode: Running zclassicd daemon DETECTED!")
                await MainActor.run {
                    self.daemonDetected = true
                }
                return true
            }
        } catch {
            print("⚠️ WalletMode: No daemon detected - \(error.localizedDescription)")
        }

        await MainActor.run {
            self.daemonDetected = false
        }
        return false
        #else
        // iOS always uses light mode
        return false
        #endif
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

        // If switching away from full node, reset wallet source to ZipherX
        if mode == .light {
            setWalletSource(.zipherx)
        }

        print("✅ Wallet mode set to: \(mode.displayName)")
    }

    /// Set the wallet source (ZipherX wallet or wallet.dat)
    /// Only has effect in Full Node mode
    public func setWalletSource(_ source: WalletSource) {
        // wallet.dat only available in Full Node mode
        if source == .walletDat && currentMode != .fullNode {
            print("⚠️ wallet.dat source only available in Full Node mode")
            return
        }

        walletSource = source
        UserDefaults.standard.set(source.rawValue, forKey: walletSourceKey)

        print("✅ Wallet source set to: \(source.displayName)")

        // Notify theme manager to update theme
        NotificationCenter.default.post(
            name: .walletSourceDidChange,
            object: nil,
            userInfo: ["source": source]
        )
    }

    /// Check if wallet.dat exists in the Zclassic data directory
    public func walletDatExists() -> Bool {
        #if os(macOS)
        let walletPath = RPCClient.zclassicDataDir.appendingPathComponent("wallet.dat")
        return FileManager.default.fileExists(atPath: walletPath.path)
        #else
        return false
        #endif
    }

    /// Check if mode selection is needed
    /// Returns true if:
    /// - macOS first launch AND daemon detected (user should choose)
    /// Note: If no daemon detected, default to light mode silently
    public var needsModeSelection: Bool {
        #if os(iOS)
        // iOS always uses light mode, no selection needed
        return false
        #else
        // Only show mode selection if daemon detected AND user hasn't chosen yet
        return !hasSelectedMode && daemonDetected
        #endif
    }

    /// Reset mode selection (for testing or settings)
    public func resetModeSelection() {
        hasSelectedMode = false
        UserDefaults.standard.set(false, forKey: hasSelectedModeKey)
    }
}

// MARK: - Notification Names

public extension Notification.Name {
    /// Posted when wallet source changes (ZipherX wallet <-> wallet.dat)
    static let walletSourceDidChange = Notification.Name("walletSourceDidChange")
}
