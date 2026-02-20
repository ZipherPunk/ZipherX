import Foundation
import UserNotifications
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

/// Manages local notifications for wallet events
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    /// Flag to suppress notifications during initial sync for imported wallets
    /// (avoids notification spam when scanning through historical transactions)
    var isInitialSyncInProgress: Bool = false

    /// Helper to check if we should suppress notifications
    /// Suppresses during: initial sync flag OR wallet manager syncing
    private var shouldSuppressNotifications: Bool {
        if isInitialSyncInProgress {
            return true
        }
        // Also suppress during any wallet sync operation
        return WalletManager.shared.isSyncing
    }

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

    // Cypherpunk messages for incoming transactions
    private let cypherpunkMessages = [
        "Privacy preserved.",
        "Financial sovereignty in action.",
        "No middleman. No permission needed.",
        "Trustless transfer complete.",
        "Cryptographic proof verified.",
        "Decentralized and free.",
        "Your keys, your coins.",
        "Shielded from prying eyes."
    ]

    /// Notify when ZCL is received (pending in mempool)
    func notifyReceived(amount: UInt64, txid: String, memo: String? = nil) {
        // Suppress notifications during initial wallet sync (historical txs)
        guard !shouldSuppressNotifications else { return }

        let zcl = Double(amount) / 100_000_000.0
        print("🔔 Notification: +\(amount.redactedAmount) incoming (mempool)")

        let content = UNMutableNotificationContent()
        content.title = "Incoming ZCL"

        // Build body with amount and pending status
        var body = String(format: "+%.8f ZCL\n⏳ Awaiting confirmation", zcl)
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

    /// Notify when ZCL is received AND confirmed (mined in block)
    func notifyReceivedConfirmed(amount: UInt64, txid: String, memo: String? = nil) {
        // Suppress notifications during initial wallet sync (historical txs)
        guard !shouldSuppressNotifications else { return }

        let zcl = Double(amount) / 100_000_000.0
        print("🔔 Notification: +\(amount.redactedAmount) confirmed")

        // Remove the pending "Incoming" notification for this txid
        // This replaces the "Awaiting confirmation" message with "Received"
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["received-\(txid)"])

        let content = UNMutableNotificationContent()
        content.title = "⛏️ ZCL Received"

        // Build body with amount and cypherpunk message
        let cypherpunkMessage = cypherpunkMessages.randomElement() ?? cypherpunkMessages[0]
        var body = String(format: "+%.8f ZCL\n%@", zcl, cypherpunkMessage)
        if let memo = memo, !memo.isEmpty {
            // Truncate memo for notification if too long
            let truncatedMemo = memo.count > 100 ? String(memo.prefix(100)) + "..." : memo
            body += "\n📝 \(truncatedMemo)"
        }
        content.body = body
        content.sound = .default
        content.userInfo = ["type": "received_confirmed", "txid": txid, "amount": amount, "memo": memo ?? ""]

        let request = UNNotificationRequest(
            identifier: "received-confirmed-\(txid)",
            content: content,
            trigger: nil // Immediate
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("❌ Failed to send received confirmed notification: \(error.localizedDescription)")
            }
        }
    }

    /// Notify when transaction is confirmed (for outgoing txs)
    func notifyConfirmed(amount: UInt64, txid: String) {
        // Suppress notifications during initial wallet sync (historical txs)
        guard !shouldSuppressNotifications else { return }

        let zcl = Double(amount) / 100_000_000.0
        print("🔔 Notification: -\(amount.redactedAmount) confirmed")

        let content = UNMutableNotificationContent()
        content.title = "⛏️ Transaction Mined"
        let cypherpunkMessage = cypherpunkMessages.randomElement() ?? cypherpunkMessages[0]
        content.body = String(format: "-%.8f ZCL\n%@", zcl, cypherpunkMessage)
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
        // Note: notifySent is NOT suppressed during sync because user explicitly initiates sends
        // This is intentional - user should always see confirmation of their own actions

        let zcl = Double(amount) / 100_000_000.0
        print("🔔 NOTIFICATION: notifySent called")
        print("   amount=\(amount.redactedAmount)")
        print("   txid=\(txid.prefix(16))...")
        // PRIVACY: P-META-003 — Redact memo content from logs
        print("   memo=\(LogRedaction.redactMemo(memo))")
        print("   >>> Sending SENT notification (tx broadcast)")

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

    /// FIX #174: Notify when external wallet spends our funds
    func notifyExternalWalletSpend(amount: UInt64, txid: String) {
        let zcl = Double(amount) / 100_000_000.0
        print("🚨 NOTIFICATION: notifyExternalWalletSpend called")
        print("   amount=\(amount.redactedAmount)")
        print("   txid=\(txid.prefix(16))...")
        print("   >>> ALERT: External wallet spent our funds!")

        let content = UNMutableNotificationContent()
        content.title = "⚠️ External Wallet Spend Detected"
        content.body = String(format: "Another wallet spent %.8f ZCL from your address.\nThis was NOT sent by ZipherX!", zcl)
        content.sound = .defaultCritical // Use critical sound to get attention
        content.userInfo = ["type": "external_spend", "txid": txid, "amount": amount]

        let request = UNNotificationRequest(
            identifier: "external-spend-\(txid)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("❌ Failed to send external spend notification: \(error.localizedDescription)")
            }
        }
    }

    /// Update app badge with pending transaction count
    func updateBadge(count: Int) {
        #if os(iOS)
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
        #elseif os(macOS)
        // macOS uses dock badge
        DispatchQueue.main.async {
            if count > 0 {
                NSApp.dockTile.badgeLabel = "\(count)"
            } else {
                NSApp.dockTile.badgeLabel = nil
            }
        }
        #endif
    }

    // MARK: - Chat Notifications (FIX #223)

    /// Chat messages for notifications
    private let chatCypherpunkMessages = [
        "Encrypted message received.",
        "Privacy preserved in communication.",
        "Secure channel active.",
        "End-to-end encrypted.",
        "No middleman can read this."
    ]

    /// Notify when a chat message is received
    /// - Parameters:
    ///   - senderName: Display name of sender (nickname or truncated onion)
    ///   - messageType: Type of message (text, payment request, etc.)
    ///   - preview: Optional message preview (for text messages)
    func notifyChatMessage(from senderName: String, type: String, preview: String? = nil) {
        let content = UNMutableNotificationContent()

        switch type {
        case "text":
            content.title = "💬 \(senderName)"
            if let preview = preview {
                // Truncate preview for privacy
                let truncated = preview.count > 50 ? String(preview.prefix(50)) + "..." : preview
                content.body = truncated
            } else {
                content.body = chatCypherpunkMessages.randomElement() ?? "New encrypted message"
            }

        case "pay_req":
            content.title = "💰 Payment Request"
            content.body = "\(senderName) is requesting payment"

        case "pay_sent", "pay_rcv":
            content.title = "✅ Payment Received"
            content.body = "Payment from \(senderName) confirmed"

        default:
            content.title = "💬 \(senderName)"
            content.body = chatCypherpunkMessages.randomElement() ?? "New message"
        }

        content.sound = .default
        content.categoryIdentifier = "chat"

        let request = UNNotificationRequest(
            identifier: "chat-\(UUID().uuidString)",
            content: content,
            trigger: nil  // Deliver immediately
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("❌ Chat notification error: \(error)")
            }
        }
    }

    /// Clear all notifications
    func clearAll() {
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        #if os(iOS)
        if #available(iOS 16.0, *) {
            UNUserNotificationCenter.current().setBadgeCount(0) { _ in }
        } else {
            DispatchQueue.main.async {
                UIApplication.shared.applicationIconBadgeNumber = 0
            }
        }
        #elseif os(macOS)
        DispatchQueue.main.async {
            NSApp.dockTile.badgeLabel = nil
        }
        #endif
    }
}
