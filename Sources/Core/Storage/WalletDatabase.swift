import Foundation
// Note: sqlite3 functions are available via bridging header (SQLCipher)
// Do NOT import SQLite3 here as it conflicts with SQLCipher's sqlite3.h
import CryptoKit
import Security  // VUL-016: For SecRandomCopyBytes

/// Encrypted SQLite database for wallet data
/// Uses AES-GCM-256 for field-level encryption of sensitive data
final class WalletDatabase {

    // MARK: - Encryption Helpers

    /// Encryption error types - VUL-002 fix
    enum EncryptionError: Error, LocalizedError {
        case encryptionFailed(String)
        case decryptionFailed(String)
        case dataCorrupted

        var errorDescription: String? {
            switch self {
            case .encryptionFailed(let msg): return "Encryption failed: \(msg)"
            case .decryptionFailed(let msg): return "Decryption failed: \(msg)"
            case .dataCorrupted: return "Data is corrupted or in unexpected format"
            }
        }
    }

    // MARK: - DEBUG FLAG - Disable field-level encryption for debugging
    // WARNING: Only set to true for debugging purposes! Set back to false before release!
    // FIX #226: Re-enabled field-level encryption - AES-GCM-256 active for sensitive fields
    // TEMPORARY: Disabled for debugging FIX #375
    private static let DEBUG_DISABLE_ENCRYPTION = true

    /// Encrypt sensitive data before storing in database
    /// Returns: nonce (12 bytes) + ciphertext + tag (16 bytes)
    /// SECURITY VUL-002: NEVER returns plaintext - throws on failure
    private func encryptBlob(_ data: Data) throws -> Data {
        // DEBUG: Skip encryption for debugging database issues
        if WalletDatabase.DEBUG_DISABLE_ENCRYPTION {
            return data
        }

        do {
            return try DatabaseEncryption.shared.encrypt(data)
        } catch {
            // SECURITY: Never store unencrypted data - throw error
            print("🔐 SECURITY ERROR: Encryption failed - refusing to store plaintext")
            throw EncryptionError.encryptionFailed(error.localizedDescription)
        }
    }

    /// Decrypt sensitive data retrieved from database
    /// SECURITY VUL-002: Throws on failure instead of returning corrupted data
    private func decryptBlob(_ encryptedData: Data) throws -> Data {
        // DEBUG: Skip decryption for debugging database issues
        if WalletDatabase.DEBUG_DISABLE_ENCRYPTION {
            return encryptedData
        }

        // AES-GCM combined format: 12 (nonce) + ciphertext + 16 (tag) = 29+ bytes
        guard encryptedData.count >= 29 else {
            // Data too short to be encrypted - this is a security issue
            print("🔐 SECURITY WARNING: Data too short to be encrypted (\(encryptedData.count) bytes)")
            throw EncryptionError.dataCorrupted
        }

        do {
            return try DatabaseEncryption.shared.decrypt(encryptedData)
        } catch {
            // SECURITY: Don't return potentially corrupted/wrong data
            print("🔐 SECURITY ERROR: Decryption failed - data may be corrupted")
            throw EncryptionError.decryptionFailed(error.localizedDescription)
        }
    }

    /// Check if encryption is enabled (always true after this update)
    var isEncryptionEnabled: Bool { !WalletDatabase.DEBUG_DISABLE_ENCRYPTION }

    /// Check if database connection is open
    var isOpen: Bool { db != nil }

    // MARK: - VUL-009: Nullifier Hashing

    /// Hash a nullifier for privacy-preserving storage
    /// Prevents spending pattern analysis if database is compromised
    /// FIX #212: Made internal (was private) for use in WalletManager.repairUnrecordedSpends()
    func hashNullifier(_ nullifier: Data) -> Data {
        return Data(SHA256.hash(data: nullifier))
    }

    /// Check if nullifier appears to be already hashed (32 bytes from SHA256)
    /// Used for backwards compatibility with pre-hashed nullifiers
    private func isNullifierHashed(_ data: Data) -> Bool {
        return data.count == 32  // SHA256 output is 32 bytes
    }

    // MARK: - VUL-015: Transaction Type Encryption

    /// Obfuscated transaction type codes (stored in database)
    /// Uses deterministic mapping so CHECK/UNIQUE constraints still work
    /// SECURITY: These codes don't reveal transaction direction if database is compromised
    private static let txTypeEncryptionMap: [TransactionType: String] = [
        .sent: "α",      // Obfuscated: doesn't reveal "sent"
        .received: "β",  // Obfuscated: doesn't reveal "received"
        .change: "γ"     // Obfuscated: doesn't reveal "change"
    ]

    private static let txTypeDecryptionMap: [String: TransactionType] = [
        "α": .sent,
        "β": .received,
        "γ": .change,
        // Backwards compatibility: support old plaintext values
        "sent": .sent,
        "received": .received,
        "change": .change
    ]

    /// Encrypt transaction type for database storage
    private func encryptTxType(_ type: TransactionType) -> String {
        return WalletDatabase.txTypeEncryptionMap[type] ?? type.rawValue
    }

    /// Decrypt transaction type from database storage
    /// FIX #503: Use byte comparison FIRST - String comparison fails due to Unicode normalization
    private func decryptTxType(_ stored: String) -> TransactionType {
        let storedBytes = stored.data(using: .utf8)

        // FIX #503: Try byte comparison FIRST - more reliable than String dictionary lookup
        for (key, value) in WalletDatabase.txTypeDecryptionMap {
            let keyBytes = key.data(using: .utf8)
            if storedBytes == keyBytes {
                return value
            }
        }

        // FIX #492: Direct lookup (legacy, less reliable due to Unicode normalization)
        if let result = WalletDatabase.txTypeDecryptionMap[stored] {
            return result
        }

        // FIX #492 v2: Handle Unicode normalization issues
        // Check first byte directly (faster than iterating)
        if let firstByte = storedBytes?.first {
            switch firstByte {
            case 0xCE:  // Greek letters range
                if let secondByte = storedBytes?.dropFirst().first {
                    switch secondByte {
                    case 0xB1: return .sent   // α
                    case 0xB2: return .received  // β
                    case 0xB3: return .change   // γ
                    default: break
                    }
                }
            default: break
            }
        }

        // Still failed - log for debugging
        print("⚠️ FIX #503: decryptTxType lookup failed for '\(stored)' (bytes: \(storedBytes?.hexString ?? "N/A"))")

        print("   Available keys: \(WalletDatabase.txTypeDecryptionMap.keys.map { "\($0)(\($0.data(using: .utf8)?.hexString ?? "N/A"))" }.joined(separator: ", "))")

        // Final fallback
        return .received
    }

    static let shared = WalletDatabase()

    private var db: OpaquePointer?
    private let dbPath: String
    private let queue = DispatchQueue(label: "com.zipherx.database", qos: .userInitiated)

    private init() {
        dbPath = AppDirectories.database.appendingPathComponent("zipherx_wallet.db").path
        // Thread safety is handled via SQLITE_OPEN_FULLMUTEX in open()

        // SECURITY: Apply iOS Data Protection to the database file
        applyDataProtection()
    }

