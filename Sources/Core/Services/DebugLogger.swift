import Foundation
import os.log
#if canImport(UIKit)
import UIKit
#endif

// MARK: - OSLog Logger for Device Debugging
private let zipherxLog = OSLog(subsystem: "com.zipherx.wallet", category: "debug")

// MARK: - Global Print Override
// Override Swift's print to use os_log for device visibility

/// Thread-safe timestamp generation using ISO8601DateFormatter
/// Note: DateFormatter is NOT thread-safe, so we use ISO8601DateFormatter or manual formatting
private func getCurrentTimestamp() -> String {
    // Use POSIX strftime which is thread-safe
    var now = time(nil)
    var timeinfo = tm()
    localtime_r(&now, &timeinfo)

    var buffer = [CChar](repeating: 0, count: 24)
    strftime(&buffer, 24, "%H:%M:%S", &timeinfo)

    // Add milliseconds
    var tv = timeval()
    gettimeofday(&tv, nil)
    let ms = tv.tv_usec / 1000

    return String(cString: buffer) + String(format: ".%03d", ms)
}

/// Global print override - uses os_log for reliable device logging with timestamps
/// NOTE: Only use os_log OR Swift.print, not both, to avoid duplicate log lines
public func print(_ items: Any..., separator: String = " ", terminator: String = "\n") {
    let output = items.map { "\($0)" }.joined(separator: separator)
    let timestamp = getCurrentTimestamp()
    let formattedOutput = "[\(timestamp)] DEBUGZIPHERX: \(output)"
    // Use Swift.print only - os_log can cause duplicate lines when both stdout and os_log
    // are captured in the same log file (common on macOS)
    Swift.print(formattedOutput, terminator: terminator)
}

/// Debug logging system that writes to a file for export
/// Enable/disable via Settings or UserDefaults "debugLoggingEnabled"
final class DebugLogger {
    static let shared = DebugLogger()

    private let logFileName = "debug.log"
    private var logFileURL: URL
    private let dateFormatter: DateFormatter
    private let queue = DispatchQueue(label: "com.zipherx.debuglogger", qos: .utility)
    private var fileHandle: FileHandle?

