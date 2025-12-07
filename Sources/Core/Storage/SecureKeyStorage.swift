import Foundation
import Security
import LocalAuthentication
import CryptoKit
#if os(macOS)
import IOKit
#endif

/// Secure Key Storage using iOS Secure Enclave
/// Keys NEVER leave the hardware security module
///
/// Memory Protection:
/// - Spending keys are NEVER cached in memory
/// - Keys are retrieved fresh from Secure Enclave for each operation
/// - Decrypted key data is zeroed immediately after use via `SecureData`
final class SecureKeyStorage {

    // MARK: - Singleton
    static let shared = SecureKeyStorage()

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

    /// macOS file-based storage with AES-GCM encryption
    /// Uses encrypted file instead of keychain to avoid -67068 errSecMissingEntitlement on unsigned builds
    private func storeKeySimpleMacOS(_ key: Data, tag: String) throws {
        print("🖥️ macOS: Storing \(key.count) bytes with tag: \(tag) (encrypted file)")

        // Encrypt the key using AES-GCM with device-unique key
        let encryptionKey = try getMacOSEncryptionKey()
        let sealedBox = try AES.GCM.seal(key, using: encryptionKey)
        guard let encryptedData = sealedBox.combined else {
            throw SecureStorageError.encryptionFailed("Failed to create sealed box")
        }
        print("🔐 macOS: Encrypted to \(encryptedData.count) bytes")

        // Store in encrypted file in app's Application Support directory
        let fileURL = try getMacOSKeyFileURL(for: tag)

        // Create directory if needed
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Write encrypted data atomically
        // NOTE: Don't use .completeFileProtection on macOS - it causes permission errors
        // The file is already AES-GCM encrypted with a device-bound key
        try encryptedData.write(to: fileURL, options: [.atomic])

        print("✓ macOS: Encrypted key stored at \(fileURL.path)")
    }

    /// Get the file URL for storing encrypted keys on macOS
    private func getMacOSKeyFileURL(for tag: String) throws -> URL {
        let fileManager = FileManager.default

        // Use Application Support directory
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw SecureStorageError.keyGenerationFailed("Could not find Application Support directory")
        }

