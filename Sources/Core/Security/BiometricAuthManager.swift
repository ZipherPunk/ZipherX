import Foundation
import LocalAuthentication
import Combine

/// Biometric Authentication Manager
/// Provides Face ID / Touch ID authentication for sensitive operations
///
/// Face ID triggers ONLY at:
/// 1. App launch (if enabled)
/// 2. Send transaction confirmation
/// 3. After inactivity timeout (configurable, default 30 seconds)
final class BiometricAuthManager: ObservableObject {
    static let shared = BiometricAuthManager()

    // MARK: - Properties

    /// UserDefaults key for inactivity timeout
    private static let timeoutKey = "biometricInactivityTimeout"

    /// Default timeout: 30 seconds
    private static let defaultTimeout: TimeInterval = 30

    /// Time interval before requiring re-authentication (user configurable)
    var authTimeout: TimeInterval {
        let saved = UserDefaults.standard.double(forKey: Self.timeoutKey)
        return saved > 0 ? saved : Self.defaultTimeout
    }

    /// Set the inactivity timeout
    func setAuthTimeout(_ seconds: TimeInterval) {
        UserDefaults.standard.set(seconds, forKey: Self.timeoutKey)
    }

    /// Last user activity timestamp (for inactivity tracking)
    private var lastActivityTime: Date = Date()

    /// Last successful authentication timestamp
    private var lastAuthTime: Date?

    /// Whether the app is currently locked
    @Published private(set) var isLocked: Bool = true

    /// Whether biometric auth is enabled in settings
    var isBiometricEnabled: Bool {
        UserDefaults.standard.bool(forKey: "useBiometricAuth")
    }

    private init() {
        // Initialize with current time
        lastActivityTime = Date()
    }

    // MARK: - Activity Tracking

    /// Call this when user interacts with the app (touch, scroll, etc.)
    func recordUserActivity() {
        lastActivityTime = Date()
    }

    /// Check if inactivity timeout has been exceeded
    var isInactivityTimeoutExceeded: Bool {
        return Date().timeIntervalSince(lastActivityTime) >= authTimeout
    }

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
        case .none:
            return .none
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

    /// Authenticate user with biometrics - ALWAYS prompts for Face ID
    /// Use this for app unlock and inactivity timeout
    /// - Parameters:
    ///   - reason: The reason shown to the user
    ///   - completion: Callback with result (true if authenticated)
    func authenticate(reason: String, completion: @escaping (Bool, Error?) -> Void) {
        // Skip if biometric not enabled
        guard isBiometricEnabled else {
            completion(true, nil)
            return
        }

        let context = LAContext()
        context.localizedFallbackTitle = "Use Passcode"
        context.localizedCancelTitle = "Cancel"

        var error: NSError?

        // First try biometrics only
        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
            context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { [weak self] success, authError in
                DispatchQueue.main.async {
                    if success {
                        self?.lastAuthTime = Date()
                        self?.lastActivityTime = Date()
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
                        self?.lastActivityTime = Date()
                        self?.isLocked = false
                    }
                    completion(success, authError)
                }
            }
        }
        else {
            // No biometric/passcode available - allow access
            completion(true, nil)
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
    /// Requires Face ID if enabled in settings, otherwise skips biometric
    func authenticateForSend(amount: UInt64, completion: @escaping (Bool, Error?) -> Void) {
        // Check if biometric auth is enabled in settings
        let biometricEnabled = UserDefaults.standard.bool(forKey: "useBiometricAuth")

        guard biometricEnabled else {
            // Biometric disabled in settings - skip authentication
            completion(true, nil)
            return
        }

        let zcl = Double(amount) / 100_000_000.0
        let reason = String(format: "Authenticate to send %.8f ZCL", zcl)
        authenticateFresh(reason: reason, completion: completion)
    }

    /// Authenticate with FRESH biometrics - ALWAYS prompts, no cache
    /// Use for high-security operations like sending transactions
    private func authenticateFresh(reason: String, completion: @escaping (Bool, Error?) -> Void) {
        let context = LAContext()
        context.localizedFallbackTitle = "Use Passcode"
        context.localizedCancelTitle = "Cancel"

        var error: NSError?

        // First try biometrics only - always fresh, no timeout check
        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
            context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { [weak self] success, authError in
                DispatchQueue.main.async {
                    if success {
                        self?.lastAuthTime = Date()
                        self?.lastActivityTime = Date()
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
                        self?.lastActivityTime = Date()
                        self?.isLocked = false
                    }
                    completion(success, authError)
                }
            }
        }
        else {
            // No biometric available - block the operation for security
            completion(false, error)
        }
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

    /// Lock the app (call when going to background or after inactivity)
    func lockApp() {
        isLocked = true
        lastAuthTime = nil
    }

    /// Unlock the app (call after successful authentication)
    func unlockApp() {
        isLocked = false
        lastAuthTime = Date()
        lastActivityTime = Date()
    }

    /// Check if re-authentication is needed (inactivity timeout)
    var needsReauthentication: Bool {
        guard isBiometricEnabled else { return false }
        return isInactivityTimeoutExceeded
    }

    /// Reset activity timeout (call on any user interaction)
    func resetActivityTimeout() {
        lastActivityTime = Date()
    }

    /// Check if app should be locked and prompt for authentication if needed
    /// Call this when app becomes active or user performs sensitive action
    func checkAndAuthenticate(completion: @escaping (Bool) -> Void) {
        guard isBiometricEnabled else {
            completion(true)
            return
        }

        // If inactivity timeout exceeded, require authentication
        if isInactivityTimeoutExceeded {
            lockApp()
            authenticateForAppUnlock { success, _ in
                completion(success)
            }
        } else {
            completion(true)
        }
    }

    /// Available timeout options (in seconds)
    static let timeoutOptions: [(label: String, seconds: TimeInterval)] = [
        ("15 seconds", 15),
        ("30 seconds", 30),
        ("1 minute", 60),
        ("2 minutes", 120),
        ("5 minutes", 300),
        ("Never", 0)
    ]

    /// Get current timeout as display string
    var timeoutDisplayString: String {
        let current = authTimeout
        if current == 0 {
            return "Never"
        }
        for option in Self.timeoutOptions {
            if option.seconds == current {
                return option.label
            }
        }
        return "\(Int(current)) seconds"
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
