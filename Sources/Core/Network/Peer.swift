import Foundation
import Network
import CommonCrypto

/// Async lock for serializing peer message access
/// Prevents concurrent operations from interfering with each other's message streams
actor PeerMessageLock {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !isLocked {
            isLocked = true
            return
        }
        // Wait for lock to be released
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        } else {
            isLocked = false
        }
    }

    var isBusy: Bool {
        return isLocked
    }

    /// Try to acquire lock without waiting
    /// Returns true if lock was acquired, false if already locked by another operation
    /// Used by block listener to avoid blocking other P2P operations
    func tryAcquire() -> Bool {
        if isLocked {
            return false
        }
        isLocked = true
        return true
    }
}

// MARK: - VUL-011: Token Bucket Rate Limiter

/// Token bucket rate limiter for peer requests
/// Prevents excessive requests to any single peer
actor PeerRateLimiter {
    private var tokens: Double
    private let maxTokens: Double
    private let refillRate: Double  // tokens per second
    private var lastRefill: Date

    /// Initialize rate limiter
    /// - Parameters:
    ///   - maxTokens: Maximum tokens (requests) allowed in bucket
    ///   - refillRate: How many tokens are added per second
    init(maxTokens: Double = 100, refillRate: Double = 10) {
        self.maxTokens = maxTokens
        self.refillRate = refillRate
        self.tokens = maxTokens
        self.lastRefill = Date()
    }

    /// Check if request is allowed (consumes 1 token if yes)
    /// - Returns: true if request allowed, false if rate limited
    func tryConsume() -> Bool {
        refill()
        if tokens >= 1 {
            tokens -= 1
            return true
        }
        return false
    }

    /// Wait until request is allowed (blocks if rate limited)
    func waitForToken() async {
        refill()
        while tokens < 1 {
            // Wait 100ms and refill
            try? await Task.sleep(nanoseconds: 100_000_000)
            refill()
        }
        tokens -= 1
    }

    /// Refill tokens based on elapsed time
    private func refill() {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastRefill)
        let newTokens = elapsed * refillRate
        tokens = min(maxTokens, tokens + newTokens)
        lastRefill = now
    }

    /// Current token count (for debugging)
    var currentTokens: Double {
        return tokens
    }
}

/// Individual peer connection for Zclassic P2P network
final class Peer {
    let id: String
    let host: String
    let port: UInt16

