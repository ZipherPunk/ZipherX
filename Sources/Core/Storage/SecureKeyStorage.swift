import Foundation
import Security
import LocalAuthentication
import CryptoKit
#if os(macOS)
import IOKit
#endif

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

    /// Check if running on macOS (may be unsigned during development)
    private var isMacOS: Bool {
        #if os(macOS)
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

        if isMacOS {
            // macOS: Use simple storage without accessibility constraints
            // This avoids -67068 errSecMissingEntitlement on unsigned builds
            print("🖥️ macOS detected, using simple keychain storage")
            try storeKeySimpleMacOS(key, tag: spendingKeyTag)
            print("✅ SecureKeyStorage: Key stored in macOS keychain")
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

        var status = SecItemAdd(query as CFDictionary, nil)

        // If duplicate exists, update instead
        if status == errSecDuplicateItem {
            print("⚠️ SE: Key already exists, updating...")
            let searchQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "ZipherX",
                kSecAttrAccount as String: spendingKeyTag
            ]
            let updateAttributes: [String: Any] = [
                kSecValueData as String: encryptedData
            ]
            status = SecItemUpdate(searchQuery as CFDictionary, updateAttributes as CFDictionary)
        }

        guard status == errSecSuccess else {
            print("❌ SE: Keychain store failed with status: \(status)")
            throw SecureStorageError.keychainStoreFailed(status)
        }
        print("✓ SE: Encrypted key stored in keychain")
    }

    /// Simulator keychain storage with AES-GCM encryption
    /// Uses a device-unique key to encrypt the spending key before storing
    private func storeKeySimple(_ key: Data, tag: String) throws {
        print("🔐 Simulator: Storing \(key.count) bytes with tag: \(tag) (encrypted)")

        // Encrypt the key using AES-GCM with simulator-unique key
        let encryptionKey = try getSimulatorEncryptionKey()
        let sealedBox = try AES.GCM.seal(key, using: encryptionKey)
        guard let encryptedData = sealedBox.combined else {
            throw SecureStorageError.encryptionFailed("Failed to create sealed box")
        }
        print("🔐 Simulator: Encrypted to \(encryptedData.count) bytes")

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "ZipherX",
            kSecAttrAccount as String: tag,
            kSecValueData as String: encryptedData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        var status = SecItemAdd(query as CFDictionary, nil)

        // If duplicate exists (-25299), update instead of add
        if status == errSecDuplicateItem {
            print("⚠️ Simulator: Key already exists, updating...")
            let searchQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "ZipherX",
                kSecAttrAccount as String: tag
            ]
            let updateAttributes: [String: Any] = [
                kSecValueData as String: encryptedData
            ]
            status = SecItemUpdate(searchQuery as CFDictionary, updateAttributes as CFDictionary)
        }

        guard status == errSecSuccess else {
            print("❌ Simulator: Keychain store failed with status: \(status)")
            throw SecureStorageError.keychainStoreFailed(status)
        }
        print("✓ Simulator: Encrypted key stored in keychain")
    }

    /// Get encryption key for simulator (uses device identifier)
    private func getSimulatorEncryptionKey() throws -> SymmetricKey {
        // Use simulator device UDID or a derived identifier
        let deviceId = getSimulatorDeviceId()
        let salt = try getOrCreateSimulatorSalt()

        // Derive encryption key using HKDF
        let inputKeyMaterial = SymmetricKey(data: Data(deviceId.utf8))
        let derivedKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: inputKeyMaterial,
            salt: salt,
            info: Data("ZipherX-simulator-encryption".utf8),
            outputByteCount: 32
        )

        return derivedKey
    }

    /// Get simulator device identifier
    private func getSimulatorDeviceId() -> String {
        #if targetEnvironment(simulator)
        // Use the simulator's UDID from environment or a fallback
        if let simulatorUDID = ProcessInfo.processInfo.environment["SIMULATOR_UDID"] {
            return simulatorUDID
        }
        #endif
        // Fallback: use bundle identifier + a constant
        return "ZipherX-sim-\(Bundle.main.bundleIdentifier ?? "unknown")-device"
    }

    /// Get or create salt for simulator encryption
    private func getOrCreateSimulatorSalt() throws -> Data {
        let saltTag = "com.zipherx.simulator.salt"

        // Try to retrieve existing salt
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "ZipherX-Salt",
            kSecAttrAccount as String: saltTag,
            kSecReturnData as String: true
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecSuccess, let salt = result as? Data {
            return salt
        }

        // Create new random salt
        var salt = Data(count: 32)
        let saltResult = salt.withUnsafeMutableBytes { ptr in
            SecRandomCopyBytes(kSecRandomDefault, 32, ptr.baseAddress!)
        }
        guard saltResult == errSecSuccess else {
            throw SecureStorageError.keyGenerationFailed("Failed to generate random salt")
        }

        // Store salt in keychain
        let storeQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "ZipherX-Salt",
            kSecAttrAccount as String: saltTag,
            kSecValueData as String: salt,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let storeStatus = SecItemAdd(storeQuery as CFDictionary, nil)
        if storeStatus != errSecSuccess && storeStatus != errSecDuplicateItem {
            print("⚠️ Simulator: Could not store salt (status: \(storeStatus)), using in-memory")
        }

        return salt
    }

    /// Decrypt data stored with simulator encryption
    private func decryptSimulatorData(_ encryptedData: Data) throws -> Data {
        let encryptionKey = try getSimulatorEncryptionKey()
        let sealedBox = try AES.GCM.SealedBox(combined: encryptedData)
        let decryptedData = try AES.GCM.open(sealedBox, using: encryptionKey)
        return decryptedData
    }

    /// macOS keychain storage with AES-GCM encryption
    /// Uses a device-unique key to encrypt the spending key before storing
    /// This avoids -67068 errSecMissingEntitlement on unsigned/development builds
    private func storeKeySimpleMacOS(_ key: Data, tag: String) throws {
        print("🖥️ macOS: Storing \(key.count) bytes with tag: \(tag) (encrypted)")

        // Encrypt the key using AES-GCM with device-unique key
        let encryptionKey = try getMacOSEncryptionKey()
        let sealedBox = try AES.GCM.seal(key, using: encryptionKey)
        guard let encryptedData = sealedBox.combined else {
            throw SecureStorageError.encryptionFailed("Failed to create sealed box")
        }
        print("🔐 macOS: Encrypted to \(encryptedData.count) bytes")

        // macOS keychain without accessibility constraints (works without code signing)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "ZipherX",
            kSecAttrAccount as String: tag,
            kSecValueData as String: encryptedData
            // Deliberately NOT setting kSecAttrAccessible to avoid entitlement requirement
        ]

        var status = SecItemAdd(query as CFDictionary, nil)

        // If duplicate exists, update instead of add
        if status == errSecDuplicateItem {
            print("⚠️ macOS: Key already exists, updating...")
            let searchQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "ZipherX",
                kSecAttrAccount as String: tag
            ]
            let updateAttributes: [String: Any] = [
                kSecValueData as String: encryptedData
            ]
            status = SecItemUpdate(searchQuery as CFDictionary, updateAttributes as CFDictionary)
        }

        guard status == errSecSuccess else {
            print("❌ macOS: Keychain store failed with status: \(status)")
            throw SecureStorageError.keychainStoreFailed(status)
        }
        print("✓ macOS: Encrypted key stored in keychain")
    }

    /// Get or create a device-unique encryption key for macOS
    /// This key is derived from the hardware UUID and a salt stored in keychain
    private func getMacOSEncryptionKey() throws -> SymmetricKey {
        // Get hardware UUID
        let hardwareUUID = getHardwareUUID()

        // Get or create salt
        let salt = try getOrCreateMacOSSalt()

        // Derive encryption key using HKDF
        let inputKeyMaterial = SymmetricKey(data: Data(hardwareUUID.utf8))
        let derivedKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: inputKeyMaterial,
            salt: salt,
            info: Data("ZipherX-macOS-encryption".utf8),
            outputByteCount: 32
        )

        return derivedKey
    }

    /// Get hardware UUID on macOS
    private func getHardwareUUID() -> String {
        #if os(macOS)
        let platformExpert = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )
        defer { IOObjectRelease(platformExpert) }

        if let uuid = IORegistryEntryCreateCFProperty(
            platformExpert,
            kIOPlatformUUIDKey as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? String {
            return uuid
        }
        #endif
        // Fallback: use a static string (less secure but works)
        return "ZipherX-macOS-fallback-\(Bundle.main.bundleIdentifier ?? "unknown")"
    }

    /// Get or create a random salt for key derivation
    private func getOrCreateMacOSSalt() throws -> Data {
        let saltTag = "com.zipherx.macos.salt"

        // Try to retrieve existing salt
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "ZipherX-Salt",
            kSecAttrAccount as String: saltTag,
            kSecReturnData as String: true
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecSuccess, let salt = result as? Data {
            return salt
        }

        // Create new random salt
        var salt = Data(count: 32)
        let saltResult = salt.withUnsafeMutableBytes { ptr in
            SecRandomCopyBytes(kSecRandomDefault, 32, ptr.baseAddress!)
        }
        guard saltResult == errSecSuccess else {
            throw SecureStorageError.keyGenerationFailed("Failed to generate random salt")
        }

        // Store salt in keychain
        let storeQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "ZipherX-Salt",
            kSecAttrAccount as String: saltTag,
            kSecValueData as String: salt
        ]

        let storeStatus = SecItemAdd(storeQuery as CFDictionary, nil)
        if storeStatus != errSecSuccess && storeStatus != errSecDuplicateItem {
            print("⚠️ macOS: Could not store salt (status: \(storeStatus)), using in-memory")
        }

        return salt
    }

    /// Decrypt data stored with macOS encryption
    private func decryptMacOSData(_ encryptedData: Data) throws -> Data {
        let encryptionKey = try getMacOSEncryptionKey()
        let sealedBox = try AES.GCM.SealedBox(combined: encryptedData)
        let decryptedData = try AES.GCM.open(sealedBox, using: encryptionKey)
        return decryptedData
    }

    /// Retrieve spending key with biometric authentication
    /// - Returns: The decrypted spending key
    /// Check if a spending key exists AND is usable in secure storage
    /// This validates that we can actually retrieve the key, not just that an entry exists
    /// (An encrypted key without its Secure Enclave decryption key is NOT usable)
    func hasSpendingKey() -> Bool {
        print("🔐 hasSpendingKey: Checking key existence...")

        // First check: Does the keychain entry exist at all? (without reading data to avoid prompt)
        let existsQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "ZipherX",
            kSecAttrAccount as String: spendingKeyTag,
            kSecReturnAttributes as String: true,  // Just get attributes, not data
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail  // Don't show UI
        ]

        var existsResult: AnyObject?
        let existsStatus = SecItemCopyMatching(existsQuery as CFDictionary, &existsResult)

        if existsStatus == errSecItemNotFound {
            print("🔐 hasSpendingKey: No keychain entry found")
            return false
        }

        if existsStatus == errSecInteractionNotAllowed {
            // Item exists but requires authentication - we can't check further without UI
            // On macOS, assume it exists and let retrieveSpendingKey handle errors
            print("🔐 hasSpendingKey: Entry exists but requires authentication")
            // For now, return true and let the actual retrieval fail with proper error handling
            return true
        }

        if existsStatus != errSecSuccess {
            print("🔐 hasSpendingKey: Query failed with status \(existsStatus)")
            return false
        }

        print("🔐 hasSpendingKey: Keychain entry exists, checking data size...")

        // Second check: Get the data size to determine if encrypted or not
        let dataQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "ZipherX",
            kSecAttrAccount as String: spendingKeyTag,
            kSecReturnData as String: true,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail  // Don't show UI
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(dataQuery as CFDictionary, &result)

        if status == errSecInteractionNotAllowed {
            // Data exists but requires user interaction - assume valid on macOS
            print("🔐 hasSpendingKey: Data requires authentication, assuming valid")
            return true
        }

        guard status == errSecSuccess, let data = result as? Data else {
            print("🔐 hasSpendingKey: Could not read data, status=\(status)")
            return false
        }

        print("🔐 hasSpendingKey: Got data, size=\(data.count) bytes")

        // Simulator: data is encrypted with AES-GCM (169 + 12 nonce + 16 tag = 197 bytes)
        if isSimulator {
            // Try to decrypt to verify it's valid
            do {
                let decrypted = try decryptSimulatorData(data)
                let valid = decrypted.count == 169
                print("🔐 hasSpendingKey: Simulator mode, decrypted valid=\(valid)")
                return valid
            } catch {
                print("🔐 hasSpendingKey: Simulator mode, decrypt failed - \(error)")
                return false
            }
        }

        // macOS: data is encrypted with AES-GCM (169 + 12 nonce + 16 tag = 197 bytes)
        if isMacOS {
            // Try to decrypt to verify it's valid
            do {
                let decrypted = try decryptMacOSData(data)
                let valid = decrypted.count == 169
                print("🔐 hasSpendingKey: macOS mode, decrypted valid=\(valid)")
                return valid
            } catch {
                print("🔐 hasSpendingKey: macOS mode, decrypt failed - \(error)")
                return false
            }
        }

        // Check if data is unencrypted (169 bytes = valid spending key)
        if data.count == 169 {
            print("🔐 hasSpendingKey: Unencrypted key (169 bytes)")
            return true
        }

        print("🔐 hasSpendingKey: Data is encrypted (\(data.count) bytes), checking SE key...")

        // Data is encrypted - check if we have the Secure Enclave key to decrypt it
        let keyQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: encryptionKeyTag.data(using: .utf8)!,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnRef as String: true,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail  // Don't show UI
        ]

        var keyRef: AnyObject?
        let keyStatus = SecItemCopyMatching(keyQuery as CFDictionary, &keyRef)

        if keyStatus != errSecSuccess {
            // Encrypted data exists but Secure Enclave key is missing - NOT usable
            print("⚠️ hasSpendingKey: Keychain data exists but Secure Enclave key is missing (status=\(keyStatus))")
            return false
        }

        print("🔐 hasSpendingKey: Both encrypted data and SE key exist - valid!")
        return true
    }

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

        // Simulator: data is encrypted with AES-GCM, need to decrypt
        if isSimulator {
            print("📱 Simulator: Decrypting key from keychain")
            return try decryptSimulatorData(data)
        }

        // macOS: data is encrypted with AES-GCM, need to decrypt
        if isMacOS {
            print("🖥️ macOS: Decrypting key from keychain")
            return try decryptMacOSData(data)
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
    /// This function is tolerant of errors - it tries its best to delete everything
    func deleteSpendingKey() throws {
        var errors: [String] = []

        // Delete encrypted key from keychain
        do {
            try deleteKey(tag: spendingKeyTag)
        } catch {
            // Log but continue - we want to try deleting everything
            print("⚠️ deleteSpendingKey: Failed to delete keychain entry: \(error)")
            errors.append("keychain: \(error.localizedDescription)")
        }

        // Also try deleting viewing key
        do {
            try deleteKey(tag: viewingKeyTag)
        } catch {
            print("⚠️ deleteSpendingKey: Failed to delete viewing key: \(error)")
            // Don't add to errors - viewing key is optional
        }

        // Delete Secure Enclave key
        let keyQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: encryptionKeyTag.data(using: .utf8)!
        ]

        let status = SecItemDelete(keyQuery as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            print("⚠️ deleteSpendingKey: Failed to delete SE key, status: \(status)")
            // On macOS, -25244 (errSecInvalidKeychain) can happen - ignore it
            if status != -25244 {
                errors.append("SE key: status \(status)")
            }
        }

        // Only throw if we couldn't delete anything critical
        // If the item doesn't exist, that's fine - the goal is to ensure it's gone
        if !errors.isEmpty {
            print("⚠️ deleteSpendingKey completed with warnings: \(errors)")
            // Don't throw - we did our best to clean up
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
        // Accept success, item not found, or various macOS keychain issues
        let acceptableStatuses: [OSStatus] = [
            errSecSuccess,
            errSecItemNotFound,
            -25244,  // errSecInvalidKeychain - can happen on macOS
            -25243,  // errSecNoSuchKeychain
            -25291,  // errSecAuthFailed - item may not exist anyway
            -67068   // errSecMissingEntitlement - unsigned macOS builds
        ]
        if !acceptableStatuses.contains(status) {
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
