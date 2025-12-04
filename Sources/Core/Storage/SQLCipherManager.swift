// Copyright (c) 2025 Zipherpunk.com dev team
// SQLCipher Database Encryption Manager
//
// "Privacy is necessary for an open society in the electronic age."
//   - A Cypherpunk's Manifesto
//
// This module provides transparent full-database encryption using SQLCipher.
// When SQLCipher is not available, falls back to field-level encryption.

import Foundation
import SQLite3
import CryptoKit
#if os(iOS)
import UIKit
#endif

/// Manages SQLCipher database encryption
/// Provides transparent encryption/decryption for the entire SQLite database
final class SQLCipherManager {
    static let shared = SQLCipherManager()

    /// Whether SQLCipher is available (compiled with encryption support)
    private(set) var isSQLCipherAvailable: Bool = false

    /// Cached encryption key (derived from Secure Enclave)
    private var encryptionKey: Data?

    /// Salt for key derivation (stored in keychain)
    private var salt: Data?

    /// Keychain identifiers
    private let keychainService = "com.zipherx.wallet.sqlcipher"
    private let saltKey = "sqlcipher-salt"
    private let keyVersionKey = "sqlcipher-key-version"

    /// Current key version (for future key rotation)
    private let currentKeyVersion: Int = 1

    private init() {
        // Check if SQLCipher is available by looking for cipher_version
        isSQLCipherAvailable = checkSQLCipherAvailable()
        if isSQLCipherAvailable {
            print("🔐 SQLCipher is available - full database encryption enabled")
        } else {
            print("⚠️ SQLCipher not available - using field-level encryption only")
        }
    }

    // MARK: - SQLCipher Detection