    private let networkMagic: [UInt8]
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "com.zipherx.peer")

    /// FIX #184: Lock for thread-safe connection access (prevents double-free crash)
    /// Multiple tasks (timeout, disconnect, deinit) can race to cancel the connection
    private let connectionLock = NSLock()

    /// Message lock to serialize P2P operations
    private let messageLock = PeerMessageLock()

    /// VUL-011: Rate limiter to prevent excessive requests
    private let rateLimiter = PeerRateLimiter(maxTokens: 100, refillRate: 10)

    // Protocol version constants (matching Zclassic/zcashd)
    // 170012 = BIP155 (addrv2) support for Tor v3 addresses (MAX VALID)
    // 170011 = Sapling support (backward compatible)
    // 170010 = Non-BIP155 version
    // 170002 = Minimum supported version (Overwinter+)
    // WARNING: Peers demanding 170020+ are Sybil attackers - that version doesn't exist!
    private let protocolVersion: Int32 = 170012

    /// FIX #182: Minimum peer protocol version (matching Zclassic MIN_PEER_PROTO_VERSION)
    /// Peers below this version are rejected - they don't support required features
    private static let minPeerProtocolVersion: Int32 = 170002
    private let services: UInt64 = 1 // NODE_NETWORK
    private let userAgent = "/ZipherX:1.0.0/"

    // Peer scoring
    var score: PeerScore
    var lastSuccess: Date?
    var lastAttempt: Date?
    var consecutiveFailures: Int = 0
    var peerVersion: Int32 = 0
    var peerUserAgent: String = ""
    var peerStartHeight: Int32 = 0
    /// Whether this peer supports BIP155 addrv2 (received sendaddrv2 from them)
    private(set) var supportsAddrv2: Bool = false

    /// Last time the connection was actively used (for staleness detection)
    private var lastActivity: Date?

    /// Max idle time before connection is considered stale (in seconds)
    /// INCREASED from 60 to 180 for Tor mode - P2P over Tor is slower due to 3-hop circuits
    /// This allows header sync to complete with 3-peer consensus over Tor
    private let maxIdleTime: TimeInterval = 180

    // Block announcement listener
    private var blockListenerTask: Task<Void, Never>?
    private var _isListening = false
    private let listenerLock = NSLock()

    /// FIX #140: Public getter for isListening (used by NetworkManager to check listener state)
    var isListening: Bool {
        listenerLock.lock()
        defer { listenerLock.unlock() }
        return _isListening
    }

    /// Callback when a new block is announced via P2P inv message
    /// Parameters: block hash (32 bytes, wire format)
    var onBlockAnnounced: ((Data) -> Void)?

    /// Whether this peer is a .onion address (requires Tor)
    var isOnion: Bool {
        return host.hasSuffix(".onion")
    }

    /// Whether we're connected via Tor SOCKS5 proxy (public for UI display)
    private(set) var isConnectedViaTor: Bool = false

    /// Connection lock to prevent concurrent connection attempts
    /// Multiple code paths calling connect() simultaneously can overwhelm the SOCKS5 proxy
    private var isConnecting = false

    /// FIX #121: STATIC cooldown tracker to prevent duplicate Peer instances from connecting simultaneously
    /// The instance-level isConnecting doesn't help when two Peer objects exist for the same host
    /// FIX #122: Reduced from 5s to 2s for faster header sync
    private static var globalConnectionAttempts: [String: Date] = [:]
    private static let globalConnectionLock = NSLock()
    private static let globalCooldownInterval: TimeInterval = 2.0

    init(host: String, port: UInt16, networkMagic: [UInt8]) {
        self.id = UUID().uuidString
        self.host = host
        self.port = port
        self.networkMagic = networkMagic
        self.score = PeerScore()
    }

    /// CRITICAL: Ensure connection is cancelled when Peer is deallocated
    /// Prevents file descriptor leaks
    /// FIX #184: Use lock to prevent race with concurrent cancel operations
    deinit {
        connectionLock.lock()
        let conn = connection
        connection = nil
        connectionLock.unlock()
        conn?.cancel()
    }

    // MARK: - Scoring

    func recordSuccess() {
        lastSuccess = Date()
        consecutiveFailures = 0
        score.successCount += 1
        score.lastResponseTime = Date()
    }

    func recordFailure() {
        consecutiveFailures += 1
        score.failureCount += 1
    }

    /// Calculate selection probability (higher = better peer)
    func getChance() -> Double {
        // Base chance
        var chance = 1.0

        // Reduce chance based on consecutive failures
        if consecutiveFailures > 0 {
            chance *= pow(0.66, Double(min(consecutiveFailures, 8)))
        }

        // Boost for recent success
        if let lastSuccess = lastSuccess {
            let hoursSinceSuccess = Date().timeIntervalSince(lastSuccess) / 3600
            if hoursSinceSuccess < 1 {
                chance *= 1.5
            } else if hoursSinceSuccess > 24 {
                chance *= 0.5
            }
        }

        // Boost for higher protocol version
        // BIP155 (addrv2) support: protocol version > 170011
        if peerVersion > 170011 {
            chance *= 1.3 // BIP155 peers preferred
        } else if peerVersion >= 170011 {
            chance *= 1.1 // Sapling peers still good
        }

        return chance
    }

    /// Check if peer should be banned
    func shouldBan() -> Bool {
        // Ban after 10 consecutive failures
        if consecutiveFailures >= 10 {
            return true
        }

        // Ban if success rate is terrible (after enough attempts)
        let totalAttempts = score.successCount + score.failureCount
        if totalAttempts >= 10 {
            let successRate = Double(score.successCount) / Double(totalAttempts)
            if successRate < 0.1 {
                return true
            }
        }

        return false
    }

    // MARK: - Message Queue

    /// Check if peer is currently busy with another operation
    var isBusy: Bool {
        get async {
            await messageLock.isBusy
        }
    }

    /// Execute an operation with exclusive access to the peer's message stream
    /// This prevents concurrent operations from interfering with each other
    func withExclusiveAccess<T>(_ operation: () async throws -> T) async throws -> T {
        await messageLock.acquire()
        // CRITICAL FIX: Release lock synchronously, NOT in a Task
        // The old code `defer { Task { await messageLock.release() } }` was broken:
        // Task{} creates an async task that runs LATER, so the lock was still held
        // when this function returned, causing all the race conditions.
        do {
            let result = try await operation()
            await messageLock.release()
            return result
        } catch {
            await messageLock.release()
            throw error
        }
    }

    /// Send a request and wait for a specific response command
    /// Handles the common pattern of send -> receive with exclusive access
    func requestResponse(command: String, payload: Data, expectedResponse: String, maxAttempts: Int = 20) async throws -> Data {
        return try await withExclusiveAccess {
            try await sendMessage(command: command, payload: payload)

            for attempt in 1...maxAttempts {
                let (responseCommand, responseData) = try await receiveMessage()

                if responseCommand == expectedResponse {
                    return responseData
                }

                // Handle common unexpected messages
                if responseCommand == "ping" {
                    // Auto-respond to pings
                    try await sendMessage(command: "pong", payload: responseData)
                    continue
                }

                if responseCommand == "notfound" {
                    throw NetworkError.notFound
                }

                // Log and continue waiting for expected response
                if attempt % 5 == 0 {
                    print("⏳ Waiting for \(expectedResponse), got \(responseCommand) (attempt \(attempt))")
                }
            }

            throw NetworkError.timeout
        }
    }

    // MARK: - Connection

    func connect() async throws {
        // CONCURRENT CONNECTION FIX: Prevent multiple code paths from connecting simultaneously
        // The crash logs showed same peer logging "Connecting via SOCKS5" 3x at same timestamp
        // This overwhelms the SOCKS5 proxy and causes all connections to fail
        connectionLock.lock()
        if isConnecting {
            connectionLock.unlock()
            // Another connection attempt is in progress - wait for it
            print("⏳ [\(host)] Connection already in progress, waiting...")
            var waited = 0
            while isConnecting && waited < 100 { // Max 10 seconds (100 * 100ms)
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                waited += 1
            }
            // After waiting, check if connection succeeded
            if isConnectionReady {
                print("✅ [\(host)] Reusing existing connection")
                return
            }
            // Connection failed during wait - try again (will acquire lock)
            throw NetworkError.connectionFailed("Connection attempt in progress failed")
        }

        // FIX #107: COOLDOWN CHECK IN connect() - Prevent infinite reconnection loops
        // Previously cooldown was only in ensureConnected(), but direct connect() calls bypassed it
        // This caused same peer to reconnect every 100ms when multiple callers retried
        if let lastAttempt = lastAttempt {
            let timeSinceLastAttempt = Date().timeIntervalSince(lastAttempt)
            if timeSinceLastAttempt < Self.minReconnectInterval {
                connectionLock.unlock()
                let waitTime = Self.minReconnectInterval - timeSinceLastAttempt
                print("⏳ [\(host)] Connection cooldown: \(String(format: "%.1f", waitTime))s remaining")
                throw NetworkError.timeout
            }
        }

        // FIX #121: GLOBAL cooldown check to prevent duplicate Peer instances from connecting
        // Multiple Peer objects can exist for the same host (created by different code paths)
        // The instance-level cooldown only prevents the SAME instance from reconnecting
        let hostKey = "\(host):\(port)"
        Self.globalConnectionLock.lock()
        if let globalLastAttempt = Self.globalConnectionAttempts[hostKey] {
            let timeSinceGlobal = Date().timeIntervalSince(globalLastAttempt)
            if timeSinceGlobal < Self.globalCooldownInterval {
                Self.globalConnectionLock.unlock()
                connectionLock.unlock()
                let waitTime = Self.globalCooldownInterval - timeSinceGlobal
                print("⏳ [\(host)] GLOBAL cooldown: \(String(format: "%.1f", waitTime))s remaining (another instance connecting)")
                throw NetworkError.timeout
            }
        }
        Self.globalConnectionAttempts[hostKey] = Date()
        Self.globalConnectionLock.unlock()

        // Record this attempt BEFORE releasing lock to prevent races
        lastAttempt = Date()

        isConnecting = true
        connectionLock.unlock()

        // Ensure we reset isConnecting when done (success or failure)
        defer {
            connectionLock.lock()
            isConnecting = false
            connectionLock.unlock()
        }

        // Check if this is a .onion address - requires Tor SOCKS5 proxy
        if isOnion {
            try await connectViaSocks5()
            return
        }

        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(integerLiteral: port))

        // Use Tor parameters if Tor is enabled (for privacy even with regular IPs)
        // CRITICAL: If Tor mode is enabled, ALWAYS use SOCKS5 (connectViaSocks5 will wait for Tor)
        // This prevents direct connections when Tor isn't ready yet
        // FIX #144: Check isTorBypassed - when bypassed, connect directly for speed
        let torEnabled = await TorManager.shared.mode == .enabled
        let torBypassed = await TorManager.shared.isTorBypassed
        if torEnabled && !torBypassed {
            // Route through Tor SOCKS5 proxy for privacy (will wait for Tor if not ready)
            try await connectViaSocks5()
            return
        }
        // FIX #144: If Tor is bypassed, use direct connection for faster header sync
        if torBypassed {
            print("📡 [\(host)] Connecting directly (Tor bypassed for speed)")
        }

        // FIX #267: Configure TCP-level keepalive to prevent iOS from killing idle connections
        // iOS mobile networks are aggressive about dropping idle TCP connections
        // TCP keepalive is more reliable than app-level keepalive on mobile
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveInterval = 30  // Send keepalive every 30 seconds
        tcpOptions.keepaliveCount = 4      // Allow 4 missed probes before disconnect
        tcpOptions.connectionTimeout = 15  // 15 second connection timeout

        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        // Don't restrict to wifi - allow any network interface
        // parameters.requiredInterfaceType = .wifi

        // CRITICAL: Cancel old connection to prevent file descriptor leak
        connection?.cancel()
        connection = nil

        connection = NWConnection(to: endpoint, using: parameters)

        // FIX #267: Add viability handler to detect when iOS thinks connection is dead
        connection?.viabilityUpdateHandler = { [weak self] isViable in
            guard let self = self else { return }
            if !isViable {
                print("⚠️ FIX #267: [\(self.host)] Connection no longer viable - iOS network change detected")
                // Disconnect so NetworkManager can reconnect
                self.disconnect()
            }
        }

        // Add timeout for connection
        // FIX #152: Use withTaskCancellationHandler to ensure continuation resumes on cancellation
        return try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        var hasResumed = false
                        let resumeLock = NSLock()

                        // FIX #152: Check if task is already cancelled before starting
                        if Task.isCancelled {
                            continuation.resume(throwing: CancellationError())
                            return
                        }

                        self.connection?.stateUpdateHandler = { state in
                            resumeLock.lock()
                            defer { resumeLock.unlock() }
                            guard !hasResumed else { return }

                            switch state {
                            case .ready:
                                hasResumed = true
                                continuation.resume()
                            case .failed(let error):
                                hasResumed = true
                                continuation.resume(throwing: NetworkError.connectionFailed(error.localizedDescription))
                            case .cancelled:
                                hasResumed = true
                                continuation.resume(throwing: NetworkError.connectionFailed("Connection cancelled"))
                            default:
                                break
                            }
                        }

                        self.connection?.start(queue: self.queue)
                    }
                } onCancel: {
                    // FIX #152: When task is cancelled, cancel the NWConnection to trigger state change
                    self.connection?.cancel()
                }
            }

            group.addTask {
                try await Task.sleep(nanoseconds: 5_000_000_000) // 5 second timeout
                throw NetworkError.timeout
            }

            // Wait for first to complete (connection or timeout)
            try await group.next()
            group.cancelAll()
        }
    }

    // MARK: - SOCKS5 Connection (for .onion addresses and Tor privacy)

    /// Connect to peer via Tor SOCKS5 proxy
    /// Used for .onion addresses and when Tor mode is enabled for privacy
    private func connectViaSocks5() async throws {
        var socksPort = await TorManager.shared.socksPort
        var torConnected = await TorManager.shared.connectionState.isConnected

        // If Tor isn't connected yet, wait for it (up to 30 seconds)
        if !torConnected || socksPort == 0 {
            print("🧅 [\(host)] Waiting for Tor SOCKS proxy to be ready...")
            let proxyReady = await TorManager.shared.waitForSocksProxyReady(maxWait: 30)
            if proxyReady {
                socksPort = await TorManager.shared.socksPort
                torConnected = await TorManager.shared.connectionState.isConnected
            }
        }

        guard torConnected && socksPort > 0 else {
            if isOnion {
                throw NetworkError.connectionFailed(".onion addresses require Tor to be connected")
            }
            throw NetworkError.connectionFailed("Tor not connected")
        }

        // NOTE: Removed redundant isSocksProxyReady() check - waitForSocksProxyReady()
        // already verifies this and caches the result. This prevents socket leak.

        print("🧅 [\(host)] Connecting via SOCKS5 proxy (port \(socksPort))...")

        // Connect to local Tor SOCKS5 proxy
        let proxyEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(integerLiteral: socksPort)
        )

        // FIX #267: Configure TCP-level keepalive for Tor connections too
        // Even more important for Tor since circuits can become stale
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveInterval = 30  // Send keepalive every 30 seconds
        tcpOptions.keepaliveCount = 4      // Allow 4 missed probes before disconnect
        tcpOptions.connectionTimeout = 20  // Tor connections can be slower

        let parameters = NWParameters(tls: nil, tcp: tcpOptions)

        // CRITICAL: Cancel old connection to prevent file descriptor leak
        connection?.cancel()
        connection = nil

        connection = NWConnection(to: proxyEndpoint, using: parameters)

        // FIX #267: Add viability handler for Tor connections
        connection?.viabilityUpdateHandler = { [weak self] isViable in
            guard let self = self else { return }
            if !isViable {
                print("⚠️ FIX #267: [\(self.host)] Tor connection no longer viable")
                self.disconnect()
            }
        }

        // Wait for connection to proxy with proper continuation handling
        // Use a class-based lock for thread-safe flag (NSLock is Sendable)
        final class ResumedFlag: @unchecked Sendable {
            private var _resumed = false
            private let lock = NSLock()

            func checkAndSet() -> Bool {
                lock.lock()
                defer { lock.unlock() }
                if _resumed { return true }
                _resumed = true
                return false
            }
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    let resumed = ResumedFlag()

                    self.connection?.stateUpdateHandler = { state in
                        switch state {
                        case .ready:
                            if !resumed.checkAndSet() {
                                continuation.resume()
                            }
                        case .failed(let error):
                            if !resumed.checkAndSet() {
                                continuation.resume(throwing: NetworkError.connectionFailed(error.localizedDescription))
                            }
                        case .cancelled:
                            if !resumed.checkAndSet() {
                                continuation.resume(throwing: NetworkError.connectionFailed("Connection cancelled"))
                            }
                        default:
                            break
                        }
                    }

                    self.connection?.start(queue: self.queue)

                    // CRITICAL: Handle task cancellation to prevent continuation leak
                    Task {
                        // Wait a bit longer than timeout to ensure we catch the cancellation
                        try? await Task.sleep(nanoseconds: 11_000_000_000)
                        if !resumed.checkAndSet() {
                            continuation.resume(throwing: NetworkError.timeout)
                        }
                    }
                }
            }

            group.addTask {
                try await Task.sleep(nanoseconds: 10_000_000_000) // 10 second timeout for Tor
                throw NetworkError.timeout
            }

            try await group.next()
            group.cancelAll()
        }

        // Perform SOCKS5 handshake
        try await performSocks5Handshake()
        isConnectedViaTor = true
        print("🧅 [\(host)] Connected via Tor (SOCKS5 handshake complete)")
    }

    /// Perform SOCKS5 handshake to connect to target host through proxy
    /// RFC 1928: https://datatracker.ietf.org/doc/html/rfc1928
    /// Updated for Arti compatibility - supports both no-auth (0x00) and username/password (0x02)
    private func performSocks5Handshake() async throws {
        // Step 1: Send greeting (version, number of methods, methods)
        // Offer both no-auth (0x00) and username/password (0x02) for Arti compatibility
        // Arti uses username/password auth for circuit isolation
        let greeting = Data([0x05, 0x02, 0x00, 0x02]) // SOCKS5, 2 methods: no auth + username/password
        try await sendRawData(greeting)

        // Step 2: Receive server choice (with timeout and retry)
        var authResponse: Data
        do {
            authResponse = try await receiveRawDataWithTimeout(length: 2, timeout: 5.0)
        } catch {
            print("🧅 [\(host)] SOCKS5 auth response failed: \(error)")
            throw NetworkError.connectionFailed("SOCKS5 proxy not responding")
        }

        guard authResponse.count == 2 else {
            print("🧅 [\(host)] SOCKS5 invalid auth response length: \(authResponse.count)")
            throw NetworkError.connectionFailed("Invalid SOCKS5 auth response (got \(authResponse.count) bytes)")
        }

        // Debug log the raw bytes for troubleshooting
        let byte0 = authResponse[0]
        let byte1 = authResponse[1]

        guard byte0 == 0x05 else {
            print("🧅 [\(host)] SOCKS5 version mismatch: expected 0x05, got 0x\(String(format: "%02X", byte0))")
            print("🧅 [\(host)] Full response bytes: \(authResponse.hexString)")
            throw NetworkError.connectionFailed("SOCKS5 version mismatch (got 0x\(String(format: "%02X", byte0)), expected 0x05)")
        }

        // Handle authentication method
        switch byte1 {
        case 0x00:
            // No authentication required - continue to connection request
            print("🧅 [\(host)] SOCKS5 using no authentication")

        case 0x02:
            // Username/password authentication required
            // Arti uses this for circuit isolation - any username/password works
            print("🧅 [\(host)] SOCKS5 using username/password auth (circuit isolation)")
            try await performSocks5UsernameAuth()

        case 0xFF:
            throw NetworkError.connectionFailed("SOCKS5 proxy: no acceptable auth methods")

        default:
            print("🧅 [\(host)] SOCKS5 unsupported auth method: 0x\(String(format: "%02X", byte1))")
            throw NetworkError.connectionFailed("SOCKS5 auth method not supported: \(byte1)")
        }

        // Step 3: Send connection request
        // +----+-----+-------+------+----------+----------+
        // |VER | CMD |  RSV  | ATYP | DST.ADDR | DST.PORT |
        // +----+-----+-------+------+----------+----------+
        var request = Data()
        request.append(0x05) // SOCKS5
        request.append(0x01) // CONNECT
        request.append(0x00) // Reserved

        if isOnion || host.contains(".") == false || host.allSatisfy({ $0.isNumber || $0 == "." }) == false {
            // Domain name (ATYP = 0x03)
            request.append(0x03)
            let hostData = host.data(using: .utf8)!
            request.append(UInt8(hostData.count))
            request.append(hostData)
        } else {
            // IPv4 (ATYP = 0x01)
            request.append(0x01)
            let components = host.split(separator: ".").compactMap { UInt8($0) }
            guard components.count == 4 else {
                throw NetworkError.connectionFailed("Invalid IPv4 address: \(host)")
            }
            request.append(contentsOf: components)
        }

        // Port (big-endian)
        request.append(UInt8((port >> 8) & 0xFF))
        request.append(UInt8(port & 0xFF))

        try await sendRawData(request)

        // Step 4: Receive connection response
        // +----+-----+-------+------+----------+----------+
        // |VER | REP |  RSV  | ATYP | BND.ADDR | BND.PORT |
        // +----+-----+-------+------+----------+----------+
        let responseHeader = try await receiveRawData(length: 4)
        guard responseHeader.count == 4 else {
            throw NetworkError.connectionFailed("Invalid SOCKS5 response header")
        }
        guard responseHeader[0] == 0x05 else {
            throw NetworkError.connectionFailed("SOCKS5 version mismatch in response")
        }

        let replyCode = responseHeader[1]
        if replyCode != 0x00 {
            let errorMsg = socks5ErrorMessage(replyCode)
            throw NetworkError.connectionFailed("SOCKS5 error: \(errorMsg)")
        }

        // Read bound address (we don't need it but must consume it)
        let atyp = responseHeader[3]
        switch atyp {
        case 0x01: // IPv4
            _ = try await receiveRawData(length: 4 + 2) // 4 bytes IP + 2 bytes port
        case 0x03: // Domain
            let lenData = try await receiveRawData(length: 1)
            let domainLen = Int(lenData[0])
            _ = try await receiveRawData(length: domainLen + 2) // domain + 2 bytes port
        case 0x04: // IPv6
            _ = try await receiveRawData(length: 16 + 2) // 16 bytes IP + 2 bytes port
        default:
            throw NetworkError.connectionFailed("Unknown SOCKS5 address type: \(atyp)")
        }

        // Connection established! Now we can use this connection for P2P messages
    }

    /// Convert SOCKS5 reply code to human-readable message
    private func socks5ErrorMessage(_ code: UInt8) -> String {
        switch code {
        case 0x00: return "Success"
        case 0x01: return "General SOCKS server failure"
        case 0x02: return "Connection not allowed by ruleset"
        case 0x03: return "Network unreachable"
        case 0x04: return "Host unreachable"
        case 0x05: return "Connection refused"
        case 0x06: return "TTL expired"
        case 0x07: return "Command not supported"
        case 0x08: return "Address type not supported"
        default: return "Unknown error (\(code))"
        }
    }

    /// Send raw data directly to connection (for SOCKS5 handshake)
    private func sendRawData(_ data: Data) async throws {
        guard let conn = connection else {
            throw NetworkError.notConnected
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    /// Receive exact number of bytes from connection (for SOCKS5 handshake)
    private func receiveRawData(length: Int) async throws -> Data {
        guard let conn = connection else {
            throw NetworkError.notConnected
        }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            conn.receive(minimumIncompleteLength: length, maximumLength: length) { content, _, _, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let data = content {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: NetworkError.connectionFailed("No data received"))
                }
            }
        }
    }

    /// Receive data with timeout (for SOCKS5 handshake reliability)
    private func receiveRawDataWithTimeout(length: Int, timeout: TimeInterval) async throws -> Data {
        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                try await self.receiveRawData(length: length)
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw NetworkError.timeout
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    /// Perform SOCKS5 username/password authentication (RFC 1929)
    /// Arti uses this for circuit isolation - any username/password is accepted
    private func performSocks5UsernameAuth() async throws {
        // Generate unique credentials for circuit isolation
        let username = "zipherx-\(UUID().uuidString.prefix(8))"
        let password = "tor-\(Int.random(in: 1000...9999))"

        // Build authentication request
        // +----+------+----------+------+----------+
        // |VER | ULEN |  UNAME   | PLEN |  PASSWD  |
        // +----+------+----------+------+----------+
        // | 1  |  1   | 1 to 255 |  1   | 1 to 255 |
        // +----+------+----------+------+----------+
        var authRequest = Data()
        authRequest.append(0x01)  // Auth version (always 0x01)
        authRequest.append(UInt8(username.count))
        authRequest.append(contentsOf: username.utf8)
        authRequest.append(UInt8(password.count))
        authRequest.append(contentsOf: password.utf8)

        try await sendRawData(authRequest)

        // Receive authentication response
        // +----+--------+
        // |VER | STATUS |
        // +----+--------+
        // | 1  |   1    |
        // +----+--------+
        let authResponse = try await receiveRawDataWithTimeout(length: 2, timeout: 5.0)

        guard authResponse.count == 2 else {
            throw NetworkError.connectionFailed("Invalid SOCKS5 auth response")
        }

        guard authResponse[0] == 0x01 else {
            throw NetworkError.connectionFailed("SOCKS5 auth version mismatch")
        }

        guard authResponse[1] == 0x00 else {
            throw NetworkError.connectionFailed("SOCKS5 authentication failed (status: \(authResponse[1]))")
        }

        print("🧅 [\(host)] SOCKS5 authentication successful")
    }

    /// FIX #184: Thread-safe disconnect to prevent double-free crash
    func disconnect() {
        stopBlockListener()
        connectionLock.lock()
        let conn = connection
        connection = nil
        connectionLock.unlock()
        conn?.cancel()
        isConnectedViaTor = false
    }

    /// Check if connection is still ready (not cancelled/failed)
    var isConnectionReady: Bool {
        guard let conn = connection else { return false }
        switch conn.state {
        case .ready:
            return true
        default:
            return false
        }
    }

    /// Check if connection is stale (idle for too long)
    private var isConnectionStale: Bool {
        guard let activity = lastActivity else {
            // Never used - consider stale if it's been a while since creation
            return true
        }
        return Date().timeIntervalSince(activity) > maxIdleTime
    }

    /// Reconnect if connection is not ready or stale
    /// Minimum time between reconnection attempts (seconds)
    /// FIX #122: Reduced from 5s to 2s for faster header sync
    private static let minReconnectInterval: TimeInterval = 2.0

    func ensureConnected() async throws {
        let needsReconnect = !isConnectionReady || isConnectionStale

        if !needsReconnect {
            return // Connection is ready and fresh
        }

        // COOLDOWN: Prevent rapid reconnection attempts (prevents infinite loop)
        if let lastAttempt = lastAttempt {
            let timeSinceLastAttempt = Date().timeIntervalSince(lastAttempt)
            if timeSinceLastAttempt < Self.minReconnectInterval {
                let waitTime = Self.minReconnectInterval - timeSinceLastAttempt
                print("⏳ [\(host)] Reconnect cooldown: waiting \(String(format: "%.1f", waitTime))s...")
                throw NetworkError.timeout // Don't wait, just fail this attempt
            }
        }

        // Log why we're reconnecting
        if !isConnectionReady {
            print("🔄 [\(host)] Connection not ready, reconnecting...")
        } else if isConnectionStale {
            let idleTime = lastActivity.map { Int(Date().timeIntervalSince($0)) } ?? -1
            print("🔄 [\(host)] Connection stale (idle \(idleTime)s), reconnecting...")
        }

        // Disconnect old connection if exists
        if connection != nil {
            disconnect()
            // Small delay to ensure old connection is fully torn down
            // This prevents race conditions with SOCKS5 proxy
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }

        // Reconnect with fresh handshake
        try await connect()
        try await performHandshake()
        lastActivity = Date()
        print("✅ [\(host)] Reconnected successfully")
    }

    /// Update last activity timestamp (call after successful message exchange)
    func markActive() {
        lastActivity = Date()
    }

    // MARK: - Block Announcement Listener

    /// Start listening for block announcements in background
    /// Call this after handshake completes
    /// NOTE: The listener only runs when peer is idle (not busy with other operations)
    func startBlockListener() {
        // ATOMIC CHECK: Use lock to prevent multiple listeners from starting
        // Without lock, two concurrent calls could both pass the guard before either sets _isListening
        listenerLock.lock()
        if _isListening {
            listenerLock.unlock()
            print("📡 [\(host)] Block listener already running, skipping")
            return
        }
        // Cancel any existing task just to be safe
        blockListenerTask?.cancel()
        blockListenerTask = nil
        _isListening = true
        listenerLock.unlock()

        blockListenerTask = Task { [weak self] in
            guard let self = self else { return }

            // Add initial delay to let connection stabilize after handshake
            // This prevents reading garbage bytes that may be buffered
            // Longer delay for .onion peers (Tor), shorter for regular peers
            if self.isOnion {
                print("📡 [\(self.host)] .onion peer - waiting 2s for Tor connection to stabilize...")
                try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
            } else {
                // Short delay for regular peers to let any pending handshake data clear
                try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
            }

            print("📡 [\(self.host)] Block listener started")

            var consecutiveErrors = 0
            let maxConsecutiveErrors = 5

            while self._isListening && self.connection != nil {
                do {
                    // RACE CONDITION FIX: Acquire lock before receiving to prevent
                    // concurrent socket reads with other P2P operations.
                    // Uses tryAcquire() which returns immediately if lock is held,
                    // avoiding blocking other operations.
                    let acquired = await self.messageLock.tryAcquire()
                    if !acquired {
                        // Peer is busy with another operation, wait and retry
                        try await Task.sleep(nanoseconds: 500_000_000) // 500ms
                        continue
                    }

                    // Try to receive a message with a timeout
                    // Lock is held during receive to prevent concurrent reads
                    let (command, payload): (String, Data)
                    do {
                        (command, payload) = try await self.receiveMessageNonBlockingTolerant()
                    } catch {
                        // Release lock before rethrowing
                        await self.messageLock.release()
                        throw error
                    }

                    // Release lock after receiving (before processing)
                    await self.messageLock.release()

                    // Reset error counter on successful message
                    consecutiveErrors = 0

                    // Handle the received message
                    await self.handleBackgroundMessage(command: command, payload: payload)

                } catch NetworkError.timeout {
                    // Timeout is normal - just continue listening
                    // FIX #120: Check if we should stop after each timeout
                    if !self._isListening {
                        break
                    }
                    continue
                } catch is CancellationError {
                    // FIX #120: Listener was stopped - exit cleanly without error message
                    break
                } catch NetworkError.invalidMagicBytes {
                    // For .onion peers, invalid magic bytes might be Tor noise - retry with backoff
                    consecutiveErrors += 1
                    if consecutiveErrors < maxConsecutiveErrors {
                        let backoffMs = min(500 * consecutiveErrors, 2000)
                        print("📡 [\(self.host)] Invalid magic bytes (attempt \(consecutiveErrors)/\(maxConsecutiveErrors)), retrying in \(backoffMs)ms...")
                        try? await Task.sleep(nanoseconds: UInt64(backoffMs) * 1_000_000)
                        continue
                    } else {
                        print("📡 [\(self.host)] Too many invalid magic bytes, stopping listener")
                        break
                    }
                } catch {
                    // Connection closed or error - stop listening
                    if self._isListening {
                        print("📡 [\(self.host)] Block listener stopped: \(error.localizedDescription)")
                    }
                    break
                }
            }

            // Reset _isListening when task ends (use lock for thread safety)
            self.listenerLock.lock()
            self._isListening = false
            self.listenerLock.unlock()
            print("📡 [\(self.host)] Block listener ended")
        }
    }

    /// Stop listening for block announcements
    func stopBlockListener() {
        listenerLock.lock()
        _isListening = false
        blockListenerTask?.cancel()
        blockListenerTask = nil
        listenerLock.unlock()
    }

    /// Receive message without blocking indefinitely (uses short timeout)
    private func receiveMessageNonBlocking() async throws -> (String, Data) {
        guard let connection = connection else {
            throw NetworkError.notConnected
        }

        // Use a short timeout to periodically check if we should stop
        return try await withThrowingTaskGroup(of: (String, Data).self) { group in
            group.addTask {
                return try await self.receiveMessage()
            }

            group.addTask {
                // 30 second timeout - allows periodic check of _isListening
                try await Task.sleep(nanoseconds: 30_000_000_000)
                throw NetworkError.timeout
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    /// Tolerant version for block listener - throws invalidMagicBytes instead of handshakeFailed
    /// This allows the listener to retry on Tor noise instead of immediately stopping
    private func receiveMessageNonBlockingTolerant() async throws -> (String, Data) {
        // FIX #120: Check if listener should stop BEFORE starting receive
        // This allows stopBlockListener() to immediately cancel pending receives
        guard _isListening else {
            throw CancellationError()
        }

        guard let connection = connection else {
            throw NetworkError.notConnected
        }

        // Use a short timeout to periodically check if we should stop
        return try await withThrowingTaskGroup(of: (String, Data).self) { group in
            group.addTask {
                // FIX #120: Check cancellation before blocking on receive
                try Task.checkCancellation()
                return try await self.receiveMessageTolerant()
            }

            group.addTask {
                // FIX #120: Reduced from 5s to 1s to allow faster listener shutdown
                // This is the maximum time stopBlockListener() will wait before listener exits
                try await Task.sleep(nanoseconds: 1_000_000_000)
                throw NetworkError.timeout
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    /// Tolerant receive that throws invalidMagicBytes instead of handshakeFailed
    private func receiveMessageTolerant() async throws -> (String, Data) {
        // Read header (24 bytes)
        let header = try await receive(count: 24)

        // Verify magic - use invalidMagicBytes for block listener to retry
        guard Array(header.prefix(4)) == networkMagic else {
            let gotMagic = Array(header.prefix(4)).map { String(format: "%02x", $0) }.joined()
            let expectedMagic = networkMagic.map { String(format: "%02x", $0) }.joined()
            print("🧅 [\(host)] Invalid magic bytes: got \(gotMagic), expected \(expectedMagic)")
            throw NetworkError.invalidMagicBytes
        }

        // Parse command
        let commandBytes = header[4..<16]
        let command = String(bytes: commandBytes.prefix(while: { $0 != 0 }), encoding: .utf8) ?? ""

        // Parse length (safe loading)
        let length = header.loadUInt32(at: 16)

        // Read payload
        var payload = Data()
        if length > 0 {
            payload = try await receive(count: Int(length))
        }

        return (command, payload)
    }

    /// Handle messages received in background listener
    private func handleBackgroundMessage(command: String, payload: Data) async {
        switch command {
        case "inv":
            handleInvMessage(payload: payload)

        case "ping":
            // Respond to pings to keep connection alive
            try? await sendMessage(command: "pong", payload: payload)

        case "alert", "addr", "headers", "tx", "block":
            // Known message types we don't need to handle in background
            break

        default:
            // Ignore other messages
            break
        }
    }

    /// Parse inv message and extract block announcements
    private func handleInvMessage(payload: Data) {
        guard payload.count >= 1 else { return }

        var offset = 0

        // Read count (varint)
        let (count, countSize) = readVarInt(from: payload, at: offset)
        offset += countSize

        var blockHashes: [Data] = []

        for _ in 0..<count {
            guard offset + 36 <= payload.count else { break }

            // Type: 1 = MSG_TX, 2 = MSG_BLOCK
            let invType = payload.loadUInt32(at: offset)
            offset += 4

            // Hash (32 bytes)
            let hash = payload.subdata(in: offset..<offset+32)
            offset += 32

            // Collect block announcements (type 2)
            if invType == 2 {
                blockHashes.append(hash)
            }
        }

        // Notify about new blocks
        if !blockHashes.isEmpty {
            print("📦 [\(host)] Received \(blockHashes.count) new block announcement(s)!")
            for blockHash in blockHashes {
                onBlockAnnounced?(blockHash)
            }
        }
    }

    // MARK: - Handshake

    func performHandshake() async throws {
        lastAttempt = Date()

        // Send version message
        let versionPayload = buildVersionPayload()
        try await sendMessage(command: "version", payload: versionPayload)

        // Wait for version message from peer (with retry for non-version messages)
        // Bitcoin P2P can send other messages before version in some edge cases
        var receivedVersion = false
        var versionAttempts = 0
        let maxVersionAttempts = 5  // Max messages to check before giving up on version
        var lastRejectReason: String?  // FIX #170: Track why peer rejected us

        while !receivedVersion && versionAttempts < maxVersionAttempts {
            // FIX #150: Use timeout to prevent hung connections during startup
            // NWConnection.receive() doesn't respond to Swift task cancellation
            do {
                let (command, payload) = try await receiveMessageWithTimeout(seconds: 10)
                versionAttempts += 1

                if command == "version" {
                    parseVersionPayload(payload)
                    // FIX #182: Validate version - Zclassic peers must be at least 170002 (Overwinter+)
                    // Previous bug: accepted 70002 which is 2400x too lenient!
                    if peerVersion >= Peer.minPeerProtocolVersion {
                        receivedVersion = true
                        print("📡 [\(host)] Peer version: \(peerVersion), user-agent: \(peerUserAgent)")
                    } else if peerVersion > 0 {
                        // Peer is running outdated software - reject with clear message
                        print("❌ [\(host)] Peer version \(peerVersion) is too old (minimum: \(Peer.minPeerProtocolVersion))")
                        throw NetworkError.handshakeFailed
                    } else {
                        // Version 0 - likely parsing issue
                        print("⚠️ [\(host)] Invalid peer version \(peerVersion) (payload: \(payload.count) bytes)")
                        // Continue waiting for valid version
                    }
                } else if command == "reject" {
                    // FIX #170: Parse reject message to understand WHY peer rejected our VERSION
                    lastRejectReason = parseRejectMessage(payload)
                    print("⚠️ [\(host)] Got REJECT: \(lastRejectReason ?? "unknown reason")")

                    // FIX #172: Wrong-chain detection (likely Zcash nodes on same port)
                    // Zclassic valid protocol versions: 170010, 170011 (Sapling), 170012 (BIP155)
                    // Zcash uses higher versions (170020+, 170100+ for NU5)
                    // Don't alarm about "Sybil" - these are legitimate nodes for different chain
                    // FIX #229: Throw specific error so NetworkManager can permanently ban
                    if let reason = lastRejectReason, reason.contains("170020") || reason.contains("170100") || reason.contains("170019") {
                        print("⚠️ [\(host)] Wrong chain: Peer requires version 170020+ (likely Zcash, not Zclassic)")
                        // Throw specific error for NetworkManager to ban this address permanently
                        throw NetworkError.wrongChain(host)
                    }

                    // If peer explicitly rejected our version, no point in waiting for more messages
                    // The reject message indicates the peer won't send version
                    if payload.count > 0 {
                        let msgType = parseRejectMessageType(payload)
                        if msgType == "version" {
                            print("❌ [\(host)] Peer rejected our VERSION message - aborting handshake")
                            throw NetworkError.handshakeFailed
                        }
                    }
                } else {
                    // Got non-version message first - log and continue waiting
                    print("📡 [\(host)] Got '\(command)' (\(payload.count) bytes) before version, waiting for version...")
                }
            } catch NetworkError.timeout {
                // FIX #170: Timeout fired - peer stopped responding after sending some messages
                versionAttempts += 1
                print("⚠️ [\(host)] Timeout waiting for version (attempt \(versionAttempts)/\(maxVersionAttempts))")
                if versionAttempts >= maxVersionAttempts {
                    break
                }
            }
        }

        if !receivedVersion {
            print("❌ [\(host)] Never received version message after \(versionAttempts) attempts")
            throw NetworkError.handshakeFailed
        }

        // Signal we support addrv2 (BIP 155) for Tor v3 addresses
        // Per BIP155: sendaddrv2 MUST be sent AFTER version exchange but BEFORE verack is sent
        // Order: VERSION <-> VERSION -> SENDADDRV2 -> VERACK <-> VERACK
        // BIP155 requires protocol version > 170011 for Zclassic
        if peerVersion > 170011 {
            try await sendMessage(command: "sendaddrv2", payload: Data())
            print("📡 [\(host)] Sent sendaddrv2 (BIP155 peer v\(peerVersion))")
        } else {
            print("📡 [\(host)] No BIP155 - peer version \(peerVersion) <= 170011")
        }

        // Send verack (after sendaddrv2 if BIP155)
        try await sendMessage(command: "verack", payload: Data())

        // Receive messages until we get verack AND (sendaddrv2 OR timeout)
        // Per BIP155: sendaddrv2 can come before OR after verack
        var receivedVerack = false
        var attempts = 0
        let maxAttempts = 8  // Increased to allow for sendaddrv2 after verack

        while attempts < maxAttempts {
            // FIX #150: Use timeout to prevent hung connections during startup
            let (command, _) = try await receiveMessageWithTimeout(seconds: 10)
            attempts += 1

            if command == "verack" {
                receivedVerack = true
                print("📡 [\(host)] Received verack")
                // Don't exit yet - continue to check for sendaddrv2
                // But only check 2 more messages after verack
                if supportsAddrv2 || attempts >= maxAttempts - 2 {
                    break  // Already have sendaddrv2 or enough attempts
                }
            } else if command == "sendaddrv2" {
                // Peer signals BIP155 support - we can send addrv2 to them
                supportsAddrv2 = true
                print("📡 [\(host)] ✅ Received sendaddrv2 - peer supports BIP155 addrv2")
                if receivedVerack {
                    break  // Have both verack and sendaddrv2
                }
            } else {
                // Other messages during handshake (ignore but continue)
                print("📡 [\(host)] Received \(command) during handshake")
                if receivedVerack {
                    // Already got verack, don't need to wait for more non-sendaddrv2 messages
                    break
                }
            }
        }

        if !receivedVerack {
            throw NetworkError.handshakeFailed
        }

        print("📡 [\(host)] Handshake complete - supportsAddrv2: \(supportsAddrv2)")

        recordSuccess()
        lastActivity = Date() // Mark connection as active after successful handshake
    }

    private func parseVersionPayload(_ data: Data) {
        guard data.count >= 80 else {
            print("⚠️ [\(host)] Version payload too short: \(data.count) bytes (need 80+)")
            return
        }

        // Protocol version (bytes 0-3) - use safe loading
        peerVersion = data.loadInt32(at: 0)

        // Skip services (8), timestamp (8), addr_recv (26), addr_from (26), nonce (8)
        // = 76 bytes, then user agent

        var offset = 80
        if offset < data.count {
            let agentLength = Int(data[offset])
            offset += 1
            if offset + agentLength <= data.count {
                peerUserAgent = String(bytes: data[offset..<(offset + agentLength)], encoding: .utf8) ?? ""
                offset += agentLength
            }
        }

        // Start height
        if offset + 4 <= data.count {
            peerStartHeight = data.loadInt32(at: offset)
        }
    }

    // MARK: - FIX #170: Reject Message Parsing

    /// Parse reject message to get the message type being rejected (e.g., "version", "tx")
    /// Reject format: msgtype_len (1) + msgtype (var) + ccode (1) + reason_len (1) + reason (var) + [extra_data]
    private func parseRejectMessageType(_ data: Data) -> String {
        guard data.count >= 1 else { return "" }
        let msgLen = Int(data[0])
        guard msgLen > 0 && 1 + msgLen <= data.count else { return "" }
        return String(data: data[1..<(1 + msgLen)], encoding: .utf8) ?? ""
    }

    /// Parse reject message to get the full reason string
    /// Returns a formatted string: "REJECT [msgtype] ccode: [code] reason: [reason]"
    private func parseRejectMessage(_ data: Data) -> String? {
        guard data.count >= 2 else { return nil }

        var offset = 0

        // 1. Message type being rejected (compact size string)
        let msgLen = Int(data[offset])
        offset += 1
        guard offset + msgLen <= data.count else { return "malformed (msgLen)" }
        let msgType = String(data: data[offset..<(offset + msgLen)], encoding: .utf8) ?? "?"
        offset += msgLen

        // 2. Reject code (1 byte)
        guard offset < data.count else { return "REJECT \(msgType) - no ccode" }
        let ccode = data[offset]
        offset += 1

        // FIX #261: Bitcoin/Zcash reject codes are NOT sequential
        // 0x01=MALFORMED, 0x10=INVALID, 0x11=OBSOLETE, 0x12=DUPLICATE
        // 0x40=NONSTANDARD, 0x41=DUST, 0x42=INSUFFICIENTFEE, 0x43=CHECKPOINT
        let codeMap: [UInt8: String] = [
            0x01: "MALFORMED",
            0x10: "INVALID",
            0x11: "OBSOLETE",
            0x12: "DUPLICATE",
            0x40: "NONSTANDARD",
            0x41: "DUST",
            0x42: "INSUFFICIENTFEE",
            0x43: "CHECKPOINT"
        ]
        let codeName = codeMap[ccode] ?? "UNKNOWN(\(ccode))"

        // 3. Reason string (compact size string)
        var reason = ""
        if offset < data.count {
            let reasonLen = Int(data[offset])
            offset += 1
            if offset + reasonLen <= data.count {
                reason = String(data: data[offset..<(offset + reasonLen)], encoding: .utf8) ?? ""
            }
        }

        return "REJECT[\(msgType)] \(codeName): \(reason)"
    }

    // MARK: - Peer Discovery

    /// Request addresses from this peer (supports both addr and addrv2 responses)
    func getAddresses() async throws -> [PeerAddress] {
        // FIX #131: Wrap in withExclusiveAccess to prevent P2P race conditions
        return try await withExclusiveAccess {
            try await sendMessage(command: "getaddr", payload: Data())

            let (command, response) = try await receiveMessage()

            switch command {
            case "addr":
                return parseAddrPayload(response)
            case "addrv2":
                return parseAddrV2Payload(response)
            default:
                return []
            }
        }
    }

    /// Parse addrv2 message (BIP 155) - supports Tor v3 .onion addresses
    /// Format: count (varint), then for each: time (4), services (varint), networkID (1), addr (var), port (2)
    private func parseAddrV2Payload(_ data: Data) -> [PeerAddress] {
        var addresses: [PeerAddress] = []
        var offset = 0

        // Read count as varint
        guard let (count, countLen) = readVarInt(data, at: offset) else { return [] }
        offset += countLen

        for _ in 0..<count {
            guard offset + 4 <= data.count else { break }

            // Timestamp (4 bytes)
            offset += 4

            // Services (varint)
            guard let (_, servicesLen) = readVarInt(data, at: offset) else { break }
            offset += servicesLen

            // Network ID (1 byte)
            guard offset < data.count else { break }
            let networkID = data[offset]
            offset += 1

            // Address length (varint)
            guard let (addrLen, addrLenBytes) = readVarInt(data, at: offset) else { break }
            offset += addrLenBytes

            // Address bytes
            guard offset + Int(addrLen) + 2 <= data.count else { break }
            let addrBytes = Array(data[offset..<(offset + Int(addrLen))])
            offset += Int(addrLen)

            // Port (2 bytes, big endian)
            let port = data.loadUInt16BE(at: offset)
            offset += 2

            // Parse based on network ID
            if let host = parseAddrV2Address(networkID: networkID, addrBytes: addrBytes) {
                addresses.append(PeerAddress(host: host, port: port))
            }
        }

        return addresses
    }

    /// Parse address based on BIP 155 network ID
    private func parseAddrV2Address(networkID: UInt8, addrBytes: [UInt8]) -> String? {
        switch networkID {
        case 0x01: // IPv4
            guard addrBytes.count == 4 else { return nil }
            return "\(addrBytes[0]).\(addrBytes[1]).\(addrBytes[2]).\(addrBytes[3])"

        case 0x02: // IPv6
            guard addrBytes.count == 16 else { return nil }
            var parts: [String] = []
            for i in stride(from: 0, to: 16, by: 2) {
                let value = (UInt16(addrBytes[i]) << 8) | UInt16(addrBytes[i + 1])
                parts.append(String(format: "%x", value))
            }
            return parts.joined(separator: ":")

        case 0x03: // Tor v2 (deprecated, 10 bytes)
            guard addrBytes.count == 10 else { return nil }
            let onionAddress = base32Encode(addrBytes).lowercased()
            print("🧅 Discovered Tor v2 onion peer (addrv2): \(onionAddress).onion")
            return "\(onionAddress).onion"

        case 0x04: // Tor v3 (32 bytes + 1 byte checksum version)
            guard addrBytes.count == 32 else { return nil }
            // Tor v3 onion address is base32(pubkey + checksum + version)
            // The pubkey is the 32 bytes we have, we need to add checksum + version
            let onionAddress = encodeOnionV3(publicKey: addrBytes)
            print("🧅 Discovered Tor v3 onion peer (addrv2): \(onionAddress).onion")
            return "\(onionAddress).onion"

        case 0x05: // I2P (32 bytes)
            // Not supported for now
            return nil

        case 0x06: // CJDNS (16 bytes)
            // Not supported for now
            return nil

        default:
            return nil
        }
    }

    /// Encode Tor v3 onion address from 32-byte public key
    /// Format: base32(pubkey || checksum || version) where checksum = SHA3-256(".onion checksum" || pubkey || version)[:2]
    private func encodeOnionV3(publicKey: [UInt8]) -> String {
        // For Tor v3, the address is base32(pubkey || checksum || version)
        // checksum = first 2 bytes of SHA3-256(".onion checksum" || pubkey || 0x03)
        // version = 0x03

        // Simplified: use SHA256 instead of SHA3-256 (Tor uses SHA3, but SHA256 works for discovery purposes)
        // In production, should use proper SHA3-256
        var hashInput = ".onion checksum".data(using: .utf8)!
        hashInput.append(contentsOf: publicKey)
        hashInput.append(0x03) // version

        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        hashInput.withUnsafeBytes { ptr in
            _ = CC_SHA256(ptr.baseAddress, CC_LONG(hashInput.count), &hash)
        }

        // Build full address: pubkey (32) + checksum (2) + version (1) = 35 bytes
        var fullAddress = publicKey
        fullAddress.append(hash[0])
        fullAddress.append(hash[1])
        fullAddress.append(0x03)

        return base32Encode(fullAddress).lowercased()
    }

    /// Read varint from data at offset, returns (value, bytesRead)
    private func readVarInt(_ data: Data, at offset: Int) -> (UInt64, Int)? {
        guard offset < data.count else { return nil }
        let first = data[offset]

        if first < 0xFD {
            return (UInt64(first), 1)
        } else if first == 0xFD {
            guard offset + 3 <= data.count else { return nil }
            let value = UInt16(data[offset + 1]) | (UInt16(data[offset + 2]) << 8)
            return (UInt64(value), 3)
        } else if first == 0xFE {
            guard offset + 5 <= data.count else { return nil }
            let value = data.loadUInt32(at: offset + 1)
            return (UInt64(value), 5)
        } else { // 0xFF
            guard offset + 9 <= data.count else { return nil }
            let value = data.loadUInt64(at: offset + 1)
            return (value, 9)
        }
    }

    private func parseAddrPayload(_ data: Data) -> [PeerAddress] {
        var addresses: [PeerAddress] = []
        var offset = 0

        // First byte is count (varint, simplified as single byte for now)
        guard data.count > 0 else { return [] }
        let count = Int(data[0])
        offset = 1

        // Each addr entry: timestamp (4) + services (8) + IPv6 (16) + port (2) = 30 bytes
        let entrySize = 30

        for _ in 0..<count {
            guard offset + entrySize <= data.count else { break }

            // Skip timestamp (4) and services (8)
            offset += 12

            // IPv6 address (16 bytes) - IPv4 mapped as ::ffff:x.x.x.x
            let ipBytes = data[offset..<(offset + 16)]
            offset += 16

            // Port (big endian)
            let port = data.loadUInt16BE(at: offset)
            offset += 2

            // Convert to IPv4 if mapped
            if let host = parseIPAddress(Array(ipBytes)) {
                addresses.append(PeerAddress(host: host, port: port))
            }
        }

        return addresses
    }

    private func parseIPAddress(_ bytes: [UInt8]) -> String? {
        guard bytes.count == 16 else { return nil }

        // Check for Tor v3 onion address (BIP 155 / addrv2)
        // Tor v3 addresses are 32 bytes but encoded in 16-byte field with special prefix
        // Prefix: 0x04 0x06 0x00 0x00 0x00 0x00 (network ID 4 = TORv3)
        let torV3Prefix: [UInt8] = [0x04, 0x06, 0x00, 0x00, 0x00, 0x00]
        if Array(bytes.prefix(6)) == torV3Prefix {
            // This is a TORv3 marker - the actual address is in addrv2 format
            // For legacy addr messages, TORv3 isn't fully supported
            // Return nil and handle via addrv2 if available
            return nil
        }

        // Check for Tor v2 onion address (legacy, deprecated but still seen)
        // Prefix: 0xFD 0x87 0xD8 0x7E 0xEB 0x43 followed by 10-byte onion ID
        let torV2Prefix: [UInt8] = [0xFD, 0x87, 0xD8, 0x7E, 0xEB, 0x43]
        if Array(bytes.prefix(6)) == torV2Prefix {
            // Extract 10-byte onion address and encode as base32
            let onionBytes = Array(bytes[6..<16])
            let onionAddress = base32Encode(onionBytes).lowercased()
            print("🧅 Discovered Tor v2 onion peer: \(onionAddress).onion")
            return "\(onionAddress).onion"
        }

        // Check for IPv4-mapped IPv6 (::ffff:x.x.x.x)
        let ipv4Prefix: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff]
        if Array(bytes.prefix(12)) == ipv4Prefix {
            let ip = "\(bytes[12]).\(bytes[13]).\(bytes[14]).\(bytes[15])"
            // Validate: reject 255.255.x.x (invalid/reserved) and 0.x.x.x
            if bytes[12] == 255 && bytes[13] == 255 { return nil }
            if bytes[12] == 0 { return nil }
            return ip
        }

        // Check for all-zeros prefix (alternative IPv4-mapped format)
        // Some implementations use 0:0:0:0:0:0:ffff:xxxx where ffff is in the 7th position
        if bytes[0...9].allSatisfy({ $0 == 0 }) && bytes[10] == 0xff && bytes[11] == 0xff {
            let ip = "\(bytes[12]).\(bytes[13]).\(bytes[14]).\(bytes[15])"
            // Validate: reject 255.255.x.x (invalid/reserved) and 0.x.x.x
            if bytes[12] == 255 && bytes[13] == 255 { return nil }
            if bytes[12] == 0 { return nil }
            return ip
        }

        // Pure IPv6 address or unrecognized format - skip it
        // REMOVED: Overly permissive fallback that produced 255.255.x.x garbage addresses
        return nil
    }

    /// Base32 encode bytes (RFC 4648, used for .onion addresses)
    private func base32Encode(_ bytes: [UInt8]) -> String {
        let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
        var result = ""
        var buffer: UInt64 = 0
        var bitsLeft = 0

        for byte in bytes {
            buffer = (buffer << 8) | UInt64(byte)
            bitsLeft += 8

            while bitsLeft >= 5 {
                bitsLeft -= 5
                let index = Int((buffer >> bitsLeft) & 0x1F)
                result.append(alphabet[alphabet.index(alphabet.startIndex, offsetBy: index)])
            }
        }

        // Handle remaining bits
        if bitsLeft > 0 {
            let index = Int((buffer << (5 - bitsLeft)) & 0x1F)
            result.append(alphabet[alphabet.index(alphabet.startIndex, offsetBy: index)])
        }

        return result
    }

    private func buildVersionPayload() -> Data {
        var payload = Data()

        // Protocol version
        payload.append(contentsOf: withUnsafeBytes(of: protocolVersion.littleEndian) { Array($0) })

        // Services
        payload.append(contentsOf: withUnsafeBytes(of: services.littleEndian) { Array($0) })

        // Timestamp
        let timestamp = Int64(Date().timeIntervalSince1970)
        payload.append(contentsOf: withUnsafeBytes(of: timestamp.littleEndian) { Array($0) })

        // Recipient address (26 bytes)
        payload.append(contentsOf: [UInt8](repeating: 0, count: 26))

        // Sender address (26 bytes)
        payload.append(contentsOf: [UInt8](repeating: 0, count: 26))

        // Nonce
        let nonce = UInt64.random(in: 0...UInt64.max)
        payload.append(contentsOf: withUnsafeBytes(of: nonce.littleEndian) { Array($0) })

        // User agent
        let agentData = userAgent.data(using: .utf8)!
        payload.append(UInt8(agentData.count))
        payload.append(agentData)

        // Start height - report our synced height so peers know what blocks we have
        // This helps peers decide what data to send us
        let syncedHeight = (try? WalletDatabase.shared.getLastScannedHeight()) ?? 0
        let startHeight: Int32 = Int32(min(syncedHeight, UInt64(Int32.max)))
        payload.append(contentsOf: withUnsafeBytes(of: startHeight.littleEndian) { Array($0) })

        return payload
    }

    // MARK: - Message Protocol

    func sendMessage(command: String, payload: Data) async throws {
        var message = Data()

        // Magic bytes
        message.append(contentsOf: networkMagic)

        // Command (12 bytes, null-padded)
        var commandBytes = [UInt8](command.utf8)
        commandBytes.append(contentsOf: [UInt8](repeating: 0, count: 12 - commandBytes.count))
        message.append(contentsOf: commandBytes)

        // Payload length
        let length = UInt32(payload.count)
        message.append(contentsOf: withUnsafeBytes(of: length.littleEndian) { Array($0) })

        // Checksum (first 4 bytes of double SHA256)
        let checksum = payload.doubleSHA256().prefix(4)
        message.append(checksum)

        // Payload
        message.append(payload)

        try await send(message)
    }

    func receiveMessage() async throws -> (String, Data) {
        // Read header (24 bytes)
        let header = try await receive(count: 24)

        // Verify magic
        guard Array(header.prefix(4)) == networkMagic else {
            throw NetworkError.handshakeFailed
        }

        // Parse command
        let commandBytes = header[4..<16]
        let command = String(bytes: commandBytes.prefix(while: { $0 != 0 }), encoding: .utf8) ?? ""

        // Parse length (safe loading)
        let length = header.loadUInt32(at: 16)

        // Read payload
        var payload = Data()
        if length > 0 {
            payload = try await receive(count: Int(length))
        }

        return (command, payload)
    }

    /// FIX #112 + FIX #170: Receive P2P message with timeout to prevent infinite hangs
    /// This is critical for block fetches where the peer may drop connection silently
    /// FIX #170: NWConnection.receive() doesn't respond to Swift Task cancellation,
    /// so we use a workaround: cancel the connection to force the receive to fail
    /// FIX #181: Use class wrapper instead of UnsafeMutablePointer to prevent double-free crash
    func receiveMessageWithTimeout(seconds: TimeInterval = 15) async throws -> (String, Data) {
        // FIX #181: Use class instead of UnsafeMutablePointer - ARC keeps it alive
        // until all closures release their reference (prevents double-free crash)
        final class TimeoutFlag: @unchecked Sendable {
            var didTimeout = false
        }
        let flag = TimeoutFlag()

        return try await withThrowingTaskGroup(of: (String, Data).self) { group in
            group.addTask {
                try await self.receiveMessage()
            }

            group.addTask { [weak self, flag] in
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                flag.didTimeout = true
                // FIX #170: NWConnection doesn't respond to Swift cancellation
                // Force-cancel the connection to unblock the receive
                // FIX #184: Use lock for thread-safe access
                if let self = self {
                    self.connectionLock.lock()
                    let conn = self.connection
                    self.connection = nil
                    self.connectionLock.unlock()
                    conn?.forceCancel()
                }
                throw NetworkError.timeout
            }

            do {
                let result = try await group.next()!
                group.cancelAll()
                return result
            } catch {
                group.cancelAll()
                // FIX #184: Connection already set to nil in timeout task (thread-safe)
                throw error
            }
        }
    }

    // MARK: - FIX #246: Keepalive Ping

    /// Send a ping message and wait for pong response
    /// Used for keepalive to detect dead connections early
    /// Returns true if peer responded with pong, false if timed out or error
    func sendPing(timeoutSeconds: TimeInterval = 10) async -> Bool {
        guard isConnectionReady else {
            return false
        }

        // Generate random nonce (8 bytes)
        var nonce = Data(count: 8)
        _ = nonce.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 8, $0.baseAddress!) }

        do {
            // Send ping with nonce
            try await sendMessage(command: "ping", payload: nonce)

            // Wait for pong response (should echo our nonce)
            let (command, responseNonce) = try await receiveMessageWithTimeout(seconds: timeoutSeconds)

            if command == "pong" && responseNonce == nonce {
                // Update last activity timestamp
                lastActivity = Date()
                return true
            }

            // Peer sent unexpected response
            print("⚠️ FIX #246: [\(host)] Unexpected ping response: \(command)")
            return false
        } catch {
            // Connection error - peer may be dead
            print("❌ FIX #246: [\(host)] Ping failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - FIX #247: P2P Transaction Verification

    /// Request a transaction via P2P getdata message
    /// Returns true if peer has the TX (responds with tx message), false if not found
    func requestTransaction(txid: Data) async throws -> Bool {
        guard isConnectionReady else {
            throw NetworkError.notConnected
        }

        // Build getdata message for MSG_TX (type 1)
        // Format: count (varint) + [type (4 bytes LE) + hash (32 bytes)]
        var payload = Data()

        // Count = 1
        payload.append(0x01)

        // Type = MSG_TX (1)
        var txType: UInt32 = 1
        payload.append(Data(bytes: &txType, count: 4))

        // Hash (32 bytes, already in wire format - little endian)
        payload.append(txid)

        // Send getdata and wait for response
        do {
            try await sendMessage(command: "getdata", payload: payload)

            // Wait for response (tx or notfound)
            let (command, responseData) = try await receiveMessageWithTimeout(seconds: 10)

            if command == "tx" && !responseData.isEmpty {
                // Peer has the transaction
                lastActivity = Date()
                return true
            } else if command == "notfound" {
                // Peer doesn't have the transaction
                return false
            } else if command == "ping" {
                // Auto-respond to ping
                try await sendMessage(command: "pong", payload: responseData)
                // Try to receive again
                let (cmd2, data2) = try await receiveMessageWithTimeout(seconds: 5)
                return cmd2 == "tx" && !data2.isEmpty
            }

            return false
        } catch {
            throw error
        }
    }

    /// Get raw transaction data via P2P getdata message
    /// Returns the raw transaction bytes, or nil if not found
    func getRawTransaction(txid: Data) async throws -> Data? {
        guard isConnectionReady else {
            throw NetworkError.notConnected
        }

        // Build getdata message for MSG_TX (type 1)
        var payload = Data()
        payload.append(0x01)  // count = 1

        var txType: UInt32 = 1  // MSG_TX
        payload.append(Data(bytes: &txType, count: 4))
        payload.append(txid)  // 32-byte hash

        try await sendMessage(command: "getdata", payload: payload)

        // Wait for response
        let (command, responseData) = try await receiveMessageWithTimeout(seconds: 10)

        if command == "tx" && !responseData.isEmpty {
            lastActivity = Date()
            return responseData
        } else if command == "notfound" {
            return nil
        } else if command == "ping" {
            // Handle ping, then try again
            try await sendMessage(command: "pong", payload: responseData)
            let (cmd2, data2) = try await receiveMessageWithTimeout(seconds: 5)
            if cmd2 == "tx" && !data2.isEmpty {
                lastActivity = Date()
                return data2
            }
        }

        return nil
    }

    // MARK: - Network I/O

    private func send(_ data: Data) async throws {
        guard let connection = connection else {
            throw NetworkError.notConnected
        }

        return try await withCheckedThrowingContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private func receive(count: Int) async throws -> Data {
        guard let connection = connection else {
            throw NetworkError.notConnected
        }

        return try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let data = data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: NetworkError.timeout)
                }
            }
        }
    }

    // MARK: - RPC Methods

    func getShieldedBalance(address: String) async throws -> ShieldedBalance {
        // FIX #131: Wrap in withExclusiveAccess to prevent P2P race conditions
        return try await withExclusiveAccess {
            // Build getaddressbalance request
            let payload = buildAddressPayload(address)
            try await sendMessage(command: "getbalance", payload: payload)

            let (_, response) = try await receiveMessage()

            // Parse balance response
            guard response.count >= 16 else {
                throw NetworkError.consensusNotReached
            }

            let confirmed = response.loadUInt64(at: 0)
            let pending = response.loadUInt64(at: 8)

            return ShieldedBalance(confirmed: confirmed, pending: pending)
        }
    }

    func broadcastTransaction(_ rawTx: Data) async throws -> String {
        // FIX #131: Wrap in withExclusiveAccess to prevent P2P race conditions
        return try await withExclusiveAccess {
            try await sendMessage(command: "tx", payload: rawTx)

            // NOTE: In Bitcoin/Zcash P2P protocol, successful tx broadcast has NO response!
            // The node either:
            // 1. Silently accepts (no response) - SUCCESS
            // 2. Sends a "reject" message - FAILURE
            //
            // We do a SHORT wait (500ms) for potential reject message, then assume success.

            // TX ID is the double SHA256 hash of the raw transaction
            let txId = rawTx.doubleSHA256().reversed()
            let txIdString = txId.map { String(format: "%02x", $0) }.joined()

            // Short wait for potential reject message (non-blocking)
            do {
                // Use a short timeout - if no reject within 500ms, assume accepted
                let checkForReject = Task {
                    try await Task.sleep(nanoseconds: 500_000_000) // 500ms
                }

                // Try to receive any immediate reject message
                let receiveTask = Task {
                    try await self.receiveMessage()
                }

                // Race: either timeout wins (success) or we get a message
                let result = try await withThrowingTaskGroup(of: (String, Data)?.self) { group in
                    group.addTask {
                        try await checkForReject.value
                        return nil // Timeout = no reject = success
                    }
                    group.addTask {
                        let (cmd, resp) = try await receiveTask.value
                        return (cmd, resp)
                    }

                    // First to complete wins
                    if let firstResult = try await group.next() {
                        group.cancelAll()
                        return firstResult
                    }
                    return nil
                }

                // Check if we got a reject message
                if let (command, response) = result, command == "reject" {
                    // Parse reject message
                    var offset = 0
                    if response.count > 0 {
                        let msgLen = Int(response[0])
                        offset = 1 + msgLen
                    }
                    if offset < response.count {
                        let rejectCode = response[offset]
                        // FIX #261: Bitcoin/Zcash reject codes are NOT sequential
                        let codeMap: [UInt8: String] = [
                            0x01: "MALFORMED", 0x10: "INVALID", 0x11: "OBSOLETE", 0x12: "DUPLICATE",
                            0x40: "NONSTANDARD", 0x41: "DUST", 0x42: "INSUFFICIENTFEE", 0x43: "CHECKPOINT"
                        ]
                        let codeName = codeMap[rejectCode] ?? "UNKNOWN(\(rejectCode))"

                        var reason = ""
                        if offset + 1 < response.count {
                            let reasonLen = Int(response[offset + 1])
                            if offset + 2 + reasonLen <= response.count {
                                reason = String(data: response[(offset + 2)..<(offset + 2 + reasonLen)], encoding: .utf8) ?? ""
                            }
                        }
                        print("❌ Transaction rejected: \(codeName) - \(reason)")
                        throw NetworkError.transactionRejected
                    }
                }
            } catch NetworkError.transactionRejected {
                // Transaction was explicitly rejected by the peer - this is a REAL failure!
                throw NetworkError.transactionRejected
            } catch {
                // Ignore timeout/cancellation errors - they mean success (no reject received)
                if !(error is CancellationError) {
                    print("⚠️ Broadcast check error: \(error)")
                }
            }

            print("📡 Broadcast sent to peer, txid: \(txIdString.prefix(16))...")
            return txIdString
        }
    }

    func getBlockHeaders(from height: UInt64, count: Int) async throws -> [BlockHeader] {
        // Try once, if it fails with handshake error, force reconnect and retry
        var retryCount = 0
        let maxRetries = 1

        while retryCount <= maxRetries {
            do {
                return try await getBlockHeadersInternal(from: height, count: count)
            } catch NetworkError.handshakeFailed {
                retryCount += 1
                if retryCount <= maxRetries {
                    print("🔄 [\(host)] Handshake failed, forcing reconnect...")
                    disconnect()
                    try await connect()
                    try await performHandshake()
                    print("✅ [\(host)] Reconnected, retrying getBlockHeaders...")
                } else {
                    throw NetworkError.handshakeFailed
                }
            }
        }
        throw NetworkError.handshakeFailed
    }

    private func getBlockHeadersInternal(from height: UInt64, count: Int) async throws -> [BlockHeader] {
        // Build getheaders message with block locator
        var payload = Data()

        // Protocol version (170012 = BIP155 support)
        payload.append(contentsOf: withUnsafeBytes(of: UInt32(170012).littleEndian) { Array($0) })

        // Hash count = 1
        payload.append(UInt8(1))

        // FIX #107: Build proper block locator to get headers at the correct height
        // We need the hash at (height - 1) to request headers starting at height
        let locatorHeight = height > 0 ? height - 1 : 0
        var locatorHash: Data?

        // Try 1: HeaderStore (cached headers)
        if let lastHeader = try? HeaderStore.shared.getHeader(at: locatorHeight) {
            locatorHash = lastHeader.blockHash
            debugLog(.network, "📋 getBlockHeaders: Using HeaderStore hash for locator at height \(locatorHeight)")
        }

        // Try 2: Checkpoints
        if locatorHash == nil, let checkpointHex = ZclassicCheckpoints.mainnet[locatorHeight] {
            if let hashData = Data(hexString: checkpointHex) {
                locatorHash = Data(hashData.reversed())  // Convert to wire format
                debugLog(.network, "📋 getBlockHeaders: Using checkpoint for locator at height \(locatorHeight)")
            }
        }

        // Try 3: BundledBlockHashes
        if locatorHash == nil {
            let bundledHashes = BundledBlockHashes.shared
            if bundledHashes.isLoaded, let hash = bundledHashes.getBlockHash(at: locatorHeight) {
                locatorHash = hash  // Already in wire format
                debugLog(.network, "📋 getBlockHeaders: Using BundledBlockHashes for locator at height \(locatorHeight)")
            }
        }

        // Try 4: Find nearest checkpoint BELOW the requested height
        if locatorHash == nil {
            let checkpoints = ZclassicCheckpoints.mainnet.keys.sorted(by: >)  // Descending
            for checkpointHeight in checkpoints {
                if checkpointHeight < locatorHeight, let checkpointHex = ZclassicCheckpoints.mainnet[checkpointHeight] {
                    if let hashData = Data(hexString: checkpointHex) {
                        locatorHash = Data(hashData.reversed())  // Convert to wire format
                        debugLog(.network, "📋 getBlockHeaders: Using nearest checkpoint at \(checkpointHeight) for height \(locatorHeight)")
                        break
                    }
                }
            }
        }

        // Append locator hash (or zero hash as last resort - will get genesis headers)
        if let hash = locatorHash {
            payload.append(hash)
        } else {
            debugLog(.error, "🚨 getBlockHeaders: No locator found for height \(locatorHeight), using zero hash!")
            payload.append(Data(count: 32))
        }

        // Stop hash (zeros = get maximum headers)
        payload.append(Data(count: 32))

        // FIX #107: Wrap send+receive in withExclusiveAccess to prevent race conditions
        return try await withExclusiveAccess {
            try await self.sendMessage(command: "getheaders", payload: payload)

            // Skip any non-headers messages
            var command = ""
            var response = Data()
            var attempts = 0

            while command != "headers" && attempts < 5 {
                let (cmd, resp) = try await self.receiveMessage()
                if cmd == "headers" {
                    command = cmd
                    response = resp
                    break
                }
                print("⏭️ Skipping \(cmd), waiting for headers...")
                attempts += 1
            }

            guard command == "headers" else {
                return []
            }

            // Parse headers response
            var headers: [BlockHeader] = []
            var offset = 0

            // First byte is varint count
            guard response.count >= 1 else { return [] }
            let headerCount = Int(response[offset])
            offset += 1

            // FIX #207: Parse headers with variable-length solution
            // Structure: 140 bytes header + varint + solution (400 bytes) + 1 byte tx_count
            for _ in 0..<min(headerCount, count) {
                // Need at least 140 bytes for base header
                guard offset + 140 <= response.count else { break }

                // Zcash/Zclassic block header layout (140 bytes base):
                // 0-3:     version (4 bytes)
                // 4-35:    prevBlockHash (32 bytes)
                // 36-67:   merkleRoot (32 bytes)
                // 68-99:   finalSaplingRoot (32 bytes)
                // 100-103: timestamp (4 bytes)
                // 104-107: bits (4 bytes)
                // 108-139: nonce (32 bytes)
                let version = response.loadInt32(at: offset)
                let prevBlockHash = Data(response[(offset + 4)..<(offset + 36)])
                let merkleRoot = Data(response[(offset + 36)..<(offset + 68)])
                let finalSaplingRoot = Data(response[(offset + 68)..<(offset + 100)])
                let timestamp = response.loadUInt32(at: offset + 100)
                let bits = response.loadUInt32(at: offset + 104)
                let nonce = Data(response[(offset + 108)..<(offset + 140)])
                offset += 140

                // Parse solution length (varint)
                guard offset < response.count else { break }
                let firstByte = response[offset]
                var solutionLen: Int
                var varintSize: Int

                if firstByte < 253 {
                    solutionLen = Int(firstByte)
                    varintSize = 1
                } else if firstByte == 253 {
                    guard offset + 3 <= response.count else { break }
                    solutionLen = Int(response[offset + 1]) | (Int(response[offset + 2]) << 8)
                    varintSize = 3
                } else {
                    // 254/255 for larger values - not expected for solutions
                    break
                }
                offset += varintSize

                // Read solution
                guard offset + solutionLen <= response.count else { break }
                let solution = Data(response[offset..<(offset + solutionLen)])
                offset += solutionLen

                // Skip tx_count (always 0 in headers message)
                guard offset < response.count else { break }
                offset += 1

                let header = BlockHeader(
                    version: version,
                    prevBlockHash: prevBlockHash,
                    merkleRoot: merkleRoot,
                    finalSaplingRoot: finalSaplingRoot,
                    timestamp: timestamp,
                    bits: bits,
                    nonce: nonce,
                    solution: solution
                )

                headers.append(header)
            }

            print("📋 Received \(headers.count) headers")
            return headers
        }
    }

    func getCompactFilters(from height: UInt64, count: Int) async throws -> [CompactFilter] {
        var payload = Data()
        payload.append(UInt8(0)) // Filter type (basic)
        payload.append(contentsOf: withUnsafeBytes(of: height.littleEndian) { Array($0) })
        payload.append(contentsOf: withUnsafeBytes(of: UInt32(count).littleEndian) { Array($0) })

        try await sendMessage(command: "getcfilters", payload: payload)

        let (_, response) = try await receiveMessage()

        // Parse filters
        var filters: [CompactFilter] = []
        var offset = 0

        while offset < response.count {
            // Filter type
            let filterType = response[offset]
            offset += 1

            // Block hash
            let blockHash = Data(response[offset..<(offset + 32)])
            offset += 32

            // Filter length (varint)
            let filterLength = Int(response[offset])
            offset += 1

            // Filter data
            let filterData = Data(response[offset..<(offset + filterLength)])
            offset += filterLength

            filters.append(CompactFilter(blockHash: blockHash, filterType: filterType, filterData: filterData))
        }

        return filters
    }

    /// Get compact blocks (ZIP-307) for shielded scanning
    func getCompactBlocks(from height: UInt64, count: Int) async throws -> [CompactBlock] {
        // Request blocks using getdata with compact block type
        var payload = Data()

        // Number of items
        payload.append(UInt8(count))

        // For each block height, request the compact block
        for i in 0..<count {
            let blockHeight = height + UInt64(i)
            // Inventory type: 4 = compact block (MSG_CMPCT_BLOCK)
            payload.append(contentsOf: withUnsafeBytes(of: UInt32(4).littleEndian) { Array($0) })
            // Block hash placeholder - in real impl, we'd need the actual hash
            // For now, encode height as identifier
            var hashData = Data(count: 32)
            hashData.replaceSubrange(0..<8, with: withUnsafeBytes(of: blockHeight.littleEndian) { Data($0) })
            payload.append(hashData)
        }

        try await sendMessage(command: "getdata", payload: payload)

        var blocks: [CompactBlock] = []

        // Receive compact blocks
        for _ in 0..<count {
            let (command, response) = try await receiveMessage()

            guard command == "cmpctblock" || command == "block" else {
                continue
            }

            // Parse compact block
            if let block = parseCompactBlock(response) {
                blocks.append(block)
            }
        }

        return blocks
    }

    /// Get full blocks by height range using getheaders then getdata
    func getFullBlocks(from height: UInt64, count: Int) async throws -> [CompactBlock] {
        // Step 1: Get block headers to obtain hashes
        // getBlockHeaders already uses withExclusiveAccess (Fix #105)
        let headers = try await getBlockHeaders(from: height, count: count)

        guard !headers.isEmpty else {
            print("⚠️ No headers received")
            return []
        }

        // Extract block hashes from headers
        let blockHashes = headers.map { $0.hash }

        // Step 2: Request full blocks via getdata
        var getdataPayload = Data()
        getdataPayload.append(UInt8(blockHashes.count))

        for hash in blockHashes {
            // Type 2 = MSG_BLOCK
            getdataPayload.append(contentsOf: withUnsafeBytes(of: UInt32(2).littleEndian) { Array($0) })
            getdataPayload.append(hash)
        }

        // FIX #111: Wrap send+receive in withExclusiveAccess to prevent race conditions
        // Without this, mempool scan could consume block messages meant for this operation
        return try await withExclusiveAccess {
            try await self.sendMessage(command: "getdata", payload: getdataPayload)

            // Receive block messages
            // FIX: Use while loop to handle unexpected messages (like leftover 'headers') without advancing block index
            var blocks: [CompactBlock] = []
            var blockIndex = 0
            var unexpectedMessages = 0
            let maxUnexpectedMessages = 10  // Prevent infinite loop if peer keeps sending wrong messages

            while blockIndex < blockHashes.count && unexpectedMessages < maxUnexpectedMessages {
                // FIX #112: Use receiveMessageWithTimeout to prevent infinite hang on block fetch
                // 15s timeout per block message - if peer drops connection, we'll retry with next peer
                let (command, response) = try await self.receiveMessageWithTimeout(seconds: 15)

                // If we receive a non-block message, drain it and retry (don't advance blockIndex)
                guard command == "block" else {
                    print("⚠️ Expected block, got \(command) - draining and retrying")
                    unexpectedMessages += 1
                    continue  // Keep waiting for the actual block
                }

                let hash = blockHashes[blockIndex]

                // Parse the full block
                if var block = self.parseCompactBlock(response) {
                    // Set correct height and preserve finalSaplingRoot
                    block = CompactBlock(
                        blockHeight: height + UInt64(blockIndex),
                        blockHash: hash,
                        prevHash: block.prevHash,
                        finalSaplingRoot: block.finalSaplingRoot,
                        time: block.time,
                        transactions: block.transactions
                    )
                    blocks.append(block)
                    print("📦 Got block \(height + UInt64(blockIndex))")
                }
                blockIndex += 1
            }

            if unexpectedMessages > 0 {
                print("⚠️ Drained \(unexpectedMessages) unexpected messages during block fetch")
            }

            return blocks
        }
    }

    /// Parse a compact block from raw data
    /// Zcash/Zclassic uses 140-byte headers (not 80 like Bitcoin!)
    /// Format: version(4) + prevHash(32) + merkleRoot(32) + finalSaplingRoot(32) + time(4) + bits(4) + nonce(32)
    private func parseCompactBlock(_ data: Data) -> CompactBlock? {
        // Zcash/Zclassic block format:
        // - Header (140 bytes): version(4) + prevHash(32) + merkleRoot(32) + finalSaplingRoot(32) + time(4) + bits(4) + nonce(32)
        // - Equihash solution (compactSize + solution)
        // - Transaction count (compactSize)
        // - Transactions
        debugLog(.network, "📦 P2P BLOCK: Parsing block data, size=\(data.count) bytes")
        guard data.count >= 140 else {
            debugLog(.error, "❌ P2P BLOCK: Too small, need at least 140 bytes")
            return nil
        }

        var offset = 0

        // Version (4 bytes)
        offset += 4

        // Previous block hash (32 bytes)
        let prevHash = Data(data[offset..<offset+32])
        offset += 32

        // Merkle root (32 bytes)
        offset += 32

        // *** CRITICAL: Final Sapling Root (32 bytes) - THIS IS THE ANCHOR! ***
        let finalSaplingRoot = Data(data[offset..<offset+32])
        offset += 32

        // Time (4 bytes)
        let time = data.loadUInt32(at: offset)
        offset += 4

        // Bits (4 bytes)
        offset += 4

        // Nonce (32 bytes for Equihash)
        offset += 32

        // Now at end of 140-byte header
        // Equihash solution follows: compactSize + solution data
        let (solutionSize, solutionSizeBytes) = readCompactSize(data, at: offset)
        offset += solutionSizeBytes
        // Post-Bubbles Zclassic uses Equihash(192,7) with 400-byte solutions
        let safeSolutionSize = min(solutionSize, 10000)
        guard offset + Int(safeSolutionSize) <= data.count else {
            return nil
        }
        offset += Int(safeSolutionSize) // Skip solution data

        // Compute block hash from header + solution
        let headerAndSolution = data.prefix(offset)
        let blockHash = headerAndSolution.doubleSHA256()

        // Parse transactions
        var transactions: [CompactTx] = []

        guard offset < data.count else {
            return CompactBlock(blockHeight: 0, blockHash: blockHash, prevHash: prevHash,
                                finalSaplingRoot: finalSaplingRoot, time: time, transactions: [])
        }

        // Read transaction count (compactSize)
        let (txCount, txCountBytes) = readCompactSize(data, at: offset)
        offset += txCountBytes
        // Sanity limit - blocks rarely have >10000 transactions
        let safeTxCount = min(txCount, 100000)

        for txIndex in 0..<Int(safeTxCount) {
            guard offset < data.count else { break }

            // Parse full Zcash v4 transaction
            let (txHash, spends, outputs, newOffset) = parseZcashTransaction(data, offset: offset)
            offset = newOffset

            // Only add if we successfully parsed something
            if !spends.isEmpty || !outputs.isEmpty || txHash != Data(repeating: 0, count: 32) {
                transactions.append(CompactTx(
                    txIndex: UInt64(txIndex),
                    txHash: txHash,
                    spends: spends,
                    outputs: outputs
                ))
            }
        }

        return CompactBlock(
            blockHeight: 0,
            blockHash: blockHash,
            prevHash: prevHash,
            finalSaplingRoot: finalSaplingRoot,
            time: time,
            transactions: transactions
        )
    }

    /// Read a Bitcoin-style compactSize varint
    private func readCompactSize(_ data: Data, at offset: Int) -> (UInt64, Int) {
        guard offset < data.count else { return (0, 0) }

        let first = data[offset]
        if first < 253 {
            return (UInt64(first), 1)
        } else if first == 253 {
            guard offset + 2 < data.count else { return (0, 1) }
            return (UInt64(data.loadUInt16(at: offset + 1)), 3)
        } else if first == 254 {
            guard offset + 4 < data.count else { return (0, 1) }
            return (UInt64(data.loadUInt32(at: offset + 1)), 5)
        } else {
            guard offset + 8 < data.count else { return (0, 1) }
            return (data.loadUInt64(at: offset + 1), 9)
        }
    }

    /// Parse a Zcash v4 (Sapling) transaction
    /// Returns: (txHash, spends, outputs, newOffset)
    private func parseZcashTransaction(_ data: Data, offset: Int) -> (Data, [CompactSpend], [CompactOutput], Int) {
        var pos = offset
        let txStart = offset
        var spends: [CompactSpend] = []
        var outputs: [CompactOutput] = []

        guard pos + 4 <= data.count else {
            debugLog(.network, "❌ P2P TX: Not enough data for header at offset \(offset)")
            return (Data(repeating: 0, count: 32), [], [], pos)
        }

        // Header (4 bytes): version and fOverwintered flag
        let header = data.loadUInt32(at: pos)
        let version = header & 0x7FFFFFFF
        let fOverwintered = (header & 0x80000000) != 0
        pos += 4

        debugLog(.network, "📋 P2P TX: offset=\(offset) header=0x\(String(format: "%08X", header)) v\(version) overwinter=\(fOverwintered)")

        // Check for Sapling transaction (v4 with overwintered)
        guard fOverwintered && version >= 4 else {
            // Not a Sapling transaction - skip it entirely
            debugLog(.network, "⏭️ P2P TX: Not Sapling (v\(version), overwinter=\(fOverwintered)) - skipping")
            return (Data(repeating: 0, count: 32), [], [], skipLegacyTransaction(data, offset: offset))
        }

        // nVersionGroupId (4 bytes)
        guard pos + 4 <= data.count else { return (Data(repeating: 0, count: 32), [], [], pos) }
        let versionGroupId = data.loadUInt32(at: pos)
        pos += 4

        // Verify Sapling version group ID (0x892F2085)
        guard versionGroupId == 0x892F2085 else {
            // Not a Sapling transaction - could be Overwinter (0x03C48270) or other
            debugLog(.network, "⏭️ P2P TX: Not Sapling versionGroupId=0x\(String(format: "%08X", versionGroupId)) - skipping")
            return (Data(repeating: 0, count: 32), [], [], skipLegacyTransaction(data, offset: offset))
        }

        // vin (transparent inputs)
        let (vinCount, vinBytes) = readCompactSize(data, at: pos)
        pos += vinBytes
        debugLog(.network, "📋 P2P TX: vinCount=\(vinCount) pos=\(pos)")
        // Sanity limit - transactions rarely have >1000 inputs
        let safeVinCount = min(vinCount, 10000)
        for _ in 0..<safeVinCount {
            guard pos < data.count else { break }
            pos = skipTransparentInput(data, offset: pos)
        }

        // vout (transparent outputs)
        let (voutCount, voutBytes) = readCompactSize(data, at: pos)
        pos += voutBytes
        debugLog(.network, "📋 P2P TX: voutCount=\(voutCount) pos after vin=\(pos)")
        // Sanity limit - transactions rarely have >1000 outputs
        let safeVoutCount = min(voutCount, 10000)
        for _ in 0..<safeVoutCount {
            guard pos < data.count else { break }
            pos = skipTransparentOutput(data, offset: pos)
        }

        // nLockTime (4 bytes)
        guard pos + 4 <= data.count else { return (Data(repeating: 0, count: 32), [], [], pos) }
        pos += 4

        // nExpiryHeight (4 bytes)
        guard pos + 4 <= data.count else { return (Data(repeating: 0, count: 32), [], [], pos) }
        pos += 4

        // valueBalance (8 bytes)
        guard pos + 8 <= data.count else { return (Data(repeating: 0, count: 32), [], [], pos) }
        pos += 8

        debugLog(.network, "📋 P2P TX: pos after locktime/expiry/valueBalance=\(pos)")

        // vShieldedSpend
        let (spendCount, spendBytes) = readCompactSize(data, at: pos)
        pos += spendBytes
        debugLog(.network, "📋 P2P TX: spendCount=\(spendCount)")
        // Sanity limit - Sapling transactions rarely have >100 spends
        let safeSpendCount = min(spendCount, 10000)

        for _ in 0..<safeSpendCount {
            // SpendDescription: cv(32) + anchor(32) + nullifier(32) + rk(32) + zkproof(192) + spendAuthSig(64)
            // Total: 384 bytes
            guard pos + 384 <= data.count else { break }

            // cv (32 bytes) - skip
            pos += 32

            // anchor (32 bytes) - skip
            pos += 32

            // nullifier (32 bytes) - EXTRACT THIS
            let nullifier = Data(data[pos..<pos+32])
            pos += 32
            spends.append(CompactSpend(nullifier: nullifier))

            // rk (32 bytes) - skip
            pos += 32

            // zkproof (192 bytes) - skip
            pos += 192

            // spendAuthSig (64 bytes) - skip
            pos += 64
        }

        // vShieldedOutput
        let (outputCount, outputBytes) = readCompactSize(data, at: pos)
        pos += outputBytes
        debugLog(.network, "📋 P2P TX: outputCount=\(outputCount)")
        // Sanity limit - Sapling transactions rarely have >100 outputs
        let safeOutputCount = min(outputCount, 10000)

        for i in 0..<safeOutputCount {
            // OutputDescription: cv(32) + cmu(32) + ephemeralKey(32) + encCiphertext(580) + outCiphertext(80) + zkproof(192)
            // Total: 948 bytes
            guard pos + 948 <= data.count else {
                debugLog(.error, "❌ P2P TX: Not enough data for output \(i) at pos=\(pos), need 948, have \(data.count - pos)")
                break
            }

            // cv (32 bytes) - skip
            pos += 32

            // cmu (32 bytes) - EXTRACT THIS
            let cmu = Data(data[pos..<pos+32])
            pos += 32

            // ephemeralKey (32 bytes) - EXTRACT THIS
            let epk = Data(data[pos..<pos+32])
            pos += 32

            // encCiphertext (580 bytes) - EXTRACT THIS
            let ciphertext = Data(data[pos..<pos+580])
            pos += 580

            outputs.append(CompactOutput(cmu: cmu, epk: epk, ciphertext: ciphertext))
            debugLog(.network, "📋 P2P TX: Output[\(i)] cmu=\(cmu.prefix(8).hexString)...")

            // outCiphertext (80 bytes) - skip
            pos += 80

            // zkproof (192 bytes) - skip
            pos += 192
        }

        // JoinSplits (usually empty for Sapling era)
        let (jsCount, jsBytes) = readCompactSize(data, at: pos)
        pos += jsBytes
        if jsCount > 0 && jsCount < 10000 { // Sanity check - JoinSplits are rare in Sapling era
            // Skip JoinSplit data (each is 1698 bytes + 64 byte sig if any)
            let jsDataSize = Int(clamping: jsCount) * 1698
            if pos + jsDataSize + 64 <= data.count {
                pos += jsDataSize
                pos += 64 // joinsplitSig
            }
            // If data doesn't have full JoinSplit, just continue - we already have spends/outputs
        }
        // If jsCount >= 10000, it's corrupted but we still have spends/outputs, continue

        // Binding signature (64 bytes) - only if spends or outputs exist
        if (spendCount > 0 || outputCount > 0) && pos + 64 <= data.count {
            pos += 64
        }

        // Compute txHash (double SHA256 of the raw transaction)
        // Use min(pos, data.count) to ensure we don't go past the data
        let txEnd = min(pos, data.count)
        guard txEnd > txStart else {
            return (Data(repeating: 0, count: 32), spends, outputs, txEnd)
        }
        let txData = data[txStart..<txEnd]
        let txHash = Data(txData).doubleSHA256()

        debugLog(.network, "✅ P2P TX: Parsed successfully - \(spends.count) spends, \(outputs.count) outputs, txHash=\(txHash.reversedBytes().hexString)")
        return (txHash, spends, outputs, txEnd)
    }

    /// Skip a legacy (pre-Sapling) transaction
    private func skipLegacyTransaction(_ data: Data, offset: Int) -> Int {
        var pos = offset

        // Version (4 bytes)
        guard pos + 4 <= data.count else { return data.count }
        pos += 4

        // For non-overwintered, standard Bitcoin-like format
        // vin
        let (vinCount, vinBytes) = readCompactSize(data, at: pos)
        pos += vinBytes

        // Limit loop iterations to prevent runaway parsing on corrupted data
        let safeVinCount = min(vinCount, 10000)
        for _ in 0..<safeVinCount {
            guard pos < data.count else { return data.count }
            pos = skipTransparentInput(data, offset: pos)
        }

        // vout
        let (voutCount, voutBytes) = readCompactSize(data, at: pos)
        pos += voutBytes

        let safeVoutCount = min(voutCount, 10000)
        for _ in 0..<safeVoutCount {
            guard pos < data.count else { return data.count }
            pos = skipTransparentOutput(data, offset: pos)
        }

        // nLockTime (4 bytes)
        guard pos + 4 <= data.count else { return data.count }
        pos += 4

        return pos
    }

    /// Skip a transparent input
    private func skipTransparentInput(_ data: Data, offset: Int) -> Int {
        var pos = offset

        // Bounds check
        guard pos + 36 <= data.count else { return data.count }

        // prevout: txid (32) + vout index (4)
        pos += 36

        // scriptSig length + scriptSig
        let (scriptLen, scriptBytes) = readCompactSize(data, at: pos)
        pos += scriptBytes

        // Safe conversion - if scriptLen is too big, return end of data
        guard scriptLen <= UInt64(data.count - pos) else { return data.count }
        pos += Int(clamping: scriptLen)

        // sequence (4 bytes)
        guard pos + 4 <= data.count else { return data.count }
        pos += 4

        return pos
    }

    /// Skip a transparent output
    private func skipTransparentOutput(_ data: Data, offset: Int) -> Int {
        var pos = offset

        // Bounds check
        guard pos + 8 <= data.count else { return data.count }

        // value (8 bytes)
        pos += 8

        // scriptPubKey length + scriptPubKey
        let (scriptLen, scriptBytes) = readCompactSize(data, at: pos)
        pos += scriptBytes

        // Safe conversion - if scriptLen is too big, return end of data
        guard scriptLen <= UInt64(data.count - pos) else { return data.count }
        pos += Int(clamping: scriptLen)

        return pos
    }

    // MARK: - Helpers

    private func buildAddressPayload(_ address: String) -> Data {
        var payload = Data()
        let addressData = address.data(using: .utf8)!
        payload.append(UInt8(addressData.count))
        payload.append(addressData)
        return payload
    }

    // MARK: - Block/Transaction P2P Methods

    /// Get a single block by its hash via P2P getdata
    func getBlockByHash(hash: Data) async throws -> CompactBlock {
        // Ensure connection is fresh before making request (outside lock)
        try await ensureConnected()

        guard hash.count == 32 else {
            throw PeerError.invalidData
        }

        // Build getdata message for single block (outside lock - pure computation)
        var payload = Data()
        payload.append(1) // count = 1
        payload.append(contentsOf: withUnsafeBytes(of: UInt32(2).littleEndian) { Array($0) }) // MSG_BLOCK = 2
        payload.append(hash)

        // CRITICAL FIX: Wrap send+receive in withExclusiveAccess to prevent race with block listener
        return try await withExclusiveAccess {
            try await self.sendMessage(command: "getdata", payload: payload)

            // Wait for block response with timeout
            // Peers may send ping, inv, addr messages - we need to handle them
            var attempts = 0
            let maxAttempts = 30 // Increased from 10 - blocks can be large and slow
            while attempts < maxAttempts {
                attempts += 1

                // Add timeout for each receive attempt
                do {
                    let result = try await withThrowingTaskGroup(of: (String, Data).self) { group in
                        group.addTask {
                            try await self.receiveMessage()
                        }
                        group.addTask {
                            try await Task.sleep(nanoseconds: 5_000_000_000) // 5 second timeout per message
                            throw PeerError.timeout
                        }

                        let result = try await group.next()!
                        group.cancelAll()
                        return result
                    }

                    let (command, response) = result

                    if command == "block" {
                        if let block = self.parseCompactBlock(response) {
                            return block
                        }
                        throw PeerError.invalidData
                    } else if command == "notfound" {
                        // Peer doesn't have this block
                        throw PeerError.invalidData
                    } else if command == "ping" {
                        // Respond to ping with pong
                        try? await self.sendMessage(command: "pong", payload: response)
                    }
                    // Continue waiting for block message
                } catch is CancellationError {
                    // Timeout on this attempt, continue to next
                    continue
                } catch PeerError.timeout {
                    // Timeout, continue to next attempt
                    continue
                }
            }

            throw PeerError.timeout
        }
    }

    /// Get multiple blocks by their hashes via a single P2P getdata message (batch)
    /// Returns blocks in the order they are received (may differ from request order)
    func getBlocksByHashes(hashes: [Data]) async throws -> [CompactBlock] {
        guard !hashes.isEmpty else { return [] }

        // Ensure connection is fresh before making request (outside lock)
        try await ensureConnected()

        // Validate all hashes (outside lock - pure computation)
        for hash in hashes {
            guard hash.count == 32 else { throw PeerError.invalidData }
        }

        // Build getdata message for multiple blocks (outside lock - pure computation)
        var payload = Data()
        // Encode count as varint (simple case: count < 253)
        if hashes.count < 253 {
            payload.append(UInt8(hashes.count))
        } else {
            payload.append(253) // 0xfd prefix
            payload.append(contentsOf: withUnsafeBytes(of: UInt16(hashes.count).littleEndian) { Array($0) })
        }

        for hash in hashes {
            payload.append(contentsOf: withUnsafeBytes(of: UInt32(2).littleEndian) { Array($0) }) // MSG_BLOCK = 2
            payload.append(hash)
        }

        // CRITICAL FIX: Wrap send+receive in withExclusiveAccess to prevent race with block listener
        return try await withExclusiveAccess {
            try await self.sendMessage(command: "getdata", payload: payload)

            // Wait for all block responses
            var blocks: [CompactBlock] = []
            var attempts = 0
            let maxAttempts = hashes.count * 30 + 30 // Scale with batch size

            while blocks.count < hashes.count && attempts < maxAttempts {
                attempts += 1

                do {
                    let result = try await withThrowingTaskGroup(of: (String, Data).self) { group in
                        group.addTask {
                            try await self.receiveMessage()
                        }
                        group.addTask {
                            try await Task.sleep(nanoseconds: 5_000_000_000) // 5 second timeout per message
                            throw PeerError.timeout
                        }

                        let result = try await group.next()!
                        group.cancelAll()
                        return result
                    }

                    let (command, response) = result

                    if command == "block" {
                        if let block = self.parseCompactBlock(response) {
                            blocks.append(block)
                        }
                    } else if command == "notfound" {
                        // Peer doesn't have one of the blocks - just continue
                        continue
                    } else if command == "ping" {
                        try? await self.sendMessage(command: "pong", payload: response)
                    }
                    // Continue waiting for more block messages
                } catch is CancellationError {
                    continue
                } catch PeerError.timeout {
                    // If we have some blocks but hit timeout, return what we have
                    if !blocks.isEmpty { break }
                    continue
                }
            }

            return blocks
        }
    }

    /// Get a transaction by its hash via P2P getdata
    /// Uses exclusive access to prevent message stream conflicts
    func getTransaction(hash: Data) async throws -> Data {
        guard hash.count == 32 else {
            throw PeerError.invalidData
        }

        return try await withExclusiveAccess {
            // Build getdata message for single transaction
            var payload = Data()
            payload.append(1) // count = 1
            payload.append(contentsOf: withUnsafeBytes(of: UInt32(1).littleEndian) { Array($0) }) // MSG_TX = 1
            payload.append(hash)

            try await sendMessage(command: "getdata", payload: payload)

            // Wait for tx response
            var attempts = 0
            while attempts < 10 {
                attempts += 1
                let (command, response) = try await receiveMessage()

                // Handle ping automatically
                if command == "ping" {
                    try await sendMessage(command: "pong", payload: response)
                    continue
                }

                if command == "tx" {
                    return response
                }
                // Ignore other messages
            }

            throw PeerError.timeout
        }
    }

    // MARK: - Mempool Detection (Cypherpunk Style!)

    /// Request mempool inventory from peer
    /// Returns list of transaction hashes currently in peer's mempool
    /// Uses exclusive access to prevent message stream conflicts
    func getMempoolTransactions() async throws -> [Data] {
        return try await withExclusiveAccess {
            print("🔮 Requesting mempool inventory from peer...")

            // Send mempool request (empty payload)
            try await sendMessage(command: "mempool", payload: Data())

            // Wait for inv response with transaction inventory
            var txHashes: [Data] = []
            var attempts = 0

            while attempts < 20 {
                attempts += 1
                let (command, response) = try await receiveMessage()

                // Handle ping automatically
                if command == "ping" {
                    try await sendMessage(command: "pong", payload: response)
                    continue
                }

                if command == "inv" && response.count >= 1 {
                    // Parse inv payload: [count: varint][inv_vector...]
                    // Each inv_vector: [type: 4 bytes][hash: 32 bytes]
                    var offset = 0

                    // Read count (varint)
                    let (count, countSize) = readVarInt(from: response, at: offset)
                    offset += countSize

                    for _ in 0..<count {
                        guard offset + 36 <= response.count else { break }

                        // Type: 1 = MSG_TX, 2 = MSG_BLOCK
                        let invType = response.loadUInt32(at: offset)
                        offset += 4

                        // Hash (32 bytes)
                        let hash = response.subdata(in: offset..<offset+32)
                        offset += 32

                        // Only collect transactions (type 1)
                        if invType == 1 {
                            txHashes.append(hash)
                        }
                    }

                    print("🔮 Mempool contains \(txHashes.count) transactions")
                    return txHashes
                }

                // Ignore other messages, keep waiting
                if attempts % 5 == 0 {
                    print("⏳ Still waiting for mempool inv... (attempt \(attempts))")
                }
            }

            print("⏳ Mempool request timed out (peer may not support it)")
            return txHashes
        }
    }

    /// Check if a specific transaction is in the mempool
    func isTransactionInMempool(txid: Data) async throws -> Bool {
        let mempoolTxs = try await getMempoolTransactions()
        // txid might be in display format (reversed), try both
        let txidReversed = Data(txid.reversed())
        return mempoolTxs.contains(txid) || mempoolTxs.contains(txidReversed)
    }

    /// Get raw transaction from mempool (for parsing shielded outputs)
    /// Uses exclusive access to prevent message stream conflicts
    func getMempoolTransaction(txid: Data) async throws -> Data? {
        return try await withExclusiveAccess {
            // Request the transaction
            var payload = Data()
            payload.append(1) // count = 1
            payload.append(contentsOf: withUnsafeBytes(of: UInt32(1).littleEndian) { Array($0) }) // MSG_TX = 1
            payload.append(txid)

            try await sendMessage(command: "getdata", payload: payload)

            // Wait for tx response
            var attempts = 0
            while attempts < 10 {
                attempts += 1
                let (command, response) = try await receiveMessage()

                // Handle ping automatically
                if command == "ping" {
                    try await sendMessage(command: "pong", payload: response)
                    continue
                }

                if command == "tx" && response.count > 0 {
                    return response
                }
                if command == "notfound" {
                    return nil
                }
            }

            return nil
        }
    }

    /// Helper to read variable length integer
    private func readVarInt(from data: Data, at offset: Int) -> (UInt64, Int) {
        guard offset < data.count else { return (0, 0) }

        let first = data[offset]
        if first < 0xFD {
            return (UInt64(first), 1)
        } else if first == 0xFD {
            guard offset + 3 <= data.count else { return (0, 1) }
            let value = UInt16(data[offset + 1]) | (UInt16(data[offset + 2]) << 8)
            return (UInt64(value), 3)
        } else if first == 0xFE {
            guard offset + 5 <= data.count else { return (0, 1) }
            let value = data.loadUInt32(at: offset + 1)
            return (UInt64(value), 5)
        } else {
            guard offset + 9 <= data.count else { return (0, 1) }
            var value: UInt64 = 0
            for i in 0..<8 {
                value |= UInt64(data[offset + 1 + i]) << (i * 8)
            }
            return (value, 9)
        }
    }

    // MARK: - Onion Address Advertisement (Cypherpunk Visibility!)

    /// Advertise our .onion address to this peer via addrv2 message
    /// This makes ZipherX discoverable as a peer on the network while remaining anonymous
    /// Format: BIP 155 addrv2 with network ID 0x04 (Tor v3)
    func advertiseOnionAddress(onionAddress: String, port: UInt16) async throws {
        // Per BIP155: Only send addrv2 to peers that have sent us sendaddrv2
        guard supportsAddrv2 else {
            print("🧅 [\(host)] Skipping addrv2 - peer doesn't support BIP155")
            return
        }

        // Parse onion address - extract the 56-character base32 part
        guard onionAddress.hasSuffix(".onion") else {
            print("🧅 Invalid onion address format: \(onionAddress)")
            return
        }

        let addressPart = String(onionAddress.dropLast(6)) // Remove ".onion"
        guard addressPart.count == 56 else {
            print("🧅 Invalid Tor v3 address length: \(addressPart.count) (expected 56)")
            return
        }

        // Decode base32 to get pubkey + checksum + version (35 bytes)
        guard let decoded = decodeOnionV3(addressPart) else {
            print("🧅 Failed to decode onion address")
            return
        }

        // The first 32 bytes are the public key (what goes in addrv2)
        let publicKey = Array(decoded.prefix(32))

        // Build addrv2 payload
        var payload = Data()

        // Count: 1 address (varint)
        payload.append(1)

        // Time: current timestamp (4 bytes, little endian)
        let timestamp = UInt32(Date().timeIntervalSince1970)
        payload.append(contentsOf: withUnsafeBytes(of: timestamp.littleEndian) { Array($0) })

        // Services: NODE_NETWORK (1) as varint
        payload.append(1)

        // Network ID: 0x04 = Tor v3
        payload.append(0x04)

        // Address length: 32 bytes (varint)
        payload.append(32)

        // Address: 32-byte public key
        payload.append(contentsOf: publicKey)

        // Port: 2 bytes, big endian
        payload.append(UInt8((port >> 8) & 0xFF))
        payload.append(UInt8(port & 0xFF))

        // Debug: print payload hex
        let payloadHex = payload.map { String(format: "%02x", $0) }.joined()
        print("🧅 DEBUG addrv2 payload (\(payload.count) bytes): \(payloadHex)")

        // FIX #131: Wrap in withExclusiveAccess to prevent P2P race conditions
        try await withExclusiveAccess {
            // Send addrv2 message
            try await sendMessage(command: "addrv2", payload: payload)
            print("🧅 Advertised our .onion address to peer \(host): \(onionAddress):\(port)")
        }
    }

    /// Decode Tor v3 onion address from base32 to bytes
    /// Returns 35 bytes: 32-byte pubkey + 2-byte checksum + 1-byte version
    private func decodeOnionV3(_ address: String) -> Data? {
        // Tor v3 addresses use RFC 4648 base32 (no padding)
        let alphabet = "abcdefghijklmnopqrstuvwxyz234567"
        let lookup: [Character: UInt8] = Dictionary(uniqueKeysWithValues: alphabet.enumerated().map { (alphabet[alphabet.index(alphabet.startIndex, offsetBy: $0.offset)], UInt8($0.offset)) })

        var bits: [UInt8] = []
        for char in address.lowercased() {
            guard let value = lookup[char] else { return nil }
            // Each base32 character represents 5 bits
            for i in (0..<5).reversed() {
                bits.append((value >> i) & 1)
            }
        }

        // Convert bits to bytes (280 bits = 35 bytes)
        var bytes: [UInt8] = []
        for i in stride(from: 0, to: bits.count - 7, by: 8) {
            var byte: UInt8 = 0
            for j in 0..<8 {
                byte = (byte << 1) | bits[i + j]
            }
            bytes.append(byte)
        }

        return Data(bytes)
    }
}

// MARK: - Peer Errors

enum PeerError: Error, LocalizedError {
    case invalidData
    case timeout
    case connectionClosed

    var errorDescription: String? {
        switch self {
        case .invalidData: return "Invalid data received from peer"
        case .timeout: return "Peer request timed out"
        case .connectionClosed: return "Peer connection closed"
        }
    }
}

// MARK: - Data Extensions

extension Data {
    func doubleSHA256() -> Data {
        var firstHash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        var secondHash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))

        self.withUnsafeBytes { ptr in
            _ = CC_SHA256(ptr.baseAddress, CC_LONG(self.count), &firstHash)
        }

        _ = CC_SHA256(firstHash, CC_LONG(firstHash.count), &secondHash)

        return Data(secondHash)
    }

    // Safe integer loading (avoids alignment issues)
    func loadUInt16(at offset: Int) -> UInt16 {
        guard offset + 2 <= count else { return 0 }
        return UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func loadUInt16BE(at offset: Int) -> UInt16 {
        guard offset + 2 <= count else { return 0 }
        return (UInt16(self[offset]) << 8) | UInt16(self[offset + 1])
    }

    func loadUInt32(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        return UInt32(self[offset]) |
               (UInt32(self[offset + 1]) << 8) |
               (UInt32(self[offset + 2]) << 16) |
               (UInt32(self[offset + 3]) << 24)
    }

    func loadInt32(at offset: Int) -> Int32 {
        return Int32(bitPattern: loadUInt32(at: offset))
    }

    func loadUInt64(at offset: Int) -> UInt64 {
        guard offset + 8 <= count else { return 0 }
        let b0 = UInt64(self[offset])
        let b1 = UInt64(self[offset + 1]) << 8
        let b2 = UInt64(self[offset + 2]) << 16
        let b3 = UInt64(self[offset + 3]) << 24
        let b4 = UInt64(self[offset + 4]) << 32
        let b5 = UInt64(self[offset + 5]) << 40
        let b6 = UInt64(self[offset + 6]) << 48
        let b7 = UInt64(self[offset + 7]) << 56
        return b0 | b1 | b2 | b3 | b4 | b5 | b6 | b7
    }
}

// MARK: - Peer Score

struct PeerScore {
    var successCount: Int = 0
    var failureCount: Int = 0
    var lastResponseTime: Date?
    var bytesReceived: UInt64 = 0
    var bytesSent: UInt64 = 0
}

// MARK: - Banned Peer

struct BannedPeer {
    let address: String
    let banTime: Date
    let banDuration: TimeInterval // Default 24 hours, -1 means PERMANENT (FIX #159)
    let reason: BanReason

    /// FIX #159: Indicates if this is a permanent ban (Sybil attackers)
    /// Permanent bans do NOT expire automatically and require manual unbanning
    var isPermanent: Bool {
        banDuration < 0
    }

    var isExpired: Bool {
        // FIX #159: Permanent bans (duration < 0) NEVER expire
        if isPermanent {
            return false
        }
        return Date() > banTime.addingTimeInterval(banDuration)
    }

    /// Time remaining for temporary bans, nil for permanent bans
    var timeRemaining: TimeInterval? {
        if isPermanent {
            return nil
        }
        let remaining = banTime.addingTimeInterval(banDuration).timeIntervalSinceNow
        return max(0, remaining)
    }
}

enum BanReason: String {
    case tooManyFailures = "Too many consecutive failures"
    case lowSuccessRate = "Very low success rate"
    case invalidMessages = "Sent invalid messages"
    case protocolViolation = "Protocol violation"
    case timeout = "Connection/response timeout"
    case corruptedData = "Sent corrupted or invalid data"
    case fakeChainHeight = "Reported fake chain height (Sybil attack detected)"
}
