//
//  HiddenServiceManager.swift
//  ZipherX
//
//  Created by ZipherX Team on 2025-12-09.
//  Tor Hidden Service hosting - make ZipherX discoverable as a .onion peer
//
//  "Privacy is the power to selectively reveal oneself to the world."
//  - A Cypherpunk's Manifesto
//

import Foundation

// MARK: - Global Connection Callback

/// FIX #272: Global callback function for C FFI - cannot capture context
/// Routes incoming connections to the HiddenServiceManager singleton
/// Rust signature: (connection_id: u64, host_ptr: *const c_char, port: u16)
private func hiddenServiceConnectionCallback(clientId: UInt64, remoteAddrPtr: UnsafePointer<CChar>?, port: UInt16) {
    let remoteAddr: String
    if let ptr = remoteAddrPtr {
        remoteAddr = String(cString: ptr)
    } else {
        remoteAddr = "unknown"
    }

    print("🧅 FIX #272: Incoming connection callback! Client: \(clientId), Host: \(remoteAddr), Port: \(port)")

    // Handle on main thread via singleton
    DispatchQueue.main.async {
        Task { @MainActor in
            HiddenServiceManager.shared.handleIncomingConnection(clientId: clientId, remoteAddress: "\(remoteAddr):\(port)")
        }
    }
}

// MARK: - Hidden Service State

/// State of the hidden service (onion hosting)
public enum HiddenServiceState: UInt8 {
    case stopped = 0
    case starting = 1
    case running = 2
    case error = 3

    var displayText: String {
        switch self {
        case .stopped: return "Stopped"
        case .starting: return "Starting..."
        case .running: return "Running"
        case .error: return "Error"
        }
    }

    var isActive: Bool {
        self == .running
    }
}

// MARK: - Hidden Service Manager

/// Manages the ZipherX Tor hidden service (onion hosting)
/// When enabled, other peers can connect to your wallet via a .onion address
/// This makes ZipherX a true cypherpunk P2P node - discoverable yet anonymous
@MainActor
public final class HiddenServiceManager: ObservableObject {

    // MARK: - Singleton

    public static let shared = HiddenServiceManager()

    /// Cached onion address for synchronous access (prevents self-connection)
    /// Updated when hidden service starts/stops
    /// nonisolated to allow synchronous access from non-MainActor contexts
    nonisolated(unsafe) public static var cachedOnionAddress: String?

    // MARK: - Published Properties

    /// Current state of the hidden service
    @Published public private(set) var state: HiddenServiceState = .stopped

    /// The .onion address for this ZipherX instance (nil if not running)
    @Published public private(set) var onionAddress: String?

