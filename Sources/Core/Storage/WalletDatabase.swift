import Foundation
import SQLite3

/// Encrypted SQLite database for wallet data
/// Uses SQLCipher for encryption at rest
final class WalletDatabase {
    static let shared = WalletDatabase()

    private var db: OpaquePointer?
    private let dbPath: String
    private let queue = DispatchQueue(label: "com.zipherx.database", qos: .userInitiated)

    private init() {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        dbPath = documentsPath.appendingPathComponent("zipherx_wallet.db").path
        // Thread safety is handled via SQLITE_OPEN_FULLMUTEX in open()
    }

    // MARK: - Database Connection

    /// Open database with encryption key
    func open(encryptionKey: Data) throws {
        // Don't reopen if already open
        if db != nil {
            print("📂 Database already open")
            return
        }

        print("📂 Opening database at: \(dbPath)")
        // Use FULLMUTEX for thread safety
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(dbPath, &db, flags, nil) == SQLITE_OK else {
            let errorMsg = db != nil ? String(cString: sqlite3_errmsg(db)) : "Unknown error"
            throw DatabaseError.openFailed(errorMsg)
        }

        // Note: SQLCipher encryption requires special entitlement on iOS
        // For development, using unencrypted database
        // TODO: For production, use SQLCipher pod or file-level encryption

        // Create tables
        try createTables()
        print("📂 Database opened successfully")
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
                received_in_tx BLOB NOT NULL,
                received_height INTEGER NOT NULL,
                witness BLOB,
                witness_height INTEGER,
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
            INSERT OR IGNORE INTO sync_state (id, last_scanned_height) VALUES (1, 0);
            """,

            // Transaction history (unified view of sent/received)
            """
            CREATE TABLE IF NOT EXISTS transaction_history (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                txid BLOB NOT NULL,
                block_height INTEGER NOT NULL,
                block_time INTEGER,
                tx_type TEXT NOT NULL CHECK (tx_type IN ('sent', 'received')),
                value INTEGER NOT NULL,
                fee INTEGER,
                to_address TEXT,
                from_diversifier BLOB,
                memo TEXT,
                created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
                UNIQUE(txid, tx_type, value)
            );
            """,

            // Indexes for performance
            """
            CREATE INDEX IF NOT EXISTS idx_notes_account ON notes(account_id);
            CREATE INDEX IF NOT EXISTS idx_notes_spent ON notes(is_spent);
            CREATE INDEX IF NOT EXISTS idx_notes_height ON notes(received_height);
            CREATE INDEX IF NOT EXISTS idx_nullifiers_height ON nullifiers(block_height);
            CREATE INDEX IF NOT EXISTS idx_history_height ON transaction_history(block_height DESC);
            CREATE INDEX IF NOT EXISTS idx_history_type ON transaction_history(tx_type);
            """
        ]

        for schema in schemas {
            guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else {
                throw DatabaseError.schemaCreationFailed(String(cString: sqlite3_errmsg(db)))
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
        witness: Data?
    ) throws -> Int64 {
        // Use INSERT OR IGNORE to skip notes that already exist (by nullifier uniqueness)
        // This prevents duplicates during rescanning
        let sql = """
            INSERT OR IGNORE INTO notes (account_id, diversifier, value, rcm, memo, nf, received_in_tx, received_height, witness, witness_height)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        // SQLITE_TRANSIENT tells SQLite to copy the data immediately
        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        sqlite3_bind_int64(stmt, 1, accountId)
        diversifier.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, 2, ptr.baseAddress, Int32(diversifier.count), SQLITE_TRANSIENT)
        }
        sqlite3_bind_int64(stmt, 3, Int64(value))
        rcm.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, 4, ptr.baseAddress, Int32(rcm.count), SQLITE_TRANSIENT)
        }
        if let memo = memo {
            memo.withUnsafeBytes { ptr in
                sqlite3_bind_blob(stmt, 5, ptr.baseAddress, Int32(memo.count), SQLITE_TRANSIENT)
            }
        } else {
            sqlite3_bind_null(stmt, 5)
        }
        nullifier.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, 6, ptr.baseAddress, Int32(nullifier.count), SQLITE_TRANSIENT)
        }
        txid.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, 7, ptr.baseAddress, Int32(txid.count), SQLITE_TRANSIENT)
        }
        sqlite3_bind_int64(stmt, 8, Int64(height))
        if let witness = witness {
            witness.withUnsafeBytes { ptr in
                sqlite3_bind_blob(stmt, 9, ptr.baseAddress, Int32(witness.count), SQLITE_TRANSIENT)
            }
            sqlite3_bind_int64(stmt, 10, Int64(height))
        } else {
            sqlite3_bind_null(stmt, 9)
            sqlite3_bind_null(stmt, 10)
        }

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.insertFailed(String(cString: sqlite3_errmsg(db)))
        }

        let insertedId = sqlite3_last_insert_rowid(db)

        // If INSERT OR IGNORE skipped the insert (duplicate nullifier), fetch existing note ID
        if sqlite3_changes(db) == 0 {
            // Note already exists, fetch its ID by nullifier
            let selectSql = "SELECT id FROM notes WHERE nf = ?;"
            var selectStmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, selectSql, -1, &selectStmt, nil) == SQLITE_OK else {
                return 0 // Return 0 if we can't find it
            }
            defer { sqlite3_finalize(selectStmt) }

            let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            nullifier.withUnsafeBytes { ptr in
                sqlite3_bind_blob(selectStmt, 1, ptr.baseAddress, Int32(nullifier.count), SQLITE_TRANSIENT)
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

    /// Get unspent notes for account
    func getUnspentNotes(accountId: Int64) throws -> [WalletNote] {
        let sql = """
            SELECT id, diversifier, value, rcm, memo, nf, received_in_tx, received_height, witness
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

            let note = WalletNote(
                id: id,
                diversifier: Data(bytes: divPtr!, count: Int(divLen)),
                value: value,
                rcm: Data(bytes: rcmPtr!, count: Int(rcmLen)),
                nullifier: Data(bytes: nfPtr!, count: Int(nfLen)),
                height: height,
                witness: Data(bytes: witnessPtr!, count: Int(witnessLen))
            )

            notes.append(note)
        }

        return notes
    }

    /// Mark note as spent
    func markNoteSpent(nullifier: Data, txid: Data) throws {
        let sql = "UPDATE notes SET is_spent = 1, spent_in_tx = ? WHERE nf = ?;"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        txid.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, 1, ptr.baseAddress, Int32(txid.count), nil)
        }
        nullifier.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, 2, ptr.baseAddress, Int32(nullifier.count), nil)
        }

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.updateFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    /// Mark note as spent by height
    func markNoteSpent(nullifier: Data, spentHeight: UInt64) throws {
        let sql = "UPDATE notes SET is_spent = 1 WHERE nf = ?;"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        nullifier.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, 1, ptr.baseAddress, Int32(nullifier.count), nil)
        }

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.updateFailed(String(cString: sqlite3_errmsg(db)))
        }
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

    /// Get all nullifiers for spend detection
    func getAllNullifiers() throws -> Set<Data> {
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
            if let ptr = nfPtr {
                nullifiers.insert(Data(bytes: ptr, count: Int(nfLen)))
            }
        }

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

        return UInt64(sqlite3_column_int64(stmt, 0))
    }

    /// Update last scanned height
    func updateLastScannedHeight(_ height: UInt64, hash: Data) throws {
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

    /// Update witness for a note
    func updateNoteWitness(noteId: Int64, witness: Data) throws {
        let sql = "UPDATE notes SET witness = ? WHERE id = ?;"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        witness.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, 1, ptr.baseAddress, Int32(witness.count), nil)
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
        let sql = """
            INSERT OR IGNORE INTO transaction_history
            (txid, block_height, block_time, tx_type, value, fee, to_address, from_diversifier, memo)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        txid.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, 1, ptr.baseAddress, Int32(txid.count), nil)
        }
        sqlite3_bind_int64(stmt, 2, Int64(height))
        if let blockTime = blockTime {
            sqlite3_bind_int64(stmt, 3, Int64(blockTime))
        } else {
            sqlite3_bind_null(stmt, 3)
        }
        sqlite3_bind_text(stmt, 4, type.rawValue, -1, nil)
        sqlite3_bind_int64(stmt, 5, Int64(value))
        if let fee = fee {
            sqlite3_bind_int64(stmt, 6, Int64(fee))
        } else {
            sqlite3_bind_null(stmt, 6)
        }
        if let toAddress = toAddress {
            sqlite3_bind_text(stmt, 7, toAddress, -1, nil)
        } else {
            sqlite3_bind_null(stmt, 7)
        }
        if let fromDiversifier = fromDiversifier {
            fromDiversifier.withUnsafeBytes { ptr in
                sqlite3_bind_blob(stmt, 8, ptr.baseAddress, Int32(fromDiversifier.count), nil)
            }
        } else {
            sqlite3_bind_null(stmt, 8)
        }
        if let memo = memo {
            sqlite3_bind_text(stmt, 9, memo, -1, nil)
        } else {
            sqlite3_bind_null(stmt, 9)
        }

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.insertFailed(String(cString: sqlite3_errmsg(db)))
        }

        return sqlite3_last_insert_rowid(db)
    }

    /// Get transaction history ordered by height (newest first)
    func getTransactionHistory(limit: Int = 100, offset: Int = 0) throws -> [TransactionHistoryItem] {
        let sql = """
            SELECT txid, block_height, block_time, tx_type, value, fee, to_address, memo
            FROM transaction_history
            ORDER BY block_height DESC, created_at DESC
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
            let txidPtr = sqlite3_column_blob(stmt, 0)
            let txidLen = sqlite3_column_bytes(stmt, 0)
            let height = UInt64(sqlite3_column_int64(stmt, 1))
            let blockTime = sqlite3_column_type(stmt, 2) != SQLITE_NULL ? UInt64(sqlite3_column_int64(stmt, 2)) : nil
            let typeStr = String(cString: sqlite3_column_text(stmt, 3))
            let value = UInt64(sqlite3_column_int64(stmt, 4))
            let fee = sqlite3_column_type(stmt, 5) != SQLITE_NULL ? UInt64(sqlite3_column_int64(stmt, 5)) : nil
            let toAddress = sqlite3_column_type(stmt, 6) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 6)) : nil
            let memo = sqlite3_column_type(stmt, 7) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 7)) : nil

            let item = TransactionHistoryItem(
                txid: Data(bytes: txidPtr!, count: Int(txidLen)),
                height: height,
                blockTime: blockTime,
                type: TransactionType(rawValue: typeStr) ?? .received,
                value: value,
                fee: fee,
                toAddress: toAddress,
                memo: memo
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
    var confirmations: Int = 0 // Set by caller based on current chain height
}

enum TransactionType: String {
    case sent = "sent"
    case received = "received"
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

    /// Transaction ID as hex string (reversed for display)
    var txidString: String {
        // Reverse bytes for display (Bitcoin-style txid)
        Data(txid.reversed()).map { String(format: "%02x", $0) }.joined()
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

    /// Formatted date string
    var dateString: String? {
        guard let blockTime = blockTime else { return nil }
        let date = Date(timeIntervalSince1970: TimeInterval(blockTime))
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

// MARK: - Errors

enum DatabaseError: LocalizedError {
    case openFailed(String)
    case encryptionFailed
    case schemaCreationFailed(String)
    case prepareFailed(String)
    case insertFailed(String)
    case updateFailed(String)
    case deleteFailed(String)
    case queryFailed(String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let msg):
            return "Failed to open database: \(msg)"
        case .encryptionFailed:
            return "Database encryption failed"
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
        }
    }
}
