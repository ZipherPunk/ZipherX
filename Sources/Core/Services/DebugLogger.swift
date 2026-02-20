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
/// FIX #763: Now writes to BOTH console AND file for complete debugging
/// FIX #1442: Respects isEnabled — when debug logging is off, suppresses BOTH console AND file output
/// NOTE: Only use os_log OR Swift.print, not both, to avoid duplicate log lines
public func print(_ items: Any..., separator: String = " ", terminator: String = "\n") {
    // FIX #1442: Skip all output when debug logging is disabled by user
    guard DebugLogger.shared.isEnabled else { return }

    let output = items.map { "\($0)" }.joined(separator: separator)
    let timestamp = getCurrentTimestamp()
    let formattedOutput = "[\(timestamp)] DEBUGZIPHERX: \(output)"

    // Write to Xcode console
    Swift.print(formattedOutput, terminator: terminator)

    // FIX #763: Also write to debug log file
    DebugLogger.shared.writeToFile(formattedOutput + (terminator == "\n" ? "" : "\n"))
}

/// Debug logging system that writes to a file for export
/// FIX #763: Always enabled - logs to both console and file
/// On app start, previous log is backed up with timestamp
///
/// Log locations:
/// - macOS DEBUG: ~/ZipherX/zmac.log (project dir for agent access)
/// - macOS RELEASE: ~/Library/Application Support/ZipherX/Logs/zmac.log
/// - iOS: Documents/Logs/z.log
final class DebugLogger {
    static let shared = DebugLogger()

    // Platform-specific log file names matching user's convention
    #if os(macOS)
    private let currentLogName = "zmac.log"
    private let backupPrefix = "zmac_"
    #else
    private let currentLogName = "z.log"
    private let backupPrefix = "z_"
    #endif

    private var logFileURL: URL
    private let dateFormatter: DateFormatter
    private let backupDateFormatter: DateFormatter
    private let queue = DispatchQueue(label: "com.zipherx.debuglogger", qos: .utility)
    private var fileHandle: FileHandle?
    private var isInitialized = false

    /// Session start time for this app launch
    let sessionStartTime: Date

    /// Get the logs directory
    /// FIX #763: On macOS DEBUG, use project directory for multi-agent access
    var logsDirectory: URL {
        #if os(macOS) && DEBUG
        // Use project directory for easy agent access during development
        let projectLogDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("ZipherX")
        if FileManager.default.isWritableFile(atPath: projectLogDir.path) {
            return projectLogDir
        }
        #endif
        return AppDirectories.logs
    }

