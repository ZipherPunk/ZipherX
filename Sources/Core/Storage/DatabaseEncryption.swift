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

/// Provides AES-GCM-256 encryption for sensitive database fields
/// Key is derived from device-specific identifier + stored salt using HKDF
@available(macOS 10.15, iOS 13.0, *)
final class DatabaseEncryption {
    static let shared = DatabaseEncryption()

    /// Encryption key (derived on first use)
    private var encryptionKey: SymmetricKey?

    /// Salt for key derivation (stored in keychain)
    private var salt: Data?

    /// Keychain service identifiers
    private let keychainService = "com.zipherx.wallet.dbencryption"
    private let saltKey = "dbEncryptionSalt"

    private init() {}

    // MARK: - Public API

    /// Encrypt data for database storage
    /// Returns: nonce (12 bytes) + ciphertext + tag (16 bytes)
    func encrypt(_ data: Data) throws -> Data {
        let key = try getOrCreateEncryptionKey()
        let sealedBox = try AES.GCM.seal(data, using: key)

        guard let combined = sealedBox.combined else {
            throw EncryptionError.encryptionFailed
        }

        return combined
    }

    /// Decrypt data from database storage
    func decrypt(_ encryptedData: Data) throws -> Data {
        let key = try getOrCreateEncryptionKey()
        let sealedBox = try AES.GCM.SealedBox(combined: encryptedData)
        return try AES.GCM.open(sealedBox, using: key)
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

    /// Get or create the database encryption key
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

    /// Clear cached key (forces re-derivation on next use)
    func clearCachedKey() {
        encryptionKey = nil
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

    /// Decrypt this data from database storage
    func dbDecrypt() throws -> Data {
        try DatabaseEncryption.shared.decrypt(self)
    }
}
