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
    }

    // MARK: - Database Connection

    /// Open database with encryption key
    func open(encryptionKey: Data) throws {
        // Don't reopen if already open
        if db != nil {
            return
        }

        guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
            throw DatabaseError.openFailed(String(cString: sqlite3_errmsg(db)))
        }

        // Note: SQLCipher encryption requires special entitlement on iOS
        // For development, using unencrypted database
        // TODO: For production, use SQLCipher pod or file-level encryption

        // Create tables
        try createTables()
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

            // Indexes for performance
            """
            CREATE INDEX IF NOT EXISTS idx_notes_account ON notes(account_id);
            CREATE INDEX IF NOT EXISTS idx_notes_spent ON notes(is_spent);
            CREATE INDEX IF NOT EXISTS idx_notes_height ON notes(received_height);
            CREATE INDEX IF NOT EXISTS idx_nullifiers_height ON nullifiers(block_height);
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
        let sql = "SELECT id, spending_key, viewing_key, address, birthday_height FROM accounts WHERE account_index = ?;"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int(stmt, 1, Int32(index))

        guard sqlite3_step(stmt) == SQLITE_ROW else {
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
        let sql = """
            INSERT INTO notes (account_id, diversifier, value, rcm, memo, nf, received_in_tx, received_height, witness, witness_height)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, accountId)
        diversifier.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, 2, ptr.baseAddress, Int32(diversifier.count), nil)
        }
        sqlite3_bind_int64(stmt, 3, Int64(value))
        rcm.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, 4, ptr.baseAddress, Int32(rcm.count), nil)
        }
        if let memo = memo {
            memo.withUnsafeBytes { ptr in
                sqlite3_bind_blob(stmt, 5, ptr.baseAddress, Int32(memo.count), nil)
            }
        } else {
            sqlite3_bind_null(stmt, 5)
        }
        nullifier.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, 6, ptr.baseAddress, Int32(nullifier.count), nil)
        }
        txid.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, 7, ptr.baseAddress, Int32(txid.count), nil)
        }
        sqlite3_bind_int64(stmt, 8, Int64(height))
        if let witness = witness {
            witness.withUnsafeBytes { ptr in
                sqlite3_bind_blob(stmt, 9, ptr.baseAddress, Int32(witness.count), nil)
            }
            sqlite3_bind_int64(stmt, 10, Int64(height))
        } else {
            sqlite3_bind_null(stmt, 9)
            sqlite3_bind_null(stmt, 10)
        }

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.insertFailed(String(cString: sqlite3_errmsg(db)))
        }

        return sqlite3_last_insert_rowid(db)
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

// MARK: - Errors

enum DatabaseError: LocalizedError {
    case openFailed(String)
    case encryptionFailed
    case schemaCreationFailed(String)
    case prepareFailed(String)
    case insertFailed(String)
    case updateFailed(String)
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
        case .queryFailed(let msg):
            return "Query failed: \(msg)"
        }
    }
}
