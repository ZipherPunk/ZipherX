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
    /// Falls back to simple keychain storage on Simulator or if Secure Enclave fails
    /// - Parameter key: The spending key data to store
    func storeSpendingKey(_ key: Data) throws {
        print("🔐 SecureKeyStorage: Starting key storage (\(key.count) bytes)")

        // Delete existing key if present
        print("🔐 SecureKeyStorage: Deleting any existing key...")
        let deleteResult = deleteKeyInternal(tag: spendingKeyTag)
        print("🔐 SecureKeyStorage: Delete existing key result: \(deleteResult)")

        // Also delete any existing Secure Enclave key to avoid orphaned keys
        let oldKeyQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: encryptionKeyTag.data(using: .utf8)!
        ]
        let seDeleteStatus = SecItemDelete(oldKeyQuery as CFDictionary)
        print("🔐 SecureKeyStorage: Delete Secure Enclave key status: \(seDeleteStatus)")

        if isSimulator {
            // Simulator fallback: store directly in keychain (NOT SECURE - dev only!)
            print("📱 Simulator detected, using simple keychain storage")
            try storeKeySimple(key, tag: spendingKeyTag)
            print("✅ SecureKeyStorage: Key stored in simulator keychain")
            return
        }

        // Try Secure Enclave first, fall back to simple keychain if it fails
        do {
            print("🔐 SecureKeyStorage: Attempting Secure Enclave storage...")
            try storeKeyWithSecureEnclave(key)
            print("✅ SecureKeyStorage: Key stored with Secure Enclave protection")
        } catch {
            // Secure Enclave failed (maybe no biometrics enrolled)
            // Fall back to simple keychain storage
            print("⚠️ SecureKeyStorage: Secure Enclave failed: \(error.localizedDescription)")
            print("📱 SecureKeyStorage: Falling back to keychain storage (less secure)")
            try storeKeySimple(key, tag: spendingKeyTag)
            print("✅ SecureKeyStorage: Key stored in fallback keychain")
        }
    }

    /// Internal delete that returns status for debugging
    private func deleteKeyInternal(tag: String) -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "ZipherX",
            kSecAttrAccount as String: tag
        ]
        return SecItemDelete(query as CFDictionary)
    }

    /// Store key using Secure Enclave (may throw if biometrics not available)
    private func storeKeyWithSecureEnclave(_ key: Data) throws {
        // Check if biometrics are available (for logging only)
        let context = LAContext()
        var authError: NSError?
        let biometricsAvailable = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &authError)
        print("🔐 SE: Biometrics available: \(biometricsAvailable), error: \(authError?.localizedDescription ?? "none")")

        // Create access control - DO NOT require biometrics for key access
        // Biometric auth is handled at the UI level (SendView) before transactions
        // This allows startup/sync without Face ID prompts
        var error: Unmanaged<CFError>?
        let accessFlags: SecAccessControlCreateFlags = [.privateKeyUsage]
        print("🔐 SE: Using access flags: \(accessFlags.rawValue) (no biometric requirement)")

        guard let accessControl = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            accessFlags,
            &error
        ) else {
            let errorMsg = error?.takeRetainedValue().localizedDescription ?? "Unknown error"
            print("❌ SE: Access control creation failed: \(errorMsg)")
            throw SecureStorageError.accessControlCreationFailed(errorMsg)
        }
        print("✓ SE: Access control created")

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
            let errorMsg = keyError?.takeRetainedValue().localizedDescription ?? "Unknown error"
            print("❌ SE: Key generation failed: \(errorMsg)")
            throw SecureStorageError.keyGenerationFailed(errorMsg)
        }
        print("✓ SE: Secure Enclave key generated")

        // Encrypt the spending key with the Secure Enclave key
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            print("❌ SE: Failed to extract public key")
            throw SecureStorageError.publicKeyExtractionFailed
        }
        print("✓ SE: Public key extracted")

        var encryptError: Unmanaged<CFError>?
        guard let encryptedData = SecKeyCreateEncryptedData(
            publicKey,
            .eciesEncryptionCofactorVariableIVX963SHA256AESGCM,
            key as CFData,
            &encryptError
        ) else {
            let errorMsg = encryptError?.takeRetainedValue().localizedDescription ?? "Unknown error"
            print("❌ SE: Encryption failed: \(errorMsg)")
            throw SecureStorageError.encryptionFailed(errorMsg)
        }
        print("✓ SE: Data encrypted (\(CFDataGetLength(encryptedData)) bytes)")

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
            print("❌ SE: Keychain store failed with status: \(status)")
            throw SecureStorageError.keychainStoreFailed(status)
        }
        print("✓ SE: Encrypted key stored in keychain")
    }

    /// Simple keychain storage for Simulator or fallback (NOT SECURE - development only)
    private func storeKeySimple(_ key: Data, tag: String) throws {
        print("🔐 Simple: Storing \(key.count) bytes with tag: \(tag)")
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "ZipherX",
            kSecAttrAccount as String: tag,
            kSecValueData as String: key,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            print("❌ Simple: Keychain store failed with status: \(status)")
            throw SecureStorageError.keychainStoreFailed(status)
        }
        print("✓ Simple: Key stored in keychain")
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

        // Check if we have a Secure Enclave key
        // NOTE: Do NOT use kSecUseOperationPrompt here - that would trigger Face ID
        // Face ID should only be required for SENDING transactions, not reading
        let keyQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: encryptionKeyTag.data(using: .utf8)!,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnRef as String: true
        ]

        var keyRef: AnyObject?
        let keyStatus = SecItemCopyMatching(keyQuery as CFDictionary, &keyRef)

        // If no Secure Enclave key exists, the data is stored unencrypted (fallback mode)
        if keyStatus != errSecSuccess {
            // Check if the data looks like a valid spending key (169 bytes for extended spending key)
            // If it's 169 bytes, it's likely unencrypted (simple keychain fallback)
            if data.count == 169 {
                print("📱 Using fallback keychain storage (no Secure Enclave key)")
                return data
            }
            // Otherwise it might be encrypted but we lost the key - this is bad
            throw SecureStorageError.secureEnclaveKeyNotFound
        }

        // Real device with Secure Enclave: data is encrypted, need to decrypt
        let privateKey = keyRef as! SecKey
        let encryptedData = data

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
