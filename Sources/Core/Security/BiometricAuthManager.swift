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

    /// FIX #1253: Whether app has been authenticated at least once this session
    /// Prevents showing wallet content before first successful auth
    @Published private(set) var hasAuthenticatedThisSession: Bool = false

    /// FIX #1253: Consecutive failed authentication attempts (for increasing delay)
    @Published private(set) var consecutiveFailures: Int = 0

    /// FIX #1253: Timestamp of last failed attempt (for enforcing retry delay)
    private var lastFailureTime: Date?

    /// Whether biometric auth is enabled in settings
    var isBiometricEnabled: Bool {
        UserDefaults.standard.bool(forKey: "useBiometricAuth")
    }

    /// FIX #1253: Retry delay based on consecutive failures (seconds)
    /// 0 failures = 0s, 1 = 2s, 2 = 5s, 3 = 10s, 4 = 20s, 5+ = 30s
    var currentRetryDelay: TimeInterval {
        switch consecutiveFailures {
        case 0: return 0
        case 1: return 2
        case 2: return 5
        case 3: return 10
        case 4: return 20
        default: return 30
        }
    }

    /// FIX #1253: Time remaining before retry is allowed
    var retryDelayRemaining: TimeInterval {
        guard let lastFailure = lastFailureTime else { return 0 }
        let elapsed = Date().timeIntervalSince(lastFailure)
        let remaining = currentRetryDelay - elapsed
        return max(0, remaining)
    }

    /// FIX #1253: Whether retry is currently allowed (delay has passed)
    var canRetry: Bool {
        return retryDelayRemaining <= 0
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
            unlockApp()  // Ensure isLocked=false when biometric disabled
            hasAuthenticatedThisSession = true  // FIX #1253
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
                        self?.hasAuthenticatedThisSession = true  // FIX #1253
                        self?.consecutiveFailures = 0  // FIX #1253: Reset on success
                        self?.lastFailureTime = nil
                    } else {
                        // FIX #1253: Track failure for retry delay
                        self?.consecutiveFailures += 1
                        self?.lastFailureTime = Date()
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
                        self?.hasAuthenticatedThisSession = true  // FIX #1253
                        self?.consecutiveFailures = 0  // FIX #1253: Reset on success
                        self?.lastFailureTime = nil
                    } else {
                        // FIX #1253: Track failure for retry delay
                        self?.consecutiveFailures += 1
                        self?.lastFailureTime = Date()
                    }
                    completion(success, authError)
                }
            }
        }
        else {
            // No biometric/passcode available - allow access
            hasAuthenticatedThisSession = true  // FIX #1253
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
    /// SECURITY VUL-005 FIX: Always requires authentication - biometric OR passcode
    /// If biometric is enabled: require Face ID/Touch ID
    /// If biometric is disabled: still require device passcode for security
    func authenticateForSend(amount: UInt64, completion: @escaping (Bool, Error?) -> Void) {
        let zcl = Double(amount) / 100_000_000.0
        let reason = String(format: "Authenticate to send %.8f ZCL", zcl)

        #if DEBUG
        // UAT mode: bypass send auth for test amounts (<= 0.0019 ZCL = 190000 zatoshis)
        // Enable via: defaults write com.zipherpunk.zipherx.mac uatModeEnabled -bool true
        if UserDefaults.standard.bool(forKey: "uatModeEnabled") && amount <= 190000 {
            print("🧪 [UAT] Send auth bypassed for \(amount) zatoshis (\(String(format: "%.4f", zcl)) ZCL)")
            completion(true, nil)
            return
        }
        #endif

        // Check if biometric auth is enabled in settings
        let biometricEnabled = UserDefaults.standard.bool(forKey: "useBiometricAuth")

        if biometricEnabled {
            // Biometric enabled - require Face ID/Touch ID (fresh, no cache)
            authenticateFresh(reason: reason, completion: completion)
        } else {
            // VUL-005 FIX: Even with biometric disabled, require device passcode
            // This ensures every transaction requires authentication
            authenticateWithPasscode(reason: reason, completion: completion)
        }
    }

    /// Authenticate using device passcode only (no biometrics)
    /// SECURITY: Required when biometric auth is disabled to ensure transactions are authorized
    private func authenticateWithPasscode(reason: String, completion: @escaping (Bool, Error?) -> Void) {
        let context = LAContext()
        context.localizedFallbackTitle = "" // Hide biometric fallback option
        context.localizedCancelTitle = "Cancel"

        var error: NSError?

        // Use deviceOwnerAuthentication which allows passcode
        if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) {
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
        } else {
            // No passcode set on device - this is a security risk
            // Block the operation with clear error
            print("🔐 VUL-005: No device passcode configured - blocking transaction")
            let securityError = NSError(
                domain: "BiometricAuthManager",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Device passcode required. Please set a passcode in iOS Settings."]
            )
            completion(false, securityError)
        }
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
        #if DEBUG
        // UAT mode: bypass app unlock for automated testing
        // Enable via: defaults write com.zipherpunk.zipherx.mac uatModeEnabled -bool true
        if UserDefaults.standard.bool(forKey: "uatModeEnabled") {
            print("🧪 [UAT] App unlock bypassed (uatModeEnabled=true)")
            unlockApp()
            completion(true, nil)
            return
        }
        #endif
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
        hasAuthenticatedThisSession = true  // FIX #1253
        consecutiveFailures = 0  // FIX #1253: Reset failures on unlock
        lastFailureTime = nil
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
