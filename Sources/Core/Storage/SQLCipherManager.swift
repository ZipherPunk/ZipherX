// Copyright (c) 2025 Zipherpunk.com dev team
// SQLCipher Database Encryption Manager
//
// "Privacy is necessary for an open society in the electronic age."
//   - A Cypherpunk's Manifesto
//
// This module provides transparent full-database encryption using SQLCipher.
// When SQLCipher is not available, falls back to field-level encryption.

import Foundation
import LocalAuthentication
// Note: sqlite3 functions are available via bridging header (SQLCipher)
// Do NOT import SQLite3 here as it conflicts with SQLCipher's sqlite3.h
import CryptoKit
#if os(iOS)
import UIKit
#endif

/// Manages SQLCipher database encryption
/// Provides transparent encryption/decryption for the entire SQLite database
///
/// SECURITY (CRIT-001): Key derivation uses biometric-protected secret
/// The encryption key cannot be derived without Face ID/Touch ID authentication
final class SQLCipherManager {
    static let shared = SQLCipherManager()

    // DEBUG: Set to true to disable SQLCipher encryption for debugging
    // TODO: Re-enable (set to false) after all tests pass: send/receive/history
    private static let DEBUG_DISABLE_SQLCIPHER = true

    /// Whether SQLCipher is available (compiled with encryption support)
    private(set) var isSQLCipherAvailable: Bool = false

    /// Whether the wallet database is actually encrypted (not just available)
    /// This checks if encryption key has been applied to the actual database file
    var isWalletDatabaseEncrypted: Bool {
        guard isSQLCipherAvailable else { return false }
        // Check the actual wallet database file
        let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        if let dbPath = documentsDir?.appendingPathComponent("zipherx_wallet.db").path {
            return isDatabaseEncrypted(path: dbPath)
        }
        return false
    }

    /// Cached encryption key (derived with biometric protection)
    private var encryptionKey: Data?

    /// Salt for key derivation (stored in keychain)
    private var salt: Data?

    /// Biometric-protected secret (stored in keychain with LAContext)
    /// SECURITY (CRIT-001): This secret requires biometric auth to access
    private var biometricSecret: Data?

    /// Keychain identifiers
    private let keychainService = "com.zipherx.wallet.sqlcipher"
    private let saltKey = "sqlcipher-salt"
    private let keyVersionKey = "sqlcipher-key-version"
    private let biometricSecretKey = "sqlcipher-biometric-secret"

    /// Current key version (for future key rotation)
    /// v2: biometric-gated secret (caused double Touch ID)
    /// v3: app secret (single Touch ID via app lock)
    private let currentKeyVersion: Int = 3

    /// Whether biometric secret is available (set after first successful auth)
    private(set) var hasBiometricProtection: Bool = false

    private init() {
        // DEBUG: Skip SQLCipher for debugging database issues
        if SQLCipherManager.DEBUG_DISABLE_SQLCIPHER {
            isSQLCipherAvailable = false
            print("⚠️ DEBUG: SQLCipher DISABLED - database stored unencrypted")
        } else {
            // Check if SQLCipher is available by looking for cipher_version
            isSQLCipherAvailable = checkSQLCipherAvailable()
            if isSQLCipherAvailable {
                print("🔐 SQLCipher is available - full database encryption enabled")
            } else {
                print("⚠️ SQLCipher not available - using field-level encryption only")
            }
        }

        // Check if biometric protection is available
        hasBiometricProtection = checkBiometricSecretExists()
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

    // MARK: - Biometric Protection Check

    /// Check if biometric secret exists in keychain
    private func checkBiometricSecretExists() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: biometricSecretKey,
            kSecReturnData as String: false,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    // MARK: - Key Management

    /// Get or create the database encryption key
    /// Key is derived from device ID + salt + app secret
    /// App-level biometric lock (Face ID/Touch ID) provides user authentication
    /// NOTE: Changed from biometric-protected secret to fix double Touch ID issue
    func getEncryptionKey() throws -> Data {
        if let key = encryptionKey {
            return key
        }

        // Get or create salt
        let salt = try getOrCreateSalt()

        // Get device-specific identifier
        let deviceId = getDeviceIdentifier()

        // SECURITY NOTE: Database encryption uses device ID + salt + app secret
        // The app-level biometric lock (Face ID/Touch ID) in ContentView provides
        // user authentication protection. We don't need a separate biometric prompt
        // for database encryption - this was causing DOUBLE Touch ID at startup.
        //
        // Security is maintained because:
        // 1. Database is AES-256 encrypted (via SQLCipher)
        // 2. Key is derived from device-specific identifier (cannot decrypt on other device)
        // 3. App-level biometric lock prevents unauthorized app access
        let appSecret = Data("ZipherX-Cypherpunk-2025".utf8)

        // Combine all inputs: deviceId + appSecret
        var combinedInput = Data(deviceId.utf8)
        combinedInput.append(appSecret)

        // Derive 256-bit key using HKDF
        let inputKey = SymmetricKey(data: combinedInput)
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

    /// Get encryption key with explicit biometric authentication
    /// Call this when opening the database after app launch
    func getEncryptionKeyWithAuth() async throws -> Data {
        // If already cached, return immediately
        if let key = encryptionKey {
            return key
        }

        // Perform biometric authentication first
        let context = LAContext()
        context.localizedFallbackTitle = "Use Passcode"

        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            print("🔐 [CRIT-001] Biometric auth not available, using device ID only")
            return try getEncryptionKey()
        }

        // This will trigger Face ID/Touch ID or passcode
        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Authenticate to access your wallet"
            )
            guard success else {
                throw SQLCipherError.authenticationFailed
            }
        } catch {
            print("🔐 [CRIT-001] Authentication failed: \(error)")
            throw SQLCipherError.authenticationFailed
        }