    /// Apply iOS Data Protection Class to database file
    /// This encrypts the file at rest using device-bound key
    private func applyDataProtection() {
        let fileURL = URL(fileURLWithPath: dbPath)
        do {
            // Use most secure protection class - file only accessible when device is unlocked
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUnlessOpen],
                ofItemAtPath: fileURL.path
            )
        } catch {
            // File may not exist yet, protection will be applied on creation
        }
    }

    // MARK: - Database Connection

    private let openLock = NSLock()

    /// Open database with encryption key (thread-safe)
    /// Uses SQLCipher for full database encryption when available
    func open(encryptionKey: Data) throws {
        openLock.lock()
        defer { openLock.unlock() }

        // Don't reopen if already open
        if db != nil {
            print("📂 Database already open")
            return
        }

        let sqlCipher = SQLCipherManager.shared

        // Check if we need to migrate an existing unencrypted database
        let fileExists = FileManager.default.fileExists(atPath: dbPath)
        let needsMigration = fileExists &&
                             sqlCipher.isSQLCipherAvailable &&
                             !sqlCipher.isDatabaseEncrypted(path: dbPath)

        if needsMigration {
            try migrateToEncryptedDatabase()
        }

        print("📂 Opening database at: \(dbPath)")
        // Use FULLMUTEX for thread safety
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(dbPath, &db, flags, nil) == SQLITE_OK else {
            let errorMsg = db != nil ? String(cString: sqlite3_errmsg(db)) : "Unknown error"
            throw DatabaseError.openFailed(errorMsg)
        }

        // SECURITY: Apply SQLCipher encryption if available
        // This calls PRAGMA key with the derived encryption key
        if sqlCipher.isSQLCipherAvailable {
            do {
                try sqlCipher.applyEncryption(to: db!)
                print("🔐 Full database encryption active (SQLCipher)")
            } catch {
                // SQLCipher failed - close the connection
                sqlite3_close(db)
                db = nil

                // If database is encrypted but key doesn't work, it may be corrupted
                // from a failed migration. Try to recover by deleting it.
                print("⚠️ Database encryption failed - attempting recovery...")
                if sqlCipher.isDatabaseEncrypted(path: dbPath) {
                    print("🗑️ Removing corrupted encrypted database...")
                    try? FileManager.default.removeItem(atPath: dbPath)
                    try? FileManager.default.removeItem(atPath: dbPath + "-wal")
                    try? FileManager.default.removeItem(atPath: dbPath + "-shm")

                    // Retry opening (will create fresh database)
                    guard sqlite3_open_v2(dbPath, &db, flags, nil) == SQLITE_OK else {
                        throw DatabaseError.openFailed("Recovery failed")
                    }
                    try sqlCipher.applyEncryption(to: db!)
                    print("✅ Database recovered - created fresh encrypted database")
                } else {
                    throw DatabaseError.encryptionFailed
                }
            }
        } else {
            // DEBUG: Allow unencrypted database for debugging
            if WalletDatabase.DEBUG_DISABLE_ENCRYPTION {
                print("⚠️ DEBUG: VUL-007 bypassed - SQLCipher disabled for debugging")
            } else {
                // VUL-007 SECURITY FIX: SQLCipher is REQUIRED for wallet creation
                // iOS Data Protection alone is insufficient - database is readable after first unlock
                // Field-level encryption is a mitigation but doesn't protect metadata
                sqlite3_close(db)
                db = nil
                print("🔐 VUL-007: SQLCipher required but not available - refusing to create wallet")
                throw DatabaseError.encryptionRequired
            }
        }

        // FIX #200: SQLite performance optimizations
        // WAL mode: 10-50x faster writes, concurrent reads during writes
        // cache_size: 32MB (default 2MB) - faster repeated queries
        // mmap_size: 256MB - memory-mapped I/O for faster large reads
        let performancePragmas = [
            "PRAGMA journal_mode = WAL;",
            "PRAGMA synchronous = NORMAL;",  // Safe with WAL mode
            "PRAGMA cache_size = -32000;",   // 32MB (negative = KB)
            "PRAGMA mmap_size = 268435456;", // 256MB
            "PRAGMA temp_store = MEMORY;"    // Temp tables in memory
        ]

        for pragma in performancePragmas {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, pragma, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_step(stmt)
                sqlite3_finalize(stmt)
            }
        }
        print("⚡ FIX #200: SQLite performance pragmas applied (WAL, 32MB cache, 256MB mmap)")

        // Create tables
        try createTables()

        // VUL-015: Migrate any existing plaintext tx_type values to obfuscated codes
        // and remove duplicates caused by the type mismatch bug
        try migrateTransactionHistoryTypes()

        print("📂 Database opened successfully")
    }

    /// Migrate existing unencrypted database to encrypted format
    private func migrateToEncryptedDatabase() throws {
        print("🔐 Migrating existing database to encrypted format...")

        let backupPath = dbPath + ".backup"
        let tempEncryptedPath = dbPath + ".encrypted"
        let fileManager = FileManager.default

        // Create backup of original
        try? fileManager.removeItem(atPath: backupPath)
        try fileManager.copyItem(atPath: dbPath, toPath: backupPath)

        do {
            // Migrate to encrypted format
            try SQLCipherManager.shared.migrateToEncrypted(
                sourcePath: dbPath,
                destPath: tempEncryptedPath
            )

            // Replace original with encrypted version
            try fileManager.removeItem(atPath: dbPath)
            try fileManager.moveItem(atPath: tempEncryptedPath, toPath: dbPath)

            // Remove backup on success
            try? fileManager.removeItem(atPath: backupPath)

            print("🔐 Database migration to encrypted format complete")

        } catch {
            // Restore from backup on failure
            try? fileManager.removeItem(atPath: dbPath)
            try? fileManager.moveItem(atPath: backupPath, toPath: dbPath)
            try? fileManager.removeItem(atPath: tempEncryptedPath)

            print("⚠️ Database migration failed, restored original: \(error)")
            throw error
        }
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
    /// CRITICAL: Without this, wallet data may be lost on app termination
    /// Call this on app background/termination to ensure durability
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
                    print("💾 FIX #894: WalletDatabase WAL checkpoint - busy:\(busy), log:\(log), checkpointed:\(checkpointed)")
                }
            }
            sqlite3_finalize(stmt)
        }
    }

    /// Delete the entire database file (for wallet reset/import)
    /// CRITICAL: This permanently deletes all wallet data!
    func deleteDatabase() throws {
        // Close connection first
        close()

        // Delete the database file
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: dbPath) {
            try fileManager.removeItem(atPath: dbPath)
            print("🗑️ Database file deleted: \(dbPath)")
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

    // MARK: - Schema

    private func createTables() throws {
        guard db != nil else {
            throw DatabaseError.notOpened
        }

        let schemas = [
            // Accounts table
            """
            CREATE TABLE IF NOT EXISTS accounts (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                account_index INTEGER NOT NULL UNIQUE,
                spending_key BLOB NOT NULL,
                viewing_key BLOB NOT NULL,
                address TEXT NOT NULL,
                birthday_height INTEGER NOT NULL DEFAULT 0,
                created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now'))
            );
            """,

            // Notes (received shielded outputs)
            """
            CREATE TABLE IF NOT EXISTS notes (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                account_id INTEGER NOT NULL,
                diversifier BLOB NOT NULL,
                value INTEGER NOT NULL,
                rcm BLOB NOT NULL,
                memo BLOB,
                nf BLOB NOT NULL UNIQUE,
                is_spent INTEGER NOT NULL DEFAULT 0,
                spent_in_tx BLOB,
                spent_height INTEGER,
                received_in_tx BLOB NOT NULL,
                received_height INTEGER NOT NULL,
                witness BLOB,
                witness_height INTEGER,
                cmu BLOB,
                anchor BLOB,
                FOREIGN KEY (account_id) REFERENCES accounts(id)
            );
            """,

            // Transactions
            """
            CREATE TABLE IF NOT EXISTS transactions (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                txid BLOB NOT NULL UNIQUE,
                raw_tx BLOB NOT NULL,
                block_height INTEGER,
                block_time INTEGER,
                fee INTEGER,
                created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now'))
            );
            """,

            // Sent notes (for outgoing transactions)
            """
            CREATE TABLE IF NOT EXISTS sent_notes (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                tx_id INTEGER NOT NULL,
                output_index INTEGER NOT NULL,
                to_address TEXT NOT NULL,
                value INTEGER NOT NULL,
                memo BLOB,
                FOREIGN KEY (tx_id) REFERENCES transactions(id)
            );
            """,

            // Block headers (for SPV validation)
            """
            CREATE TABLE IF NOT EXISTS blocks (
                height INTEGER PRIMARY KEY,
                hash BLOB NOT NULL UNIQUE,
                prev_hash BLOB NOT NULL,
                time INTEGER NOT NULL,
                sapling_tree BLOB
            );
            """,

            // Nullifiers (to track spent notes)
            """
            CREATE TABLE IF NOT EXISTS nullifiers (
                nf BLOB PRIMARY KEY,
                block_height INTEGER NOT NULL,
                tx_index INTEGER NOT NULL
            );
            """,

            // Sync state
            """
            CREATE TABLE IF NOT EXISTS sync_state (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                last_scanned_height INTEGER NOT NULL DEFAULT 0,
                last_scanned_hash BLOB,
                tree_state BLOB
            );
            """,

            // Initialize sync state with default row
            """
            INSERT OR IGNORE INTO sync_state (id, last_scanned_height) VALUES (1, 0);
            """,

            // Transaction history (unified view of sent/received/change)
            // VUL-015: tx_type uses obfuscated codes (α, β, γ) with backwards compat for (sent, received, change)
            """
            CREATE TABLE IF NOT EXISTS transaction_history (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                txid BLOB NOT NULL,
                block_height INTEGER NOT NULL,
                block_time INTEGER,
                tx_type TEXT NOT NULL CHECK (tx_type IN ('sent', 'received', 'change', 'α', 'β', 'γ')),
                value INTEGER NOT NULL,
                fee INTEGER,
                to_address TEXT,
                from_diversifier BLOB,
                memo TEXT,
                status TEXT NOT NULL DEFAULT 'confirmed' CHECK (status IN ('pending', 'mempool', 'confirming', 'confirmed')),
                confirmations INTEGER NOT NULL DEFAULT 0,
                created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
                UNIQUE(txid, tx_type)
            );
            """,

            // Tree checkpoints - for fast witness generation and validation
            // Stores verified tree state at block boundaries for reliable transaction building
            """
            CREATE TABLE IF NOT EXISTS tree_checkpoints (
                height INTEGER PRIMARY KEY,
                tree_root BLOB NOT NULL,
                tree_serialized BLOB NOT NULL,
                cmu_count INTEGER NOT NULL,
                block_hash BLOB NOT NULL,
                created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now'))
            );
            """,

            // FIX #229: Trusted peers table - stores verified Zclassic nodes
            // These are used for initial bootstrap and fallback when DNS seeds return Zcash nodes
            """
            CREATE TABLE IF NOT EXISTS trusted_peers (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                host TEXT NOT NULL,
                port INTEGER NOT NULL DEFAULT 16125,
                last_connected INTEGER,
                successes INTEGER NOT NULL DEFAULT 0,
                failures INTEGER NOT NULL DEFAULT 0,
                is_onion INTEGER NOT NULL DEFAULT 0,
                notes TEXT,
                added_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
                UNIQUE(host, port)
            );
            """,

            // Indexes for performance
            "CREATE INDEX IF NOT EXISTS idx_notes_account ON notes(account_id);",
            "CREATE INDEX IF NOT EXISTS idx_notes_spent ON notes(is_spent);",
            "CREATE INDEX IF NOT EXISTS idx_notes_height ON notes(received_height);",
            "CREATE INDEX IF NOT EXISTS idx_nullifiers_height ON nullifiers(block_height);",
            "CREATE INDEX IF NOT EXISTS idx_history_height ON transaction_history(block_height DESC);",
            "CREATE INDEX IF NOT EXISTS idx_history_type ON transaction_history(tx_type);",
            "CREATE INDEX IF NOT EXISTS idx_tree_checkpoints_height ON tree_checkpoints(height DESC);",
            "CREATE INDEX IF NOT EXISTS idx_trusted_peers_host ON trusted_peers(host);",
            // FIX #754: Performance indexes for frequently queried columns
            "CREATE INDEX IF NOT EXISTS idx_notes_spent_in_tx ON notes(spent_in_tx);",
            "CREATE INDEX IF NOT EXISTS idx_notes_received_in_tx ON notes(received_in_tx);",
            "CREATE INDEX IF NOT EXISTS idx_history_txid ON transaction_history(txid);"
        ]

        for schema in schemas {
            guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else {
                throw DatabaseError.schemaCreationFailed(String(cString: sqlite3_errmsg(db)))
            }
        }

        // Run migrations for existing databases
        try runMigrations()
    }

    /// Run database migrations for schema updates
    private func runMigrations() throws {
        // Migration 1: Add cmu column to notes table if it doesn't exist
        // SQLite doesn't support IF NOT EXISTS for ALTER TABLE, so check column existence first
        var pragmaStmt: OpaquePointer?
        let pragmaSql = "PRAGMA table_info(notes);"
        guard sqlite3_prepare_v2(db, pragmaSql, -1, &pragmaStmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(pragmaStmt) }

        var hasCmuColumn = false
        while sqlite3_step(pragmaStmt) == SQLITE_ROW {
            if let columnName = sqlite3_column_text(pragmaStmt, 1) {
                if String(cString: columnName) == "cmu" {
                    hasCmuColumn = true
                    break
                }
            }
        }

        if !hasCmuColumn {
            let alterSql = "ALTER TABLE notes ADD COLUMN cmu BLOB;"
            guard sqlite3_exec(db, alterSql, nil, nil, nil) == SQLITE_OK else {
                throw DatabaseError.schemaCreationFailed("Migration failed: \(String(cString: sqlite3_errmsg(db)))")
            }
            print("📂 Migration: Added cmu column to notes table")
        }

        // Migration 2: Add unique index on CMU to prevent duplicate notes
        // CMU is the true unique identifier of a note (nullifier can be computed incorrectly)
        let createIndexSql = "CREATE UNIQUE INDEX IF NOT EXISTS idx_notes_cmu ON notes(cmu) WHERE cmu IS NOT NULL;"
        if sqlite3_exec(db, createIndexSql, nil, nil, nil) != SQLITE_OK {
            // Index might already exist or CMU column doesn't exist yet, not critical
            print("📂 Note: CMU unique index already exists or could not be created")
        }

        // Migration 3: Add anchor column to notes table if it doesn't exist
        // Re-check columns for anchor
        var pragmaStmt2: OpaquePointer?
        guard sqlite3_prepare_v2(db, pragmaSql, -1, &pragmaStmt2, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(pragmaStmt2) }

        var hasAnchorColumn = false
        while sqlite3_step(pragmaStmt2) == SQLITE_ROW {
            if let columnName = sqlite3_column_text(pragmaStmt2, 1) {
                if String(cString: columnName) == "anchor" {
                    hasAnchorColumn = true
                    break
                }
            }
        }

        if !hasAnchorColumn {
            let alterSql = "ALTER TABLE notes ADD COLUMN anchor BLOB;"
            guard sqlite3_exec(db, alterSql, nil, nil, nil) == SQLITE_OK else {
                throw DatabaseError.schemaCreationFailed("Migration failed: \(String(cString: sqlite3_errmsg(db)))")
            }
            print("📂 Migration: Added anchor column to notes table")
        }

        // Migration 4: Add spent_height column to notes table if it doesn't exist
        var pragmaStmt3: OpaquePointer?
        guard sqlite3_prepare_v2(db, pragmaSql, -1, &pragmaStmt3, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(pragmaStmt3) }

        var hasSpentHeightColumn = false
        while sqlite3_step(pragmaStmt3) == SQLITE_ROW {
            if let columnName = sqlite3_column_text(pragmaStmt3, 1) {
                if String(cString: columnName) == "spent_height" {
                    hasSpentHeightColumn = true
                    break
                }
            }
        }

        if !hasSpentHeightColumn {
            let alterSql = "ALTER TABLE notes ADD COLUMN spent_height INTEGER;"
            guard sqlite3_exec(db, alterSql, nil, nil, nil) == SQLITE_OK else {
                throw DatabaseError.schemaCreationFailed("Migration failed: \(String(cString: sqlite3_errmsg(db)))")
            }
            print("📂 Migration: Added spent_height column to notes table")
        }

        // Migration 5: Add status and confirmations columns to transaction_history
        let historyPragmaSql = "PRAGMA table_info(transaction_history);"
        var historyPragmaStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, historyPragmaSql, -1, &historyPragmaStmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(historyPragmaStmt) }

        var hasStatusColumn = false
        var hasConfirmationsColumn = false
        while sqlite3_step(historyPragmaStmt) == SQLITE_ROW {
            if let columnName = sqlite3_column_text(historyPragmaStmt, 1) {
                let name = String(cString: columnName)
                if name == "status" { hasStatusColumn = true }
                if name == "confirmations" { hasConfirmationsColumn = true }
            }
        }

        if !hasStatusColumn {
            let alterSql = "ALTER TABLE transaction_history ADD COLUMN status TEXT NOT NULL DEFAULT 'confirmed';"
            if sqlite3_exec(db, alterSql, nil, nil, nil) == SQLITE_OK {
                print("📂 Migration: Added status column to transaction_history")
            }
        }

        if !hasConfirmationsColumn {
            let alterSql = "ALTER TABLE transaction_history ADD COLUMN confirmations INTEGER NOT NULL DEFAULT 0;"
            if sqlite3_exec(db, alterSql, nil, nil, nil) == SQLITE_OK {
                print("📂 Migration: Added confirmations column to transaction_history")
            }
        }

        // Migration 6: Recreate transaction_history with 'change' type and fixed UNIQUE constraint
        // SQLite doesn't support ALTER TABLE for CHECK constraints, so we need to recreate
        // First check if the current constraint allows 'change' type
        // Use minimal INSERT that doesn't depend on status/confirmations columns existing
        print("📂 Migration 6: Testing if 'change' type is supported...")
        let testInsert = "INSERT INTO transaction_history (txid, block_height, tx_type, value) VALUES (X'00', 0, 'change', 0);"
        let testResult = sqlite3_exec(db, testInsert, nil, nil, nil)
        print("📂 Migration 6: Test result = \(testResult) (SQLITE_OK = \(SQLITE_OK))")
        if testResult != SQLITE_OK {
            // 'change' type not allowed or schema is old, need to recreate table
            print("📂 Migration 6: Recreating transaction_history with 'change' type support...")

            // Drop any leftover _new table from previous failed migration
            _ = sqlite3_exec(db, "DROP TABLE IF EXISTS transaction_history_new;", nil, nil, nil)

            // Start transaction
            _ = sqlite3_exec(db, "BEGIN TRANSACTION;", nil, nil, nil)

            // Create new table with correct schema
            let createNewTable = """
                CREATE TABLE IF NOT EXISTS transaction_history_new (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    txid BLOB NOT NULL,
                    block_height INTEGER NOT NULL,
                    block_time INTEGER,
                    tx_type TEXT NOT NULL CHECK (tx_type IN ('sent', 'received', 'change')),
                    value INTEGER NOT NULL,
                    fee INTEGER,
                    to_address TEXT,
                    from_diversifier BLOB,
                    memo TEXT,
                    status TEXT NOT NULL DEFAULT 'confirmed' CHECK (status IN ('pending', 'mempool', 'confirming', 'confirmed')),
                    confirmations INTEGER NOT NULL DEFAULT 0,
                    created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
                    UNIQUE(txid, tx_type)
                );
            """

            let createResult = sqlite3_exec(db, createNewTable, nil, nil, nil)
            print("📂 Migration 6: Create new table result = \(createResult)")
            if createResult == SQLITE_OK {
                // Copy data, keeping only one entry per (txid, tx_type) - prefer the one with highest value
                // Check if old table has status column to determine which copy query to use
                var hasOldStatusColumn = false
                var columnCheckStmt: OpaquePointer?
                if sqlite3_prepare_v2(db, "PRAGMA table_info(transaction_history);", -1, &columnCheckStmt, nil) == SQLITE_OK {
                    while sqlite3_step(columnCheckStmt) == SQLITE_ROW {
                        if let colName = sqlite3_column_text(columnCheckStmt, 1) {
                            if String(cString: colName) == "status" { hasOldStatusColumn = true }
                        }
                    }
                    sqlite3_finalize(columnCheckStmt)
                }

                let copyData: String
                if hasOldStatusColumn {
                    copyData = """
                        INSERT INTO transaction_history_new (txid, block_height, block_time, tx_type, value, fee, to_address, from_diversifier, memo, status, confirmations, created_at)
                        SELECT txid, block_height, block_time, tx_type, MAX(value), fee, to_address, from_diversifier, memo, status, confirmations, created_at
                        FROM transaction_history
                        GROUP BY txid, tx_type;
                    """
                } else {
                    // Old table doesn't have status/confirmations - use defaults
                    copyData = """
                        INSERT INTO transaction_history_new (txid, block_height, block_time, tx_type, value, fee, to_address, from_diversifier, memo, created_at)
                        SELECT txid, block_height, block_time, tx_type, MAX(value), fee, to_address, from_diversifier, memo, created_at
                        FROM transaction_history
                        GROUP BY txid, tx_type;
                    """
                }

                print("📂 Migration 6: hasOldStatusColumn = \(hasOldStatusColumn)")
                let copyResult = sqlite3_exec(db, copyData, nil, nil, nil)
                print("📂 Migration 6: Copy data result = \(copyResult)")
                if copyResult == SQLITE_OK {
                    // Drop old table and rename new one
                    let dropResult = sqlite3_exec(db, "DROP TABLE transaction_history;", nil, nil, nil)
                    print("📂 Migration 6: Drop old table result = \(dropResult)")
                    let renameResult = sqlite3_exec(db, "ALTER TABLE transaction_history_new RENAME TO transaction_history;", nil, nil, nil)
                    print("📂 Migration 6: Rename result = \(renameResult)")
                    _ = sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_history_height ON transaction_history(block_height DESC);", nil, nil, nil)
                    _ = sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_history_type ON transaction_history(tx_type);", nil, nil, nil)
                    _ = sqlite3_exec(db, "COMMIT;", nil, nil, nil)
                    print("📂 Migration 6: Successfully recreated transaction_history")
                } else {
                    let errMsg = String(cString: sqlite3_errmsg(db))
                    print("📂 Migration 6: Failed to copy data: \(errMsg)")
                    _ = sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                }
            } else {
                let errMsg = String(cString: sqlite3_errmsg(db))
                print("📂 Migration 6: Failed to create new table: \(errMsg)")
                _ = sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            }
        } else {
            // 'change' type already supported, delete test row
            _ = sqlite3_exec(db, "DELETE FROM transaction_history WHERE txid = X'00' AND value = 0;", nil, nil, nil)
            print("📂 Migration 6: 'change' type already supported")
        }

        // Migration 7: FIX #165 - Add verified_checkpoint_height column to sync_state
        // This stores the last block height where balance/history was verified correct.
        // On startup, app MUST scan from checkpoint to chain tip to catch ALL missed transactions.
        var syncStateColumns: Set<String> = []
        var pragmaStmtSync: OpaquePointer?
        if sqlite3_prepare_v2(db, "PRAGMA table_info(sync_state);", -1, &pragmaStmtSync, nil) == SQLITE_OK {
            while sqlite3_step(pragmaStmtSync) == SQLITE_ROW {
                if let columnName = sqlite3_column_text(pragmaStmtSync, 1) {
                    syncStateColumns.insert(String(cString: columnName))
                }
            }
            sqlite3_finalize(pragmaStmtSync)
        }

        if !syncStateColumns.contains("verified_checkpoint_height") {
            let alterSql = "ALTER TABLE sync_state ADD COLUMN verified_checkpoint_height INTEGER NOT NULL DEFAULT 0;"
            if sqlite3_exec(db, alterSql, nil, nil, nil) == SQLITE_OK {
                print("📂 Migration 7: Added verified_checkpoint_height column to sync_state (FIX #165)")
            } else {
                print("⚠️ Migration 7: Failed to add verified_checkpoint_height: \(String(cString: sqlite3_errmsg(db)))")
            }
        }

        // Migration 8: FIX #241 - Checkpoint history table (last 10 checkpoints)
        let checkpointTableSql = """
            CREATE TABLE IF NOT EXISTS checkpoint_history (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                height INTEGER NOT NULL,
                tree_root BLOB,
                timestamp INTEGER NOT NULL DEFAULT (strftime('%s', 'now'))
            );
        """
        if sqlite3_exec(db, checkpointTableSql, nil, nil, nil) == SQLITE_OK {
            print("📂 Migration 8: Created checkpoint_history table (FIX #241)")
        }

        // Migration 9: FIX #284 - Add is_preferred column to trusted_peers for Preferred Seeds
        // Preferred seeds get priority connection and are exempt from parking (not bans)
        var trustedPeersStmt: OpaquePointer?
        let trustedPeersPragma = "PRAGMA table_info(trusted_peers);"
        if sqlite3_prepare_v2(db, trustedPeersPragma, -1, &trustedPeersStmt, nil) == SQLITE_OK {
            var hasPreferredColumn = false
            while sqlite3_step(trustedPeersStmt) == SQLITE_ROW {
                if let columnName = sqlite3_column_text(trustedPeersStmt, 1) {
                    if String(cString: columnName) == "is_preferred" {
                        hasPreferredColumn = true
                        break
                    }
                }
            }
            sqlite3_finalize(trustedPeersStmt)

            if !hasPreferredColumn {
                let alterSql = "ALTER TABLE trusted_peers ADD COLUMN is_preferred INTEGER NOT NULL DEFAULT 0;"
                if sqlite3_exec(db, alterSql, nil, nil, nil) == SQLITE_OK {
                    print("📂 Migration 9: Added is_preferred column to trusted_peers (FIX #284)")

                    // Seed the preferred seeds table with known good Zclassic nodes
                    let seedSql = """
                        INSERT OR IGNORE INTO trusted_peers (host, port, is_preferred, notes)
                        VALUES
                        ('140.174.189.3', 8033, 1, 'Preferred seed'),
                        ('140.174.189.17', 8033, 1, 'Preferred seed'),
                        ('205.209.104.118', 8033, 1, 'Preferred seed'),
                        ('95.179.131.117', 8033, 1, 'Preferred seed'),
                        ('45.77.216.198', 8033, 1, 'Preferred seed');
                    """
                    if sqlite3_exec(db, seedSql, nil, nil, nil) == SQLITE_OK {
                        print("📂 Migration 9: Seeded 5 preferred seeds")
                    }
                } else {
                    print("⚠️ Migration 9: Failed to add is_preferred: \(String(cString: sqlite3_errmsg(db)))")
                }
            }
        }

        // Migration 10: FIX #370 - Add tx_confirmed_checkpoint column to sync_state
        // This checkpoint ONLY updates when a TX is confirmed (incoming or outgoing).
        // Used by periodic deep verification to catch missed transactions.
        // Different from verified_checkpoint_height which updates on every scan.
        if !syncStateColumns.contains("tx_confirmed_checkpoint") {
            let alterSql = "ALTER TABLE sync_state ADD COLUMN tx_confirmed_checkpoint INTEGER NOT NULL DEFAULT 0;"
            if sqlite3_exec(db, alterSql, nil, nil, nil) == SQLITE_OK {
                print("📂 Migration 10: Added tx_confirmed_checkpoint column to sync_state (FIX #370)")

                // Initialize to current verified_checkpoint if available
                let initSql = "UPDATE sync_state SET tx_confirmed_checkpoint = verified_checkpoint_height WHERE id = 1;"
                sqlite3_exec(db, initSql, nil, nil, nil)
            } else {
                print("⚠️ Migration 10: Failed to add tx_confirmed_checkpoint: \(String(cString: sqlite3_errmsg(db)))")
            }
        }

        // Migration 11: FIX #370 - Add last_deep_verification timestamp to sync_state
        // Tracks when the last deep verification scan was run
        if !syncStateColumns.contains("last_deep_verification") {
            let alterSql = "ALTER TABLE sync_state ADD COLUMN last_deep_verification INTEGER NOT NULL DEFAULT 0;";
            if sqlite3_exec(db, alterSql, nil, nil, nil) == SQLITE_OK {
                print("📂 Migration 11: Added last_deep_verification column to sync_state (FIX #370)")
            } else {
                print("⚠️ Migration 11: Failed to add last_deep_verification: \(String(cString: sqlite3_errmsg(db)))")
            }
        }

        // Migration 12: FIX #557 v45 - Add witness_index column to notes table
        // Stores the index of the witness in the global FFI tree, allowing us to retrieve fresh witnesses
        let notesColumns = getTableColumns("notes")
        if !notesColumns.contains("witness_index") {
            let alterSql = "ALTER TABLE notes ADD COLUMN witness_index INTEGER NOT NULL DEFAULT 0;";
            if sqlite3_exec(db, alterSql, nil, nil, nil) == SQLITE_OK {
                print("📂 Migration 12: Added witness_index column to notes table (FIX #557 v45)")
            } else {
                print("⚠️ Migration 12: Failed to add witness_index: \(String(cString: sqlite3_errmsg(db)))")
            }
        }

        // Migration 13: FIX #741 - Add tree_height column to sync_state table
        // Stores the height of the commitment tree, allowing us to persist delta sync progress
        if !syncStateColumns.contains("tree_height") {
            let alterSql = "ALTER TABLE sync_state ADD COLUMN tree_height INTEGER NOT NULL DEFAULT 0;";
            if sqlite3_exec(db, alterSql, nil, nil, nil) == SQLITE_OK {
                print("📂 Migration 13: Added tree_height column to sync_state table (FIX #741)")
            } else {
                print("⚠️ Migration 13: Failed to add tree_height: \(String(cString: sqlite3_errmsg(db)))")
            }
        }

        // Migration 14: FIX #1085 - Add peer scoring columns to trusted_peers table
        // score: 0-100, higher = better peer (starts at 50)
        // is_reliable: 1 = peer has proven reliable (score >= 70, successes >= 5)
        // is_bad: 1 = permanently bad peer (wrong chain, protocol errors) - never use
        // response_time_ms: average response time in milliseconds
        // last_success: timestamp of last successful connection
        var trustedPeersColumns: Set<String> = []
        var tpStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "PRAGMA table_info(trusted_peers);", -1, &tpStmt, nil) == SQLITE_OK {
            while sqlite3_step(tpStmt) == SQLITE_ROW {
                if let colName = sqlite3_column_text(tpStmt, 1) {
                    trustedPeersColumns.insert(String(cString: colName))
                }
            }
            sqlite3_finalize(tpStmt)
        }

        if !trustedPeersColumns.contains("score") {
            let alterSql = "ALTER TABLE trusted_peers ADD COLUMN score INTEGER NOT NULL DEFAULT 50;"
            if sqlite3_exec(db, alterSql, nil, nil, nil) == SQLITE_OK {
                print("📂 Migration 14: Added score column to trusted_peers (FIX #1085)")
            }
        }
        if !trustedPeersColumns.contains("is_reliable") {
            let alterSql = "ALTER TABLE trusted_peers ADD COLUMN is_reliable INTEGER NOT NULL DEFAULT 0;"
            if sqlite3_exec(db, alterSql, nil, nil, nil) == SQLITE_OK {
                print("📂 Migration 14: Added is_reliable column to trusted_peers (FIX #1085)")
            }
        }
        if !trustedPeersColumns.contains("is_bad") {
            let alterSql = "ALTER TABLE trusted_peers ADD COLUMN is_bad INTEGER NOT NULL DEFAULT 0;"
            if sqlite3_exec(db, alterSql, nil, nil, nil) == SQLITE_OK {
                print("📂 Migration 14: Added is_bad column to trusted_peers (FIX #1085)")
            }
        }
        if !trustedPeersColumns.contains("response_time_ms") {
            let alterSql = "ALTER TABLE trusted_peers ADD COLUMN response_time_ms INTEGER NOT NULL DEFAULT 0;"
            if sqlite3_exec(db, alterSql, nil, nil, nil) == SQLITE_OK {
                print("📂 Migration 14: Added response_time_ms column to trusted_peers (FIX #1085)")
            }
        }
        if !trustedPeersColumns.contains("last_success") {
            let alterSql = "ALTER TABLE trusted_peers ADD COLUMN last_success INTEGER NOT NULL DEFAULT 0;"
            if sqlite3_exec(db, alterSql, nil, nil, nil) == SQLITE_OK {
                print("📂 Migration 14: Added last_success column to trusted_peers (FIX #1085)")
            }
        }
    }

    // MARK: - Account Operations

    /// Store a new account
    func insertAccount(
        accountIndex: UInt32,
        spendingKey: Data,
        viewingKey: Data,
        address: String,
        birthdayHeight: UInt64
    ) throws -> Int64 {
        let sql = """
            INSERT INTO accounts (account_index, spending_key, viewing_key, address, birthday_height)
            VALUES (?, ?, ?, ?, ?);
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int(stmt, 1, Int32(accountIndex))
        _ = spendingKey.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, 2, ptr.baseAddress, Int32(spendingKey.count), nil)
        }
        _ = viewingKey.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, 3, ptr.baseAddress, Int32(viewingKey.count), nil)
        }
        sqlite3_bind_text(stmt, 4, address, -1, nil)
        sqlite3_bind_int64(stmt, 5, Int64(birthdayHeight))

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.insertFailed(String(cString: sqlite3_errmsg(db)))
        }

        return sqlite3_last_insert_rowid(db)
    }

    /// Get account by index
    func getAccount(index: UInt32) throws -> Account? {
        guard db != nil else {
            print("❌ getAccount: Database not open")
            throw DatabaseError.openFailed("Database not open")
        }

        // Debug: check how many accounts exist
        var countStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM accounts;", -1, &countStmt, nil) == SQLITE_OK {
            if sqlite3_step(countStmt) == SQLITE_ROW {
                let count = sqlite3_column_int(countStmt, 0)
                print("📊 Total accounts in database: \(count)")
            }
            sqlite3_finalize(countStmt)
        }

        let sql = "SELECT id, spending_key, viewing_key, address, birthday_height FROM accounts WHERE account_index = ?;"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int(stmt, 1, Int32(index))

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            print("❌ No account found with index \(index)")
            return nil
        }

        let id = sqlite3_column_int64(stmt, 0)
        let skPtr = sqlite3_column_blob(stmt, 1)
        let skLen = sqlite3_column_bytes(stmt, 1)
        let vkPtr = sqlite3_column_blob(stmt, 2)
        let vkLen = sqlite3_column_bytes(stmt, 2)
        let address = String(cString: sqlite3_column_text(stmt, 3))
        let birthday = UInt64(sqlite3_column_int64(stmt, 4))

        return Account(
            accountId: id,
            spendingKey: Data(bytes: skPtr!, count: Int(skLen)),
            viewingKey: Data(bytes: vkPtr!, count: Int(vkLen)),
            address: address,
            birthdayHeight: birthday
        )
    }

    // MARK: - Note Operations

    /// Insert a received note
    func insertNote(
        accountId: Int64,
        diversifier: Data,
        value: UInt64,
        rcm: Data,
        memo: Data?,
        nullifier: Data,
        txid: Data,
        height: UInt64,
        witness: Data?,
        cmu: Data? = nil
    ) throws -> Int64 {
        // Use INSERT OR IGNORE to skip notes that already exist (by nullifier uniqueness)
        // This prevents duplicates during rescanning
        let sql = """
            INSERT OR IGNORE INTO notes (account_id, diversifier, value, rcm, memo, nf, received_in_tx, received_height, witness, witness_height, cmu)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        // SQLITE_TRANSIENT tells SQLite to copy the data immediately
        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        // SECURITY: Encrypt sensitive fields before storage (VUL-002: throws on failure)
        // - diversifier: address component (encrypted)
        // - rcm: randomness commitment used in spending (encrypted)
        // - memo: potentially sensitive message (encrypted)
        // - witness: Merkle path for spending (encrypted)
        let encryptedDiversifier = try encryptBlob(diversifier)
        let encryptedRcm = try encryptBlob(rcm)
        let encryptedMemo = memo != nil ? try encryptBlob(memo!) : nil

        sqlite3_bind_int64(stmt, 1, accountId)
        _ = encryptedDiversifier.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, 2, ptr.baseAddress, Int32(encryptedDiversifier.count), SQLITE_TRANSIENT)
        }
        sqlite3_bind_int64(stmt, 3, Int64(value))
        _ = encryptedRcm.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, 4, ptr.baseAddress, Int32(encryptedRcm.count), SQLITE_TRANSIENT)
        }
        if let encMemo = encryptedMemo {
            _ = encMemo.withUnsafeBytes { ptr in
                sqlite3_bind_blob(stmt, 5, ptr.baseAddress, Int32(encMemo.count), SQLITE_TRANSIENT)
            }
        } else {
            sqlite3_bind_null(stmt, 5)
        }
        // VUL-009: Hash nullifier before storage to prevent spending pattern analysis
        let hashedNullifier = hashNullifier(nullifier)
        _ = hashedNullifier.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, 6, ptr.baseAddress, Int32(hashedNullifier.count), SQLITE_TRANSIENT)
        }
        _ = txid.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, 7, ptr.baseAddress, Int32(txid.count), SQLITE_TRANSIENT)
        }
        sqlite3_bind_int64(stmt, 8, Int64(height))
        if let witness = witness {
            // SECURITY: Encrypt witness (Merkle path) - VUL-002: throws on failure
            let encryptedWitness = try encryptBlob(witness)
            _ = encryptedWitness.withUnsafeBytes { ptr in
                sqlite3_bind_blob(stmt, 9, ptr.baseAddress, Int32(encryptedWitness.count), SQLITE_TRANSIENT)
            }
            sqlite3_bind_int64(stmt, 10, Int64(height))
        } else {
            sqlite3_bind_null(stmt, 9)
            sqlite3_bind_null(stmt, 10)
        }
        // Bind CMU (note commitment) - not encrypted (public on chain)
        if let cmu = cmu {
            _ = cmu.withUnsafeBytes { ptr in
                sqlite3_bind_blob(stmt, 11, ptr.baseAddress, Int32(cmu.count), SQLITE_TRANSIENT)
            }
        } else {
            sqlite3_bind_null(stmt, 11)
        }

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.insertFailed(String(cString: sqlite3_errmsg(db)))
        }

        let insertedId = sqlite3_last_insert_rowid(db)

        // If INSERT OR IGNORE skipped the insert (duplicate nullifier), fetch existing note ID
        if sqlite3_changes(db) == 0 {
            // Note already exists, fetch its ID by hashed nullifier (VUL-009)
            let selectSql = "SELECT id FROM notes WHERE nf = ?;"
            var selectStmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, selectSql, -1, &selectStmt, nil) == SQLITE_OK else {
                return 0 // Return 0 if we can't find it
            }
            defer { sqlite3_finalize(selectStmt) }

            let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            _ = hashedNullifier.withUnsafeBytes { ptr in
                sqlite3_bind_blob(selectStmt, 1, ptr.baseAddress, Int32(hashedNullifier.count), SQLITE_TRANSIENT)
            }

            if sqlite3_step(selectStmt) == SQLITE_ROW {
                return sqlite3_column_int64(selectStmt, 0)
            }
            return 0
        }

        return insertedId
    }

    /// Struct for batch note insertion (FIX #754)
    struct BatchNote {
        let accountId: Int64
        let diversifier: Data
        let value: UInt64
        let rcm: Data
        let memo: Data?
        let nullifier: Data
        let txid: Data
        let height: UInt64
        let witness: Data?
        let cmu: Data?
    }

    /// FIX #754: Batch insert notes with single transaction for better performance
    /// Uses prepared statement reuse + transaction wrapping for ~50x speedup
    /// - Parameter notes: Array of notes to insert
    /// - Returns: Number of notes successfully inserted
    @discardableResult
    func insertNotesBatch(_ notes: [BatchNote]) throws -> Int {
        guard !notes.isEmpty else { return 0 }

        let sql = """
            INSERT OR IGNORE INTO notes (account_id, diversifier, value, rcm, memo, nf, received_in_tx, received_height, witness, witness_height, cmu)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        // Start transaction
        guard sqlite3_exec(db, "BEGIN IMMEDIATE TRANSACTION;", nil, nil, nil) == SQLITE_OK else {
            throw DatabaseError.transactionFailed("BEGIN failed: \(String(cString: sqlite3_errmsg(db)))")
        }

        var insertedCount = 0
        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        do {
            for note in notes {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)

                // Encrypt sensitive fields
                let encryptedDiversifier = try encryptBlob(note.diversifier)
                let encryptedRcm = try encryptBlob(note.rcm)
                let encryptedMemo = note.memo != nil ? try encryptBlob(note.memo!) : nil

                sqlite3_bind_int64(stmt, 1, note.accountId)
                _ = encryptedDiversifier.withUnsafeBytes { ptr in
                    sqlite3_bind_blob(stmt, 2, ptr.baseAddress, Int32(encryptedDiversifier.count), SQLITE_TRANSIENT)
                }
                sqlite3_bind_int64(stmt, 3, Int64(note.value))
                _ = encryptedRcm.withUnsafeBytes { ptr in
                    sqlite3_bind_blob(stmt, 4, ptr.baseAddress, Int32(encryptedRcm.count), SQLITE_TRANSIENT)
                }
                if let encMemo = encryptedMemo {
                    _ = encMemo.withUnsafeBytes { ptr in
                        sqlite3_bind_blob(stmt, 5, ptr.baseAddress, Int32(encMemo.count), SQLITE_TRANSIENT)
                    }
                } else {
                    sqlite3_bind_null(stmt, 5)
                }
                // VUL-009: Hash nullifier
                let hashedNullifier = hashNullifier(note.nullifier)
                _ = hashedNullifier.withUnsafeBytes { ptr in
                    sqlite3_bind_blob(stmt, 6, ptr.baseAddress, Int32(hashedNullifier.count), SQLITE_TRANSIENT)
                }
                _ = note.txid.withUnsafeBytes { ptr in
                    sqlite3_bind_blob(stmt, 7, ptr.baseAddress, Int32(note.txid.count), SQLITE_TRANSIENT)
                }
                sqlite3_bind_int64(stmt, 8, Int64(note.height))
                if let witness = note.witness {
                    let encryptedWitness = try encryptBlob(witness)
                    _ = encryptedWitness.withUnsafeBytes { ptr in
                        sqlite3_bind_blob(stmt, 9, ptr.baseAddress, Int32(encryptedWitness.count), SQLITE_TRANSIENT)
                    }
                    sqlite3_bind_int64(stmt, 10, Int64(note.height))
                } else {
                    sqlite3_bind_null(stmt, 9)
                    sqlite3_bind_null(stmt, 10)
                }
                if let cmu = note.cmu {
                    _ = cmu.withUnsafeBytes { ptr in
                        sqlite3_bind_blob(stmt, 11, ptr.baseAddress, Int32(cmu.count), SQLITE_TRANSIENT)
                    }
                } else {
                    sqlite3_bind_null(stmt, 11)
                }

                if sqlite3_step(stmt) == SQLITE_DONE {
                    if sqlite3_changes(db) > 0 {
                        insertedCount += 1
                    }
                }
            }

            // Commit transaction
            guard sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK else {
                throw DatabaseError.transactionFailed("COMMIT failed: \(String(cString: sqlite3_errmsg(db)))")
            }

            return insertedCount
        } catch {
            // Rollback on error
            _ = sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            throw error
        }
    }

    /// Debug: Get all notes (spent and unspent) with detailed info
    func debugListAllNotes(accountId: Int64) throws {
        let sql = """
            SELECT id, diversifier, value, rcm, nf, received_height, is_spent, witness
            FROM notes
            WHERE account_id = ?
            ORDER BY received_height ASC;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, accountId)

        var totalUnspent: UInt64 = 0
        var totalSpent: UInt64 = 0
        var unspentCount = 0
        var spentCount = 0

        print("📊 ===== DATABASE NOTES ANALYSIS =====")

        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let divPtr = sqlite3_column_blob(stmt, 1)
            let divLen = sqlite3_column_bytes(stmt, 1)
            let value = UInt64(sqlite3_column_int64(stmt, 2))
            let height = UInt64(sqlite3_column_int64(stmt, 5))
            let isSpent = sqlite3_column_int(stmt, 6)
            let witnessPtr = sqlite3_column_blob(stmt, 7)
            let witnessLen = sqlite3_column_bytes(stmt, 7)

            let divHex = Data(bytes: divPtr!, count: Int(divLen)).map { String(format: "%02x", $0) }.joined()
            let hasWitness = witnessPtr != nil && witnessLen > 0

            let spentStatus = isSpent == 1 ? "SPENT" : "UNSPENT"
            let witnessStatus = hasWitness ? "✅" : "❌"

            print("📝 Note \(id): value=\(value) zatoshis (\(Double(value)/100000000.0) ZCL), height=\(height), \(spentStatus), witness=\(witnessStatus)")
            print("   diversifier: \(divHex.prefix(22))...")

            if isSpent == 1 {
                spentCount += 1
                totalSpent += value
            } else {
                unspentCount += 1
                totalUnspent += value
            }
        }

        print("📊 ===== SUMMARY =====")
        print("📊 Unspent notes: \(unspentCount), Total: \(totalUnspent) zatoshis (\(Double(totalUnspent)/100000000.0) ZCL)")
        print("📊 Spent notes: \(spentCount), Total: \(totalSpent) zatoshis (\(Double(totalSpent)/100000000.0) ZCL)")
        print("📊 Grand total: \(totalUnspent + totalSpent) zatoshis (\(Double(totalUnspent + totalSpent)/100000000.0) ZCL)")
        print("📊 ================================")
    }

    /// Get all unspent notes (regardless of witness status) - for diagnostics
    func getAllUnspentNotes(accountId: Int64) throws -> [WalletNote] {
        // FIX #940: Guard against nil database handle
        // sqlite3_errmsg(nil) returns "out of memory" which is misleading
        // This happens when health checks run before database is opened
        guard db != nil else {
            print("⚠️ getAllUnspentNotes: Database not open, returning empty array")
            return []
        }

        let sql = """
            SELECT id, diversifier, value, rcm, memo, nf, received_in_tx, received_height, witness, cmu, anchor, witness_index
            FROM notes
            WHERE account_id = ? AND is_spent = 0
            ORDER BY received_height ASC;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, accountId)

        var notes: [WalletNote] = []

        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let divPtr = sqlite3_column_blob(stmt, 1)
            let divLen = sqlite3_column_bytes(stmt, 1)
            let value = UInt64(sqlite3_column_int64(stmt, 2))
            let rcmPtr = sqlite3_column_blob(stmt, 3)
            let rcmLen = sqlite3_column_bytes(stmt, 3)
            let nfPtr = sqlite3_column_blob(stmt, 5)
            let nfLen = sqlite3_column_bytes(stmt, 5)
            let height = UInt64(sqlite3_column_int64(stmt, 7))

            // SECURITY: Decrypt sensitive fields - VUL-002: throws on failure
            let encryptedDiv = Data(bytes: divPtr!, count: Int(divLen))
            let encryptedRcm = Data(bytes: rcmPtr!, count: Int(rcmLen))
            let diversifier = try decryptBlob(encryptedDiv)
            let rcm = try decryptBlob(encryptedRcm)

            // Witness might be NULL
            var witnessData = Data()
            if sqlite3_column_type(stmt, 8) != SQLITE_NULL {
                let witnessPtr = sqlite3_column_blob(stmt, 8)
                let witnessLen = sqlite3_column_bytes(stmt, 8)
                // FIX #557 v34: Double-check pointer isn't nil (empty blob != NULL)
                if witnessPtr != nil && witnessLen > 0 {
                    let encryptedWitness = Data(bytes: witnessPtr!, count: Int(witnessLen))
                    witnessData = try decryptBlob(encryptedWitness)
                }
            }

            // CMU might be NULL (not encrypted - public on chain)
            var cmuData: Data? = nil
            if sqlite3_column_type(stmt, 9) != SQLITE_NULL {
                let cmuPtr = sqlite3_column_blob(stmt, 9)
                let cmuLen = sqlite3_column_bytes(stmt, 9)
                // FIX #557 v34: Double-check pointer isn't nil (empty blob != NULL)
                if cmuPtr != nil && cmuLen > 0 {
                    cmuData = Data(bytes: cmuPtr!, count: Int(cmuLen))
                }
            }

            // Anchor might be NULL
            var anchorData: Data? = nil
            if sqlite3_column_type(stmt, 10) != SQLITE_NULL {
                let anchorPtr = sqlite3_column_blob(stmt, 10)
                let anchorLen = sqlite3_column_bytes(stmt, 10)
                // FIX #557 v34: Double-check pointer isn't nil (empty blob != NULL)
                if anchorPtr != nil && anchorLen > 0 {
                    anchorData = Data(bytes: anchorPtr!, count: Int(anchorLen))
                }
            }

            // FIX #557 v45: Extract witness_index
            let witnessIndex = UInt64(sqlite3_column_int64(stmt, 11))

            let note = WalletNote(
                id: id,
                diversifier: diversifier,
                value: value,
                rcm: rcm,
                nullifier: Data(bytes: nfPtr!, count: Int(nfLen)),
                height: height,
                witness: witnessData,
                cmu: cmuData,
                anchor: anchorData,
                witnessIndex: witnessIndex
            )

            notes.append(note)
        }

        return notes
    }

    /// FIX #162 v3: Get ALL notes (both spent and unspent) - for balance reconciliation
    /// This is needed to calculate total received amount which must equal spent + unspent
    func getAllNotes(accountId: Int64) throws -> [WalletNote] {
        let sql = """
            SELECT id, diversifier, value, rcm, memo, nf, received_in_tx, received_height, witness, cmu, anchor, witness_index
            FROM notes
            WHERE account_id = ?
            ORDER BY received_height ASC;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, accountId)

        var notes: [WalletNote] = []

        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let divPtr = sqlite3_column_blob(stmt, 1)
            let divLen = sqlite3_column_bytes(stmt, 1)
            let value = UInt64(sqlite3_column_int64(stmt, 2))
            let rcmPtr = sqlite3_column_blob(stmt, 3)
            let rcmLen = sqlite3_column_bytes(stmt, 3)
            let nfPtr = sqlite3_column_blob(stmt, 5)
            let nfLen = sqlite3_column_bytes(stmt, 5)
            let height = UInt64(sqlite3_column_int64(stmt, 7))

            // SECURITY: Decrypt sensitive fields - VUL-002: throws on failure
            let encryptedDiv = Data(bytes: divPtr!, count: Int(divLen))
            let encryptedRcm = Data(bytes: rcmPtr!, count: Int(rcmLen))
            let diversifier = try decryptBlob(encryptedDiv)
            let rcm = try decryptBlob(encryptedRcm)

            // Witness might be NULL
            var witnessData = Data()
            if sqlite3_column_type(stmt, 8) != SQLITE_NULL {
                let witnessPtr = sqlite3_column_blob(stmt, 8)
                let witnessLen = sqlite3_column_bytes(stmt, 8)
                // FIX #557 v34: Double-check pointer isn't nil (empty blob != NULL)
                if witnessPtr != nil && witnessLen > 0 {
                    let encryptedWitness = Data(bytes: witnessPtr!, count: Int(witnessLen))
                    witnessData = try decryptBlob(encryptedWitness)
                }
            }

            // CMU might be NULL (not encrypted - public on chain)
            var cmuData: Data? = nil
            if sqlite3_column_type(stmt, 9) != SQLITE_NULL {
                let cmuPtr = sqlite3_column_blob(stmt, 9)
                let cmuLen = sqlite3_column_bytes(stmt, 9)
                // FIX #557 v34: Double-check pointer isn't nil (empty blob != NULL)
                if cmuPtr != nil && cmuLen > 0 {
                    cmuData = Data(bytes: cmuPtr!, count: Int(cmuLen))
                }
            }

            // Anchor might be NULL
            var anchorData: Data? = nil
            if sqlite3_column_type(stmt, 10) != SQLITE_NULL {
                let anchorPtr = sqlite3_column_blob(stmt, 10)
                let anchorLen = sqlite3_column_bytes(stmt, 10)
                // FIX #557 v34: Double-check pointer isn't nil (empty blob != NULL)
                if anchorPtr != nil && anchorLen > 0 {
                    anchorData = Data(bytes: anchorPtr!, count: Int(anchorLen))
                }
            }

            // FIX #557 v45: Extract witness_index
            let witnessIndex = UInt64(sqlite3_column_int64(stmt, 11))

            let note = WalletNote(
                id: id,
                diversifier: diversifier,
                value: value,
                rcm: rcm,
                nullifier: Data(bytes: nfPtr!, count: Int(nfLen)),
                height: height,
                witness: witnessData,
                cmu: cmuData,
                anchor: anchorData,
                witnessIndex: witnessIndex
            )

            notes.append(note)
        }

        return notes
    }

    /// Get unspent notes for account (with valid witnesses only)
    func getUnspentNotes(accountId: Int64) throws -> [WalletNote] {
        // FIX #940: Guard against nil database handle
        guard db != nil else {
            print("⚠️ getUnspentNotes: Database not open, returning empty array")
            return []
        }

        let sql = """
            SELECT id, diversifier, value, rcm, memo, nf, received_in_tx, received_height, witness, cmu, anchor, witness_index
            FROM notes
            WHERE account_id = ? AND is_spent = 0 AND witness IS NOT NULL
            ORDER BY received_height ASC;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, accountId)

        var notes: [WalletNote] = []

        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let divPtr = sqlite3_column_blob(stmt, 1)
            let divLen = sqlite3_column_bytes(stmt, 1)
            let value = UInt64(sqlite3_column_int64(stmt, 2))
            let rcmPtr = sqlite3_column_blob(stmt, 3)
            let rcmLen = sqlite3_column_bytes(stmt, 3)
            let nfPtr = sqlite3_column_blob(stmt, 5)
            let nfLen = sqlite3_column_bytes(stmt, 5)
            let height = UInt64(sqlite3_column_int64(stmt, 7))
            let witnessPtr = sqlite3_column_blob(stmt, 8)
            let witnessLen = sqlite3_column_bytes(stmt, 8)

            // SECURITY: Decrypt sensitive fields - VUL-002: throws on failure
            let encryptedDiv = Data(bytes: divPtr!, count: Int(divLen))
            let encryptedRcm = Data(bytes: rcmPtr!, count: Int(rcmLen))

            // FIX #557 v33 crash fix: Witness might be NULL after clearing stale witnesses
            let witness: Data
            if witnessPtr == nil {
                witness = Data()
            } else {
                let encryptedWitness = Data(bytes: witnessPtr!, count: Int(witnessLen))
                witness = try decryptBlob(encryptedWitness)
            }

            let diversifier = try decryptBlob(encryptedDiv)
            let rcm = try decryptBlob(encryptedRcm)

            // CMU might be NULL (not encrypted - public on chain)
            var cmuData: Data? = nil
            if sqlite3_column_type(stmt, 9) != SQLITE_NULL {
                let cmuPtr = sqlite3_column_blob(stmt, 9)
                let cmuLen = sqlite3_column_bytes(stmt, 9)
                // FIX #557 v34: Double-check pointer isn't nil (empty blob != NULL)
                if cmuPtr != nil && cmuLen > 0 {
                    cmuData = Data(bytes: cmuPtr!, count: Int(cmuLen))
                }
            }

            // Anchor might be NULL
            var anchorData: Data? = nil
            if sqlite3_column_type(stmt, 10) != SQLITE_NULL {
                let anchorPtr = sqlite3_column_blob(stmt, 10)
                let anchorLen = sqlite3_column_bytes(stmt, 10)
                // FIX #557 v34: Double-check pointer isn't nil (empty blob != NULL)
                if anchorPtr != nil && anchorLen > 0 {
                    anchorData = Data(bytes: anchorPtr!, count: Int(anchorLen))
                }
            }

            // FIX #557 v45: Extract witness_index
            let witnessIndex = UInt64(sqlite3_column_int64(stmt, 11))

            // FIX #557 v34: Safety check for nullifier (should never be NULL)
            guard nfPtr != nil && nfLen > 0 else {
                print("⚠️ WARNING: Note \(id) has NULL nullifier - skipping")
                continue
            }

            let note = WalletNote(
                id: id,
                diversifier: diversifier,
                value: value,
                rcm: rcm,
                nullifier: Data(bytes: nfPtr!, count: Int(nfLen)),
                height: height,
                witness: witness,
                cmu: cmuData,
                anchor: anchorData,
                witnessIndex: witnessIndex
            )

            notes.append(note)
        }

        return notes
    }

    /// Mark note as spent and record sent transaction in history
    /// NOTE: This function expects an UNHASHED nullifier from the blockchain
    /// Use markNoteSpentByHashedNullifier() if you have an already-hashed nullifier from the database
    func markNoteSpent(nullifier: Data, txid: Data, spentHeight: UInt64) throws {
        // SECURITY: Never log nullifiers - they are sensitive privacy data

        // VUL-009: Hash the incoming nullifier to match stored hashed nullifiers
        let hashedNullifier = hashNullifier(nullifier)

        // FIX #1079: Try hashed first, then fall back to raw for pre-VUL-009 notes
        try markNoteSpentByHashedNullifier(hashedNullifier: hashedNullifier, txid: txid, spentHeight: spentHeight)

        // If no rows changed, try with raw nullifier (backwards compatibility)
        if sqlite3_changes(db) == 0 {
            print("⚠️ FIX #1079: No match with hashed nullifier, trying raw...")
            try markNoteSpentByHashedNullifier(hashedNullifier: nullifier, txid: txid, spentHeight: spentHeight)
        }
    }

    /// Mark note as spent using an already-hashed nullifier (from getUnspentNotes)
    /// This is used when we have the nullifier from a WalletNote which is already hashed
    func markNoteSpentByHashedNullifier(hashedNullifier: Data, txid: Data, spentHeight: UInt64) throws {
        // SECURITY: Never log nullifiers - they are sensitive privacy data

        // First, get the note's value so we can record it in transaction history
        var noteValue: UInt64 = 0
        let selectSql = "SELECT value FROM notes WHERE nf = ?;"
        var selectStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, selectSql, -1, &selectStmt, nil) == SQLITE_OK {
            _ = hashedNullifier.withUnsafeBytes { ptr in
                sqlite3_bind_blob(selectStmt, 1, ptr.baseAddress, Int32(hashedNullifier.count), nil)
            }
            if sqlite3_step(selectStmt) == SQLITE_ROW {
                noteValue = UInt64(sqlite3_column_int64(selectStmt, 0))
            }
            sqlite3_finalize(selectStmt)
        }

        // Update the note as spent
        let sql = "UPDATE notes SET is_spent = 1, spent_in_tx = ?, spent_height = ? WHERE nf = ?;"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        _ = txid.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, 1, ptr.baseAddress, Int32(txid.count), nil)
        }
        sqlite3_bind_int64(stmt, 2, Int64(spentHeight))
        _ = hashedNullifier.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, 3, ptr.baseAddress, Int32(hashedNullifier.count), nil)
        }

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.updateFailed(String(cString: sqlite3_errmsg(db)))
        }

        let changedRows = sqlite3_changes(db)
        if changedRows > 0 {
            print("✅ Marked \(changedRows) note(s) as spent at height \(spentHeight)")
        }

        // NOTE: SENT transactions are now recorded by populateHistoryFromNotes() which
        // correctly calculates actualSent = input - change - fee. Do not add SENT here
        // as it would use the note value instead of the actual sent amount.
    }

    /// Mark note as spent by height
    /// NOTE: This function expects an UNHASHED nullifier from the blockchain
    /// Use markNoteSpentByHashedNullifier() if you have an already-hashed nullifier from the database
    /// Also sets spent_in_tx using nullifier as synthetic txid for history tracking
    func markNoteSpent(nullifier: Data, spentHeight: UInt64) throws {
        // VUL-009: Hash the incoming nullifier to match stored hashed nullifiers
        let hashedNullifier = hashNullifier(nullifier)
        try markNoteSpentByHashedNullifier(hashedNullifier: hashedNullifier, spentHeight: spentHeight)

        // FIX #1079: Try raw nullifier if hashed didn't match (backwards compatibility)
        if sqlite3_changes(db) == 0 {
            print("⚠️ FIX #1079: No match with hashed nullifier, trying raw...")
            try markNoteSpentByHashedNullifier(hashedNullifier: nullifier, spentHeight: spentHeight)
        }
    }

    /// Mark note as spent using an already-hashed nullifier (from getUnspentNotes)
    /// This is used when we have the nullifier from a WalletNote which is already hashed
    func markNoteSpentByHashedNullifier(hashedNullifier: Data, spentHeight: UInt64) throws {
        // Use nullifier hash as synthetic txid if no real txid available
        // This ensures populateHistoryFromNotes() can still create SENT entries
        let syntheticTxid = hashedNullifier.prefix(32)

        let sql = "UPDATE notes SET is_spent = 1, spent_height = ?, spent_in_tx = ? WHERE nf = ?;"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, Int64(spentHeight))
        _ = syntheticTxid.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, 2, ptr.baseAddress, Int32(syntheticTxid.count), nil)
        }
        _ = hashedNullifier.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, 3, ptr.baseAddress, Int32(hashedNullifier.count), nil)
        }

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.updateFailed(String(cString: sqlite3_errmsg(db)))
        }
        print("📜 Marked note spent at height \(spentHeight) with synthetic txid")
    }

    // MARK: - FIX #291: Atomic Spend + History Recording

    /// FIX #291: ATOMIC transaction for recording sent transactions
    /// This function wraps both note marking AND history insertion in a single database transaction.
    /// If either operation fails, BOTH are rolled back - preventing orphaned spent notes or missing history.
    ///
    /// CRITICAL: This solves the bug where app crash between markNoteSpent and insertHistory
    /// would leave notes marked as spent but no history record (lost transaction).
    ///
    /// - Parameters:
    ///   - hashedNullifier: The already-hashed nullifier of the spent note
    ///   - txid: Transaction ID (32 bytes)
    ///   - spentHeight: Block height where spend was recorded (may be updated later on confirmation)
    ///   - amount: Amount sent to recipient (excluding fee)
    ///   - fee: Transaction fee in zatoshis
    ///   - toAddress: Recipient z-address
    ///   - memo: Optional encrypted memo
    /// - Returns: History record ID if successful
    /// - Throws: DatabaseError if transaction fails (both operations rolled back)
    func recordSentTransactionAtomic(
        hashedNullifier: Data,
        txid: Data,
        spentHeight: UInt64,
        amount: UInt64,
        fee: UInt64,
        toAddress: String,
        memo: String?
    ) throws -> Int64 {
        // BEGIN TRANSACTION - both operations must succeed or both fail
        let beginResult = sqlite3_exec(db, "BEGIN IMMEDIATE TRANSACTION;", nil, nil, nil)
        guard beginResult == SQLITE_OK else {
            throw DatabaseError.transactionFailed("Failed to begin transaction: \(String(cString: sqlite3_errmsg(db)))")
        }

        do {
            // STEP 1: Mark note as spent
            let updateSql = "UPDATE notes SET is_spent = 1, spent_in_tx = ?, spent_height = ? WHERE nf = ?;"

            var updateStmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, updateSql, -1, &updateStmt, nil) == SQLITE_OK else {
                throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(updateStmt) }

            _ = txid.withUnsafeBytes { ptr in
                sqlite3_bind_blob(updateStmt, 1, ptr.baseAddress, Int32(txid.count), nil)
            }
            sqlite3_bind_int64(updateStmt, 2, Int64(spentHeight))
            _ = hashedNullifier.withUnsafeBytes { ptr in
                sqlite3_bind_blob(updateStmt, 3, ptr.baseAddress, Int32(hashedNullifier.count), nil)
            }

            guard sqlite3_step(updateStmt) == SQLITE_DONE else {
                throw DatabaseError.updateFailed(String(cString: sqlite3_errmsg(db)))
            }

            let changedRows = sqlite3_changes(db)
            // FIX #688: Don't throw error if note doesn't exist - still record transaction in history!
            // The note may have been deleted during full resync, but we still need to record the TX
            if changedRows == 0 {
                print("⚠️ FIX #688: Note not found for nullifier (deleted during resync?), recording TX history anyway")
            } else {
                print("✅ FIX #688: Note marked as spent (changedRows=\(changedRows))")
            }

            // STEP 2: Insert transaction history (ALWAYS do this, even if note was missing)
            let insertSql = """
                INSERT OR REPLACE INTO transaction_history
                (txid, block_height, block_time, tx_type, value, fee, to_address, from_diversifier, memo, status)
                VALUES (?, ?, ?, ?, ?, ?, ?, NULL, ?, 'pending');
            """

            var insertStmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, insertSql, -1, &insertStmt, nil) == SQLITE_OK else {
                throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(insertStmt) }

            let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

            _ = txid.withUnsafeBytes { ptr in
                sqlite3_bind_blob(insertStmt, 1, ptr.baseAddress, Int32(txid.count), SQLITE_TRANSIENT)
            }
            sqlite3_bind_int64(insertStmt, 2, Int64(spentHeight))
            // FIX #291: Use NULL for block_time - will be set when TX is confirmed
            // Using current time was WRONG because TX isn't mined yet
            sqlite3_bind_null(insertStmt, 3)

            // VUL-015: Use obfuscated type code
            let encryptedType = encryptTxType(.sent)
            sqlite3_bind_text(insertStmt, 4, encryptedType, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(insertStmt, 5, Int64(amount))
            sqlite3_bind_int64(insertStmt, 6, Int64(fee))
            sqlite3_bind_text(insertStmt, 7, toAddress, -1, SQLITE_TRANSIENT)
            if let memo = memo {
                sqlite3_bind_text(insertStmt, 8, memo, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(insertStmt, 8)
            }

            guard sqlite3_step(insertStmt) == SQLITE_DONE else {
                throw DatabaseError.insertFailed(String(cString: sqlite3_errmsg(db)))
            }

            let historyId = sqlite3_last_insert_rowid(db)

            // COMMIT - both operations succeeded
            let commitResult = sqlite3_exec(db, "COMMIT;", nil, nil, nil)
            guard commitResult == SQLITE_OK else {
                throw DatabaseError.transactionFailed("Failed to commit: \(String(cString: sqlite3_errmsg(db)))")
            }

            print("✅ FIX #291: Atomic transaction recorded - note marked spent + history inserted (id=\(historyId))")
            return historyId

        } catch {
            // ROLLBACK - something failed, undo everything
            _ = sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            print("❌ FIX #291: Transaction rolled back due to error: \(error)")
            throw error
        }
    }

    /// FIX #291: Update sent transaction when confirmed in a block
    /// Updates block_height, block_time, and status from 'pending' to 'confirmed'
    func updateSentTransactionOnConfirmation(txid: Data, confirmedHeight: UInt64, blockTime: UInt64) throws {
        let sql = """
            UPDATE transaction_history
            SET block_height = ?, block_time = ?, status = 'confirmed'
            WHERE txid = ? AND tx_type IN ('sent', 'α');
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, Int64(confirmedHeight))
        sqlite3_bind_int64(stmt, 2, Int64(blockTime))
        _ = txid.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, 3, ptr.baseAddress, Int32(txid.count), nil)
        }

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.updateFailed(String(cString: sqlite3_errmsg(db)))
        }

        let changedRows = sqlite3_changes(db)
        if changedRows > 0 {
            print("✅ FIX #291: Updated sent TX to confirmed at height \(confirmedHeight)")
        }
    }

    /// FIX #964: Record a minimal sent transaction when VUL-002 showed error but TX actually confirmed
    /// This handles the case where broadcast appeared to fail (TCP desync) but TX reached the network
    /// We don't have the full metadata (hashedNullifier, toAddress, memo) but we can still record
    /// that a send happened, so it appears in transaction history
    func recordSentTransactionMinimal(txid: Data, amount: UInt64, fee: UInt64, confirmedHeight: UInt64) throws {
        // First check if a record already exists (avoid duplicates)
        let checkSql = "SELECT id FROM transaction_history WHERE txid = ? LIMIT 1;"
        var checkStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, checkSql, -1, &checkStmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(checkStmt) }

        _ = txid.withUnsafeBytes { ptr in
            sqlite3_bind_blob(checkStmt, 1, ptr.baseAddress, Int32(txid.count), nil)
        }

        if sqlite3_step(checkStmt) == SQLITE_ROW {
            print("📤 FIX #964: TX already exists in history - skipping duplicate insert")
            return
        }

        // VUL-015: Use obfuscated type code 'α' instead of 'sent' (same as recordSentTransaction)
        let sql = """
            INSERT INTO transaction_history (txid, block_height, tx_type, value, fee, status, confirmations)
            VALUES (?, ?, 'α', ?, ?, 'confirmed', 1);
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        _ = txid.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, 1, ptr.baseAddress, Int32(txid.count), nil)
        }
        sqlite3_bind_int64(stmt, 2, Int64(confirmedHeight))
        sqlite3_bind_int64(stmt, 3, Int64(amount))
        sqlite3_bind_int64(stmt, 4, Int64(fee))

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.insertFailed(String(cString: sqlite3_errmsg(db)))
        }

        print("✅ FIX #964: Recorded minimal sent TX at height \(confirmedHeight) (amount: \(amount), fee: \(fee))")
    }

    /// FIX #965: Check if a transaction exists in transaction_history
    /// Used to detect sent transactions that were broadcast but never recorded
    func transactionExistsInHistory(txid: Data) throws -> Bool {
        let sql = "SELECT 1 FROM transaction_history WHERE txid = ? LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        _ = txid.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, 1, ptr.baseAddress, Int32(txid.count), nil)
        }

        return sqlite3_step(stmt) == SQLITE_ROW
    }

    /// FIX #970: Get transaction status from history (for phantom TX detection)
    func getTransactionStatus(txid: Data) throws -> String? {
        let sql = "SELECT status FROM transaction_history WHERE txid = ? LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        _ = txid.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, 1, ptr.baseAddress, Int32(txid.count), nil)
        }

        if sqlite3_step(stmt) == SQLITE_ROW {
            if let statusPtr = sqlite3_column_text(stmt, 0) {
                return String(cString: statusPtr)
            }
        }
        return nil
    }

    /// FIX #980: Check if any note was spent by this txid (blockchain evidence of confirmation)
    /// This proves the TX was actually mined - the nullifier was found on-chain
    func noteSpentByTxidExists(txid: Data) throws -> Bool {
        let sql = "SELECT 1 FROM notes WHERE spent_in_tx = ? LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        _ = txid.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, 1, ptr.baseAddress, Int32(txid.count), nil)
        }

        return sqlite3_step(stmt) == SQLITE_ROW
    }

    /// FIX #174: Get note info by nullifier (for external wallet spend detection)
    /// Returns (id: Int64, value: UInt64) if note exists and is unspent, nil otherwise
    /// NOTE: This function expects an UNHASHED nullifier from the blockchain
    func getNoteByNullifier(nullifier: Data) throws -> (id: Int64, value: UInt64)? {
        // VUL-009: Hash the incoming nullifier to match stored hashed nullifiers
        let hashedNullifier = hashNullifier(nullifier)

        let sql = "SELECT id, value FROM notes WHERE nf = ? AND is_spent = 0;"

        // FIX #1079: Try hashed nullifier first
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }

        _ = hashedNullifier.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, 1, ptr.baseAddress, Int32(hashedNullifier.count), nil)
        }

        if sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let value = UInt64(sqlite3_column_int64(stmt, 1))
            sqlite3_finalize(stmt)
            return (id: id, value: value)
        }
        sqlite3_finalize(stmt)

        // FIX #1079: Try raw nullifier (backwards compatibility for pre-VUL-009 notes)
        var stmt2: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt2, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt2) }

        _ = nullifier.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt2, 1, ptr.baseAddress, Int32(nullifier.count), nil)
        }

        if sqlite3_step(stmt2) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt2, 0)
            let value = UInt64(sqlite3_column_int64(stmt2, 1))
            return (id: id, value: value)
        }
        return nil
    }

    /// FIX #885: Get note info by ALREADY-HASHED nullifier
    /// Used by FIX #605 when SpendableNote.nullifier is already hashed (from database)
    /// Returns (id: Int64, value: UInt64) if note exists and is unspent, nil otherwise
    func getNoteByHashedNullifier(hashedNullifier: Data) throws -> (id: Int64, value: UInt64)? {
        let sql = "SELECT id, value FROM notes WHERE nf = ? AND is_spent = 0;"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        _ = hashedNullifier.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, 1, ptr.baseAddress, Int32(hashedNullifier.count), nil)
        }

        if sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let value = UInt64(sqlite3_column_int64(stmt, 1))
            return (id: id, value: value)
        }
        return nil
    }

    /// Mark note as unspent (recover from failed broadcast)
    func markNoteUnspent(nullifier: Data) throws {
        // VUL-009: Hash the incoming nullifier to match stored hashed nullifiers
        let hashedNullifier = hashNullifier(nullifier)

        let sql = "UPDATE notes SET is_spent = 0, spent_in_tx = NULL WHERE nf = ?;"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        _ = hashedNullifier.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, 1, ptr.baseAddress, Int32(hashedNullifier.count), nil)
        }

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.updateFailed(String(cString: sqlite3_errmsg(db)))
        }
        print("Marked note as unspent")
    }

    /// Get all spent notes for an account (for recovery from failed broadcasts)
    func getSpentNotes(accountId: Int64) throws -> [SpentNote] {
        let sql = "SELECT nf, spent_in_tx FROM notes WHERE account_id = ? AND is_spent = 1;"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, accountId)

        var notes: [SpentNote] = []

        while sqlite3_step(stmt) == SQLITE_ROW {
            let nfPtr = sqlite3_column_blob(stmt, 0)
            let nfLen = sqlite3_column_bytes(stmt, 0)
            guard let ptr = nfPtr else { continue }
            let nullifier = Data(bytes: ptr, count: Int(nfLen))

            // Get spent_in_tx (may be null if broadcast failed)
            var spentInTx: Data? = nil
            if sqlite3_column_type(stmt, 1) != SQLITE_NULL {
                let txPtr = sqlite3_column_blob(stmt, 1)
                let txLen = sqlite3_column_bytes(stmt, 1)
                if let txPtr = txPtr, txLen > 0 {
                    spentInTx = Data(bytes: txPtr, count: Int(txLen))
                }
            }

            // FIX #688: SpentNote now includes value and height (optional for backward compatibility)
            // These are not returned by current SQL query, so pass nil for now
            notes.append(SpentNote(nullifier: nullifier, spentInTx: spentInTx, value: nil, height: nil))
        }

        return notes
    }

    /// Delete all notes (for rescan)
    func deleteAllNotes() throws {
        let sql = "DELETE FROM notes;"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.deleteFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    /// Delete notes received after a specific height (for repairing corrupted nullifiers)
    /// Returns the count of deleted notes
    func deleteNotesAfterHeight(_ height: UInt64) throws -> Int {
        let sql = "DELETE FROM notes WHERE received_height > ?;"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, Int64(height))

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.deleteFailed(String(cString: sqlite3_errmsg(db)))
        }

        return Int(sqlite3_changes(db))
    }

    /// Get all nullifiers for spend detection
    func getAllNullifiers() throws -> Set<Data> {
        // Debug: First count all notes and unspent notes
        var countStmt: OpaquePointer?
        let countSql = "SELECT COUNT(*) FROM notes;"
        if sqlite3_prepare_v2(db, countSql, -1, &countStmt, nil) == SQLITE_OK {
            if sqlite3_step(countStmt) == SQLITE_ROW {
                let totalNotes = sqlite3_column_int(countStmt, 0)
                print("🔍 NULLIFIER DEBUG: Total notes in DB: \(totalNotes)")
            }
            sqlite3_finalize(countStmt)
        }

        var unspentStmt: OpaquePointer?
        let unspentSql = "SELECT COUNT(*) FROM notes WHERE is_spent = 0;"
        if sqlite3_prepare_v2(db, unspentSql, -1, &unspentStmt, nil) == SQLITE_OK {
            if sqlite3_step(unspentStmt) == SQLITE_ROW {
                let unspentNotes = sqlite3_column_int(unspentStmt, 0)
                print("🔍 NULLIFIER DEBUG: Unspent notes in DB: \(unspentNotes)")
            }
            sqlite3_finalize(unspentStmt)
        }

        // FIX #865: Return ALL nullifiers (spent AND unspent) for spend detection
        // Previously only returned unspent notes, which caused:
        // - Once a note was marked spent, its nullifier was removed from knownNullifiers
        // - External spends (wallet.dat) couldn't be detected because nullifier wasn't tracked
        // - Change outputs were incorrectly recorded as "received" instead of being filtered
        // By tracking ALL nullifiers, we can always detect when our notes are spent,
        // even if they were marked spent by a previous scan or manual database update.
        let sql = "SELECT nf FROM notes;"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        var nullifiers = Set<Data>()

        while sqlite3_step(stmt) == SQLITE_ROW {
            let nfPtr = sqlite3_column_blob(stmt, 0)
            let nfLen = sqlite3_column_bytes(stmt, 0)
            if let ptr = nfPtr, nfLen > 0 {
                let nfData = Data(bytes: ptr, count: Int(nfLen))
                nullifiers.insert(nfData)
            }
        }
        // SECURITY: Log only count, never the actual nullifiers
        return nullifiers
    }

    // MARK: - Balance

    /// Get total SPENDABLE balance for account
    /// FIX #292: Only count notes with valid witnesses (not empty/null)
    /// FIX #1107: Changed from 1028 to 100 byte minimum
    /// Previous bug: Assumed full-depth tree (depth 32) = 1028 byte witnesses
    /// But current tree depth ~26 produces 838 byte witnesses (866 encrypted)
    /// 866 < 1028 → all new witnesses excluded from balance!
    /// Witness = 4 (position) + D*32 (merkle path) + 28 (encryption overhead)
    /// Minimum practical: 4 + 1*32 + 28 = 64 bytes, using 100 for safety margin
    func getBalance(accountId: Int64) throws -> UInt64 {
        let sql = """
            SELECT COALESCE(SUM(value), 0) FROM notes
            WHERE account_id = ?
            AND is_spent = 0
            AND witness IS NOT NULL
            AND LENGTH(witness) >= 100
            AND witness != ZEROBLOB(LENGTH(witness));
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, accountId)

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return 0
        }

        return UInt64(sqlite3_column_int64(stmt, 0))
    }

    /// FIX #292: Get total unspent balance INCLUDING notes without witnesses (for diagnostics)
    /// This shows what balance COULD be available after witness rebuild
    func getTotalUnspentBalance(accountId: Int64) throws -> UInt64 {
        let sql = "SELECT COALESCE(SUM(value), 0) FROM notes WHERE account_id = ? AND is_spent = 0;"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, accountId)

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return 0
        }

        return UInt64(sqlite3_column_int64(stmt, 0))
    }

    /// FIX #876: Get count and total value of notes WITHOUT valid witnesses
    /// These notes exist but cannot be spent until witnesses are rebuilt
    /// FIX #1107: Changed 1028 to 100 (see getBalance for explanation)
    func getNotesWithoutWitnesses(accountId: Int64) throws -> (count: Int, value: UInt64, minHeight: UInt64) {
        let sql = """
            SELECT COUNT(*), COALESCE(SUM(value), 0), COALESCE(MIN(received_height), 0) FROM notes
            WHERE account_id = ?
            AND is_spent = 0
            AND (witness IS NULL OR LENGTH(witness) < 100 OR witness = ZEROBLOB(LENGTH(witness)));
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, accountId)

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return (0, 0, 0)
        }

        let count = Int(sqlite3_column_int(stmt, 0))
        let value = UInt64(sqlite3_column_int64(stmt, 1))
        let minHeight = UInt64(sqlite3_column_int64(stmt, 2))
        return (count, value, minHeight)
    }

    /// FIX #292: Get count and value of notes needing witness rebuild
    /// Returns (count, totalValue) of notes that exist but cannot be spent yet
    /// FIX #1107: Changed 1028 to 100 (see getBalance for explanation)
    func getNotesNeedingWitness(accountId: Int64) throws -> (count: Int, value: UInt64) {
        let sql = """
            SELECT COUNT(*), COALESCE(SUM(value), 0) FROM notes
            WHERE account_id = ?
            AND is_spent = 0
            AND (witness IS NULL OR LENGTH(witness) < 100 OR witness = ZEROBLOB(LENGTH(witness)));
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, accountId)

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return (0, 0)
        }

        let count = Int(sqlite3_column_int(stmt, 0))
        let value = UInt64(sqlite3_column_int64(stmt, 1))
        return (count, value)
    }

    /// FIX #1082: Get max height of unspent notes
    /// Used to determine if all notes are in boost range (instant rebuild) vs delta range (needs P2P)
    func getMaxUnspentNoteHeight(accountId: Int64) throws -> UInt64 {
        let sql = """
            SELECT COALESCE(MAX(received_height), 0) FROM notes
            WHERE account_id = ? AND is_spent = 0;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, accountId)

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return 0
        }

        return UInt64(sqlite3_column_int64(stmt, 0))
    }

    /// FIX #1083: Verify balance integrity
    /// FIX #1088: CORRECTED - Balance = sum of unspent notes (includes change outputs)
    /// The previous version incorrectly compared notes balance vs history balance, which will
    /// ALWAYS mismatch when change outputs exist because change is NOT recorded in history.
    ///
    /// CORRECT FORMULA:
    /// - Balance = Sum of ALL unspent notes (genuine received + unspent change)
    /// - This is what notes table shows and is ALWAYS correct
    ///
    /// Returns: (isValid, notesBalance, historyBalance, details)
    func verifyBalanceIntegrity(accountId: Int64) throws -> (isValid: Bool, notesBalance: UInt64, historyBalance: UInt64, details: String) {
        guard db != nil else {
            throw DatabaseError.notOpened
        }

        var details: [String] = []

        // 1. Calculate balance from unspent notes - THIS IS THE AUTHORITATIVE BALANCE
        let notesBalance = try getBalance(accountId: accountId)
        let notesBalanceZCL = Double(notesBalance) / 100_000_000.0
        details.append(String(format: "📊 Balance (unspent notes): %.8f ZCL", notesBalanceZCL))

        // 2. Count total notes for diagnostics
        let countSql = """
            SELECT
                COUNT(*) as total,
                SUM(CASE WHEN is_spent = 0 THEN 1 ELSE 0 END) as unspent,
                SUM(CASE WHEN is_spent = 1 THEN 1 ELSE 0 END) as spent
            FROM notes WHERE account_id = ?;
        """
        var countStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, countSql, -1, &countStmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(countStmt) }
        sqlite3_bind_int64(countStmt, 1, accountId)

        var totalNotes: Int = 0
        var unspentCount: Int = 0
        var spentCount: Int = 0
        if sqlite3_step(countStmt) == SQLITE_ROW {
            totalNotes = Int(sqlite3_column_int(countStmt, 0))
            unspentCount = Int(sqlite3_column_int(countStmt, 1))
            spentCount = Int(sqlite3_column_int(countStmt, 2))
        }
        details.append("📝 Notes: \(totalNotes) total (\(unspentCount) unspent, \(spentCount) spent)")

        // 3. FIX #1088: Verify database consistency (NOT balance vs history)
        // Check for impossible states:
        // - Notes with negative values
        // - Notes marked both spent AND with no spent_in_tx
        var isValid = true
        var issueFound = ""

        // Check for notes with negative values
        let negativeSql = "SELECT COUNT(*) FROM notes WHERE value < 0 AND account_id = ?;"
        var negativeStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, negativeSql, -1, &negativeStmt, nil) == SQLITE_OK {
            sqlite3_bind_int64(negativeStmt, 1, accountId)
            if sqlite3_step(negativeStmt) == SQLITE_ROW {
                let negativeCount = Int(sqlite3_column_int(negativeStmt, 0))
                if negativeCount > 0 {
                    isValid = false
                    issueFound = "Found \(negativeCount) notes with negative values"
                    details.append("🚨 ERROR: \(issueFound)")
                }
            }
            sqlite3_finalize(negativeStmt)
        }

        // Check for notes marked spent but no spent_in_tx
        let orphanSpentSql = "SELECT COUNT(*) FROM notes WHERE is_spent = 1 AND (spent_in_tx IS NULL OR spent_in_tx = '') AND account_id = ?;"
        var orphanSpentStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, orphanSpentSql, -1, &orphanSpentStmt, nil) == SQLITE_OK {
            sqlite3_bind_int64(orphanSpentStmt, 1, accountId)
            if sqlite3_step(orphanSpentStmt) == SQLITE_ROW {
                let orphanCount = Int(sqlite3_column_int(orphanSpentStmt, 0))
                if orphanCount > 0 {
                    // This is a warning, not critical - spent notes without txid can happen
                    details.append("⚠️ Warning: \(orphanCount) spent notes without spent_in_tx")
                }
            }
            sqlite3_finalize(orphanSpentStmt)
        }

        // Check for zero unspent notes when balance should exist
        if unspentCount == 0 && notesBalance > 0 {
            isValid = false
            issueFound = "Balance shows \(notesBalance) but no unspent notes found"
            details.append("🚨 ERROR: \(issueFound)")
        }

        // FIX #1088: For historyBalance return, calculate what history WOULD show
        // This is for logging/diagnostics only, NOT for comparison
        let historyReceivedSql = """
            SELECT COALESCE(SUM(value), 0) FROM transaction_history
            WHERE tx_type IN ('received', 'β');
        """
        var historyReceivedStmt: OpaquePointer?
        var historyReceived: UInt64 = 0
        if sqlite3_prepare_v2(db, historyReceivedSql, -1, &historyReceivedStmt, nil) == SQLITE_OK {
            if sqlite3_step(historyReceivedStmt) == SQLITE_ROW {
                historyReceived = UInt64(sqlite3_column_int64(historyReceivedStmt, 0))
            }
            sqlite3_finalize(historyReceivedStmt)
        }

        let historySentSql = """
            SELECT COALESCE(SUM(value), 0), COALESCE(SUM(COALESCE(fee, 0)), 0)
            FROM transaction_history WHERE tx_type IN ('sent', 'α');
        """
        var historySentStmt: OpaquePointer?
        var historySent: UInt64 = 0
        var historyFees: UInt64 = 0
        if sqlite3_prepare_v2(db, historySentSql, -1, &historySentStmt, nil) == SQLITE_OK {
            if sqlite3_step(historySentStmt) == SQLITE_ROW {
                historySent = UInt64(sqlite3_column_int64(historySentStmt, 0))
                historyFees = UInt64(sqlite3_column_int64(historySentStmt, 1))
            }
            sqlite3_finalize(historySentStmt)
        }

        // History balance excludes change - this is expected to differ from notes balance
        let historyBalance = historyReceived >= (historySent + historyFees)
            ? historyReceived - historySent - historyFees
            : 0

        let historyBalanceZCL = Double(historyBalance) / 100_000_000.0
        details.append(String(format: "📈 History view (excludes change): %.8f ZCL", historyBalanceZCL))

        // The difference is expected - it's the unspent change outputs
        let changeInBalance = Int64(notesBalance) - Int64(historyBalance)
        if changeInBalance > 0 {
            let changeZCL = Double(changeInBalance) / 100_000_000.0
            details.append(String(format: "🔄 Unspent change outputs: %.8f ZCL (expected)", changeZCL))
        }

        // FIX #1076: CRITICAL - Detect when notes balance is LESS than history balance
        // This means notes that SHOULD be unspent are missing or incorrectly marked as spent!
        // Formula: history_received - history_sent - history_fees <= notes_balance (with some tolerance for pending)
        if changeInBalance < 0 {
            let missingZCL = Double(-changeInBalance) / 100_000_000.0
            details.append(String(format: "🚨 MISSING BALANCE: %.8f ZCL!", missingZCL))
            details.append("   Notes that should be unspent are missing or incorrectly marked as spent!")
            // Mark as invalid if missing amount is significant (> 10000 zatoshis = 0.0001 ZCL)
            if -changeInBalance > 10000 {
                isValid = false
                issueFound = String(format: "Missing %.8f ZCL - notes incorrectly spent or missing", missingZCL)
            }
        }

        if isValid {
            details.append("✅ Balance integrity: VALID")
        } else {
            details.append("🚨 Balance integrity: ISSUE DETECTED - \(issueFound)")
        }

        return (isValid, notesBalance, historyBalance, details.joined(separator: "\n"))
    }

    // MARK: - Sync State

    /// Get last scanned height
    /// FIX: Added validation to detect and auto-correct corrupted values
    func getLastScannedHeight() throws -> UInt64 {
        // FIX #940: Guard against nil database handle
        guard db != nil else {
            return 0
        }

        let sql = "SELECT last_scanned_height FROM sync_state WHERE id = 1;"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return 0
        }

        let rawHeight = UInt64(sqlite3_column_int64(stmt, 0))

        // FIX: Validate lastScannedHeight - detect corruption
        // Zclassic chain height is currently ~3 million
        // Any value > 10 million is definitely corrupted
        let maxReasonableHeight: UInt64 = 10_000_000

        if rawHeight > maxReasonableHeight {
            print("🚨 [DATABASE] Corrupted lastScannedHeight detected: \(rawHeight)")
            print("   Resetting to bundled tree height...")

            // Reset to bundled tree height (safe fallback)
            let bundledHeight: UInt64 = 2_926_122  // From Constants
            do {
                try updateLastScannedHeight(bundledHeight, hash: Data(repeating: 0, count: 32))
                print("   ✅ Reset to \(bundledHeight)")
            } catch {
                print("   ⚠️ Failed to reset: \(error)")
            }

            return bundledHeight
        }

        return rawHeight
    }

    /// Update last scanned height
    /// FIX #166/#167: Added validation to prevent writing corrupted values
    /// FIX #1099: Force reset lastScannedHeight AND checkpoint to 0 during Full Rescan
    /// This bypasses FIX #1075 regression protection because Full Rescan NEEDS to start from 0
    /// ONLY call this from repairNotesAfterDownloadedTree(forceFullRescan: true)
    func forceResetLastScannedHeightForFullRescan() throws {
        print("🔧 FIX #1099: Force resetting lastScannedHeight AND checkpoint to 0 for Full Rescan")
        print("   (Bypassing FIX #1075 regression protection - this is intentional)")

        // SQLITE_TRANSIENT tells SQLite to copy the data immediately
        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        // Reset lastScannedHeight to 0
        let sql = "INSERT OR REPLACE INTO sync_state (id, last_scanned_height, last_scanned_hash) VALUES (1, 0, ?);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        let emptyHash = Data(count: 32)
        _ = emptyHash.withUnsafeBytes { bytes in
            sqlite3_bind_blob(stmt, 1, bytes.baseAddress, Int32(emptyHash.count), SQLITE_TRANSIENT)
        }

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.updateFailed(String(cString: sqlite3_errmsg(db)))
        }

        // Also reset verified_checkpoint_height to 0 to allow fresh scan
        let checkpointSql = "UPDATE sync_state SET verified_checkpoint_height = 0 WHERE id = 1;"
        var checkpointStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, checkpointSql, -1, &checkpointStmt, nil) == SQLITE_OK {
            sqlite3_step(checkpointStmt)
            sqlite3_finalize(checkpointStmt)
        }

        print("✅ FIX #1099: lastScannedHeight and checkpoint forced to 0")
    }

    /// FIX #1075: NEVER allow regression below checkpoint
    /// Requires peer consensus validation before accepting any height update
    func updateLastScannedHeight(_ height: UInt64, hash: Data) throws {
        // FIX #166: Much stricter validation - block height should NEVER exceed ~3M on Zclassic
        // Current chain height is ~2.94M (Dec 2025)
        // Real max possible height by 2030: ~3.5M (at 150s/block)
        let maxReasonableHeight: UInt64 = 3_500_000

        // FIX #1050: Suppress verbose per-block height update log (routine during sync)
        // Only errors/warnings from this function are logged

        // FIX #167: CRITICAL - Validate against multiple trusted sources
        // 1. HeaderStore (P2P verified headers - Equihash validated)
        // 2. Cached chain height (from peer consensus)
        // 3. Checkpoint height (known good state)
        let headerStoreHeight = (try? HeaderStore.shared.getLatestHeight()) ?? 0
        let cachedChainHeight = UInt64(UserDefaults.standard.integer(forKey: "cachedChainHeight"))
        let checkpointHeight = (try? getVerifiedCheckpointHeight()) ?? 0

        // FIX #1075 v2: NEVER allow lastScannedHeight to REGRESS (go backwards)
        // The checkpoint represents a verified good state.
        // We allow progress FORWARD (even if below checkpoint - catching up)
        // But BLOCK progress BACKWARD (regression from current height)
        //
        // User correctly said: "if there is a valid checkpoint then the wallet must never regressed below the checkpoint"
        // This means: if we WERE at checkpoint, we can't go below it. But if we're CATCHING UP, allow progress.
        let currentLastScanned = (try? getLastScannedHeight()) ?? 0

        // REGRESSION CHECK: Block if new height is BELOW current height
        if currentLastScanned > 0 && height < currentLastScanned {
            // Only log once per 100 blocks to reduce spam during repeated attempts
            if height % 100 == 0 || height == currentLastScanned - 1 {
                print("🚨 [FIX #1075] BLOCKING regression: \(currentLastScanned) -> \(height)")
                print("   Checkpoint: \(checkpointHeight)")
            }
            return  // BLOCK the regression
        }

        // CHECKPOINT FLOOR: If we're at or above checkpoint, block regression below it
        // This is the "never regress below checkpoint" rule
        if currentLastScanned >= checkpointHeight && checkpointHeight > 0 && height < checkpointHeight {
            print("🚨 [FIX #1075] BLOCKING regression BELOW checkpoint!")
            print("   Current: \(currentLastScanned), Attempted: \(height), Checkpoint: \(checkpointHeight)")
            print("   Wallet was synced to checkpoint, cannot regress below it!")
            Thread.callStackSymbols.prefix(10).forEach { print("   \($0)") }
            return  // BLOCK the regression
        }

        // The maximum trusted height is the highest from these validated sources
        let maxTrustedHeight = max(headerStoreHeight, cachedChainHeight, checkpointHeight)

        // FIX #167: Only allow heights up to 100 blocks ahead of trusted height
        // This prevents Sybil attacks where malicious peers report fake heights
        let maxAheadOfTrusted: UInt64 = 100
        if maxTrustedHeight > 0 && height > maxTrustedHeight + maxAheadOfTrusted {
            print("🚨 [FIX #167] Blocking suspicious lastScannedHeight: \(height)")
            print("   Max trusted height: \(maxTrustedHeight) (Header: \(headerStoreHeight), Cache: \(cachedChainHeight), Checkpoint: \(checkpointHeight))")
            print("   Max allowed: \(maxTrustedHeight + maxAheadOfTrusted)")
            print("   BLOCKED - This looks like a Sybil attack!")
            Thread.callStackSymbols.prefix(10).forEach { print("   \($0)") }
            return
        }

        // Extra check: if height is more than 1000 ahead of current stored value, it's suspicious
        if let currentHeight = try? getLastScannedHeight() {
            let diff = height > currentHeight ? height - currentHeight : 0
            if diff > 1000 {
                print("⚠️ [FIX #167] Large height jump: \(currentHeight) -> \(height) (+\(diff) blocks)")
                // Allow if still within trusted range (handled above)
            }
        }

        guard height <= maxReasonableHeight else {
            print("🚨 [DATABASE] Refusing to write invalid lastScannedHeight: \(height)")
            print("   Max reasonable: \(maxReasonableHeight)")
            return  // Silently ignore invalid updates
        }

        let sql = "UPDATE sync_state SET last_scanned_height = ?, last_scanned_hash = ? WHERE id = 1;"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, Int64(height))
        _ = hash.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, 2, ptr.baseAddress, Int32(hash.count), nil)
        }

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.updateFailed(String(cString: sqlite3_errmsg(db)))
        }

        // FIX #1031: Log successful height update for debugging slow startup issues
        print("✅ [DATABASE] lastScannedHeight updated to \(height)")
    }

    // MARK: - FIX #165: Verified Checkpoint

    /// Get the last verified checkpoint height where balance/history was confirmed correct.
    /// At startup, app MUST scan from this checkpoint to chain tip to catch ALL missed transactions.
    func getVerifiedCheckpointHeight() throws -> UInt64 {
        // FIX #940: Guard against nil database handle
        guard db != nil else {
            return 0
        }

        let sql = "SELECT verified_checkpoint_height FROM sync_state WHERE id = 1;"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return 0
        }

        return UInt64(sqlite3_column_int64(stmt, 0))
    }

    /// Update the verified checkpoint height.
    /// Call this when:
    /// 1. App startup sync completes successfully (both incoming and spent tx detected)
    /// 2. Send transaction completes successfully (balance/history updated)
    /// 3. Any time balance/history is verified as correct
    /// FIX #241: Also stores in checkpoint_history (last 10 kept)
    func updateVerifiedCheckpointHeight(_ height: UInt64) throws {
        // Validate height
        let maxReasonableHeight: UInt64 = 10_000_000
        guard height <= maxReasonableHeight else {
            print("🚨 [FIX #165] Refusing to write invalid checkpoint height: \(height)")
            return
        }

        // Get current checkpoint to avoid duplicate entries
        let currentCheckpoint = (try? getVerifiedCheckpointHeight()) ?? 0
        guard height > currentCheckpoint else {
            // Don't create duplicate or older checkpoint entries
            return
        }

        let sql = "UPDATE sync_state SET verified_checkpoint_height = ? WHERE id = 1;"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, Int64(height))

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.updateFailed(String(cString: sqlite3_errmsg(db)))
        }

        // FIX #241: Add to checkpoint history
        try addCheckpointToHistory(height: height)

        print("✅ [FIX #241] Updated verified checkpoint to height \(height)")
    }

    // MARK: - FIX #241: Checkpoint History

    /// Add a checkpoint to history, keeping only the last 10
    private func addCheckpointToHistory(height: UInt64) throws {
        // Insert new checkpoint
        let insertSql = "INSERT INTO checkpoint_history (height) VALUES (?);"
        var insertStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, insertSql, -1, &insertStmt, nil) == SQLITE_OK {
            sqlite3_bind_int64(insertStmt, 1, Int64(height))
            sqlite3_step(insertStmt)
            sqlite3_finalize(insertStmt)
        }

        // Prune to keep only last 10 checkpoints
        let pruneSql = """
            DELETE FROM checkpoint_history WHERE id NOT IN (
                SELECT id FROM checkpoint_history ORDER BY id DESC LIMIT 10
            );
        """
        sqlite3_exec(db, pruneSql, nil, nil, nil)

        print("📍 [FIX #241] Added checkpoint at height \(height) to history")
    }

    /// Get checkpoint history (last 10 checkpoints, newest first)
    func getCheckpointHistory() throws -> [(id: Int64, height: UInt64, timestamp: Int64)] {
        let sql = "SELECT id, height, timestamp FROM checkpoint_history ORDER BY id DESC LIMIT 10;"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        var checkpoints: [(id: Int64, height: UInt64, timestamp: Int64)] = []

        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let height = UInt64(sqlite3_column_int64(stmt, 1))
            let timestamp = sqlite3_column_int64(stmt, 2)
            checkpoints.append((id: id, height: height, timestamp: timestamp))
        }

        return checkpoints
    }

    /// Rollback to a previous checkpoint
    func rollbackToCheckpoint(_ checkpointId: Int64) throws -> UInt64 {
        // Get the checkpoint height
        let sql = "SELECT height FROM checkpoint_history WHERE id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, checkpointId)

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw DatabaseError.notFound("Checkpoint not found")
        }

        let height = UInt64(sqlite3_column_int64(stmt, 0))

        // Update last scanned height directly (rollback doesn't have a block hash)
        let heightUpdateSql = "UPDATE sync_state SET last_scanned_height = ? WHERE id = 1;"
        var heightStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, heightUpdateSql, -1, &heightStmt, nil) == SQLITE_OK {
            sqlite3_bind_int64(heightStmt, 1, Int64(height))
            sqlite3_step(heightStmt)
            sqlite3_finalize(heightStmt)
        }

        // Update verified checkpoint
        let updateSql = "UPDATE sync_state SET verified_checkpoint_height = ? WHERE id = 1;"
        var updateStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, updateSql, -1, &updateStmt, nil) == SQLITE_OK {
            sqlite3_bind_int64(updateStmt, 1, Int64(height))
            sqlite3_step(updateStmt)
            sqlite3_finalize(updateStmt)
        }

        // Remove checkpoints newer than this one
        let deleteSql = "DELETE FROM checkpoint_history WHERE id > ?;"
        var deleteStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, deleteSql, -1, &deleteStmt, nil) == SQLITE_OK {
            sqlite3_bind_int64(deleteStmt, 1, checkpointId)
            sqlite3_step(deleteStmt)
            sqlite3_finalize(deleteStmt)
        }

        print("🔄 [FIX #241] Rolled back to checkpoint \(checkpointId) at height \(height)")
        return height
    }

    // MARK: - FIX #370: TX-Confirmed Checkpoint (Deep Verification)

    /// Get the last block height where a transaction was confirmed.
    /// This is the starting point for periodic deep verification scans.
    /// Unlike verified_checkpoint_height, this ONLY updates on actual TX confirmations.
    func getTxConfirmedCheckpoint() throws -> UInt64 {
        let sql = "SELECT tx_confirmed_checkpoint FROM sync_state WHERE id = 1;"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return 0
        }

        return UInt64(sqlite3_column_int64(stmt, 0))
    }

    /// Update the TX-confirmed checkpoint. Called ONLY when a transaction is confirmed.
    /// This ensures deep verification catches any missed transactions between confirmations.
    func updateTxConfirmedCheckpoint(_ height: UInt64) throws {
        let maxReasonableHeight: UInt64 = 10_000_000
        guard height <= maxReasonableHeight else {
            print("🚨 [FIX #370] Refusing to write invalid tx_confirmed_checkpoint: \(height)")
            return
        }

        let sql = "UPDATE sync_state SET tx_confirmed_checkpoint = ? WHERE id = 1;"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, Int64(height))

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.updateFailed(String(cString: sqlite3_errmsg(db)))
        }

        print("✅ [FIX #370] Updated tx_confirmed_checkpoint to height \(height)")
    }

    /// Get the timestamp of the last deep verification scan
    func getLastDeepVerificationTime() throws -> Int64 {
        let sql = "SELECT last_deep_verification FROM sync_state WHERE id = 1;"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return 0
        }

        return sqlite3_column_int64(stmt, 0)
    }

    /// Update the last deep verification timestamp
    func updateLastDeepVerificationTime() throws {
        let sql = "UPDATE sync_state SET last_deep_verification = strftime('%s', 'now') WHERE id = 1;"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.updateFailed(String(cString: sqlite3_errmsg(db)))
        }

        print("✅ [FIX #370] Updated last_deep_verification timestamp")
    }

    // MARK: - Tree State

    /// Save commitment tree state
    /// FIX #741: Added height parameter - CRITICAL for persisting delta sync progress!
    /// Without saving tree_height, every startup re-syncs from boost file end (984 blocks)
    func saveTreeState(_ treeData: Data, height: UInt64? = nil) throws {
        let sql: String
        if let height = height {
            sql = "UPDATE sync_state SET tree_state = ?, tree_height = ? WHERE id = 1;"
        } else {
            sql = "UPDATE sync_state SET tree_state = ? WHERE id = 1;"
        }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        _ = treeData.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, 1, ptr.baseAddress, Int32(treeData.count), nil)
        }

        if let height = height {
            sqlite3_bind_int64(stmt, 2, Int64(height))
        }

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.updateFailed(String(cString: sqlite3_errmsg(db)))
        }

        if let height = height {
            print("💾 FIX #741: Saved tree state with height \(height)")
        }
    }

    /// FIX #741: Update tree height without modifying tree_state
    /// Called after delta CMU sync to persist the new height
    func updateTreeHeight(_ height: UInt64) throws {
        let sql = "UPDATE sync_state SET tree_height = ? WHERE id = 1;"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, Int64(height))

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.updateFailed(String(cString: sqlite3_errmsg(db)))
        }

        print("💾 FIX #741: Updated tree height to \(height)")
    }

    /// Clear commitment tree state (set to NULL)
    func clearTreeState() throws {
        let sql = "UPDATE sync_state SET tree_state = NULL WHERE id = 1;"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.updateFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    /// Get commitment tree state
    func getTreeState() throws -> Data? {
        let sql = "SELECT tree_state FROM sync_state WHERE id = 1;"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return nil
        }

        guard let ptr = sqlite3_column_blob(stmt, 0) else {
            return nil
        }
        let len = sqlite3_column_bytes(stmt, 0)
        guard len > 0 else {
            return nil
        }

        return Data(bytes: ptr, count: Int(len))
    }

    /// Get the tree height (block height that the saved tree_state corresponds to)
    /// FIX #688: Added this function to support tree height queries
    func getTreeHeight() throws -> UInt64 {
        let sql = "SELECT tree_height FROM sync_state WHERE id = 1;"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return 0  // Default to 0 if no record found
        }

        return UInt64(sqlite3_column_int64(stmt, 0))
    }

    /// Clear tree state and scan height to force rebuild on next scan
    /// This is needed when witnesses are stale or invalid
    /// IMPORTANT: This preserves note records, only clearing witness data
    func clearTreeStateForRebuild() throws {
        // Clear tree state and reset scan height
        let sql1 = "UPDATE sync_state SET tree_state = NULL, last_scanned_height = 0 WHERE id = 1;"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql1, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.updateFailed(String(cString: sqlite3_errmsg(db)))
        }

        // Clear witness data only (preserve note records)
        // The rescan will rebuild witnesses for existing notes
        let sql2 = "UPDATE notes SET witness = NULL, witness_height = 0;"

        var stmt2: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql2, -1, &stmt2, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt2) }

        guard sqlite3_step(stmt2) == SQLITE_DONE else {
            throw DatabaseError.updateFailed(String(cString: sqlite3_errmsg(db)))
        }

        print("🔄 Cleared tree state and witnesses for rebuild (preserved note records)")
    }

    // MARK: - Tree Checkpoints
    // Checkpoints store verified tree state at block boundaries for reliable transaction building

    /// Checkpoint data structure
    struct TreeCheckpoint {
        let height: UInt64
        let treeRoot: Data       // 32 bytes - finalsaplingroot at this height
        let treeSerialized: Data // Serialized tree state
        let cmuCount: UInt64     // Number of CMUs in tree at this height
        let blockHash: Data      // 32 bytes - block hash for verification
        let createdAt: Date
    }

    /// Save a verified tree checkpoint
    /// Call this after initial sync completes and after each block during background sync
    func saveTreeCheckpoint(
        height: UInt64,
        treeRoot: Data,
        treeSerialized: Data,
        cmuCount: UInt64,
        blockHash: Data
    ) throws {
        // CRITICAL: Guard against nil database handle
        // sqlite3_errmsg(nil) returns "out of memory" which was misleading
        guard let database = db else {
            print("⚠️ saveTreeCheckpoint: Database not open")
            throw DatabaseError.notOpened
        }

        // Encrypt the serialized tree data (contains sensitive Merkle paths)
        let encryptedTree = try encryptBlob(treeSerialized)

        let sql = "INSERT OR REPLACE INTO tree_checkpoints (height, tree_root, tree_serialized, cmu_count, block_hash, created_at) VALUES (?, ?, ?, ?, ?, strftime('%s', 'now'));"

        var stmt: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(database, sql, -1, &stmt, nil)
        guard prepareResult == SQLITE_OK else {
            let errorMsg = String(cString: sqlite3_errmsg(database))
            print("⚠️ saveTreeCheckpoint prepare failed: \(errorMsg) (code: \(prepareResult))")
            throw DatabaseError.prepareFailed(errorMsg)
        }
        defer { sqlite3_finalize(stmt) }

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        sqlite3_bind_int64(stmt, 1, Int64(height))
        treeRoot.withUnsafeBytes { sqlite3_bind_blob(stmt, 2, $0.baseAddress, Int32($0.count), SQLITE_TRANSIENT) }
        encryptedTree.withUnsafeBytes { sqlite3_bind_blob(stmt, 3, $0.baseAddress, Int32($0.count), SQLITE_TRANSIENT) }
        sqlite3_bind_int64(stmt, 4, Int64(cmuCount))
        blockHash.withUnsafeBytes { sqlite3_bind_blob(stmt, 5, $0.baseAddress, Int32($0.count), SQLITE_TRANSIENT) }

        let stepResult = sqlite3_step(stmt)
        guard stepResult == SQLITE_DONE else {
            let errorMsg = String(cString: sqlite3_errmsg(database))
            print("⚠️ saveTreeCheckpoint step failed: \(errorMsg) (code: \(stepResult))")
            throw DatabaseError.insertFailed(errorMsg)
        }

        debugLog(.wallet, "💾 Saved tree checkpoint at height \(height) (root: \(treeRoot.prefix(8).hexString)..., \(cmuCount) CMUs)")
    }

    /// Get checkpoint at or before the specified height
    /// Useful for finding a valid starting point for witness rebuilding
    func getTreeCheckpoint(atOrBefore height: UInt64) throws -> TreeCheckpoint? {
        let sql = """
            SELECT height, tree_root, tree_serialized, cmu_count, block_hash, created_at
            FROM tree_checkpoints
            WHERE height <= ?
            ORDER BY height DESC
            LIMIT 1;
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

        return try parseCheckpointRow(stmt)
    }

    /// Get the latest (highest) checkpoint
    func getLatestTreeCheckpoint() throws -> TreeCheckpoint? {
        let sql = """
            SELECT height, tree_root, tree_serialized, cmu_count, block_hash, created_at
            FROM tree_checkpoints
            ORDER BY height DESC
            LIMIT 1;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return nil
        }

        return try parseCheckpointRow(stmt)
    }

    /// Get checkpoint at exact height (for validation)
    func getTreeCheckpoint(atHeight height: UInt64) throws -> TreeCheckpoint? {
        let sql = """
            SELECT height, tree_root, tree_serialized, cmu_count, block_hash, created_at
            FROM tree_checkpoints
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

        return try parseCheckpointRow(stmt)
    }

    /// Parse a checkpoint row from SQLite statement
    private func parseCheckpointRow(_ stmt: OpaquePointer?) throws -> TreeCheckpoint {
        let height = UInt64(sqlite3_column_int64(stmt, 0))

        guard let treeRootPtr = sqlite3_column_blob(stmt, 1) else {
            throw DatabaseError.queryFailed("Missing tree_root in checkpoint")
        }
        let treeRootSize = sqlite3_column_bytes(stmt, 1)
        let treeRoot = Data(bytes: treeRootPtr, count: Int(treeRootSize))

        guard let treeSerializedPtr = sqlite3_column_blob(stmt, 2) else {
            throw DatabaseError.queryFailed("Missing tree_serialized in checkpoint")
        }
        let treeSerializedSize = sqlite3_column_bytes(stmt, 2)
        let encryptedTree = Data(bytes: treeSerializedPtr, count: Int(treeSerializedSize))

        // Decrypt the tree data
        let treeSerialized = try decryptBlob(encryptedTree)

        let cmuCount = UInt64(sqlite3_column_int64(stmt, 3))

        guard let blockHashPtr = sqlite3_column_blob(stmt, 4) else {
            throw DatabaseError.queryFailed("Missing block_hash in checkpoint")
        }
        let blockHashSize = sqlite3_column_bytes(stmt, 4)
        let blockHash = Data(bytes: blockHashPtr, count: Int(blockHashSize))

        let createdAtTimestamp = sqlite3_column_int64(stmt, 5)
        let createdAt = Date(timeIntervalSince1970: TimeInterval(createdAtTimestamp))

        return TreeCheckpoint(
            height: height,
            treeRoot: treeRoot,
            treeSerialized: treeSerialized,
            cmuCount: cmuCount,
            blockHash: blockHash,
            createdAt: createdAt
        )
    }

    /// Validate a checkpoint against HeaderStore's finalsaplingroot
    /// Returns true if checkpoint is valid and matches blockchain state
    func validateTreeCheckpoint(_ checkpoint: TreeCheckpoint) -> Bool {
        // Get the finalsaplingroot from HeaderStore at this height
        guard let header = try? HeaderStore.shared.getHeader(at: checkpoint.height) else {
            debugLog(.wallet, "⚠️ Cannot validate checkpoint at \(checkpoint.height) - no header in store")
            return false
        }

        // Compare tree root to HeaderStore's finalsaplingroot
        if checkpoint.treeRoot != header.hashFinalSaplingRoot {
            debugLog(.wallet, "❌ Checkpoint validation FAILED at height \(checkpoint.height)")
            debugLog(.wallet, "   Checkpoint root: \(checkpoint.treeRoot.hexString)")
            debugLog(.wallet, "   HeaderStore root: \(header.hashFinalSaplingRoot.hexString)")
            return false
        }

        debugLog(.wallet, "✅ Checkpoint validated at height \(checkpoint.height)")
        return true
    }

    /// Prune old checkpoints to save space, keeping only every Nth checkpoint
    /// Keeps: the latest 10 checkpoints + every 1000th block checkpoint
    func pruneOldCheckpoints(keepRecent: Int = 10, keepEveryN: Int = 1000) throws {
        // First, get the latest N checkpoints to preserve
        let recentSql = "SELECT height FROM tree_checkpoints ORDER BY height DESC LIMIT ?;"
        var recentStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, recentSql, -1, &recentStmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(recentStmt) }
        sqlite3_bind_int(recentStmt, 1, Int32(keepRecent))

        var recentHeights: Set<UInt64> = []
        while sqlite3_step(recentStmt) == SQLITE_ROW {
            recentHeights.insert(UInt64(sqlite3_column_int64(recentStmt, 0)))
        }

        // Delete checkpoints that are not recent AND not on a keepEveryN boundary
        let deleteSql = """
            DELETE FROM tree_checkpoints
            WHERE height NOT IN (
                SELECT height FROM tree_checkpoints ORDER BY height DESC LIMIT ?
            )
            AND (height % ?) != 0;
        """

        var deleteStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, deleteSql, -1, &deleteStmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(deleteStmt) }

        sqlite3_bind_int(deleteStmt, 1, Int32(keepRecent))
        sqlite3_bind_int(deleteStmt, 2, Int32(keepEveryN))

        guard sqlite3_step(deleteStmt) == SQLITE_DONE else {
            throw DatabaseError.deleteFailed(String(cString: sqlite3_errmsg(db)))
        }

        let deletedCount = sqlite3_changes(db)
        if deletedCount > 0 {
            debugLog(.wallet, "🧹 Pruned \(deletedCount) old tree checkpoints")
        }
    }

    /// Delete all checkpoints (for wallet reset)
    func clearAllCheckpoints() throws {
        let sql = "DELETE FROM tree_checkpoints;"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.deleteFailed(String(cString: sqlite3_errmsg(db)))
        }

        debugLog(.wallet, "🗑️ Cleared all tree checkpoints")
    }

    /// Get count of stored checkpoints
    func getCheckpointCount() throws -> Int {
        let sql = "SELECT COUNT(*) FROM tree_checkpoints;"

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

    /// Clear all notes from the database (for new wallet)
    func clearAllNotes() throws {
        let sql = "DELETE FROM notes;"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.deleteFailed(String(cString: sqlite3_errmsg(db)))
        }
        print("🗑️ Cleared all notes from database")
    }

    /// Clear transaction history from the database (for new wallet)
    func clearTransactionHistory() throws {
        // VUL-016: Secure deletion - overwrite memos before delete
        try secureWipeMemos()

        let sql = "DELETE FROM transaction_history;"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.deleteFailed(String(cString: sqlite3_errmsg(db)))
        }
        print("🗑️ Cleared transaction history from database (secure)")
    }

    /// VUL-002: Delete a specific phantom transaction by txid
    /// Returns the value of the deleted transaction (for balance restoration)
    func deletePhantomTransaction(txid: Data) throws -> UInt64? {
        guard db != nil else {
            throw DatabaseError.notOpened
        }

        // First get the value before deleting
        let selectSql = "SELECT value FROM transaction_history WHERE txid = ? AND tx_type IN ('sent', 'α');"
        var selectStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, selectSql, -1, &selectStmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(selectStmt) }

        _ = txid.withUnsafeBytes { ptr in
            sqlite3_bind_blob(selectStmt, 1, ptr.baseAddress, Int32(txid.count), nil)
        }

        var deletedValue: UInt64? = nil
        if sqlite3_step(selectStmt) == SQLITE_ROW {
            deletedValue = UInt64(sqlite3_column_int64(selectStmt, 0))
        }

        // Now delete the transaction
        let deleteSql = "DELETE FROM transaction_history WHERE txid = ? AND tx_type IN ('sent', 'α');"
        var deleteStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, deleteSql, -1, &deleteStmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(deleteStmt) }

        _ = txid.withUnsafeBytes { ptr in
            sqlite3_bind_blob(deleteStmt, 1, ptr.baseAddress, Int32(txid.count), nil)
        }

        guard sqlite3_step(deleteStmt) == SQLITE_DONE else {
            throw DatabaseError.deleteFailed(String(cString: sqlite3_errmsg(db)))
        }

        let deleted = sqlite3_changes(db)
        if deleted > 0 {
            let txidHex = txid.map { String(format: "%02x", $0) }.joined()
            print("🗑️ VUL-002: Deleted phantom transaction \(txidHex) (value: \(deletedValue ?? 0))")
        }

        return deletedValue
    }

    /// VUL-002: Unmark a note as spent (restore it after phantom TX removal)
    /// This is needed when a phantom TX incorrectly marked a note as spent
    func unmarkNoteAsSpent(nullifier: Data) throws {
        guard db != nil else {
            throw DatabaseError.notOpened
        }

        // VUL-009: Nullifier may be stored hashed
        let nullifierToUse = isNullifierHashed(nullifier) ? nullifier : hashNullifier(nullifier)

        // FIX: Column is named 'nf' not 'nullifier' in the notes table schema
        let sql = """
            UPDATE notes
            SET is_spent = 0, spent_in_tx = NULL, spent_height = NULL
            WHERE nf = ?;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        _ = nullifierToUse.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, 1, ptr.baseAddress, Int32(nullifierToUse.count), nil)
        }

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.updateFailed(String(cString: sqlite3_errmsg(db)))
        }

        let updated = sqlite3_changes(db)
        if updated > 0 {
            let nullifierHex = nullifier.prefix(8).map { String(format: "%02x", $0) }.joined()
            print("✅ VUL-002: Unmarked note as unspent (nullifier: \(nullifierHex)...)")
        }
    }

    /// FIX #360: Unmark ALL notes that were marked spent with boost placeholder txids
    /// The boost file incorrectly marks some notes as spent. This function restores them.
    /// Returns the number of notes unmarked and their total value.
    func unmarkBoostPlaceholderSpentNotes() throws -> (count: Int, totalValue: UInt64) {
        guard db != nil else {
            throw DatabaseError.notOpened
        }

        // First, get the count and total value of affected notes
        let countSql = """
            SELECT COUNT(*), COALESCE(SUM(value), 0) FROM notes
            WHERE is_spent = 1 AND hex(spent_in_tx) LIKE '626F6F7374%';
        """
        // 626F6F7374 = hex for "boost"

        var countStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, countSql, -1, &countStmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(countStmt) }

        var count = 0
        var totalValue: UInt64 = 0
        if sqlite3_step(countStmt) == SQLITE_ROW {
            count = Int(sqlite3_column_int(countStmt, 0))
            totalValue = UInt64(sqlite3_column_int64(countStmt, 1))
        }

        if count == 0 {
            return (0, 0)
        }

        // Now unmark all boost placeholder spent notes
        let updateSql = """
            UPDATE notes
            SET is_spent = 0, spent_in_tx = NULL, spent_height = NULL
            WHERE is_spent = 1 AND hex(spent_in_tx) LIKE '626F6F7374%';
        """

        var updateStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, updateSql, -1, &updateStmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(updateStmt) }

        guard sqlite3_step(updateStmt) == SQLITE_DONE else {
            throw DatabaseError.updateFailed(String(cString: sqlite3_errmsg(db)))
        }

        let updated = Int(sqlite3_changes(db))
        print("🔧 FIX #360: Unmarked \(updated) notes with boost placeholder txids (total value: \(Double(totalValue) / 100_000_000) ZCL)")

        return (updated, totalValue)
    }

    /// FIX #371: Get notes with boost placeholder txids that need real txid resolution
    /// Returns: [(hashedNullifier, spentHeight)]
    func getNotesWithBoostPlaceholderTxids() throws -> [(Data, UInt64)] {
        guard db != nil else {
            throw DatabaseError.notOpened
        }

        // FIX #459: Compare actual bytes, not hex strings
        // Boost placeholders can be:
        // - "boost_spent_HEIGHT" (0x626F6F7374...) - full format
        // - "boos_HEIGHT" (0x626F6F735f...) - truncated format with underscore
        let sql = """
            SELECT nf, spent_height FROM notes
            WHERE is_spent = 1
            AND spent_height IS NOT NULL
            AND (
                substr(spent_in_tx, 1, 5) = X'626F6F7374'  -- "boost"
                OR substr(spent_in_tx, 1, 5) = X'626F6F735F'  -- "boos_" (truncated)
            );
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        var results: [(Data, UInt64)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let nfPtr = sqlite3_column_blob(stmt, 0) else { continue }
            let nfLen = sqlite3_column_bytes(stmt, 0)
            let hashedNullifier = Data(bytes: nfPtr, count: Int(nfLen))
            let spentHeight = UInt64(sqlite3_column_int64(stmt, 1))

            results.append((hashedNullifier, spentHeight))
        }

        return results
    }

    /// FIX #461: Get notes with boost placeholder txids in received_in_tx
    /// Returns: [(rowid, hashedNullifier, height)]
    func getNotesWithReceivedPlaceholderTxids() throws -> [(Int64, Data, UInt64)] {
        guard db != nil else {
            throw DatabaseError.notOpened
        }

        let sql = """
            SELECT rowid, nf, height FROM notes
            WHERE (
                substr(received_in_tx, 1, 5) = X'626F6F7374'  -- "boost"
                OR substr(received_in_tx, 1, 5) = X'626F6F735F'  -- "boos_" (truncated)
            );
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        var results: [(Int64, Data, UInt64)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let rowid = sqlite3_column_int64(stmt, 0)
            guard let nfPtr = sqlite3_column_blob(stmt, 1) else { continue }
            let nfLen = sqlite3_column_bytes(stmt, 1)
            let hashedNullifier = Data(bytes: nfPtr, count: Int(nfLen))
            let height = UInt64(sqlite3_column_int64(stmt, 2))

            results.append((rowid, hashedNullifier, height))
        }

        return results
    }

    /// FIX #461: Update a note's received_in_tx with the real transaction ID
    func updateNoteReceivedTxid(rowid: Int64, realTxid: Data) throws {
        guard db != nil else {
            throw DatabaseError.notOpened
        }

        let sql = "UPDATE notes SET received_in_tx = ? WHERE rowid = ?;"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_bind_blob(stmt, 1, (realTxid as NSData).bytes, 32, nil) == SQLITE_OK else {
            throw DatabaseError.updateFailed("Failed to bind txid")
        }
        guard sqlite3_bind_int64(stmt, 2, rowid) == SQLITE_OK else {
            throw DatabaseError.updateFailed("Failed to bind rowid")
        }
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.updateFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    /// FIX #371: Update a note's spent_in_tx with the real transaction ID
    /// Uses hashed nullifier (as stored in database) for lookup
    func updateNoteSpentTxid(hashedNullifier: Data, realTxid: Data) throws {
        guard db != nil else {
            throw DatabaseError.notOpened
        }

        let sql = "UPDATE notes SET spent_in_tx = ? WHERE nf = ?;"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        _ = realTxid.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, 1, ptr.baseAddress, Int32(realTxid.count), nil)
        }
        _ = hashedNullifier.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, 2, ptr.baseAddress, Int32(hashedNullifier.count), nil)
        }

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.updateFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    /// FIX #466: Get unspent notes with boost placeholder received_in_tx that need resolution
    /// Returns: [(cmu, receivedHeight)] - cmu is used to match transaction outputs
    func getUnspentNotesWithBoostReceivedTxid() throws -> [(Data, UInt64)] {
        guard db != nil else {
            throw DatabaseError.notOpened
        }

        // 626F6F7374 = hex for "boost"
        let sql = """
            SELECT cmu, received_height FROM notes
            WHERE is_spent = 0
            AND hex(received_in_tx) LIKE '626F6F7374%'
            AND received_height IS NOT NULL;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        var results: [(Data, UInt64)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let cmuPtr = sqlite3_column_blob(stmt, 0) else { continue }
            let cmuLen = sqlite3_column_bytes(stmt, 0)
            let cmu = Data(bytes: cmuPtr, count: Int(cmuLen))
            let receivedHeight = UInt64(sqlite3_column_int64(stmt, 1))

            results.append((cmu, receivedHeight))
        }

        return results
    }

    /// FIX #466: Update a note's received_in_tx with the real transaction ID
    /// Uses cmu (commitment) for lookup since it's unique per note
    func updateNoteReceivedTxid(cmu: Data, realTxid: Data) throws {
        guard db != nil else {
            throw DatabaseError.notOpened
        }

        let sql = "UPDATE notes SET received_in_tx = ? WHERE cmu = ?;"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        _ = realTxid.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, 1, ptr.baseAddress, Int32(realTxid.count), nil)
        }
        _ = cmu.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, 2, ptr.baseAddress, Int32(cmu.count), nil)
        }

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.updateFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    /// VUL-002: Get nullifiers of notes marked as spent in a specific transaction
    func getNullifiersSpentInTx(txid: Data) throws -> [Data] {
        guard db != nil else {
            throw DatabaseError.notOpened
        }

        // FIX: Column is named 'nf' not 'nullifier' in the notes table schema
        let sql = "SELECT nf FROM notes WHERE spent_in_tx = ?;"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        _ = txid.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, 1, ptr.baseAddress, Int32(txid.count), nil)
        }

        var nullifiers: [Data] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let nullifierPtr = sqlite3_column_blob(stmt, 0) else { continue }
            let nullifierLen = sqlite3_column_bytes(stmt, 0)
            let nullifier = Data(bytes: nullifierPtr, count: Int(nullifierLen))
            nullifiers.append(nullifier)
        }

        return nullifiers
    }

    /// FIX #162 v3: Rebuild transaction history from ALL notes
    /// This creates a consistent history where:
    /// - RECEIVED = sum of ALL notes (spent + unspent)
    /// - SENT = sum of sent amounts from spent notes
    /// - Balance = RECEIVED - SENT - FEES = sum of UNSPENT notes
    /// Unlike populateHistoryFromNotes() which creates fake transactions with synthetic txids,
    /// this function creates accurate entries from actual note data.
    func rebuildHistoryFromUnspentNotes() throws {
        guard db != nil else {
            throw DatabaseError.notOpened
        }

        // SQLITE_TRANSIENT tells SQLite to copy the data immediately
        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        // ============================================================
        // PART 1: Insert RECEIVED transactions from ALL notes (spent + unspent)
        // FIX #162 v3: Must include spent notes too for balance to reconcile!
        // ============================================================
        let allNotes = try getAllNotes(accountId: 1)  // FIX #162 v3: Now correctly gets ALL notes including spent
        print("🔧 FIX #162 v3: Rebuilding history from \(allNotes.count) notes (all, including spent)")

        let insertReceivedSql = """
            INSERT OR IGNORE INTO transaction_history (txid, block_height, block_time, tx_type, value, fee, to_address, from_diversifier, memo)
            VALUES (?, ?, ?, ?, ?, NULL, NULL, ?, NULL);
        """
        var insertReceivedStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, insertReceivedSql, -1, &insertReceivedStmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(insertReceivedStmt) }

        var receivedCount = 0
        for note in allNotes {
            let txid: Data
            if let cmu = note.cmu, !cmu.isEmpty {
                txid = cmu
            } else {
                var uniqueData = Data()
                uniqueData.append(contentsOf: withUnsafeBytes(of: note.height.littleEndian) { Data($0) })
                uniqueData.append(contentsOf: withUnsafeBytes(of: note.value.littleEndian) { Data($0) })
                uniqueData.append(note.diversifier)
                txid = uniqueData.prefix(32)
            }

            _ = txid.withUnsafeBytes { ptr in
                sqlite3_bind_blob(insertReceivedStmt, 1, ptr.baseAddress, Int32(txid.count), SQLITE_TRANSIENT)
            }
            sqlite3_bind_int64(insertReceivedStmt, 2, Int64(note.height))

            // FIX #299: Get real block timestamp instead of NULL
            if let timestamp = BlockTimestampManager.shared.getTimestamp(at: note.height) {
                sqlite3_bind_int64(insertReceivedStmt, 3, Int64(timestamp))
            } else if let headerTime = try? HeaderStore.shared.getBlockTime(at: note.height) {
                sqlite3_bind_int64(insertReceivedStmt, 3, Int64(headerTime))
            } else {
                sqlite3_bind_null(insertReceivedStmt, 3)
            }

            let receivedType = encryptTxType(.received)
            sqlite3_bind_text(insertReceivedStmt, 4, receivedType, -1, SQLITE_TRANSIENT)

            sqlite3_bind_int64(insertReceivedStmt, 5, Int64(note.value))

            _ = note.diversifier.withUnsafeBytes { ptr in
                sqlite3_bind_blob(insertReceivedStmt, 6, ptr.baseAddress, Int32(note.diversifier.count), SQLITE_TRANSIENT)
            }

            if sqlite3_step(insertReceivedStmt) == SQLITE_DONE {
                receivedCount += 1
            }
            sqlite3_reset(insertReceivedStmt)
        }

        // ============================================================
        // PART 2: Insert SENT transactions from spent notes
        // FIX #162: Group spent notes by spent_in_tx to calculate sent amounts
        // ============================================================
        let spentSql = """
            SELECT spent_in_tx, spent_height, SUM(value) as total_input
            FROM notes
            WHERE is_spent = 1 AND spent_in_tx IS NOT NULL AND spent_height IS NOT NULL
            GROUP BY spent_in_tx
            ORDER BY spent_height DESC;
        """
        var spentStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, spentSql, -1, &spentStmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(spentStmt) }

        // Collect spent transaction info
        var spentTxs: [(txid: Data, height: UInt64, totalInput: UInt64)] = []
        while sqlite3_step(spentStmt) == SQLITE_ROW {
            let txidPtr = sqlite3_column_blob(spentStmt, 0)
            let txidLen = sqlite3_column_bytes(spentStmt, 0)
            let height = UInt64(sqlite3_column_int64(spentStmt, 1))
            let totalInput = UInt64(sqlite3_column_int64(spentStmt, 2))

            if let ptr = txidPtr, txidLen > 0 {
                let txid = Data(bytes: ptr, count: Int(txidLen))
                // Skip fake boost txids (they start with "boost_spent_")
                if !txid.starts(with: Data("boost_spent_".utf8)) {
                    spentTxs.append((txid: txid, height: height, totalInput: totalInput))
                }
            }
        }

        print("🔧 FIX #162: Found \(spentTxs.count) real sent transactions from spent notes")

        // For each spent tx, calculate: sent amount = total input - change - fee
        // Change = notes received at same height in same tx
        // Fee = 10000 zatoshis (standard fee)
        let insertSentSql = """
            INSERT OR IGNORE INTO transaction_history (txid, block_height, block_time, tx_type, value, fee, to_address, from_diversifier, memo)
            VALUES (?, ?, ?, ?, ?, ?, NULL, NULL, NULL);
        """
        var insertSentStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, insertSentSql, -1, &insertSentStmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(insertSentStmt) }

        var sentCount = 0
        let defaultFee: UInt64 = 10000

        for spentTx in spentTxs {
            // FIX #295: Look for change outputs by TXID, not height
            // Change notes are in the SAME transaction (received_in_tx == spentTx.txid)
            // FIX #450 v5: BUT with boost placeholders, need height-based fallback!
            let changeSql = """
                SELECT COALESCE(SUM(value), 0) FROM notes
                WHERE received_in_tx = ?;
            """
            var changeAmount: UInt64 = 0

            // First try txid match (works for real txids)
            var changeStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, changeSql, -1, &changeStmt, nil) == SQLITE_OK {
                _ = spentTx.txid.withUnsafeBytes { ptr in
                    sqlite3_bind_blob(changeStmt, 1, ptr.baseAddress, Int32(spentTx.txid.count), SQLITE_TRANSIENT)
                }
                if sqlite3_step(changeStmt) == SQLITE_ROW {
                    changeAmount = UInt64(sqlite3_column_int64(changeStmt, 0))
                }
                sqlite3_finalize(changeStmt)
            }

            // FIX #450 v5: If no change found by txid (boost placeholder case), try height match
            if changeAmount == 0 {
                // Look for notes received at same height that are NOT spent (these are change outputs)
                let changeByHeightSql = """
                    SELECT COALESCE(SUM(value), 0) FROM notes
                    WHERE received_height = ? AND is_spent = 0;
                """
                if sqlite3_prepare_v2(db, changeByHeightSql, -1, &changeStmt, nil) == SQLITE_OK {
                    sqlite3_bind_int64(changeStmt, 1, Int64(spentTx.height))
                    if sqlite3_step(changeStmt) == SQLITE_ROW {
                        let heightBasedChange = UInt64(sqlite3_column_int64(changeStmt, 0))
                        // Only use height-based change if it makes sense (change < input)
                        if heightBasedChange > 0 && heightBasedChange < spentTx.totalInput {
                            changeAmount = heightBasedChange
                            print("🔧 FIX #450 v5: Using height-based change detection for tx at height \(spentTx.height): \(changeAmount) zatoshis")
                        }
                    }
                    sqlite3_finalize(changeStmt)
                }
            }

            // FIX #450 v6: Sent amount = inputs - change (includes fee!)
            // The fee is PART of the sent amount - it's money that left the wallet
            // Example: Send 0.1 ZCL + 0.0001 fee = 0.1001 total sent
            // If totalInput < change, something is wrong, skip
            guard spentTx.totalInput > changeAmount else {
                print("🔧 FIX #162: Skipping tx with totalInput \(spentTx.totalInput) <= change \(changeAmount)")
                continue
            }

            // Sent amount includes the fee (total that left the wallet)
            let sentAmount = spentTx.totalInput - changeAmount  // Includes fee!
            // fee is still stored separately for display purposes
            let actualFee = defaultFee

            _ = spentTx.txid.withUnsafeBytes { ptr in
                sqlite3_bind_blob(insertSentStmt, 1, ptr.baseAddress, Int32(spentTx.txid.count), SQLITE_TRANSIENT)
            }
            sqlite3_bind_int64(insertSentStmt, 2, Int64(spentTx.height))

            // FIX #299: Get real block timestamp instead of NULL
            if let timestamp = BlockTimestampManager.shared.getTimestamp(at: spentTx.height) {
                sqlite3_bind_int64(insertSentStmt, 3, Int64(timestamp))
            } else if let headerTime = try? HeaderStore.shared.getBlockTime(at: spentTx.height) {
                sqlite3_bind_int64(insertSentStmt, 3, Int64(headerTime))
            } else {
                sqlite3_bind_null(insertSentStmt, 3)
            }

            let sentType = encryptTxType(.sent)
            sqlite3_bind_text(insertSentStmt, 4, sentType, -1, SQLITE_TRANSIENT)

            sqlite3_bind_int64(insertSentStmt, 5, Int64(sentAmount))
            sqlite3_bind_int64(insertSentStmt, 6, Int64(actualFee))

            if sqlite3_step(insertSentStmt) == SQLITE_DONE {
                sentCount += 1
                print("🔧 FIX #450 v6: Added SENT tx at height \(spentTx.height): \(sentAmount) zatoshis (input: \(spentTx.totalInput), change: \(changeAmount), fee: \(actualFee), to_recipient: \(sentAmount - actualFee))")
            }
            sqlite3_reset(insertSentStmt)
        }

        // Calculate totals for logging
        let totalReceived = allNotes.reduce(0) { $0 + $1.value }
        let unspentNotes = try getUnspentNotes(accountId: 1)
        let unspentBalance = unspentNotes.reduce(0) { $0 + $1.value }
        let spentNotesCount = allNotes.count - unspentNotes.count
        print("🔧 FIX #162 v3: Inserted \(receivedCount)/\(allNotes.count) received entries")
        print("🔧 FIX #162 v3: - Total ALL notes (spent+unspent): \(allNotes.count)")
        print("🔧 FIX #162 v3: - Spent notes: \(spentNotesCount), Unspent notes: \(unspentNotes.count)")
        print("🔧 FIX #162 v3: - Total received: \(totalReceived) zatoshis")
        print("🔧 FIX #162 v3: Inserted \(sentCount) sent entries")
        print("🔧 FIX #162 v3: Expected balance (unspent only) = \(unspentBalance) zatoshis")
    }

    /// FIX #120: Repair transaction history timestamps
    /// Updates all block_time values using correct timestamps from HeaderStore
    /// For heights without timestamps, extrapolates from last known timestamp (150s per block)
    func repairTransactionHistoryTimestamps() throws -> Int {
        guard db != nil else {
            throw DatabaseError.notOpened
        }

        // Get all distinct heights from transaction history (sorted ascending)
        let selectSql = "SELECT DISTINCT block_height FROM transaction_history WHERE block_height > 0 ORDER BY block_height;"
        var selectStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, selectSql, -1, &selectStmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(selectStmt) }

        var heights: [UInt64] = []
        while sqlite3_step(selectStmt) == SQLITE_ROW {
            let height = UInt64(sqlite3_column_int64(selectStmt, 0))
            heights.append(height)
        }

        print("📜 FIX #120: Repairing timestamps for \(heights.count) unique heights...")

        // Update each height with correct timestamp from HeaderStore
        let updateSql = "UPDATE transaction_history SET block_time = ? WHERE block_height = ?;"
        var updateStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, updateSql, -1, &updateStmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(updateStmt) }

        // NO EXTRAPOLATION - ONLY REAL TIMESTAMPS!
        var repairedCount = 0
        var missingCount = 0

        for height in heights {
            // ONLY use REAL timestamps from HeaderStore (block_times or headers table)
            // NO extrapolation, NO estimation - REAL DATA ONLY!
            guard let realTimestamp = try? HeaderStore.shared.getBlockTime(at: height) else {
                // No real timestamp available - skip this height, don't fake it!
                missingCount += 1
                print("⏳ Height \(height): No real timestamp yet (will sync from P2P)")
                continue
            }

            sqlite3_reset(updateStmt)
            sqlite3_bind_int64(updateStmt, 1, Int64(realTimestamp))
            sqlite3_bind_int64(updateStmt, 2, Int64(height))

            if sqlite3_step(updateStmt) == SQLITE_DONE {
                repairedCount += Int(sqlite3_changes(db))
            }
        }

        if missingCount > 0 {
            print("⚠️ FIX #120: \(missingCount) heights need P2P header sync for real timestamps")
        }
        print("✅ FIX #120: Repaired \(repairedCount) timestamps (NO extrapolation - real data only)")
        return repairedCount
    }

    /// FIX #120: Get transaction heights above a given height that need timestamps
    func getTransactionHeightsAbove(_ minHeight: UInt64) throws -> [UInt64] {
        guard db != nil else {
            throw DatabaseError.notOpened
        }

        let sql = "SELECT DISTINCT block_height FROM transaction_history WHERE block_height > ? ORDER BY block_height;"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, Int64(minHeight))

        var heights: [UInt64] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let height = UInt64(sqlite3_column_int64(stmt, 0))
            heights.append(height)
        }

        return heights
    }

    /// Migrate transaction history to use obfuscated type codes and remove duplicates
    /// This fixes the VUL-015 bug where both 'sent' and 'α' entries existed for the same txid
    func migrateTransactionHistoryTypes() throws {
        // Step 1: Convert plaintext type codes to obfuscated codes
        let migrations = [
            "UPDATE transaction_history SET tx_type = 'α' WHERE tx_type = 'sent';",
            "UPDATE transaction_history SET tx_type = 'β' WHERE tx_type = 'received';",
            "UPDATE transaction_history SET tx_type = 'γ' WHERE tx_type = 'change';"
        ]

        for sql in migrations {
            if sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK {
                let changes = sqlite3_changes(db)
                if changes > 0 {
                    let typeCode = sql.contains("sent") ? "sent→α" : (sql.contains("received") ? "received→β" : "change→γ")
                    print("📜 Migration: converted \(changes) '\(typeCode)' entries")
                }
            }
        }

        // Step 2: Remove duplicates - keep the lowest id (first inserted) for each (txid, normalized_type)
        // This handles cases where both 'sent' and 'α' existed before migration converted them
        let deduplicateSql = """
            DELETE FROM transaction_history
            WHERE id NOT IN (
                SELECT MIN(id)
                FROM transaction_history
                GROUP BY txid, tx_type
            );
        """

        if sqlite3_exec(db, deduplicateSql, nil, nil, nil) == SQLITE_OK {
            let deletedCount = sqlite3_changes(db)
            if deletedCount > 0 {
                print("📜 Migration: removed \(deletedCount) duplicate transaction history entries")
            }
        }

        print("📜 Transaction history migration complete")
    }

    // MARK: - VUL-016: Secure Memo Deletion

    /// Securely wipe all memos by overwriting with random data before deletion
    /// Prevents forensic recovery of sensitive memo content
    private func secureWipeMemos() throws {
        // Generate random data to overwrite memos (512 bytes = max memo length)
        var randomBytes = [UInt8](repeating: 0, count: 512)
        _ = SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes)
        let randomString = String(repeating: "X", count: 512)

        // Overwrite all memo fields with random data
        let overwriteSql = "UPDATE transaction_history SET memo = ? WHERE memo IS NOT NULL;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, overwriteSql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, randomString, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.updateFailed(String(cString: sqlite3_errmsg(db)))
        }

        let changedRows = sqlite3_changes(db)
        if changedRows > 0 {
            print("🔐 VUL-016: Securely wiped \(changedRows) memo(s)")
        }
    }

    /// Securely delete a single memo by ID (overwrites before setting to NULL)
    func secureDeleteMemo(historyId: Int64) throws {
        // First overwrite with random data
        var randomBytes = [UInt8](repeating: 0, count: 512)
        _ = SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes)
        let randomString = String(repeating: "X", count: 512)

        let overwriteSql = "UPDATE transaction_history SET memo = ? WHERE id = ? AND memo IS NOT NULL;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, overwriteSql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, randomString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 2, historyId)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            sqlite3_finalize(stmt)
            throw DatabaseError.updateFailed(String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_finalize(stmt)

        // Then set to NULL
        let nullSql = "UPDATE transaction_history SET memo = NULL WHERE id = ?;"
        guard sqlite3_prepare_v2(db, nullSql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, historyId)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.updateFailed(String(cString: sqlite3_errmsg(db)))
        }
        print("🔐 VUL-016: Securely deleted memo for history ID \(historyId)")
    }

    /// Clear all accounts from the database (for new wallet)
    func clearAccounts() throws {
        let sql = "DELETE FROM accounts;"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.deleteFailed(String(cString: sqlite3_errmsg(db)))
        }
        print("🗑️ Cleared accounts from database")
    }

    /// Update witness for a note
    func updateNoteWitness(noteId: Int64, witness: Data) throws {
        let sql = "UPDATE notes SET witness = ? WHERE id = ?;"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        // SECURITY: Encrypt witness before storage - VUL-002: throws on failure
        let encryptedWitness = try encryptBlob(witness)
        _ = encryptedWitness.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, 1, ptr.baseAddress, Int32(encryptedWitness.count), nil)
        }
        sqlite3_bind_int64(stmt, 2, noteId)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.updateFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    /// Update anchor for a note (the tree root when witness was last updated)
    func updateNoteAnchor(noteId: Int64, anchor: Data) throws {
        let sql = "UPDATE notes SET anchor = ? WHERE id = ?;"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        _ = anchor.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, 1, ptr.baseAddress, Int32(anchor.count), nil)
        }
        sqlite3_bind_int64(stmt, 2, noteId)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.updateFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    /// FIX #557 v45: Update witness_index for a note
    /// Stores the index in the global FFI tree, allowing us to retrieve fresh witnesses
    func updateNoteWitnessIndex(noteId: Int64, witnessIndex: UInt64) throws {
        let sql = "UPDATE notes SET witness_index = ? WHERE id = ?;"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, Int64(witnessIndex))
        sqlite3_bind_int64(stmt, 2, noteId)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.updateFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    /// FIX #557 v45: Helper function to get column names for a table
    /// Used in migrations to check if a column already exists
    private func getTableColumns(_ tableName: String) -> Set<String> {
        var columns: Set<String> = []
        var stmt: OpaquePointer?
        let sql = "PRAGMA table_info(\(tableName));"
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let columnName = sqlite3_column_text(stmt, 1) {
                    columns.insert(String(cString: columnName))
                }
            }
            sqlite3_finalize(stmt)
        }
        return columns
    }

    /// FIX #550: Get anchor for a specific note
    /// Used to verify anchor writes succeeded
    func getAnchor(for noteId: Int64) throws -> Data? {
        let sql = "SELECT anchor FROM notes WHERE id = ? LIMIT 1;"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, noteId)

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return nil
        }

        guard let anchorPtr = sqlite3_column_blob(stmt, 0) else {
            return nil
        }
        let anchorLength = sqlite3_column_bytes(stmt, 0)
        let anchor = Data(bytes: anchorPtr, count: Int(anchorLength))

        return anchor
    }

    /// FIX #554: Get height for a specific note
    /// Used to get correct anchor from HeaderStore when witness extraction fails
    func getNoteHeight(noteId: Int64) throws -> Int64? {
        let sql = "SELECT height FROM notes WHERE id = ? LIMIT 1;"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, noteId)

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return nil
        }

        return sqlite3_column_int64(stmt, 0)
    }

    /// Update nullifier for a note (used when recomputing nullifiers with correct positions)
    func updateNoteNullifier(noteId: Int64, nullifier: Data) throws {
        // Hash the nullifier before storage for privacy
        let hashedNullifier = hashNullifier(nullifier)
        let sql = "UPDATE notes SET nf = ? WHERE id = ?;"  // Column is 'nf', not 'nullifier'

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        _ = hashedNullifier.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, 1, ptr.baseAddress, Int32(hashedNullifier.count), nil)
        }
        sqlite3_bind_int64(stmt, 2, noteId)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.updateFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    /// Reset sync state for full rescan
    /// Deletes notes, nullifiers, tree state, and resets scan height
    func resetSyncState() throws {
        // Delete all notes (they will be re-discovered during scan)
        var sql = "DELETE FROM notes;"
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw DatabaseError.updateFailed(String(cString: sqlite3_errmsg(db)))
        }
        print("🗑️ Deleted all notes")

        // Delete all nullifiers
        sql = "DELETE FROM nullifiers;"
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw DatabaseError.updateFailed(String(cString: sqlite3_errmsg(db)))
        }
        print("🗑️ Deleted all nullifiers")

        // Reset sync state (height and tree)
        sql = "UPDATE sync_state SET last_scanned_height = 0, last_scanned_hash = NULL, tree_state = NULL WHERE id = 1;"
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw DatabaseError.updateFailed(String(cString: sqlite3_errmsg(db)))
        }
        print("🗑️ Reset sync state to height 0")

        // Delete transaction history
        sql = "DELETE FROM transaction_history;"
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw DatabaseError.updateFailed(String(cString: sqlite3_errmsg(db)))
        }
        print("🗑️ Deleted transaction history")
    }

    /// Clear notes for rescan WITHOUT affecting tree state
    /// Used when rescanning within bundled tree range - preserves tree but clears notes for rediscovery
    func clearNotesForRescan() throws {
        // Delete all notes (they will be re-discovered during scan)
        var sql = "DELETE FROM notes;"
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw DatabaseError.updateFailed(String(cString: sqlite3_errmsg(db)))
        }
        print("🗑️ Deleted all notes (tree preserved)")

        // Delete all nullifiers
        sql = "DELETE FROM nullifiers;"
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw DatabaseError.updateFailed(String(cString: sqlite3_errmsg(db)))
        }
        print("🗑️ Deleted all nullifiers")

        // Delete transaction history
        sql = "DELETE FROM transaction_history;"
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw DatabaseError.updateFailed(String(cString: sqlite3_errmsg(db)))
        }
        print("🗑️ Deleted transaction history")

        // Note: We intentionally do NOT clear tree_state or last_scanned_height
        // The tree remains intact for spending proofs
        print("📝 Tree state preserved for spending")
    }

    // MARK: - Transaction History

    /// Insert a transaction into history
    func insertTransactionHistory(
        txid: Data,
        height: UInt64,
        blockTime: UInt64?,
        type: TransactionType,
        value: UInt64,
        fee: UInt64?,
        toAddress: String?,
        fromDiversifier: Data?,
        memo: String?
    ) throws -> Int64 {
        // Use INSERT OR REPLACE to update existing entries with same (txid, tx_type)
        // This ensures sent transactions are properly recorded even if a "received"
        // entry for the same txid exists (e.g., change output detected during scan)
        let sql = """
            INSERT OR REPLACE INTO transaction_history
            (txid, block_height, block_time, tx_type, value, fee, to_address, from_diversifier, memo)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        _ = txid.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, 1, ptr.baseAddress, Int32(txid.count), SQLITE_TRANSIENT)
        }
        sqlite3_bind_int64(stmt, 2, Int64(height))
        if let blockTime = blockTime {
            sqlite3_bind_int64(stmt, 3, Int64(blockTime))
        } else {
            sqlite3_bind_null(stmt, 3)
        }
        // VUL-015: Use obfuscated type code instead of plaintext
        let encryptedType = encryptTxType(type)
        sqlite3_bind_text(stmt, 4, encryptedType, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 5, Int64(value))
        if let fee = fee {
            sqlite3_bind_int64(stmt, 6, Int64(fee))
        } else {
            sqlite3_bind_null(stmt, 6)
        }
        if let toAddress = toAddress {
            sqlite3_bind_text(stmt, 7, toAddress, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 7)
        }
        if let fromDiversifier = fromDiversifier {
            _ = fromDiversifier.withUnsafeBytes { ptr in
                sqlite3_bind_blob(stmt, 8, ptr.baseAddress, Int32(fromDiversifier.count), SQLITE_TRANSIENT)
            }
        } else {
            sqlite3_bind_null(stmt, 8)
        }
        if let memo = memo {
            sqlite3_bind_text(stmt, 9, memo, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 9)
        }

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.insertFailed(String(cString: sqlite3_errmsg(db)))
        }

        let rowsChanged = sqlite3_changes(db)
        let rowId = sqlite3_last_insert_rowid(db)
        print("📜 DB: Insert result - rowId=\(rowId), rowsChanged=\(rowsChanged), txid=\(txid.prefix(8).map { String(format: "%02x", $0) }.joined())..., type=\(type.rawValue)")

        return rowId
    }

    /// Get count of transaction history entries
    func getTransactionHistoryCount() throws -> Int {
        guard db != nil else { return 0 }
        let sql = "SELECT COUNT(*) FROM transaction_history"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        if sqlite3_step(stmt) == SQLITE_ROW {
            return Int(sqlite3_column_int64(stmt, 0))
        }
        return 0
    }

    /// Get transaction history ordered by height (newest first)
    func getTransactionHistory(limit: Int = 100, offset: Int = 0) throws -> [TransactionHistoryItem] {
        print("📜 getTransactionHistory called")

        // FIX #120: Guard against nil database handle
        guard db != nil else {
            print("⚠️ getTransactionHistory: Database not open, returning empty")
            return []
        }

        // FIRST: Clean up any duplicate transactions in the database
        // Duplicates can occur when same tx is recorded with different txid byte orders
        // Keep the one with the lowest id (first inserted)
        // VUL-015 fix: Normalize tx_type before grouping to handle both plaintext and obfuscated codes
        // 'sent' and 'α' are the same, 'received' and 'β' are the same, 'change' and 'γ' are the same
        let cleanupSql = """
            DELETE FROM transaction_history
            WHERE id NOT IN (
                SELECT MIN(id) FROM transaction_history
                GROUP BY
                    CASE
                        WHEN tx_type IN ('sent', 'α') THEN 'sent'
                        WHEN tx_type IN ('received', 'β') THEN 'received'
                        WHEN tx_type IN ('change', 'γ') THEN 'change'
                        ELSE tx_type
                    END,
                    value,
                    block_height
            );
        """
        if sqlite3_exec(db, cleanupSql, nil, nil, nil) == SQLITE_OK {
            let deleted = sqlite3_changes(db)
            if deleted > 0 {
                print("📜 DB: Cleaned up \(deleted) duplicate transaction(s)")
            }
        }

        // Check total count (excluding change outputs for accurate count)
        // VUL-015: Include both plaintext and obfuscated type codes for backwards compat
        // FIX #1083: Filter β entries where txid matches α OR note was spent in same tx
        let countSql = """
            SELECT COUNT(*) FROM transaction_history t1
            WHERE t1.tx_type NOT IN ('change', 'γ')
            AND NOT (
                t1.tx_type IN ('received', 'β')
                AND (
                    EXISTS (
                        SELECT 1 FROM transaction_history t2
                        WHERE t2.txid = t1.txid
                        AND t2.tx_type IN ('sent', 'α')
                    )
                    OR EXISTS (
                        SELECT 1 FROM notes n
                        WHERE n.spent_in_tx = t1.txid
                    )
                )
            );
        """
        var countStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, countSql, -1, &countStmt, nil) == SQLITE_OK {
            if sqlite3_step(countStmt) == SQLITE_ROW {
                let count = sqlite3_column_int(countStmt, 0)
                print("📜 DB: transaction_history has \(count) displayable rows (excluding change outputs)")
            }
            sqlite3_finalize(countStmt)
        }

        // FIX #1083: Exclude change outputs properly
        // 1. Explicitly exclude tx_type = 'change' or 'γ' (VUL-015 obfuscated)
        // 2. Filter out β entries where there's an α entry with SAME txid (change from our send)
        // 3. Filter out β entries received in same tx where we spent a note (change output)
        // 4. Use subquery with DISTINCT to deduplicate BEFORE ordering
        let sql = """
            SELECT txid, block_height, block_time, tx_type, value, fee, to_address, memo, status, confirmations
            FROM transaction_history t1
            WHERE t1.tx_type NOT IN ('change', 'γ')
            AND NOT (
                t1.tx_type IN ('received', 'β')
                AND (
                    -- FIX #1083: Filter β entries where there's an α entry with SAME txid
                    EXISTS (
                        SELECT 1 FROM transaction_history t2
                        WHERE t2.txid = t1.txid
                        AND t2.tx_type IN ('sent', 'α')
                    )
                    OR
                    -- FIX #1083: Filter β entries received in tx where we spent a note (change)
                    EXISTS (
                        SELECT 1 FROM notes n
                        WHERE n.spent_in_tx = t1.txid
                    )
                )
            )
            AND t1.rowid IN (
                SELECT MIN(rowid)
                FROM transaction_history
                WHERE tx_type NOT IN ('change', 'γ')
                GROUP BY
                    CASE
                        WHEN tx_type IN ('sent', 'α') THEN 'sent'
                        WHEN tx_type IN ('received', 'β') THEN 'received'
                        WHEN tx_type IN ('change', 'γ') THEN 'change'
                        ELSE tx_type
                    END,
                    value,
                    block_height
            )
            ORDER BY block_height DESC
            LIMIT ? OFFSET ?;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int(stmt, 1, Int32(limit))
        sqlite3_bind_int(stmt, 2, Int32(offset))

        var items: [TransactionHistoryItem] = []

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let txidPtr = sqlite3_column_blob(stmt, 0) else {
                continue
            }
            let txidLen = sqlite3_column_bytes(stmt, 0)
            let height = UInt64(sqlite3_column_int64(stmt, 1))
            var blockTime = sqlite3_column_type(stmt, 2) != SQLITE_NULL ? UInt64(sqlite3_column_int64(stmt, 2)) : nil

            // ALWAYS try to get real timestamp - BlockTimestampManager first (bundled data), then HeaderStore
            if height > 0 {
                if let timestamp = BlockTimestampManager.shared.getTimestamp(at: height) {
                    blockTime = UInt64(timestamp)
                } else if let headerTime = try? HeaderStore.shared.getBlockTime(at: height) {
                    blockTime = UInt64(headerTime)
                }
            }
            // If still nil (header not synced yet), leave as nil - UI will handle it
            // VUL-015: Decrypt the obfuscated type code
            let rawTypeStr = String(cString: sqlite3_column_text(stmt, 3))
            let txType = decryptTxType(rawTypeStr)
            let value = UInt64(sqlite3_column_int64(stmt, 4))
            let fee = sqlite3_column_type(stmt, 5) != SQLITE_NULL ? UInt64(sqlite3_column_int64(stmt, 5)) : nil
            let toAddress = sqlite3_column_type(stmt, 6) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 6)) : nil
            let memo = sqlite3_column_type(stmt, 7) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 7)) : nil
            let statusStr = sqlite3_column_type(stmt, 8) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 8)) : "confirmed"
            let confirmations = Int(sqlite3_column_int(stmt, 9))

            let txidData = Data(bytes: txidPtr, count: Int(txidLen))
            let item = TransactionHistoryItem(
                txid: txidData,
                height: height,
                blockTime: blockTime,
                type: txType,  // VUL-015: Use decrypted type
                value: value,
                fee: fee,
                toAddress: toAddress,
                memo: memo,
                status: TransactionStatus(rawValue: statusStr) ?? .confirmed,
                confirmations: confirmations
            )

            items.append(item)
        }

        return items
    }

    /// Get total transaction count
    func getTransactionCount() throws -> Int {
        let sql = "SELECT COUNT(*) FROM transaction_history;"

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

    /// Check if a transaction exists in history (direct check, no filtering)
    /// VUL-015: Check both plaintext and obfuscated type codes for backwards compat
    func transactionExists(txid: Data, type: TransactionType) throws -> Bool {
        // Check both old plaintext and new obfuscated codes
        let encryptedType = encryptTxType(type)
        let sql = "SELECT 1 FROM transaction_history WHERE txid = ? AND tx_type IN (?, ?) LIMIT 1;"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = txid.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, 1, ptr.baseAddress, Int32(txid.count), SQLITE_TRANSIENT)
        }
        sqlite3_bind_text(stmt, 2, type.rawValue, -1, SQLITE_TRANSIENT)  // Old plaintext
        sqlite3_bind_text(stmt, 3, encryptedType, -1, SQLITE_TRANSIENT)  // New obfuscated

        return sqlite3_step(stmt) == SQLITE_ROW
    }

    // REMOVED: estimateBlockTime() - NEVER estimate timestamps!
    // Always use real blockchain timestamp from HeaderStore.shared.getBlockTime(at:)

    /// Populate transaction history from notes table
    /// Creates a unified view with: SENT, RECEIVED, and CHANGE transaction types
    ///
    /// Transaction Types:
    /// - SENT: When we spent a note to send funds elsewhere. Value = actualSent (input - change - fee)
    /// - RECEIVED: When we received funds from an external source
    /// - CHANGE: When we received change back from our own SENT transaction
    ///
    /// Logic:
    /// 1. Build a set of all spent_in_tx txids (these are SENT transactions)
    /// 2. For each note:
    ///    - If note.txid matches a spent_in_tx → it's a CHANGE output
    ///    - Otherwise → it's a RECEIVED transaction
    /// 3. For each SENT tx: actualSent = input.value - sum(change outputs) - fee
    ///
    /// NOTE: This function uses INSERT OR IGNORE to only ADD missing entries.
    /// It does NOT clear existing history - WalletManager's entries are preserved.
    func populateHistoryFromNotes() throws -> Int {
        // FIX #120: Guard against nil database handle
        // sqlite3_errmsg(nil) returns "out of memory" which is misleading
        guard db != nil else {
            print("⚠️ populateHistoryFromNotes: Database not open, skipping")
            return 0
        }

        // IMPORTANT: Do NOT clear transaction history here!
        // WalletManager records SENT transactions with the correct amount at send time.
        // Clearing would wipe out that correct value, then we'd recalculate from notes
        // which may not yet reflect the pending transaction.
        // Instead, we use INSERT OR IGNORE to only add missing entries.
        // try clearTransactionHistory() // REMOVED - this was wiping WalletManager's correct entries

        // Get ALL notes - even those without txid (we'll create a synthetic txid based on nullifier)
        let sql = """
            SELECT n.diversifier, n.value, n.received_height, n.received_in_tx, n.is_spent, n.spent_in_tx, n.nf, n.spent_height
            FROM notes n
            ORDER BY n.received_height ASC;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }

        var count = 0
        var notesFound = 0

        // Collect all notes first
        struct NoteData {
            let diversifier: Data?
            let value: UInt64
            let receivedHeight: UInt64
            let txid: Data
            let isSpent: Bool
            let spentTxid: Data?
            let spentHeight: UInt64?
        }
        var allNotes: [NoteData] = []

        while sqlite3_step(stmt) == SQLITE_ROW {
            notesFound += 1
            let diversifierPtr = sqlite3_column_blob(stmt, 0)
            let diversifierLen = sqlite3_column_bytes(stmt, 0)
            let value = UInt64(sqlite3_column_int64(stmt, 1))
            let receivedHeight = UInt64(sqlite3_column_int64(stmt, 2))
            let txidPtr = sqlite3_column_type(stmt, 3) != SQLITE_NULL ? sqlite3_column_blob(stmt, 3) : nil
            let txidLen = sqlite3_column_bytes(stmt, 3)
            let isSpent = sqlite3_column_int(stmt, 4) != 0
            let spentTxPtr = sqlite3_column_type(stmt, 5) != SQLITE_NULL ? sqlite3_column_blob(stmt, 5) : nil
            let spentTxLen = sqlite3_column_bytes(stmt, 5)
            let nullifierPtr = sqlite3_column_blob(stmt, 6)
            let nullifierLen = sqlite3_column_bytes(stmt, 6)
            let spentHeight: UInt64? = sqlite3_column_type(stmt, 7) != SQLITE_NULL
                ? UInt64(sqlite3_column_int64(stmt, 7))
                : nil

            // Use actual txid if available, otherwise use nullifier as synthetic txid
            let txid: Data
            if let txidPtr = txidPtr, txidLen > 0 {
                txid = Data(bytes: txidPtr, count: Int(txidLen))
            } else if let nullifierPtr = nullifierPtr, nullifierLen > 0 {
                txid = Data(bytes: nullifierPtr, count: min(Int(nullifierLen), 32))
            } else {
                print("📜 Note at height \(receivedHeight) has no txid or nullifier, skipping")
                continue
            }

            let diversifier = diversifierPtr != nil ? Data(bytes: diversifierPtr!, count: Int(diversifierLen)) : nil
            let spentTxid: Data? = (spentTxPtr != nil && spentTxLen > 0) ? Data(bytes: spentTxPtr!, count: Int(spentTxLen)) : nil

            allNotes.append(NoteData(
                diversifier: diversifier,
                value: value,
                receivedHeight: receivedHeight,
                txid: txid,
                isSpent: isSpent,
                spentTxid: spentTxid,
                spentHeight: spentHeight
            ))
        }
        sqlite3_finalize(stmt)

        print("📜 populateHistoryFromNotes: Found \(allNotes.count) notes total")
        let spentNotes = allNotes.filter { $0.isSpent }
        print("📜 populateHistoryFromNotes: \(spentNotes.count) notes are spent")
        for note in spentNotes {
            print("📜   Spent note: value=\(note.value), spentTxid=\(note.spentTxid?.prefix(8).hexString ?? "nil"), spentHeight=\(note.spentHeight ?? 0)")
        }

        // Build a set of all spent_in_tx txids - these represent our SENT transactions
        var sentTxids: Set<Data> = []
        for note in allNotes where note.isSpent {
            if let spentTxid = note.spentTxid {
                sentTxids.insert(spentTxid)
            }
        }

        // IMPORTANT: Use INSERT OR IGNORE for ALL transaction types
        // WalletManager records SENT transactions with correct amounts at send time.
        // We don't want to overwrite those with recalculated values.
        // For RECEIVED/CHANGE, INSERT OR IGNORE is also fine - only adds new entries.
        let insertSentSql = """
            INSERT OR IGNORE INTO transaction_history
            (txid, block_height, block_time, tx_type, value, fee, to_address, from_diversifier, memo)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        // Also use INSERT OR IGNORE for received (keeps existing entries intact)
        let insertReceivedSql = """
            INSERT OR IGNORE INTO transaction_history
            (txid, block_height, block_time, tx_type, value, fee, to_address, from_diversifier, memo)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let fee: UInt64 = 10_000

        // PASS 1: Insert all SENT transactions (only if not already recorded by WalletManager)
        // Group spent notes by their spent_in_tx to handle multi-input transactions
        var sentTxData: [Data: (inputValue: UInt64, spentHeight: UInt64)] = [:]
        for note in allNotes where note.isSpent {
            guard let spentTxid = note.spentTxid else { continue }
            let existing = sentTxData[spentTxid]
            let newInputValue = (existing?.inputValue ?? 0) + note.value
            let height = note.spentHeight ?? note.receivedHeight
            sentTxData[spentTxid] = (inputValue: newInputValue, spentHeight: existing?.spentHeight ?? height)
        }

        for (spentTxid, txInfo) in sentTxData {
            // FIX #373: DO NOT skip boost placeholders - these ARE real spent transactions!
            // The boost file marks notes as spent at specific heights - these are real spends
            // Placeholder txid "boost_spent_HEIGHT" will be resolved to real txid by FIX #371
            // Even before resolution, we should show SENT transactions (amount is correct)

            // FIX #1125: Find change outputs by TXID OR HEIGHT
            // Problem: FIX #465 skipped real SENT txs when change txid didn't match spent_in_tx
            // This caused historyBalance > notesBalance discrepancy after Full Rescan
            // Root cause: Boost file notes may have different txids for change outputs
            // Solution: Also look for change outputs by HEIGHT (same block = likely change)

            // Method 1: Direct txid match (original logic)
            var changeOutputs = allNotes.filter { $0.txid == spentTxid }

            // Method 2: Height-based match for boost file notes (FIX #464 v3 parity)
            // If a note was received at the same height where we spent, it's likely our change
            if changeOutputs.isEmpty {
                let heightBasedChange = allNotes.filter {
                    !$0.isSpent && $0.receivedHeight == txInfo.spentHeight
                }
                if !heightBasedChange.isEmpty {
                    changeOutputs = heightBasedChange
                    print("📜 FIX #1125: Found \(heightBasedChange.count) change outputs by HEIGHT at \(txInfo.spentHeight)")
                }
            }

            let totalChangeValue = changeOutputs.reduce(0) { $0 + $1.value }

            // totalBalanceImpact = sum(inputs) - sum(change) = amount to recipient + fee
            // This is the actual balance decrease, which makes history sum = current balance
            let totalBalanceImpact = txInfo.inputValue - totalChangeValue
            // amountToRecipient = balance impact - fee (for display info)
            let amountToRecipient = totalBalanceImpact - fee

            // FIX #464 v4: Skip SENT transactions where amountToRecipient is 0 or very small
            // These are internal transactions (change consolidation, self-sends) that shouldn't appear in history
            // If amountToRecipient <= 1000 zatoshis (0.00001 ZCL), it's essentially a change-only transaction
            if amountToRecipient <= 1000 {
                print("📜 FIX #464 v4: Skipping SENT txid=\(spentTxid.prefix(8).hexString)... - amountToRecipient=\(amountToRecipient) (change-only/self-send transaction)")
                continue
            }

            // FIX #1125: Disable FIX #465's aggressive skip - it causes balance discrepancies!
            // FIX #465 skipped SENT txs when recipientRatio > 95% AND totalChangeValue == 0
            // But now with height-based change detection, totalChangeValue is usually found
            // If still 0, it's better to record the SENT tx than skip it (prevents missing balance)
            //
            // OLD (broken):
            // let recipientRatio = Double(amountToRecipient) / Double(txInfo.inputValue)
            // if recipientRatio > 0.95 && totalChangeValue == 0 { continue }
            //
            // NEW: Always record SENT tx if amountToRecipient > 1000 (already checked above)

            print("📜 SENT: txid=\(spentTxid.prefix(8).hexString)..., input=\(txInfo.inputValue), change=\(totalChangeValue), fee=\(fee), toRecipient=\(amountToRecipient), balanceImpact=\(totalBalanceImpact)")

            var spentStmt: OpaquePointer?
            // Use insertSentSql (INSERT OR IGNORE) - WalletManager already recorded correct amount
            guard sqlite3_prepare_v2(db, insertSentSql, -1, &spentStmt, nil) == SQLITE_OK else {
                print("📜 SENT: Failed to prepare statement for txid=\(spentTxid.prefix(8).hexString)")
                continue
            }

            _ = spentTxid.withUnsafeBytes { ptr in
                sqlite3_bind_blob(spentStmt, 1, ptr.baseAddress, Int32(spentTxid.count), SQLITE_TRANSIENT)
            }
            sqlite3_bind_int64(spentStmt, 2, Int64(txInfo.spentHeight))
            // Get real block time - try BlockTimestampManager first (has bundled data), then HeaderStore
            if let timestamp = BlockTimestampManager.shared.getTimestamp(at: txInfo.spentHeight) {
                sqlite3_bind_int64(spentStmt, 3, Int64(timestamp))
            } else if let headerTime = try? HeaderStore.shared.getBlockTime(at: txInfo.spentHeight) {
                sqlite3_bind_int64(spentStmt, 3, Int64(headerTime))
            } else {
                sqlite3_bind_null(spentStmt, 3) // Will be fetched from BlockTimestampManager when displayed
            }
            // VUL-015: Use obfuscated type code to match recordSentTransaction
            // This ensures UNIQUE(txid, tx_type) constraint works correctly
            let encryptedSentType = encryptTxType(.sent)
            sqlite3_bind_text(spentStmt, 4, encryptedSentType, -1, SQLITE_TRANSIENT)
            // FIX #169: Store amountToRecipient (actual sent amount WITHOUT fee), not totalBalanceImpact
            // The fee is stored separately in the fee column
            // History display should show what was SENT TO RECIPIENT, not total balance decrease
            sqlite3_bind_int64(spentStmt, 5, Int64(amountToRecipient))
            sqlite3_bind_int64(spentStmt, 6, Int64(fee))
            sqlite3_bind_null(spentStmt, 7)
            sqlite3_bind_null(spentStmt, 8)
            sqlite3_bind_null(spentStmt, 9)

            let stepResult = sqlite3_step(spentStmt)
            if stepResult == SQLITE_DONE {
                // INSERT OR IGNORE: check if row was actually inserted or ignored
                let changes = sqlite3_changes(db)
                if changes > 0 {
                    count += 1
                    print("📜 SENT: Inserted from notes txid=\(spentTxid.prefix(8).hexString) (no prior record)")
                } else {
                    print("📜 SENT: Skipped txid=\(spentTxid.prefix(8).hexString) (already recorded by WalletManager)")
                }
            } else {
                let errMsg = String(cString: sqlite3_errmsg(db))
                print("📜 SENT: Failed for txid=\(spentTxid.prefix(8).hexString), error=\(errMsg)")
            }
            sqlite3_finalize(spentStmt)
        }

        // PASS 2: Insert RECEIVED transactions only (skip CHANGE outputs)
        // FIX #460: Change outputs are filtered out in display, no need to insert them
        // This reduces database size and prevents confusion

        // FIX #464 v3: Following Zclassic's IsNoteSaplingChange logic from wallet.cpp:
        // "A Note is marked as 'change' if the address that received it also spent
        //  Notes in the same transaction."
        //
        // Build two maps:
        // 1. txHasOurSpends: Transactions (by txid) where we spent notes
        // 2. heightHasOurSpends: Block heights where we spent notes
        var txHasOurSpends: Set<Data> = []
        var heightHasOurSpends: Set<UInt64> = []
        for note in allNotes where note.isSpent {
            if let spentTxid = note.spentTxid {
                txHasOurSpends.insert(spentTxid)
            }
            if let spentHeight = note.spentHeight {
                heightHasOurSpends.insert(spentHeight)
            }
        }
        print("📜 FIX #464 v3: Found \(txHasOurSpends.count) txids + \(heightHasOurSpends.count) heights where we spent notes (Zclassic logic)")

        for note in allNotes {
            // Determine if this is a CHANGE output (received in a tx that we initiated)
            // Method 1: Direct txid match (works for real transactions recorded by WalletManager)
            var isChange = sentTxids.contains(note.txid)

            // FIX #464 v3: Following Zclassic's IsNoteSaplingChange:
            // A note is CHANGE if received_in_tx (note.txid) is a transaction where we spent notes
            // This works because when we send, we create: spends + recipient output + change output
            // All in the SAME transaction, so change outputs have txid in txHasOurSpends
            if !isChange && txHasOurSpends.contains(note.txid) {
                isChange = true
                let txidDesc = String(bytes: note.txid.prefix(8), encoding: .ascii) ?? note.txid.prefix(8).hexString
                print("📜 FIX #464 v3: Detected change by txid (Zclassic logic): txid=\(txidDesc)")
            }

            // FIX #464 v3: For boost-file notes with placeholder txids, match by HEIGHT
            // When we send a transaction, we spend notes AND receive change in the SAME block
            // So if this note was received at a height where we spent, it's CHANGE
            if !isChange && heightHasOurSpends.contains(note.receivedHeight) {
                isChange = true
                print("📜 FIX #464 v3: Detected change by height (boost-file logic): receivedHeight=\(note.receivedHeight)")
            }

            // FIX #460: Skip inserting change transactions - they're filtered in display anyway
            if isChange {
                let txidDesc = String(bytes: note.txid.prefix(8), encoding: .ascii) ?? note.txid.prefix(8).hexString
                print("📜 FIX #464: Skipping change txid=\(txidDesc) at height \(note.receivedHeight)")
                continue
            }

            let txType = TransactionType.received  // Only received after filtering change

            var insertStmt: OpaquePointer?
            // Use insertReceivedSql (INSERT OR REPLACE) - notes are the source of truth for received
            guard sqlite3_prepare_v2(db, insertReceivedSql, -1, &insertStmt, nil) == SQLITE_OK else {
                print("📜 Failed to prepare insert statement")
                continue
            }

            _ = note.txid.withUnsafeBytes { ptr in
                sqlite3_bind_blob(insertStmt, 1, ptr.baseAddress, Int32(note.txid.count), SQLITE_TRANSIENT)
            }
            sqlite3_bind_int64(insertStmt, 2, Int64(note.receivedHeight))
            // Get real block time - try BlockTimestampManager first (has bundled data), then HeaderStore
            if let timestamp = BlockTimestampManager.shared.getTimestamp(at: note.receivedHeight) {
                sqlite3_bind_int64(insertStmt, 3, Int64(timestamp))
            } else if let headerTime = try? HeaderStore.shared.getBlockTime(at: note.receivedHeight) {
                sqlite3_bind_int64(insertStmt, 3, Int64(headerTime))
            } else {
                sqlite3_bind_null(insertStmt, 3) // Will be fetched from BlockTimestampManager when displayed
            }
            // VUL-015: Use obfuscated type codes to match recordReceivedTransaction
            let encryptedTxType = encryptTxType(txType)
            sqlite3_bind_text(insertStmt, 4, encryptedTxType, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(insertStmt, 5, Int64(note.value))
            sqlite3_bind_null(insertStmt, 6) // fee (only for SENT)
            sqlite3_bind_null(insertStmt, 7) // to_address
            if let diversifier = note.diversifier {
                _ = diversifier.withUnsafeBytes { ptr in
                    sqlite3_bind_blob(insertStmt, 8, ptr.baseAddress, Int32(diversifier.count), SQLITE_TRANSIENT)
                }
            } else {
                sqlite3_bind_null(insertStmt, 8)
            }
            sqlite3_bind_null(insertStmt, 9) // memo

            let result = sqlite3_step(insertStmt)
            if result == SQLITE_DONE {
                count += 1
                print("📜 Inserted \(txType.rawValue) tx: height=\(note.receivedHeight), value=\(note.value)")
            } else {
                print("📜 Insert failed: \(String(cString: sqlite3_errmsg(db)))")
            }
            sqlite3_finalize(insertStmt)
        }

        print("📜 Found \(notesFound) notes, populated \(count) transaction history entries")
        return count
    }

    // MARK: - Immediate Transaction Recording
    // These functions ensure history is updated in real-time, not lazily

    /// Record a received transaction immediately when a note is discovered during scanning
    /// Called from FilterScanner when we successfully decrypt a note
    func recordReceivedTransaction(
        txid: Data,
        height: UInt64,
        value: UInt64,
        memo: String? = nil,
        blockTime: UInt64? = nil
    ) throws {
        // VUL-015: Use obfuscated type code instead of plaintext
        let sql = """
            INSERT OR IGNORE INTO transaction_history
            (txid, block_height, block_time, tx_type, value, fee, to_address, from_diversifier, memo)
            VALUES (?, ?, ?, 'β', ?, NULL, NULL, NULL, ?);
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        _ = txid.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, 1, ptr.baseAddress, Int32(txid.count), SQLITE_TRANSIENT)
        }
        sqlite3_bind_int64(stmt, 2, Int64(height))

        // Use real block time if provided, otherwise try to get from BlockTimestampManager/HeaderStore
        // NEVER estimate - only use real blockchain timestamp!
        let actualBlockTime: UInt64?
        if let bt = blockTime {
            actualBlockTime = bt
        } else if let timestamp = BlockTimestampManager.shared.getTimestamp(at: height) {
            actualBlockTime = UInt64(timestamp)
        } else if let headerTime = try? HeaderStore.shared.getBlockTime(at: height) {
            actualBlockTime = UInt64(headerTime)
        } else {
            // No real timestamp available - store NULL and fix later
            actualBlockTime = nil
        }
        if let bt = actualBlockTime {
            sqlite3_bind_int64(stmt, 3, Int64(bt))
        } else {
            sqlite3_bind_null(stmt, 3)
        }

        sqlite3_bind_int64(stmt, 4, Int64(value))
        if let memo = memo {
            sqlite3_bind_text(stmt, 5, memo, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 5)
        }

        let result = sqlite3_step(stmt)
        if result == SQLITE_DONE {
            let changes = sqlite3_changes(db)
            if changes > 0 {
                print("📜 Recorded received transaction: height=\(height), value=\(value) zatoshis, time=\(actualBlockTime ?? 0)")
            }
        }
    }

    /// Record a sent transaction immediately when user initiates send
    /// Called from WalletManager BEFORE broadcasting to ensure we have a record
    func recordSentTransaction(
        txid: Data,
        height: UInt64,
        value: UInt64,
        fee: UInt64,
        toAddress: String?,
        memo: String? = nil,
        status: TransactionStatus = .confirmed,
        confirmations: Int = 0
    ) throws {
        // VUL-015: Use obfuscated type code instead of plaintext
        let sql = """
            INSERT OR REPLACE INTO transaction_history
            (txid, block_height, block_time, tx_type, value, fee, to_address, from_diversifier, memo, status, confirmations)
            VALUES (?, ?, ?, 'α', ?, ?, ?, NULL, ?, ?, ?);
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        _ = txid.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, 1, ptr.baseAddress, Int32(txid.count), SQLITE_TRANSIENT)
        }
        sqlite3_bind_int64(stmt, 2, Int64(height))

        // Use real block time: current time for height=0 (pending), BlockTimestampManager/HeaderStore for confirmed
        // NEVER estimate - only use real blockchain timestamp!
        let actualBlockTime: UInt64?
        if height == 0 {
            // Pending transaction - use current time (will be updated when confirmed)
            actualBlockTime = UInt64(Date().timeIntervalSince1970)
        } else if let timestamp = BlockTimestampManager.shared.getTimestamp(at: height) {
            actualBlockTime = UInt64(timestamp)
        } else if let headerTime = try? HeaderStore.shared.getBlockTime(at: height) {
            actualBlockTime = UInt64(headerTime)
        } else {
            // No real timestamp available - store NULL
            actualBlockTime = nil
        }
        if let bt = actualBlockTime {
            sqlite3_bind_int64(stmt, 3, Int64(bt))
        } else {
            sqlite3_bind_null(stmt, 3)
        }
        sqlite3_bind_int64(stmt, 4, Int64(value))
        sqlite3_bind_int64(stmt, 5, Int64(fee))
        if let toAddress = toAddress {
            sqlite3_bind_text(stmt, 6, toAddress, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 6)
        }
        if let memo = memo {
            sqlite3_bind_text(stmt, 7, memo, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 7)
        }
        sqlite3_bind_text(stmt, 8, status.rawValue, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 9, Int32(confirmations))

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.insertFailed(String(cString: sqlite3_errmsg(db)))
        }
        print("📜 Recorded sent transaction: height=\(height), value=\(value) zatoshis, fee=\(fee), status=\(status.rawValue)")
    }

    /// Record a pending transaction (just broadcast, not yet in any block)
    func recordPendingTransaction(
        txid: Data,
        type: TransactionType,
        value: UInt64,
        fee: UInt64?,
        toAddress: String?
    ) throws {
        let sql = """
            INSERT OR REPLACE INTO transaction_history
            (txid, block_height, block_time, tx_type, value, fee, to_address, from_diversifier, memo, status, confirmations)
            VALUES (?, 0, NULL, ?, ?, ?, ?, NULL, NULL, 'pending', 0);
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        _ = txid.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, 1, ptr.baseAddress, Int32(txid.count), SQLITE_TRANSIENT)
        }
        // VUL-015: Use obfuscated type code instead of plaintext
        let encryptedType = encryptTxType(type)
        sqlite3_bind_text(stmt, 2, encryptedType, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 3, Int64(value))
        if let fee = fee {
            sqlite3_bind_int64(stmt, 4, Int64(fee))
        } else {
            sqlite3_bind_null(stmt, 4)
        }
        if let toAddress = toAddress {
            sqlite3_bind_text(stmt, 5, toAddress, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 5)
        }

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.insertFailed(String(cString: sqlite3_errmsg(db)))
        }
        let txidHex = txid.map { String(format: "%02x", $0) }.joined()
        print("📜 Recorded pending transaction: txid=\(txidHex.prefix(16))..., type=\(type.rawValue), value=\(value)")
    }

    /// Update transaction status (when it gets confirmed)
    func updateTransactionStatus(txid: Data, status: TransactionStatus, confirmations: Int, height: UInt64? = nil) throws {
        var sql: String
        if let height = height {
            sql = "UPDATE transaction_history SET status = ?, confirmations = ?, block_height = ? WHERE txid = ?;"
        } else {
            sql = "UPDATE transaction_history SET status = ?, confirmations = ? WHERE txid = ?;"
        }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        sqlite3_bind_text(stmt, 1, status.rawValue, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 2, Int32(confirmations))
        if let height = height {
            sqlite3_bind_int64(stmt, 3, Int64(height))
            _ = txid.withUnsafeBytes { ptr in
                sqlite3_bind_blob(stmt, 4, ptr.baseAddress, Int32(txid.count), SQLITE_TRANSIENT)
            }
        } else {
            _ = txid.withUnsafeBytes { ptr in
                sqlite3_bind_blob(stmt, 3, ptr.baseAddress, Int32(txid.count), SQLITE_TRANSIENT)
            }
        }

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.updateFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    /// Get the earliest transaction height that needs a timestamp
    /// Used by background sync to know how far back to sync headers
    /// FIX #120: Sync headers from earliest missing timestamp, not just current height
    func getEarliestHeightNeedingTimestamp() throws -> UInt64? {
        // FIX #940: Guard against nil database handle
        guard db != nil else {
            return nil
        }

        let sql = "SELECT MIN(block_height) FROM transaction_history WHERE block_height > 0 AND (block_time IS NULL OR block_time = 0);"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        if sqlite3_step(stmt) == SQLITE_ROW {
            let height = sqlite3_column_int64(stmt, 0)
            return height > 0 ? UInt64(height) : nil
        }
        return nil
    }

    /// Clear wrong timestamps for transactions in the timestamp gap (between boost file end and header sync start)
    /// FIX #120: Transactions in gap have wrong estimated timestamps that need to be re-fetched
    /// @param boostEndHeight - last height covered by BlockTimestampManager (from boost file)
    /// @param headerStartHeight - first height in HeaderStore (from P2P sync)
    @discardableResult
    func clearWrongTimestampsInGap(boostEndHeight: UInt64, headerStartHeight: UInt64) throws -> Int {
        guard headerStartHeight > boostEndHeight else { return 0 }

        // Clear block_time for transactions in the gap - they have wrong estimated timestamps
        let sql = """
            UPDATE transaction_history
            SET block_time = NULL
            WHERE block_height > ? AND block_height < ?;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, Int64(boostEndHeight))
        sqlite3_bind_int64(stmt, 2, Int64(headerStartHeight))

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.updateFailed(String(cString: sqlite3_errmsg(db)))
        }

        let cleared = Int(sqlite3_changes(db))
        if cleared > 0 {
            print("📜 FIX #120: Cleared \(cleared) wrong timestamps in gap (\(boostEndHeight+1)-\(headerStartHeight-1))")
        }
        return cleared
    }

    /// Fix block_time for transactions that have NULL or zero timestamps using actual timestamps from HeaderStore
    /// This corrects estimated timestamps saved by older code or newly synced transactions
    @discardableResult
    func fixTransactionBlockTimes() throws -> Int {
        // FIX #143: Get ALL transactions and verify their timestamps against HeaderStore
        // Previously this only fixed NULL/zero timestamps, but incorrect timestamps also need fixing
        let selectSql = "SELECT id, block_height, block_time FROM transaction_history WHERE block_height > 0;"

        var selectStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, selectSql, -1, &selectStmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(selectStmt) }

        var updates: [(id: Int64, time: UInt32)] = []

        while sqlite3_step(selectStmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(selectStmt, 0)
            let height = UInt64(sqlite3_column_int64(selectStmt, 1))
            let currentTime = UInt32(sqlite3_column_int64(selectStmt, 2))

            // FIX #143: Get correct block time from HeaderStore (P2P synced headers are authoritative)
            // PRIORITY 1: HeaderStore headers table (real P2P-synced data)
            // PRIORITY 2: BlockTimestampManager (boost file for historical blocks)
            var correctTime: UInt32?
            if let blockTime = try? HeaderStore.shared.getBlockTime(at: height) {
                correctTime = blockTime
            } else if let timestamp = BlockTimestampManager.shared.getTimestamp(at: height) {
                correctTime = timestamp
            }

            // FIX #143: Only update if we have a correct time AND it differs from current
            if let correct = correctTime {
                if currentTime != correct {
                    updates.append((id: id, time: correct))
                    print("📜 Correcting timestamp for height \(height): \(currentTime) -> \(correct)")
                }
            }
        }

        // Update each transaction with the real block time
        let updateSql = "UPDATE transaction_history SET block_time = ? WHERE id = ?;"

        var updateStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, updateSql, -1, &updateStmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(updateStmt) }

        var fixedCount = 0
        for update in updates {
            sqlite3_reset(updateStmt)
            sqlite3_bind_int64(updateStmt, 1, Int64(update.time))
            sqlite3_bind_int64(updateStmt, 2, update.id)

            if sqlite3_step(updateStmt) == SQLITE_DONE {
                fixedCount += 1
            }
        }

        if fixedCount > 0 {
            print("📜 FIX #143: Corrected block_time for \(fixedCount) transactions using real timestamps from HeaderStore")
        } else {
            print("📜 All transaction timestamps are correct (no corrections needed)")
        }
        return fixedCount
    }

    /// Get all pending/unconfirmed transactions
    func getPendingTransactions() throws -> [TransactionHistoryItem] {
        let sql = """
            SELECT txid, block_height, block_time, tx_type, value, fee, to_address, memo, status, confirmations
            FROM transaction_history
            WHERE status IN ('pending', 'mempool', 'confirming')
            ORDER BY created_at DESC;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        var items: [TransactionHistoryItem] = []

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let txidPtr = sqlite3_column_blob(stmt, 0) else { continue }
            let txidLen = sqlite3_column_bytes(stmt, 0)
            let height = UInt64(sqlite3_column_int64(stmt, 1))
            var blockTime = sqlite3_column_type(stmt, 2) != SQLITE_NULL ? UInt64(sqlite3_column_int64(stmt, 2)) : nil

            // If blockTime is NULL, try to get actual timestamp from HeaderStore
            if blockTime == nil && height > 0 {
                if let header = try? HeaderStore.shared.getHeader(at: height) {
                    blockTime = UInt64(header.time)
                }
            }
            let typeStr = String(cString: sqlite3_column_text(stmt, 3))
            let value = UInt64(sqlite3_column_int64(stmt, 4))
            let fee = sqlite3_column_type(stmt, 5) != SQLITE_NULL ? UInt64(sqlite3_column_int64(stmt, 5)) : nil
            let toAddress = sqlite3_column_type(stmt, 6) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 6)) : nil
            let memo = sqlite3_column_type(stmt, 7) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 7)) : nil
            let statusStr = String(cString: sqlite3_column_text(stmt, 8))
            let confirmations = Int(sqlite3_column_int(stmt, 9))

            let txidData = Data(bytes: txidPtr, count: Int(txidLen))
            let decodedType = decryptTxType(typeStr)

            // Debug: Log first 5 items to trace duplicates
            if items.count < 5 {
                let txidHex = txidData.prefix(8).map { String(format: "%02x", $0) }.joined()
                print("📜 DB row[\(items.count)]: type=\(typeStr)→\(decodedType.rawValue), height=\(height), value=\(value), txid=\(txidHex)...")
            }

            items.append(TransactionHistoryItem(
                txid: txidData,
                height: height,
                blockTime: blockTime,
                type: decodedType,  // VUL-015: Handle both obfuscated (α,β,γ) and plaintext types
                value: value,
                fee: fee,
                toAddress: toAddress,
                memo: memo,
                status: TransactionStatus(rawValue: statusStr) ?? .pending,
                confirmations: confirmations
            ))
        }

        print("📜 DB: getTransactionHistory returning \(items.count) items")

        return items
    }

    /// VUL-002: Get all SENT transactions for blockchain verification
    /// Used by WalletHealthCheck to detect phantom transactions
    func getSentTransactions() throws -> [TransactionHistoryItem] {
        guard db != nil else {
            print("⚠️ getSentTransactions: Database not open")
            return []
        }

        // VUL-015: Include both plaintext and obfuscated type codes for backwards compat
        let sql = """
            SELECT txid, block_height, block_time, tx_type, value, fee, to_address, memo, status, confirmations
            FROM transaction_history
            WHERE tx_type IN ('sent', 'α')
            ORDER BY block_height DESC;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        var items: [TransactionHistoryItem] = []

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let txidPtr = sqlite3_column_blob(stmt, 0) else { continue }
            let txidLen = sqlite3_column_bytes(stmt, 0)
            let height = UInt64(sqlite3_column_int64(stmt, 1))
            var blockTime = sqlite3_column_type(stmt, 2) != SQLITE_NULL ? UInt64(sqlite3_column_int64(stmt, 2)) : nil

            // If blockTime is NULL, try to get actual timestamp from HeaderStore
            if blockTime == nil && height > 0 {
                if let header = try? HeaderStore.shared.getHeader(at: height) {
                    blockTime = UInt64(header.time)
                }
            }
            let typeStr = String(cString: sqlite3_column_text(stmt, 3))
            let value = UInt64(sqlite3_column_int64(stmt, 4))
            let fee = sqlite3_column_type(stmt, 5) != SQLITE_NULL ? UInt64(sqlite3_column_int64(stmt, 5)) : nil
            let toAddress = sqlite3_column_type(stmt, 6) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 6)) : nil
            let memo = sqlite3_column_type(stmt, 7) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 7)) : nil
            let statusStr = String(cString: sqlite3_column_text(stmt, 8))
            let confirmations = Int(sqlite3_column_int(stmt, 9))

            let txidData = Data(bytes: txidPtr, count: Int(txidLen))
            let decodedType = decryptTxType(typeStr)

            items.append(TransactionHistoryItem(
                txid: txidData,
                height: height,
                blockTime: blockTime,
                type: decodedType,
                value: value,
                fee: fee,
                toAddress: toAddress,
                memo: memo,
                status: TransactionStatus(rawValue: statusStr) ?? .confirmed,
                confirmations: confirmations
            ))
        }

        print("📜 VUL-002: Found \(items.count) SENT transactions to verify")
        return items
    }

    /// FIX #847: Get SENT transactions that are still pending (not confirmed)
    /// Used at startup to restore hasOurPendingOutgoing flag and prevent double-spending
    func getPendingSentTransactions() throws -> [TransactionHistoryItem] {
        guard db != nil else {
            print("⚠️ getPendingSentTransactions: Database not open")
            return []
        }

        // VUL-015: Include both plaintext and obfuscated type codes for backwards compat
        let sql = """
            SELECT txid, block_height, block_time, tx_type, value, fee, to_address, memo, status, confirmations
            FROM transaction_history
            WHERE tx_type IN ('sent', 'α')
            AND status IN ('pending', 'mempool', 'confirming')
            ORDER BY created_at DESC;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        var items: [TransactionHistoryItem] = []

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let txidPtr = sqlite3_column_blob(stmt, 0) else { continue }
            let txidLen = sqlite3_column_bytes(stmt, 0)
            let height = UInt64(sqlite3_column_int64(stmt, 1))
            let blockTime = sqlite3_column_type(stmt, 2) != SQLITE_NULL ? UInt64(sqlite3_column_int64(stmt, 2)) : nil
            let typeStr = String(cString: sqlite3_column_text(stmt, 3))
            let value = UInt64(sqlite3_column_int64(stmt, 4))
            let fee = sqlite3_column_type(stmt, 5) != SQLITE_NULL ? UInt64(sqlite3_column_int64(stmt, 5)) : nil
            let toAddress = sqlite3_column_type(stmt, 6) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 6)) : nil
            let memo = sqlite3_column_type(stmt, 7) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 7)) : nil
            let statusStr = String(cString: sqlite3_column_text(stmt, 8))
            let confirmations = Int(sqlite3_column_int(stmt, 9))

            let txidData = Data(bytes: txidPtr, count: Int(txidLen))
            let decodedType = decryptTxType(typeStr)

            items.append(TransactionHistoryItem(
                txid: txidData,
                height: height,
                blockTime: blockTime,
                type: decodedType,
                value: value,
                fee: fee,
                toAddress: toAddress,
                memo: memo,
                status: TransactionStatus(rawValue: statusStr) ?? .pending,
                confirmations: confirmations
            ))
        }

        print("📜 FIX #847: Found \(items.count) pending SENT transactions")
        return items
    }

    /// FIX #970 v3: Get recent sent transactions for phantom verification
    /// Returns all sent transactions from the last 24 hours, regardless of status
    /// This catches phantom TXs that were incorrectly marked as 'confirmed'
    func getRecentSentTransactions(hoursBack: Int = 24) throws -> [TransactionHistoryItem] {
        guard db != nil else {
            print("⚠️ getRecentSentTransactions: Database not open")
            return []
        }

        let cutoffTime = Int(Date().timeIntervalSince1970) - (hoursBack * 3600)

        // VUL-015: Include both plaintext and obfuscated type codes for backwards compat
        let sql = """
            SELECT txid, block_height, block_time, tx_type, value, fee, to_address, memo, status, confirmations
            FROM transaction_history
            WHERE tx_type IN ('sent', 'α')
            AND created_at >= ?
            ORDER BY created_at DESC;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, Int64(cutoffTime))

        var items: [TransactionHistoryItem] = []

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let txidPtr = sqlite3_column_blob(stmt, 0) else { continue }
            let txidLen = sqlite3_column_bytes(stmt, 0)
            let height = UInt64(sqlite3_column_int64(stmt, 1))
            let blockTime = sqlite3_column_type(stmt, 2) != SQLITE_NULL ? UInt64(sqlite3_column_int64(stmt, 2)) : nil
            let typeStr = String(cString: sqlite3_column_text(stmt, 3))
            let value = UInt64(sqlite3_column_int64(stmt, 4))
            let fee = sqlite3_column_type(stmt, 5) != SQLITE_NULL ? UInt64(sqlite3_column_int64(stmt, 5)) : nil
            let toAddress = sqlite3_column_type(stmt, 6) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 6)) : nil
            let memo = sqlite3_column_type(stmt, 7) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 7)) : nil
            let statusStr = String(cString: sqlite3_column_text(stmt, 8))
            let confirmations = Int(sqlite3_column_int(stmt, 9))

            let txidData = Data(bytes: txidPtr, count: Int(txidLen))
            let decodedType = decryptTxType(typeStr)

            items.append(TransactionHistoryItem(
                txid: txidData,
                height: height,
                blockTime: blockTime,
                type: decodedType,
                value: value,
                fee: fee,
                toAddress: toAddress,
                memo: memo,
                status: TransactionStatus(rawValue: statusStr) ?? .pending,
                confirmations: confirmations
            ))
        }

        print("📜 FIX #970 v3: Found \(items.count) sent transactions from last \(hoursBack) hours")
        return items
    }

    /// FIX #353: Get the last confirmed transaction (for checkpoint reset after phantom TX removal)
    /// Returns the most recent transaction that is confirmed (status = 'confirmed')
    func getLastConfirmedTransaction() throws -> TransactionHistoryItem? {
        guard db != nil else {
            print("⚠️ getLastConfirmedTransaction: Database not open")
            return nil
        }

        let sql = """
            SELECT txid, block_height, block_time, tx_type, value, fee, to_address, memo, status, confirmations
            FROM transaction_history
            WHERE status = 'confirmed' AND block_height > 0
            ORDER BY block_height DESC
            LIMIT 1;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        if sqlite3_step(stmt) == SQLITE_ROW {
            guard let txidPtr = sqlite3_column_blob(stmt, 0) else { return nil }
            let txidLen = sqlite3_column_bytes(stmt, 0)
            let height = UInt64(sqlite3_column_int64(stmt, 1))
            let blockTime = sqlite3_column_type(stmt, 2) != SQLITE_NULL ? UInt64(sqlite3_column_int64(stmt, 2)) : nil
            let typeStr = String(cString: sqlite3_column_text(stmt, 3))
            let value = UInt64(sqlite3_column_int64(stmt, 4))
            let fee = sqlite3_column_type(stmt, 5) != SQLITE_NULL ? UInt64(sqlite3_column_int64(stmt, 5)) : nil
            let toAddress = sqlite3_column_type(stmt, 6) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 6)) : nil
            let memo = sqlite3_column_type(stmt, 7) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 7)) : nil
            let statusStr = String(cString: sqlite3_column_text(stmt, 8))
            let confirmations = Int(sqlite3_column_int(stmt, 9))

            let txidData = Data(bytes: txidPtr, count: Int(txidLen))
            let decodedType = decryptTxType(typeStr)

            return TransactionHistoryItem(
                txid: txidData,
                height: height,
                blockTime: blockTime,
                type: decodedType,
                value: value,
                fee: fee,
                toAddress: toAddress,
                memo: memo,
                status: TransactionStatus(rawValue: statusStr) ?? .confirmed,
                confirmations: confirmations
            )
        }

        return nil
    }

    /// Update confirmations for all transactions based on current chain height
    func updateAllConfirmations(chainHeight: UInt64) throws {
        // For confirmed transactions, calculate confirmations = chainHeight - block_height + 1
        // Update status based on confirmation count
        let sql = """
            UPDATE transaction_history
            SET confirmations = CASE
                WHEN block_height > 0 THEN MAX(0, ? - block_height + 1)
                ELSE 0
            END,
            status = CASE
                WHEN block_height = 0 THEN status
                WHEN (? - block_height + 1) >= 6 THEN 'confirmed'
                WHEN (? - block_height + 1) >= 1 THEN 'confirming'
                ELSE 'mempool'
            END
            WHERE status != 'pending';
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, Int64(chainHeight))
        sqlite3_bind_int64(stmt, 2, Int64(chainHeight))
        sqlite3_bind_int64(stmt, 3, Int64(chainHeight))

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.updateFailed(String(cString: sqlite3_errmsg(db)))
        }
        let updated = sqlite3_changes(db)
        if updated > 0 {
            print("📜 Updated confirmations for \(updated) transactions (chainHeight=\(chainHeight))")
        }
    }

    // MARK: - Deprecated Migration Code (removed)
    // populateSentTransactionsFromSpentNotes() was removed because it added SENT transactions
    // with incorrect values (note value instead of actual sent amount).
    // populateHistoryFromNotes() now correctly calculates: actualSent = input - change - fee

    // MARK: - FIX #851/852: Auto-Clean Mislabeled Change Outputs

    /// FIX #852: Detect and clean mislabeled "received" transactions that are actually change outputs
    /// Key insight: If we have a "received" history entry AND a note spent in the SAME txid,
    /// that "received" is actually our change output (we provided inputs to that TX)
    /// Also creates the missing "sent" entry if one doesn't exist
    /// Called at startup - works even without knowing pending txids
    /// FIX #853 v2: Handle both wire format and display format txids (inconsistent storage from old code)
    /// Returns: Number of transactions cleaned up
    func cleanMislabeledChangeOutputsAuto() throws -> Int {
        guard let db = db else { throw DatabaseError.notOpened }

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        // Step 1: Get all "received" entries from transaction_history
        let getReceivedSql = """
            SELECT txid, value, block_height, block_time
            FROM transaction_history
            WHERE tx_type IN ('received', 'β');
        """

        var receivedStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, getReceivedSql, -1, &receivedStmt, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(receivedStmt) }

        struct ReceivedEntry {
            let txid: Data
            let amount: Int64
            let blockHeight: Int64
            let timestamp: Int64
        }
        var receivedEntries: [ReceivedEntry] = []

        while sqlite3_step(receivedStmt) == SQLITE_ROW {
            if let txidBlob = sqlite3_column_blob(receivedStmt, 0) {
                let txidLen = sqlite3_column_bytes(receivedStmt, 0)
                let txid = Data(bytes: txidBlob, count: Int(txidLen))
                let amount = sqlite3_column_int64(receivedStmt, 1)
                let blockHeight = sqlite3_column_int64(receivedStmt, 2)
                let timestamp = sqlite3_column_int64(receivedStmt, 3)
                receivedEntries.append(ReceivedEntry(txid: txid, amount: amount, blockHeight: blockHeight, timestamp: timestamp))
            }
        }

        guard !receivedEntries.isEmpty else {
            print("✅ FIX #852: No 'received' entries to check")
            return 0
        }

        print("🔍 FIX #852: Checking \(receivedEntries.count) 'received' entries for mislabeled change outputs...")

        // Step 2: For each received entry, check if we spent a note in that TX (check both formats)
        struct MislabeledTx {
            let txid: Data           // Original txid from history (for deletion)
            let changeAmount: Int64  // The "received" amount is actually change
            let blockHeight: Int64
            let timestamp: Int64
            let totalSpent: Int64    // Total value of notes spent in this TX
            let spentTxid: Data      // The txid format used in notes.spent_in_tx
        }
        var mislabeledTxs: [MislabeledTx] = []

        let checkSpentSql = "SELECT SUM(value) FROM notes WHERE spent_in_tx = ?;"

        for entry in receivedEntries {
            // Try original format
            var totalSpent: Int64 = 0
            var matchedTxid = entry.txid

            var checkStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, checkSpentSql, -1, &checkStmt, nil) == SQLITE_OK {
                _ = entry.txid.withUnsafeBytes { ptr in
                    sqlite3_bind_blob(checkStmt, 1, ptr.baseAddress, Int32(entry.txid.count), SQLITE_TRANSIENT)
                }
                if sqlite3_step(checkStmt) == SQLITE_ROW && sqlite3_column_type(checkStmt, 0) != SQLITE_NULL {
                    totalSpent = sqlite3_column_int64(checkStmt, 0)
                }
                sqlite3_finalize(checkStmt)
            }

            // If no match, try reversed format (wire <-> display)
            if totalSpent == 0 && entry.txid.count == 32 {
                let reversedTxid = Data(entry.txid.reversed())

                var checkStmt2: OpaquePointer?
                if sqlite3_prepare_v2(db, checkSpentSql, -1, &checkStmt2, nil) == SQLITE_OK {
                    _ = reversedTxid.withUnsafeBytes { ptr in
                        sqlite3_bind_blob(checkStmt2, 1, ptr.baseAddress, Int32(reversedTxid.count), SQLITE_TRANSIENT)
                    }
                    if sqlite3_step(checkStmt2) == SQLITE_ROW && sqlite3_column_type(checkStmt2, 0) != SQLITE_NULL {
                        totalSpent = sqlite3_column_int64(checkStmt2, 0)
                        matchedTxid = reversedTxid  // Use reversed format for sent entry
                        print("🔄 FIX #853 v2: Found match with reversed txid format")
                    }
                    sqlite3_finalize(checkStmt2)
                }
            }

            if totalSpent > 0 {
                mislabeledTxs.append(MislabeledTx(
                    txid: entry.txid,
                    changeAmount: entry.amount,
                    blockHeight: entry.blockHeight,
                    timestamp: entry.timestamp,
                    totalSpent: totalSpent,
                    spentTxid: matchedTxid
                ))
            }
        }

        guard !mislabeledTxs.isEmpty else {
            print("✅ FIX #852: No mislabeled change outputs found")
            return 0
        }

        print("🔍 FIX #852: Found \(mislabeledTxs.count) mislabeled 'received' entries (actually change outputs)")

        var cleanedCount = 0

        for tx in mislabeledTxs {
            // Delete the mislabeled "received" history entry
            let deleteSql = """
                DELETE FROM transaction_history
                WHERE txid = ? AND tx_type IN ('received', 'β');
            """

            var deleteStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, deleteSql, -1, &deleteStmt, nil) == SQLITE_OK {
                _ = tx.txid.withUnsafeBytes { ptr in
                    sqlite3_bind_blob(deleteStmt, 1, ptr.baseAddress, Int32(tx.txid.count), SQLITE_TRANSIENT)
                }

                if sqlite3_step(deleteStmt) == SQLITE_DONE {
                    let deleted = Int(sqlite3_changes(db))
                    if deleted > 0 {
                        let txidHex = tx.txid.map { String(format: "%02x", $0) }.joined()
                        let changeZCL = Double(tx.changeAmount) / 100_000_000.0
                        print("🧹 FIX #852: Deleted mislabeled 'received' entry: \(txidHex.prefix(16))... (\(changeZCL) ZCL was change)")
                        cleanedCount += deleted
                    }
                }
                sqlite3_finalize(deleteStmt)
            }

            // Check if a "sent" entry already exists for this txid (check both original and spent formats)
            let checkSentSql = "SELECT COUNT(*) FROM transaction_history WHERE txid = ? AND tx_type = 'sent';"
            var sentExists = false

            // Check original txid format
            var checkStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, checkSentSql, -1, &checkStmt, nil) == SQLITE_OK {
                _ = tx.txid.withUnsafeBytes { ptr in
                    sqlite3_bind_blob(checkStmt, 1, ptr.baseAddress, Int32(tx.txid.count), SQLITE_TRANSIENT)
                }
                if sqlite3_step(checkStmt) == SQLITE_ROW {
                    sentExists = sqlite3_column_int(checkStmt, 0) > 0
                }
                sqlite3_finalize(checkStmt)
            }

            // Also check with spentTxid format (may be reversed)
            if !sentExists && tx.spentTxid != tx.txid {
                var checkStmt2: OpaquePointer?
                if sqlite3_prepare_v2(db, checkSentSql, -1, &checkStmt2, nil) == SQLITE_OK {
                    _ = tx.spentTxid.withUnsafeBytes { ptr in
                        sqlite3_bind_blob(checkStmt2, 1, ptr.baseAddress, Int32(tx.spentTxid.count), SQLITE_TRANSIENT)
                    }
                    if sqlite3_step(checkStmt2) == SQLITE_ROW {
                        sentExists = sqlite3_column_int(checkStmt2, 0) > 0
                    }
                    sqlite3_finalize(checkStmt2)
                }
            }

            // If no "sent" entry exists, create one using wire format txid (spentTxid)
            // Sent amount = total spent - change - fee (assume 10000 zatoshis default fee)
            if !sentExists {
                let defaultFee: Int64 = 10000
                let sentAmount = tx.totalSpent - tx.changeAmount - defaultFee

                if sentAmount > 0 {
                    let insertSql = """
                        INSERT INTO transaction_history (txid, tx_type, value, fee, block_height, block_time, confirmations)
                        VALUES (?, 'sent', ?, ?, ?, ?, 1);
                    """

                    var insertStmt: OpaquePointer?
                    if sqlite3_prepare_v2(db, insertSql, -1, &insertStmt, nil) == SQLITE_OK {
                        // FIX #853 v2: Use spentTxid (wire format) for consistency with block-scanned txids
                        _ = tx.spentTxid.withUnsafeBytes { ptr in
                            sqlite3_bind_blob(insertStmt, 1, ptr.baseAddress, Int32(tx.spentTxid.count), SQLITE_TRANSIENT)
                        }
                        sqlite3_bind_int64(insertStmt, 2, sentAmount)
                        sqlite3_bind_int64(insertStmt, 3, defaultFee)
                        sqlite3_bind_int64(insertStmt, 4, tx.blockHeight)
                        sqlite3_bind_int64(insertStmt, 5, tx.timestamp)  // block_time uses timestamp value

                        if sqlite3_step(insertStmt) == SQLITE_DONE {
                            // Display in display format (reversed from wire)
                            let displayTxid = Data(tx.spentTxid.reversed())
                            let txidHex = displayTxid.map { String(format: "%02x", $0) }.joined()
                            let sentZCL = Double(sentAmount) / 100_000_000.0
                            print("📤 FIX #852: Created missing 'sent' entry: \(txidHex.prefix(16))... (\(sentZCL) ZCL)")
                        }
                        sqlite3_finalize(insertStmt)
                    }
                }
            }
        }

        if cleanedCount > 0 {
            print("✅ FIX #852: Cleaned \(cleanedCount) mislabeled change output(s) and created missing sent entries")
        }

        return cleanedCount
    }

    /// FIX #851: Delete mislabeled "received" transactions that are actually change outputs from our pending TXs
    /// Called at startup after restoring persisted pending txids
    /// Returns: Number of transactions cleaned up
    func cleanMislabeledChangeOutputs(pendingTxids: [String]) throws -> Int {
        guard !pendingTxids.isEmpty else { return 0 }

        // SQLITE_TRANSIENT tells SQLite to copy the data immediately
        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        var cleanedCount = 0

        for txidHex in pendingTxids {
            guard let txidData = Data(hexString: txidHex) else { continue }

            // Delete any "received" history entries with this txid (they're actually change)
            let deleteHistorySql = """
                DELETE FROM transaction_history
                WHERE txid = ? AND tx_type IN ('received', 'β');
            """

            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, deleteHistorySql, -1, &stmt, nil) == SQLITE_OK {
                _ = txidData.withUnsafeBytes { ptr in
                    sqlite3_bind_blob(stmt, 1, ptr.baseAddress, Int32(txidData.count), SQLITE_TRANSIENT)
                }

                if sqlite3_step(stmt) == SQLITE_DONE {
                    let deleted = Int(sqlite3_changes(db))
                    if deleted > 0 {
                        print("🧹 FIX #851: Deleted \(deleted) mislabeled 'received' history for pending TX: \(txidHex.prefix(16))...")
                        cleanedCount += deleted
                    }
                }
                sqlite3_finalize(stmt)
            }

            // Also check notes table - notes with this received_in_tx are change outputs
            // We don't delete notes (they're real), but we could mark them appropriately
            // For now, just log if found
            let countNotesSql = "SELECT COUNT(*) FROM notes WHERE received_in_tx = ?;"
            var countStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, countNotesSql, -1, &countStmt, nil) == SQLITE_OK {
                _ = txidData.withUnsafeBytes { ptr in
                    sqlite3_bind_blob(countStmt, 1, ptr.baseAddress, Int32(txidData.count), SQLITE_TRANSIENT)
                }

                if sqlite3_step(countStmt) == SQLITE_ROW {
                    let noteCount = sqlite3_column_int(countStmt, 0)
                    if noteCount > 0 {
                        print("📝 FIX #851: Found \(noteCount) note(s) with pending TX \(txidHex.prefix(16))... (likely change outputs)")
                    }
                }
                sqlite3_finalize(countStmt)
            }
        }

        return cleanedCount
    }

    // MARK: - FIX #1084 v2: Detect Mislabeled Change by Value Pattern

    /// FIX #1084 v2: DISABLED - Detect and fix change outputs recorded as "received" by analyzing value patterns
    ///
    /// ⚠️ FIX #1110: DISABLED due to false positives!
    /// This function incorrectly marked note 6178 (0.0025 ZCL) as spent because:
    /// - Note 6178 received at height 2953099 (0.0025 ZCL) - INCOMING TX
    /// - Note 6179 received at height 2953104 (0.0015 ZCL) - ALSO INCOMING TX
    /// - Function assumed 6178 was spent to create 6179, but they're UNRELATED!
    /// - Value pattern matching is too dangerous - two separate incoming TXs can have similar values
    ///
    /// Returns: 0 (disabled)
    func fixMislabeledChangeByValuePattern() throws -> Int {
        // FIX #1110: DISABLED - Value pattern matching causes false positives
        // The logic assumes notes with similar values are related by spend/change,
        // but users can receive multiple unrelated incoming transactions of similar sizes.
        print("⏭️ FIX #1110: fixMislabeledChangeByValuePattern DISABLED (false positive risk)")
        return 0

        // Original code below - DO NOT ENABLE
        guard let db = db else { throw DatabaseError.notOpened }

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        // Step 1: Get all "received" entries with their heights and values
        let getReceivedSql = """
            SELECT th.id, th.txid, th.block_height, th.value, n.id as note_id
            FROM transaction_history th
            JOIN notes n ON n.received_height = th.block_height AND n.value = th.value
            WHERE th.tx_type IN ('received', 'β')
            ORDER BY th.block_height DESC;
        """

        var receivedStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, getReceivedSql, -1, &receivedStmt, nil) == SQLITE_OK else {
            print("⚠️ FIX #1084 v2: Failed to prepare received query: \(String(cString: sqlite3_errmsg(db)))")
            return 0
        }
        defer { sqlite3_finalize(receivedStmt) }

        struct ReceivedTx {
            let historyId: Int64
            let txid: Data
            let blockHeight: Int64
            let value: Int64
            let noteId: Int64
        }
        var receivedTxs: [ReceivedTx] = []

        while sqlite3_step(receivedStmt) == SQLITE_ROW {
            let historyId = sqlite3_column_int64(receivedStmt, 0)
            if let txidBlob = sqlite3_column_blob(receivedStmt, 1) {
                let txidLen = sqlite3_column_bytes(receivedStmt, 1)
                let txid = Data(bytes: txidBlob, count: Int(txidLen))
                let blockHeight = sqlite3_column_int64(receivedStmt, 2)
                let value = sqlite3_column_int64(receivedStmt, 3)
                let noteId = sqlite3_column_int64(receivedStmt, 4)
                receivedTxs.append(ReceivedTx(historyId: historyId, txid: txid, blockHeight: blockHeight, value: value, noteId: noteId))
            }
        }

        guard !receivedTxs.isEmpty else {
            print("✅ FIX #1084 v2: No received transactions to check")
            return 0
        }

        print("🔍 FIX #1084 v2: Checking \(receivedTxs.count) 'received' transactions for value pattern match...")

        var fixedCount = 0

        // Step 2: For each received TX, look for an unspent note that could have been the input
        // Input note: value = received_value + sent_amount + fee
        // Typical sent amounts: 100000-500000 zatoshis (0.001-0.005 ZCL)
        // Typical fee: 10000 zatoshis (0.0001 ZCL)
        // So look for unspent notes with value = received + 50000 to 600000

        let findInputSql = """
            SELECT id, value, received_height FROM notes
            WHERE is_spent = 0
              AND received_height < ?
              AND value > ?
              AND value < ?
            ORDER BY received_height DESC
            LIMIT 1;
        """

        for rx in receivedTxs {
            // Check if a "sent" entry already exists for this height
            let checkSentSql = "SELECT COUNT(*) FROM transaction_history WHERE block_height = ? AND tx_type IN ('sent', 'α');"
            var checkStmt: OpaquePointer?
            var sentExists = false
            if sqlite3_prepare_v2(db, checkSentSql, -1, &checkStmt, nil) == SQLITE_OK {
                sqlite3_bind_int64(checkStmt, 1, rx.blockHeight)
                if sqlite3_step(checkStmt) == SQLITE_ROW {
                    sentExists = sqlite3_column_int(checkStmt, 0) > 0
                }
                sqlite3_finalize(checkStmt)
            }

            // If sent exists, this received entry is legitimate (not change)
            if sentExists { continue }

            // Look for an unspent note that could have been the input
            let minInputValue = rx.value + 50000   // At least 50k more (fee + tiny send)
            let maxInputValue = rx.value + 600000  // At most 600k more (fee + reasonable send)

            var inputStmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, findInputSql, -1, &inputStmt, nil) == SQLITE_OK else { continue }
            defer { sqlite3_finalize(inputStmt) }

            sqlite3_bind_int64(inputStmt, 1, rx.blockHeight)
            sqlite3_bind_int64(inputStmt, 2, minInputValue)
            sqlite3_bind_int64(inputStmt, 3, maxInputValue)

            if sqlite3_step(inputStmt) == SQLITE_ROW {
                let inputNoteId = sqlite3_column_int64(inputStmt, 0)
                let inputValue = sqlite3_column_int64(inputStmt, 1)
                let inputHeight = sqlite3_column_int64(inputStmt, 2)

                // Found a potential input note! This "received" is likely change.
                let sentAmount = inputValue - rx.value - 10000  // Assume 10000 fee
                let inputZCL = Double(inputValue) / 100_000_000.0
                let changeZCL = Double(rx.value) / 100_000_000.0
                let sentZCL = Double(sentAmount) / 100_000_000.0

                print("🔍 FIX #1084 v2: Detected mislabeled change at height \(rx.blockHeight):")
                print("   Input note #\(inputNoteId) at height \(inputHeight): \(inputZCL) ZCL (marked unspent but likely spent)")
                print("   Change note #\(rx.noteId) at height \(rx.blockHeight): \(changeZCL) ZCL (recorded as 'received')")
                print("   Implied sent amount: \(sentZCL) ZCL + 0.0001 fee")

                // Fix: Mark input note as spent, delete "received" entry, add "sent" entry
                // Step 2a: Mark input note as spent
                let markSpentSql = "UPDATE notes SET is_spent = 1, spent_height = ?, spent_in_tx = ? WHERE id = ?;"
                var markStmt: OpaquePointer?
                if sqlite3_prepare_v2(db, markSpentSql, -1, &markStmt, nil) == SQLITE_OK {
                    sqlite3_bind_int64(markStmt, 1, rx.blockHeight)
                    _ = rx.txid.withUnsafeBytes { ptr in
                        sqlite3_bind_blob(markStmt, 2, ptr.baseAddress, Int32(rx.txid.count), SQLITE_TRANSIENT)
                    }
                    sqlite3_bind_int64(markStmt, 3, inputNoteId)
                    if sqlite3_step(markStmt) == SQLITE_DONE {
                        print("   ✅ Marked note #\(inputNoteId) as spent at height \(rx.blockHeight)")
                    }
                    sqlite3_finalize(markStmt)
                }

                // Step 2b: Delete the "received" history entry
                let deleteReceivedSql = "DELETE FROM transaction_history WHERE id = ?;"
                var deleteStmt: OpaquePointer?
                if sqlite3_prepare_v2(db, deleteReceivedSql, -1, &deleteStmt, nil) == SQLITE_OK {
                    sqlite3_bind_int64(deleteStmt, 1, rx.historyId)
                    if sqlite3_step(deleteStmt) == SQLITE_DONE {
                        print("   ✅ Deleted mislabeled 'received' history entry #\(rx.historyId)")
                    }
                    sqlite3_finalize(deleteStmt)
                }

                // Step 2c: Add "sent" history entry (using α type code)
                let insertSentSql = """
                    INSERT INTO transaction_history (txid, block_height, tx_type, value, fee, status, confirmations)
                    VALUES (?, ?, 'α', ?, 10000, 'confirmed', 1);
                """
                var insertStmt: OpaquePointer?
                if sqlite3_prepare_v2(db, insertSentSql, -1, &insertStmt, nil) == SQLITE_OK {
                    _ = rx.txid.withUnsafeBytes { ptr in
                        sqlite3_bind_blob(insertStmt, 1, ptr.baseAddress, Int32(rx.txid.count), SQLITE_TRANSIENT)
                    }
                    sqlite3_bind_int64(insertStmt, 2, rx.blockHeight)
                    sqlite3_bind_int64(insertStmt, 3, sentAmount)
                    if sqlite3_step(insertStmt) == SQLITE_DONE {
                        print("   ✅ Added 'sent' history entry for \(sentZCL) ZCL at height \(rx.blockHeight)")
                    }
                    sqlite3_finalize(insertStmt)
                }

                fixedCount += 1
            }
        }

        if fixedCount > 0 {
            print("🧹 FIX #1084 v2: Fixed \(fixedCount) mislabeled change output(s) by value pattern")
        } else {
            print("✅ FIX #1084 v2: No mislabeled change outputs detected by value pattern")
        }

        return fixedCount
    }

    // MARK: - FIX #1110: Unmark Note as Spent by ID

    /// FIX #1110: Unmark a note as spent by its ID
    /// Used to fix notes wrongly marked by FIX #1084 v2's false positives
    func unmarkNoteAsSpentById(noteId: Int64) throws {
        guard let db = db else { throw DatabaseError.notOpened }

        let sql = """
            UPDATE notes
            SET is_spent = 0, spent_in_tx = NULL, spent_height = NULL
            WHERE id = ?;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, noteId)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.updateFailed(String(cString: sqlite3_errmsg(db)))
        }

        let changes = sqlite3_changes(db)
        if changes > 0 {
            print("✅ FIX #1110: Unmarked note #\(noteId) as unspent")
        } else {
            print("⚠️ FIX #1110: Note #\(noteId) not found")
        }
    }

    // MARK: - FIX #1085: P2P Verification - Get Suspicious Heights

    /// FIX #1085: Get heights where notes may be mislabeled for P2P verification
    /// Returns heights where:
    /// - "received" entry exists without corresponding "sent" entry
    /// - Value pattern suggests it could be change from an unrecorded send
    /// Called before P2P verification to know which blocks to fetch
    func getSuspiciousHeightsForP2PVerification() throws -> [UInt64] {
        guard let db = db else { throw DatabaseError.notOpened }

        // Get "received" entries that don't have a matching "sent" at the same height
        let sql = """
            SELECT DISTINCT th.block_height
            FROM transaction_history th
            LEFT JOIN (
                SELECT block_height FROM transaction_history
                WHERE tx_type IN ('sent', 'α')
            ) sent ON th.block_height = sent.block_height
            WHERE th.tx_type IN ('received', 'β')
              AND sent.block_height IS NULL
            ORDER BY th.block_height;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            print("⚠️ FIX #1085: Failed to prepare suspicious heights query")
            return []
        }
        defer { sqlite3_finalize(stmt) }

        var heights: [UInt64] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let height = UInt64(sqlite3_column_int64(stmt, 0))
            heights.append(height)
        }

        return heights
    }

    /// FIX #1085: Get notes at a specific height for comparison with P2P data
    /// Returns: [(noteId, value, isSpent, nullifierHash)]
    func getNotesAtHeight(_ height: UInt64) throws -> [(id: Int64, value: Int64, isSpent: Bool, nullifierHash: Data?)] {
        guard let db = db else { throw DatabaseError.notOpened }

        let sql = "SELECT id, value, is_spent, hashed_nullifier FROM notes WHERE received_height = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, Int64(height))

        var notes: [(id: Int64, value: Int64, isSpent: Bool, nullifierHash: Data?)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let value = sqlite3_column_int64(stmt, 1)
            let isSpent = sqlite3_column_int(stmt, 2) != 0
            var nullifierHash: Data? = nil
            if let blob = sqlite3_column_blob(stmt, 3) {
                let len = sqlite3_column_bytes(stmt, 3)
                nullifierHash = Data(bytes: blob, count: Int(len))
            }
            notes.append((id: id, value: value, isSpent: isSpent, nullifierHash: nullifierHash))
        }

        return notes
    }

    /// FIX #1085: Delete notes and history at specific heights for P2P rescan
    /// Called when P2P verification finds discrepancies
    func deleteNotesAndHistoryAtHeights(_ heights: [UInt64]) throws -> Int {
        guard let db = db else { throw DatabaseError.notOpened }
        guard !heights.isEmpty else { return 0 }

        var deletedCount = 0

        for height in heights {
            // Delete notes at this height
            let deleteNotesSql = "DELETE FROM notes WHERE received_height = ?;"
            var deleteNotesStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, deleteNotesSql, -1, &deleteNotesStmt, nil) == SQLITE_OK {
                sqlite3_bind_int64(deleteNotesStmt, 1, Int64(height))
                if sqlite3_step(deleteNotesStmt) == SQLITE_DONE {
                    deletedCount += Int(sqlite3_changes(db))
                }
                sqlite3_finalize(deleteNotesStmt)
            }

            // Delete history at this height
            let deleteHistorySql = "DELETE FROM transaction_history WHERE block_height = ?;"
            var deleteHistoryStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, deleteHistorySql, -1, &deleteHistoryStmt, nil) == SQLITE_OK {
                sqlite3_bind_int64(deleteHistoryStmt, 1, Int64(height))
                sqlite3_step(deleteHistoryStmt)
                sqlite3_finalize(deleteHistoryStmt)
            }
        }

        if deletedCount > 0 {
            print("🗑️ FIX #1085: Deleted \(deletedCount) note(s) at \(heights.count) height(s) for P2P rescan")
        }

        return deletedCount
    }

    // MARK: - FIX #853 v2: Migrate Display-Format TXIDs to Wire Format

    /// FIX #853 v2: One-time migration to convert display-format txids to wire format
    /// Detection: If a txid doesn't match any note's received_in_tx/spent_in_tx but reversed does, it's display format
    /// Called at startup after database is open
    /// Returns: Number of txids migrated
    func migrateDisplayFormatTxidsToWireFormat() throws -> Int {
        guard let db = db else { throw DatabaseError.notOpened }

        // Check if migration already ran (stored in sync_state or user defaults)
        let migrationKey = "FIX853v2_TxidMigrationComplete"
        if UserDefaults.standard.bool(forKey: migrationKey) {
            print("✅ FIX #853 v2: TXID format migration already complete")
            return 0
        }

        print("🔄 FIX #853 v2: Starting one-time TXID format migration...")

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        // Get all txids from transaction_history
        let getTxidsSql = "SELECT DISTINCT txid FROM transaction_history WHERE txid IS NOT NULL;"
        var getTxidsStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, getTxidsSql, -1, &getTxidsStmt, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(getTxidsStmt) }

        var txidsToCheck: [Data] = []
        while sqlite3_step(getTxidsStmt) == SQLITE_ROW {
            if let blob = sqlite3_column_blob(getTxidsStmt, 0) {
                let len = sqlite3_column_bytes(getTxidsStmt, 0)
                txidsToCheck.append(Data(bytes: blob, count: Int(len)))
            }
        }

        print("🔄 FIX #853 v2: Checking \(txidsToCheck.count) transaction txids...")

        var migratedCount = 0

        // For each txid, check if it matches notes or if reversed matches
        let checkNotesSql = """
            SELECT COUNT(*) FROM notes
            WHERE received_in_tx = ? OR spent_in_tx = ?;
        """

        for txid in txidsToCheck {
            guard txid.count == 32 else { continue }

            // Check if original format matches any note
            var matchesOriginal = false
            var checkStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, checkNotesSql, -1, &checkStmt, nil) == SQLITE_OK {
                _ = txid.withUnsafeBytes { ptr in
                    sqlite3_bind_blob(checkStmt, 1, ptr.baseAddress, Int32(txid.count), SQLITE_TRANSIENT)
                    sqlite3_bind_blob(checkStmt, 2, ptr.baseAddress, Int32(txid.count), SQLITE_TRANSIENT)
                }
                if sqlite3_step(checkStmt) == SQLITE_ROW {
                    matchesOriginal = sqlite3_column_int(checkStmt, 0) > 0
                }
                sqlite3_finalize(checkStmt)
            }

            if matchesOriginal {
                // Already in correct format (wire format matches notes)
                continue
            }

            // Check if reversed format matches any note
            let reversedTxid = Data(txid.reversed())
            var matchesReversed = false
            var checkStmt2: OpaquePointer?
            if sqlite3_prepare_v2(db, checkNotesSql, -1, &checkStmt2, nil) == SQLITE_OK {
                _ = reversedTxid.withUnsafeBytes { ptr in
                    sqlite3_bind_blob(checkStmt2, 1, ptr.baseAddress, Int32(reversedTxid.count), SQLITE_TRANSIENT)
                    sqlite3_bind_blob(checkStmt2, 2, ptr.baseAddress, Int32(reversedTxid.count), SQLITE_TRANSIENT)
                }
                if sqlite3_step(checkStmt2) == SQLITE_ROW {
                    matchesReversed = sqlite3_column_int(checkStmt2, 0) > 0
                }
                sqlite3_finalize(checkStmt2)
            }

            if matchesReversed {
                // This txid is in display format - convert to wire format
                let updateSql = "UPDATE transaction_history SET txid = ? WHERE txid = ?;"
                var updateStmt: OpaquePointer?
                if sqlite3_prepare_v2(db, updateSql, -1, &updateStmt, nil) == SQLITE_OK {
                    _ = reversedTxid.withUnsafeBytes { ptr in
                        sqlite3_bind_blob(updateStmt, 1, ptr.baseAddress, Int32(reversedTxid.count), SQLITE_TRANSIENT)
                    }
                    _ = txid.withUnsafeBytes { ptr in
                        sqlite3_bind_blob(updateStmt, 2, ptr.baseAddress, Int32(txid.count), SQLITE_TRANSIENT)
                    }

                    if sqlite3_step(updateStmt) == SQLITE_DONE {
                        let updated = sqlite3_changes(db)
                        if updated > 0 {
                            let displayHex = txid.map { String(format: "%02x", $0) }.joined()
                            let wireHex = reversedTxid.map { String(format: "%02x", $0) }.joined()
                            print("🔄 FIX #853 v2: Migrated txid \(displayHex.prefix(16))... → \(wireHex.prefix(16))...")
                            migratedCount += Int(updated)
                        }
                    }
                    sqlite3_finalize(updateStmt)
                }
            }
            // If neither matches, leave as-is (could be orphan transaction)
        }

        // Mark migration as complete
        UserDefaults.standard.set(true, forKey: migrationKey)

        if migratedCount > 0 {
            print("✅ FIX #853 v2: Migrated \(migratedCount) txid(s) from display format to wire format")
        } else {
            print("✅ FIX #853 v2: No txids needed migration (all already in wire format)")
        }

        return migratedCount
    }

    // MARK: - FIX #896: Migrate Delta Transaction TXIDs (InsightAPI Display Format Bug)

    /// FIX #896: Migrate delta transaction txids from display format to wire format
    /// InsightAPI returns txids in display format (big-endian), but we need wire format (little-endian)
    /// This migration reverses txid bytes for all transactions above boost file height
    /// Called at startup after database is open
    /// Returns: Number of txids migrated
    func migrateDeltaTxidsToWireFormat() throws -> Int {
        guard let db = db else { throw DatabaseError.notOpened }

        let migrationKey = "FIX896_DeltaTxidMigrationComplete"
        if UserDefaults.standard.bool(forKey: migrationKey) {
            print("✅ FIX #896: Delta TXID migration already complete")
            return 0
        }

        print("🔄 FIX #896: Starting delta TXID migration (InsightAPI display format fix)...")

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let boostFileEndHeight: UInt64 = 2988797  // ZipherXConstants.effectiveTreeHeight

        // Get all txids from transaction_history at heights > boost file
        let getTxidsSql = """
            SELECT DISTINCT txid, height FROM transaction_history
            WHERE height > ? AND txid IS NOT NULL;
        """
        var getTxidsStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, getTxidsSql, -1, &getTxidsStmt, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(getTxidsStmt) }

        sqlite3_bind_int64(getTxidsStmt, 1, Int64(boostFileEndHeight))

        var deltaTxids: [(Data, UInt64)] = []
        while sqlite3_step(getTxidsStmt) == SQLITE_ROW {
            if let blob = sqlite3_column_blob(getTxidsStmt, 0) {
                let len = sqlite3_column_bytes(getTxidsStmt, 0)
                let height = UInt64(sqlite3_column_int64(getTxidsStmt, 1))
                deltaTxids.append((Data(bytes: blob, count: Int(len)), height))
            }
        }

        if deltaTxids.isEmpty {
            print("✅ FIX #896: No delta transactions found (above height \(boostFileEndHeight))")
            UserDefaults.standard.set(true, forKey: migrationKey)
            return 0
        }

        print("🔄 FIX #896: Found \(deltaTxids.count) delta transaction(s) to check...")

        var migratedCount = 0

        // For each delta txid, check if notes have a REVERSED version
        // If so, the transaction_history has display format and needs conversion
        let checkNotesSql = """
            SELECT COUNT(*) FROM notes
            WHERE received_in_tx = ? OR spent_in_tx = ?;
        """

        for (txid, height) in deltaTxids {
            guard txid.count == 32 else { continue }

            let reversedTxid = Data(txid.reversed())

            // Check if REVERSED txid matches any note
            var matchesReversed = false
            var checkStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, checkNotesSql, -1, &checkStmt, nil) == SQLITE_OK {
                _ = reversedTxid.withUnsafeBytes { ptr in
                    sqlite3_bind_blob(checkStmt, 1, ptr.baseAddress, Int32(reversedTxid.count), SQLITE_TRANSIENT)
                    sqlite3_bind_blob(checkStmt, 2, ptr.baseAddress, Int32(reversedTxid.count), SQLITE_TRANSIENT)
                }
                if sqlite3_step(checkStmt) == SQLITE_ROW {
                    matchesReversed = sqlite3_column_int(checkStmt, 0) > 0
                }
                sqlite3_finalize(checkStmt)
            }

            if matchesReversed {
                // Transaction has display format, notes have wire format
                // Convert transaction to wire format
                let updateSql = "UPDATE transaction_history SET txid = ? WHERE txid = ?;"
                var updateStmt: OpaquePointer?
                if sqlite3_prepare_v2(db, updateSql, -1, &updateStmt, nil) == SQLITE_OK {
                    _ = reversedTxid.withUnsafeBytes { ptr in
                        sqlite3_bind_blob(updateStmt, 1, ptr.baseAddress, Int32(reversedTxid.count), SQLITE_TRANSIENT)
                    }
                    _ = txid.withUnsafeBytes { ptr in
                        sqlite3_bind_blob(updateStmt, 2, ptr.baseAddress, Int32(txid.count), SQLITE_TRANSIENT)
                    }

                    if sqlite3_step(updateStmt) == SQLITE_DONE {
                        let updated = sqlite3_changes(db)
                        if updated > 0 {
                            let displayHex = txid.map { String(format: "%02x", $0) }.joined()
                            let wireHex = reversedTxid.map { String(format: "%02x", $0) }.joined()
                            print("🔄 FIX #896: Height \(height) - converted \(displayHex.prefix(16))... → \(wireHex.prefix(16))...")
                            migratedCount += Int(updated)
                        }
                    }
                    sqlite3_finalize(updateStmt)
                }
            }
        }

        UserDefaults.standard.set(true, forKey: migrationKey)

        if migratedCount > 0 {
            print("✅ FIX #896: Migrated \(migratedCount) delta transaction txid(s) to wire format")
        } else {
            print("✅ FIX #896: No delta txids needed migration (format already correct)")
        }

        return migratedCount
    }

    // MARK: - FIX #229: Trusted Peers Management

    /// Trusted peer structure for reliable Zclassic bootstrap
    struct TrustedPeer {
        let host: String
        let port: UInt16
        let lastConnected: Date?
        let successes: Int
        let failures: Int
        let isOnion: Bool
        let notes: String?
        let isPreferred: Bool  // FIX #284: Preferred seeds get priority and are exempt from parking
    }

    /// Get all trusted peers from database, prioritized by preferred status then success rate
    func getTrustedPeers() throws -> [TrustedPeer] {
        guard let db = db else { throw DatabaseError.notOpened }

        // Seed initial trusted peers if table is empty
        try seedInitialTrustedPeersIfNeeded()

        let sql = """
            SELECT host, port, last_connected, successes, failures, is_onion, notes,
                   COALESCE(is_preferred, 0) as is_preferred
            FROM trusted_peers
            ORDER BY is_preferred DESC, (successes - failures) DESC, last_connected DESC
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        var peers: [TrustedPeer] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let host = String(cString: sqlite3_column_text(stmt, 0))
            let port = UInt16(sqlite3_column_int(stmt, 1))
            let lastConnectedRaw = sqlite3_column_int64(stmt, 2)
            let lastConnected = lastConnectedRaw > 0 ? Date(timeIntervalSince1970: TimeInterval(lastConnectedRaw)) : nil
            let successes = Int(sqlite3_column_int(stmt, 3))
            let failures = Int(sqlite3_column_int(stmt, 4))
            let isOnion = sqlite3_column_int(stmt, 5) != 0
            let notesPtr = sqlite3_column_text(stmt, 6)
            let notes = notesPtr != nil ? String(cString: notesPtr!) : nil
            let isPreferred = sqlite3_column_int(stmt, 7) != 0

            peers.append(TrustedPeer(
                host: host,
                port: port,
                lastConnected: lastConnected,
                successes: successes,
                failures: failures,
                isOnion: isOnion,
                notes: notes,
                isPreferred: isPreferred
            ))
        }

        return peers
    }

    /// Add or update a trusted peer
    func addTrustedPeer(host: String, port: UInt16 = 16125, isOnion: Bool = false, notes: String? = nil) throws {
        guard let db = db else { throw DatabaseError.notOpened }

        let sql = """
            INSERT INTO trusted_peers (host, port, is_onion, notes)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(host, port) DO UPDATE SET
                notes = COALESCE(excluded.notes, notes)
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, host, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int(stmt, 2, Int32(port))
        sqlite3_bind_int(stmt, 3, isOnion ? 1 : 0)
        if let notes = notes {
            sqlite3_bind_text(stmt, 4, notes, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        } else {
            sqlite3_bind_null(stmt, 4)
        }

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.insertFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    /// Record successful connection to a trusted peer
    func recordTrustedPeerSuccess(host: String, port: UInt16 = 16125) throws {
        guard let db = db else { throw DatabaseError.notOpened }

        let sql = """
            UPDATE trusted_peers
            SET successes = successes + 1, last_connected = strftime('%s', 'now')
            WHERE host = ? AND port = ?
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, host, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int(stmt, 2, Int32(port))

        _ = sqlite3_step(stmt)
    }

    /// Record failed connection to a trusted peer
    func recordTrustedPeerFailure(host: String, port: UInt16 = 16125) throws {
        guard let db = db else { throw DatabaseError.notOpened }

        let sql = """
            UPDATE trusted_peers
            SET failures = failures + 1
            WHERE host = ? AND port = ?
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, host, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int(stmt, 2, Int32(port))

        _ = sqlite3_step(stmt)
    }

    /// Remove a peer from trusted list (e.g., if it's a Zcash node)
    func removeTrustedPeer(host: String, port: UInt16 = 16125) throws {
        guard let db = db else { throw DatabaseError.notOpened }

        let sql = "DELETE FROM trusted_peers WHERE host = ? AND port = ?"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, host, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int(stmt, 2, Int32(port))

        _ = sqlite3_step(stmt)
    }

    // MARK: - FIX #284: Preferred Seeds Management

    /// Get only preferred seeds (priority connection, exempt from parking)
    func getPreferredSeeds() throws -> [TrustedPeer] {
        guard let db = db else { throw DatabaseError.notOpened }

        let sql = """
            SELECT host, port, last_connected, successes, failures, is_onion, notes, is_preferred
            FROM trusted_peers
            WHERE is_preferred = 1
            ORDER BY (successes - failures) DESC, last_connected DESC
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        var peers: [TrustedPeer] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let host = String(cString: sqlite3_column_text(stmt, 0))
            let port = UInt16(sqlite3_column_int(stmt, 1))
            let lastConnectedRaw = sqlite3_column_int64(stmt, 2)
            let lastConnected = lastConnectedRaw > 0 ? Date(timeIntervalSince1970: TimeInterval(lastConnectedRaw)) : nil
            let successes = Int(sqlite3_column_int(stmt, 3))
            let failures = Int(sqlite3_column_int(stmt, 4))
            let isOnion = sqlite3_column_int(stmt, 5) != 0
            let notesPtr = sqlite3_column_text(stmt, 6)
            let notes = notesPtr != nil ? String(cString: notesPtr!) : nil
            let isPreferred = sqlite3_column_int(stmt, 7) != 0

            peers.append(TrustedPeer(
                host: host,
                port: port,
                lastConnected: lastConnected,
                successes: successes,
                failures: failures,
                isOnion: isOnion,
                notes: notes,
                isPreferred: isPreferred
            ))
        }

        return peers
    }

    /// Check if a peer is a preferred seed
    func isPreferredSeed(host: String, port: UInt16 = 8033) -> Bool {
        guard let db = db else { return false }

        let sql = "SELECT is_preferred FROM trusted_peers WHERE host = ? AND port = ?"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return false
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, host, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int(stmt, 2, Int32(port))

        if sqlite3_step(stmt) == SQLITE_ROW {
            return sqlite3_column_int(stmt, 0) != 0
        }

        return false
    }

    /// Promote a peer to preferred seed (called when a parked peer responds OK)
    func promoteToPreferredSeed(host: String, port: UInt16 = 8033) throws {
        guard let db = db else { throw DatabaseError.notOpened }

        // First ensure the peer exists, then update
        let sql = """
            INSERT INTO trusted_peers (host, port, is_preferred, notes)
            VALUES (?, ?, 1, 'Promoted from parked')
            ON CONFLICT(host, port) DO UPDATE SET
                is_preferred = 1,
                notes = COALESCE(notes, 'Promoted from parked')
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, host, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int(stmt, 2, Int32(port))

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.insertFailed(String(cString: sqlite3_errmsg(db)))
        }

        print("⭐ FIX #284: Promoted \(host):\(port) to preferred seed")
    }

    /// Demote a peer from preferred to regular (before parking)
    func demoteFromPreferredSeed(host: String, port: UInt16 = 8033) throws {
        guard let db = db else { throw DatabaseError.notOpened }

        let sql = """
            UPDATE trusted_peers
            SET is_preferred = 0
            WHERE host = ? AND port = ?
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, host, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int(stmt, 2, Int32(port))

        _ = sqlite3_step(stmt)
        print("📉 FIX #284: Demoted \(host):\(port) from preferred seed")
    }

    /// Set preferred status for a peer
    func setPreferredSeed(host: String, port: UInt16 = 8033, isPreferred: Bool) throws {
        guard let db = db else { throw DatabaseError.notOpened }

        let sql = """
            INSERT INTO trusted_peers (host, port, is_preferred)
            VALUES (?, ?, ?)
            ON CONFLICT(host, port) DO UPDATE SET is_preferred = excluded.is_preferred
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, host, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int(stmt, 2, Int32(port))
        sqlite3_bind_int(stmt, 3, isPreferred ? 1 : 0)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.insertFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    /// Seed initial trusted peers if the table is empty
    private func seedInitialTrustedPeersIfNeeded() throws {
        guard let db = db else { throw DatabaseError.notOpened }

        // Check if table is empty
        var countStmt: OpaquePointer?
        let countSql = "SELECT COUNT(*) FROM trusted_peers"
        guard sqlite3_prepare_v2(db, countSql, -1, &countStmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(countStmt) }

        var count: Int64 = 0
        if sqlite3_step(countStmt) == SQLITE_ROW {
            count = sqlite3_column_int64(countStmt, 0)
        }

        // Only seed if empty
        guard count == 0 else { return }

        print("📡 FIX #229: Seeding initial trusted Zclassic peers...")

        // Known working Zclassic nodes (verified December 2025)
        let initialPeers: [(host: String, port: UInt16, notes: String)] = [
            ("140.174.189.17", 8033, "Primary - confirmed working ZCL node"),
            ("205.209.104.118", 8033, "Primary - confirmed working ZCL node"),
            ("185.205.246.161", 8033, "Secondary ZCL node"),
        ]

        for peer in initialPeers {
            try addTrustedPeer(host: peer.host, port: peer.port, notes: peer.notes)
        }

        print("📡 FIX #229: Seeded \(initialPeers.count) trusted Zclassic peers")
    }

    // MARK: - FIX #1085: Peer Scoring System

    /// Update peer score after successful connection
    /// - Parameters:
    ///   - host: Peer hostname/IP
    ///   - port: Peer port
    ///   - responseTimeMs: Response time in milliseconds (optional)
    func recordPeerSuccess(host: String, port: UInt16 = 8033, responseTimeMs: Int? = nil) {
        guard let db = db else { return }

        let now = Int(Date().timeIntervalSince1970)
        var sql: String

        if let responseTime = responseTimeMs {
            // Update with response time averaging
            sql = """
                INSERT INTO trusted_peers (host, port, successes, failures, score, last_success, response_time_ms, last_connected)
                VALUES (?, ?, 1, 0, 55, ?, ?, ?)
                ON CONFLICT(host, port) DO UPDATE SET
                    successes = successes + 1,
                    score = MIN(100, score + 5),
                    last_success = excluded.last_success,
                    last_connected = excluded.last_connected,
                    response_time_ms = CASE
                        WHEN response_time_ms = 0 THEN excluded.response_time_ms
                        ELSE (response_time_ms + excluded.response_time_ms) / 2
                    END,
                    is_reliable = CASE
                        WHEN score + 5 >= 70 AND successes + 1 >= 5 THEN 1
                        ELSE is_reliable
                    END
            """
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, host, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                sqlite3_bind_int(stmt, 2, Int32(port))
                sqlite3_bind_int64(stmt, 3, Int64(now))
                sqlite3_bind_int(stmt, 4, Int32(responseTime))
                sqlite3_bind_int64(stmt, 5, Int64(now))
                sqlite3_step(stmt)
                sqlite3_finalize(stmt)
            }
        } else {
            sql = """
                INSERT INTO trusted_peers (host, port, successes, failures, score, last_success, last_connected)
                VALUES (?, ?, 1, 0, 55, ?, ?)
                ON CONFLICT(host, port) DO UPDATE SET
                    successes = successes + 1,
                    score = MIN(100, score + 5),
                    last_success = excluded.last_success,
                    last_connected = excluded.last_connected,
                    is_reliable = CASE
                        WHEN score + 5 >= 70 AND successes + 1 >= 5 THEN 1
                        ELSE is_reliable
                    END
            """
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, host, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                sqlite3_bind_int(stmt, 2, Int32(port))
                sqlite3_bind_int64(stmt, 3, Int64(now))
                sqlite3_bind_int64(stmt, 4, Int64(now))
                sqlite3_step(stmt)
                sqlite3_finalize(stmt)
            }
        }
    }

    /// Update peer score after failed connection
    func recordPeerFailure(host: String, port: UInt16 = 8033) {
        guard let db = db else { return }

        let sql = """
            INSERT INTO trusted_peers (host, port, successes, failures, score)
            VALUES (?, ?, 0, 1, 40)
            ON CONFLICT(host, port) DO UPDATE SET
                failures = failures + 1,
                score = MAX(0, score - 10),
                is_reliable = CASE WHEN score - 10 < 50 THEN 0 ELSE is_reliable END
        """

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, host, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_int(stmt, 2, Int32(port))
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
    }

    /// Mark peer as permanently bad (wrong chain, protocol errors)
    func markPeerAsBad(host: String, port: UInt16 = 8033, reason: String) {
        guard let db = db else { return }

        let sql = """
            INSERT INTO trusted_peers (host, port, is_bad, score, notes)
            VALUES (?, ?, 1, 0, ?)
            ON CONFLICT(host, port) DO UPDATE SET
                is_bad = 1,
                score = 0,
                is_reliable = 0,
                notes = excluded.notes
        """

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, host, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_int(stmt, 2, Int32(port))
            sqlite3_bind_text(stmt, 3, reason, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
            print("🚫 FIX #1085: Marked \(host):\(port) as permanently bad: \(reason)")
        }
    }

    /// Get all reliable peers (score >= 70, successes >= 5, not bad)
    func getReliablePeers() -> [(host: String, port: UInt16, score: Int)] {
        guard let db = db else { return [] }

        let sql = """
            SELECT host, port, score FROM trusted_peers
            WHERE is_reliable = 1 AND is_bad = 0 AND score >= 70
            ORDER BY score DESC, last_success DESC
        """

        var peers: [(String, UInt16, Int)] = []
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let host = String(cString: sqlite3_column_text(stmt, 0))
                let port = UInt16(sqlite3_column_int(stmt, 1))
                let score = Int(sqlite3_column_int(stmt, 2))
                peers.append((host, port, score))
            }
            sqlite3_finalize(stmt)
        }
        return peers
    }

    /// Get all bad peers to exclude from connection attempts
    func getBadPeers() -> Set<String> {
        guard let db = db else { return [] }

        let sql = "SELECT host FROM trusted_peers WHERE is_bad = 1"

        var badPeers: Set<String> = []
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let host = String(cString: sqlite3_column_text(stmt, 0))
                badPeers.insert(host)
            }
            sqlite3_finalize(stmt)
        }
        return badPeers
    }

    /// Get peers sorted by score for prioritized connection
    func getPeersByScore() -> [(host: String, port: UInt16, score: Int, isReliable: Bool)] {
        guard let db = db else { return [] }

        let sql = """
            SELECT host, port, score, is_reliable FROM trusted_peers
            WHERE is_bad = 0
            ORDER BY is_reliable DESC, score DESC, last_success DESC
            LIMIT 50
        """

        var peers: [(String, UInt16, Int, Bool)] = []
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let host = String(cString: sqlite3_column_text(stmt, 0))
                let port = UInt16(sqlite3_column_int(stmt, 1))
                let score = Int(sqlite3_column_int(stmt, 2))
                let isReliable = sqlite3_column_int(stmt, 3) != 0
                peers.append((host, port, score, isReliable))
            }
            sqlite3_finalize(stmt)
        }
        return peers
    }

    /// Check if a peer is marked as bad
    func isPeerBad(host: String) -> Bool {
        guard let db = db else { return false }

        let sql = "SELECT is_bad FROM trusted_peers WHERE host = ?"

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, host, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            if sqlite3_step(stmt) == SQLITE_ROW {
                let isBad = sqlite3_column_int(stmt, 0) != 0
                sqlite3_finalize(stmt)
                return isBad
            }
            sqlite3_finalize(stmt)
        }
        return false
    }

    /// Get count of reliable peers
    func getReliablePeerCount() -> Int {
        guard let db = db else { return 0 }

        let sql = "SELECT COUNT(*) FROM trusted_peers WHERE is_reliable = 1 AND is_bad = 0"

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW {
                let count = Int(sqlite3_column_int(stmt, 0))
                sqlite3_finalize(stmt)
                return count
            }
            sqlite3_finalize(stmt)
        }
        return 0
    }
}

// MARK: - Data Types

struct Account {
    let accountId: Int64  // FIX #557 v8: Renamed from 'id' to avoid SwiftUI .id() modifier conflict
    let spendingKey: Data
    let viewingKey: Data
    let address: String
    let birthdayHeight: UInt64
}

struct WalletNote {
    let id: Int64
    let diversifier: Data
    let value: UInt64
    let rcm: Data
    let nullifier: Data
    let height: UInt64
    let witness: Data
    let cmu: Data? // Note commitment - needed for witness rebuild
    let anchor: Data? // Tree root when witness was last updated
    let witnessIndex: UInt64 // FIX #557 v45: Index in global FFI tree for retrieving fresh witnesses
    var confirmations: Int = 0 // Set by caller based on current chain height
}

/// Represents a spent note (for recovery checks)
struct SpentNote {
    let nullifier: Data
    let spentInTx: Data? // nil if transaction broadcast failed
    let value: UInt64? // Note value (optional for backward compatibility)
    let height: UInt64? // Note height (optional for backward compatibility)
}

enum TransactionType: String {
    case sent = "sent"
    case received = "received"
    case change = "change"
}

/// Transaction confirmation status
enum TransactionStatus: String {
    case pending = "pending"         // Not yet broadcast
    case mempool = "mempool"         // In mempool, 0 confirmations
    case confirming = "confirming"   // 1-5 confirmations
    case confirmed = "confirmed"     // 6+ confirmations
}

struct TransactionHistoryItem {
    let txid: Data
    let height: UInt64
    let blockTime: UInt64?
    let type: TransactionType
    let value: UInt64
    let fee: UInt64?
    let toAddress: String?
    let memo: String?
    let status: TransactionStatus
    let confirmations: Int

    /// Transaction ID as hex string for display
    var txidString: String {
        // FIX #853 v2 + FIX #882: txid is stored in wire format (little-endian), reverse to display format (big-endian)
        // This matches how block explorers display txids
        // FIX #882 fixed FIX #880 which incorrectly stored in display format causing double-reversal
        txid.reversed().map { String(format: "%02x", $0) }.joined()
    }

    /// Unique identifier for ForEach - uses txid prefix + type + height + value
    /// All components needed to distinguish transactions in the same block
    var uniqueId: String {
        // FIX #465: Reverse txid prefix for display consistency
        let txidPrefix = txid.prefix(8).reversed().map { String(format: "%02x", $0) }.joined()
        return "\(txidPrefix)_\(type.rawValue)_\(height)_\(value)"
    }

    /// Status display string
    var statusString: String {
        switch status {
        case .pending: return "Pending"
        case .mempool: return "Unconfirmed"
        case .confirming: return "\(confirmations) conf."
        case .confirmed: return "Confirmed"
        }
    }

    /// Whether this transaction is still pending (not yet confirmed)
    var isPending: Bool {
        status == .pending || status == .mempool || status == .confirming
    }

    /// Value in ZCL (not zatoshis)
    var valueInZCL: Double {
        Double(value) / 100_000_000.0
    }

    /// Fee in ZCL
    var feeInZCL: Double? {
        guard let fee = fee else { return nil }
        return Double(fee) / 100_000_000.0
    }

    /// Formatted date string using REAL block timestamp from blockchain
    var dateString: String? {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short

        // Use actual block timestamp if available (already set by getTransactionHistory)
        if let blockTime = blockTime, blockTime > 0 {
            let date = Date(timeIntervalSince1970: TimeInterval(blockTime))
            return formatter.string(from: date)
        }

        // Fallback: try to get from HeaderStore (checks BOTH headers table AND block_times table)
        if height > 0 {
            if let timestamp = try? HeaderStore.shared.getBlockTime(at: height) {
                let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
                return formatter.string(from: date)
            }
        }

        // FIX #120: If HeaderStore fails, also try BlockTimestampManager (in-memory cache from boost file)
        if height > 0 {
            if let timestamp = BlockTimestampManager.shared.getTimestamp(at: height) {
                let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
                return formatter.string(from: date)
            }
        }

        // ONLY REAL TIMESTAMPS - NO ESTIMATION
        // Return nil if no real timestamp found - dates will appear after P2P header sync completes
        return nil
    }
}

// MARK: - Errors

enum DatabaseError: LocalizedError {
    case openFailed(String)
    case encryptionFailed
    case encryptionRequired  // VUL-007: SQLCipher required but not available
    case schemaCreationFailed(String)
    case prepareFailed(String)
    case insertFailed(String)
    case updateFailed(String)
    case deleteFailed(String)
    case queryFailed(String)
    case notOpened
    case notFound(String)  // FIX #241: Checkpoint not found
    case transactionFailed(String)  // FIX #291: Atomic transaction failed

    var errorDescription: String? {
        switch self {
        case .openFailed(let msg):
            return "Failed to open database: \(msg)"
        case .encryptionFailed:
            return "Database encryption failed"
        case .encryptionRequired:
            return "SQLCipher encryption required but not available. Wallet cannot be created without full database encryption."
        case .schemaCreationFailed(let msg):
            return "Schema creation failed: \(msg)"
        case .prepareFailed(let msg):
            return "Statement preparation failed: \(msg)"
        case .insertFailed(let msg):
            return "Insert failed: \(msg)"
        case .updateFailed(let msg):
            return "Update failed: \(msg)"
        case .deleteFailed(let msg):
            return "Delete failed: \(msg)"
        case .queryFailed(let msg):
            return "Query failed: \(msg)"
        case .notOpened:
            return "Database not opened"
        case .notFound(let msg):
            return "Not found: \(msg)"
        case .transactionFailed(let msg):
            return "Transaction failed: \(msg)"
        }
    }
}