    /// Check if debug logging is enabled
    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "debugLoggingEnabled") }
        set {
            UserDefaults.standard.set(newValue, forKey: "debugLoggingEnabled")
            if newValue {
                log("🔧 Debug logging ENABLED")
            }
        }
    }

    private init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        logFileURL = documents.appendingPathComponent(logFileName)

        dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"

        // Create or open the log file
        setupLogFile()
    }

    private func setupLogFile() {
        if !FileManager.default.fileExists(atPath: logFileURL.path) {
            FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
        }
    }

    /// Log a message with timestamp
    /// All logs are prefixed with "DEBUGZIPHERX" for easy filtering in Xcode console
    func log(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        // Always print to console with timestamp (print() already adds DEBUGZIPHERX prefix)
        print(message)

        // Only write to file if enabled
        guard isEnabled else { return }

        let timestamp = dateFormatter.string(from: Date())
        let fileName = (file as NSString).lastPathComponent
        let logMessage = "[\(timestamp)] [\(fileName):\(line)] \(message)\n"

        queue.async { [weak self] in
            guard let self = self,
                  let data = logMessage.data(using: .utf8) else { return }

            do {
                let handle = try FileHandle(forWritingTo: self.logFileURL)
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            } catch {
                // Fallback: append using Data
                if var existingData = try? Data(contentsOf: self.logFileURL) {
                    existingData.append(data)
                    try? existingData.write(to: self.logFileURL)
                } else {
                    try? data.write(to: self.logFileURL)
                }
            }
        }
    }

    /// Log with category prefix
    func log(_ category: LogCategory, _ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        log("[\(category.rawValue)] \(message)", file: file, function: function, line: line)
    }

    /// Get the log file contents
    func getLogContents() -> String {
        do {
            return try String(contentsOf: logFileURL, encoding: .utf8)
        } catch {
            return "Error reading log file: \(error.localizedDescription)"
        }
    }

    /// Get log file size in bytes
    func getLogFileSize() -> Int {
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: logFileURL.path)
            return (attrs[.size] as? Int) ?? 0
        } catch {
            return 0
        }
    }

    /// Get log file URL for sharing
    func getLogFileURL() -> URL {
        return logFileURL
    }

    /// Clear the log file
    func clearLog() {
        queue.async { [weak self] in
            guard let self = self else { return }
            try? "".write(to: self.logFileURL, atomically: true, encoding: .utf8)
        }
        log("🗑️ Debug log cleared")
    }

    /// Add system info header to log
    func logSystemInfo() {
        guard isEnabled else { return }

        let bundle = Bundle.main

        log("═══════════════════════════════════════════════════════════")
        log("ZipherX Debug Log")
        log("═══════════════════════════════════════════════════════════")
        log("App Version: \(bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
        log("Build: \(bundle.infoDictionary?["CFBundleVersion"] as? String ?? "?")")
        #if os(iOS)
        let device = UIDevice.current
        log("Device: \(device.model)")
        log("iOS Version: \(device.systemVersion)")
        log("Device Name: \(device.name)")
        log("Identifier: \(device.identifierForVendor?.uuidString ?? "?")")
        #elseif os(macOS)
        log("Platform: macOS")
        log("macOS Version: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        log("Host Name: \(ProcessInfo.processInfo.hostName)")
        #endif
        log("Date: \(Date())")
        log("═══════════════════════════════════════════════════════════")
    }
}

// MARK: - Log Categories

enum LogCategory: String {
    case network = "NET"
    case crypto = "CRYPTO"
    case wallet = "WALLET"
    case sync = "SYNC"
    case tx = "TX"
    case ffi = "FFI"
    case ui = "UI"
    case error = "ERROR"
    case params = "PARAMS"
}

// MARK: - Global Debug Log Function

/// Convenience function for debug logging
func debugLog(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
    DebugLogger.shared.log(message, file: file, function: function, line: line)
}

/// Convenience function for categorized debug logging
func debugLog(_ category: LogCategory, _ message: String, file: String = #file, function: String = #function, line: Int = #line) {
    DebugLogger.shared.log(category, message, file: file, function: function, line: line)
}

// MARK: - Log Redaction for Privacy (VUL-004)

/// Redacts sensitive data from log messages
/// Use these functions when logging potentially sensitive information
struct LogRedaction {

    /// Redact a z-address (zs1...) - shows only first/last 6 characters
    /// "zs1abc123...xyz789" -> "zs1abc...xyz789"
    static func redactAddress(_ address: String) -> String {
        guard address.count > 16 else { return address }
        if address.hasPrefix("zs1") || address.hasPrefix("zt") {
            let prefix = String(address.prefix(8))
            let suffix = String(address.suffix(6))
            return "\(prefix)...\(suffix)"
        }
        return address
    }

    /// Redact a transaction ID - shows only first/last 8 characters
    /// "abc123...def456" (64 char hex) -> "abc123de...f4567890"
    static func redactTxid(_ txid: String) -> String {
        guard txid.count > 20 else { return txid }
        let prefix = String(txid.prefix(8))
        let suffix = String(txid.suffix(8))
        return "\(prefix)...\(suffix)"
    }

    /// Redact an amount - shows only order of magnitude
    /// 12345678 zatoshis -> "~0.1 ZCL"
    static func redactAmount(_ zatoshis: UInt64) -> String {
        let zcl = Double(zatoshis) / 100_000_000.0
        if zcl >= 10 {
            return "~\(Int(zcl)) ZCL"
        } else if zcl >= 1 {
            return "~\(Int(zcl)) ZCL"
        } else if zcl >= 0.1 {
            return "~0.X ZCL"
        } else if zcl >= 0.01 {
            return "~0.0X ZCL"
        } else if zcl >= 0.001 {
            return "~0.00X ZCL"
        } else {
            return "~0.000X ZCL"
        }
    }

    /// Redact nullifier hex - shows only first 8 characters
    static func redactNullifier(_ nullifier: String) -> String {
        guard nullifier.count > 12 else { return nullifier }
        return String(nullifier.prefix(8)) + "..."
    }

    /// Redact IP address for privacy
    /// "192.168.1.100" -> "192.168.x.x"
    static func redactIP(_ ip: String) -> String {
        let parts = ip.split(separator: ".")
        guard parts.count == 4 else { return ip }
        return "\(parts[0]).\(parts[1]).x.x"
    }

    /// Redact memo content - shows only length
    static func redactMemo(_ memo: String?) -> String {
        guard let memo = memo, !memo.isEmpty else { return "[empty]" }
        return "[memo: \(memo.count) chars]"
    }

    /// Redact diversifier or other 11-byte hex values
    static func redactDiversifier(_ hex: String) -> String {
        guard hex.count > 8 else { return hex }
        return String(hex.prefix(4)) + "..." + String(hex.suffix(4))
    }
}

// MARK: - Privacy-Safe Logging Extensions

extension String {
    /// Return redacted version of this string if it looks like an address
    var redactedAddress: String {
        LogRedaction.redactAddress(self)
    }

    /// Return redacted version of this string if it looks like a txid
    var redactedTxid: String {
        LogRedaction.redactTxid(self)
    }
}

extension UInt64 {
    /// Return redacted amount string
    var redactedAmount: String {
        LogRedaction.redactAmount(self)
    }
}
