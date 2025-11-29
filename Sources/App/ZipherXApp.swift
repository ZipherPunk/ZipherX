import SwiftUI

@main
struct ZipherXApp: App {
    @StateObject private var walletManager = WalletManager.shared
    @StateObject private var networkManager = NetworkManager.shared
    @Environment(\.scenePhase) private var scenePhase

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
                .onChange(of: scenePhase) { newPhase in
                    switch newPhase {
                    case .background:
                        // Lock app when going to background
                        BiometricAuthManager.shared.lockApp()
                    case .active:
                        // App became active - Face ID handled by Secure Enclave
                        break
                    case .inactive:
                        break
                    @unknown default:
                        break
                    }
                }
        }
    }
}
