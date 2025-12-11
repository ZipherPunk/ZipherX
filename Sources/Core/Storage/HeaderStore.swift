// Copyright (c) 2025 Zipherpunk.com dev team
// Block header storage for header-sync approach

import Foundation
// Note: sqlite3 functions are available via bridging header (SQLCipher)
// Do NOT import SQLite3 here as it conflicts with SQLCipher's sqlite3.h

/// SQLite storage for block headers
/// Stores headers with finalsaplingroot (anchor) for trustless transaction building
final class HeaderStore {
    static let shared = HeaderStore()

    private var db: OpaquePointer?
    private let dbPath: String
    private let queue = DispatchQueue(label: "com.zipherx.headerstore", qos: .userInitiated)

    private init() {
        dbPath = AppDirectories.database.appendingPathComponent("zipherx_headers.db").path
    }

    // MARK: - Database Connection

    /// Open database connection
    func open() throws {
        if db != nil {
            // Already open - but still run createTables() to ensure new tables are created
            // (e.g., block_times table added after initial schema)
            try createTables()
            print("📂 HeaderStore already open (schema updated)")
            return
        }

        print("📂 Opening HeaderStore at: \(dbPath)")
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(dbPath, &db, flags, nil) == SQLITE_OK else {
            let errorMsg = db != nil ? String(cString: sqlite3_errmsg(db)) : "Unknown error"
            throw DatabaseError.openFailed(errorMsg)
        }

        try createTables()
        print("📂 HeaderStore opened successfully")
    }

    /// Close database connection
    func close() {
        if db != nil {
            sqlite3_close(db)
            db = nil
        }
    }

    // MARK: - Schema

    private func createTables() throws {
        let schemas = [
            // Block headers table (full headers from P2P sync)
            """
            CREATE TABLE IF NOT EXISTS headers (
                height INTEGER PRIMARY KEY,
                block_hash BLOB NOT NULL UNIQUE,
                prev_hash BLOB NOT NULL,
                merkle_root BLOB NOT NULL,
                sapling_root BLOB NOT NULL,
                time INTEGER NOT NULL,
                bits INTEGER NOT NULL,
                nonce BLOB NOT NULL,
                version INTEGER NOT NULL,
                created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now'))
            );
            """,

            // Block times table (lightweight timestamps from boost file)
            // This provides continuous timestamp coverage without requiring full headers
            """
            CREATE TABLE IF NOT EXISTS block_times (
                height INTEGER PRIMARY KEY,
                timestamp INTEGER NOT NULL
            );
            """,

            // Indexes for performance
            """
            CREATE INDEX IF NOT EXISTS idx_headers_hash ON headers(block_hash);
            CREATE INDEX IF NOT EXISTS idx_headers_time ON headers(time);
            """
        ]

        for schema in schemas {
            guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else {
                throw DatabaseError.schemaCreationFailed(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    // MARK: - Header Operations

    /// Insert or replace a block header
    func insertHeader(_ header: ZclassicBlockHeader) throws {
        let sql = """
            INSERT OR REPLACE INTO headers
            (height, block_hash, prev_hash, merkle_root, sapling_root, time, bits, nonce, version)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        sqlite3_bind_int64(stmt, 1, Int64(header.height))
        header.blockHash.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, 2, ptr.baseAddress, Int32(header.blockHash.count), SQLITE_TRANSIENT)
        }
        header.hashPrevBlock.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, 3, ptr.baseAddress, Int32(header.hashPrevBlock.count), SQLITE_TRANSIENT)
        }
        header.hashMerkleRoot.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, 4, ptr.baseAddress, Int32(header.hashMerkleRoot.count), SQLITE_TRANSIENT)
        }
        header.hashFinalSaplingRoot.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, 5, ptr.baseAddress, Int32(header.hashFinalSaplingRoot.count), SQLITE_TRANSIENT)
        }
        sqlite3_bind_int64(stmt, 6, Int64(header.time))
        sqlite3_bind_int64(stmt, 7, Int64(header.bits))
        header.nonce.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, 8, ptr.baseAddress, Int32(header.nonce.count), SQLITE_TRANSIENT)
        }
        sqlite3_bind_int64(stmt, 9, Int64(header.version))

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.insertFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    /// Batch insert headers (more efficient for syncing)
    func insertHeaders(_ headers: [ZclassicBlockHeader]) throws {
        guard !headers.isEmpty else { return }

        // Use a transaction for batch inserts
        guard sqlite3_exec(db, "BEGIN TRANSACTION;", nil, nil, nil) == SQLITE_OK else {
            throw DatabaseError.insertFailed("Failed to begin transaction")
        }

        do {
            for header in headers {
                try insertHeader(header)
            }

            guard sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK else {
                throw DatabaseError.insertFailed("Failed to commit transaction")
            }
        } catch {
            sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            throw error
        }
    }

    /// Get header at specific height
    func getHeader(at height: UInt64) throws -> ZclassicBlockHeader? {
        let sql = """
            SELECT height, block_hash, prev_hash, merkle_root, sapling_root, time, bits, nonce, version
            FROM headers
            WHERE height = ?;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, Int64(height))

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return nil
        }

        return try parseHeaderFromRow(stmt!)
    }

    /// Get header by block hash
    func getHeader(hash: Data) throws -> ZclassicBlockHeader? {
        let sql = """
            SELECT height, block_hash, prev_hash, merkle_root, sapling_root, time, bits, nonce, version
            FROM headers
            WHERE block_hash = ?;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        hash.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, 1, ptr.baseAddress, Int32(hash.count), SQLITE_TRANSIENT)
        }

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return nil
        }

        return try parseHeaderFromRow(stmt!)
    }

    /// Get anchor (finalsaplingroot) for a specific height
    /// This is the critical method for transaction building!
    func getAnchor(at height: UInt64) throws -> Data? {
        let sql = "SELECT sapling_root FROM headers WHERE height = ?;"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, Int64(height))

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return nil
        }

        guard let ptr = sqlite3_column_blob(stmt, 0) else {
            return nil
        }
        let len = sqlite3_column_bytes(stmt, 0)
        return Data(bytes: ptr, count: Int(len))
    }

    /// Get latest height in database
    func getLatestHeight() throws -> UInt64? {
        let sql = "SELECT MAX(height) FROM headers;"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return nil
        }

        if sqlite3_column_type(stmt, 0) == SQLITE_NULL {
            return nil
        }

        return UInt64(sqlite3_column_int64(stmt, 0))
    }

    /// Get total header count
    func getHeaderCount() throws -> Int {
        let sql = "SELECT COUNT(*) FROM headers;"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return 0
        }

        return Int(sqlite3_column_int(stmt, 0))
    }

    /// Get headers in a range (for syncing)
    func getHeaders(from startHeight: UInt64, to endHeight: UInt64) throws -> [ZclassicBlockHeader] {
        let sql = """
            SELECT height, block_hash, prev_hash, merkle_root, sapling_root, time, bits, nonce, version
            FROM headers
            WHERE height >= ? AND height <= ?
            ORDER BY height ASC;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, Int64(startHeight))
        sqlite3_bind_int64(stmt, 2, Int64(endHeight))

        var headers: [ZclassicBlockHeader] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let header = try parseHeaderFromRow(stmt!)
            headers.append(header)
        }

        return headers
    }

