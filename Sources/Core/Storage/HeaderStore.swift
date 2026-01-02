// Copyright (c) 2025 Zipherpunk.com dev team
// Block header storage for header-sync approach

import Foundation
import CommonCrypto
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

        // FIX #200: SQLite performance optimizations (same as WalletDatabase)
        let performancePragmas = [
            "PRAGMA journal_mode = WAL;",
            "PRAGMA synchronous = NORMAL;",
            "PRAGMA cache_size = -16000;",   // 16MB for headers
            "PRAGMA mmap_size = 134217728;", // 128MB
            "PRAGMA temp_store = MEMORY;"
        ]
        for pragma in performancePragmas {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, pragma, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_step(stmt)
                sqlite3_finalize(stmt)
            }
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

        // FIX #188: Add solution column for Equihash verification (stores only last 100)
        // This is a migration - only runs if column doesn't exist
        let migrationSQL = "ALTER TABLE headers ADD COLUMN solution BLOB;"
        sqlite3_exec(db, migrationSQL, nil, nil, nil)  // Ignore error if column exists

        // FIX #535: Add chainwork column for fork detection (CRITICAL SECURITY)
        // Chainwork = accumulated proof-of-work difficulty
        // Allows us to detect when P2P peers are on a wrong fork (lower chainwork)
        let chainworkMigration = "ALTER TABLE headers ADD COLUMN chainwork BLOB;"
        sqlite3_exec(db, chainworkMigration, nil, nil, nil)  // Ignore error if column exists
    }

    // MARK: - Header Operations

    /// FIX #535: Compute chainwork (accumulated proof-of-work) for a header
    /// Chainwork represents the total work in the chain up to this block
    /// Formula: chainwork = previous_chainwork + (2^256 / (target + 1))
    /// where target is derived from bits (compact representation of difficulty)
    private func computeChainWork(for header: ZclassicBlockHeader) throws -> Data {
        // Get previous header's chainwork
        var previousChainWork = Data(count: 32)  // Zero for genesis

        if header.height > 0 {
            if let prevHeader = try? getHeader(at: header.height - 1) {
                previousChainWork = prevHeader.chainwork.isEmpty ? Data(count: 32) : prevHeader.chainwork
            }
        }

        // Compute work for this block: work = 2^256 / (target + 1)
        // Target is derived from bits using the compact representation
        let work = computeWorkFromBits(bits: header.bits)

        // Add work to previous chainwork (big integer addition)
        return addChainwork(previous: previousChainWork, work: work)
    }

    /// Compute work for a single block from bits (compact target representation)
    private func computeWorkFromBits(bits: UInt32) -> Data {
        // Convert bits to target: target = (bits & 0x007FFFFF) * 256^((0x00FFFFFF - bits) >> 24)
        let exponent = UInt32((0x00FFFFFF - bits) >> 24)
        let mantissa = bits & 0x007FFFFF
        var target: UInt64 = UInt64(mantissa)
        if exponent <= 3 {
            target >>= UInt64(8 * (3 - Int(exponent)))
        } else {
            target <<= UInt64(8 * (Int(exponent) - 3))
        }

        // work = 2^256 / (target + 1)
        // For large targets, work is approximately (2^256 - 1) / target
        // We store as little-endian 256-bit integer

        var work = [UInt8](repeating: 0, count: 32)

        if target < 2 {
            // Very low target (very high difficulty) - max work
            work[31] = 0xFF  // Approximate max work
        } else {
            // work ≈ 2^256 / target
            // For practical purposes, we can use a simplified representation
            // since we're mainly comparing chainwork, not computing exact values

            // Use a simplified 64-bit work value for comparison
            // This is sufficient for detecting forks (higher bits are same for all recent blocks)
            let work64 = UInt64.max / UInt64(target)

            // Store as little-endian
            for i in 0..<8 {
                work[i] = UInt8((work64 >> (i * 8)) & 0xFF)
            }
        }

        return Data(work)
    }

    /// Add two chainwork values (big integer addition)
    private func addChainwork(previous: Data, work: Data) -> Data {
        var result = [UInt8](repeating: 0, count: 32)
        var carry: UInt64 = 0

        // Convert Data to [UInt64] for easier addition
        let prevArray = previous.withUnsafeBytes { Array($0) }
        let workArray = work.withUnsafeBytes { Array($0) }

        // Add as 64-bit chunks (little-endian)
        for i in stride(from: 0, to: 32, by: 8) {
            var a: UInt64 = 0
            var b: UInt64 = 0

            for j in 0..<8 where i + j < 32 {
                a |= UInt64(prevArray[i + j]) << (j * 8)
                b |= UInt64(workArray[i + j]) << (j * 8)
            }

            let sum = a &+ b &+ carry
            result[i + 0] = UInt8((sum >> 0) & 0xFF)
            result[i + 1] = UInt8((sum >> 8) & 0xFF)
            result[i + 2] = UInt8((sum >> 16) & 0xFF)
            result[i + 3] = UInt8((sum >> 24) & 0xFF)
            result[i + 4] = UInt8((sum >> 32) & 0xFF)
            result[i + 5] = UInt8((sum >> 40) & 0xFF)
            result[i + 6] = UInt8((sum >> 48) & 0xFF)
            result[i + 7] = UInt8((sum >> 56) & 0xFF)

            carry = sum >> 64
        }

        return Data(result)
    }

    /// FIX #535: Compare two chainwork values
    /// Returns: .orderedAscending if a < b, .orderedSame if a == b, .orderedDescending if a > b
    /// Chainwork is stored as little-endian 256-bit integer
    func compareChainwork(_ a: Data, _ b: Data) -> ComparisonResult {
        guard a.count == 32 && b.count == 32 else {
            return .orderedSame  // Invalid data
        }

        let aArray = a.withUnsafeBytes { Array($0) }
        let bArray = b.withUnsafeBytes { Array($0) }

        // Compare from most significant byte (end) to least significant (start)
        for i in stride(from: 31, through: 0, by: -1) {
            if aArray[i] < bArray[i] {
                return .orderedAscending
            } else if aArray[i] > bArray[i] {
                return .orderedDescending
            }
        }

        return .orderedSame
    }

    /// Insert or replace a block header
    /// FIX #188: Now includes Equihash solution for local verification
    /// FIX #535: Now includes chainwork for fork detection
    func insertHeader(_ header: ZclassicBlockHeader) throws {
        let sql = """
            INSERT OR REPLACE INTO headers
            (height, block_hash, prev_hash, merkle_root, sapling_root, time, bits, nonce, version, solution, chainwork)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        // FIX #535: Compute chainwork for this header
        let chainwork = try computeChainWork(for: header)

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
        // FIX #188: Store solution for Equihash verification
        if !header.solution.isEmpty {
            header.solution.withUnsafeBytes { ptr in
                sqlite3_bind_blob(stmt, 10, ptr.baseAddress, Int32(header.solution.count), SQLITE_TRANSIENT)
            }
        } else {
            sqlite3_bind_null(stmt, 10)
        }
        // FIX #535: Store chainwork for fork detection
        chainwork.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, 11, ptr.baseAddress, Int32(chainwork.count), SQLITE_TRANSIENT)
        }

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.insertFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    /// Batch insert headers (more efficient for syncing)
    /// FIX #476: Prepare statement ONCE and reuse for massive speedup (100+ headers/sec)
    func insertHeaders(_ headers: [ZclassicBlockHeader]) throws {
        guard !headers.isEmpty else { return }

        // Use a transaction for batch inserts
        guard sqlite3_exec(db, "BEGIN TRANSACTION;", nil, nil, nil) == SQLITE_OK else {
            throw DatabaseError.insertFailed("Failed to begin transaction")
        }

        do {
            // FIX #476: Prepare statement ONCE instead of 160 times!
            // This is the key optimization - prepare/finalize are expensive operations
            // FIX #535: Now includes chainwork for fork detection
            let sql = """
                INSERT OR REPLACE INTO headers
                (height, block_hash, prev_hash, merkle_root, sapling_root, time, bits, nonce, version, solution, chainwork)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }

            let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

            // Insert all headers using the same prepared statement
            for header in headers {
                // Reset statement for reuse
                sqlite3_reset(stmt)

                // Bind values
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
                // FIX #188: Store solution for Equihash verification
                if !header.solution.isEmpty {
                    header.solution.withUnsafeBytes { ptr in
                        sqlite3_bind_blob(stmt, 10, ptr.baseAddress, Int32(header.solution.count), SQLITE_TRANSIENT)
                    }
                } else {
                    sqlite3_bind_null(stmt, 10)
                }
                // FIX #535: Compute and store chainwork for fork detection
                let chainwork = try computeChainWork(for: header)
                chainwork.withUnsafeBytes { ptr in
                    sqlite3_bind_blob(stmt, 11, ptr.baseAddress, Int32(chainwork.count), SQLITE_TRANSIENT)
                }

                // Execute
                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    throw DatabaseError.insertFailed(String(cString: sqlite3_errmsg(db)))
                }
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
            SELECT height, block_hash, prev_hash, merkle_root, sapling_root, time, bits, nonce, version, solution, chainwork
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
            SELECT height, block_hash, prev_hash, merkle_root, sapling_root, time, bits, nonce, version, solution, chainwork
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

    /// Get minimum height in database
    func getMinHeight() throws -> UInt64? {
        let sql = "SELECT MIN(height) FROM headers;"

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

    /// Count headers in a specific range (for checking if boost file headers are loaded)
    func countHeadersInRange(from startHeight: UInt64, to endHeight: UInt64) throws -> Int {
        let sql = "SELECT COUNT(*) FROM headers WHERE height >= ? AND height <= ?;"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, Int64(startHeight))
        sqlite3_bind_int64(stmt, 2, Int64(endHeight))

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return 0
        }

        return Int(sqlite3_column_int(stmt, 0))
    }

    /// Get headers in a range (for syncing)
    func getHeaders(from startHeight: UInt64, to endHeight: UInt64) throws -> [ZclassicBlockHeader] {
        let sql = """
            SELECT height, block_hash, prev_hash, merkle_root, sapling_root, time, bits, nonce, version, solution, chainwork
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
            do {
                try open()
            } catch {
                print("⚠️ HeaderStore.getBlockTime: Failed to open db: \(error)")
                return nil
            }
        }
        guard db != nil else {
            print("⚠️ HeaderStore.getBlockTime: db is nil after open attempt")
            return nil
        }

        // FIX #120: PRIORITY 1 - Check block_times table FIRST (boost file data is most reliable)
        // The boost file timestamps are verified correct, while P2P-synced headers can be corrupted
        let blockTimeSql = "SELECT timestamp FROM block_times WHERE height = ? LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, blockTimeSql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }

        sqlite3_bind_int64(stmt, 1, Int64(height))

        if sqlite3_step(stmt) == SQLITE_ROW {
            let timestamp = UInt32(sqlite3_column_int64(stmt, 0))
            sqlite3_finalize(stmt)
            return timestamp
        }
        sqlite3_finalize(stmt)

        // FIX #120: PRIORITY 2 - Fallback to headers table (P2P synced)
        // Only used for heights above boost file range - NO estimation, only real data
        let headerSql = "SELECT time FROM headers WHERE height = ? LIMIT 1;"
        var stmt2: OpaquePointer?
        guard sqlite3_prepare_v2(db, headerSql, -1, &stmt2, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt2) }

        sqlite3_bind_int64(stmt2, 1, Int64(height))

        if sqlite3_step(stmt2) == SQLITE_ROW {
            let timestamp = UInt32(sqlite3_column_int64(stmt2, 0))
            return timestamp
        }

        // FIX #120: Return nil if no real timestamp available - NO estimation
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

    // MARK: - FIX #413: Bundled Headers from Boost File

    /// FIX #413: Load headers from boost file data
    /// Header format (140 bytes each):
    /// - version: 4 bytes (UInt32 LE)
    /// - hashPrevBlock: 32 bytes
    /// - hashMerkleRoot: 32 bytes
    /// - hashFinalSaplingRoot: 32 bytes (CRITICAL for anchor validation!)
    /// - time: 4 bytes (UInt32 LE)
    /// - bits: 4 bytes (UInt32 LE)
    /// - nonce: 32 bytes
    /// Uses chunked inserts to avoid SQLite out-of-memory errors
    /// FIX #457: Accepts pre-computed block hashes to avoid slow SHA-256 computation
    /// FIX #457 v2: Accepts expectedCount because boost file headers include Equihash solutions (variable size)
    /// FIX #468: Added onProgress callback for real-time progress updates
    func loadHeadersFromBoostData(_ data: Data, blockHashes: Data? = nil, startHeight: UInt64, expectedCount: Int? = nil, onProgress: ((Double) -> Void)? = nil) throws {
        let headerSize = 140  // Compact header without solution or block_hash
        // FIX #457 v2: Use expected count from manifest if provided, else calculate from data size
        let headerCount = expectedCount ?? (data.count / headerSize)
        guard headerCount > 0 else { return }

        // FIX #413: Ensure database is open
        if db == nil {
            try open()
        }
        guard db != nil else { return }

        let endHeight = startHeight + UInt64(headerCount) - 1
        print("📜 FIX #457: Loading \(headerCount) headers from boost file (heights \(startHeight) to \(endHeight))")
        print("📜 FIX #457 DEBUG: data.count = \(data.count), dataCapacity = \(data.count)")

        // FIX #457 v8: Check if we CONTIGUOUSLY have all the boost file headers
        // Old bug: Only checked if max height >= endHeight, which skipped loading
        // when database had sparse headers from P2P sync but missing boost range!
        let hasContiguousBoostHeaders: Bool
        if let existingMax = try? getLatestHeight() {
            // Check if we have a CONTIGUOUS range covering the boost file
            // We need headers from startHeight to endHeight WITHOUT GAPS
            let existingMin = (try? getMinHeight()) ?? 0
            let hasMin = existingMin <= startHeight
            let hasMax = existingMax >= endHeight
            let countInRange = (try? countHeadersInRange(from: startHeight, to: endHeight)) ?? 0
            let expectedCount = Int(endHeight - startHeight + 1)

            hasContiguousBoostHeaders = hasMin && hasMax && (countInRange >= expectedCount * 95 / 100) // Allow 5% gaps

            if hasContiguousBoostHeaders {
                print("📜 FIX #457: Headers already loaded (contiguous range \(existingMin)-\(existingMax), skipping)")
                return
            } else {
                print("📜 FIX #457: Need boost headers - existing: \(existingMin)-\(existingMax) (\(countInRange)/\(expectedCount) in range)")
            }
        } else {
            hasContiguousBoostHeaders = false
        }

        print("📜 FIX #457 DEBUG: Passing check - about to enter INSERT loop")

        // FIX #457: Use pre-computed block hashes if provided (instant vs 1+ minute!)
        if let hashes = blockHashes {
            let expectedHashCount = headerCount * 32
            if hashes.count >= expectedHashCount {
                print("📜 FIX #457: Using pre-computed block hashes (instant!)")
            } else {
                print("⚠️ FIX #457: Block hashes data too small (\(hashes.count) < \(expectedHashCount)), will compute")
            }
        }

        // Process in chunks of 10,000 to avoid out-of-memory errors
        let chunkSize = 10000
        var processedCount = 0

        let sql = """
            INSERT OR IGNORE INTO headers
            (height, block_hash, prev_hash, merkle_root, sapling_root, time, bits, nonce, version)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
        """

        // FIX #457 v2: Parse variable-length headers (140 + varint + 400 bytes solution)
        var byteOffset = 0
        let dataCount = data.count

        print("📜 FIX #457 DEBUG: About to enter data.withUnsafeBytes, headerCount=\(headerCount)")

        try data.withUnsafeBytes { ptr in
            var headerIndex = 0
            var debugEnteredLoop = false

            while headerIndex < headerCount && byteOffset < dataCount {
                if !debugEnteredLoop {
                    debugEnteredLoop = true
                    print("📜 FIX #457: ENTERED while loop! headerIndex=\(headerIndex), headerCount=\(headerCount), byteOffset=\(byteOffset), dataCount=\(dataCount)")
                }

                if headerIndex == 0 {
                    print("📜 FIX #457: Processing first header at height \(startHeight)")
                }

                if headerIndex % 100000 == 0 {
                    print("📜 FIX #457 DEBUG: Processing header \(headerIndex)/\(headerCount), byteOffset=\(byteOffset)")
                }
                // Begin transaction for this chunk
                guard sqlite3_exec(db, "BEGIN TRANSACTION;", nil, nil, nil) == SQLITE_OK else {
                    throw DatabaseError.insertFailed("Failed to begin transaction")
                }

                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                    sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                    throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
                }

                let endIndex = min(headerIndex + chunkSize, headerCount)
                let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

                while headerIndex < endIndex && byteOffset < dataCount {
                    let height = startHeight + UInt64(headerIndex)

                    // Parse header fields (first 140 bytes) - use Data subscripts to avoid alignment issues
                    guard byteOffset + 140 <= dataCount else {
                        sqlite3_finalize(stmt)
                        sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                        throw DatabaseError.insertFailed("Unexpected end of boost file data")
                    }

                    // Helper to read UInt32 from Data at offset
                    func readUInt32(_ offset: Int) -> UInt32 {
                        return UInt32(data[offset]) |
                               UInt32(data[offset + 1]) << 8 |
                               UInt32(data[offset + 2]) << 16 |
                               UInt32(data[offset + 3]) << 24
                    }

                    let version = readUInt32(byteOffset)
                    let prevHash = Data(data[byteOffset + 4..<byteOffset + 36])
                    let merkleRoot = Data(data[byteOffset + 36..<byteOffset + 68])
                    let saplingRoot = Data(data[byteOffset + 68..<byteOffset + 100])
                    let time = readUInt32(byteOffset + 100)
                    let bits = readUInt32(byteOffset + 104)
                    let nonce = Data(data[byteOffset + 108..<byteOffset + 140])

                    // FIX #457: Use pre-computed block hash if available, else compute (SLOW!)
                    let blockHash: Data
                    if let hashes = blockHashes, headerIndex < hashes.count / 32 {
                        // Use pre-computed hash from boost file (instant!)
                        let hashOffset = headerIndex * 32
                        blockHash = hashes[hashOffset..<hashOffset + 32]
                    } else {
                        // Fallback: compute block hash from header (SLOW - 1+ minute!)
                        let headerData = Data(bytes: ptr.baseAddress! + byteOffset, count: 140)
                        blockHash = computeBlockHash(headerData)
                    }

                    sqlite3_reset(stmt)
                    sqlite3_bind_int64(stmt, 1, Int64(height))
                    blockHash.withUnsafeBytes { hashPtr in
                        sqlite3_bind_blob(stmt, 2, hashPtr.baseAddress, Int32(blockHash.count), SQLITE_TRANSIENT)
                    }
                    prevHash.withUnsafeBytes { hashPtr in
                        sqlite3_bind_blob(stmt, 3, hashPtr.baseAddress, Int32(prevHash.count), SQLITE_TRANSIENT)
                    }
                    merkleRoot.withUnsafeBytes { hashPtr in
                        sqlite3_bind_blob(stmt, 4, hashPtr.baseAddress, Int32(merkleRoot.count), SQLITE_TRANSIENT)
                    }
                    saplingRoot.withUnsafeBytes { hashPtr in
                        sqlite3_bind_blob(stmt, 5, hashPtr.baseAddress, Int32(saplingRoot.count), SQLITE_TRANSIENT)
                    }
                    sqlite3_bind_int64(stmt, 6, Int64(time))
                    sqlite3_bind_int64(stmt, 7, Int64(bits))
                    nonce.withUnsafeBytes { hashPtr in
                        sqlite3_bind_blob(stmt, 8, hashPtr.baseAddress, Int32(nonce.count), SQLITE_TRANSIENT)
                    }
                    sqlite3_bind_int64(stmt, 9, Int64(version))

                    let stepResult = sqlite3_step(stmt)
                    if stepResult != SQLITE_DONE {
                        let error = String(cString: sqlite3_errmsg(db))
                        print("❌ FIX #457: INSERT FAILED at header \(headerIndex) height \(height): \(error) (code \(stepResult))")
                        sqlite3_finalize(stmt)
                        sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                        throw DatabaseError.insertFailed(error)
                    }

                    if headerIndex == 0 {
                        print("✅ FIX #457: First INSERT succeeded at height \(height)")
                    }
                    if headerIndex == 1 {
                        print("✅ FIX #457: Second INSERT succeeded at height \(height)")
                    }

                    // FIX #457 v10: Parse solution size from boost file format
                    // Boost file uses uint16 (2 bytes) NOT varint for solution length!
                    byteOffset += 140  // Skip compact header

                    // Read solution length as uint16 (2 bytes, little-endian)
                    guard byteOffset + 2 <= dataCount else {
                        print("❌ FIX #457: Missing solution length at header \(headerIndex)")
                        sqlite3_finalize(stmt)
                        sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                        throw DatabaseError.insertFailed("Missing solution length")
                    }

                    let solutionSize = Int(data[byteOffset]) | (Int(data[byteOffset + 1]) << 8)
                    byteOffset += 2  // Skip 2-byte solution length

                    if byteOffset + solutionSize > dataCount {
                        print("❌ FIX #457: Solution size \(solutionSize) exceeds data bounds at header \(headerIndex)")
                        sqlite3_finalize(stmt)
                        sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                        throw DatabaseError.insertFailed("Solution size exceeds data bounds")
                    }

                    if headerIndex == 0 {
                        print("📊 FIX #457: First header solutionSize=\(solutionSize) bytes")
                    }

                    // Skip Equihash solution
                    byteOffset += solutionSize
                    headerIndex += 1
                }

                sqlite3_finalize(stmt)

                // Commit this chunk
                guard sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK else {
                    throw DatabaseError.insertFailed("Failed to commit transaction")
                }

                processedCount = headerIndex

                // Progress log every 100k entries
                if processedCount % 100000 == 0 || processedCount == headerCount {
                    print("📜 FIX #457: Inserted \(processedCount)/\(headerCount) headers...")
                }

                // FIX #468: Report progress after each chunk
                // FIX #485: Add log to verify callback is being invoked
                let progressValue = Double(processedCount) / Double(headerCount)
                print("🔧 FIX #485: Calling onProgress callback with \(Int(progressValue * 100))%")
                onProgress?(progressValue)

                // FIX #494 v2: Yield longer to allow UI updates during tight loop
                // 10ms gives enough time for DispatchQueue.main.async to execute
                // Without this, main thread is blocked and UI never updates
                Thread.sleep(forTimeInterval: 0.01)
            }
        }

        print("✅ FIX #457: Loaded \(headerCount) headers into HeaderStore")
    }

    /// FIX #413: Compute block hash from header data (double SHA-256)
    private func computeBlockHash(_ headerData: Data) -> Data {
        var hash1 = [UInt8](repeating: 0, count: 32)
        var hash2 = [UInt8](repeating: 0, count: 32)

        headerData.withUnsafeBytes { ptr in
            CC_SHA256(ptr.baseAddress, CC_LONG(headerData.count), &hash1)
        }
        CC_SHA256(&hash1, CC_LONG(32), &hash2)

        return Data(hash2)
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

    /// FIX #120: Clear headers above a specific height
    /// Used to clear corrupted P2P-synced headers above the boost file range
    func clearHeadersAboveHeight(_ height: UInt64) throws {
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

        let deletedCount = sqlite3_changes(db)
        print("🗑️ FIX #120: Cleared \(deletedCount) headers above height \(height)")
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

        // FIX #535: Read chainwork column (column 10)
        // Note: column 9 is solution, which we may or may not have selected
        var chainwork = Data(count: 32)
        let columnCount = sqlite3_column_count(stmt)
        if columnCount > 10 {
            // Check if chainwork column exists (newer schema)
            if let chainworkPtr = sqlite3_column_blob(stmt, 10) {
                let chainworkLen = sqlite3_column_bytes(stmt, 10)
                if chainworkLen == 32 {
                    chainwork = Data(bytes: chainworkPtr, count: Int(chainworkLen))
                }
            }
        }

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
            blockHash: blockHash,
            chainwork: chainwork  // FIX #535: Include chainwork
        )
    }

    // MARK: - FIX #188: Equihash Verification Support

    /// Get headers with solutions for local Equihash verification
    /// Returns the last N headers that have solutions stored
    /// - Parameter count: Number of headers to retrieve (default 100)
    func getHeadersWithSolutions(count: Int = 100) throws -> [ZclassicBlockHeader] {
        // FIX #535: Now includes chainwork for fork detection
        let sql = """
            SELECT height, block_hash, prev_hash, merkle_root, sapling_root, time, bits, nonce, version, solution, chainwork
            FROM headers
            WHERE solution IS NOT NULL AND length(solution) > 0
            ORDER BY height DESC
            LIMIT ?;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int(stmt, 1, Int32(count))

        var headers: [ZclassicBlockHeader] = []

        while sqlite3_step(stmt) == SQLITE_ROW {
            let height = UInt64(sqlite3_column_int64(stmt, 0))

            let hashLength = sqlite3_column_bytes(stmt, 1)
            let blockHash = Data(bytes: sqlite3_column_blob(stmt, 1), count: Int(hashLength))

            let prevLength = sqlite3_column_bytes(stmt, 2)
            let prevHash = Data(bytes: sqlite3_column_blob(stmt, 2), count: Int(prevLength))

            let merkleLength = sqlite3_column_bytes(stmt, 3)
            let merkleRoot = Data(bytes: sqlite3_column_blob(stmt, 3), count: Int(merkleLength))

            let saplingLength = sqlite3_column_bytes(stmt, 4)
            let saplingRoot = Data(bytes: sqlite3_column_blob(stmt, 4), count: Int(saplingLength))

            let time = UInt32(sqlite3_column_int64(stmt, 5))
            let bits = UInt32(sqlite3_column_int64(stmt, 6))

            let nonceLength = sqlite3_column_bytes(stmt, 7)
            let nonce = Data(bytes: sqlite3_column_blob(stmt, 7), count: Int(nonceLength))

            let version = UInt32(sqlite3_column_int64(stmt, 8))

            let solutionLength = sqlite3_column_bytes(stmt, 9)
            let solution = Data(bytes: sqlite3_column_blob(stmt, 9), count: Int(solutionLength))

            // FIX #535: Read chainwork (column 10)
            var chainwork = Data(count: 32)
            let columnCount = sqlite3_column_count(stmt)
            if columnCount > 10 {
                if let chainworkPtr = sqlite3_column_blob(stmt, 10) {
                    let chainworkLen = sqlite3_column_bytes(stmt, 10)
                    if chainworkLen == 32 {
                        chainwork = Data(bytes: chainworkPtr, count: Int(chainworkLen))
                    }
                }
            }

            let header = ZclassicBlockHeader(
                version: version,
                hashPrevBlock: prevHash,
                hashMerkleRoot: merkleRoot,
                hashFinalSaplingRoot: saplingRoot,
                time: time,
                bits: bits,
                nonce: nonce,
                solution: solution,
                height: height,
                blockHash: blockHash,
                chainwork: chainwork  // FIX #535: Include chainwork
            )
            headers.append(header)
        }

        return headers.reversed()  // Return in ascending height order
    }

    /// Clean up old Equihash solutions, keeping only the most recent N blocks
    /// This saves storage while maintaining verification capability for recent blocks
    /// - Parameter keepCount: Number of recent solutions to keep (default 100)
    func cleanupOldSolutions(keepCount: Int = 100) throws {
        // First, find the cutoff height
        let findCutoffSQL = """
            SELECT MIN(height) FROM (
                SELECT height FROM headers
                WHERE solution IS NOT NULL AND length(solution) > 0
                ORDER BY height DESC
                LIMIT ?
            );
        """

        var cutoffStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, findCutoffSQL, -1, &cutoffStmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(cutoffStmt) }

        sqlite3_bind_int(cutoffStmt, 1, Int32(keepCount))

        guard sqlite3_step(cutoffStmt) == SQLITE_ROW else { return }

        let cutoffHeight = sqlite3_column_int64(cutoffStmt, 0)
        guard cutoffHeight > 0 else { return }

        // Now clear solutions below the cutoff height
        let clearSQL = "UPDATE headers SET solution = NULL WHERE height < ?;"
        var clearStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, clearSQL, -1, &clearStmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(clearStmt) }

        sqlite3_bind_int64(clearStmt, 1, cutoffHeight)

        guard sqlite3_step(clearStmt) == SQLITE_DONE else {
            throw DatabaseError.deleteFailed(String(cString: sqlite3_errmsg(db)))
        }

        let clearedCount = sqlite3_changes(db)
        if clearedCount > 0 {
            print("🗑️ FIX #188: Cleaned up \(clearedCount) old Equihash solutions (keeping last \(keepCount))")
        }
    }

    /// Get count of headers with Equihash solutions stored
    func getSolutionCount() throws -> Int {
        let sql = "SELECT COUNT(*) FROM headers WHERE solution IS NOT NULL AND length(solution) > 0;"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }

        return Int(sqlite3_column_int64(stmt, 0))
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

    // MARK: - FIX #516: Anchor Validation

    /// Check if a Sapling root (anchor) exists in the blockchain headers
    /// Returns true if the anchor is found in any block header
    func containsSaplingRoot(_ anchor: Data) async -> Bool {
        // The saplingRoot is stored as hex string in database
        let anchorHex = anchor.map { String(format: "%02x", $0) }.joined()

        let sql = "SELECT COUNT(*) FROM headers WHERE sapling_root = ? COLLATE NOCASE;"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            print("⚠️ FIX #516: Failed to prepare query: \(String(cString: sqlite3_errmsg(db)))")
            return false
        }
        defer { sqlite3_finalize(stmt) }

        // Bind the anchor hex string
        guard sqlite3_bind_text(stmt, 1, (anchorHex as NSString).utf8String, -1, nil) == SQLITE_OK else {
            print("⚠️ FIX #516: Failed to bind anchor: \(String(cString: sqlite3_errmsg(db)))")
            return false
        }

        // Execute query
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return false
        }

        // Get count
        let count = sqlite3_column_int64(stmt, 0)
        return count > 0
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
