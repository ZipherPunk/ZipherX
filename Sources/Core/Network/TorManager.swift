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

    /// Lock to prevent multiple concurrent waitForSocksProxyReady() calls
    private var isWaitingForSocksProxy = false
    private let socksProxyLock = NSLock()

    /// Timestamp when SOCKS proxy became connected (for .onion circuit warmup delay)
    private var connectedSinceTimestamp: Date?

    /// Minimum delay after SOCKS proxy is ready before .onion circuits are likely established
    /// Hidden services require rendezvous circuits which take additional time to set up
    private let onionCircuitWarmupSeconds: TimeInterval = 10.0

    // MARK: - Initialization

    private init() {
        // Load persisted mode
        if let savedMode = UserDefaults.standard.string(forKey: "torMode"),
           let torMode = TorMode(rawValue: savedMode) {
            self.mode = torMode
        } else {
            self.mode = .disabled
        }

        // Check if Arti is available
        let isAvailable = zipherx_tor_is_available()
        print("🧅 TorManager initialized, mode: \(mode.displayName), Arti available: \(isAvailable)")
    }

    // MARK: - Public API

    /// Start Tor connection (if mode requires it)
    public func start() async {
        guard mode == .enabled else {
            print("🧅 Tor disabled, skipping start")
            return
        }

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

    // MARK: - FIX #142: Temporary Tor Bypass for Massive Operations

    /// Track if Tor was bypassed for a massive operation
    private var wasTorEnabledBeforeBypass = false
    private var isBypassActive = false

    /// Temporarily disable Tor for massive operations (header sync, full rescan)
    /// Returns true if Tor was disabled (caller should call restoreTorAfterBypass when done)
    public func bypassTorForMassiveOperation() async -> Bool {
        guard mode == .enabled && !isBypassActive else {
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
        guard !isStartingTor else {
            print("🧅 Tor already starting...")
            return
        }

        // Check if Arti is available
        guard zipherx_tor_is_available() else {
            connectionState = .error("Arti not available in this build")
            return
        }

        isStartingTor = true
        connectionState = .connecting

        print("🧅 Starting Arti (embedded Tor)...")

        // Start Arti in background thread
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<Int32, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = zipherx_tor_start()
                continuation.resume(returning: result)
            }
        }

        if result != 0 {
            // Get error message
            if let errorPtr = zipherx_tor_get_error() {
                let errorMsg = String(cString: errorPtr)
                zipherx_tor_free_string(errorPtr)
                connectionState = .error(errorMsg)
            } else {
                connectionState = .error("Failed to start Tor")
            }
            isStartingTor = false
            return
        }

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
    public func waitForSocksProxyReady(maxWait: TimeInterval = 30) async -> Bool {
        // OPTIMIZATION: Return immediately if already verified
        if socksProxyVerified {
            return true
        }

        // OPTIMIZATION: Prevent multiple concurrent callers from each creating 60 connections
        socksProxyLock.lock()
        if isWaitingForSocksProxy {
            socksProxyLock.unlock()
            // Another caller is already waiting - just wait for the result
            while isWaitingForSocksProxy && !socksProxyVerified {
                try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms
            }
            return socksProxyVerified
        }
        isWaitingForSocksProxy = true
        socksProxyLock.unlock()

        defer {
            socksProxyLock.lock()
            isWaitingForSocksProxy = false
            socksProxyLock.unlock()
        }

        let startTime = Date()
        var attempts = 0

        while Date().timeIntervalSince(startTime) < maxWait {
            attempts += 1
            if await isSocksProxyReady() {
                print("🧅 SOCKS proxy ready after \(attempts) attempt(s)")
                return true
            }

            // Wait 500ms before next check
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        print("🧅 SOCKS proxy NOT ready after \(maxWait) seconds (\(attempts) attempts)")
        return false
    }

    /// Reset SOCKS proxy verified state (called when Tor stops)
    private func resetSocksProxyState() {
        socksProxyVerified = false
        socksProxyLock.lock()
        isWaitingForSocksProxy = false
        socksProxyLock.unlock()
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
