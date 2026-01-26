//
//  TempImportDatabase.swift
//  ZipherX
//
//  FIX #506: Parallel Import Architecture with Temp Tables
//  Created to speed up import PK by running extraction tasks in parallel
//

import Foundation
// Note: sqlite3 functions are available via bridging header (SQLCipher)
// Do NOT import SQLite3 here as it conflicts with SQLCipher's sqlite3.h
import CryptoKit

/// Temporary database for parallel import operations
/// Uses temp tables to isolate partial data until verified and committed
actor TempImportDatabase {
    static let shared = TempImportDatabase()

    private var db: OpaquePointer?
    private let dbPath: String
    private let lock = NSLock()

    private init() {
        let paths = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)
        let documentsDirectory = paths[0]
        self.dbPath = (documentsDirectory as NSString).appendingPathComponent("wallet_temp.db")
        openDatabase()
    }

    private func openDatabase() {
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
            print("❌ TempImportDatabase: Failed to open database at \(dbPath)")
            return
        }

        // Enable WAL mode for concurrent access
        executeSQL("PRAGMA journal_mode=WAL;")
        executeSQL("PRAGMA synchronous=NORMAL;")
        executeSQL("PRAGMA cache_size=32000;")  // 32MB cache

        print("✅ TempImportDatabase: Opened at \(dbPath)")
    }

    /// Create all temp tables for parallel import
    func createTempTables() throws {
        print("📋 Creating temp tables for parallel import...")

        // Temp headers table
        try executeSQLThrowing("""
            CREATE TABLE IF NOT EXISTS temp_headers (
                height INTEGER PRIMARY KEY,
                version INTEGER,
                prev_hash BLOB,
                merkle_root BLOB,
                sapling_root BLOB,
                timestamp INTEGER,
                bits INTEGER,
                nonce BLOB,
                hash BLOB UNIQUE,
                is_verified BOOLEAN DEFAULT 0
            );
        """)

        // Temp CMUs table
        try executeSQLThrowing("""
            CREATE TABLE IF NOT EXISTS temp_cmus (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                height INTEGER NOT NULL,
                output_index INTEGER NOT NULL,
                cmu BLOB NOT NULL,
                epoch INTEGER NOT NULL,
                UNIQUE(height, output_index)
            );
        """)

        // Import jobs tracker
        try executeSQLThrowing("""
            CREATE TABLE IF NOT EXISTS import_jobs (
                job_id TEXT PRIMARY KEY,
                job_type TEXT NOT NULL,
                status TEXT NOT NULL,
                progress REAL DEFAULT 0,
                started_at INTEGER,
                completed_at INTEGER,
                error_message TEXT
            );
        """)

        // Import state for resume capability
        try executeSQLThrowing("""
            CREATE TABLE IF NOT EXISTS import_state (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL,
                updated_at INTEGER DEFAULT (strftime('%s', 'now'))
            );
        """)

        print("✅ Temp tables created successfully")
    }

    /// Insert headers into temp table (parallel safe)
    func insertTempHeaders(_ headers: [TempHeader]) throws {
        try executeSQLThrowing("BEGIN IMMEDIATE TRANSACTION")

        for header in headers {
            let stmt = try prepareSQL("""
                INSERT OR REPLACE INTO temp_headers
                (height, version, prev_hash, merkle_root, sapling_root,
                 timestamp, bits, nonce, hash, is_verified)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                """)

            sqlite3_bind_int64(stmt, 1, Int64(header.height))
            bindBlob(stmt, 2, header.prevHash)
            bindBlob(stmt, 3, header.merkleRoot)
            bindBlob(stmt, 4, header.saplingRoot)
            sqlite3_bind_int64(stmt, 5, Int64(header.timestamp))
            // FIX #565: Use bind_int64 for bits to handle full UInt32 range (bits can exceed Int32.max)
            sqlite3_bind_int64(stmt, 6, Int64(header.bits))
            bindBlob(stmt, 7, header.nonce)
            bindBlob(stmt, 8, header.hash)
            sqlite3_bind_int64(stmt, 9, Int64(header.version))
            sqlite3_bind_int(stmt, 10, header.isVerified ? 1 : 0)

            guard sqlite3_step(stmt) == SQLITE_DONE else {
                sqlite3_finalize(stmt)
                throw TempImportError.insertFailed("Failed to insert header at height \(header.height)")
            }

            sqlite3_finalize(stmt)
        }

        try executeSQLThrowing("COMMIT")
        print("✅ Inserted \(headers.count) headers into temp_headers")
    }

    /// Insert CMUs into temp table (parallel safe)
    func insertTempCMUs(_ cmus: [TempCMU]) throws {
        try executeSQLThrowing("BEGIN IMMEDIATE TRANSACTION")

        // Batch insert for performance
        let stmt = try prepareSQL("""
            INSERT OR REPLACE INTO temp_cmus
            (height, output_index, cmu, epoch)
            VALUES (?, ?, ?, ?);
            """)

        for cmu in cmus {
            sqlite3_bind_int64(stmt, 1, Int64(cmu.height))
            sqlite3_bind_int64(stmt, 2, Int64(cmu.outputIndex))
            bindBlob(stmt, 3, cmu.cmu)
            sqlite3_bind_int64(stmt, 4, Int64(cmu.epoch))

            guard sqlite3_step(stmt) == SQLITE_DONE else {
                sqlite3_finalize(stmt)
                throw TempImportError.insertFailed("Failed to insert CMU at height \(cmu.height)")
            }

            sqlite3_reset(stmt)
        }

        sqlite3_finalize(stmt)
        try executeSQLThrowing("COMMIT")
        print("✅ Inserted \(cmus.count) CMUs into temp_cmus")
    }

    /// Move temp headers to production HeaderStore
    func moveTempHeadersToProduction() throws {
        print("📋 Moving temp headers to production...")

        // This is handled by HeaderStore directly via loadHeadersFromBoostData
        // We just need to provide the count for verification
        let count = try getTempHeaderCount()
        print("✅ Verified \(count) temp headers ready for production")
    }

    /// Build CMU data from temp table for FFI tree build
    func buildCMUDataFromTemp() throws -> Data {
        print("🌳 Building CMU data from temp_cmus table...")

        let stmt = try prepareSQL("""
            SELECT height, output_index, cmu, epoch
            FROM temp_cmus
            ORDER BY height, output_index;
            """)

        var cmuData = Data()
        var count = 0

        while sqlite3_step(stmt) == SQLITE_ROW {
            let height = Int(sqlite3_column_int64(stmt, 0))
            let outputIndex = Int(sqlite3_column_int64(stmt, 1))
            let cmu = getBlob(stmt, 2)
            let epoch = Int(sqlite3_column_int64(stmt, 3))

            // Append in legacy format: height(4) + outputIndex(4) + cmu(32) + epoch(4)
            cmuData.append(UInt32(height).data)
            cmuData.append(UInt32(outputIndex).data)
            cmuData.append(cmu)
            cmuData.append(UInt32(epoch).data)

            count += 1

            // Report progress every 100k CMUs
            if count % 100000 == 0 {
                print("🌳 Processed \(count) CMUs from temp table...")
            }
        }

        sqlite3_finalize(stmt)
        print("✅ Built CMU data: \(cmuData.count) bytes from \(count) CMUs")
        return cmuData
    }

    /// Drop all temp tables
    func dropTempTables() throws {
        try executeSQLThrowing("DROP TABLE IF EXISTS temp_headers;")
        try executeSQLThrowing("DROP TABLE IF EXISTS temp_cmus;")
        try executeSQLThrowing("DROP TABLE IF EXISTS import_jobs;")
        try executeSQLThrowing("DROP TABLE IF EXISTS import_state;")
        print("✅ Dropped all temp tables")
    }

    /// Clear all temp data (keeps tables)
    func clearTempData() throws {
        try executeSQLThrowing("DELETE FROM temp_headers;")
        try executeSQLThrowing("DELETE FROM temp_cmus;")
        try executeSQLThrowing("DELETE FROM import_jobs;")
        try executeSQLThrowing("DELETE FROM import_state;")
        print("✅ Cleared all temp data")
    }

    // MARK: - Verification Methods

    func getTempHeaderCount() throws -> Int {
        let stmt = try prepareSQL("SELECT COUNT(*) FROM temp_headers;")
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw TempImportError.queryFailed("Failed to count temp headers")
        }
        let count = Int(sqlite3_column_int64(stmt, 0))
        sqlite3_finalize(stmt)
        return count
    }

    func getTempCMUCount() throws -> Int {
        let stmt = try prepareSQL("SELECT COUNT(*) FROM temp_cmus;")
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw TempImportError.queryFailed("Failed to count temp CMUs")
        }
        let count = Int(sqlite3_column_int64(stmt, 0))
        sqlite3_finalize(stmt)
        return count
    }

    func verifyNoDuplicateHeights() throws -> Bool {
        let stmt = try prepareSQL("""
            SELECT COUNT(*) FROM (
                SELECT height, COUNT(*) as cnt
                FROM temp_headers
                GROUP BY height
                HAVING cnt > 1
            );
            """)
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            sqlite3_finalize(stmt)
            throw TempImportError.queryFailed("Failed to check duplicate heights")
        }
        let duplicates = Int(sqlite3_column_int64(stmt, 0))
        sqlite3_finalize(stmt)
        return duplicates == 0
    }

    func verifyTempHeaderIntegrity() throws -> Bool {
        // Check that we have a sequential range from start height
        let stmt = try prepareSQL("""
            SELECT MIN(height), MAX(height), COUNT(*)
            FROM temp_headers;
            """)
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            sqlite3_finalize(stmt)
            throw TempImportError.queryFailed("Failed to verify header integrity")
        }

        let minHeight = Int(sqlite3_column_int64(stmt, 0))
        let maxHeight = Int(sqlite3_column_int64(stmt, 1))
        let count = Int(sqlite3_column_int64(stmt, 2))
        sqlite3_finalize(stmt)

        let expectedCount = maxHeight - minHeight + 1
        return count == expectedCount
    }

    /// Save import state for resume capability
    func saveImportState(key: String, value: String) throws {
        let stmt = try prepareSQL("""
            INSERT OR REPLACE INTO import_state (key, value, updated_at)
            VALUES (?, ?, strftime('%s', 'now'));
            """)
        sqlite3_bind_text(stmt, 1, (key as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (value as NSString).utf8String, -1, nil)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            sqlite3_finalize(stmt)
            throw TempImportError.insertFailed("Failed to save import state")
        }
        sqlite3_finalize(stmt)
    }

    /// Load import state
    func loadImportState(key: String) throws -> String? {
        let stmt = try prepareSQL("SELECT value FROM import_state WHERE key = ?;")
        sqlite3_bind_text(stmt, 1, (key as NSString).utf8String, -1, nil)

        if sqlite3_step(stmt) == SQLITE_ROW {
            if let value = sqlite3_column_text(stmt, 0) {
                let result = String(cString: value)
                sqlite3_finalize(stmt)
                return result
            }
        }
        sqlite3_finalize(stmt)
        return nil
    }

    // MARK: - Private Helper Methods

    private func executeSQL(_ sql: String) {
        lock.lock()
        defer { lock.unlock() }

        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            let error = String(cString: sqlite3_errmsg(db)!)
            print("❌ TempImportDatabase SQL error: \(error)")
            return
        }
    }

    private func executeSQLThrowing(_ sql: String) throws {
        lock.lock()
        defer { lock.unlock() }

        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            let error = String(cString: sqlite3_errmsg(db)!)
            throw TempImportError.queryFailed(error)
        }
    }

    private func prepareSQL(_ sql: String) throws -> OpaquePointer {
        lock.lock()
        defer { lock.unlock() }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let error = String(cString: sqlite3_errmsg(db)!)
            throw TempImportError.preparationFailed(error)
        }
        return stmt!
    }

    private func bindBlob(_ stmt: OpaquePointer, _ index: Int32, _ data: Data) {
        data.withUnsafeBytes { bytes in
            sqlite3_bind_blob(stmt, index, bytes.baseAddress, Int32(data.count), nil)
        }
    }

    private func getBlob(_ stmt: OpaquePointer, _ index: Int32) -> Data {
        if let bytes = sqlite3_column_blob(stmt, index) {
            let count = Int(sqlite3_column_bytes(stmt, index))
            return Data(bytes: bytes, count: count)
        }
        return Data()
    }

    deinit {
        sqlite3_close(db)
    }
}

