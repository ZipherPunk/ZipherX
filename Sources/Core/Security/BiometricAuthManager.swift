import Foundation
import LocalAuthentication

/// Biometric Authentication Manager
/// Provides Face ID / Touch ID authentication for sensitive operations
final class BiometricAuthManager {
    static let shared = BiometricAuthManager()

    // MARK: - Properties

    /// Time interval before requiring re-authentication (5 minutes)
    private let authTimeout: TimeInterval = 300

    /// Last successful authentication timestamp
    private var lastAuthTime: Date?

    /// Whether the app is currently locked
    @Published private(set) var isLocked: Bool = true

    private init() {}

    // MARK: - Biometric Capability Check

    /// Check if biometric authentication is available
    var isBiometricAvailable: Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    /// Get the type of biometric available (Face ID, Touch ID, or none)
    var biometricType: BiometricType {
        let context = LAContext()
        var error: NSError?

        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return .none
        }

        switch context.biometryType {
        case .faceID:
            return .faceID
        case .touchID:
            return .touchID
        case .opticID:
            return .opticID
        @unknown default:
            return .none
        }
    }

    // MARK: - Authentication

    /// Authenticate user with biometrics for a sensitive operation
    /// - Parameters:
    ///   - reason: The reason shown to the user
    ///   - completion: Callback with result (true if authenticated)
    func authenticate(reason: String, completion: @escaping (Bool, Error?) -> Void) {
        let context = LAContext()
        context.localizedFallbackTitle = "Use Passcode"
        context.localizedCancelTitle = "Cancel"

        // Check if we're within the auth timeout window
        if let lastAuth = lastAuthTime, Date().timeIntervalSince(lastAuth) < authTimeout {
            completion(true, nil)
            return
        }

        var error: NSError?

        // First try biometrics only
        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
            context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { [weak self] success, authError in
                DispatchQueue.main.async {
                    if success {
                        self?.lastAuthTime = Date()
                        self?.isLocked = false
                    }
                    completion(success, authError)
                }
            }
        }
        // Fall back to device passcode
        else if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) {
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { [weak self] success, authError in
                DispatchQueue.main.async {
                    if success {
                        self?.lastAuthTime = Date()
                        self?.isLocked = false
                    }
                    completion(success, authError)
                }
            }
        }
        else {
            completion(false, error)
        }
    }

    /// Authenticate with async/await
    @available(iOS 13.0, *)
    func authenticate(reason: String) async throws -> Bool {
        return try await withCheckedThrowingContinuation { continuation in
            authenticate(reason: reason) { success, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: success)
                }
            }
        }
    }

    /// Authenticate specifically for sending transactions
    func authenticateForSend(amount: UInt64, completion: @escaping (Bool, Error?) -> Void) {
        let zcl = Double(amount) / 100_000_000.0
        let reason = String(format: "Authenticate to send %.8f ZCL", zcl)
        authenticate(reason: reason, completion: completion)
    }

    /// Authenticate for viewing private key / seed
    func authenticateForKeyExport(completion: @escaping (Bool, Error?) -> Void) {
        authenticate(reason: "Authenticate to export private key", completion: completion)
    }

    /// Authenticate for app unlock
    func authenticateForAppUnlock(completion: @escaping (Bool, Error?) -> Void) {
        authenticate(reason: "Unlock ZipherX Wallet", completion: completion)
    }

    // MARK: - App Lock Management

    /// Lock the app (call when going to background)
    func lockApp() {
        isLocked = true
        lastAuthTime = nil
    }

    /// Check if re-authentication is needed
    var needsReauthentication: Bool {
        guard let lastAuth = lastAuthTime else { return true }
        return Date().timeIntervalSince(lastAuth) >= authTimeout
    }

    /// Reset authentication timeout
    func resetAuthTimeout() {
        lastAuthTime = Date()
    }
}

// MARK: - Biometric Type

enum BiometricType {
    case none
    case touchID
    case faceID
    case opticID

    var displayName: String {
        switch self {
        case .none:
            return "Passcode"
        case .touchID:
            return "Touch ID"
        case .faceID:
            return "Face ID"
        case .opticID:
            return "Optic ID"
        }
    }

    var systemImageName: String {
        switch self {
        case .none:
            return "lock.fill"
        case .touchID:
            return "touchid"
        case .faceID:
            return "faceid"
        case .opticID:
            return "opticid"
        }
    }
}
