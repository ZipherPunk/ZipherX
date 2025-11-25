// Copyright (c) 2025 ZipherX Development Team
// Block header storage for header-sync approach

import Foundation
import SQLite3

/// SQLite storage for block headers
/// Stores headers with finalsaplingroot (anchor) for trustless transaction building
final class HeaderStore {
    static let shared = HeaderStore()

    private var db: OpaquePointer?
    private let dbPath: String
    private let queue = DispatchQueue(label: "com.zipherx.headerstore", qos: .userInitiated)

    private init() {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        dbPath = documentsPath.appendingPathComponent("zipherx_headers.db").path
    }

    // MARK: - Database Connection

    /// Open database connection
    func open() throws {
        if db != nil {
            print("📂 HeaderStore already open")
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
            // Block headers table
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
    func insertHeader(_ header: BlockHeader) throws {
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
    func insertHeaders(_ headers: [BlockHeader]) throws {
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
    func getHeader(at height: UInt64) throws -> BlockHeader? {
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
    func getHeader(hash: Data) throws -> BlockHeader? {
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
    func getHeaders(from startHeight: UInt64, to endHeight: UInt64) throws -> [BlockHeader] {
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

        var headers: [BlockHeader] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let header = try parseHeaderFromRow(stmt!)
            headers.append(header)
        }

        return headers
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

    // MARK: - Helper Methods

    private func parseHeaderFromRow(_ stmt: OpaquePointer) throws -> BlockHeader {
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

        return BlockHeader(
            version: version,
            hashPrevBlock: prevHash,
            hashMerkleRoot: merkleRoot,
            hashFinalSaplingRoot: saplingRoot,
            time: time,
            bits: bits,
            nonce: nonce,
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
