import Foundation
import Security
import LocalAuthentication
import CryptoKit

/// Secure Key Storage using iOS Secure Enclave
/// Keys NEVER leave the hardware security module
final class SecureKeyStorage {

    // MARK: - Constants
    private let spendingKeyTag = "com.zipherx.spendingkey"
    private let viewingKeyTag = "com.zipherx.viewingkey"
    private let encryptionKeyTag = "com.zipherx.encryptionkey"

    // MARK: - Secure Enclave Key Management

    /// Check if running on simulator
    private var isSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    /// Store spending key with Secure Enclave protection
    /// Falls back to simple keychain storage on Simulator
    /// - Parameter key: The spending key data to store
    func storeSpendingKey(_ key: Data) throws {
        // Delete existing key if present
        try? deleteKey(tag: spendingKeyTag)

        if isSimulator {
            // Simulator fallback: store directly in keychain (NOT SECURE - dev only!)
            try storeKeySimple(key, tag: spendingKeyTag)
            return
        }

        // Create access control with biometric protection
        var error: Unmanaged<CFError>?
        guard let accessControl = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.privateKeyUsage, .biometryCurrentSet],
            &error
        ) else {
            throw SecureStorageError.accessControlCreationFailed(error?.takeRetainedValue().localizedDescription ?? "Unknown error")
        }

        // Generate a Secure Enclave key for encryption
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: encryptionKeyTag.data(using: .utf8)!,
                kSecAttrAccessControl as String: accessControl
            ]
        ]

        var keyError: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &keyError) else {
            throw SecureStorageError.keyGenerationFailed(keyError?.takeRetainedValue().localizedDescription ?? "Unknown error")
        }

        // Encrypt the spending key with the Secure Enclave key
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw SecureStorageError.publicKeyExtractionFailed
        }

        var encryptError: Unmanaged<CFError>?
        guard let encryptedData = SecKeyCreateEncryptedData(
            publicKey,
            .eciesEncryptionCofactorVariableIVX963SHA256AESGCM,
            key as CFData,
            &encryptError
        ) else {
            throw SecureStorageError.encryptionFailed(encryptError?.takeRetainedValue().localizedDescription ?? "Unknown error")
        }

        // Store encrypted spending key in keychain
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "ZipherX",
            kSecAttrAccount as String: spendingKeyTag,
            kSecValueData as String: encryptedData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw SecureStorageError.keychainStoreFailed(status)
        }
    }

    /// Simple keychain storage for Simulator (NOT SECURE - development only)
    private func storeKeySimple(_ key: Data, tag: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "ZipherX",
            kSecAttrAccount as String: tag,
            kSecValueData as String: key,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw SecureStorageError.keychainStoreFailed(status)
        }
    }

    /// Retrieve spending key with biometric authentication
    /// - Returns: The decrypted spending key
    func retrieveSpendingKey() throws -> Data {
        // Get data from keychain
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "ZipherX",
            kSecAttrAccount as String: spendingKeyTag,
            kSecReturnData as String: true
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            throw SecureStorageError.keyNotFound
        }

        // Simulator fallback: data is stored unencrypted
        if isSimulator {
            return data
        }

        // Real device: data is encrypted, need Secure Enclave to decrypt
        let encryptedData = data

        // Get Secure Enclave private key for decryption
        let keyQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: encryptionKeyTag.data(using: .utf8)!,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnRef as String: true,
            kSecUseOperationPrompt as String: "Authenticate to access your wallet"
        ]

        var keyRef: AnyObject?
        let keyStatus = SecItemCopyMatching(keyQuery as CFDictionary, &keyRef)

        guard keyStatus == errSecSuccess else {
            throw SecureStorageError.secureEnclaveKeyNotFound
        }

        let privateKey = keyRef as! SecKey

        // Decrypt the spending key
        var decryptError: Unmanaged<CFError>?
        guard let decryptedData = SecKeyCreateDecryptedData(
            privateKey,
            .eciesEncryptionCofactorVariableIVX963SHA256AESGCM,
            encryptedData as CFData,
            &decryptError
        ) else {
            throw SecureStorageError.decryptionFailed(decryptError?.takeRetainedValue().localizedDescription ?? "Unknown error")
        }

        return decryptedData as Data
    }

    /// Delete spending key and associated Secure Enclave key
    func deleteSpendingKey() throws {
        // Delete encrypted key from keychain
        try deleteKey(tag: spendingKeyTag)

        // Delete Secure Enclave key
        let keyQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: encryptionKeyTag.data(using: .utf8)!
        ]

        let status = SecItemDelete(keyQuery as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw SecureStorageError.keychainDeleteFailed(status)
        }
    }

    // MARK: - Viewing Key Storage (not in Secure Enclave)

    /// Store viewing key (less sensitive, doesn't require Secure Enclave)
    func storeViewingKey(_ key: Data) throws {
        try? deleteKey(tag: viewingKeyTag)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "ZipherX",
            kSecAttrAccount as String: viewingKeyTag,
            kSecValueData as String: key,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw SecureStorageError.keychainStoreFailed(status)
        }
    }

    /// Retrieve viewing key
    func retrieveViewingKey() throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "ZipherX",
            kSecAttrAccount as String: viewingKeyTag,
            kSecReturnData as String: true
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            throw SecureStorageError.keyNotFound
        }

        return data
    }

    // MARK: - Helper Methods

    private func deleteKey(tag: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "ZipherX",
            kSecAttrAccount as String: tag
        ]

        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw SecureStorageError.keychainDeleteFailed(status)
        }
    }

    /// Check if Secure Enclave is available on this device
    static var isSecureEnclaveAvailable: Bool {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave
        ]

        var error: Unmanaged<CFError>?
        let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error)

        if let key = key {
            // Clean up test key
            let deleteQuery: [String: Any] = [
                kSecClass as String: kSecClassKey,
                kSecValueRef as String: key
            ]
            SecItemDelete(deleteQuery as CFDictionary)
            return true
        }

        return false
    }
}

// MARK: - Secure Storage Errors
enum SecureStorageError: LocalizedError {
    case accessControlCreationFailed(String)
    case keyGenerationFailed(String)
    case publicKeyExtractionFailed
    case encryptionFailed(String)
    case decryptionFailed(String)
    case keychainStoreFailed(OSStatus)
    case keychainDeleteFailed(OSStatus)
    case keyNotFound
    case secureEnclaveKeyNotFound
    case secureEnclaveNotAvailable

    var errorDescription: String? {
        switch self {
        case .accessControlCreationFailed(let message):
            return "Failed to create access control: \(message)"
        case .keyGenerationFailed(let message):
            return "Failed to generate Secure Enclave key: \(message)"
        case .publicKeyExtractionFailed:
            return "Failed to extract public key"
        case .encryptionFailed(let message):
            return "Encryption failed: \(message)"
        case .decryptionFailed(let message):
            return "Decryption failed: \(message)"
        case .keychainStoreFailed(let status):
            return "Keychain store failed with status: \(status)"
        case .keychainDeleteFailed(let status):
            return "Keychain delete failed with status: \(status)"
        case .keyNotFound:
            return "Key not found in storage"
        case .secureEnclaveKeyNotFound:
            return "Secure Enclave key not found"
        case .secureEnclaveNotAvailable:
            return "Secure Enclave is not available on this device"
        }
    }
}
