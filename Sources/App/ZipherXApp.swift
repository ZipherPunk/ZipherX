import SwiftUI

@main
struct ZipherXApp: App {
    @StateObject private var walletManager = WalletManager.shared
    @StateObject private var networkManager = NetworkManager.shared

    init() {
        // Initialize NotificationManager early to set delegate
        // This ensures foreground notifications work
        _ = NotificationManager.shared
        // Request notification permission on launch
        NotificationManager.shared.requestPermission()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(walletManager)
                .environmentObject(networkManager)
        }
    }
}