// MARK: - Supporting Types

/// Temporary header representation before verification
struct TempHeader {
    let height: Int
    let version: Int
    let prevHash: Data
    let merkleRoot: Data
    let saplingRoot: Data
    let timestamp: Int
    let bits: Int
    let nonce: Data
    let hash: Data
    var isVerified: Bool = false
}

/// Temporary CMU representation
struct TempCMU {
    let height: Int
    let outputIndex: Int
    let cmu: Data
    let epoch: Int
}

/// Import job types for parallel execution
enum ImportJobType: String, CaseIterable {
    case headers = "headers"
    case cmus = "cmus"
    case network = "network"
    case hashes = "hashes"
    case tree = "tree"

    var displayName: String {
        switch self {
        case .headers: return "Headers"
        case .cmus: return "Commitments"
        case .network: return "Network"
        case .hashes: return "Block Hashes"
        case .tree: return "Tree Build"
        }
    }
}

/// Import job status
enum JobStatus: String {
    case pending = "pending"
    case running = "running"
    case completed = "completed"
    case failed = "failed"

    var displayName: String {
        switch self {
        case .pending: return "Waiting..."
        case .running: return "Running"
        case .completed: return "Complete"
        case .failed: return "Failed"
        }
    }
}

/// Import job tracking
struct ImportJob {
    let id: String
    let type: ImportJobType
    var status: JobStatus
    var progress: Double = 0
    let startedAt: Date
    var completedAt: Date?
    var errorMessage: String?

