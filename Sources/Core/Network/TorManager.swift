//
//  TorManager.swift
//  ZipherX
//
//  Created by ZipherX Team on 2025-12-08.
//  Embedded Tor support via Arti (Rust) for maximum privacy
//
//  "Privacy is necessary for an open society in the electronic age."
//  - A Cypherpunk's Manifesto
//

import Foundation
import Network

// MARK: - Tor Mode Enum

/// Tor operating modes for ZipherX
public enum TorMode: String, CaseIterable {
    case disabled = "disabled"      // Direct connections (fastest)
    case enabled = "enabled"        // Embedded Tor via Arti (maximum privacy)

    var displayName: String {
        switch self {
        case .disabled: return "Direct"
        case .enabled: return "Tor Enabled"
        }
    }

    var description: String {
        switch self {
        case .disabled:
            return "Connect directly to peers. Fastest but your IP is visible to nodes."
        case .enabled:
            return "Route all traffic through Tor. Maximum privacy, slower startup."
        }
    }
}

// MARK: - Tor Connection State

public enum TorConnectionState: Equatable {
    case disconnected
    case connecting
    case bootstrapping(progress: Int)  // 0-100%
    case connected
    case error(String)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    var displayText: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting..."
        case .bootstrapping(let progress): return "Bootstrapping \(progress)%"
        case .connected: return "Connected"
        case .error(let msg): return "Error: \(msg)"
        }
    }

    /// Initialize from Arti FFI state code
    init(artiState: UInt8) {
        switch artiState {
        case 0: self = .disconnected
        case 1: self = .connecting
        case 2: self = .bootstrapping(progress: 50)  // Will be updated by progress
        case 3: self = .connected
        case 4: self = .error("Unknown error")
        default: self = .disconnected
        }
    }
}

// MARK: - Tor Manager

/// Manages embedded Tor connectivity for ZipherX via Arti (Rust)
/// Routes all network traffic through Tor for maximum privacy
@MainActor
public final class TorManager: ObservableObject {

    // MARK: - Singleton

    public static let shared = TorManager()

    // MARK: - Published Properties

    @Published public private(set) var connectionState: TorConnectionState = .disconnected
    @Published public private(set) var currentCircuitId: String?
    @Published public private(set) var exitNodeCountry: String?

    /// IP addresses for verification - shows user their IP before and after Tor
    @Published public private(set) var realIP: String?       // User's real IP (before Tor)
    @Published public private(set) var torIP: String?        // Exit node IP (after Tor connected)

