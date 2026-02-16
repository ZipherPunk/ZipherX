import Foundation

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Secure clipboard manager with automatic expiry
/// SECURITY: Clears sensitive data from clipboard after specified duration
enum ClipboardManager {
    /// Copy text to clipboard with automatic expiry
    /// - Parameters:
    ///   - text: The string to copy
    ///   - seconds: Time before auto-clear (default 60s, use 10s for private keys)
    static func copyWithAutoExpiry(_ text: String, seconds: TimeInterval = 60) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        // Schedule automatic clearing
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            NSPasteboard.general.clearContents()
        }
        #else
        // iOS: Use native UIPasteboard expiration
        UIPasteboard.general.setItems(
            [[UIPasteboard.typeAutomatic: text]],
            options: [.expirationDate: Date().addingTimeInterval(seconds)]
        )
        #endif
    }
}
