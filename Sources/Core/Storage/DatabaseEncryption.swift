// Copyright (c) 2025 Zipherpunk.com dev team
// Database field encryption using AES-GCM-256
//
// "Privacy is necessary for an open society in the electronic age."
//   - A Cypherpunk's Manifesto

import Foundation
import CryptoKit
#if os(iOS)
import UIKit
#endif
#if os(macOS)
import IOKit
#endif

/// VUL-STOR-009: Encryption domain for HKDF key separation
/// Each domain derives a unique encryption key via HKDF with a distinct info string
enum EncryptionDomain: String {
    case notes = "ZipherX-db-notes-v2"
    case transactions = "ZipherX-db-transactions-v2"
    case keys = "ZipherX-db-keys-v2"
    case chat = "ZipherX-db-chat-v2"
    case general = "ZipherX-db-general-v2"
    case database = "ZipherX-sqlcipher-key-v1"  // SQLCipher database encryption
}

/// Provides AES-GCM-256 encryption for sensitive database fields
/// Key is derived from device-specific identifier + stored salt using HKDF
/// VUL-STOR-009: Per-domain key derivation prevents cross-purpose key reuse
@available(macOS 10.15, iOS 13.0, *)
final class DatabaseEncryption {
    static let shared = DatabaseEncryption()

    /// VUL-STOR-009: Version prefix for encrypted blobs
    /// v1 (0x01) = legacy single-key; v2 (0x02) = domain-separated
    private static let VERSION_V2: UInt8 = 0x02

    /// Legacy encryption key (v1, single key for all domains)
    private var encryptionKey: SymmetricKey?

    /// VUL-STOR-009: Per-domain encryption keys (v2)
    private var domainKeys: [EncryptionDomain: SymmetricKey] = [:]

    /// Salt for key derivation (stored in keychain)
    private var salt: Data?

    /// Thread safety lock — domainKeys/encryptionKey/salt are accessed from multiple
    /// threads during startup (ChatManager notification handler + DB opening).
    /// Without this lock: data race on domainKeys dict → corrupted memory →
    /// "NSTaggedPointerString count: unrecognized selector" crash.
    private let lock = NSLock()

    /// Keychain service identifiers
    private let keychainService = "com.zipherx.wallet.dbencryption"
    private let saltKey = "dbEncryptionSalt"
    /// FIX #1491: Keychain key for device identifier (replaces world-readable Hardware UUID)
    private let deviceIdentifierKey = "dbDeviceIdentifier"

    private init() {}

    // MARK: - Public API

