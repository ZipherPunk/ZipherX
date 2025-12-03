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
