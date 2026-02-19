import SwiftUI
import LocalAuthentication
#if os(iOS)
import UIKit
#else
import AppKit
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
    @State private var hasAcceptedDisclaimer = UserDefaults.standard.bool(forKey: "hasAcceptedDisclaimer")

    // iOS: Use AppDelegate for background fetch
    #if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #endif

    init() {
        // FIX #1276: Auth is handled SOLELY by LockScreenView — single owner, zero races.
        // Previously ZipherXApp.init() also triggered auth, causing double-prompt race conditions.
        print("🔐 FIX #1276: Auth deferred to LockScreenView (single owner)")

        // Initialize NotificationManager early to set delegate
        // This ensures foreground notifications work
        _ = NotificationManager.shared
        // Request notification permission on launch
        NotificationManager.shared.requestPermission()
        print("🚀 App init at \(Date()) - startup time was \(appStartupTime)")

        // FIX #1131: Reset session flags at app launch
        WalletHealthCheck.shared.resetSessionFlags()

        // FIX #776: Clear incorrectly set boost headers corruption flag
        // The boost file is correct - this flag was set in error
        if UserDefaults.standard.bool(forKey: "HeaderStore.boostHeadersCorrupted") {
            UserDefaults.standard.removeObject(forKey: "HeaderStore.boostHeadersCorrupted")
            print("✅ FIX #776: Cleared incorrectly set boostHeadersCorrupted flag")
        }

        // FIX #1273: Defer network-dependent tasks until after authentication.
        // These were running immediately at app launch, before the lock screen.
        Task {
            // Wait for auth before making any network requests or starting Tor
            while !BiometricAuthManager.shared.hasAuthenticatedThisSession {
                try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
                if Task.isCancelled { return }
            }

            // Fetch tree info from GitHub (lightweight ~1KB manifest)
            await CommitmentTreeUpdater.shared.fetchAndUpdateTreeInfo()

            // FIX #1383: Check for app updates on GitHub
            AppUpdateChecker.shared.checkForUpdate()

            // Auto-start Tor if mode is enabled (for maximum privacy)
            await TorManager.shared.start()
        }

        // Security audit TASK 17: Prevent screen recording/sharing on macOS
        #if os(macOS)
        DispatchQueue.main.async {
            if let window = NSApplication.shared.windows.first {
                window.sharingType = .none
            }
        }
        #endif

        // FIX #894: Register for app termination notification to checkpoint WAL databases
        // Without this, headers loaded during the session could be lost on app quit
        #if os(macOS)
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            // CRITICAL: Checkpoint WAL databases before app terminates
            // This ensures all data (especially 2.5M headers) is written to main database file
            HeaderStore.shared.checkpoint()
            WalletDatabase.shared.checkpoint()
            print("💾 FIX #894: WAL checkpoints complete before termination")
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if !hasAcceptedDisclaimer {
                    // Step 1: Disclaimer (first launch)
                    DisclaimerView(hasAcceptedDisclaimer: $hasAcceptedDisclaimer)
                }
                #if os(macOS)
                else if !modeManager.hasSelectedMode && (showModeSelection || !hasCheckedDaemon) {
                    // Step 2: Mode selection (macOS, first launch after disclaimer)
                    ModeSelectionView { mode in
                        modeManager.setMode(mode)
                        showModeSelection = false
                    }
                    .environmentObject(themeManager)
                }
                #endif
                else {
                    // Step 3: Main app
                    ContentView()
                        .environmentObject(walletManager)
                        .environmentObject(networkManager)
                        .environmentObject(themeManager)
                }
            }
            #if os(macOS)
            .task {
                // Only check once at startup
                guard !hasCheckedDaemon else { return }

                // Check if daemon is running
                let daemonDetected = await modeManager.checkForRunningDaemon()

                await MainActor.run {
                    hasCheckedDaemon = true
                    // If no daemon and user hasn't chosen, auto-select light mode
                    if !daemonDetected && !modeManager.hasSelectedMode {
                        modeManager.setMode(.light)
                    } else if daemonDetected && !modeManager.hasSelectedMode {
                        showModeSelection = true
                    }
                }
            }
            #endif
        }
    }
}