    /// Whether hidden service hosting is enabled by user preference
    @Published public var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "hiddenServiceEnabled")
            Task {
                await handleEnabledChange(from: oldValue, to: isEnabled)
            }
        }
    }

    /// Number of incoming connections currently active
    @Published public private(set) var activeConnectionsCount: Int = 0

    /// Recent connection events (for UI display)
    @Published public private(set) var connectionEvents: [ConnectionEvent] = []

    // MARK: - Configuration

    /// P2P port for the hidden service (Zclassic mainnet)
    public let p2pPort: UInt16 = 8033

    /// Chat port for encrypted messaging (Cypherpunk Chat)
    public let chatPort: UInt16 = 8034

    /// Maximum connection events to keep in history
    private let maxConnectionEvents = 50

    // MARK: - Internal State

    private var statusPollingTask: Task<Void, Never>?
    private var isStarting = false

    // MARK: - Connection Event

    public struct ConnectionEvent: Identifiable {
        public let id = UUID()
        public let timestamp: Date
        public let clientId: UInt64
        public let remoteAddress: String
        public let eventType: EventType

        public enum EventType {
            case connected
            case disconnected
        }
    }

    // MARK: - Initialization

    private init() {
        // Load persisted preference
        self.isEnabled = UserDefaults.standard.bool(forKey: "hiddenServiceEnabled")

        // Check availability
        let available = zipherx_tor_hidden_service_is_available()
        print("🧅 HiddenServiceManager initialized, enabled: \(isEnabled), available: \(available)")

        // Setup callback for incoming connections
        setupConnectionCallback()
    }

    // MARK: - Public API

    /// Start the hidden service (requires Tor to be connected)
    public func start() async -> Bool {
        guard !isStarting else {
            print("🧅 Hidden service already starting...")
            return false
        }

        guard zipherx_tor_hidden_service_is_available() else {
            print("🧅 Hidden service not available in this build")
            return false
        }

        // Check if Tor is connected first
        guard TorManager.shared.connectionState.isConnected else {
            print("🧅 Cannot start hidden service - Tor not connected")
            return false
        }

        isStarting = true
        state = .starting

        print("🧅 Starting hidden service (onion hosting)...")

        // FIX #208: Ensure persistent keypair is loaded or generated BEFORE starting
        // This guarantees the same .onion address across app restarts
        if TorManager.shared.hasPersistentKeypair {
            // Load existing keypair from Keychain into FFI
            if let address = TorManager.shared.loadAndSetPersistentKeypair() {
                print("🧅 FIX #208: Loaded persistent keypair - .onion ready")
            }
        } else {
            // Generate new keypair and save to Keychain
            if let address = TorManager.shared.generateAndSaveKeypair() {
                print("🧅 FIX #208: Generated new persistent keypair - .onion ready")
            }
        }

        // Start hidden service in background
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<Int32, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = zipherx_tor_hidden_service_start()
                continuation.resume(returning: result)
            }
        }

        isStarting = false

        if result == 0 {
            // Success - start polling for status updates
            startStatusPolling()
            // Advertise our .onion address to connected peers
            Task {
                // Wait for address to become available
                try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
                await NetworkManager.shared.advertiseOnionAddressToPeers()
            }
            return true
        } else if result == 2 {
            // Already running
            print("🧅 Hidden service already running")
            await updateStatus()
            // Also advertise when already running
            Task {
                await NetworkManager.shared.advertiseOnionAddressToPeers()
            }
            return true
        } else {
            print("🧅 Failed to start hidden service: code \(result)")
            state = .error
            return false
        }
    }

    /// Stop the hidden service
    public func stop() async {
        print("🧅 Stopping hidden service...")

        // Stop status polling
        statusPollingTask?.cancel()
        statusPollingTask = nil

        // Stop hidden service
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                _ = zipherx_tor_hidden_service_stop()
                continuation.resume()
            }
        }

        state = .stopped
        onionAddress = nil
        isStarting = false
    }

    /// Get the full .onion address for P2P connections
    public var p2pOnionAddress: String? {
        guard let address = onionAddress else { return nil }
        return "\(address):\(p2pPort)"
    }

    /// Get the full .onion address for Chat connections
    public var chatOnionAddress: String? {
        guard let address = onionAddress else { return nil }
        return "\(address):\(chatPort)"
    }

    /// Check if hidden service feature is available
    public var isAvailable: Bool {
        zipherx_tor_hidden_service_is_available()
    }

    // MARK: - Mode Change Handling

    private func handleEnabledChange(from oldValue: Bool, to newValue: Bool) async {
        guard oldValue != newValue else { return }

        print("🧅 Hidden service enabled changed: \(oldValue) → \(newValue)")

        if newValue {
            // User enabled hidden service
            if TorManager.shared.connectionState.isConnected {
                _ = await start()
            } else {
                print("🧅 Hidden service enabled but Tor not connected - will start when Tor connects")
            }
        } else {
            // User disabled hidden service
            await stop()
        }
    }

    /// Called when Tor connection state changes
    public func onTorConnectionStateChanged(isConnected: Bool) async {
        if isConnected && isEnabled && state == .stopped {
            // Tor just connected and hidden service should be enabled
            print("🧅 Tor connected - starting hidden service")
            _ = await start()
        } else if !isConnected && state == .running {
            // Tor disconnected - hidden service will stop
            print("🧅 Tor disconnected - hidden service will stop")
            state = .stopped
            onionAddress = nil
        }
    }

    // MARK: - Status Polling

    private func startStatusPolling() {
        statusPollingTask?.cancel()

        statusPollingTask = Task {
            while !Task.isCancelled {
                await updateStatus()

                // Stop polling if stopped or error
                if state == .stopped || state == .error {
                    break
                }

                try? await Task.sleep(nanoseconds: 1_000_000_000)  // 1 second
            }
        }
    }

    private func updateStatus() async {
        let ffiState = zipherx_tor_hidden_service_get_state()
        let newState = HiddenServiceState(rawValue: ffiState) ?? .error

        await MainActor.run {
            self.state = newState

            // Update onion address if running
            if newState == .running {
                if let addrPtr = zipherx_tor_hidden_service_get_address() {
                    let address = String(cString: addrPtr)
                    zipherx_tor_free_string(addrPtr)

                    if self.onionAddress != address {
                        self.onionAddress = address
                        HiddenServiceManager.cachedOnionAddress = address
                        // Security audit TASK 18: Log redaction
                        print("🧅 Hidden service running at: \(address.redactedAddress)")
                    }
                }
            } else if newState == .stopped {
                self.onionAddress = nil
                HiddenServiceManager.cachedOnionAddress = nil
            }
        }
    }

    // MARK: - Connection Callback

    private func setupConnectionCallback() {
        // Set the callback function for incoming connections
        // This is called from Rust when a peer connects to our hidden service
        // Note: C function pointers cannot capture context, so we use a global callback
        zipherx_tor_hidden_service_set_callback(hiddenServiceConnectionCallback)
    }

    /// Handle incoming connection from hidden service
    /// Called from global callback function
    func handleIncomingConnection(clientId: UInt64, remoteAddress: String) {
        print("🧅 Incoming connection! Client: \(clientId), From: \(remoteAddress)")

        // Add connection event
        let event = ConnectionEvent(
            timestamp: Date(),
            clientId: clientId,
            remoteAddress: remoteAddress,
            eventType: .connected
        )
        connectionEvents.insert(event, at: 0)

        // Trim history
        if connectionEvents.count > maxConnectionEvents {
            connectionEvents = Array(connectionEvents.prefix(maxConnectionEvents))
        }

        // Update connection count
        activeConnectionsCount += 1

        // TODO: Pass connection to NetworkManager for P2P handling
        // NetworkManager.shared.handleIncomingPeer(...)
    }
}

// MARK: - Debug Extensions

extension HiddenServiceManager {

    /// Get debug info about hidden service status
    public var debugInfo: String {
        """
        🧅 Hidden Service Status
        ─────────────────────────
        Enabled: \(isEnabled)
        State: \(state.displayText)
        Available: \(isAvailable)
        Onion Address: \(onionAddress ?? "N/A")
        P2P Port: \(p2pPort)
        Active Connections: \(activeConnectionsCount)
        Recent Events: \(connectionEvents.count)
        """
    }
}
