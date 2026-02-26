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

    // FIX #1253: In-memory cache of delta sapling roots (loaded from delta_sapling_roots.bin at startup).
    // These are finalsaplingroots from post-boost blocks stored in the delta bundle.
    // containsSaplingRoot() checks this Set (O(1)) before falling back to headers table SQL query.
    // FIX H-005: Thread-safe access via rootsLock — was unsynchronized across WalletManager/DeltaCMUManager/callers
    private var _deltaSaplingRoots: Set<Data> = []
    private let rootsLock = NSLock()

    var deltaSaplingRoots: Set<Data> {
        get {
            rootsLock.lock()
            defer { rootsLock.unlock() }
            return _deltaSaplingRoots
        }
        set {
            rootsLock.lock()
            _deltaSaplingRoots = newValue
            rootsLock.unlock()
        }
    }

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

        print("📂 Opening HeaderStore")
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(dbPath, &db, flags, nil) == SQLITE_OK else {
            let errorMsg = db != nil ? String(cString: sqlite3_errmsg(db)) : "Unknown error"
            throw DatabaseError.openFailed(errorMsg)
        }

        // FIX #200: SQLite performance optimizations (same as WalletDatabase)
        // FIX #1449: Disable mmap on iOS — Data Protection + mmap = SIGBUS crash when device locked
        #if os(iOS)
        let mmapPragma = "PRAGMA mmap_size = 0;"           // FIX #1449: No mmap on iOS
        #else
        let mmapPragma = "PRAGMA mmap_size = 134217728;"   // 128MB on macOS
        #endif
        let performancePragmas = [
            "PRAGMA journal_mode = WAL;",
            "PRAGMA synchronous = NORMAL;",
            "PRAGMA cache_size = -16000;",   // 16MB for headers
            mmapPragma,
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
            // FIX #894: Checkpoint WAL before closing to ensure all data is persisted
            checkpoint()
            sqlite3_close(db)
            db = nil
        }
    }

    // MARK: - FIX #894: WAL Checkpoint for Data Persistence

    /// FIX #894: Force WAL checkpoint to persist all data to main database file
    /// CRITICAL: Without this, headers loaded during a session may be lost on app termination
    /// WAL mode is fast for writes but requires explicit checkpoint to ensure durability
    /// Call this after bulk inserts (like loading 2.5M headers from boost file)
    func checkpoint() {
        guard db != nil else { return }

        // PRAGMA wal_checkpoint(TRUNCATE) checkpoints and truncates the WAL file
        // This is the most thorough checkpoint mode - ensures all data is in main DB
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "PRAGMA wal_checkpoint(TRUNCATE);", -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW {
                let busy = sqlite3_column_int(stmt, 0)
                let log = sqlite3_column_int(stmt, 1)
                let checkpointed = sqlite3_column_int(stmt, 2)
                if log > 0 || checkpointed > 0 {
                    print("💾 FIX #894: WAL checkpoint complete - busy:\(busy), log:\(log), checkpointed:\(checkpointed)")
                }
            }
            sqlite3_finalize(stmt)
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
            CREATE INDEX IF NOT EXISTS idx_headers_sapling_root ON headers(sapling_root);
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
    /// Compact format: exponent (byte 3) | mantissa (bytes 0-2)
    /// Formula: target = mantissa * 256^(exponent - 3)
    private func computeWorkFromBits(bits: UInt32) -> Data {
        // Extract exponent (most significant byte) and mantissa (lower 3 bytes)
        let exponent = (bits >> 24) & 0xFF
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
        // FIX #794: Ensure database is open before inserting
        if db == nil {
            try open()
        }
        guard db != nil else { return }

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
        _ = header.blockHash.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, 2, ptr.baseAddress, Int32(header.blockHash.count), SQLITE_TRANSIENT)
        }
        _ = header.hashPrevBlock.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, 3, ptr.baseAddress, Int32(header.hashPrevBlock.count), SQLITE_TRANSIENT)
        }
        _ = header.hashMerkleRoot.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, 4, ptr.baseAddress, Int32(header.hashMerkleRoot.count), SQLITE_TRANSIENT)
        }
        _ = header.hashFinalSaplingRoot.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, 5, ptr.baseAddress, Int32(header.hashFinalSaplingRoot.count), SQLITE_TRANSIENT)
        }
        sqlite3_bind_int64(stmt, 6, Int64(header.time))
        sqlite3_bind_int64(stmt, 7, Int64(header.bits))
        _ = header.nonce.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, 8, ptr.baseAddress, Int32(header.nonce.count), SQLITE_TRANSIENT)
        }
        sqlite3_bind_int64(stmt, 9, Int64(header.version))
        // FIX #188: Store solution for Equihash verification
        if !header.solution.isEmpty {
            _ = header.solution.withUnsafeBytes { ptr in
                sqlite3_bind_blob(stmt, 10, ptr.baseAddress, Int32(header.solution.count), SQLITE_TRANSIENT)
            }
        } else {
            sqlite3_bind_null(stmt, 10)
        }
        // FIX #535: Store chainwork for fork detection
        _ = chainwork.withUnsafeBytes { ptr in
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

        // FIX #794: Ensure database is open before inserting
        if db == nil {
            try open()
        }
        guard db != nil else { return }

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
                _ = header.blockHash.withUnsafeBytes { ptr in
                    sqlite3_bind_blob(stmt, 2, ptr.baseAddress, Int32(header.blockHash.count), SQLITE_TRANSIENT)
                }
                _ = header.hashPrevBlock.withUnsafeBytes { ptr in
                    sqlite3_bind_blob(stmt, 3, ptr.baseAddress, Int32(header.hashPrevBlock.count), SQLITE_TRANSIENT)
                }
                _ = header.hashMerkleRoot.withUnsafeBytes { ptr in
                    sqlite3_bind_blob(stmt, 4, ptr.baseAddress, Int32(header.hashMerkleRoot.count), SQLITE_TRANSIENT)
                }
                _ = header.hashFinalSaplingRoot.withUnsafeBytes { ptr in
                    sqlite3_bind_blob(stmt, 5, ptr.baseAddress, Int32(header.hashFinalSaplingRoot.count), SQLITE_TRANSIENT)
                }
                sqlite3_bind_int64(stmt, 6, Int64(header.time))
                sqlite3_bind_int64(stmt, 7, Int64(header.bits))
                _ = header.nonce.withUnsafeBytes { ptr in
                    sqlite3_bind_blob(stmt, 8, ptr.baseAddress, Int32(header.nonce.count), SQLITE_TRANSIENT)
                }
                sqlite3_bind_int64(stmt, 9, Int64(header.version))
                // FIX #188: Store solution for Equihash verification
                if !header.solution.isEmpty {
                    _ = header.solution.withUnsafeBytes { ptr in
                        sqlite3_bind_blob(stmt, 10, ptr.baseAddress, Int32(header.solution.count), SQLITE_TRANSIENT)
                    }
                } else {
                    sqlite3_bind_null(stmt, 10)
                }
                // FIX #535: Compute and store chainwork for fork detection
                let chainwork = try computeChainWork(for: header)
                _ = chainwork.withUnsafeBytes { ptr in
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
        // FIX #794: Ensure database is open before querying
        if db == nil {
            try open()
        }
        guard db != nil else { return nil }

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
        // FIX #794: Ensure database is open before querying
        if db == nil {
            try open()
        }
        guard db != nil else { return nil }

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
        _ = hash.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, 1, ptr.baseAddress, Int32(hash.count), SQLITE_TRANSIENT)
        }

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return nil
        }

        return try parseHeaderFromRow(stmt!)
    }

    /// FIX #1287: Batch fetch block hashes for a height range in a single SQL query.
    /// Replaces per-block getHeader(at:) calls that each do full SELECT with 11 columns
    /// (128 individual queries with 400-byte solution blob parsing → 1 query returning only hashes).
    func getBlockHashesInRange(from startHeight: UInt64, count: Int) throws -> [UInt64: Data] {
        if db == nil { try open() }
        guard db != nil else { return [:] }

        let endHeight = startHeight + UInt64(count) - 1
        let sql = "SELECT height, block_hash FROM headers WHERE height >= ? AND height <= ?;"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, Int64(startHeight))
        sqlite3_bind_int64(stmt, 2, Int64(endHeight))

        var result: [UInt64: Data] = [:]
        result.reserveCapacity(count)

        while sqlite3_step(stmt) == SQLITE_ROW {
            let height = UInt64(sqlite3_column_int64(stmt, 0))
            if let blobPtr = sqlite3_column_blob(stmt, 1) {
                let blobLen = Int(sqlite3_column_bytes(stmt, 1))
                let hash = Data(bytes: blobPtr, count: blobLen)
                result[height] = hash
            }
        }

        return result
    }

    /// Get anchor (finalsaplingroot) for a specific height
    /// This is the critical method for transaction building!
    func getAnchor(at height: UInt64) throws -> Data? {
        // FIX #794: Ensure database is open before querying
        if db == nil {
            try open()
        }
        guard db != nil else { return nil }

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
        // FIX #794: Ensure database is open before querying (prevents "out of memory" error when db is nil)
        if db == nil {
            try open()
        }
        guard db != nil else { return nil }

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
        // FIX #794: Ensure database is open before querying
        if db == nil {
            try open()
        }
        guard db != nil else { return nil }

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
        // FIX #794: Ensure database is open before querying
        if db == nil {
            try open()
        }
        guard db != nil else { return 0 }

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
        // FIX #794: Ensure database is open before querying
        if db == nil {
            try open()
        }
        guard db != nil else { return 0 }

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
        // FIX #794: Ensure database is open before querying
        if db == nil {
            try open()
        }
        guard db != nil else { return [] }

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

    /// FIX #546: Get sapling root (anchor) for a specific block height
    /// This returns the canonical anchor from the blockchain header for trustless transaction building
    /// According to SESSION_SUMMARY_2025-11-28.md: "Anchor MUST come from header store - not from computed tree state"
    func getSaplingRoot(at height: UInt64) throws -> Data? {
        // Ensure database is open
        if db == nil {
            try open()
        }

        let sql = "SELECT sapling_root FROM headers WHERE height = ? LIMIT 1;"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, Int64(height))

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            // No header found at this height
            return nil
        }

        guard let saplingRootPtr = sqlite3_column_blob(stmt, 0) else {
            return nil
        }
        let saplingRootLength = sqlite3_column_bytes(stmt, 0)
        let saplingRoot = Data(bytes: saplingRootPtr, count: Int(saplingRootLength))

        return saplingRoot
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

    // MARK: - FIX #536: Header Corruption Detection

    /// Result of sapling_root corruption check
    struct CorruptionCheckResult {
        let isCorrupted: Bool
        let sampledCount: Int
        let uniqueRoots: Int
    }

    /// Check if headers have corrupted sapling_roots (duplicated values)
    /// Samples every Nth header to detect corruption without full scan
    /// Returns CorruptionCheckResult with isCorrupted=true if duplicates found
    func checkSaplingRootCorruptionInRange(_ startHeight: UInt64, _ endHeight: UInt64) throws -> CorruptionCheckResult {
        // FIX #794: Ensure database is open before querying
        if db == nil {
            try open()
        }
        guard db != nil else {
            return CorruptionCheckResult(isCorrupted: false, sampledCount: 0, uniqueRoots: 0)
        }

        // Sample every 1000th header for efficiency (still catches massive corruption)
        let step = max(1000, Int((endHeight - startHeight) / 1000))

        let sql = "SELECT DISTINCT sapling_root FROM headers WHERE height >= ? AND height <= ? AND height % ? = 0;"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_bind_int64(stmt, 1, Int64(startHeight)) == SQLITE_OK &&
              sqlite3_bind_int64(stmt, 2, Int64(endHeight)) == SQLITE_OK &&
              sqlite3_bind_int64(stmt, 3, Int64(step)) == SQLITE_OK else {
            throw DatabaseError.prepareFailed("Failed to bind parameters")
        }

        var uniqueRoots = 0
        while sqlite3_step(stmt) == SQLITE_ROW {
            uniqueRoots += 1
        }

        // Calculate expected sample count
        let rangeSize = Int(endHeight - startHeight + 1)
        let sampledCount = (rangeSize + step - 1) / step  // Ceiling division

        // If we have significantly fewer unique roots than sampled, corruption exists
        // Allow 5% tolerance for edge cases
        let expectedUnique = sampledCount
        let isCorrupted = uniqueRoots < expectedUnique * 95 / 100

        return CorruptionCheckResult(
            isCorrupted: isCorrupted,
            sampledCount: sampledCount,
            uniqueRoots: uniqueRoots
        )
    }

    /// Delete all headers in a specific height range
    /// FIX #944: CRITICAL - Fixed parameter binding bug! sqlite3_exec does NOT bind parameters.
    /// The old code passed "?" placeholders literally, which SQLite treated as NULL.
    /// Result: DELETE WHERE height >= NULL AND height <= NULL = deletes NOTHING!
    /// This caused infinite chain mismatch loops during Import PK.
    func deleteHeadersInRange(from: UInt64, to: UInt64) throws {
        // FIX #794: Ensure database is open before deleting
        if db == nil {
            try open()
        }
        guard db != nil else { return }

        let sql = "DELETE FROM headers WHERE height >= ? AND height <= ?;"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        // FIX #944: Properly bind the from and to height parameters
        sqlite3_bind_int64(stmt, 1, Int64(from))
        sqlite3_bind_int64(stmt, 2, Int64(to))

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.deleteFailed(String(cString: sqlite3_errmsg(db)))
        }

        let deletedCount = sqlite3_changes(db)
        print("🗑️ FIX #944: Deleted \(deletedCount) headers in range \(from)-\(to)")
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
        //
        // FIX #536: Check for HEADER CORRUPTION (duplicated sapling_roots) before skipping load
        // If headers are corrupted, force reload even if contiguous range exists
        //
        // FIX #777: CRITICAL - Require 100% of boost headers, not 95%
        // Old bug: P2P-synced headers with gaps passed 95% check, boost file never loaded
        // Result: App synced from scratch via P2P instead of using boost file (fast) + delta (small)
        // Root cause: Previous P2P sync left partial headers, countInRange found enough to pass 95%
        // Solution: Require EXACTLY 100% of boost headers. If any are missing, delete all and reload.
        let hasContiguousBoostHeaders: Bool
        if let existingMax = try? getLatestHeight() {
            // Check if we have a CONTIGUOUS range covering the boost file
            // We need headers from startHeight to endHeight WITHOUT GAPS
            let existingMin = (try? getMinHeight()) ?? 0
            let hasMin = existingMin <= startHeight
            let hasMax = existingMax >= endHeight
            let countInRange = (try? countHeadersInRange(from: startHeight, to: endHeight)) ?? 0
            let expectedCount = Int(endHeight - startHeight + 1)

            // FIX #536: Check for corruption (duplicated sapling_roots)
            // Sample 1000 headers in the boost range - if many have duplicate sapling_roots, headers are corrupted
            var hasCorruption = false
            // FIX #777: Only check corruption if we have 100% of headers (not 95%)
            if hasMin && hasMax && countInRange == expectedCount {
                // Quick corruption check: count unique sapling_roots vs total headers
                let corruptionCheck = try? checkSaplingRootCorruptionInRange(startHeight, endHeight)
                if let check = corruptionCheck, check.isCorrupted {
                    print("🚨 FIX #536: CRITICAL - HeaderStore has CORRUPTED sapling_roots!")
                    print("🚨 FIX #536: Sample: \(check.sampledCount) headers, only \(check.uniqueRoots) unique sapling_roots")
                    print("🚨 FIX #536: Expected ~\(check.sampledCount) unique, but found duplicates - FORCING RELOAD")
                    hasCorruption = true
                }

                // FIX #809: Check for hash byte order corruption
                // If blockHash is in wrong byte order (big-endian instead of little-endian), force reload
                // Test by comparing stored hash at a checkpoint height vs expected checkpoint hash
                if !hasCorruption, let blockHashes = blockHashes {
                    // Use Sapling activation checkpoint (476969) as reference - guaranteed to be in boost range
                    let testHeight: UInt64 = 476969
                    if testHeight >= startHeight && testHeight <= endHeight,
                       let checkpointHex = ZclassicCheckpoints.mainnet[testHeight],
                       let checkpointHash = Data(hexString: checkpointHex) {
                        // Checkpoint is in big-endian (display format)
                        // For HeaderStore (wire format), we need little-endian = reversed checkpoint
                        let expectedWireHash = Data(checkpointHash.reversed())

                        if let storedHeader = try? getHeader(at: testHeight) {
                            if storedHeader.blockHash != expectedWireHash {
                                // Check if it matches the unreversed checkpoint (wrong byte order)
                                if storedHeader.blockHash == checkpointHash {
                                    print("🚨 FIX #809: CRITICAL - HeaderStore has wrong byte order (big-endian instead of wire format)!")
                                    print("🚨 FIX #809: At height \(testHeight): stored=\(storedHeader.blockHash.prefix(8).map { String(format: "%02x", $0) }.joined())..., expected=\(expectedWireHash.prefix(8).map { String(format: "%02x", $0) }.joined())...")
                                    print("🚨 FIX #809: This was caused by boost file loading without byte reversal - FORCING RELOAD")
                                    hasCorruption = true
                                }
                            }
                        }
                    }
                }
            }

            // FIX #777: Require 100% of boost headers - any gap means we need to reload
            hasContiguousBoostHeaders = hasMin && hasMax && (countInRange == expectedCount) && !hasCorruption

            if hasContiguousBoostHeaders {
                print("📜 FIX #457: Headers already loaded (contiguous range \(existingMin)-\(existingMax), skipping)")
                return
            } else if hasCorruption {
                print("📜 FIX #536: Corrupted headers detected - will reload from boost file")
                // Delete corrupted headers before reload
                if let minH = try? getMinHeight(), let maxH = try? getLatestHeight() {
                    print("🗑️ FIX #536: Deleting corrupted headers from height \(minH) to \(maxH)...")
                    try? deleteHeadersInRange(from: minH, to: maxH)
                }
            } else {
                // FIX #777: If we have partial headers in boost range, delete them and reload
                // Boost file provides complete verified headers - no reason to keep partial P2P headers
                let hasPartialHeaders = countInRange > 0 && countInRange < expectedCount
                if hasPartialHeaders {
                    print("🚨 FIX #777: CRITICAL - Partial headers detected in boost range!")
                    print("🚨 FIX #777: Have \(countInRange)/\(expectedCount) headers - missing \(expectedCount - countInRange)")
                    print("🚨 FIX #777: Deleting all headers to reload complete boost file...")
                    if let minH = try? getMinHeight(), let maxH = try? getLatestHeight() {
                        try? deleteHeadersInRange(from: minH, to: maxH)
                        print("🗑️ FIX #777: Deleted headers from height \(minH) to \(maxH)")
                    }
                } else {
                    print("📜 FIX #457: Need boost headers - existing: \(existingMin)-\(existingMax) (\(countInRange)/\(expectedCount) in range)")
                }
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

        // FIX #812: PERFORMANCE OPTIMIZATION - Target: < 20 seconds for 2.5M headers
        // Previous: ~100+ seconds due to per-header allocations and per-chunk transactions
        // Optimizations:
        // 1. Direct pointer arithmetic instead of Data subscript allocations
        // 2. Pre-allocated buffer for reversed hashes (reused each iteration)
        // 3. SQLITE_STATIC for pointer binds (data valid during sqlite3_step)
        //
        // FIX #948: CRITICAL - Commit every 100K headers to prevent SQLite slowdown
        // Problem: Single transaction for 2.5M headers caused:
        //   - WAL file grew to 700MB+ causing B-tree rebalancing overhead
        //   - Insert rate dropped from 81K/sec to 1.7K/sec (50x slowdown!)
        //   - Total time: 25+ minutes instead of ~30 seconds
        // Solution: Commit in batches of 100K headers to:
        //   - Keep WAL size manageable (~30MB per batch)
        //   - Allow SQLite to checkpoint periodically
        //   - Maintain consistent ~60K/sec insert rate throughout

        var processedCount = 0
        let startTime = CFAbsoluteTimeGetCurrent()
        let batchSize = 100000  // FIX #948: Commit every 100K headers

        let sql = """
            INSERT OR REPLACE INTO headers
            (height, block_hash, prev_hash, merkle_root, sapling_root, time, bits, nonce, version)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
        """

        var byteOffset = 0
        let dataCount = data.count

        print("📜 FIX #812/948: Starting optimized header load for \(headerCount) headers (batch size: \(batchSize))")

        // FIX #948: Start first transaction
        guard sqlite3_exec(db, "BEGIN TRANSACTION;", nil, nil, nil) == SQLITE_OK else {
            throw DatabaseError.insertFailed("Failed to begin transaction")
        }

        // FIX #812: Prepare statement ONCE for all headers
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }

        // FIX #812: Pre-allocate buffer for reversed hash (reused for each header)
        var reversedHashBuffer = [UInt8](repeating: 0, count: 32)
        var headersInCurrentBatch = 0  // FIX #948: Track headers in current batch

        // FIX #812: Inner processing function to avoid nested optional closures
        func processHeaders(dataPtr: UnsafeRawBufferPointer, hashesPtr: UnsafeRawBufferPointer?) throws {
            let basePtr = dataPtr.baseAddress!.assumingMemoryBound(to: UInt8.self)
            let hashesBasePtr = hashesPtr?.baseAddress?.assumingMemoryBound(to: UInt8.self)
            let hashesCount = hashesPtr?.count ?? 0

            var headerIndex = 0
            var currentOffset = byteOffset

            while headerIndex < headerCount && currentOffset < dataCount {
                guard currentOffset + 140 <= dataCount else {
                    throw DatabaseError.insertFailed("Unexpected end of boost file data at header \(headerIndex)")
                }

                let height = startHeight + UInt64(headerIndex)
                let headerPtr = basePtr + currentOffset

                // FIX #812: Direct pointer reads - no Data allocations!
                let version = UInt32(headerPtr[0]) | UInt32(headerPtr[1]) << 8 | UInt32(headerPtr[2]) << 16 | UInt32(headerPtr[3]) << 24
                let time = UInt32(headerPtr[100]) | UInt32(headerPtr[101]) << 8 | UInt32(headerPtr[102]) << 16 | UInt32(headerPtr[103]) << 24
                let bits = UInt32(headerPtr[104]) | UInt32(headerPtr[105]) << 8 | UInt32(headerPtr[106]) << 16 | UInt32(headerPtr[107]) << 24

                // Pointers to 32-byte fields (no copy needed)
                let prevHashPtr = headerPtr + 4
                let merkleRootPtr = headerPtr + 36
                let saplingRootPtr = headerPtr + 68
                let noncePtr = headerPtr + 108

                // FIX #812: Block hash with minimal allocation
                if let hashesBase = hashesBasePtr, headerIndex < hashesCount / 32 {
                    // FIX #809: Reverse bytes in-place to reusable buffer
                    let srcPtr = hashesBase + (headerIndex * 32)
                    for i in 0..<32 {
                        reversedHashBuffer[31 - i] = srcPtr[i]
                    }
                } else {
                    // Fallback: compute hash (SLOW but rare path)
                    let headerData = Data(bytes: headerPtr, count: 140)
                    let computedHash = computeBlockHash(headerData)
                    computedHash.withUnsafeBytes { ptr in
                        ptr.copyBytes(to: UnsafeMutableBufferPointer(start: &reversedHashBuffer, count: 32))
                    }
                }

                // FIX #812: Bind and execute within same scope where buffer pointers are valid
                sqlite3_reset(stmt)
                sqlite3_bind_int64(stmt, 1, Int64(height))

                // Must bind and step while reversedHashBuffer pointer is valid
                let stepResult: Int32 = reversedHashBuffer.withUnsafeBufferPointer { hashBufPtr in
                    sqlite3_bind_blob(stmt, 2, hashBufPtr.baseAddress, 32, nil)
                    sqlite3_bind_blob(stmt, 3, prevHashPtr, 32, nil)
                    sqlite3_bind_blob(stmt, 4, merkleRootPtr, 32, nil)
                    sqlite3_bind_blob(stmt, 5, saplingRootPtr, 32, nil)
                    sqlite3_bind_int64(stmt, 6, Int64(time))
                    sqlite3_bind_int64(stmt, 7, Int64(bits))
                    sqlite3_bind_blob(stmt, 8, noncePtr, 32, nil)
                    sqlite3_bind_int64(stmt, 9, Int64(version))
                    return sqlite3_step(stmt)
                }
                if stepResult != SQLITE_DONE {
                    let error = String(cString: sqlite3_errmsg(db))
                    throw DatabaseError.insertFailed("INSERT FAILED at header \(headerIndex): \(error)")
                }

                // Skip to next header: 140 bytes header + 2 bytes solution length + solution
                currentOffset += 140
                guard currentOffset + 2 <= dataCount else {
                    throw DatabaseError.insertFailed("Missing solution length at header \(headerIndex)")
                }
                let solutionSize = Int(basePtr[currentOffset]) | (Int(basePtr[currentOffset + 1]) << 8)
                currentOffset += 2 + solutionSize

                headerIndex += 1
                headersInCurrentBatch += 1

                // FIX #948: Commit every batchSize headers to prevent WAL bloat and slowdown
                if headersInCurrentBatch >= batchSize {
                    // Commit current batch
                    guard sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK else {
                        throw DatabaseError.insertFailed("Failed to commit batch at header \(headerIndex)")
                    }

                    // Start new transaction immediately
                    guard sqlite3_exec(db, "BEGIN TRANSACTION;", nil, nil, nil) == SQLITE_OK else {
                        throw DatabaseError.insertFailed("Failed to begin new batch at header \(headerIndex)")
                    }

                    headersInCurrentBatch = 0

                    // Log progress with current rate
                    processedCount = headerIndex
                    let elapsed = CFAbsoluteTimeGetCurrent() - startTime
                    let rate = Double(headerIndex) / elapsed
                    print("📜 FIX #948: \(processedCount)/\(headerCount) headers (\(Int(rate))/sec) - batch committed")
                    onProgress?(Double(processedCount) / Double(headerCount))
                }
            }

            processedCount = headerIndex
            byteOffset = currentOffset
        }

        do {
            // FIX #812: Use withUnsafeBytes properly for both data sources
            try data.withUnsafeBytes { dataPtr in
                if let hashes = blockHashes {
                    try hashes.withUnsafeBytes { hashesPtr in
                        try processHeaders(dataPtr: dataPtr, hashesPtr: hashesPtr)
                    }
                } else {
                    try processHeaders(dataPtr: dataPtr, hashesPtr: nil)
                }
            }

            sqlite3_finalize(stmt)

            // FIX #948: Commit final batch (any remaining headers after last 100K batch)
            guard sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK else {
                throw DatabaseError.insertFailed("Failed to commit final batch")
            }

            // FIX #894: CRITICAL - Checkpoint WAL immediately after bulk header insert
            // Without this, headers could be lost on app termination
            // WAL checkpoint ensures all data is written to main database file
            checkpoint()

            let totalTime = CFAbsoluteTimeGetCurrent() - startTime
            let rate = Double(headerCount) / totalTime
            print("✅ FIX #812/948: Loaded \(headerCount) headers in \(String(format: "%.1f", totalTime))s (\(Int(rate)) headers/sec)")
            onProgress?(1.0)

        } catch {
            sqlite3_finalize(stmt)
            sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            throw error
        }
    }

    /// FIX #413: Compute block hash from header data (double SHA-256)
    private func computeBlockHash(_ headerData: Data) -> Data {
        var hash1 = [UInt8](repeating: 0, count: 32)
        var hash2 = [UInt8](repeating: 0, count: 32)

        _ = headerData.withUnsafeBytes { ptr in
            CC_SHA256(ptr.baseAddress, CC_LONG(headerData.count), &hash1)
        }
        CC_SHA256(&hash1, CC_LONG(32), &hash2)

        return Data(hash2)
    }

    /// Check if header exists at height
    func hasHeader(at height: UInt64) throws -> Bool {
        // FIX #794: Ensure database is open before querying
        if db == nil {
            try open()
        }
        guard db != nil else { return false }

        let sql = "SELECT 1 FROM headers WHERE height = ? LIMIT 1;"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, Int64(height))

        return sqlite3_step(stmt) == SQLITE_ROW
    }

    /// FIX #1560: Get solution size for a header at a specific height
    /// Used to verify Equihash variant (1344 = pre-Bubbles Equihash(200,9), 400 = post-Bubbles Equihash(192,7))
    /// Returns 0 if no solution stored or header not found.
    func getSolutionSize(at height: UInt64) throws -> Int {
        if db == nil {
            try open()
        }
        guard db != nil else { return 0 }

        let sql = "SELECT length(solution) FROM headers WHERE height = ? AND solution IS NOT NULL;"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, Int64(height))

        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    /// Delete headers above a certain height (for reorg handling)
    func deleteHeadersAbove(height: UInt64) throws {
        // FIX #794: Ensure database is open before deleting
        if db == nil {
            try open()
        }
        guard db != nil else { return }

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
        // FIX #794: Ensure database is open before deleting
        if db == nil {
            try open()
        }
        guard db != nil else { return }

        let sql = "DELETE FROM headers;"

        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw DatabaseError.deleteFailed(String(cString: sqlite3_errmsg(db)))
        }

        print("🗑️ Cleared all headers")
    }

    /// FIX #677 v2: Mark boost headers as corrupted (flag only, no deletion)
    /// Called when chain mismatch detected - sets flag to skip boost file on next startup
    /// NOTE: Header deletion is handled separately by the caller via deleteHeadersInRange()
    /// DO NOT delete all headers here - that causes infinite P2P resync loop!
    func markBoostHeadersCorrupted(mismatchHeight: UInt64) {
        print("⚠️ FIX #677 v2: Chain mismatch at height \(mismatchHeight) - setting boost corruption flag")
        // FIX #766: ONLY set flag, do NOT delete all headers
        // Header deletion is done separately by the caller
        UserDefaults.standard.set(true, forKey: "HeaderStore.boostHeadersCorrupted")
        print("✅ FIX #677 v2: Corruption flag set - boost file will be skipped on next startup")
    }

    /// FIX #675: Check if boost headers should be skipped due to corruption
    /// Returns true if boost headers were previously marked as corrupted
    func shouldSkipBoostHeaders() -> Bool {
        return UserDefaults.standard.bool(forKey: "HeaderStore.boostHeadersCorrupted")
    }

    /// FIX #675: Clear the boost headers corruption flag (after successful P2P sync)
    func clearBoostHeadersCorruptionFlag() {
        UserDefaults.standard.removeObject(forKey: "HeaderStore.boostHeadersCorrupted")
        print("✅ FIX #675: Cleared boost headers corruption flag")
    }

    /// FIX #701: Get the end height of boost file headers loaded in database
    /// Returns the max height from headers table, or 0 if no headers exist
    var boostFileEndHeight: UInt64 {
        do {
            return try getLatestHeight() ?? 0
        } catch {
            print("⚠️ HeaderStore.boostFileEndHeight: Error getting latest height: \(error)")
            return 0
        }
    }

    /// FIX #698: Get the range of heights that have zero sapling roots
    /// Returns (minHeight, maxHeight) tuple or nil if no zero roots found
    /// FIX #797: Only checks POST-Sapling blocks (>= 476969) - pre-Sapling blocks have zero roots by design
    func getZeroSaplingRootRange() throws -> (UInt64, UInt64)? {
        // Ensure database is open
        if db == nil {
            try open()
        }
        guard db != nil else { return nil }

        // Zero sapling root is 32 bytes of zeros
        let zeroRoot = Data(repeating: 0, count: 32)

        // FIX #797: Sapling activation height - blocks before this have zero sapling roots BY DESIGN
        let saplingActivationHeight: UInt64 = 476_969

        // FIX #797: Only check POST-Sapling blocks - pre-Sapling blocks have zero roots and that's correct!
        let sql = "SELECT MIN(height), MAX(height) FROM headers WHERE sapling_root = ? AND height >= ?;"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = zeroRoot.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, 1, ptr.baseAddress, Int32(zeroRoot.count), SQLITE_TRANSIENT)
        }
        // FIX #797: Bind the sapling activation height
        sqlite3_bind_int64(stmt, 2, Int64(saplingActivationHeight))

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return nil
        }

        // Check if MIN/MAX returned NULL (no matching rows)
        if sqlite3_column_type(stmt, 0) == SQLITE_NULL {
            return nil
        }

        let minHeight = UInt64(sqlite3_column_int64(stmt, 0))
        let maxHeight = UInt64(sqlite3_column_int64(stmt, 1))

        return (minHeight, maxHeight)
    }

    /// FIX #698: Get list of heights with zero sapling roots
    /// FIX #797: Only checks POST-Sapling blocks (>= 476969) - pre-Sapling have zero roots by design
    func getHeightsWithZeroSaplingRoots() throws -> [UInt64] {
        // Ensure database is open
        if db == nil {
            try open()
        }
        guard db != nil else { return [] }

        let zeroRoot = Data(repeating: 0, count: 32)

        // FIX #797: Sapling activation height - blocks before this have zero sapling roots BY DESIGN
        let saplingActivationHeight: UInt64 = 476_969

        // FIX #797: Only check POST-Sapling blocks
        let sql = "SELECT height FROM headers WHERE sapling_root = ? AND height >= ? ORDER BY height ASC;"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = zeroRoot.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, 1, ptr.baseAddress, Int32(zeroRoot.count), SQLITE_TRANSIENT)
        }
        // FIX #797: Bind the sapling activation height
        sqlite3_bind_int64(stmt, 2, Int64(saplingActivationHeight))

        var heights: [UInt64] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            heights.append(UInt64(sqlite3_column_int64(stmt, 0)))
        }

        return heights
    }

    /// FIX #698: Update sapling roots for multiple headers
    /// roots: Dictionary mapping height -> sapling root data
    func updateSaplingRoots(_ roots: [UInt64: Data]) throws {
        guard !roots.isEmpty else { return }

        // Ensure database is open
        if db == nil {
            try open()
        }
        guard db != nil else { return }

        guard sqlite3_exec(db, "BEGIN TRANSACTION;", nil, nil, nil) == SQLITE_OK else {
            throw DatabaseError.insertFailed("Failed to begin transaction")
        }

        let sql = "UPDATE headers SET sapling_root = ? WHERE height = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        do {
            for (height, saplingRoot) in roots {
                sqlite3_reset(stmt)

                _ = saplingRoot.withUnsafeBytes { ptr in
                    sqlite3_bind_blob(stmt, 1, ptr.baseAddress, Int32(saplingRoot.count), SQLITE_TRANSIENT)
                }
                sqlite3_bind_int64(stmt, 2, Int64(height))

                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    throw DatabaseError.insertFailed(String(cString: sqlite3_errmsg(db)))
                }
            }

            sqlite3_finalize(stmt)

            guard sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK else {
                throw DatabaseError.insertFailed("Failed to commit transaction")
            }

            print("✅ FIX #698: Updated \(roots.count) sapling roots in HeaderStore")
        } catch {
            sqlite3_finalize(stmt)
            sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            throw error
        }
    }

    /// FIX #1156: Update or insert sapling root for a single height
    /// Used when on-demand P2P block fetch provides sapling root but header sync failed
    /// This ensures getSaplingRoot() works for notes discovered via on-demand fallback
    func updateSaplingRoot(at height: UInt64, root: Data, timestamp: UInt32) throws {
        // Ensure database is open
        if db == nil {
            try open()
        }
        guard db != nil else { return }

        // First try UPDATE (if header exists but sapling root is null/zero)
        let updateSql = "UPDATE headers SET sapling_root = ?, time = ? WHERE height = ? AND (sapling_root IS NULL OR length(sapling_root) = 0);"
        var updateStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, updateSql, -1, &updateStmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(updateStmt) }

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        _ = root.withUnsafeBytes { ptr in
            sqlite3_bind_blob(updateStmt, 1, ptr.baseAddress, Int32(root.count), SQLITE_TRANSIENT)
        }
        sqlite3_bind_int64(updateStmt, 2, Int64(timestamp))
        sqlite3_bind_int64(updateStmt, 3, Int64(height))

        guard sqlite3_step(updateStmt) == SQLITE_DONE else {
            throw DatabaseError.updateFailed(String(cString: sqlite3_errmsg(db)))
        }

        // FIX #1163: If no rows updated, header doesn't exist - DO NOT insert minimal header!
        // Previously inserted minimal headers with garbage block_hash = X'00' which broke
        // getheaders locator (peers rejected our requests with unrecognized hash).
        // Better to let header sync fill in proper headers later.
        if sqlite3_changes(db) == 0 {
            // Check if header already has a sapling root (skip if it does)
            if let existingRoot = try? getSaplingRoot(at: height), !existingRoot.isEmpty {
                return // Already has a valid sapling root
            }

            // FIX #1163: Don't insert minimal header - it corrupts HeaderStore for getheaders
            // FIX #1253: Roots are now saved to delta_sapling_roots.bin via DeltaCMUManager
            // during P2P block fetches. containsSaplingRoot() checks in-memory cache loaded
            // from that file at startup. No separate table needed.
        }
    }

    /// FIX #120: Clear headers above a specific height
    /// Used to clear corrupted P2P-synced headers above the boost file range
    func clearHeadersAboveHeight(_ height: UInt64) throws {
        // FIX #794: Ensure database is open before deleting
        if db == nil {
            try open()
        }
        guard db != nil else { return }

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
        // FIX #794: Ensure database is open before querying
        if db == nil {
            try open()
        }
        guard db != nil else { return [] }

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
        // FIX #794: Ensure database is open before querying
        if db == nil {
            try open()
        }
        guard db != nil else { return }

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
        // FIX #794: Ensure database is open before querying
        if db == nil {
            try open()
        }
        guard db != nil else { return 0 }

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
    /// FIX #536: Bind as BLOB instead of TEXT (sapling_root is BLOB column)
    /// FIX #1230: Check BOTH original and reversed byte order. HeaderStore stores
    /// finalsaplingroot in wire format (raw bytes from block header offset 68-100).
    /// FFI treeRoot()/witnessGetRoot() return roots in zcash_primitives canonical
    /// serialization which is REVERSED byte order. Without checking both, FIX #1224
    /// anchor validation always fails for FFI-produced anchors → false "corrupted witness"
    /// at startup and false anchorNotOnChain rejections in TransactionBuilder.
    func containsSaplingRoot(_ anchor: Data) async -> Bool {
        // FIX #1230: Check both the original anchor bytes AND reversed byte order
        // to handle wire format (HeaderStore) vs canonical format (FFI) mismatch
        let reversed = Data(anchor.reversed())

        // FIX #1253: Check in-memory delta sapling roots FIRST (O(1) Set lookup).
        // These are loaded from delta_sapling_roots.bin at startup — covers post-boost
        // heights where header sync may not have created full header rows yet.
        if deltaSaplingRoots.contains(anchor) || deltaSaplingRoots.contains(reversed) {
            return true
        }

        // Fall back to headers table SQL query (covers boost range + header-synced heights)
        let sql = "SELECT COUNT(*) FROM headers WHERE sapling_root = ? OR sapling_root = ?;"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            print("⚠️ FIX #516: Failed to prepare query: \(String(cString: sqlite3_errmsg(db)))")
            return false
        }
        defer { sqlite3_finalize(stmt) }

        // FIX #536: Bind as BLOB (not TEXT) - sapling_root is stored as BLOB
        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        // Bind original anchor bytes (parameter 1)
        let bindResult1 = anchor.withUnsafeBytes { bytes in
            sqlite3_bind_blob(stmt, 1, bytes.baseAddress, Int32(anchor.count), SQLITE_TRANSIENT)
        }
        guard bindResult1 == SQLITE_OK else {
            print("⚠️ FIX #1230: Failed to bind anchor BLOB (original): \(String(cString: sqlite3_errmsg(db)))")
            return false
        }

        // FIX #1230: Bind reversed anchor bytes (parameter 2)
        let bindResult2 = reversed.withUnsafeBytes { bytes in
            sqlite3_bind_blob(stmt, 2, bytes.baseAddress, Int32(reversed.count), SQLITE_TRANSIENT)
        }
        guard bindResult2 == SQLITE_OK else {
            print("⚠️ FIX #1230: Failed to bind anchor BLOB (reversed): \(String(cString: sqlite3_errmsg(db)))")
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
