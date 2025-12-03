import SwiftUI

/// Global app startup time - captured at the very first moment of app launch
let appStartupTime: Date = Date()

@main
struct ZipherXApp: App {
    @StateObject private var walletManager = WalletManager.shared
    @StateObject private var networkManager = NetworkManager.shared
    @StateObject private var themeManager = ThemeManager.shared

    init() {
        // Initialize NotificationManager early to set delegate
        // This ensures foreground notifications work
        _ = NotificationManager.shared
        // Request notification permission on launch
        NotificationManager.shared.requestPermission()
        print("🚀 App init at \(Date()) - startup time was \(appStartupTime)")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(walletManager)
                .environmentObject(networkManager)
                .environmentObject(themeManager)
        }
    }
}