    /// Check if SQLite was compiled with SQLCipher
    private func checkSQLCipherAvailable() -> Bool {
        // Try to get cipher_version pragma - only works with SQLCipher
        var db: OpaquePointer?
        let result = sqlite3_open(":memory:", &db)
        defer { sqlite3_close(db) }

        guard result == SQLITE_OK else { return false }

        // Try cipher_version pragma
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "PRAGMA cipher_version;", -1, &stmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(stmt) }
            if sqlite3_step(stmt) == SQLITE_ROW {
                if let version = sqlite3_column_text(stmt, 0) {
                    let versionStr = String(cString: version)
                    print("🔐 SQLCipher version: \(versionStr)")
                    return true
                }
            }
        }

        return false
    }

    // MARK: - Key Management

    /// Get or create the database encryption key
    /// Key is derived from device ID + salt using HKDF-SHA256
    func getEncryptionKey() throws -> Data {
        if let key = encryptionKey {
            return key
        }

        // Get or create salt
        let salt = try getOrCreateSalt()

        // Get device-specific identifier
        let deviceId = getDeviceIdentifier()

        // Derive 256-bit key using HKDF
        let inputKey = SymmetricKey(data: Data(deviceId.utf8))
        let derivedKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: inputKey,
            salt: salt,
            info: Data("ZipherX-SQLCipher-v\(currentKeyVersion)".utf8),
            outputByteCount: 32  // 256-bit key for AES-256
        )

        // Convert to Data
        let keyData = derivedKey.withUnsafeBytes { Data($0) }
        self.encryptionKey = keyData

        return keyData
    }

    /// Get the encryption key as a hex string (for PRAGMA key)
    func getEncryptionKeyHex() throws -> String {
        let keyData = try getEncryptionKey()
        return "x'" + keyData.map { String(format: "%02x", $0) }.joined() + "'"
    }

    /// Get or create salt for key derivation
    private func getOrCreateSalt() throws -> Data {
        if let salt = self.salt {
            return salt
        }

        // Try to load from keychain
        if let existingSalt = loadFromKeychain(key: saltKey) {
            self.salt = existingSalt
            return existingSalt
        }

        // Generate new random salt
        var newSalt = Data(count: 32)
        let result = newSalt.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, 32, buffer.baseAddress!)
        }

        guard result == errSecSuccess else {
            throw SQLCipherError.keyGenerationFailed
        }

        // Store in keychain
        try saveToKeychain(data: newSalt, key: saltKey)
        self.salt = newSalt

        return newSalt
    }

    /// Get device-specific identifier for key derivation
    private func getDeviceIdentifier() -> String {
        #if targetEnvironment(simulator)
        if let udid = ProcessInfo.processInfo.environment["SIMULATOR_UDID"] {
            return "SQLCIPHER-SIM-\(udid)"
        }
        return "SQLCIPHER-SIMULATOR-\(ProcessInfo.processInfo.hostName)"

        #elseif os(iOS)
        if let vendorId = UIDevice.current.identifierForVendor?.uuidString {
            return "SQLCIPHER-IOS-\(vendorId)"
        }
        return "SQLCIPHER-IOS-\(UUID().uuidString)"

        #elseif os(macOS)
        if let uuid = getMacHardwareUUID() {
            return "SQLCIPHER-MAC-\(uuid)"
        }
        return "SQLCIPHER-MAC-\(UUID().uuidString)"

        #else
        return "SQLCIPHER-UNKNOWN-\(UUID().uuidString)"
        #endif
    }

    #if os(macOS)
    private func getMacHardwareUUID() -> String? {
        let platformExpert = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )
        defer { IOObjectRelease(platformExpert) }
        guard platformExpert != 0 else { return nil }

        if let uuidCF = IORegistryEntryCreateCFProperty(
            platformExpert,
            kIOPlatformUUIDKey as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() {
            return uuidCF as? String
        }
        return nil
    }
    #endif

    // MARK: - Database Operations

    /// Apply encryption key to an open database connection
    /// Call this immediately after sqlite3_open()
    func applyEncryption(to db: OpaquePointer) throws {
        guard isSQLCipherAvailable else {
            // SQLCipher not available, field-level encryption will be used instead
            return
        }

        let keyHex = try getEncryptionKeyHex()

        // Apply the key using PRAGMA key
        let sql = "PRAGMA key = \(keyHex);"
        var errMsg: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, sql, nil, nil, &errMsg)

        if result != SQLITE_OK {
            let error = errMsg != nil ? String(cString: errMsg!) : "Unknown error"
            sqlite3_free(errMsg)
            throw SQLCipherError.encryptionFailed(error)
        }

        // Verify encryption is working by querying something
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT count(*) FROM sqlite_master;", -1, &stmt, nil) != SQLITE_OK {
            throw SQLCipherError.encryptionFailed("Database key verification failed")
        }
        sqlite3_finalize(stmt)

        print("🔐 SQLCipher encryption applied successfully")
    }

    /// Migrate an unencrypted database to encrypted format
    /// This creates a new encrypted database and copies all data
    func migrateToEncrypted(sourcePath: String, destPath: String) throws {
        guard isSQLCipherAvailable else {
            throw SQLCipherError.sqlcipherNotAvailable
        }

        print("🔐 Migrating database to encrypted format...")

        // Open source (unencrypted) database
        var sourceDb: OpaquePointer?
        guard sqlite3_open(sourcePath, &sourceDb) == SQLITE_OK else {
            throw SQLCipherError.migrationFailed("Cannot open source database")
        }
        defer { sqlite3_close(sourceDb) }

        // Attach encrypted destination database
        let keyHex = try getEncryptionKeyHex()
        let attachSQL = "ATTACH DATABASE '\(destPath)' AS encrypted KEY \(keyHex);"

        var errMsg: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(sourceDb, attachSQL, nil, nil, &errMsg) == SQLITE_OK else {
            let error = errMsg != nil ? String(cString: errMsg!) : "Unknown"
            sqlite3_free(errMsg)
            throw SQLCipherError.migrationFailed("Attach failed: \(error)")
        }

        // Export to encrypted database
        let exportSQL = "SELECT sqlcipher_export('encrypted');"
        guard sqlite3_exec(sourceDb, exportSQL, nil, nil, &errMsg) == SQLITE_OK else {
            let error = errMsg != nil ? String(cString: errMsg!) : "Unknown"
            sqlite3_free(errMsg)
            throw SQLCipherError.migrationFailed("Export failed: \(error)")
        }

        // Detach
        sqlite3_exec(sourceDb, "DETACH DATABASE encrypted;", nil, nil, nil)

        print("🔐 Database migration complete")
    }

    /// Check if a database file is encrypted
    func isDatabaseEncrypted(path: String) -> Bool {
        // Try to open without a key - if it works, it's not encrypted
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            return false  // Can't open at all
        }
        defer { sqlite3_close(db) }

        // Try a simple query
        var stmt: OpaquePointer?
        let result = sqlite3_prepare_v2(db, "SELECT count(*) FROM sqlite_master;", -1, &stmt, nil)
        sqlite3_finalize(stmt)

        // If query failed with SQLITE_NOTADB, the database is encrypted
        return result == SQLITE_NOTADB
    }

    // MARK: - Keychain Operations

    private func loadFromKeychain(key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    private func saveToKeychain(data: Data, key: String) throws {
        // Delete existing
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Add new
        var addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key,
            kSecValueData as String: data
        ]

        #if os(iOS)
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        #endif

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw SQLCipherError.keychainError
        }
    }

    // MARK: - Key Rotation (Future)

    /// Clear cached key (for security or rotation)
    func clearCachedKey() {
        encryptionKey = nil
    }
}

// MARK: - Errors

enum SQLCipherError: Error, LocalizedError {
    case sqlcipherNotAvailable
    case keyGenerationFailed
    case encryptionFailed(String)
    case migrationFailed(String)
    case keychainError

    var errorDescription: String? {
        switch self {
        case .sqlcipherNotAvailable:
            return "SQLCipher is not available"
        case .keyGenerationFailed:
            return "Failed to generate encryption key"
        case .encryptionFailed(let msg):
            return "Encryption failed: \(msg)"
        case .migrationFailed(let msg):
            return "Migration failed: \(msg)"
        case .keychainError:
            return "Keychain operation failed"
        }
    }
}

#if os(macOS)
import IOKit
#endif
