// Copyright (c) 2025 Zipherpunk.com dev team
// iOS App Delegate for Background Fetch
//
// "Privacy is necessary for an open society in the electronic age."
//   - A Cypherpunk's Manifesto

#if os(iOS)
import UIKit
import BackgroundTasks

/// App Delegate for iOS-specific functionality
/// Handles background fetch for wallet sync
class AppDelegate: NSObject, UIApplicationDelegate {

    /// Background task identifier
    private let backgroundTaskIdentifier = "com.zipherx.wallet.refresh"

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Register background task (iOS 13+)
        registerBackgroundTasks()

        // NOTE: setMinimumBackgroundFetchInterval was deprecated in iOS 13.0.
        // Modern background refresh is handled via BGTaskScheduler (iOS 13+) above.
        // This legacy API is no longer used.
        // application.setMinimumBackgroundFetchInterval(UIApplication.backgroundFetchIntervalMinimum)

        print("📱 AppDelegate: Background fetch registered")
        return true
    }

    // MARK: - Background Task Registration (iOS 13+)

    private func registerBackgroundTasks() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: backgroundTaskIdentifier,
            using: nil
        ) { task in
            self.handleBackgroundRefresh(task: task as! BGAppRefreshTask)
        }
    }

    /// Handle background refresh task
    private func handleBackgroundRefresh(task: BGAppRefreshTask) {
        // Schedule next refresh
        scheduleBackgroundRefresh()

        // Create task to sync wallet
        let syncTask = Task {
            do {
                print("🔄 Background sync starting...")

                // Get current chain height
                let networkManager = NetworkManager.shared
                let chainHeight = try await networkManager.getChainHeight()
                let walletHeight = (try? WalletDatabase.shared.getLastScannedHeight()) ?? 0

                if chainHeight > walletHeight {
                    print("🔄 Background sync: \(chainHeight - walletHeight) blocks behind")
                    await WalletManager.shared.backgroundSyncToHeight(chainHeight)
                    print("✅ Background sync complete")
                } else {
                    print("✅ Background sync: Already up to date")
                }

                // FIX #1437: Brief window for chat messages to arrive
                // If chat is running, incoming messages during this window will
                // trigger local notifications via notifyChatMessage()
                if await MainActor.run(body: { ChatManager.shared.isAvailable }) {
                    print("💬 FIX #1437: Chat active — waiting 5s for incoming messages...")
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                }

                task.setTaskCompleted(success: true)
            } catch {
                print("⚠️ Background sync failed: \(error)")
                task.setTaskCompleted(success: false)
            }
        }

        // Handle task expiration
        task.expirationHandler = {
            syncTask.cancel()
            task.setTaskCompleted(success: false)
        }
    }

    /// Schedule next background refresh
    func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: backgroundTaskIdentifier)
        // Request refresh in 15 minutes (minimum)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)

        do {
            try BGTaskScheduler.shared.submit(request)
            print("📅 Background refresh scheduled for ~15 minutes from now")
        } catch {
            print("⚠️ Could not schedule background refresh: \(error)")
        }
    }

    // MARK: - Legacy Background Fetch (iOS 12 and earlier, still called on iOS 13+)

    func application(_ application: UIApplication, performFetchWithCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        print("🔄 Legacy background fetch triggered")

        Task {
            do {
                let networkManager = NetworkManager.shared
                let chainHeight = try await networkManager.getChainHeight()
                let walletHeight = (try? WalletDatabase.shared.getLastScannedHeight()) ?? 0

                if chainHeight > walletHeight {
                    await WalletManager.shared.backgroundSyncToHeight(chainHeight)
                    completionHandler(.newData)
                } else {
                    completionHandler(.noData)
                }
            } catch {
                print("⚠️ Legacy background fetch failed: \(error)")
                completionHandler(.failed)
            }
        }
    }

    // MARK: - Scene Lifecycle

    func applicationDidEnterBackground(_ application: UIApplication) {
        // FIX #894: CRITICAL - Checkpoint WAL databases before going to background
        // Without this, headers loaded during the session could be lost if app is terminated
        // iOS can terminate background apps at any time without warning
        HeaderStore.shared.checkpoint()
        WalletDatabase.shared.checkpoint()
        print("💾 FIX #894: WAL checkpoints complete before background")

        // Schedule background refresh when app goes to background
        scheduleBackgroundRefresh()

        // FIX #1437: Request background time to keep chat/Tor connections alive
        // iOS grants ~30 seconds of background execution — messages arriving in this
        // window will trigger local notifications via notifyChatMessage()
        var bgTaskID: UIBackgroundTaskIdentifier = .invalid
        bgTaskID = application.beginBackgroundTask(withName: "chat-linger") {
            // Expiration handler
            application.endBackgroundTask(bgTaskID)
            bgTaskID = .invalid
        }
        Task {
            print("📱 FIX #1437: Background task started — keeping chat alive for ~25s")
            try? await Task.sleep(nanoseconds: 25_000_000_000) // 25s (leave 5s margin)
            if bgTaskID != .invalid {
                application.endBackgroundTask(bgTaskID)
                bgTaskID = .invalid
            }
            print("📱 FIX #1437: Background task ended")
        }

        print("📱 App entered background - scheduled sync + chat linger")
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        // Trigger sync when coming back to foreground
        print("📱 App entering foreground - will sync")
        Task {
            let networkManager = NetworkManager.shared
            if let chainHeight = try? await networkManager.getChainHeight() {
                let walletHeight = (try? WalletDatabase.shared.getLastScannedHeight()) ?? 0
                if chainHeight > walletHeight {
                    await WalletManager.shared.backgroundSyncToHeight(chainHeight)
                }
            }
        }
    }
}
#endif