    /// FIX #1376: Debug logging can be disabled by the user from Settings.
    /// When disabled, log file writes are suppressed (console output still works).
    /// FIX #1431: Default to ENABLED in DEBUG builds for development.
    /// FIX #1455: Default to DISABLED in RELEASE builds for privacy (no sensitive data in logs).
    /// User can explicitly enable/disable in Settings.
    var isEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: "debugLoggingEnabled") == nil {
                #if DEBUG
                return true
                #else
                return false
                #endif
            }
            return UserDefaults.standard.bool(forKey: "debugLoggingEnabled")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "debugLoggingEnabled")
        }
    }

    private init() {
        sessionStartTime = Date()
        // FIX #1431: Use logsDirectory (which has DEBUG override) instead of AppDirectories.logs
        logFileURL = AppDirectories.logs.appendingPathComponent(currentLogName)
        #if os(macOS) && DEBUG
        let projectLogDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("ZipherX")
        if FileManager.default.isWritableFile(atPath: projectLogDir.path) {
            logFileURL = projectLogDir.appendingPathComponent(currentLogName)
        }
        #endif

        dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"

        backupDateFormatter = DateFormatter()
        backupDateFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"

        // FIX #763: Backup previous log and create fresh one on app start
        backupPreviousLogAndCreateNew()
        isInitialized = true

        // Log session start header
        logSessionStart()
    }

    // MARK: - FIX #763: Log Backup System

    /// Backup the previous log file with timestamp and create a fresh one
    private func backupPreviousLogAndCreateNew() {
        let fm = FileManager.default

        // Check if current log exists and has content
        if fm.fileExists(atPath: logFileURL.path) {
            do {
                let attrs = try fm.attributesOfItem(atPath: logFileURL.path)
                let fileSize = (attrs[.size] as? Int) ?? 0

                if fileSize > 0 {
                    // Create backup filename with timestamp
                    let backupTimestamp = backupDateFormatter.string(from: Date())
                    let backupName = "\(backupPrefix)\(backupTimestamp).log"
                    let backupURL = logsDirectory.appendingPathComponent(backupName)

                    // Move current log to backup
                    try fm.moveItem(at: logFileURL, to: backupURL)
                    Swift.print("[FIX #763] 📁 Previous log backed up to: \(backupName)")

                    // Clean up old backups (keep last 10)
                    cleanupOldBackups(keepCount: 10)
                }
            } catch {
                Swift.print("[FIX #763] ⚠️ Failed to backup previous log: \(error.localizedDescription)")
            }
        }

        // Create fresh log file
        fm.createFile(atPath: logFileURL.path, contents: nil)
    }

    /// Remove old backup logs, keeping only the most recent ones
    /// Security audit TASK 18: Also enforces 7-day time-based retention
    private func cleanupOldBackups(keepCount: Int) {
        let fm = FileManager.default

        do {
            let files = try fm.contentsOfDirectory(at: logsDirectory, includingPropertiesForKeys: [.creationDateKey])

            // Filter backup files (matching prefix pattern)
            let backupFiles = files.filter { url in
                let name = url.lastPathComponent
                return name.hasPrefix(backupPrefix) && name.hasSuffix(".log") && name != currentLogName
            }

            // Sort by creation date (newest first)
            let sortedBackups = backupFiles.sorted { url1, url2 in
                let date1 = (try? url1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
                let date2 = (try? url2.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
                return date1 > date2
            }

            // Security audit TASK 18: Time-based log retention — delete logs older than 7 days
            let sevenDaysAgo = Date().addingTimeInterval(-7 * 24 * 60 * 60)
            for url in sortedBackups {
                let creationDate = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
                if creationDate < sevenDaysAgo {
                    try fm.removeItem(at: url)
                    Swift.print("[TASK 18] 🗑️ Deleted log older than 7 days: \(url.lastPathComponent)")
                }
            }

            // Also apply count-based limit (FIX #763)
            let remainingBackups = sortedBackups.filter { fm.fileExists(atPath: $0.path) }
            if remainingBackups.count > keepCount {
                for url in remainingBackups.dropFirst(keepCount) {
                    try fm.removeItem(at: url)
                    Swift.print("[FIX #763] 🗑️ Deleted old log backup: \(url.lastPathComponent)")
                }
            }
        } catch {
            Swift.print("[FIX #763] ⚠️ Failed to cleanup old backups: \(error.localizedDescription)")
        }
    }

    /// Log session start header with system info
    private func logSessionStart() {
        let bundle = Bundle.main
        let separator = "═══════════════════════════════════════════════════════════════════════════════"

        writeToFile("\n\(separator)")
        writeToFile("ZipherX Debug Log - Session Started: \(dateFormatter.string(from: sessionStartTime))")
        writeToFile(separator)
        writeToFile("App Version: \(bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
        writeToFile("Build: \(bundle.infoDictionary?["CFBundleVersion"] as? String ?? "?")")

        #if os(iOS)
        let device = UIDevice.current
        writeToFile("Platform: iOS")
        writeToFile("Device: \(device.model)")
        writeToFile("iOS Version: \(device.systemVersion)")
        #elseif os(macOS)
        writeToFile("Platform: macOS")
        writeToFile("macOS Version: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        #if DEBUG
        writeToFile("Host Name: \(ProcessInfo.processInfo.hostName)")
        writeToFile("Process ID: \(ProcessInfo.processInfo.processIdentifier)")
        #endif
        #endif

        #if DEBUG
        writeToFile("Log File: \(logFileURL.path)")
        #endif
        writeToFile(separator + "\n")
    }

    // MARK: - File Writing (Thread-Safe)

    /// Write directly to log file (called by global print override)
    /// FIX #1376: Respects isEnabled — when disabled, file writes are suppressed
    func writeToFile(_ message: String) {
        queue.async { [weak self] in
            guard let self = self, self.isEnabled else { return }

            let logMessage = message.hasSuffix("\n") ? message : message + "\n"
            guard let data = logMessage.data(using: .utf8) else { return }

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

    /// Log a message with timestamp (for explicit debugLog calls)
    /// All logs are prefixed with "DEBUGZIPHERX" for easy filtering in Xcode console
    func log(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        let timestamp = getCurrentTimestamp()
        let fileName = (file as NSString).lastPathComponent
        let formattedMessage = "[\(timestamp)] [\(fileName):\(line)] \(message)"

        // Print to console (which also writes to file via global override)
        Swift.print(formattedMessage)

        // Also write to file directly to ensure it's captured
        writeToFile(formattedMessage)
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

    /// Get log file size as human-readable string
    func getLogFileSizeFormatted() -> String {
        let bytes = getLogFileSize()
        if bytes < 1024 {
            return "\(bytes) B"
        } else if bytes < 1024 * 1024 {
            return String(format: "%.1f KB", Double(bytes) / 1024.0)
        } else {
            return String(format: "%.1f MB", Double(bytes) / (1024.0 * 1024.0))
        }
    }

    /// Get log file URL for sharing
    func getLogFileURL() -> URL {
        return logFileURL
    }

    /// Get all backup log files (sorted newest first)
    func getBackupLogFiles() -> [URL] {
        let fm = FileManager.default

        do {
            let files = try fm.contentsOfDirectory(at: logsDirectory, includingPropertiesForKeys: [.creationDateKey])

            let backupFiles = files.filter { url in
                let name = url.lastPathComponent
                return name.hasPrefix(backupPrefix) && name.hasSuffix(".log") && name != currentLogName
            }

            return backupFiles.sorted { url1, url2 in
                let date1 = (try? url1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
                let date2 = (try? url2.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
                return date1 > date2
            }
        } catch {
            return []
        }
    }

    /// Clear the current log file
    /// FIX #1376: Just clears the file. Does NOT restart session header (that would write to a "cleared" file).
    func clearLog() {
        queue.async { [weak self] in
            guard let self = self else { return }
            try? "".write(to: self.logFileURL, atomically: true, encoding: .utf8)
        }
        // Use Swift.print to avoid recursion
        Swift.print("[FIX #1376] 🗑️ Debug log cleared")
    }

    /// Add system info header to log (legacy method - now called automatically)
    func logSystemInfo() {
        logSessionStart()
    }

    // MARK: - Log Analysis Helpers (for multi-agent debugging)

    /// Get lines containing errors from current log
    func getErrorLines() -> [String] {
        let contents = getLogContents()
        return contents.components(separatedBy: "\n").filter { line in
            line.contains("❌") || line.contains("ERROR") || line.contains("CRITICAL") ||
            line.contains("failed") || line.contains("Failed") || line.contains("FAILED")
        }
    }

    /// Get lines containing warnings from current log
    func getWarningLines() -> [String] {
        let contents = getLogContents()
        return contents.components(separatedBy: "\n").filter { line in
            line.contains("⚠️") || line.contains("WARNING") || line.contains("WARN")
        }
    }

    /// Get lines matching a pattern (for agent analysis)
    func getLinesMatching(pattern: String) -> [String] {
        let contents = getLogContents()
        return contents.components(separatedBy: "\n").filter { line in
            line.localizedCaseInsensitiveContains(pattern)
        }
    }

    /// Get the last N lines from log
    func getLastLines(count: Int) -> [String] {
        let contents = getLogContents()
        let lines = contents.components(separatedBy: "\n")
        return Array(lines.suffix(count))
    }

    /// Get log entries within time range
    func getEntriesSince(_ date: Date) -> String {
        let targetTimestamp = dateFormatter.string(from: date)
        let contents = getLogContents()
        let lines = contents.components(separatedBy: "\n")

        var result: [String] = []
        var capturing = false

        for line in lines {
            // Check if line has timestamp and compare
            if line.contains("[") && line.contains("]") {
                if let timestampEnd = line.firstIndex(of: "]"),
                   let timestampStart = line.firstIndex(of: "[") {
                    let timestamp = String(line[line.index(after: timestampStart)..<timestampEnd])
                    if timestamp >= targetTimestamp.prefix(19) {
                        capturing = true
                    }
                }
            }

            if capturing {
                result.append(line)
            }
        }

        return result.joined(separator: "\n")
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
    case health = "HEALTH"   // FIX #763: Added for health checks
    case p2p = "P2P"         // FIX #763: Added for P2P operations
    case tor = "TOR"         // FIX #763: Added for Tor operations
}

// MARK: - Security audit TASK 18: Log Level Control

/// Log severity levels for controlling output verbosity
enum LogLevel: Int, Comparable {
    case debug = 0, info = 1, warning = 2, error = 3
    static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

extension DebugLogger {
    #if DEBUG
    static let minimumLevel: LogLevel = .debug
    #else
    static let minimumLevel: LogLevel = .warning
    #endif
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
