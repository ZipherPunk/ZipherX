import Foundation
import UserNotifications
import UIKit

/// Manages local notifications for wallet events
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    private override init() {
        super.init()
        // Set self as delegate to show notifications in foreground
        UNUserNotificationCenter.current().delegate = self
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Show notifications even when app is in foreground
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Show banner, sound, and badge even in foreground
        completionHandler([.banner, .sound, .badge])
    }

    /// Handle notification tap
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        print("📬 Notification tapped: \(userInfo)")
        // Could navigate to transaction details here
        completionHandler()
    }

    // MARK: - Permission

    /// Request notification permission from user
    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if granted {
                print("✅ Notification permission granted")
            } else if let error = error {
                print("❌ Notification permission error: \(error.localizedDescription)")
            } else {
                print("⚠️ Notification permission denied")
            }
        }
    }

    // MARK: - Wallet Notifications

    /// Notify when ZCL is received (pending)
    func notifyReceived(amount: UInt64, txid: String, memo: String? = nil) {
        let zcl = Double(amount) / 100_000_000.0
        let content = UNMutableNotificationContent()
        content.title = "ZCL Received"

        // Build body with optional memo
        var body = String(format: "+%.8f ZCL (pending)", zcl)
        if let memo = memo, !memo.isEmpty {
            // Truncate memo for notification if too long
            let truncatedMemo = memo.count > 100 ? String(memo.prefix(100)) + "..." : memo
            body += "\n📝 \(truncatedMemo)"
        }
        content.body = body
        content.sound = .default
        content.userInfo = ["type": "received", "txid": txid, "amount": amount, "memo": memo ?? ""]

        let request = UNNotificationRequest(
            identifier: "received-\(txid)",
            content: content,
            trigger: nil // Immediate
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("❌ Failed to send received notification: \(error.localizedDescription)")
            }
        }
    }

    /// Notify when transaction is confirmed
    func notifyConfirmed(amount: UInt64, txid: String) {
        let zcl = Double(amount) / 100_000_000.0
        let content = UNMutableNotificationContent()
        content.title = "Transaction Confirmed"
        content.body = String(format: "%.8f ZCL confirmed", zcl)
        content.sound = .default
        content.userInfo = ["type": "confirmed", "txid": txid, "amount": amount]

        let request = UNNotificationRequest(
            identifier: "confirmed-\(txid)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("❌ Failed to send confirmed notification: \(error.localizedDescription)")
            }
        }
    }

    /// Notify when ZCL is sent
    func notifySent(amount: UInt64, txid: String, memo: String? = nil) {
        let zcl = Double(amount) / 100_000_000.0
        let content = UNMutableNotificationContent()
        content.title = "ZCL Sent"

        // Build body with optional memo
        var body = String(format: "-%.8f ZCL", zcl)
        if let memo = memo, !memo.isEmpty {
            // Truncate memo for notification if too long
            let truncatedMemo = memo.count > 100 ? String(memo.prefix(100)) + "..." : memo
            body += "\n📝 \(truncatedMemo)"
        }
        content.body = body
        content.sound = .default
        content.userInfo = ["type": "sent", "txid": txid, "amount": amount, "memo": memo ?? ""]

        let request = UNNotificationRequest(
            identifier: "sent-\(txid)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("❌ Failed to send sent notification: \(error.localizedDescription)")
            }
        }
    }

    /// Update app badge with pending transaction count
    func updateBadge(count: Int) {
        if #available(iOS 16.0, *) {
            UNUserNotificationCenter.current().setBadgeCount(count) { error in
                if let error = error {
                    print("❌ Failed to update badge: \(error.localizedDescription)")
                }
            }
        } else {
            // Fallback for iOS < 16
            DispatchQueue.main.async {
                UIApplication.shared.applicationIconBadgeNumber = count
            }
        }
    }

    /// Clear all notifications
    func clearAll() {
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        if #available(iOS 16.0, *) {
            UNUserNotificationCenter.current().setBadgeCount(0) { _ in }
        } else {
            DispatchQueue.main.async {
                UIApplication.shared.applicationIconBadgeNumber = 0
            }
        }
    }
}
