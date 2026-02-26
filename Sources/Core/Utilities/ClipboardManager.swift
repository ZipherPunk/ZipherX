import Foundation

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Secure clipboard manager with automatic expiry
/// SECURITY: Clears sensitive data from clipboard after specified duration
/// VUL-CRYPTO-006: Auto-clear on app termination (macOS), reduced timeout for keys
enum ClipboardManager {

    /// Track the latest clipboard clear timer so we can clear on termination
    private static var pendingClearWork: DispatchWorkItem?

    /// Copy text to clipboard with automatic expiry
    /// - Parameters:
    ///   - text: The string to copy
    ///   - seconds: Time before auto-clear (default 60s for addresses, use 10s for private keys)
    static func copyWithAutoExpiry(_ text: String, seconds: TimeInterval = 60) {
        // Cancel any previous pending clear
        pendingClearWork?.cancel()

        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        // Schedule automatic clearing
        let clearWork = DispatchWorkItem {
            NSPasteboard.general.clearContents()
            pendingClearWork = nil
        }
        pendingClearWork = clearWork
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: clearWork)

        // VUL-CRYPTO-006: Register for app termination to clear clipboard
        setupTerminationHandler()
        #else
        // iOS: Use native UIPasteboard expiration
        UIPasteboard.general.setItems(
            [[UIPasteboard.typeAutomatic: text]],
            options: [.expirationDate: Date().addingTimeInterval(seconds)]
        )
        #endif
    }

    /// VUL-CRYPTO-006: Copy private key with shorter expiry (10 seconds)
    static func copyPrivateKey(_ key: String) {
        copyWithAutoExpiry(key, seconds: 10)
    }

    /// Force-clear clipboard immediately
    static func clearNow() {
        pendingClearWork?.cancel()
        pendingClearWork = nil
        #if os(macOS)
        NSPasteboard.general.clearContents()
        #else
        UIPasteboard.general.string = ""
        #endif
    }

    // MARK: - VUL-CRYPTO-006: App Termination Handler

    #if os(macOS)
    private static var terminationObserver: NSObjectProtocol?

    private static func setupTerminationHandler() {
        guard terminationObserver == nil else { return }
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            // Clear clipboard on app quit if we have pending sensitive data
            if pendingClearWork != nil {
                NSPasteboard.general.clearContents()
                pendingClearWork = nil
            }
        }
    }
    #endif
}