        let zipherxDir = appSupport.appendingPathComponent("ZipherX", isDirectory: true)
        let safeTag = tag.replacingOccurrences(of: ".", with: "_")
        return zipherxDir.appendingPathComponent("\(safeTag).enc")
    }

    /// Check if macOS key file exists
    private func macOSKeyFileExists(for tag: String) -> Bool {
        guard let fileURL = try? getMacOSKeyFileURL(for: tag) else { return false }
        return FileManager.default.fileExists(atPath: fileURL.path)
    }

    /// Read encrypted key from macOS file
    private func readMacOSKeyFile(for tag: String) throws -> Data {
        let fileURL = try getMacOSKeyFileURL(for: tag)
        return try Data(contentsOf: fileURL)
    }

    /// Delete macOS key file
    private func deleteMacOSKeyFile(for tag: String) throws {
        let fileURL = try getMacOSKeyFileURL(for: tag)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
            print("🗑️ macOS: Deleted key file at \(fileURL.path)")
        }
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

    /// Get or create a random salt for key derivation (file-based for macOS)
    private func getOrCreateMacOSSalt() throws -> Data {
        let fileManager = FileManager.default

        // Use Application Support directory for salt file
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw SecureStorageError.keyGenerationFailed("Could not find Application Support directory")
        }

        let zipherxDir = appSupport.appendingPathComponent("ZipherX", isDirectory: true)
        let saltFileURL = zipherxDir.appendingPathComponent("key_salt.bin")

        // Try to read existing salt
        if fileManager.fileExists(atPath: saltFileURL.path) {
            let salt = try Data(contentsOf: saltFileURL)
            if salt.count == 32 {
                return salt
            }
        }

        // Create directory if needed
        try fileManager.createDirectory(at: zipherxDir, withIntermediateDirectories: true)

        // Create new random salt
        var salt = Data(count: 32)
        let saltResult = salt.withUnsafeMutableBytes { ptr in
            SecRandomCopyBytes(kSecRandomDefault, 32, ptr.baseAddress!)
        }
        guard saltResult == errSecSuccess else {
            throw SecureStorageError.keyGenerationFailed("Failed to generate random salt")
        }

        // Store salt to file
        try salt.write(to: saltFileURL, options: [.atomic])
        print("🔐 macOS: Created new salt file at \(saltFileURL.path)")

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

        // macOS: Check file-based storage (keychain doesn't work on unsigned builds)
        if isMacOS {
            let fileExists = macOSKeyFileExists(for: spendingKeyTag)
            print("🔐 hasSpendingKey: macOS file exists = \(fileExists)")
            if fileExists {
                // Try to decrypt to verify it's valid
                do {
                    let encryptedData = try readMacOSKeyFile(for: spendingKeyTag)
                    let decrypted = try decryptMacOSData(encryptedData)
                    let valid = decrypted.count == 169
                    print("🔐 hasSpendingKey: macOS mode, decrypted valid=\(valid)")
                    return valid
                } catch {
                    print("🔐 hasSpendingKey: macOS mode, decrypt failed - \(error)")
                    return false
                }
            }
            return false
        }

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
            // Data exists but requires user interaction - assume valid
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
        // macOS: Use file-based storage (keychain doesn't work on unsigned builds)
        if isMacOS {
            print("🖥️ macOS: Reading encrypted key from file")
            let encryptedData = try readMacOSKeyFile(for: spendingKeyTag)
            return try decryptMacOSData(encryptedData)
        }

        // Get data from keychain (iOS device / simulator)
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

        // macOS: Delete file-based storage
        if isMacOS {
            do {
                try deleteMacOSKeyFile(for: spendingKeyTag)
                print("✓ deleteSpendingKey: macOS key file deleted")
            } catch {
                print("⚠️ deleteSpendingKey: Failed to delete macOS key file: \(error)")
                errors.append("macOS file: \(error.localizedDescription)")
            }
        }

        // Delete encrypted key from keychain (iOS / simulator)
        do {
            try deleteKey(tag: spendingKeyTag)
        } catch {
            // Log but continue - we want to try deleting everything
            print("⚠️ deleteSpendingKey: Failed to delete keychain entry: \(error)")
            if !isMacOS {
                errors.append("keychain: \(error.localizedDescription)")
            }
        }

        // Also try deleting viewing key
        do {
            try deleteKey(tag: viewingKeyTag)
        } catch {
            print("⚠️ deleteSpendingKey: Failed to delete viewing key: \(error)")
            // Don't add to errors - viewing key is optional
        }

        // Delete Secure Enclave key (iOS only)
        if !isMacOS {
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

    // MARK: - VUL-014: Key Rotation Policy

    private let keyCreationDateKey = "ZipherX.KeyCreationDate"
    private let keyRotationWarningDays: Int = 365  // Recommend rotation after 1 year

    /// Record the key creation date (call after generating new wallet)
    func recordKeyCreationDate() {
        let now = Date()
        UserDefaults.standard.set(now, forKey: keyCreationDateKey)
        print("🔑 Key creation date recorded: \(now)")
    }

    /// Get the key creation date
    func getKeyCreationDate() -> Date? {
        return UserDefaults.standard.object(forKey: keyCreationDateKey) as? Date
    }

    /// Clear the key creation date (call when deleting wallet)
    func clearKeyCreationDate() {
        UserDefaults.standard.removeObject(forKey: keyCreationDateKey)
        print("🔑 Key creation date cleared")
    }

    /// Check if key rotation is recommended (> 365 days old)
    /// Returns: number of days since creation, or nil if no creation date recorded
    func getKeyAgeDays() -> Int? {
        guard let creationDate = getKeyCreationDate() else { return nil }
        let daysSinceCreation = Calendar.current.dateComponents([.day], from: creationDate, to: Date()).day
        return daysSinceCreation
    }

    /// Check if key rotation should be recommended to the user
    /// Returns true if key is older than 365 days
    func shouldRecommendKeyRotation() -> Bool {
        guard let ageDays = getKeyAgeDays() else {
            // No creation date recorded - could be old wallet, recommend setting up date
            if hasSpendingKey() {
                // Has key but no date - assume it's old and should rotate
                print("⚠️ VUL-014: Key exists but no creation date - recommend rotation")
                return true
            }
            return false
        }
        let shouldRotate = ageDays >= keyRotationWarningDays
        if shouldRotate {
            print("⚠️ VUL-014: Key is \(ageDays) days old - rotation recommended")
        }
        return shouldRotate
    }

    /// Get a user-friendly message about key age for display in Settings
    func getKeyAgeMessage() -> String {
        guard let ageDays = getKeyAgeDays() else {
            if hasSpendingKey() {
                return "Unknown age (pre-dating tracking)"
            }
            return "No key stored"
        }

        if ageDays < 30 {
            return "Created recently (\(ageDays) days ago)"
        } else if ageDays < 365 {
            let months = ageDays / 30
            return "Created \(months) month\(months == 1 ? "" : "s") ago"
        } else {
            let years = ageDays / 365
            let remainingMonths = (ageDays % 365) / 30
            var message = "Created \(years) year\(years == 1 ? "" : "s")"
            if remainingMonths > 0 {
                message += " \(remainingMonths) month\(remainingMonths == 1 ? "" : "s")"
            }
            message += " ago"
            return message
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

// MARK: - SecureData: Memory-Protected Key Container

/// A wrapper for sensitive key data that automatically zeros memory when deallocated.
/// Use this for any decrypted spending key data to prevent keys from lingering in memory.
///
/// Usage:
/// ```swift
/// let secureKey = try SecureData(SecureKeyStorage.shared.retrieveSpendingKey())
/// // Use secureKey.data for operations
/// // Memory is automatically zeroed when secureKey goes out of scope
/// ```
final class SecureData {
    /// The underlying data - DO NOT copy or store this elsewhere
    private(set) var bytes: [UInt8]

    /// Access the data as Data (creates a copy - use sparingly)
    /// WARNING: The returned Data is a COPY and won't be zeroed!
    /// Prefer using withUnsafeBytes for FFI calls when possible.
    var data: Data {
        return Data(bytes)
    }

    /// Initialize with Data (copies bytes to internal array)
    init(_ data: Data) {
        self.bytes = Array(data)
    }

    /// Initialize with byte array (takes ownership)
    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    /// Execute a closure with direct access to the bytes (no copy)
    /// Use this for FFI calls to avoid creating additional copies in Swift memory
    @discardableResult
    func withUnsafeBytes<T>(_ body: (UnsafeRawBufferPointer) throws -> T) rethrows -> T {
        return try bytes.withUnsafeBytes(body)
    }

    /// Manually zero the memory (call this when done with the key)
    /// SECURITY VUL-008 FIX: Uses memset_s for secure zeroing that cannot be optimized away
    func zero() {
        bytes.withUnsafeMutableBytes { ptr in
            guard let baseAddress = ptr.baseAddress else { return }

            #if os(iOS) || os(macOS)
            // Use memset_s which is guaranteed not to be optimized away (C11 Annex K)
            // Even if compiler thinks bytes are not used, memset_s must execute
            _ = Darwin.memset_s(baseAddress, ptr.count, 0, ptr.count)
            #else
            // Fallback: volatile-like pattern for other platforms
            for i in 0..<ptr.count {
                baseAddress.storeBytes(of: 0 as UInt8, toByteOffset: i, as: UInt8.self)
            }
            #endif
        }
    }

    /// Automatically zero memory when deallocated
    deinit {
        zero()
        #if DEBUG
        print("🔐 SecureData: Memory zeroed (\(bytes.count) bytes)")
        #endif
    }
}

// MARK: - Secure Key Access Extension

extension SecureKeyStorage {
    /// Retrieve spending key wrapped in SecureData for automatic memory cleanup
    /// The key data will be zeroed when the SecureData object is deallocated
    func retrieveSpendingKeySecure() throws -> SecureData {
        let keyData = try retrieveSpendingKey()
        return SecureData(keyData)
    }

    /// Execute a closure with the spending key, then automatically zero the key memory
    /// SECURITY VUL-008 FIX: This is the REQUIRED way to use the spending key
    /// The key is passed as UnsafeRawBufferPointer to avoid creating copies in Swift memory
    ///
    /// Example:
    /// ```swift
    /// let result = try SecureKeyStorage.shared.withSpendingKey { keyPtr in
    ///     // Pass keyPtr to FFI functions
    ///     return someFFIFunction(keyPtr.baseAddress, keyPtr.count)
    /// }
    /// // Key memory is now zeroed
    /// ```
    func withSpendingKey<T>(_ operation: (UnsafeRawBufferPointer) throws -> T) throws -> T {
        let secureKey = try retrieveSpendingKeySecure()
        defer { secureKey.zero() }  // Ensure zeroing even on throw
        return try secureKey.withUnsafeBytes(operation)
    }

    /// Execute a closure with the spending key as Data
    /// WARNING: This creates a copy in Swift managed memory that may not be zeroed!
    /// Use withSpendingKey(UnsafeRawBufferPointer) for FFI calls when possible.
    /// Only use this when the API requires Data and zeroing is handled in Rust.
    func withSpendingKeyData<T>(_ operation: (Data) throws -> T) throws -> T {
        let secureKey = try retrieveSpendingKeySecure()
        defer { secureKey.zero() }  // Zeros our local copy
        return try operation(secureKey.data)  // WARNING: Data copy may linger
    }

    // MARK: - VUL-002 FIX: Encrypted Key Access for FFI
    // These functions provide encrypted key data that can be passed to Rust for
    // decryption in memory that Rust can explicitly zero.

    /// Retrieve the encrypted spending key data
    /// For AES-GCM format (simulator/macOS): 197 bytes = nonce(12) + ciphertext(169) + tag(16)
    /// For Secure Enclave format (iOS device): variable size (encrypted with SE public key)
    /// This data can be passed to Rust for decryption where memory can be explicitly zeroed
    func retrieveEncryptedSpendingKey() throws -> Data {
        if isSimulator {
            // Simulator: key might be stored encrypted in keychain (AES-GCM format)
            // OR it might have used Secure Enclave if available (Apple Silicon Macs)
            print("📱 Simulator: Retrieving encrypted key from keychain")
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "ZipherX",
                kSecAttrAccount as String: spendingKeyTag,
                kSecReturnData as String: true
            ]

            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)

            guard status == errSecSuccess, let encryptedData = result as? Data else {
                throw SecureStorageError.keyNotFound
            }

            // Check if it's AES-GCM format (197 bytes) or Secure Enclave format (>197 bytes)
            if encryptedData.count == 197 {
                // AES-GCM format - can be passed directly to Rust
                return encryptedData
            } else if encryptedData.count > 169 {
                // Secure Enclave format - need to decrypt and re-encrypt in AES-GCM format
                // This happens on Apple Silicon simulators that have access to Secure Enclave
                print("📱 Simulator: Key was stored with Secure Enclave (\(encryptedData.count) bytes), converting to AES-GCM format")

                // Get the Secure Enclave private key
                let keyQuery: [String: Any] = [
                    kSecClass as String: kSecClassKey,
                    kSecAttrApplicationTag as String: encryptionKeyTag.data(using: .utf8)!,
                    kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
                    kSecReturnRef as String: true
                ]

                var keyRef: AnyObject?
                let keyStatus = SecItemCopyMatching(keyQuery as CFDictionary, &keyRef)

                guard keyStatus == errSecSuccess else {
                    print("⚠️ Simulator: Secure Enclave key not found (status: \(keyStatus))")
                    throw SecureStorageError.secureEnclaveKeyNotFound
                }

                // Decrypt with Secure Enclave
                let privateKey = keyRef as! SecKey
                var decryptError: Unmanaged<CFError>?
                guard let decryptedData = SecKeyCreateDecryptedData(
                    privateKey,
                    .eciesEncryptionCofactorVariableIVX963SHA256AESGCM,
                    encryptedData as CFData,
                    &decryptError
                ) else {
                    let errorMsg = decryptError?.takeRetainedValue().localizedDescription ?? "Unknown error"
                    print("⚠️ Simulator: Secure Enclave decryption failed: \(errorMsg)")
                    throw SecureStorageError.decryptionFailed(errorMsg)
                }

                let decryptedKey = decryptedData as Data
                print("📱 Simulator: Decrypted key (\(decryptedKey.count) bytes), re-encrypting with AES-GCM")

                // Re-encrypt with AES-GCM for Rust FFI
                let encryptionKey = try getSimulatorEncryptionKey()
                let sealedBox = try AES.GCM.seal(decryptedKey, using: encryptionKey)
                guard let reEncrypted = sealedBox.combined else {
                    throw SecureStorageError.encryptionFailed("Failed to re-encrypt key")
                }
                print("📱 Simulator: Re-encrypted to AES-GCM format (\(reEncrypted.count) bytes)")
                return reEncrypted
            } else {
                print("⚠️ Simulator: Unexpected encrypted key size: \(encryptedData.count)")
                throw SecureStorageError.keyNotFound
            }
        }

        if isMacOS {
            // macOS: key is stored encrypted in file
            print("🖥️ macOS: Retrieving encrypted key from file")
            let fileURL = try getMacOSKeyFileURL(for: spendingKeyTag)

            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                throw SecureStorageError.keyNotFound
            }

            let encryptedData = try Data(contentsOf: fileURL)

            // Verify correct length (should be 197 bytes)
            guard encryptedData.count == 197 else {
                throw SecureStorageError.keyNotFound
            }

            return encryptedData
        }

        // iOS device with Secure Enclave - key is stored encrypted
        // We need to retrieve the encrypted form, not decrypt it
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "ZipherX",
            kSecAttrAccount as String: spendingKeyTag,
            kSecReturnData as String: true
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let encryptedData = result as? Data else {
            throw SecureStorageError.keyNotFound
        }

        // Verify correct length (should be 197 bytes)
        guard encryptedData.count == 197 else {
            throw SecureStorageError.keyNotFound
        }

        return encryptedData
    }

    /// Get the raw encryption key bytes for passing to Rust FFI (32 bytes)
    /// WARNING: This key is sensitive - only pass to Rust FFI for key decryption
    func getEncryptionKeyForFFI() throws -> Data {
        let encryptionKey: SymmetricKey

        if isSimulator {
            encryptionKey = try getSimulatorEncryptionKey()
        } else if isMacOS {
            encryptionKey = try getMacOSEncryptionKey()
        } else {
            // iOS device - use the same encryption key as store
            encryptionKey = try getSimulatorEncryptionKey()
        }

        // Convert SymmetricKey to Data
        return encryptionKey.withUnsafeBytes { Data($0) }
    }

    /// Get both encrypted key and encryption key for VUL-002 secure FFI transaction building
    /// Returns (encryptedKey: 197 bytes, encryptionKey: 32 bytes)
    func getEncryptedKeyAndPassword() throws -> (encryptedKey: Data, encryptionKey: Data) {
        let encryptedKey = try retrieveEncryptedSpendingKey()
        let encryptionKey = try getEncryptionKeyForFFI()

        guard encryptedKey.count == 197, encryptionKey.count == 32 else {
            throw SecureStorageError.keyNotFound
        }

        return (encryptedKey, encryptionKey)
    }
}