    /// Current Tor mode (persisted)
    @Published public var mode: TorMode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: "torMode")
            Task {
                await handleModeChange(from: oldValue, to: mode)
            }
        }
    }

    // MARK: - Configuration

    /// SOCKS5 proxy port (from Arti)
    public private(set) var socksPort: UInt16 = 0

    /// Proxy host (always localhost)
    public let proxyHost: String = "127.0.0.1"

    // MARK: - Internal State

    private var isStartingTor = false
    private var statusPollingTask: Task<Void, Never>?

    /// Circuit isolation counter (different value = different circuit via SOCKS auth)
    private var circuitIsolationCounter: UInt64 = 0

    /// Cache for SOCKS proxy ready state (prevents repeated connection tests)
    private var socksProxyVerified = false

    /// FIX #1401: Strict privacy mode — NEVER bypass Tor for any operation (slower but fully private).
    /// When true, bypassTorForMassiveOperation() refuses to bypass, keeping all traffic through Tor.
    @Published public var strictPrivacyMode: Bool {
        didSet {
            UserDefaults.standard.set(strictPrivacyMode, forKey: "torStrictPrivacyMode")
            // VUL-NET-005: Strict privacy = Tor + Hidden Service (onion)
            // Enabling strict mode MUST also enable Hidden Service for chat/P2P privacy
            if strictPrivacyMode {
                Task { @MainActor in
                    if !HiddenServiceManager.shared.isEnabled {
                        HiddenServiceManager.shared.isEnabled = true
                        print("🧅 VUL-NET-005: Strict privacy enabled — Hidden Service auto-enabled")
                    }
                }
            }
        }
    }

    // MARK: - Persistent Onion Address (FIX #169)

    /// Keychain key for storing the hidden service keypair
    private let hsKeypairKeychainKey = "com.zipherx.hidden-service-keypair"

    /// The persistent .onion address (derived from stored keypair)
    @Published public private(set) var persistentOnionAddress: String?

    /// Lock to prevent multiple concurrent waitForSocksProxyReady() calls
    private var isWaitingForSocksProxy = false
    private let socksProxyLock = NSLock()
    /// FIX #672: Track concurrent waiters to detect excessive calls
    private var socksProxyWaiterCount = 0

    /// Timestamp when SOCKS proxy became connected (for .onion circuit warmup delay)
    private var connectedSinceTimestamp: Date?

    /// Minimum delay after SOCKS proxy is ready before .onion circuits are likely established
    /// Hidden services require rendezvous circuits which take additional time to set up
    /// FIX #331: Increased from 10s to 30s for more reliable .onion circuit establishment
    /// Tor documentation suggests 30-60 seconds for rendezvous point establishment
    private let onionCircuitWarmupSeconds: TimeInterval = 30.0

    // MARK: - Initialization

    private init() {
        // Load persisted mode
        // FIX #1443: Tor enabled by default for privacy. User can disable in Settings.
        if let savedMode = UserDefaults.standard.string(forKey: "torMode"),
           let torMode = TorMode(rawValue: savedMode) {
            self.mode = torMode
        } else {
            self.mode = .enabled
        }
        // FIX #1401 / VUL-NET-005: Strict privacy defaults to TRUE (user can opt-out)
        if UserDefaults.standard.object(forKey: "torStrictPrivacyMode") != nil {
            self.strictPrivacyMode = UserDefaults.standard.bool(forKey: "torStrictPrivacyMode")
        } else {
            self.strictPrivacyMode = true
        }

        // VUL-NET-005: Strict privacy mode = Tor + Hidden Service MUST both be enabled.
        // On fresh install (no UserDefaults), ensure Hidden Service defaults to enabled.
        if self.strictPrivacyMode {
            let hsExplicitlySet = UserDefaults.standard.object(forKey: "hiddenServiceEnabled") != nil
            if !hsExplicitlySet {
                UserDefaults.standard.set(true, forKey: "hiddenServiceEnabled")
                print("🧅 VUL-NET-005: Strict privacy mode — enabling Hidden Service by default")
            }
        }

        // Check if Arti is available
        let isAvailable = zipherx_tor_is_available()
        print("🧅 TorManager initialized, mode: \(mode.displayName), Arti available: \(isAvailable)")

        // FIX #169: Load persistent keypair from Keychain if it exists
        // This ensures the .onion address is consistent across app launches
        if let keypairData = loadKeypairFromKeychain() {
            if setKeypairInFFI(keypairData) {
                persistentOnionAddress = getOnionAddressFromFFI()
                print("🧅 FIX #169: Loaded persistent keypair - .onion ready")
            }
        } else {
            print("🧅 FIX #169: No persistent keypair - will generate new one when hidden service starts")
        }
    }

    // MARK: - Public API

    /// Start Tor connection (if mode requires it)
    public func start() async {
        // FIX #250: Add diagnostic logging for real iOS debugging
        debugLog(.network, "🧅 TorManager.start() called - mode: \(mode)")

        guard mode == .enabled else {
            debugLog(.network, "🧅 Tor disabled (mode=\(mode)), skipping start")
            print("🧅 Tor disabled, skipping start")
            return
        }

        debugLog(.network, "🧅 Tor enabled, starting Arti...")
        await startArti()
    }

    /// Stop Tor connection
    public func stop() async {
        print("🧅 Stopping Tor...")
        await stopArti()
    }

    /// Request new identity (new circuit)
    /// Use before broadcasting transactions for maximum privacy
    public func requestNewIdentity() async -> Bool {
        guard mode == .enabled else { return false }

        // Use SOCKS auth isolation for new circuit
        circuitIsolationCounter += 1
        print("🧅 New circuit isolation ID: \(circuitIsolationCounter)")

        // Request new identity from Arti
        if connectionState.isConnected {
            let result = zipherx_tor_new_identity()
            return result == 0
        }

        return true
    }

    // MARK: - FIX #289: App Lifecycle Coordination

    /// Track when app went to background (for stale detection)
    private var backgroundTimestamp: Date?

    /// FIX #289: Put Tor into dormant mode when app goes to background
    /// This stops polling and marks circuits as potentially stale
    public func goDormantOnBackground() {
        guard mode == .enabled else {
            print("🧅 FIX #289: Tor disabled, no dormant action needed")
            return
        }

        print("🧅 FIX #289: App going to background - Tor entering dormant mode")
        backgroundTimestamp = Date()

        // Stop status polling to save battery
        statusPollingTask?.cancel()
        statusPollingTask = nil

        // Mark SOCKS proxy as potentially stale (will need re-verification)
        socksProxyVerified = false
        connectedSinceTimestamp = nil  // Reset .onion warmup timer

        print("🧅 FIX #289: Tor dormant - circuits may become stale")
    }

    /// FIX #289: Wake Tor and verify connectivity when app comes to foreground
    public func ensureRunningOnForeground() async {
        guard mode == .enabled else {
            print("🧅 FIX #289: Tor disabled, no foreground action needed")
            return
        }

        print("🧅 FIX #289: App coming to foreground - checking Tor status")

        // Calculate time in background
        let backgroundDuration: TimeInterval
        if let bgTime = backgroundTimestamp {
            backgroundDuration = Date().timeIntervalSince(bgTime)
            print("🧅 FIX #289: Was in background for \(Int(backgroundDuration))s")
        } else {
            backgroundDuration = 0
        }
        backgroundTimestamp = nil

        // If in background > 30s, circuits are likely stale
        let circuitsMayBeStale = backgroundDuration > 30

        // Check if Tor was in connected state
        guard case .connected = connectionState else {
            // Tor wasn't connected - try to restart
            print("🧅 FIX #289: Tor was not connected, attempting restart")
            await startArti()
            return
        }

        // Verify SOCKS proxy is still working
        let proxyWorking = await isSocksProxyReady()

        if !proxyWorking {
            // SOCKS proxy dead - restart Tor
            print("🧅 FIX #289: SOCKS proxy not responding - restarting Tor")
            await stopArti()
            await startArti()
            return
        }

        // Proxy working - restore connected state
        print("🧅 FIX #289: SOCKS proxy verified, restoring connected state")
        socksProxyVerified = true
        connectedSinceTimestamp = Date()

        // If circuits may be stale, request new identity
        if circuitsMayBeStale {
            print("🧅 FIX #289: Circuits may be stale after \(Int(backgroundDuration))s - requesting new identity")
            _ = await requestNewIdentity()
        }

        // Restart status polling
        startStatusPolling()

        // Notify HiddenServiceManager to check hidden service status
        Task {
            await HiddenServiceManager.shared.onTorConnectionStateChanged(isConnected: true)
        }

        print("🧅 FIX #289: Tor fully restored from dormant mode")
    }

    // MARK: - FIX #142: Temporary Tor Bypass for Massive Operations

    /// Track if Tor was bypassed for a massive operation
    private var wasTorEnabledBeforeBypass = false
    // FIX #1401: Published so BalanceView can show privacy warning during bypass
    @Published public private(set) var isBypassActive = false

    /// Temporarily disable Tor for massive operations (header sync, full rescan)
    /// Returns true if Tor was disabled (caller should call restoreTorAfterBypass when done)
    public func bypassTorForMassiveOperation() async -> Bool {
        guard mode == .enabled && !isBypassActive else {
            return false
        }

        // FIX #1401: Strict privacy mode — refuse to bypass Tor
        if strictPrivacyMode {
            print("🧅 FIX #1401: Tor bypass REFUSED — strict privacy mode enabled (sync will be slower)")
            return false
        }

        print("🧅 FIX #142: Temporarily disabling Tor for faster sync...")
        wasTorEnabledBeforeBypass = true
        isBypassActive = true

        // Stop Tor and set mode to disabled
        await stopArti()

        // Don't persist the mode change - just change in memory
        // We'll restore it after the operation
        await MainActor.run {
            self.connectionState = .disconnected
        }

        // Disconnect existing peers so they reconnect without Tor
        await NetworkManager.shared.disconnectAllPeers()

        print("🧅 FIX #142: Tor bypassed - using direct connections for faster sync")
        return true
    }

    /// Restore Tor after massive operation completes
    public func restoreTorAfterBypass() async {
        guard wasTorEnabledBeforeBypass && isBypassActive else {
            return
        }

        print("🧅 FIX #142: Restoring Tor after sync complete...")
        isBypassActive = false
        wasTorEnabledBeforeBypass = false

        // Disconnect direct peers before switching back to Tor
        await NetworkManager.shared.disconnectAllPeers()

        // Restart Tor
        await startArti()

        print("🧅 FIX #142: Tor restored - maximum privacy mode active")
    }

    /// Check if Tor bypass is currently active
    public var isTorBypassed: Bool {
        return isBypassActive
    }

    // MARK: - FIX #210: Temporary Tor Bypass for Single Transaction

    /// Temporarily bypass Tor when it's enabled but not running
    /// Use this when user wants to send TX despite Tor being unavailable
    /// Does NOT change the persisted mode setting - just allows direct connections
    public func temporarilyBypassTor() async {
        guard mode == .enabled else {
            print("🧅 FIX #210: Tor not enabled, no bypass needed")
            return
        }

        print("🧅 FIX #210: Temporarily bypassing Tor for transaction broadcast")
        print("🧅 FIX #210: User's IP will be visible to peers for this transaction")

        // Mark bypass active so peers connect directly
        isBypassActive = true
        wasTorEnabledBeforeBypass = true

        // Disconnect existing peers (they're waiting for SOCKS)
        await NetworkManager.shared.disconnectAllPeers()

        // Set connection state to indicate bypass mode
        await MainActor.run {
            self.connectionState = .disconnected
        }

        print("🧅 FIX #210: Tor bypassed - peers will reconnect directly")
    }

    /// Restore Tor after single transaction completes
    /// Called automatically by SendView after TX broadcast
    public func restoreAfterSingleTxBypass() async {
        guard wasTorEnabledBeforeBypass && isBypassActive else {
            return
        }

        print("🧅 FIX #210: Transaction complete - attempting to restore Tor")
        isBypassActive = false
        wasTorEnabledBeforeBypass = false

        // Try to restart Tor
        await startArti()

        // If Tor fails to start, that's okay - it will show in UI
        // User can manually restart from Settings
    }

    /// Check if Tor should be used but isn't available
    /// Returns true if mode is enabled but Tor is not connected and SOCKS is not available
    public var isTorEnabledButUnavailable: Bool {
        guard mode == .enabled else { return false }
        if isBypassActive { return false }  // Already bypassed
        if connectionState.isConnected { return false }  // Tor is running
        return true
    }

    /// Get URLSession configured for Tor proxy
    public func getTorURLSession(isolate: Bool = false) -> URLSession {
        guard mode == .enabled, connectionState.isConnected, socksPort > 0 else {
            return URLSession.shared
        }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60  // Tor is slower
        config.timeoutIntervalForResource = 120

        // SOCKS5 proxy configuration
        var proxyDict: [AnyHashable: Any] = [
            kCFStreamPropertySOCKSProxyHost as String: proxyHost,
            kCFStreamPropertySOCKSProxyPort as String: socksPort,
            kCFStreamPropertySOCKSVersion as String: kCFStreamSocketSOCKSVersion5
        ]

        // Circuit isolation via SOCKS authentication
        if isolate {
            circuitIsolationCounter += 1
            let username = "zipherx-\(circuitIsolationCounter)"
            let password = "isolate-\(UUID().uuidString.prefix(8))"
            proxyDict[kCFStreamPropertySOCKSUser as String] = username
            proxyDict[kCFStreamPropertySOCKSPassword as String] = password
            print("🧅 Isolated circuit: \(username)")
        }

        config.connectionProxyDictionary = proxyDict

        return URLSession(configuration: config)
    }

    /// Get NWParameters configured for Tor SOCKS5 proxy
    /// Note: Full SOCKS5 proxy support requires iOS 17+ / macOS 14+
    /// For older versions, P2P connections go direct (Tor only for HTTP)
    public func getTorConnectionParameters(isolate: Bool = false) -> NWParameters {
        guard mode == .enabled, connectionState.isConnected else {
            return NWParameters.tcp
        }

        // If isolating, increment counter for different SOCKS auth
        if isolate {
            circuitIsolationCounter += 1
        }

        // Note: Full NWConnection SOCKS5 proxy requires iOS 17+ / macOS 14+
        // For now, return TCP parameters - P2P will connect directly
        // This is a limitation of Network.framework on older OS versions
        // HTTP traffic (InsightAPI) still goes through Tor via URLSession
        print("🧅 Note: P2P connections are direct. HTTP traffic routes through Tor.")
        return NWParameters.tcp
    }

    /// Make HTTP GET request through Tor (uses Arti directly)
    /// Returns response body as string, or nil on error
    public func httpGet(url: String) async -> String? {
        guard mode == .enabled, connectionState.isConnected else {
            print("🧅 httpGet: Tor not connected")
            return nil
        }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = url.withCString { urlPtr -> String? in
                    guard let responsePtr = zipherx_tor_http_get(urlPtr) else {
                        return nil
                    }
                    let response = String(cString: responsePtr)
                    zipherx_tor_free_string(responsePtr)
                    return response
                }
                continuation.resume(returning: result)
            }
        }
    }

    /// Check if Tor is available and connected
    public var isAvailable: Bool {
        mode == .enabled && connectionState.isConnected
    }

    /// Check if .onion circuits are likely ready (connected for warmup period)
    /// .onion addresses require rendezvous circuits which take time to establish
    /// Regular IPv4 connections via SOCKS work immediately; .onion needs ~10s warmup
    public var isOnionCircuitsReady: Bool {
        guard connectionState.isConnected, let connectedSince = connectedSinceTimestamp else {
            return false
        }
        let elapsed = Date().timeIntervalSince(connectedSince)
        return elapsed >= onionCircuitWarmupSeconds
    }

    /// Time remaining until .onion circuits are ready (for UI)
    public var onionCircuitWarmupRemaining: TimeInterval {
        guard connectionState.isConnected, let connectedSince = connectedSinceTimestamp else {
            return onionCircuitWarmupSeconds
        }
        let elapsed = Date().timeIntervalSince(connectedSince)
        return max(0, onionCircuitWarmupSeconds - elapsed)
    }

    /// Check if Arti (Rust Tor) is compiled in
    public var isArtiAvailable: Bool {
        zipherx_tor_is_available()
    }

    // MARK: - SOCKS5 Health Monitoring (FIX for Tor Proxy Crashes)

    /// Track last SOCKS5 health check time
    private var lastSOCKS5HealthCheck: Date?
    private let SOCKS5_HEALTH_CHECK_INTERVAL: TimeInterval = 15.0  // Check every 15 seconds

    /// Track consecutive SOCKS5 failures for detection
    private var consecutiveSOCKS5Failures: Int = 0
    private let SOCKS5_FAILURE_THRESHOLD = 2  // Restart Tor after 2 consecutive failures

    /// Perform a quick SOCKS5 health check (non-blocking, fast)
    /// Returns true if SOCKS5 proxy is accepting connections
    public func checkSOCKS5Health() async -> Bool {
        print("🔍 [SOCKS5] checkSOCKS5Health() called - mode: \(mode.rawValue), socksPort: \(socksPort)")

        guard mode == .enabled, socksPort > 0 else {
            print("🔍 [SOCKS5] Skipped - Tor not enabled or socksPort=0")
            return false  // Tor not enabled or not started
        }

        // Quick TCP connection test to SOCKS5 proxy
        let isHealthy = await testSOCKS5Connection(timeout: 1.0)  // 1 second timeout

        if isHealthy {
            consecutiveSOCKS5Failures = 0
            lastSOCKS5HealthCheck = Date()
            print("🔍 [SOCKS5] Health check PASSED ✅")
            return true
        } else {
            consecutiveSOCKS5Failures += 1
            print("⚠️ SOCKS5 health check FAILED (consecutive failures: \(consecutiveSOCKS5Failures))")

            // If threshold exceeded, restart Tor
            if consecutiveSOCKS5Failures >= SOCKS5_FAILURE_THRESHOLD {
                print("🚨 CRITICAL: SOCKS5 proxy unresponsive - restarting Tor...")
                await restartTor()
                consecutiveSOCKS5Failures = 0  // Reset after restart
            }

            return false
        }
    }

    /// Test SOCKS5 connection with timeout
    private func testSOCKS5Connection(timeout: TimeInterval) async -> Bool {
        print("🔍 [SOCKS5] Testing connection to 127.0.0.1:\(socksPort) (timeout: \(timeout)s)")

        return await withCheckedContinuation { continuation in
            let endpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host("127.0.0.1"),
                port: NWEndpoint.Port(integerLiteral: socksPort)
            )
            let connection = NWConnection(to: endpoint, using: .tcp)

            var hasResumed = false
            let queue = DispatchQueue(label: "socks-health-\(UUID().uuidString.prefix(8))")

            connection.stateUpdateHandler = { state in
                guard !hasResumed else { return }
                print("🔍 [SOCKS5] State update: \(state)")
                switch state {
                case .ready:
                    print("🔍 [SOCKS5] Connection READY ✅")
                    hasResumed = true
                    connection.cancel()
                    continuation.resume(returning: true)
                case .failed(let error):
                    print("🔍 [SOCKS5] Connection FAILED: \(error)")
                    hasResumed = true
                    connection.cancel()
                    continuation.resume(returning: false)
                case .cancelled:
                    print("🔍 [SOCKS5] Connection CANCELLED")
                    hasResumed = true
                    connection.cancel()
                    continuation.resume(returning: false)
                default:
                    break
                }
            }

            connection.start(queue: queue)
            print("🔍 [SOCKS5] Connection started, waiting for state...")

            // Timeout
            queue.asyncAfter(deadline: .now() + timeout) {
                guard !hasResumed else { return }
                print("🔍 [SOCKS5] Connection TIMEOUT after \(timeout)s")
                hasResumed = true
                connection.cancel()
                continuation.resume(returning: false)
            }
        }
    }

    /// FIX #1419: Get exit circuit failure count from Rust FFI
    public func getExitCircuitFailures() -> UInt32 {
        return zipherx_tor_get_exit_failures()
    }

    /// FIX #1419: Reset exit circuit failure counter (after successful restart)
    public func resetExitCircuitFailures() {
        zipherx_tor_reset_exit_failures()
    }

    /// Restart Tor completely (stop + start) with circuit readiness wait
    /// FIX #1419: clearCache parameter forces fresh consensus download
    public func restartTor(clearCache: Bool = false) async {
        if clearCache {
            print("🧹 FIX #1419: Restarting Tor WITH cache clear (force fresh consensus)...")
        } else {
            print("🔄 Restarting Tor due to SOCKS5 failure or all-peers-dead event...")
        }

        // Stop Tor
        await stopArti()

        // FIX #1419: Clear cache if requested (stale consensus causes exit circuit failures)
        if clearCache {
            let result = zipherx_tor_clear_cache()
            if result == 0 {
                print("✅ FIX #1419: Tor cache cleared — will download fresh consensus")
            } else {
                print("⚠️ FIX #1419: Tor cache clear returned error (continuing anyway)")
            }
            // Also reset the exit failure counter
            zipherx_tor_reset_exit_failures()
        }

        // Wait for cleanup
        try? await Task.sleep(nanoseconds: 1_000_000_000)  // 1 second

        // Start Tor
        await startArti()

        // Wait for circuits to be ready
        let maxWait = 30  // 30 seconds max
        var attempts = 0
        while !isOnionCircuitsReady && attempts < maxWait {
            try? await Task.sleep(nanoseconds: 1_000_000_000)  // 1 second
            attempts += 1
        }

        print("✅ Tor restarted, circuits ready: \(isOnionCircuitsReady), clearCache: \(clearCache)")
    }

    // MARK: - Mode Change Handling

    private func handleModeChange(from oldMode: TorMode, to newMode: TorMode) async {
        print("🧅 Mode change: \(oldMode.displayName) → \(newMode.displayName)")

        // Stop old connection
        if oldMode == .enabled {
            await stopArti()
        }

        // Start new mode
        if newMode == .enabled {
            await start()
        } else {
            connectionState = .disconnected

            // FIX: Do NOT automatically modify zclassic.conf
            // User must manually configure proxy settings
            #if os(macOS)
            print("🧅 Tor disabled - user can remove proxy from zclassic.conf manually if needed")
            #endif
        }
    }

    // MARK: - Arti (Rust Tor) Integration

    private func startArti() async {
        // FIX #250: Enhanced diagnostics for real iOS debugging
        debugLog(.network, "🧅 startArti() called - isStartingTor: \(isStartingTor)")

        guard !isStartingTor else {
            debugLog(.network, "🧅 Tor already starting, skipping...")
            print("🧅 Tor already starting...")
            return
        }

        // Check if Arti is available
        let artiAvailable = zipherx_tor_is_available()
        debugLog(.network, "🧅 zipherx_tor_is_available() = \(artiAvailable)")

        guard artiAvailable else {
            debugLog(.network, "🧅 ERROR: Arti not available in this build!")
            connectionState = .error("Arti not available in this build")
            return
        }

        isStartingTor = true
        connectionState = .connecting

        debugLog(.network, "🧅 Starting Arti (embedded Tor)...")
        print("🧅 Starting Arti (embedded Tor)...")

        // Start Arti in background thread
        debugLog(.network, "🧅 Calling zipherx_tor_start()...")
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<Int32, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = zipherx_tor_start()
                continuation.resume(returning: result)
            }
        }

        debugLog(.network, "🧅 zipherx_tor_start() returned: \(result)")

        if result != 0 {
            // Get error message
            if let errorPtr = zipherx_tor_get_error() {
                let errorMsg = String(cString: errorPtr)
                zipherx_tor_free_string(errorPtr)
                debugLog(.network, "🧅 ERROR: Tor start failed: \(errorMsg)")
                connectionState = .error(errorMsg)
            } else {
                debugLog(.network, "🧅 ERROR: Tor start failed (no error message)")
                connectionState = .error("Failed to start Tor")
            }
            isStartingTor = false
            return
        }

        debugLog(.network, "🧅 Tor started successfully, starting status polling...")
        // Start polling for status updates
        startStatusPolling()
    }

    private func stopArti() async {
        print("🧅 Stopping Arti...")

        // Stop status polling
        statusPollingTask?.cancel()
        statusPollingTask = nil

        // Stop Arti
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                _ = zipherx_tor_stop()
                continuation.resume()
            }
        }

        connectionState = .disconnected
        socksPort = 0
        isStartingTor = false
        connectedSinceTimestamp = nil  // Reset .onion circuit warmup timer
        resetSocksProxyState()  // Clear cached proxy state

        // Notify HiddenServiceManager that Tor is disconnected
        Task {
            await HiddenServiceManager.shared.onTorConnectionStateChanged(isConnected: false)
        }
    }

    private func startStatusPolling() {
        statusPollingTask?.cancel()

        statusPollingTask = Task {
            while !Task.isCancelled {
                await updateStatus()

                // Stop polling if connected or error
                if case .connected = connectionState {
                    isStartingTor = false
                    break
                }
                if case .error = connectionState {
                    isStartingTor = false
                    break
                }

                try? await Task.sleep(nanoseconds: 500_000_000)  // 500ms
            }
        }
    }

    private func updateStatus() async {
        let state = zipherx_tor_get_state()
        let progress = zipherx_tor_get_progress()
        let port = zipherx_tor_get_socks_port()

        await MainActor.run {
            // Update connection state based on Arti state
            switch state {
            case 0:  // Disconnected
                connectionState = .disconnected
            case 1:  // Connecting
                connectionState = .connecting
            case 2:  // Bootstrapping
                connectionState = .bootstrapping(progress: Int(progress))
            case 3:  // Connected (Arti reports connected)
                socksPort = port
                print("🧅 Arti reports connected, SOCKS port: \(port)")

                // Verify SOCKS proxy is actually accepting connections
                // This is done in a separate task to not block status updates
                if !connectionState.isConnected {
                    connectionState = .bootstrapping(progress: 99)
                    Task {
                        let proxyReady = await self.waitForSocksProxyReady(maxWait: 30)
                        await MainActor.run {
                            if proxyReady {
                                self.connectionState = .connected
                                self.connectedSinceTimestamp = Date()
                                print("🧅 Tor fully connected! SOCKS proxy verified on port \(port)")
                                print("🧅 .onion circuits will be ready in \(self.onionCircuitWarmupSeconds)s")

                                // FIX: Do NOT automatically modify zclassic.conf
                                // User must manually configure proxy settings or explicitly save from Settings
                                // The app should NEVER modify user's config files without explicit action
                                #if os(macOS)
                                print("🧅 Tor proxy available at \(self.proxyHost):\(port) - user can configure zclassic.conf manually if needed")
                                #endif

                                // Notify HiddenServiceManager that Tor is now connected
                                // This ensures hidden service starts automatically if enabled
                                Task {
                                    await HiddenServiceManager.shared.onTorConnectionStateChanged(isConnected: true)
                                }
                            } else {
                                self.connectionState = .error("SOCKS proxy not responding on port \(port)")
                            }
                        }
                    }
                }
            case 4:  // Error
                if let errorPtr = zipherx_tor_get_error() {
                    let errorMsg = String(cString: errorPtr)
                    zipherx_tor_free_string(errorPtr)
                    connectionState = .error(errorMsg)
                } else {
                    connectionState = .error("Unknown error")
                }
            default:
                break
            }
        }
    }

    // MARK: - Helper Functions

    private func getTorDataDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("ZipherX/Tor", isDirectory: true)
    }

    // MARK: - IP Address Verification

    /// Fetch public IP address using direct connection (bypassing Tor)
    /// Call this BEFORE enabling Tor to show user their real IP
    public func fetchRealIP() async {
        // Use a simple IP check service - direct connection
        let session = URLSession.shared
        guard let url = URL(string: "https://api.ipify.org") else { return }

        do {
            let (data, _) = try await session.data(from: url)
            if let ip = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
                await MainActor.run {
                    self.realIP = ip
                    print("🧅 Real IP (before Tor): \(ip)")
                }
            }
        } catch {
            print("🧅 Failed to fetch real IP: \(error.localizedDescription)")
        }
    }

    /// Fetch public IP address through Tor
    /// Call this AFTER Tor is connected to verify exit node IP
    public func fetchTorIP() async {
        guard connectionState.isConnected else {
            print("🧅 Cannot fetch Tor IP - not connected")
            return
        }

        // Use Tor-configured URLSession
        let session = getTorURLSession(isolate: false)
        guard let url = URL(string: "https://api.ipify.org") else { return }

        do {
            let (data, _) = try await session.data(from: url)
            if let ip = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
                await MainActor.run {
                    self.torIP = ip
                    print("🧅 Tor exit IP (after Tor): \(ip)")
                }
            }
        } catch {
            print("🧅 Failed to fetch Tor IP: \(error.localizedDescription)")
        }
    }

    /// Verify Tor is working by comparing IPs
    /// Returns true if IPs are different (Tor is hiding your real IP)
    public func verifyTorWorking() -> Bool {
        guard let real = realIP, let tor = torIP else { return false }
        return real != tor
    }

    /// Test if the SOCKS5 proxy is actually accepting connections
    /// Returns true if we can establish a TCP connection to the proxy port
    /// OPTIMIZED: Returns cached result if already verified to prevent socket leak
    public func isSocksProxyReady() async -> Bool {
        guard socksPort > 0 else { return false }

        // OPTIMIZATION: Return cached state if already verified
        if socksProxyVerified {
            return true
        }

        return await withCheckedContinuation { continuation in
            let endpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host("127.0.0.1"),
                port: NWEndpoint.Port(integerLiteral: socksPort)
            )
            let connection = NWConnection(to: endpoint, using: .tcp)

            var hasResumed = false
            let queue = DispatchQueue(label: "socks-test-\(UUID().uuidString.prefix(8))")

            connection.stateUpdateHandler = { [weak self] state in
                guard !hasResumed else { return }
                switch state {
                case .ready:
                    hasResumed = true
                    // Cache success state
                    Task { @MainActor in
                        self?.socksProxyVerified = true
                    }
                    connection.cancel()
                    continuation.resume(returning: true)
                case .failed, .cancelled:
                    hasResumed = true
                    connection.cancel()  // Ensure cleanup
                    continuation.resume(returning: false)
                default:
                    break
                }
            }

            connection.start(queue: queue)

            // Timeout after 2 seconds
            queue.asyncAfter(deadline: .now() + 2) {
                guard !hasResumed else { return }
                hasResumed = true
                connection.cancel()  // Ensure cleanup on timeout
                continuation.resume(returning: false)
            }
        }
    }

    /// Wait for SOCKS proxy to become ready (up to maxWait seconds)
    /// Returns true if proxy became ready within the timeout
    /// OPTIMIZED: Prevents multiple concurrent waits and caches result
    /// FIX #672: Added concurrency guard to prevent excessive concurrent calls
    public func waitForSocksProxyReady(maxWait: TimeInterval = 30) async -> Bool {
        // OPTIMIZATION: Return immediately if already verified
        if socksProxyVerified {
            return true
        }

        // FIX #672: Track concurrent waiters and detect excessive calls
        socksProxyLock.lock()
        let waiterId = UUID().uuidString.prefix(8)
        let concurrentWaiters = socksProxyWaiterCount
        socksProxyWaiterCount += 1

        if concurrentWaiters > 100 {
            socksProxyLock.unlock()
            print("🚨 FIX #672: EXCESSIVE CONCURRENCY - \(concurrentWaiters) concurrent SOCKS proxy waiters!")
            print("🚨 FIX #672: This indicates a bug - waitForSocksProxyReady() is being called too often")
            print("🚨 FIX #672: Waiter ID: \(waiterId), returning false immediately")
            socksProxyLock.lock()
            socksProxyWaiterCount -= 1
            socksProxyLock.unlock()
            return false
        }

        if isWaitingForSocksProxy {
            socksProxyLock.unlock()
            // Another caller is already waiting - just wait for the result
            print("🧅 FIX #672: Waiter \(waiterId) joining existing wait (concurrent: \(concurrentWaiters))")
            while isWaitingForSocksProxy && !socksProxyVerified {
                try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms
            }
            socksProxyLock.lock()
            socksProxyWaiterCount -= 1
            socksProxyLock.unlock()
            return socksProxyVerified
        }
        isWaitingForSocksProxy = true
        socksProxyLock.unlock()

        defer {
            socksProxyLock.lock()
            isWaitingForSocksProxy = false
            socksProxyWaiterCount -= 1
            socksProxyLock.unlock()
        }

        print("🧅 FIX #672: Waiter \(waiterId) starting SOCKS proxy wait (concurrent: \(concurrentWaiters))")
        let startTime = Date()
        var attempts = 0

        while Date().timeIntervalSince(startTime) < maxWait {
            attempts += 1
            // FIX #672: Sanity check - if attempts are way too high, abort
            if attempts > 100 {
                print("🚨 FIX #672: ABNORMAL - \(attempts) attempts detected, aborting wait")
                break
            }
            if await isSocksProxyReady() {
                print("🧅 SOCKS proxy ready after \(attempts) attempt(s) (waiter: \(waiterId))")
                return true
            }

            // Wait 500ms before next check
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        print("🧅 SOCKS proxy NOT ready after \(maxWait) seconds (\(attempts) attempts, waiter: \(waiterId))")
        return false
    }

    /// Reset SOCKS proxy verified state (called when Tor stops)
    private func resetSocksProxyState() {
        socksProxyVerified = false
        socksProxyLock.lock()
        isWaitingForSocksProxy = false
        socksProxyLock.unlock()
    }

    // MARK: - FIX #169: Persistent Hidden Service Keypair Management

    /// Check if a persistent keypair exists in Keychain
    public var hasPersistentKeypair: Bool {
        loadKeypairFromKeychain() != nil
    }

    /// Generate a new Ed25519 keypair and save to Keychain
    /// Returns the .onion address that will be used, or nil on error
    public func generateAndSaveKeypair() -> String? {
        var keypairBuffer = [UInt8](repeating: 0, count: 64)

        let result = keypairBuffer.withUnsafeMutableBufferPointer { ptr -> Int32 in
            zipherx_tor_generate_hs_keypair(ptr.baseAddress)
        }

        guard result == 0 else {
            print("🧅 FIX #169: Failed to generate keypair")
            return nil
        }

        // Save to Keychain
        let keypairData = Data(keypairBuffer)
        guard saveKeypairToKeychain(keypairData) else {
            print("🧅 FIX #169: Failed to save keypair to Keychain")
            return nil
        }

        // Set the keypair in FFI for future hidden service starts
        _ = setKeypairInFFI(keypairData)

        // Get the .onion address from the keypair
        let onionAddress = getOnionAddressFromFFI()
        persistentOnionAddress = onionAddress

        print("🧅 FIX #169: Generated and saved persistent keypair")
        print("🧅 FIX #169: Persistent .onion address ready")

        return onionAddress
    }

    /// Load keypair from Keychain and set it in FFI
    /// Call this before starting the hidden service
    /// Returns the .onion address, or nil if no keypair exists
    public func loadAndSetPersistentKeypair() -> String? {
        guard let keypairData = loadKeypairFromKeychain() else {
            print("🧅 FIX #169: No persistent keypair found - will generate random .onion address")
            persistentOnionAddress = nil
            return nil
        }

        // Set the keypair in FFI
        guard setKeypairInFFI(keypairData) else {
            print("🧅 FIX #169: Failed to set keypair in FFI")
            return nil
        }

        // Get the .onion address
        let onionAddress = getOnionAddressFromFFI()
        persistentOnionAddress = onionAddress

        print("🧅 FIX #169: Loaded persistent keypair from Keychain")
        print("🧅 FIX #169: Persistent .onion address ready")

        return onionAddress
    }

    /// Clear the stored keypair (will generate random address on next start)
    public func clearPersistentKeypair() {
        // Clear from FFI
        _ = zipherx_tor_clear_hs_keypair()

        // Delete from Keychain
        deleteKeypairFromKeychain()

        persistentOnionAddress = nil

        print("🧅 FIX #169: Cleared persistent keypair - next start will use random address")
    }

    /// Regenerate keypair (clear old, generate new)
    /// Returns the new .onion address, or nil on error
    public func regenerateKeypair() -> String? {
        clearPersistentKeypair()
        return generateAndSaveKeypair()
    }

    // MARK: - Private Keychain Helpers

    private func saveKeypairToKeychain(_ keypairData: Data) -> Bool {
        // Delete existing if any
        deleteKeypairFromKeychain()

        // VUL-NET-007: Add device passcode protection for .onion keypair
        // Ed25519 keys can't use Secure Enclave, so use Keychain with access control
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "ZipherX",
            kSecAttrAccount as String: hsKeypairKeychainKey,
            kSecValueData as String: keypairData
        ]

        // VUL-NET-007: Protect .onion key at rest — accessible only when device unlocked
        // NOTE: .devicePasscode NOT used here — .onion key is read at Tor startup
        // (before any user interaction) and does NOT protect spending keys
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            print("🧅 FIX #169: Keychain save error: \(status)")
            return false
        }
        return true
    }

    private func loadKeypairFromKeychain() -> Data? {
        // FIX #1481: Read without kSecUseAuthenticationUIFail to allow macOS Keychain
        // "Allow access?" dialog after code signing changes. Previous code suppressed
        // this dialog → errSecInteractionNotAllowed → DELETED keypair → new .onion address.
        // The keypair is stored with kSecAttrAccessibleWhenUnlockedThisDeviceOnly (NOT
        // .devicePasscode), so no Touch ID/passcode prompt is expected.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "ZipherX",
            kSecAttrAccount as String: hsKeypairKeychainKey,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecSuccess, let data = result as? Data, data.count == 64 {
            return data
        }

        if status == errSecInteractionNotAllowed {
            // Device locked or Keychain requires UI — do NOT delete, try again later.
            // Deleting here would destroy the .onion address permanently.
            print("🧅 FIX #1481: Keychain access deferred — device may be locked, will retry")
            return nil
        }

        if status != errSecItemNotFound {
            print("🧅 FIX #169: Keychain load error: \(status)")
        }

        return nil
    }

    private func deleteKeypairFromKeychain() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "ZipherX",
            kSecAttrAccount as String: hsKeypairKeychainKey
        ]

        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Private FFI Helpers

    private func setKeypairInFFI(_ keypairData: Data) -> Bool {
        let result = keypairData.withUnsafeBytes { ptr -> Int32 in
            guard let baseAddress = ptr.baseAddress else { return 1 }
            return zipherx_tor_set_hs_keypair(baseAddress.assumingMemoryBound(to: UInt8.self), keypairData.count)
        }
        return result == 0
    }

    private func getOnionAddressFromFFI() -> String? {
        guard let addressPtr = zipherx_tor_get_keypair_onion_address() else {
            return nil
        }
        let address = String(cString: addressPtr)
        zipherx_tor_free_string(addressPtr)
        return address
    }
}

// MARK: - Debug Extensions

extension TorManager {

    /// Get debug info about Tor status
    public var debugInfo: String {
        let circuitsStatus = isOnionCircuitsReady ? "Ready" : "Warming (\(Int(onionCircuitWarmupRemaining))s)"
        return """
        🧅 Tor Status (Arti)
        ─────────────────────────
        Mode: \(mode.displayName)
        State: \(connectionState.displayText)
        .onion Circuits: \(circuitsStatus)
        Arti Available: \(isArtiAvailable)
        SOCKS: \(proxyHost):\(socksPort)
        Circuit ID: \(currentCircuitId ?? "N/A")
        Exit Country: \(exitNodeCountry ?? "N/A")
        Isolation Counter: \(circuitIsolationCounter)
        """
    }
}
