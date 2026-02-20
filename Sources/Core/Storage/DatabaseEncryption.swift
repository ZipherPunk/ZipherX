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

    /// Keychain service identifiers
    private let keychainService = "com.zipherx.wallet.dbencryption"
    private let saltKey = "dbEncryptionSalt"

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
        if let key = encryptionKey {
            return key
        }

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

        self.encryptionKey = derivedKey
        return derivedKey
    }

    /// VUL-STOR-009: Get or create a domain-separated encryption key
    /// Each domain uses a unique HKDF info string to derive an independent key
    private func getOrCreateDomainKey(_ domain: EncryptionDomain) throws -> SymmetricKey {
        if let key = domainKeys[domain] {
            return key
        }

        let salt = try getOrCreateSalt()
        let deviceId = getDeviceIdentifier()

        let inputKey = SymmetricKey(data: Data(deviceId.utf8))
        let derivedKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: inputKey,
            salt: salt,
            info: Data(domain.rawValue.utf8),
            outputByteCount: 32
        )

        domainKeys[domain] = derivedKey
        return derivedKey
    }

    /// Get or create encryption salt (stored in keychain)
    private func getOrCreateSalt() throws -> Data {
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
        // macOS - use hardware UUID
        if let uuid = getHardwareUUID() {
            return "MAC-\(uuid)"
        }
        return "MAC-FALLBACK-\(UUID().uuidString)"

        #else
        return "UNKNOWN-\(UUID().uuidString)"
        #endif
    }

    #if os(macOS)
    /// Get macOS hardware UUID via IOKit
    private func getHardwareUUID() -> String? {
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

        #if os(iOS)
        // iOS: Use most secure accessibility
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        #endif

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw EncryptionError.keychainWriteFailed
        }
    }

    // MARK: - Key Rotation (for future use)

    /// Clear cached keys (forces re-derivation on next use)
    func clearCachedKey() {
        encryptionKey = nil
        domainKeys.removeAll()
        salt = nil
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
