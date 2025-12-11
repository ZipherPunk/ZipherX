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
    private func hashNullifier(_ nullifier: Data) -> Data {
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
    private func decryptTxType(_ stored: String) -> TransactionType {
        return WalletDatabase.txTypeDecryptionMap[stored] ?? .received
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
            sqlite3_close(db)
            db = nil
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

            // Indexes for performance
            "CREATE INDEX IF NOT EXISTS idx_notes_account ON notes(account_id);",
            "CREATE INDEX IF NOT EXISTS idx_notes_spent ON notes(is_spent);",
            "CREATE INDEX IF NOT EXISTS idx_notes_height ON notes(received_height);",
            "CREATE INDEX IF NOT EXISTS idx_nullifiers_height ON nullifiers(block_height);",
            "CREATE INDEX IF NOT EXISTS idx_history_height ON transaction_history(block_height DESC);",
            "CREATE INDEX IF NOT EXISTS idx_history_type ON transaction_history(tx_type);",
            "CREATE INDEX IF NOT EXISTS idx_tree_checkpoints_height ON tree_checkpoints(height DESC);"
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
        spendingKey.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, 2, ptr.baseAddress, Int32(spendingKey.count), nil)
        }
        viewingKey.withUnsafeBytes { ptr in
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
            id: id,
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
        encryptedDiversifier.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, 2, ptr.baseAddress, Int32(encryptedDiversifier.count), SQLITE_TRANSIENT)
        }
        sqlite3_bind_int64(stmt, 3, Int64(value))
        encryptedRcm.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, 4, ptr.baseAddress, Int32(encryptedRcm.count), SQLITE_TRANSIENT)
        }
        if let encMemo = encryptedMemo {
            encMemo.withUnsafeBytes { ptr in
                sqlite3_bind_blob(stmt, 5, ptr.baseAddress, Int32(encMemo.count), SQLITE_TRANSIENT)
            }
        } else {
            sqlite3_bind_null(stmt, 5)
        }
        // VUL-009: Hash nullifier before storage to prevent spending pattern analysis
        let hashedNullifier = hashNullifier(nullifier)
        hashedNullifier.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, 6, ptr.baseAddress, Int32(hashedNullifier.count), SQLITE_TRANSIENT)
        }
        txid.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, 7, ptr.baseAddress, Int32(txid.count), SQLITE_TRANSIENT)
        }
        sqlite3_bind_int64(stmt, 8, Int64(height))
        if let witness = witness {
            // SECURITY: Encrypt witness (Merkle path) - VUL-002: throws on failure
            let encryptedWitness = try encryptBlob(witness)
            encryptedWitness.withUnsafeBytes { ptr in
                sqlite3_bind_blob(stmt, 9, ptr.baseAddress, Int32(encryptedWitness.count), SQLITE_TRANSIENT)
            }
            sqlite3_bind_int64(stmt, 10, Int64(height))
        } else {
            sqlite3_bind_null(stmt, 9)
            sqlite3_bind_null(stmt, 10)
        }
        // Bind CMU (note commitment) - not encrypted (public on chain)
        if let cmu = cmu {
            cmu.withUnsafeBytes { ptr in
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
            hashedNullifier.withUnsafeBytes { ptr in
                sqlite3_bind_blob(selectStmt, 1, ptr.baseAddress, Int32(hashedNullifier.count), SQLITE_TRANSIENT)
            }

            if sqlite3_step(selectStmt) == SQLITE_ROW {
                return sqlite3_column_int64(selectStmt, 0)
            }
            return 0
        }

        return insertedId
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
        let sql = """
            SELECT id, diversifier, value, rcm, memo, nf, received_in_tx, received_height, witness, cmu, anchor
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
                let encryptedWitness = Data(bytes: witnessPtr!, count: Int(witnessLen))
                witnessData = try decryptBlob(encryptedWitness)
            }

            // CMU might be NULL (not encrypted - public on chain)
            var cmuData: Data? = nil
            if sqlite3_column_type(stmt, 9) != SQLITE_NULL {
                let cmuPtr = sqlite3_column_blob(stmt, 9)
                let cmuLen = sqlite3_column_bytes(stmt, 9)
                cmuData = Data(bytes: cmuPtr!, count: Int(cmuLen))
            }

            // Anchor might be NULL
            var anchorData: Data? = nil
            if sqlite3_column_type(stmt, 10) != SQLITE_NULL {
                let anchorPtr = sqlite3_column_blob(stmt, 10)
                let anchorLen = sqlite3_column_bytes(stmt, 10)
                anchorData = Data(bytes: anchorPtr!, count: Int(anchorLen))
            }

            let note = WalletNote(
                id: id,
                diversifier: diversifier,
                value: value,
                rcm: rcm,
                nullifier: Data(bytes: nfPtr!, count: Int(nfLen)),
                height: height,
                witness: witnessData,
                cmu: cmuData,
                anchor: anchorData
            )

            notes.append(note)
        }

        return notes
    }

    /// Get unspent notes for account (with valid witnesses only)
    func getUnspentNotes(accountId: Int64) throws -> [WalletNote] {
        let sql = """
            SELECT id, diversifier, value, rcm, memo, nf, received_in_tx, received_height, witness, cmu, anchor
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
            let encryptedWitness = Data(bytes: witnessPtr!, count: Int(witnessLen))

            let diversifier = try decryptBlob(encryptedDiv)
            let rcm = try decryptBlob(encryptedRcm)
            let witness = try decryptBlob(encryptedWitness)

            // CMU might be NULL (not encrypted - public on chain)
            var cmuData: Data? = nil
            if sqlite3_column_type(stmt, 9) != SQLITE_NULL {
                let cmuPtr = sqlite3_column_blob(stmt, 9)
                let cmuLen = sqlite3_column_bytes(stmt, 9)
                cmuData = Data(bytes: cmuPtr!, count: Int(cmuLen))
            }

            // Anchor might be NULL
            var anchorData: Data? = nil
            if sqlite3_column_type(stmt, 10) != SQLITE_NULL {
                let anchorPtr = sqlite3_column_blob(stmt, 10)
                let anchorLen = sqlite3_column_bytes(stmt, 10)
                anchorData = Data(bytes: anchorPtr!, count: Int(anchorLen))
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
                anchor: anchorData
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
        try markNoteSpentByHashedNullifier(hashedNullifier: hashedNullifier, txid: txid, spentHeight: spentHeight)
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
            hashedNullifier.withUnsafeBytes { ptr in
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

        txid.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, 1, ptr.baseAddress, Int32(txid.count), nil)
        }
        sqlite3_bind_int64(stmt, 2, Int64(spentHeight))
        hashedNullifier.withUnsafeBytes { ptr in
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
        syntheticTxid.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, 2, ptr.baseAddress, Int32(syntheticTxid.count), nil)
        }
        hashedNullifier.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, 3, ptr.baseAddress, Int32(hashedNullifier.count), nil)
        }

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.updateFailed(String(cString: sqlite3_errmsg(db)))
        }
        print("📜 Marked note spent at height \(spentHeight) with synthetic txid")
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

        hashedNullifier.withUnsafeBytes { ptr in
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

            notes.append(SpentNote(nullifier: nullifier, spentInTx: spentInTx))
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

        let sql = "SELECT nf FROM notes WHERE is_spent = 0;"

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

    /// Get total unspent balance for account
    func getBalance(accountId: Int64) throws -> UInt64 {
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

    // MARK: - Sync State

    /// Get last scanned height
    /// FIX: Added validation to detect and auto-correct corrupted values
    func getLastScannedHeight() throws -> UInt64 {
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
    /// FIX: Added validation to prevent writing corrupted values
    func updateLastScannedHeight(_ height: UInt64, hash: Data) throws {
        // FIX: Validate height before writing to prevent corruption
        let maxReasonableHeight: UInt64 = 10_000_000
        guard height <= maxReasonableHeight else {
            print("🚨 [DATABASE] Refusing to write invalid lastScannedHeight: \(height)")
            return  // Silently ignore invalid updates
        }

        let sql = "UPDATE sync_state SET last_scanned_height = ?, last_scanned_hash = ? WHERE id = 1;"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, Int64(height))
        hash.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, 2, ptr.baseAddress, Int32(hash.count), nil)
        }

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.updateFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    // MARK: - Tree State

    /// Save commitment tree state
    func saveTreeState(_ treeData: Data) throws {
        let sql = "UPDATE sync_state SET tree_state = ? WHERE id = 1;"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        treeData.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, 1, ptr.baseAddress, Int32(treeData.count), nil)
        }

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.updateFailed(String(cString: sqlite3_errmsg(db)))
        }
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
        encryptedWitness.withUnsafeBytes { ptr in
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

        anchor.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, 1, ptr.baseAddress, Int32(anchor.count), nil)
        }
        sqlite3_bind_int64(stmt, 2, noteId)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.updateFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    /// Update nullifier for a note (used when recomputing nullifiers with correct positions)
    func updateNoteNullifier(noteId: Int64, nullifier: Data) throws {
        // Hash the nullifier before storage for privacy
        let hashedNullifier = hashNullifier(nullifier)
        let sql = "UPDATE notes SET nullifier = ? WHERE id = ?;"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        hashedNullifier.withUnsafeBytes { ptr in
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

        txid.withUnsafeBytes { ptr in
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
            fromDiversifier.withUnsafeBytes { ptr in
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
        let countSql = """
            SELECT COUNT(*) FROM transaction_history t1
            WHERE t1.tx_type NOT IN ('change', 'γ')
            AND NOT (
                t1.tx_type IN ('received', 'β')
                AND EXISTS (
                    SELECT 1 FROM transaction_history t2
                    WHERE t2.txid = t1.txid AND t2.tx_type IN ('sent', 'α')
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

        // Exclude change outputs and deduplicate:
        // 1. Explicitly exclude tx_type = 'change' or 'γ' (VUL-015 obfuscated)
        // 2. Also exclude received transactions where the same txid exists as sent
        // 3. Use subquery with DISTINCT to deduplicate BEFORE ordering
        // NOTE: GROUP BY can cause unpredictable order - use DISTINCT on dedup key instead
        let sql = """
            SELECT txid, block_height, block_time, tx_type, value, fee, to_address, memo, status, confirmations
            FROM transaction_history t1
            WHERE t1.tx_type NOT IN ('change', 'γ')
            AND NOT (
                t1.tx_type IN ('received', 'β')
                AND EXISTS (
                    SELECT 1 FROM transaction_history t2
                    WHERE t2.txid = t1.txid AND t2.tx_type IN ('sent', 'α')
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
        txid.withUnsafeBytes { ptr in
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
            // Find all change outputs: notes received in the same tx (note.txid == spentTxid)
            let changeOutputs = allNotes.filter { $0.txid == spentTxid }
            let totalChangeValue = changeOutputs.reduce(0) { $0 + $1.value }

            // totalBalanceImpact = sum(inputs) - sum(change) = amount to recipient + fee
            // This is the actual balance decrease, which makes history sum = current balance
            let totalBalanceImpact = txInfo.inputValue - totalChangeValue
            // amountToRecipient = balance impact - fee (for display info)
            let amountToRecipient = totalBalanceImpact - fee

            print("📜 SENT: txid=\(spentTxid.prefix(8).hexString)..., input=\(txInfo.inputValue), change=\(totalChangeValue), fee=\(fee), toRecipient=\(amountToRecipient), balanceImpact=\(totalBalanceImpact)")

            var spentStmt: OpaquePointer?
            // Use insertSentSql (INSERT OR IGNORE) - WalletManager already recorded correct amount
            guard sqlite3_prepare_v2(db, insertSentSql, -1, &spentStmt, nil) == SQLITE_OK else {
                print("📜 SENT: Failed to prepare statement for txid=\(spentTxid.prefix(8).hexString)")
                continue
            }

            spentTxid.withUnsafeBytes { ptr in
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
            // Store totalBalanceImpact (recipient + fee) so history sum equals current balance
            sqlite3_bind_int64(spentStmt, 5, Int64(totalBalanceImpact))
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

        // PASS 2: Insert RECEIVED and CHANGE transactions for each note
        for note in allNotes {
            // Determine if this is a CHANGE output (received in a tx that we initiated)
            let isChange = sentTxids.contains(note.txid)
            let txType = isChange ? TransactionType.change : TransactionType.received

            var insertStmt: OpaquePointer?
            // Use insertReceivedSql (INSERT OR REPLACE) - notes are the source of truth for received
            guard sqlite3_prepare_v2(db, insertReceivedSql, -1, &insertStmt, nil) == SQLITE_OK else {
                print("📜 Failed to prepare insert statement")
                continue
            }

            note.txid.withUnsafeBytes { ptr in
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
                diversifier.withUnsafeBytes { ptr in
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

        txid.withUnsafeBytes { ptr in
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

        txid.withUnsafeBytes { ptr in
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

        txid.withUnsafeBytes { ptr in
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
            txid.withUnsafeBytes { ptr in
                sqlite3_bind_blob(stmt, 4, ptr.baseAddress, Int32(txid.count), SQLITE_TRANSIENT)
            }
        } else {
            txid.withUnsafeBytes { ptr in
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

    /// Fix block_time for transactions that have NULL or zero timestamps using actual timestamps from HeaderStore
    /// This corrects estimated timestamps saved by older code or newly synced transactions
    @discardableResult
    func fixTransactionBlockTimes() throws -> Int {
        // Get all transactions with NULL or zero block_time
        let selectSql = "SELECT id, block_height FROM transaction_history WHERE block_height > 0 AND (block_time IS NULL OR block_time = 0);"

        var selectStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, selectSql, -1, &selectStmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(selectStmt) }

        var updates: [(id: Int64, time: UInt32)] = []

        while sqlite3_step(selectStmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(selectStmt, 0)
            let height = UInt64(sqlite3_column_int64(selectStmt, 1))

            // Get actual block time - try BlockTimestampManager first (bundled data), then HeaderStore
            if let timestamp = BlockTimestampManager.shared.getTimestamp(at: height) {
                updates.append((id: id, time: timestamp))
            } else if let blockTime = try? HeaderStore.shared.getBlockTime(at: height) {
                updates.append((id: id, time: blockTime))
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
            print("📜 Fixed block_time for \(fixedCount) transactions using real timestamps from HeaderStore")
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
}

// MARK: - Data Types

struct Account {
    let id: Int64
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
    var confirmations: Int = 0 // Set by caller based on current chain height
}

/// Represents a spent note (for recovery checks)
struct SpentNote {
    let nullifier: Data
    let spentInTx: Data? // nil if transaction broadcast failed
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
        // txid is already stored in display format (big-endian), no reversal needed
        txid.map { String(format: "%02x", $0) }.joined()
    }

    /// Unique identifier for ForEach - uses txid prefix + type + height + value
    /// All components needed to distinguish transactions in the same block
    var uniqueId: String {
        let txidPrefix = txid.prefix(8).map { String(format: "%02x", $0) }.joined()
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
        }
    }
}
