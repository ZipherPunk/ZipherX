import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Global app startup time - captured at the very first moment of app launch
let appStartupTime: Date = Date()

@main
struct ZipherXApp: App {
    @StateObject private var walletManager = WalletManager.shared
    @StateObject private var networkManager = NetworkManager.shared
    @StateObject private var themeManager = ThemeManager.shared
    #if os(macOS)
    @StateObject private var modeManager = WalletModeManager.shared
    @State private var hasCheckedDaemon = false
    @State private var showModeSelection = false
    #endif

    // iOS: Use AppDelegate for background fetch
    #if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #endif

    init() {
        // Initialize NotificationManager early to set delegate
        // This ensures foreground notifications work
        _ = NotificationManager.shared
        // Request notification permission on launch
        NotificationManager.shared.requestPermission()
        print("🚀 App init at \(Date()) - startup time was \(appStartupTime)")

        // Fetch tree info from GitHub on first launch or to check for updates
        // This runs async and updates ZipherXConstants with latest values
        Task {
            await CommitmentTreeUpdater.shared.fetchAndUpdateTreeInfo()
        }

        // Auto-start Tor if mode is enabled (for maximum privacy)
        // This ensures daemon routes through Tor from first connection
        Task {
            await TorManager.shared.start()
        }
    }

    var body: some Scene {
        WindowGroup {
            #if os(macOS)
            // macOS: Check for daemon and show mode selection if needed
            Group {
                if showModeSelection {
                    ModeSelectionView { mode in
                        modeManager.setMode(mode)
                        showModeSelection = false
                    }
                    .environmentObject(themeManager)
                } else {
                    ContentView()
                        .environmentObject(walletManager)
                        .environmentObject(networkManager)
                        .environmentObject(themeManager)
                }
            }
            .task {
                // Only check once at startup
                guard !hasCheckedDaemon else { return }
                hasCheckedDaemon = true

                // Check if daemon is running
                let daemonDetected = await modeManager.checkForRunningDaemon()

                // Show mode selection if daemon detected and user hasn't chosen
                if daemonDetected && !modeManager.hasSelectedMode {
                    await MainActor.run {
                        showModeSelection = true
                    }
                }
            }
            #else
            // iOS: Always light mode, no selection needed
            ContentView()
                .environmentObject(walletManager)
                .environmentObject(networkManager)
                .environmentObject(themeManager)
            #endif
        }
    }
}