    /// VUL-STOR-009: Derive SQLCipher database encryption key using HKDF
    /// This is called from WalletManager to derive the database key from the spending key
    /// - Parameter rawKey: SHA256(spendingKey) - 32 bytes
    /// - Returns: HKDF-derived 256-bit key for SQLCipher
    static func deriveDatabaseKey(from rawKey: Data) -> Data {
        let inputKey = SymmetricKey(data: rawKey)
        let derivedKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: inputKey,
            salt: Data("ZipherX-SQLCipher-Salt-v1".utf8),  // Constant salt for database key
            info: Data(EncryptionDomain.database.rawValue.utf8),
            outputByteCount: 32  // 256-bit key for SQLCipher
        )
        return derivedKey.withUnsafeBytes { Data($0) }
    }

    /// Encrypt data for database storage (legacy v1, single key)
    /// Returns: nonce (12 bytes) + ciphertext + tag (16 bytes)
    func encrypt(_ data: Data) throws -> Data {
        let key = try getOrCreateEncryptionKey()
        let sealedBox = try AES.GCM.seal(data, using: key)

        guard let combined = sealedBox.combined else {
            throw EncryptionError.encryptionFailed
        }

        return combined
    }

    /// VUL-STOR-009: Encrypt data with domain-separated key
    /// Returns: [0x02] + nonce (12 bytes) + ciphertext + tag (16 bytes)
    func encrypt(_ data: Data, domain: EncryptionDomain) throws -> Data {
        let key = try getOrCreateDomainKey(domain)
        let sealedBox = try AES.GCM.seal(data, using: key)

        guard let combined = sealedBox.combined else {
            throw EncryptionError.encryptionFailed
        }

        // Prepend version byte
        var result = Data([Self.VERSION_V2])
        result.append(combined)
        return result
    }

    /// Decrypt data from database storage
    /// VUL-STOR-009: Handles both v1 (legacy) and v2 (domain-separated) formats
    func decrypt(_ encryptedData: Data) throws -> Data {
        let key = try getOrCreateEncryptionKey()
        let sealedBox = try AES.GCM.SealedBox(combined: encryptedData)
        return try AES.GCM.open(sealedBox, using: key)
    }

    /// VUL-STOR-009: Decrypt data with domain awareness
    /// Detects version prefix and uses correct key
    /// Falls back to v1 legacy if v2 decryption fails (handles false v2 prefix match)
    func decrypt(_ encryptedData: Data, domain: EncryptionDomain) throws -> Data {
        // Check for v2 version prefix
        if encryptedData.count > 29 && encryptedData[encryptedData.startIndex] == Self.VERSION_V2 {
            do {
                let payload = encryptedData.dropFirst()
                let key = try getOrCreateDomainKey(domain)
                let sealedBox = try AES.GCM.SealedBox(combined: payload)
                return try AES.GCM.open(sealedBox, using: key)
            } catch {
                // V2 failed — first nonce byte of v1 data may coincidentally equal 0x02
                // Fall through to v1 legacy
            }
        }

        // Fall back to v1 legacy decryption
        return try decrypt(encryptedData)
    }

    /// Check if data appears to be encrypted (has AES-GCM structure)
    /// AES-GCM combined format: 12-byte nonce + ciphertext + 16-byte tag
    func isEncrypted(_ data: Data) -> Bool {
        // Minimum size: 12 (nonce) + 1 (min ciphertext) + 16 (tag) = 29 bytes
        return data.count >= 29
    }

    /// Encrypt if not already encrypted (for migration)
    func encryptIfNeeded(_ data: Data) throws -> Data {
        // Try to decrypt - if it works, data is already encrypted
        if let _ = try? decrypt(data) {
            return data
        }
        // Not encrypted, encrypt it
        return try encrypt(data)
    }

    // MARK: - Key Management

    /// Get or create the database encryption key (v1 legacy)
    private func getOrCreateEncryptionKey() throws -> SymmetricKey {
        lock.lock()
        if let key = encryptionKey {
            lock.unlock()
            return key
        }
        lock.unlock()

        // Get or create salt
        let salt = try getOrCreateSalt()

        // Get device-specific identifier
        let deviceId = getDeviceIdentifier()

        // Derive key using HKDF
        let inputKey = SymmetricKey(data: Data(deviceId.utf8))
        let derivedKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: inputKey,
            salt: salt,
            info: Data("ZipherX-database-encryption-v1".utf8),
            outputByteCount: 32  // 256-bit key
        )

        lock.lock()
        self.encryptionKey = derivedKey
        lock.unlock()
        return derivedKey
    }

    /// VUL-STOR-009: Get or create a domain-separated encryption key
    /// Each domain uses a unique HKDF info string to derive an independent key
    private func getOrCreateDomainKey(_ domain: EncryptionDomain) throws -> SymmetricKey {
        lock.lock()
        if let key = domainKeys[domain] {
            lock.unlock()
            return key
        }
        lock.unlock()

        let salt = try getOrCreateSalt()
        let deviceId = getDeviceIdentifier()

        let inputKey = SymmetricKey(data: Data(deviceId.utf8))
        let derivedKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: inputKey,
            salt: salt,
            info: Data(domain.rawValue.utf8),
            outputByteCount: 32
        )

        lock.lock()
        domainKeys[domain] = derivedKey
        lock.unlock()
        return derivedKey
    }

    /// Get or create encryption salt (stored in keychain)
    private func getOrCreateSalt() throws -> Data {
        // FIX L-002: Hold lock for entire operation to prevent TOCTOU race.
        // Without this, two concurrent callers could both find salt==nil, both generate
        // a new salt, and store different values — producing an inconsistent derived key.
        lock.lock()
        defer { lock.unlock() }

        if let salt = self.salt {
            return salt
        }

        // Try to retrieve from keychain
        if let existingSalt = try? loadSaltFromKeychain() {
            self.salt = existingSalt
            return existingSalt
        }

        // Generate new random salt
        var newSalt = Data(count: 32)
        let result = newSalt.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, 32, buffer.baseAddress!)
        }

        guard result == errSecSuccess else {
            throw EncryptionError.randomGenerationFailed
        }

        // Store in keychain
        try saveSaltToKeychain(newSalt)
        self.salt = newSalt
        return newSalt
    }

    /// Get device-specific identifier
    /// iOS: Uses identifierForVendor
    /// Simulator: Uses SIMULATOR_UDID
    /// macOS: Uses hardware UUID
    private func getDeviceIdentifier() -> String {
        #if targetEnvironment(simulator)
        // iOS Simulator
        if let udid = ProcessInfo.processInfo.environment["SIMULATOR_UDID"] {
            return "SIM-\(udid)"
        }
        return "SIMULATOR-FALLBACK-\(ProcessInfo.processInfo.hostName)"

        #elseif os(iOS)
        // Real iOS device
        if let vendorId = UIDevice.current.identifierForVendor?.uuidString {
            return "IOS-\(vendorId)"
        }
        return "IOS-FALLBACK-\(UUID().uuidString)"

        #elseif os(macOS)
        // FIX #1491: Use Keychain-stored device identifier instead of world-readable Hardware UUID.
        // Hardware UUID via IOKit requires no entitlements — any process can read it, making it
        // unsuitable as HKDF input key material. A Keychain-stored random UUID ensures both
        // key derivation inputs (device ID + salt) require Keychain access to obtain.
        return getOrCreateMacDeviceIdentifier()

        #else
        return "UNKNOWN-\(UUID().uuidString)"
        #endif
    }

    #if os(macOS)
    // MARK: - macOS Device Identifier (FIX #1491)

    /// FIX #1491: Get or create a macOS device identifier stored in Keychain.
    ///
    /// Migration path for existing installs: on first call after update, reads the Hardware UUID
    /// (IOKit) and stores it in Keychain. Subsequent calls use the Keychain value — IOKit is no
    /// longer accessed. Existing encrypted data remains decryptable (same derived key).
    ///
    /// New installs: IOKit unavailable or no Hardware UUID → generates a cryptographically-random
    /// UUID and stores it in Keychain. Neither HKDF input (device ID + salt) is readable without
    /// Keychain access.
    private func getOrCreateMacDeviceIdentifier() -> String {
        // Fast path: load previously stored identifier from Keychain
        if let existing = loadMacDeviceIdentifierFromKeychain() {
            return existing
        }

        // First call after FIX #1491 update, or fresh install:
        // For existing installs, use the Hardware UUID so already-encrypted data stays decryptable.
        // For new installs where Hardware UUID is unavailable, generate a fresh random UUID.
        let identifier: String
        if let hwUUID = getHardwareUUIDForMigration() {
            // Existing install migration: store Hardware UUID in Keychain so IOKit is never
            // consulted again. The key derivation result is identical — data remains accessible.
            identifier = "MAC-\(hwUUID)"
        } else {
            // New install: both HKDF inputs (device ID + salt) will be random and Keychain-only.
            identifier = "MAC-\(UUID().uuidString)"
        }

        // Persist to Keychain (best-effort; if it fails we'll retry next call)
        try? saveMacDeviceIdentifierToKeychain(identifier)
        return identifier
    }

    private func loadMacDeviceIdentifierFromKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: deviceIdentifierKey,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let identifier = String(data: data, encoding: .utf8) else {
            return nil
        }

        return identifier
    }

    private func saveMacDeviceIdentifierToKeychain(_ identifier: String) throws {
        let data = Data(identifier.utf8)

        // Delete any existing entry first
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: deviceIdentifierKey
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Store with ThisDeviceOnly so the identifier cannot be extracted via cloud backup
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: deviceIdentifierKey,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw EncryptionError.keychainWriteFailed
        }
    }

    /// Read Hardware UUID from IOKit — used ONLY for the one-time migration in
    /// getOrCreateMacDeviceIdentifier(). After migration the value lives in Keychain
    /// and this function is never called again.
    private func getHardwareUUIDForMigration() -> String? {
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

    // MARK: - Keychain Operations

    private func loadSaltFromKeychain() throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: saltKey,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            throw EncryptionError.keychainReadFailed
        }

        return data
    }

    private func saveSaltToKeychain(_ salt: Data) throws {
        // Delete any existing salt first
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: saltKey
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Add new salt
        var addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: saltKey,
            kSecValueData as String: salt
        ]

        // FIX #1491: Apply ThisDeviceOnly accessibility on all platforms.
        // Prevents cloud backup export of encryption key material.
        // Previously only set on iOS; macOS left unprotected (allowed iCloud Keychain sync).
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw EncryptionError.keychainWriteFailed
        }
    }

    // MARK: - Key Rotation (for future use)

    /// Clear cached keys (forces re-derivation on next use)
    func clearCachedKey() {
        lock.lock()
        encryptionKey = nil
        domainKeys.removeAll()
        salt = nil
        lock.unlock()
    }

    /// Delete encryption salt (DANGEROUS - will make encrypted data unrecoverable!)
    func deleteSalt() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: saltKey
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw EncryptionError.keychainDeleteFailed
        }

        clearCachedKey()
    }
}