    /// Get block timestamp by height
    /// Checks: 1) Full headers table (from P2P sync), 2) block_times table (from boost file)
    /// Returns the actual Unix timestamp for the block
    func getBlockTime(at height: UInt64) throws -> UInt32? {
        // FIX #120: Ensure database is open before querying
        if db == nil {
            try open()
        }
        guard db != nil else { return nil }

        // First, check full headers table (P2P synced headers have priority)
        let headerSql = "SELECT time FROM headers WHERE height = ? LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, headerSql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }

        sqlite3_bind_int64(stmt, 1, Int64(height))

        if sqlite3_step(stmt) == SQLITE_ROW {
            let timestamp = UInt32(sqlite3_column_int64(stmt, 0))
            sqlite3_finalize(stmt)
            return timestamp
        }
        sqlite3_finalize(stmt)

        // Second, check block_times table (from boost file)
        let blockTimeSql = "SELECT timestamp FROM block_times WHERE height = ? LIMIT 1;"
        var stmt2: OpaquePointer?
        guard sqlite3_prepare_v2(db, blockTimeSql, -1, &stmt2, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt2) }

        sqlite3_bind_int64(stmt2, 1, Int64(height))

        if sqlite3_step(stmt2) == SQLITE_ROW {
            return UInt32(sqlite3_column_int64(stmt2, 0))
        }
        return nil
    }

    // MARK: - Block Times (from boost file)

    /// Insert a single block timestamp (from boost file or sync)
    func insertBlockTime(height: UInt64, timestamp: UInt32) throws {
        // FIX #120: Ensure database is open before inserting
        if db == nil {
            try open()
        }
        guard db != nil else { return }

        let sql = "INSERT OR REPLACE INTO block_times (height, timestamp) VALUES (?, ?);"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, Int64(height))
        sqlite3_bind_int64(stmt, 2, Int64(timestamp))

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.insertFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    /// Batch insert block timestamps from boost file (efficient bulk load)
    /// timestamps: Array of (height, timestamp) pairs
    func insertBlockTimesBatch(_ timestamps: [(UInt64, UInt32)]) throws {
        guard !timestamps.isEmpty else { return }

        // FIX #120: Ensure database is open before inserting
        if db == nil {
            try open()
        }
        guard db != nil else { return }

        guard sqlite3_exec(db, "BEGIN TRANSACTION;", nil, nil, nil) == SQLITE_OK else {
            throw DatabaseError.insertFailed("Failed to begin transaction")
        }

        let sql = "INSERT OR REPLACE INTO block_times (height, timestamp) VALUES (?, ?);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }

        do {
            for (height, timestamp) in timestamps {
                sqlite3_reset(stmt)
                sqlite3_bind_int64(stmt, 1, Int64(height))
                sqlite3_bind_int64(stmt, 2, Int64(timestamp))

                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    throw DatabaseError.insertFailed(String(cString: sqlite3_errmsg(db)))
                }
            }

            sqlite3_finalize(stmt)

            guard sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK else {
                throw DatabaseError.insertFailed("Failed to commit transaction")
            }
        } catch {
            sqlite3_finalize(stmt)
            sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            throw error
        }
    }

    /// Insert block timestamps from boost file data
    /// data: Raw timestamp data (4 bytes per timestamp, little-endian)
    /// startHeight: First block height in the data
    /// Uses chunked inserts to avoid SQLite out-of-memory errors
    func insertBlockTimesFromBoostData(_ data: Data, startHeight: UInt64) throws {
        let timestampCount = data.count / 4
        guard timestampCount > 0 else { return }

        let endHeight = startHeight + UInt64(timestampCount) - 1
        print("⏰ HeaderStore: Loading \(timestampCount) timestamps from boost file (heights \(startHeight) to \(endHeight))")

        // Process in chunks of 50,000 to avoid out-of-memory errors
        let chunkSize = 50000
        var processedCount = 0

        let sql = "INSERT OR REPLACE INTO block_times (height, timestamp) VALUES (?, ?);"

        try data.withUnsafeBytes { ptr in
            var currentIndex = 0

            while currentIndex < timestampCount {
                // Begin transaction for this chunk
                guard sqlite3_exec(db, "BEGIN TRANSACTION;", nil, nil, nil) == SQLITE_OK else {
                    throw DatabaseError.insertFailed("Failed to begin transaction")
                }

                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                    sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                    throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
                }

                let endIndex = min(currentIndex + chunkSize, timestampCount)

                for i in currentIndex..<endIndex {
                    let timestamp = ptr.load(fromByteOffset: i * 4, as: UInt32.self)
                    let height = startHeight + UInt64(i)

                    sqlite3_reset(stmt)
                    sqlite3_bind_int64(stmt, 1, Int64(height))
                    sqlite3_bind_int64(stmt, 2, Int64(timestamp))

                    guard sqlite3_step(stmt) == SQLITE_DONE else {
                        let error = String(cString: sqlite3_errmsg(db))
                        sqlite3_finalize(stmt)
                        sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                        throw DatabaseError.insertFailed(error)
                    }
                }

                sqlite3_finalize(stmt)

                // Commit this chunk
                guard sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK else {
                    throw DatabaseError.insertFailed("Failed to commit transaction")
                }

                processedCount += (endIndex - currentIndex)
                currentIndex = endIndex

                // Progress log every 500k entries
                if processedCount % 500000 == 0 || processedCount == timestampCount {
                    print("⏰ HeaderStore: Inserted \(processedCount)/\(timestampCount) timestamps...")
                }
            }
        }

        print("✅ HeaderStore: Loaded \(timestampCount) timestamps into block_times table")
    }

    /// Get count of timestamps in block_times table
    func getBlockTimesCount() throws -> Int {
        // FIX #120: Ensure database is open before querying
        if db == nil {
            try open()
        }
        guard db != nil else { return 0 }

        let sql = "SELECT COUNT(*) FROM block_times;"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return 0
        }

        return Int(sqlite3_column_int64(stmt, 0))
    }

    /// Clear all block times (for repair/resync)
    func clearBlockTimes() throws {
        let sql = "DELETE FROM block_times;"

        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw DatabaseError.deleteFailed(String(cString: sqlite3_errmsg(db)))
        }

        print("🗑️ Cleared all block times")
    }

    /// Check if header exists at height
    func hasHeader(at height: UInt64) throws -> Bool {
        let sql = "SELECT 1 FROM headers WHERE height = ? LIMIT 1;"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, Int64(height))

        return sqlite3_step(stmt) == SQLITE_ROW
    }

    /// Delete headers above a certain height (for reorg handling)
    func deleteHeadersAbove(height: UInt64) throws {
        let sql = "DELETE FROM headers WHERE height > ?;"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, Int64(height))

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.deleteFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    /// Clear all headers (for full resync)
    func clearAllHeaders() throws {
        let sql = "DELETE FROM headers;"

        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw DatabaseError.deleteFailed(String(cString: sqlite3_errmsg(db)))
        }

        print("🗑️ Cleared all headers")
    }

    /// Delete the entire header database file (for wallet deletion)
    func deleteDatabase() throws {
        // Close connection first
        close()

        // Delete the database file
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: dbPath) {
            try fileManager.removeItem(atPath: dbPath)
            print("🗑️ Header store deleted: \(dbPath)")
        }

        // Also delete any journal/wal files
        let walPath = dbPath + "-wal"
        let shmPath = dbPath + "-shm"
        let journalPath = dbPath + "-journal"

        if fileManager.fileExists(atPath: walPath) {
            try? fileManager.removeItem(atPath: walPath)
        }
        if fileManager.fileExists(atPath: shmPath) {
            try? fileManager.removeItem(atPath: shmPath)
        }
        if fileManager.fileExists(atPath: journalPath) {
            try? fileManager.removeItem(atPath: journalPath)
        }
    }

    // MARK: - Helper Methods

    private func parseHeaderFromRow(_ stmt: OpaquePointer) throws -> ZclassicBlockHeader {
        let height = UInt64(sqlite3_column_int64(stmt, 0))

        guard let hashPtr = sqlite3_column_blob(stmt, 1) else {
            throw DatabaseError.queryFailed("Missing block_hash")
        }
        let hashLen = sqlite3_column_bytes(stmt, 1)
        let blockHash = Data(bytes: hashPtr, count: Int(hashLen))

        guard let prevPtr = sqlite3_column_blob(stmt, 2) else {
            throw DatabaseError.queryFailed("Missing prev_hash")
        }
        let prevLen = sqlite3_column_bytes(stmt, 2)
        let prevHash = Data(bytes: prevPtr, count: Int(prevLen))

        guard let merklePtr = sqlite3_column_blob(stmt, 3) else {
            throw DatabaseError.queryFailed("Missing merkle_root")
        }
        let merkleLen = sqlite3_column_bytes(stmt, 3)
        let merkleRoot = Data(bytes: merklePtr, count: Int(merkleLen))

        guard let saplingPtr = sqlite3_column_blob(stmt, 4) else {
            throw DatabaseError.queryFailed("Missing sapling_root")
        }
        let saplingLen = sqlite3_column_bytes(stmt, 4)
        let saplingRoot = Data(bytes: saplingPtr, count: Int(saplingLen))

        let time = UInt32(sqlite3_column_int64(stmt, 5))
        let bits = UInt32(sqlite3_column_int64(stmt, 6))

        guard let noncePtr = sqlite3_column_blob(stmt, 7) else {
            throw DatabaseError.queryFailed("Missing nonce")
        }
        let nonceLen = sqlite3_column_bytes(stmt, 7)
        let nonce = Data(bytes: noncePtr, count: Int(nonceLen))

        let version = UInt32(sqlite3_column_int64(stmt, 8))

        return ZclassicBlockHeader(
            version: version,
            hashPrevBlock: prevHash,
            hashMerkleRoot: merkleRoot,
            hashFinalSaplingRoot: saplingRoot,
            time: time,
            bits: bits,
            nonce: nonce,
            solution: Data(),  // Not stored - headers from DB were already verified
            height: height,
            blockHash: blockHash
        )
    }

    // MARK: - Statistics

    /// Get storage statistics
    func getStats() throws -> HeaderStoreStats {
        guard let latestHeight = try getLatestHeight() else {
            return HeaderStoreStats(count: 0, latestHeight: nil, storageSize: 0)
        }

        let count = try getHeaderCount()

        // Calculate storage size
        let fileManager = FileManager.default
        var storageSize: Int64 = 0
        if let attrs = try? fileManager.attributesOfItem(atPath: dbPath) {
            storageSize = attrs[.size] as? Int64 ?? 0
        }

        return HeaderStoreStats(
            count: count,
            latestHeight: latestHeight,
            storageSize: storageSize
        )
    }
}

// MARK: - Data Types

struct HeaderStoreStats {
    let count: Int
    let latestHeight: UInt64?
    let storageSize: Int64

    var storageSizeMB: Double {
        Double(storageSize) / (1024.0 * 1024.0)
    }
}
