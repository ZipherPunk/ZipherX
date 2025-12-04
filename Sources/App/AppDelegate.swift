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

        // Set minimum background fetch interval (legacy)
        application.setMinimumBackgroundFetchInterval(UIApplication.backgroundFetchIntervalMinimum)

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
        // Schedule background refresh when app goes to background
        scheduleBackgroundRefresh()
        print("📱 App entered background - scheduled sync")
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