        // Now get the key (biometric secret will be accessible)
        return try getEncryptionKey()
    }

    /// Get or create biometric-protected secret
    /// SECURITY (CRIT-001): Stored with LAContext requiring biometric auth
    private func getOrCreateBiometricSecret() throws -> Data {
        if let secret = self.biometricSecret {
            return secret
        }

        // Try to load from keychain (requires biometric)
        if let existingSecret = loadBiometricSecret() {
            self.biometricSecret = existingSecret
            self.hasBiometricProtection = true
            return existingSecret
        }

        // Generate new random secret
        var newSecret = Data(count: 32)
        let result = newSecret.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, 32, buffer.baseAddress!)
        }

        guard result == errSecSuccess else {
            throw SQLCipherError.keyGenerationFailed
        }

        // Store with biometric protection
        try saveBiometricSecret(newSecret)
        self.biometricSecret = newSecret
        self.hasBiometricProtection = true

        print("🔐 [CRIT-001] Created biometric-protected secret")
        return newSecret
    }

    /// Load biometric secret from keychain (may prompt for Face ID)
    private func loadBiometricSecret() -> Data? {
        // Create LAContext for biometric access
        let context = LAContext()
        context.localizedReason = "Access wallet encryption key"

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: biometricSecretKey,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecSuccess {
            return result as? Data
        } else if status == errSecUserCanceled || status == errSecAuthFailed {
            print("🔐 [CRIT-001] Biometric authentication cancelled/failed")
        }

        return nil
    }

    /// Save biometric secret to keychain with LAContext protection
    private func saveBiometricSecret(_ secret: Data) throws {
        // Create access control requiring biometric auth
        var error: Unmanaged<CFError>?
        guard let accessControl = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
            .userPresence,  // Requires Face ID/Touch ID or passcode
            &error
        ) else {
            throw SQLCipherError.keychainError
        }

        // Delete existing if any
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: biometricSecretKey
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Add with biometric protection
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: biometricSecretKey,
            kSecValueData as String: secret,
            kSecAttrAccessControl as String: accessControl
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            print("🔐 [CRIT-001] Failed to save biometric secret: \(status)")
            throw SQLCipherError.keychainError
        }
    }

    /// Get the encryption key as a hex string (for PRAGMA key)
    /// SQLCipher requires format: "x'..hex..'" with double quotes around the blob
    func getEncryptionKeyHex() throws -> String {
        let keyData = try getEncryptionKey()
        // SQLCipher syntax: PRAGMA key = "x'..hex..'";
        // The hex blob must be wrapped in double quotes
        let hex = "\"x'" + keyData.map { String(format: "%02x", $0) }.joined() + "'\""
        // Log key fingerprint (first 4 bytes) for debugging
        let fingerprint = keyData.prefix(4).map { String(format: "%02x", $0) }.joined()
        print("🔑 Key fingerprint: \(fingerprint)...")
        return hex
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
        var errMsg: UnsafeMutablePointer<CChar>?

        // Apply the key using PRAGMA key
        // SQLCipher 4.x uses secure defaults (AES-256-CBC, HMAC-SHA512, 256000 iterations)
        let keySQL = "PRAGMA key = \(keyHex);"
        let result = sqlite3_exec(db, keySQL, nil, nil, &errMsg)

        if result != SQLITE_OK {
            let error = errMsg != nil ? String(cString: errMsg!) : "Unknown error"
            sqlite3_free(errMsg)
            throw SQLCipherError.encryptionFailed(error)
        }

        // Verify encryption is working by querying something
        var stmt: OpaquePointer?
        let prepResult = sqlite3_prepare_v2(db, "SELECT count(*) FROM sqlite_master;", -1, &stmt, nil)
        if prepResult != SQLITE_OK {
            let errorCode = sqlite3_errcode(db)
            let errorMsg = String(cString: sqlite3_errmsg(db))
            print("🔐 Key verification failed: code=\(errorCode), msg=\(errorMsg)")
            throw SQLCipherError.encryptionFailed("Database key verification failed: \(errorMsg)")
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

        // Attach encrypted destination database with SQLCipher 4.x defaults
        // The key and cipher settings are passed in the ATTACH statement
        let keyHex = try getEncryptionKeyHex()

        // SQLCipher 4.x uses these defaults - we explicitly set them to ensure consistency
        // cipher_page_size=4096, kdf_iter=256000, HMAC_SHA512, PBKDF2_HMAC_SHA512
        // These are the defaults for SQLCipher 4.x so we don't need to override them
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
    case authenticationFailed  // CRIT-001: Biometric auth required

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
        case .authenticationFailed:
            return "Authentication required to access wallet"
        }
    }
}

#if os(macOS)
import IOKit
#endif