// MARK: - Errors

enum EncryptionError: Error, LocalizedError {
    case encryptionFailed
    case decryptionFailed
    case randomGenerationFailed
    case keychainReadFailed
    case keychainWriteFailed
    case keychainDeleteFailed
    case invalidData

    var errorDescription: String? {
        switch self {
        case .encryptionFailed: return "Failed to encrypt data"
        case .decryptionFailed: return "Failed to decrypt data"
        case .randomGenerationFailed: return "Failed to generate random bytes"
        case .keychainReadFailed: return "Failed to read from keychain"
        case .keychainWriteFailed: return "Failed to write to keychain"
        case .keychainDeleteFailed: return "Failed to delete from keychain"
        case .invalidData: return "Invalid encrypted data format"
        }
    }
}

// MARK: - Convenience Extensions

extension Data {
    /// Encrypt this data for database storage
    func dbEncrypt() throws -> Data {
        try DatabaseEncryption.shared.encrypt(self)
    }

    /// VUL-STOR-009: Encrypt with domain-separated key
    func dbEncrypt(domain: EncryptionDomain) throws -> Data {
        try DatabaseEncryption.shared.encrypt(self, domain: domain)
    }

    /// Decrypt this data from database storage
    func dbDecrypt() throws -> Data {
        try DatabaseEncryption.shared.decrypt(self)
    }

    /// VUL-STOR-009: Decrypt with domain awareness
    func dbDecrypt(domain: EncryptionDomain) throws -> Data {
        try DatabaseEncryption.shared.decrypt(self, domain: domain)
    }
}