    init(id: String = UUID().uuidString, type: ImportJobType, status: JobStatus = .pending) {
        self.id = id
        self.type = type
        self.status = status
        self.startedAt = Date()
    }
}

/// Import progress for UI updates
struct ImportProgress {
    let type: ImportJobType
    let progress: Double
    let status: String

    init(type: ImportJobType, progress: Double, status: String) {
        self.type = type
        self.progress = progress
        self.status = status
    }
}

/// Result of parallel extraction
struct ParallelExtractionResult {
    let tempHeaders: [TempHeader]
    let tempCMUs: [TempCMU]
    let headersCount: Int
    let cmusCount: Int
    let duration: TimeInterval

    init(tempHeaders: [TempHeader], tempCMUs: [TempCMU], duration: TimeInterval) {
        self.tempHeaders = tempHeaders
        self.tempCMUs = tempCMUs
        self.headersCount = tempHeaders.count
        self.cmusCount = tempCMUs.count
        self.duration = duration
    }
}

/// Temp import errors
enum TempImportError: LocalizedError {
    case databaseClosed
    case queryFailed(String)
    case preparationFailed(String)
    case insertFailed(String)
    case verificationFailed(String)

    var errorDescription: String? {
        switch self {
        case .databaseClosed:
            return "Database is closed"
        case .queryFailed(let msg):
            return "Query failed: \(msg)"
        case .preparationFailed(let msg):
            return "Statement preparation failed: \(msg)"
        case .insertFailed(let msg):
            return "Insert failed: \(msg)"
        case .verificationFailed(let msg):
            return "Verification failed: \(msg)"
        }
    }
}

// MARK: - Extensions

extension UInt32 {
    var data: Data {
        var value = self.littleEndian
        return Data(bytes: &value, count: MemoryLayout<UInt32>.size)
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let importJobProgress = Notification.Name("importJobProgress")
    static let importJobCompleted = Notification.Name("importJobCompleted")
    static let importJobFailed = Notification.Name("importJobFailed")
}
