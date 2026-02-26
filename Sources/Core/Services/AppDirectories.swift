import Foundation

/// Centralized app directory management
/// On macOS: Uses Application Support (no TCC required)
/// On iOS: Uses Documents (sandboxed, no TCC required)
enum AppDirectories {

    /// Main app data directory
    /// - macOS: ~/Library/Application Support/ZipherX/
    /// - iOS: Documents/
    static var appData: URL {
        #if os(macOS)
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let zipherxDir = appSupport.appendingPathComponent("ZipherX")
        try? FileManager.default.createDirectory(at: zipherxDir, withIntermediateDirectories: true)
        return zipherxDir
        #else
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        #endif
    }

    /// Sapling parameters directory
    static var saplingParams: URL {
        let dir = appData.appendingPathComponent("sapling-params")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Boost file cache directory
    static var boostCache: URL {
        let dir = appData.appendingPathComponent("BoostCache")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Tree cache directory
    static var treeCache: URL {
        let dir = appData.appendingPathComponent("TreeCache")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Debug logs directory
    static var logs: URL {
        let dir = appData.appendingPathComponent("Logs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Database files directory
    static var database: URL {
        return appData // Databases stored in root of app data
    }

    /// Block timestamps file
    static var blockTimestamps: URL {
        return appData.appendingPathComponent("block_timestamps_cache.bin")
    }

    /// Block hashes file
    static var blockHashes: URL {
        return appData.appendingPathComponent("block_hashes.bin")
    }
}
