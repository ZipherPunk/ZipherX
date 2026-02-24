import Foundation
import Network
import CommonCrypto

// MARK: - Zclassic Protocol Constants (FIX #565)

/// Maximum number of headers returned in one getheaders response
/// Matches Zclassic's MAX_HEADERS_RESULTS in main.h:92
private let MAX_HEADERS_RESULTS = 160

/// Maximum blocks in transit per peer (from Zclassic main.h)
/// static const int MAX_BLOCKS_IN_TRANSIT_PER_PEER = 128;
private let MAX_BLOCKS_IN_TRANSIT_PER_PEER = 128

/// Message types (from Zclassic protocol.h)
private enum MSGType: UInt32 {
    case tx = 1
    case block = 2
    case filteredBlock = 3  // MSG_FILTERED_BLOCK
}

/// FIX #869: Ping result type to distinguish between failure modes
/// This allows callers to decide whether to count failure towards ban threshold
public enum PingResult {
    case success                    // Peer responded with valid pong
    case busy                       // Lock acquisition failed (peer busy) - don't count
    case timeout                    // Ping/pong timeout - protocol issue, count towards ban
    case protocolError              // Invalid response - protocol issue, count towards ban
    case transientNetworkError      // Connection reset, broken pipe - don't count towards ban
}

// MARK: - FIX #879: Centralized Message Dispatcher
// Block listener becomes the SINGLE message reader, dispatching to waiting handlers
// This eliminates race conditions where multiple operations read from TCP stream

/// FIX #883: Centralized Message Dispatcher - Block listener handles ALL TCP reads
/// Operations register handlers here; block listener dispatches messages to waiting handlers
/// This eliminates race conditions where multiple operations read from TCP stream
actor PeerMessageDispatcher {

    // MARK: - FIX #1528: One-shot continuation wrapper
    // `waitForAnyResponse` registers the SAME continuation for multiple commands.
    // When one command fires, the continuation is resumed — but the same object
    // remains registered for the other commands. If another dispatch or cleanup
    // tries to resume it again → "SWIFT TASK CONTINUATION MISUSE" fatal crash.
    // This wrapper nil-guards the inner continuation so only the FIRST resume wins.
    // Actor serialization ensures no data race on the `inner` property.
    final class OneShotContinuation {
        private var inner: CheckedContinuation<(String, Data), Error>?

        init(_ continuation: CheckedContinuation<(String, Data), Error>) {
            self.inner = continuation
        }

        /// Resume with value. Returns true if this was the first resume, false if already consumed.
        @discardableResult
        func resume(returning value: (String, Data)) -> Bool {
            guard let c = inner else { return false }
            inner = nil
            c.resume(returning: value)
            return true
        }

        /// Resume with error. Returns true if this was the first resume, false if already consumed.
        @discardableResult
        func resume(throwing error: Error) -> Bool {
            guard let c = inner else { return false }
            inner = nil
            c.resume(throwing: error)
            return true
        }

        /// Whether this continuation has already been consumed
        var isConsumed: Bool { inner == nil }
    }

    /// Waiting handlers keyed by expected command (e.g., "headers", "block", "reject")
    private var pendingHandlers: [String: [OneShotContinuation]] = [:]

    /// FIX #883: Special handler for broadcast - waits for "reject" OR first message
    /// Key: "broadcast_{txid}" - receives either reject or any other message (silence = accept)
    private var broadcastHandlers: [String: CheckedContinuation<(String, Data)?, Error>] = [:]

    /// FIX #883: Mempool tx callback - called when we see a tx in mempool
    var onMempoolTxSeen: ((Data) -> Void)?

    /// FIX #883: TX confirmation callback - called when tx confirmed in block
    var onTxConfirmed: ((Data, UInt32) -> Void)?

    /// FIX #887: Track if dispatcher is active (block listener running)
    private(set) var isActive: Bool = false

    /// FIX #1521: Early response queue — holds responses that arrive before handler is registered.
    /// Prevents race condition where peer responds to getaddr before waitForResponse registers.
    private var earlyResponses: [String: [(String, Data)]] = [:]

    /// FIX #887: Set dispatcher active state
    func setActive(_ active: Bool) {
        isActive = active
    }

    /// FIX #1521: Mark commands as expected so dispatch() queues responses that arrive
    /// before waitForResponse registers the handler. Call BEFORE sending the request.
    func expectCommands(_ commands: [String]) {
        for command in commands {
            if earlyResponses[command] == nil {
                earlyResponses[command] = []
            }
        }
    }

    /// FIX #1521: Clear expected commands (cleanup after wait completes or times out)
    func clearExpectedCommands(_ commands: [String]) {
        for command in commands {
            earlyResponses.removeValue(forKey: command)
        }
    }

    /// Register to wait for a specific response type
    func waitForResponse(command: String) async throws -> (String, Data) {
        // FIX #1521: Check if response already arrived before handler was registered
        if var early = earlyResponses[command], !early.isEmpty {
            let response = early.removeFirst()
            earlyResponses[command] = early.isEmpty ? nil : early
            return response
        }

        return try await withCheckedThrowingContinuation { continuation in
            if pendingHandlers[command] == nil {
                pendingHandlers[command] = []
            }
            pendingHandlers[command]?.append(OneShotContinuation(continuation))
        }
    }

    /// FIX #887: Wait for response with timeout
    /// FIX #1069: Use GCD-based timeout for reliability (Task.sleep can be delayed)
    /// Returns nil if timeout occurs, (command, payload) otherwise
    func waitForResponseWithTimeout(command: String, timeoutSeconds: Double) async -> (String, Data)? {
        return await withReliableTimeout(seconds: timeoutSeconds) {
            do {
                return try await self.waitForResponse(command: command)
            } catch {
                return nil
            }
        } onTimeout: {
            return nil
        }
    }

    /// FIX #887: Wait for any of multiple response types (e.g., "headers" OR "reject")
    /// FIX #1528: Uses OneShotContinuation so the same continuation registered for multiple
    /// commands can only be resumed ONCE — subsequent dispatch/cleanup calls are no-ops.
    func waitForAnyResponse(commands: [String]) async throws -> (String, Data) {
        return try await withCheckedThrowingContinuation { continuation in
            // FIX #1528: Wrap in OneShotContinuation — same instance shared across all commands
            let oneShot = OneShotContinuation(continuation)
            for command in commands {
                if pendingHandlers[command] == nil {
                    pendingHandlers[command] = []
                }
                pendingHandlers[command]?.append(oneShot)
            }
        }
    }

    /// FIX #1201: Wait for any of multiple response types with timeout and cleanup
    /// When one command fires, removes the stale handler for the other commands
    /// to prevent double-resume crashes. Returns nil on timeout.
    func waitForAnyResponseWithTimeout(commands: [String], timeoutSeconds: Double) async -> (String, Data)? {
        let result: (String, Data)? = await withReliableTimeout(seconds: timeoutSeconds) {
            do {
                return try await self.waitForAnyResponse(commands: commands)
            } catch {
                return nil as (String, Data)?
            }
        } onTimeout: {
            return nil as (String, Data)?
        }

        // FIX #1201: Clean up stale handlers for commands that didn't fire
        // When "notfound" fires, the "tx" handler still has the same (now-resumed) continuation.
        // When timeout fires, ALL handlers are stale. Remove them to prevent double-resume.
        if let fired = result {
            // One command fired — remove handlers for the OTHER commands
            for command in commands where command != fired.0 {
                cancelWaitingHandler(command: command)
            }
        } else {
            // Timeout — remove ALL handlers
            for command in commands {
                cancelWaitingHandler(command: command)
            }
        }

        return result
    }

    /// FIX #887: Cancel waiting handler for a specific command (for cleanup after timeout)
    /// FIX #1519: MUST resume continuation before removing — dropping a CheckedContinuation
    /// without resuming it leaks the task forever ("SWIFT TASK CONTINUATION MISUSE" warning).
    func cancelWaitingHandler(command: String) {
        if var handlers = pendingHandlers[command], !handlers.isEmpty {
            let handler = handlers.removeFirst()
            handler.resume(throwing: CancellationError())
            pendingHandlers[command] = handlers.isEmpty ? nil : handlers
        }
    }

    /// FIX #883: Register to wait for broadcast result (reject or timeout)
    /// Returns (command, payload) if reject received, nil if timeout (= success)
    func waitForBroadcastResult(txid: String) async throws -> (String, Data)? {
        return try await withCheckedThrowingContinuation { continuation in
            broadcastHandlers["broadcast_\(txid)"] = continuation
        }
    }

    /// FIX #883: Signal broadcast timeout (no reject received = success)
    func signalBroadcastTimeout(txid: String) {
        if let handler = broadcastHandlers.removeValue(forKey: "broadcast_\(txid)") {
            handler.resume(returning: nil)  // nil = no reject = success
        }
    }

    /// FIX #1184: Wait for broadcast reject with timeout (routed through dispatcher)
    /// Returns (command, payload) if reject received, nil if timeout (silence = success)
    /// Uses GCD-based timeout for reliability (same pattern as waitForResponseWithTimeout)
    func waitForBroadcastResultWithTimeout(txid: String, timeoutSeconds: Double) async -> (String, Data)? {
        return await withReliableTimeout(seconds: timeoutSeconds) {
            do {
                return try await self.waitForBroadcastResult(txid: txid)
            } catch {
                return nil  // Connection error = treat as no reject
            }
        } onTimeout: {
            // Timeout fired — signal no-reject (success) and clean up handler
            self.signalBroadcastTimeout(txid: txid)
            return nil
        }
    }

    /// Dispatch a received message to waiting handler (called by block listener)
    /// Returns true if message was dispatched, false if no handler waiting
    func dispatch(command: String, payload: Data) -> Bool {
        // FIX #893: Check batch collectors FIRST (for "block" messages, etc.)
        if dispatchToBatchCollector(command: command, payload: payload) {
            return true
        }

        // Check for exact command match (single handlers)
        if var handlers = pendingHandlers[command], !handlers.isEmpty {
            let handler = handlers.removeFirst()
            pendingHandlers[command] = handlers.isEmpty ? nil : handlers
            // FIX #1528: OneShotContinuation returns false if already consumed by another command
            let wasResumed = handler.resume(returning: (command, payload))
            if !wasResumed {
                print("⚠️ FIX #1528: [\(command)] handler already consumed (multi-command race avoided)")
            }
            return true
        }

        // FIX #1521: If command is expected but handler not yet registered, queue it
        if earlyResponses[command] != nil {
            earlyResponses[command]?.append((command, payload))
            return true
        }

        // FIX #883: Check broadcast handlers for reject messages
        if command == "reject" {
            // Parse reject to get txid and deliver to correct handler
            if let txid = parseRejectTxid(payload: payload) {
                let key = "broadcast_\(txid)"
                if let handler = broadcastHandlers.removeValue(forKey: key) {
                    handler.resume(returning: (command, payload))
                    return true
                }
            }
            // FIX #1360: TASK 11 — SECURITY: Remove "any handler" fallback
            // Delivering unmatched rejects to wrong handler causes TX-A reject → TX-B failure
            print("⚠️ Reject message with unmatched txid — dropping")
            return false
        }

        return false
    }

    /// FIX #1365 / Security audit TASK 9: Decode CompactSize varint per Bitcoin protocol
    /// Used by parseRejectTxid to properly decode variable-length fields
    private func readCompactSize(from data: Data, at offset: inout Int) -> UInt64? {
        guard offset < data.count else { return nil }
        let first = data[offset]
        offset += 1

        switch first {
        case 0x00...0xFC:
            return UInt64(first)
        case 0xFD:
            guard offset + 2 <= data.count else { return nil }
            let val = data[offset..<offset+2].withUnsafeBytes { $0.loadUnaligned(as: UInt16.self).littleEndian }
            offset += 2
            return UInt64(val)
        case 0xFE:
            guard offset + 4 <= data.count else { return nil }
            let val = data[offset..<offset+4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
            offset += 4
            return UInt64(val)
        case 0xFF:
            guard offset + 8 <= data.count else { return nil }
            let val = data[offset..<offset+8].withUnsafeBytes { $0.loadUnaligned(as: UInt64.self).littleEndian }
            offset += 8
            return UInt64(val)
        default:
            return nil
        }
    }

    /// FIX #883: Parse txid from reject message payload
    private func parseRejectTxid(payload: Data) -> String? {
        guard payload.count > 0 else { return nil }
        var offset = 0

        // FIX #1365 / Security audit TASK 9: Use proper CompactSize varint decoding
        // Skip message type (CompactSize string)
        guard let msgLen = readCompactSize(from: payload, at: &offset) else { return nil }
        guard msgLen <= 1000 else { return nil }  // FIX #1365: Sanity check
        offset += Int(msgLen)

        // Skip reject code (1 byte)
        guard offset < payload.count else { return nil }
        offset += 1

        // Skip reason (CompactSize string)
        guard let reasonLen = readCompactSize(from: payload, at: &offset) else { return nil }
        guard reasonLen <= 1000 else { return nil }  // FIX #1365: Sanity check
        offset += Int(reasonLen)

        // Next 32 bytes should be txid (for tx rejects)
        if offset + 32 <= payload.count {
            let txidBytes = payload[offset..<offset+32]
            return txidBytes.reversed().map { String(format: "%02x", $0) }.joined()
        }
        return nil
    }

    /// Cancel all pending handlers (called on disconnect)
    /// FIX #1528: OneShotContinuation safely ignores double-resume from multi-command registrations
    func cancelAll(error: Error) {
        for (_, handlers) in pendingHandlers {
            for handler in handlers {
                handler.resume(throwing: error)  // No-op if already consumed
            }
        }
        pendingHandlers.removeAll()

        // FIX #883: Also cancel broadcast handlers
        for (_, handler) in broadcastHandlers {
            handler.resume(throwing: error)
        }
        broadcastHandlers.removeAll()

        // FIX #893: Cancel batch collectors (return partial results)
        cancelAllBatchCollectors()
    }

    /// Check if any handlers are waiting for a specific command
    func hasWaitingHandler(for command: String) -> Bool {
        return pendingHandlers[command]?.isEmpty == false || commandToBatchIds[command]?.isEmpty == false
    }

    /// Get count of all pending handlers
    var pendingCount: Int {
        return pendingHandlers.values.reduce(0) { $0 + $1.count } + broadcastHandlers.count + batchCollectors.count
    }

    // MARK: - FIX #893: Batch Collectors for Multi-Message Operations

    /// Batch collector for operations expecting multiple messages (e.g., 50 blocks)
    private struct BatchCollector {
        let command: String
        let expectedCount: Int
        var collected: [Data] = []
        let continuation: CheckedContinuation<[Data], Never>
    }

    /// Active batch collectors keyed by unique ID
    private var batchCollectors: [UUID: BatchCollector] = [:]

    /// Mapping from command to collector IDs (for dispatch routing)
    private var commandToBatchIds: [String: [UUID]] = [:]

    /// FIX #893: Wait for multiple responses of the same type (e.g., N "block" messages)
    /// Returns collected payloads (may be partial if timeout occurs)
    func waitForBatch(
        command: String,
        expectedCount: Int,
        timeoutSeconds: Double
    ) async -> [Data] {
        let collectorId = UUID()

        // Register collector and wait via continuation
        // The continuation will be resumed when batch is complete OR timeout occurs
        return await withCheckedContinuation { (continuation: CheckedContinuation<[Data], Never>) in
            // Register collector (actor-isolated)
            batchCollectors[collectorId] = BatchCollector(
                command: command,
                expectedCount: expectedCount,
                continuation: continuation
            )

            if commandToBatchIds[command] == nil {
                commandToBatchIds[command] = []
            }
            commandToBatchIds[command]?.append(collectorId)

            print("📦 FIX #893: Registered batch collector for \(expectedCount) '\(command)' messages")

            // Start timeout task
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))

                // Timeout fired - return whatever we collected (if not already completed)
                await self.handleBatchTimeout(collectorId: collectorId, command: command, expectedCount: expectedCount)
            }
        }
    }

    /// FIX #893: Handle batch timeout (actor-isolated)
    private func handleBatchTimeout(collectorId: UUID, command: String, expectedCount: Int) {
        // Only handle if collector still exists (wasn't completed)
        guard let collector = batchCollectors.removeValue(forKey: collectorId) else {
            return  // Already completed via dispatch
        }

        // Clean up mapping
        commandToBatchIds[command]?.removeAll { $0 == collectorId }
        if commandToBatchIds[command]?.isEmpty == true {
            commandToBatchIds[command] = nil
        }

        print("⏱️ FIX #893: Batch timeout - returning \(collector.collected.count)/\(expectedCount) items")
        collector.continuation.resume(returning: collector.collected)
    }

    /// FIX #893: Dispatch message to batch collector
    /// Returns true if dispatched to a batch collector
    private func dispatchToBatchCollector(command: String, payload: Data) -> Bool {
        guard let collectorIds = commandToBatchIds[command], let firstId = collectorIds.first else {
            return false
        }

        guard var collector = batchCollectors[firstId] else {
            return false
        }

        // Add to collection
        collector.collected.append(payload)

        if collector.collected.count >= collector.expectedCount {
            // Batch complete!
            batchCollectors.removeValue(forKey: firstId)
            commandToBatchIds[command]?.removeFirst()
            if commandToBatchIds[command]?.isEmpty == true {
                commandToBatchIds[command] = nil
            }
            print("✅ FIX #893: Batch complete - collected \(collector.collected.count)/\(collector.expectedCount) '\(command)' messages")
            collector.continuation.resume(returning: collector.collected)
        } else {
            // Still collecting
            batchCollectors[firstId] = collector
        }

        return true
    }

    /// FIX #893: Cancel all batch collectors (returns partial results)
    private func cancelAllBatchCollectors() {
        for (id, collector) in batchCollectors {
            print("🛑 FIX #893: Cancelling batch collector with \(collector.collected.count) items")
            collector.continuation.resume(returning: collector.collected)
        }
        batchCollectors.removeAll()
        commandToBatchIds.removeAll()
    }
}

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

    /// FIX #419: Acquire lock with timeout to prevent indefinite hangs
    /// FIX #1069: Use GCD-based timeout instead of Task.sleep for reliability
    /// Returns true if lock acquired, false if timed out
    func acquireWithTimeout(seconds: Double) async -> Bool {
        if !isLocked {
            isLocked = true
            return true
        }

        // FIX #1069: Use GCD-based timeout (guaranteed to fire)
        // Task.sleep can be delayed by Swift's cooperative threading
        return await withCheckedContinuation { continuation in
            var continuationResumed = false
            let lock = NSLock()

            // Task 1: Wait for lock
            Task {
                let acquired = await self.waitForLock()

                lock.lock()
                if !continuationResumed {
                    continuationResumed = true
                    lock.unlock()
                    continuation.resume(returning: acquired)
                } else {
                    lock.unlock()
                    // Timed out before we acquired - release the lock we just got
                    if acquired {
                        await self.release()
                    }
                }
            }

            // Task 2: GCD timeout (separate thread pool, guaranteed to fire)
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                lock.lock()
                if !continuationResumed {
                    continuationResumed = true
                    lock.unlock()
                    continuation.resume(returning: false)  // Timed out
                } else {
                    lock.unlock()
                }
            }
        }
    }

    /// Helper method to wait for lock acquisition
    /// This runs in actor context so can call addWaiter safely
    private func waitForLock() async -> Bool {
        await withCheckedContinuation { continuation in
            addWaiter(continuation)
        }
        return true  // Lock was acquired (continuation only returns when resumed)
    }

    /// Helper for acquireWithTimeout to add waiter from async context
    private func addWaiter(_ continuation: CheckedContinuation<Void, Never>) {
        waiters.append(continuation)
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

    /// FIX #906: Force release the lock unconditionally
    /// Used when block listener times out and may have left the lock held
    /// This prevents header sync from being blocked by dead/stuck listeners
    /// FIX #1088: CRITICAL - When resuming waiters, pass lock to first waiter
    /// Previous bug: set isLocked=false then resumed waiters, but waiters assumed
    /// they had the lock. This allowed tryAcquire() to steal the lock!
    func forceRelease() {
        if let firstWaiter = waiters.first {
            // Pass lock to first waiter (keep isLocked = true)
            waiters.removeFirst()
            firstWaiter.resume()
            // DON'T resume remaining waiters - they have their own timeout
            // If we resume them, they'll think they have the lock but won't
            // Let them timeout naturally via GCD timeout in acquireWithTimeout
        } else {
            // No waiters - just unlock
            isLocked = false
        }
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

/// FIX #1401: Semaphore to limit concurrent SOCKS5 handshakes to the Arti proxy.
/// Without this, 45+ concurrent Tor connection attempts overwhelm the proxy,
/// causing 30-second timeouts and starving other tasks.
/// FIX #1538: Reduced to 2 on iOS — Arti can't create 6 simultaneous circuits on cellular.
/// z13.log evidence: first 4 of 6 succeed, rest cascade-timeout at 11s, then ALL subsequent fail.
#if os(iOS)
private let socksSemaphore = DispatchSemaphore(value: 2)
#else
private let socksSemaphore = DispatchSemaphore(value: 6)
#endif

/// Individual peer connection for Zclassic P2P network
public final class Peer {
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

    /// FIX #434 + FIX #1159: Valid Zclassic protocol versions
    /// Zclassic uses:
    ///   - 170010-170012 (Sapling + BIP155, older releases)
    ///   - 170100-170199 (v2.x.x releases, e.g., 170110 = v2.1.2)
    /// Zcash uses 170018+ (NU upgrades) - these are WRONG CHAIN and must be rejected
    private static let maxZclassicProtocolVersion: Int32 = 170012
    private static let zclassicV2MinVersion: Int32 = 170100
    private static let zclassicV2MaxVersion: Int32 = 170199
    private let services: UInt64 = 1 // NODE_NETWORK
    // PRIVACY: P-NET-004 — Mimic full node user agent to prevent wallet fingerprinting
    private let userAgent = "/MagicBean:2.1.2/"

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

    // MARK: - FIX #915: Zcash-compatible connection management
    // Based on zcash/src/net.h CNode class

    /// Last time data was sent to this peer (matches Zcash nLastSend)
    private var lastSend: Date?

    /// Last time data was received from this peer (matches Zcash nLastRecv)
    private var lastRecv: Date?

    /// Legacy: Last activity timestamp (for backward compatibility)
    private var lastActivity: Date? {
        get {
            // Return the most recent of send/recv
            guard let send = lastSend, let recv = lastRecv else {
                return lastSend ?? lastRecv
            }
            return max(send, recv)
        }
        set {
            // When setting lastActivity, update both
            lastSend = newValue
            lastRecv = newValue
        }
    }

    // Note: isHandshakeComplete is a computed property (line ~1133) that checks
    // peerVersion > 0 && isValidZclassicPeer - this matches Zcash fSuccessfullyConnected

    /// Peer should be disconnected (matches Zcash fDisconnect)
    var shouldDisconnect: Bool = false

    // MARK: - FIX #1012: Zcash-Aligned Timeout Constants (from net.h)
    // Based on Zclassic/Zcash source: src/net.h lines 69-75
    // These intervals are battle-tested for P2P stability

    /// Time between automatic keepalive pings (matches Zcash PING_INTERVAL)
    /// "Time between pings automatically sent out for latency probing and keepalive"
    /// FIX #1012: Zcash uses 2 minutes - aggressive 30s was causing unnecessary traffic
    static let PING_INTERVAL: TimeInterval = 120  // 2 minutes (Zcash default)

    /// Time after which to disconnect for inactivity (matches Zcash TIMEOUT_INTERVAL)
    /// "Time after which to disconnect, after waiting for a ping response (or inactivity)"
    /// FIX #1012: Zcash uses 20 minutes - this is the absolute maximum idle time
    static let TIMEOUT_INTERVAL: TimeInterval = 1200  // 20 minutes (Zcash default)

    /// FIX #1012: Minimum time before considering a peer for inactivity check
    /// If peer had activity within this window, it's definitely alive - no ping needed
    /// This is MORE aggressive than PING_INTERVAL to catch dead connections faster
    /// while still respecting the overall TIMEOUT_INTERVAL for final disconnect
    static let ACTIVITY_GRACE_PERIOD: TimeInterval = 90  // 1.5 minutes

    /// Max idle time before connection is considered for timeout check
    /// This is NOT used for reconnection - only for detecting truly dead connections
    /// FIX #1012: Aligned with Zcash TIMEOUT_INTERVAL
    private let maxIdleTime: TimeInterval = 1200  // Match TIMEOUT_INTERVAL

    // MARK: - FIX #1069: Block Listener State Machine
    // Replaces scattered flags with formal state machine for predictable behavior
    // State transitions: stopped → starting → running → stopping → stopped

    /// FIX #1069: Block listener state enum - replaces _isListening, blockListenerTask flags
    private enum BlockListenerState: Equatable {
        case stopped
        case starting
        case running(taskID: UUID)  // UUID identifies the task for matching
        case stopping

        /// Whether the listener is conceptually "on" (starting, running, or stopping)
        var isActive: Bool {
            switch self {
            case .stopped: return false
            case .starting, .running, .stopping: return true
            }
        }

        /// FIX #1114: Helper for suppressing common log spam
        var isRunning: Bool {
            if case .running = self { return true }
            return false
        }

        /// FIX #1114: Helper for suppressing common log spam
        var isStarting: Bool {
            if case .starting = self { return true }
            return false
        }

        static func == (lhs: BlockListenerState, rhs: BlockListenerState) -> Bool {
            switch (lhs, rhs) {
            case (.stopped, .stopped): return true
            case (.starting, .starting): return true
            case (.running(let id1), .running(let id2)): return id1 == id2
            case (.stopping, .stopping): return true
            default: return false
            }
        }
    }

    /// FIX #1069: Current block listener state
    private var listenerState: BlockListenerState = .stopped
    private let stateLock = NSLock()

    /// FIX #1069: The actual task running the block listener
    private var blockListenerTask: Task<Void, Never>?

    /// FIX #1069 v3: Flag to track if connection was used by block listener
    /// When true, direct block reads need a fresh connection to avoid stale socket data
    private var connectionUsedByBlockListener: Bool = false

    /// FIX #1071 v2: Flag to indicate force reconnection is in progress
    /// When true, other callers (like sequential fallback) should wait instead of hitting cooldown
    /// This prevents the race condition where forceReconnect() sets a NEW cooldown
    /// that blocks concurrent ensureConnected() calls on the SAME peer
    private var isForceReconnecting: Bool = false

    /// FIX #892 v2: Count resyncs to detect persistent corruption
    /// Reset when fresh connection is established
    private var resyncCount: Int = 0

    /// FIX #140: Public getter for isListening (used by NetworkManager to check listener state)
    /// FIX #1069: Now derived from state machine
    var isListening: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return listenerState.isActive
    }

    /// FIX #1069: Validate and perform state transition
    /// Returns true if transition was valid, false otherwise
    private func transitionTo(_ newState: BlockListenerState, from expectedStates: [BlockListenerState]? = nil) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }

        // FIX #1069 v2: If already in target state, return true without warning (idempotent)
        // FIX #1451: For .running, must compare taskIDs — different taskID is NOT the same state
        let isAlreadyInTargetState: Bool = {
            switch (listenerState, newState) {
            case (.stopped, .stopped): return true
            case (.starting, .starting): return true
            case (.running(let currentID), .running(let newID)): return currentID == newID
            case (.stopping, .stopping): return true
            default: return false
            }
        }()

        if isAlreadyInTargetState {
            // Already in target state - no-op, return success
            return true
        }

        // Validate transition if expected states provided
        if let expected = expectedStates {
            // Check current state is one of the expected
            let currentMatches = expected.contains { exp in
                switch (listenerState, exp) {
                case (.stopped, .stopped): return true
                case (.starting, .starting): return true
                // FIX #1451: Compare taskIDs! Without this, a stale listener (old taskID)
                // exiting after 300s timeout overwrites the state of the CURRENT listener
                // (new taskID) → sets state to .stopped → cascading listener death → peers drop to 1.
                case (.running(let currentID), .running(let expectedID)): return currentID == expectedID
                case (.stopping, .stopping): return true
                default: return false
                }
            }
            if !currentMatches {
                // FIX #1114: Suppress log for common case: running→starting (just means listener already running)
                // This is expected behavior, not an error - the caller handles it gracefully
                let isCommonCase = (listenerState.isRunning && newState.isStarting)
                if !isCommonCase {
                    print("⚠️ FIX #1069: [\(host)] Invalid state transition: \(listenerState) → \(newState) (expected one of: \(expected))")
                }
                return false
            }
        }

        // Log state transition
        let oldState = listenerState
        listenerState = newState
        print("🔄 FIX #1069: [\(host)] Block listener: \(oldState) → \(newState)")

        // FIX #1069 v3: Mark connection as needing refresh when block listener runs
        // Block listener consumes messages and can leave stale data in socket buffer
        if case .running = newState {
            connectionUsedByBlockListener = true
        }

        return true
    }

    /// FIX #1069: Get current state (thread-safe)
    private func getCurrentState() -> BlockListenerState {
        stateLock.lock()
        defer { stateLock.unlock() }
        return listenerState
    }

    /// Callback when a new block is announced via P2P inv message
    /// Parameters: block hash (32 bytes, wire format)
    var onBlockAnnounced: ((Data) -> Void)?

    // MARK: - FIX #879: Centralized Message Dispatcher
    /// When enabled, block listener handles ALL message receiving and dispatches to waiting handlers
    /// This eliminates TCP stream race conditions that cause "INVALID MAGIC BYTES" errors
    private let messageDispatcher = PeerMessageDispatcher()

    /// FIX #1184: Public accessor to check if dispatcher is active
    var isDispatcherActive: Bool {
        get async { await messageDispatcher.isActive }
    }

    /// FIX #879: When true, operations use dispatcher instead of direct reads
    /// Set to true when block listener is running
    var useMessageDispatcher: Bool = false

    // MARK: - FIX #887: Dispatcher-Based Operations
    /// Send a request and wait for response via dispatcher (when block listener is active)
    /// Falls back to direct reads if dispatcher not active
    /// - Parameters:
    ///   - command: The P2P command to send (e.g., "getheaders")
    ///   - payload: The message payload
    ///   - expectedResponse: The expected response command (e.g., "headers")
    ///   - timeoutSeconds: Maximum time to wait for response
    /// - Returns: (command, payload) tuple for the response
    func sendAndWaitViaDispatcher(
        command: String,
        payload: Data,
        expectedResponse: String,
        timeoutSeconds: Double = 10  // FIX #1217: Reduced from 30s — single P2P responses arrive in <1s
    ) async throws -> (String, Data) {
        // Check if dispatcher is active (block listener running)
        let dispatcherActive = await messageDispatcher.isActive

        if dispatcherActive {
            // FIX #887: Use dispatcher pattern - block listener will deliver response
            // FIX #1440: Suppress repetitive getheaders/getdata logs (fire 100+ times during sync)
            if command != "getheaders" && command != "getdata" {
                print("📨 FIX #887: [\(host)] Sending '\(command)', waiting for '\(expectedResponse)' via dispatcher")
            }

            // Send the request
            try await sendMessage(command: command, payload: payload)

            // Wait for response via dispatcher with timeout
            if let response = await messageDispatcher.waitForResponseWithTimeout(
                command: expectedResponse,
                timeoutSeconds: timeoutSeconds
            ) {
                return response
            } else {
                // Timeout - cancel any waiting handler
                await messageDispatcher.cancelWaitingHandler(command: expectedResponse)
                print("⏱️ FIX #887: [\(host)] Timeout waiting for '\(expectedResponse)'")
                throw NetworkError.timeout
            }
        } else {
            // FIX #1184: Do NOT use direct reads — receiveMessageWithTimeout(destroyConnectionOnTimeout: false)
            // leaves orphaned NWConnection readers that desync TCP streams when block listeners restart.
            // Try to activate dispatcher first. If still inactive, throw timeout to let caller retry.
            print("📨 FIX #1184: [\(host)] Dispatcher not active for '\(command)' — attempting to start block listener...")

            // Try to start block listener to activate dispatcher
            startBlockListener()

            // Wait briefly for dispatcher activation (up to 2s)
            for _ in 1...4 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                let nowActive = await messageDispatcher.isActive
                if nowActive {
                    print("📨 FIX #1184: [\(host)] Dispatcher activated — routing '\(command)' through it")
                    try await sendMessage(command: command, payload: payload)
                    if let response = await messageDispatcher.waitForResponseWithTimeout(
                        command: expectedResponse,
                        timeoutSeconds: timeoutSeconds
                    ) {
                        return response
                    } else {
                        await messageDispatcher.cancelWaitingHandler(command: expectedResponse)
                        throw NetworkError.timeout
                    }
                }
            }

            // Dispatcher still not active after 2s — throw timeout (caller can retry with another peer)
            print("⚠️ FIX #1184: [\(host)] Dispatcher failed to activate for '\(command)' — timeout")
            throw NetworkError.timeout
        }
    }

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
    // FIX #1080: Reduced from 2.0s to 0.5s for faster parallel block fetching
    private static let globalCooldownInterval: TimeInterval = 0.5

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
        // FIX #1039: Check state before cancel to prevent "already cancelled" warnings
        if let conn = conn {
            conn.stateUpdateHandler = nil
            if case .cancelled = conn.state {
                // Already cancelled, don't call cancel again
            } else {
                conn.cancel()
            }
        }
    }

    // MARK: - Safe Connection Cancel

    /// FIX #1039: Safely cancel connection without triggering NWConnection warnings
    /// - Checks if connection is nil or already cancelled
    /// - Clears stateUpdateHandler before cancelling to prevent endpoint access warnings
    /// - Prevents "already cancelled, ignoring cancel" and endpoint access warnings
    /// - force: Use forceCancel() instead of cancel() for immediate disconnection
    private func safeCancelConnection(_ conn: NWConnection?, force: Bool = false) {
        guard let conn = conn else { return }

        // Clear state handler FIRST to prevent it from firing after cancel
        conn.stateUpdateHandler = nil

        // Check state before cancelling
        switch conn.state {
        case .cancelled:
            // Already cancelled, don't call cancel again
            return
        case .failed(_):
            // Already failed, cancel is safe but might warn
            if force {
                conn.forceCancel()
            } else {
                conn.cancel()
            }
        default:
            if force {
                conn.forceCancel()
            } else {
                conn.cancel()
            }
        }
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

    // MARK: - FIX #1097: Preferred Peer for Downloads (fPreferredDownload equivalent)

    /// FIX #1097: Check if peer should be preferred for downloads
    /// Matches Zclassic's fPreferredDownload = true for whitelisted peers
    /// Preferred peers are hardcoded seeds (verified good Zclassic nodes)
    /// These peers gate header sync and block fetch - they should always be tried first
    /// NOTE: ZipherX P2P mode has NO local node - localhost is NOT a preferred peer!
    var isPreferredForDownload: Bool {
        // Hardcoded seeds - verified good Zclassic nodes
        // FIX #1097: Removed localhost check - ZipherX P2P mode has no local node!
        return PeerManager.shared.HARDCODED_SEEDS.contains(host)
    }

    // MARK: - FIX #535: Performance Score for Header Sync Prioritization

    /// Calculate overall performance score (higher = better peer)
    /// Used to rank peers for header sync AND block fetch - best peers tried first
    /// FIX #1097: Preferred peers get massive bonus to ensure they're selected first
    /// FIX #1100: Dynamic speed-based scoring - prefer fastest peers regardless of location
    func getPerformanceScore() -> Double {
        var score: Double = 0.0

        // FIX #1100: SPEED IS KING - fastest peers get highest bonus (0-500 points)
        // This dynamically prefers geographically closer peers based on ACTUAL measured speed
        // A user in US will naturally see US peers as faster, EU user will see EU peers faster
        if self.score.blockFetchSamples >= 3 {  // Need at least 3 samples for reliable average
            let avgSpeed = self.score.averageBlocksPerSecond
            // Scale: 200+ blocks/sec = 500 points, 100 = 250 points, 50 = 125 points
            score += min(500.0, avgSpeed * 2.5)
        }

        // FIX #1097: Preferred peer bonus (200 points) - REDUCED from 1000
        // Speed-based scoring now dominates - preferred peers only get small boost
        // This ensures actually fast peers beat slow "preferred" peers
        if isPreferredForDownload {
            score += 200.0
        }

        // Success rate (0-100 points)
        let totalAttempts = self.score.successCount + self.score.failureCount
        if totalAttempts > 0 {
            let successRate = Double(self.score.successCount) / Double(totalAttempts)
            score += successRate * 100.0
        }

        // Headers provided (0-50 points)
        if self.score.headersProvided > 0 {
            // Logarithmic scale - first few headers matter most
            score += min(50.0, log(1.0 + Double(self.score.headersProvided)) * 10)
        }

        // Chainwork validations (0-30 points) - critical for fork detection
        score += min(30.0, Double(self.score.chainworkValidations) * 5)

        // Recent activity bonus (0-20 points)
        if let lastSuccess = lastSuccess {
            let hoursSinceSuccess = Date().timeIntervalSince(lastSuccess) / 3600
            if hoursSinceSuccess < 1 {
                score += 20.0  // Very recent
            } else if hoursSinceSuccess < 6 {
                score += 10.0  // Recent
            } else if hoursSinceSuccess < 24 {
                score += 5.0   // Somewhat recent
            }
        }

        // Consecutive failures penalty
        if consecutiveFailures > 0 {
            score -= Double(consecutiveFailures) * 10.0
        }

        // FIX #1101: Consecutive slow fetches penalty (severe)
        // 3+ consecutive slow fetches = skip this peer for batch operations
        if self.score.consecutiveSlowFetches >= 3 {
            score -= 300.0  // Severe penalty - will be skipped
        } else if self.score.consecutiveSlowFetches >= 2 {
            score -= 100.0  // Moderate penalty
        }

        // Fast response time bonus (if we have data)
        if self.score.headerResponseTimeMs > 0 && self.score.headerResponseTimeMs < 1000 {
            score += 10.0  // Sub-second response
        } else if self.score.headerResponseTimeMs > 0 && self.score.headerResponseTimeMs < 5000 {
            score += 5.0   // Under 5 seconds
        }

        // Ensure score is non-negative
        return max(0, score)
    }

    /// Get detailed performance description for debug logging
    func getPerformanceDescription() -> String {
        let totalAttempts = score.successCount + score.failureCount
        let successRate = totalAttempts > 0 ? Double(score.successCount) / Double(totalAttempts) * 100 : 0
        let perfScore = getPerformanceScore()

        var desc = "\(host):\(port)"
        desc += " | Score: \(String(format: "%.1f", perfScore))"
        desc += " | Success: \(score.successCount)/\(totalAttempts) (\(String(format: "%.1f", successRate))%)"
        desc += " | Headers: \(score.headersProvided)"
        desc += " | Chainwork: \(score.chainworkValidations)"

        if score.headerResponseTimeMs > 0 {
            desc += " | Avg: \(String(format: "%.0f", score.headerResponseTimeMs))ms"
        }

        if consecutiveFailures > 0 {
            desc += " | Failures: \(consecutiveFailures)"
        }

        return desc
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

    /// FIX #419: Execute operation with exclusive access, but with lock acquisition timeout
    /// This prevents indefinite hangs when block listeners are holding the lock
    /// Throws NetworkError.timeout if lock cannot be acquired within the timeout
    func withExclusiveAccessTimeout<T>(seconds: Double, _ operation: () async throws -> T) async throws -> T {
        let acquired = await messageLock.acquireWithTimeout(seconds: seconds)
        guard acquired else {
            print("⚠️ FIX #419: Lock acquisition timed out after \(seconds)s for peer \(host)")
            throw NetworkError.timeout
        }
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
                // FIX #426: Check for cancellation BEFORE sleeping
                // The previous try? swallowed CancellationError, causing withTaskGroup to hang
                if Task.isCancelled {
                    throw CancellationError()
                }
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
        // FIX #856: Only attempt .onion connection if Tor is actually enabled
        if isOnion {
            let torEnabled = await TorManager.shared.mode == .enabled
            if !torEnabled {
                throw NetworkError.connectionFailed(".onion addresses require Tor to be enabled")
            }
            try await connectViaSocks5()
            return
        }

        // FIX #504 CRITICAL: localhost/127.0.0.1 should NEVER route through Tor!
        // Local node must connect directly for speed and reliability
        let isLocalhost = host == "127.0.0.1" || host == "localhost" || host.hasPrefix("192.168.") || host.hasPrefix("10.") || host.hasPrefix("172.16.")

        // FIX #1091 v3: REFUSE localhost connections in ZipherX mode!
        // ZipherX is pure P2P - there is NO local zclassic daemon to connect to.
        // This is a final safety check - filtering should also happen earlier in the pipeline.
        let isFullNodeMode = WalletModeManager.shared.isUsingWalletDat
        if isLocalhost && !isFullNodeMode {
            print("🚫 FIX #1091 v3: REFUSING localhost connection in ZipherX mode - no local node exists!")
            throw NetworkError.connectionFailed("Localhost not available in ZipherX mode")
        }

        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(integerLiteral: port))

        // Use Tor parameters if Tor is enabled (for privacy even with regular IPs)
        // CRITICAL: If Tor mode is enabled, ALWAYS use SOCKS5 (connectViaSocks5 will wait for Tor)
        // This prevents direct connections when Tor isn't ready yet
        // FIX #144: Check isTorBypassed - when bypassed, connect directly for speed
        // FIX #504: NEVER route localhost through Tor!
        let torEnabled = await TorManager.shared.mode == .enabled
        let torBypassed = await TorManager.shared.isTorBypassed
        if torEnabled && !torBypassed && !isLocalhost {
            // Route through Tor SOCKS5 proxy for privacy (will wait for Tor if not ready)
            // BUT NOT for localhost - local nodes connect directly!
            try await connectViaSocks5()
            return
        }
        // FIX #144: If Tor is bypassed, use direct connection for faster header sync
        // FIX #1549: Log bypass clearly so it's visible in logs for privacy auditing
        if torBypassed || isLocalhost {
            if isLocalhost {
                print("📡 [\(host)] Connecting directly (localhost - never through Tor)")
            } else if torEnabled {
                // FIX #1549: This should ONLY happen for explicit user-initiated actions (e.g. TX broadcast bypass)
                // If you see this in logs during peer growth/recovery, FIX #1549 has a gap
                print("⚠️ FIX #1549: [\(host)] Connecting directly (Tor BYPASSED — verify this is user-initiated)")
            } else {
                print("📡 [\(host)] Connecting directly (Tor not enabled)")
            }
        }

        // FIX #267: Configure TCP-level keepalive to prevent iOS from killing idle connections
        // iOS mobile networks are aggressive about dropping idle TCP connections
        // TCP keepalive is more reliable than app-level keepalive on mobile
        // FIX #1450: Relaxed keepalive on iOS (45s) to reduce battery drain.
        // 15s × 30 peers = 120 TCP packets/min was excessive. 45s × 8 peers = 10 packets/min.
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.enableKeepalive = true
        #if os(iOS)
        tcpOptions.keepaliveInterval = 45  // FIX #1450: 45s on iOS (battery)
        tcpOptions.keepaliveCount = 3      // 3 probes × 45s = 135s timeout
        #else
        tcpOptions.keepaliveInterval = 15  // 15s on macOS (always on power)
        tcpOptions.keepaliveCount = 2      // 2 probes × 15s = 30s timeout
        #endif
        tcpOptions.connectionTimeout = 15  // 15 second connection timeout
        // FIX #1287: Disable Nagle's algorithm — send getdata requests immediately.
        // Without this, small writes are buffered up to 200ms. Bitcoin Core sets this on all peers.
        tcpOptions.noDelay = true

        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        // Don't restrict to wifi - allow any network interface
        // parameters.requiredInterfaceType = .wifi

        // CRITICAL: Cancel old connection to prevent file descriptor leak
        // FIX #1039: Use safe cancel to prevent NWConnection warnings
        safeCancelConnection(connection)
        connection = nil

        connection = NWConnection(to: endpoint, using: parameters)

        // Add timeout for connection
        // FIX #152: Use withTaskCancellationHandler to ensure continuation resumes on cancellation
        // FIX #1043: Use class-based flag for thread-safe resumption tracking (same pattern as SOCKS5)
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

        return try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    let resumed = ResumedFlag()

                    // FIX #152: Check if task is already cancelled before starting
                    if Task.isCancelled {
                        if !resumed.checkAndSet() {
                            continuation.resume(throwing: CancellationError())
                        }
                        return
                    }

                    self.connection?.stateUpdateHandler = { state in
                        switch state {
                        case .ready:
                            if !resumed.checkAndSet() {
                                // FIX #545 v2: Removed viabilityUpdateHandler to prevent nw_connection warnings
                                // Keepalive pings (FIX #246) and path monitoring (FIX #268) already detect dead connections
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

                    // FIX #1043: Safety net - ensure continuation is always resumed
                    // FIX #1112 v4: Reduced from 6s to 2.5s - good peers connect in <1s
                    Task {
                        try? await Task.sleep(nanoseconds: 2_500_000_000) // 2.5s safety net
                        if !resumed.checkAndSet() {
                            continuation.resume(throwing: NetworkError.timeout)
                        }
                    }
                }
            }

            group.addTask {
                // FIX #1112 v4: Reduced from 5s to 2s - good peers connect in <1s
                try await Task.sleep(nanoseconds: 2_000_000_000) // 2 second timeout
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
        // FIX #1401: Rate-limit concurrent SOCKS5 handshakes to prevent Arti proxy saturation.
        // Without this, 45+ concurrent waiters pile up → 30s timeouts → task starvation.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility).async {
                socksSemaphore.wait()
                cont.resume()
            }
        }
        defer {
            socksSemaphore.signal()
        }

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
        // FIX #1450: Relaxed keepalive on iOS to reduce battery drain
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.enableKeepalive = true
        #if os(iOS)
        tcpOptions.keepaliveInterval = 45  // FIX #1450: 45s on iOS (battery)
        tcpOptions.keepaliveCount = 3      // 3 probes × 45s = 135s timeout
        #else
        tcpOptions.keepaliveInterval = 15  // 15s on macOS
        tcpOptions.keepaliveCount = 2      // 2 probes × 15s = 30s timeout
        #endif
        tcpOptions.connectionTimeout = 20  // Tor connections can be slower

        let parameters = NWParameters(tls: nil, tcp: tcpOptions)

        // CRITICAL: Cancel old connection to prevent file descriptor leak
        // FIX #1039: Use safeCancelConnection to avoid NWConnection warnings
        safeCancelConnection(connection)
        connection = nil

        connection = NWConnection(to: proxyEndpoint, using: parameters)

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
                                // FIX #545: Set viability handler AFTER connection is ready
                                // FIX #545 v2: Removed viabilityUpdateHandler to prevent nw_connection warnings
                                // Keepalive pings (FIX #246) and path monitoring (FIX #268) already detect dead connections
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
                // FIX #1538: 10s was too tight for iOS cellular Tor circuits (5-10s circuit + 1-2s SOCKS5).
                // z13.log: systematic 11s timeouts on ALL peers after initial batch.
                // iOS: 15s allows 2 full circuit attempts. macOS: 10s is fine on WiFi.
                #if os(iOS)
                try await Task.sleep(nanoseconds: 15_000_000_000) // 15s — Tor circuits slower on cellular
                #else
                try await Task.sleep(nanoseconds: 10_000_000_000) // 10s — macOS/WiFi
                #endif
                throw NetworkError.timeout
            }

            try await group.next()
            group.cancelAll()
        }

        // Perform SOCKS5 handshake
        do {
            try await performSocks5Handshake()
        } catch {
            // FIX #1538: On SOCKS5 handshake failure, trigger health check.
            // TorManager.checkSOCKS5Health() has threshold=2 and auto-restarts Tor.
            // Without this: NetworkManager counts to 5 before acting → 5 wasted connections.
            Task {
                let healthy = await TorManager.shared.checkSOCKS5Health()
                if !healthy {
                    print("🚨 FIX #1538: [\(self.host)] SOCKS5 health check triggered Tor restart")
                }
            }
            throw error
        }
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
            // FIX #1496: Guard against hostname >255 bytes — UInt8(_:) traps on overflow
            guard hostData.count <= 255 else {
                throw NetworkError.connectionFailed("SOCKS5 hostname too long (\(hostData.count) bytes, max 255): \(host)")
            }
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
    /// FIX #1178: Null connection to trigger block listener identity check exit
    /// FIX #1179: Do NOT cancel blockListenerTask — cancellation makes try? Task.sleep return
    /// instantly via CancellationError, causing listeners to die within 4ms of starting.
    /// The connection identity check (currentConn === startConnection) is sufficient.
    func disconnect() {
        // FIX #1179: Removed blockListenerTask?.cancel() — see comment above
        // FIX #509: Request graceful stop via state machine
        Task { await stopBlockListener() }

        connectionLock.lock()
        let conn = connection
        connection = nil  // FIX #1178: Block listener identity check will see this and exit
        connectionLock.unlock()
        // FIX #1039: Use safe cancel pattern to avoid NWConnection warnings
        safeCancelConnection(conn)
        isConnectedViaTor = false
    }

    /// FIX #1205: Track consecutive batch fetch failures for peer selection
    /// Peers that repeatedly return 0 blocks are skipped to avoid 30s timeouts
    private var _consecutiveBatchFailures: Int = 0
    private let _batchFailLock = NSLock()
    var consecutiveBatchFailures: Int {
        _batchFailLock.lock()
        defer { _batchFailLock.unlock() }
        return _consecutiveBatchFailures
    }
    func recordBatchResult(blocksReceived: Int) {
        _batchFailLock.lock()
        if blocksReceived == 0 {
            _consecutiveBatchFailures += 1
        } else {
            _consecutiveBatchFailures = 0
        }
        _batchFailLock.unlock()
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

    /// Check if P2P handshake is complete (version message received and validated)
    var isHandshakeComplete: Bool {
        // Handshake is complete when we have received and validated a version message
        // peerVersion > 0 means we received a version message
        // isValidZclassicPeer checks if the version is within valid range
        return peerVersion > 0 && isValidZclassicPeer
    }

    /// FIX #434 + FIX #1159: Check if peer is a valid Zclassic node (not Zcash or other chain)
    /// Zclassic uses protocol versions:
    ///   - 170010-170012 (Sapling + BIP155, older releases)
    ///   - 170100-170199 (v2.x.x releases, e.g., 170110 = v2.1.2)
    /// Zcash uses 170018+ (NU5 upgrades) - these return wrong Equihash params!
    var isValidZclassicPeer: Bool {
        // FIX #1159: Include Zclassic v2.x.x versions (170100-170199)
        let isOldZclassic = peerVersion >= Peer.minPeerProtocolVersion && peerVersion <= Peer.maxZclassicProtocolVersion
        let isZclassicV2 = peerVersion >= Peer.zclassicV2MinVersion && peerVersion <= Peer.zclassicV2MaxVersion
        return isOldZclassic || isZclassicV2
    }

    /// Check if connection is stale (idle for too long)
    private var isConnectionStale: Bool {
        guard let activity = lastActivity else {
            // Never used - consider stale if it's been a while since creation
            return true
        }
        return Date().timeIntervalSince(activity) > maxIdleTime
    }

    /// FIX #327: Check if peer had recent activity (for keepalive optimization)
    /// If block listener is receiving messages, we don't need to send ping
    /// FIX #1012: Use ACTIVITY_GRACE_PERIOD (90s) instead of hardcoded 60s
    /// This is derived from Zcash's PING_INTERVAL but slightly more conservative
    public var hasRecentActivity: Bool {
        guard let activity = lastActivity else { return false }
        // FIX #1012: If activity within grace period, peer is alive (no ping needed)
        return Date().timeIntervalSince(activity) < Peer.ACTIVITY_GRACE_PERIOD
    }

    /// FIX #327: Get seconds since last activity (for debugging)
    public var secondsSinceActivity: Int {
        guard let activity = lastActivity else { return -1 }
        return Int(Date().timeIntervalSince(activity))
    }

    /// Reconnect if connection is not ready or stale
    /// Minimum time between reconnection attempts (seconds)
    /// FIX #122: Reduced from 5s to 2s for faster header sync
    /// FIX #1012: Increased to 5s - 2s was too aggressive and caused connection spam
    /// Zcash nodes don't like rapid reconnection attempts (can trigger ban)
    private static let minReconnectInterval: TimeInterval = 5.0

    func ensureConnected() async throws {
        // FIX #915: CRITICAL - Only reconnect when connection is ACTUALLY dead
        //
        // In Bitcoin/Zclassic P2P protocol:
        // - Connection established ONCE with VERSION/VERACK handshake
        // - Connection stays open and is REUSED for all messages
        // - Reconnect ONLY when socket actually fails (read=0, error)
        //
        // Previous bug: `isConnectionStale` triggered reconnection after 180s idle
        // This was WRONG because idle connections are still valid!
        // The handshake on already-connected peers causes "Duplicate version" rejection.
        //
        // New logic: If connection shows `.ready` state, TRUST IT and use it.
        // Only reconnect when NWConnection state is not `.ready`.

        if isConnectionReady {
            // Connection is alive - don't touch it!
            // Mark activity so we know it's being used
            lastActivity = Date()
            return
        }

        // Connection is NOT ready - need to reconnect
        let connState = connection?.state
        print("🔄 FIX #915: [\(host)] Connection not ready (state: \(String(describing: connState))), reconnecting...")

        // FIX #1071 v2: If force reconnection is in progress, wait for it instead of hitting cooldown
        // This fixes the race condition where:
        // 1. forceReconnect() clears cooldowns and starts connecting
        // 2. forceReconnect() sets NEW cooldown when connect() is called
        // 3. ensureConnected() from sequential fallback hits that NEW cooldown → timeout
        // Solution: Wait up to 2 seconds for force reconnection to complete
        if isForceReconnecting {
            print("⏳ FIX #1071 v2: [\(host)] Force reconnection in progress, waiting...")
            for _ in 0..<20 {  // 20 × 100ms = 2 seconds max wait
                try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms
                if !isForceReconnecting && isConnectionReady {
                    print("✅ FIX #1071 v2: [\(host)] Force reconnection completed - connection now ready")
                    lastActivity = Date()
                    return
                }
            }
            // Force reconnect took too long or failed - proceed with normal reconnection
            print("⚠️ FIX #1071 v2: [\(host)] Force reconnection still in progress after 2s, proceeding...")
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

        // Disconnect old connection if exists
        if connection != nil {
            disconnect()
            // Small delay to ensure old connection is fully torn down
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }

        // Reconnect with fresh handshake
        try await connect()
        try await performHandshake()
        // FIX #1181: Removed drainBufferedMessages() — it left orphaned NWConnection readers
        // that desync TCP streams. receiveMessage() now resyncs on invalid magic instead.
        lastActivity = Date()
        print("✅ FIX #915: [\(host)] Reconnected successfully")
    }

    /// FIX #1069 v4: Force reconnect for fresh socket (ignores cooldown and current state)
    /// FIX #1070: Added safety check - caller should verify peer needs reconnection first
    /// Used BEFORE parallel block fetches to ensure all peers have clean TCP connections
    /// This prevents race conditions where block listener stale data corrupts subsequent reads
    /// Force reconnect this peer with a fresh TCP socket
    /// - Parameter bypassHealthCheck: If true, skip the health check and ALWAYS reconnect (for FIX #1071 v2)
    func forceReconnect(bypassHealthCheck: Bool = false) async {
        // FIX #1071 v2: Allow bypassing the health check for critical block fetches
        // The health check (isConnectionReady + activity < 10s) is UNRELIABLE:
        // - Peers can appear "healthy" but have dead TCP sockets
        // - This caused 100% fetch failures in PHASE 2 block fetches
        if !bypassHealthCheck {
            // FIX #1070: Safety check - if peer is already healthy, just mark active and return
            // This prevents "Duplicate version message" errors when called on healthy peers
            // (Bitcoin/Zclassic protocol: VERSION message can only be sent ONCE per TCP connection)
            let timeSinceActivity = Date().timeIntervalSince(lastActivity ?? Date.distantPast)
            if isConnectionReady && timeSinceActivity < 10.0 {
                // Connection is ready AND had activity in last 10 seconds - it's healthy
                print("✅ FIX #1070: [\(host)] Connection healthy (activity \(String(format: "%.1f", timeSinceActivity))s ago) - skipping reconnect")
                lastActivity = Date()  // Update activity timestamp
                return
            }
        }

        print("🔄 FIX #1071 v2: [\(host)] Force reconnecting for fresh socket (bypassHealthCheck=\(bypassHealthCheck))...")

        // FIX #1071 v2: Set flag to indicate force reconnection in progress
        // This prevents ensureConnected() from hitting the cooldown during concurrent calls
        isForceReconnecting = true
        defer { isForceReconnecting = false }

        // Force disconnect existing connection
        connectionLock.lock()
        let existingConn = connection
        connection = nil
        connectionLock.unlock()
        if let conn = existingConn {
            conn.forceCancel()
        }

        // Reset resync counter for fresh connection
        resyncCount = 0
        connectionUsedByBlockListener = false

        // FIX #1069 v4: Clear BOTH cooldowns to allow immediate reconnection
        // This is safe because forceReconnect is only called during pre-reconnection phase
        // where we intentionally want to reconnect all peers at once
        lastAttempt = nil

        // Clear GLOBAL cooldown for this host
        let hostKey = "\(host):\(port)"
        Self.globalConnectionLock.lock()
        Self.globalConnectionAttempts.removeValue(forKey: hostKey)
        Self.globalConnectionLock.unlock()

        // Small delay to ensure socket is fully torn down
        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms

        // Reconnect with fresh handshake (bypasses cooldown since lastAttempt is nil)
        do {
            try await connect()
            try await performHandshake()
            // FIX #1181: Removed drainBufferedMessages() — orphaned readers desync TCP
            lastActivity = Date()
            print("✅ FIX #1070: [\(host)] Force reconnect successful")
        } catch is CancellationError {
            // FIX #1096: Don't log CancellationError as failure
            // This is expected when task group cancels remaining tasks after reaching target peer count
            // Logging these clutters the log and confuses users (same pattern as FIX #1039)
            return
        } catch {
            print("❌ FIX #1070: [\(host)] Force reconnect failed: \(error)")
            // Don't throw - caller will skip this peer during batch fetch
        }
    }

    /// Update last activity timestamp (call after successful message exchange)
    func markActive() {
        lastActivity = Date()
    }

    // MARK: - Block Announcement Listener

    /// Start listening for block announcements in background
    /// Call this after handshake completes
    /// NOTE: The listener only runs when peer is idle (not busy with other operations)
    /// FIX #1069: Now uses state machine for predictable behavior
    func startBlockListener() {
        // FIX #907: Comprehensive check - block listeners can ONLY run when app is idle
        // This prevents block listeners from interfering with ANY operation:
        // - Header sync
        // - PHASE 1/1.5/2 scan
        // - Import
        // - Repair
        // - Broadcast
        if !PeerManager.shared.canStartBlockListeners() {
            let headerBlocked = PeerManager.shared.isHeaderSyncInProgress()
            let opsBlocked = PeerManager.shared.areBlockListenersBlocked()
            print("🛑 FIX #907: [\(host)] Block listener NOT started - headerSync=\(headerBlocked), opsBlocked=\(opsBlocked)")
            return
        }

        // FIX #1069: Atomic state transition: stopped → starting
        guard transitionTo(.starting, from: [.stopped]) else {
            print("📡 [\(host)] Block listener already running or starting, skipping")
            return
        }

        // Cancel any existing task just to be safe
        blockListenerTask?.cancel()
        blockListenerTask = nil

        // Create task ID for this listener instance
        let taskID = UUID()

        blockListenerTask = Task { [weak self] in
            guard let self = self else { return }

            // FIX #1178: Capture the connection we're starting on
            // If self.connection changes (reconnection), we MUST exit immediately
            // to prevent reading from a stale or new TCP stream (causes invalid magic bytes)
            guard let startConnection = self.connection else {
                _ = self.transitionTo(.stopped, from: nil)
                return
            }

            // FIX #1069: Transition to running state - if this fails, stopBlockListener was called
            // during the .starting state, so we should exit immediately
            let transitionSucceeded = self.transitionTo(.running(taskID: taskID), from: [.starting])
            guard transitionSucceeded else {
                // State was changed (likely to .stopping) - exit cleanly
                print("📡 FIX #1069: [\(LogRedaction.redactHost(self.host))] Block listener task exiting - state changed during startup")
                _ = self.transitionTo(.stopped, from: nil)
                return
            }

            // Add initial delay to let connection stabilize after handshake
            // This prevents reading garbage bytes that may be buffered
            // Longer delay for .onion peers (Tor), shorter for regular peers
            // FIX #1179: Use do/catch instead of try? to properly handle CancellationError
            // try? swallows CancellationError, making the sleep return instantly (0ms instead of 200ms)
            // which caused block listeners to die within 4ms of starting
            do {
                if self.isOnion {
                    print("📡 [\(LogRedaction.redactHost(self.host))] .onion peer - waiting 2s for Tor connection to stabilize...")
                    try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
                } else {
                    // Short delay for regular peers to let any pending handshake data clear
                    try await Task.sleep(nanoseconds: 200_000_000) // 200ms
                }
            } catch is CancellationError {
                // FIX #1179: Task was cancelled during stabilization — exit cleanly
                print("📡 FIX #1179: [\(LogRedaction.redactHost(self.host))] Block listener cancelled during stabilization delay")
                _ = self.transitionTo(.stopped, from: nil)
                return
            } catch {
                // Other errors during sleep — continue anyway
            }

            // FIX #1050: Suppress verbose log - block listener start is routine
            // print("📡 [\(self.host)] Block listener started")

            // FIX #1094: Activate dispatcher BEFORE entering main loop
            // This tells other operations to use the dispatcher pattern instead of direct reads
            // Without this, dispatcher.isActive is always false and the pattern is never used!
            await self.messageDispatcher.setActive(true)
            print("📡 FIX #1094: [\(LogRedaction.redactHost(self.host))] Dispatcher activated - block listener is sole reader")

            var consecutiveErrors = 0
            let maxConsecutiveErrors = 5

            // FIX #1069: Check state machine instead of _isListening flag
            // FIX #1178: Also check connection identity — if connection changed, exit immediately
            while case .running = self.getCurrentState(),
                  let currentConn = self.connection,
                  currentConn === startConnection {
                do {
                    // RACE CONDITION FIX: Acquire lock before receiving to prevent
                    // concurrent socket reads with other P2P operations.
                    // FIX #1495: Use acquireWithTimeout() instead of tryAcquire() + 500ms busy-wait.
                    // 8 iOS peers × 500ms polling = heavy cooperative thread pool saturation,
                    // CPU drain, and thermal throttling. acquireWithTimeout() parks the listener
                    // in a continuation-based waiter queue (zero polling overhead) and wakes
                    // immediately when the lock is released. GCD-backed 5s timeout ensures the
                    // state machine is rechecked even if task cancellation doesn't interrupt the wait.
                    let acquired = await self.messageLock.acquireWithTimeout(seconds: 5)
                    if !acquired {
                        // Lock still held after 5s — check for cancellation, then recheck state machine
                        try Task.checkCancellation()
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
                    // FIX #1184b: With the 500ms task group removed, timeout now means the
                    // 120s header receive timed out (peer sent nothing for 120s = dead peer).
                    // The connection was killed by receive(count:)'s GCD timeout.
                    // Exit the listener — health check will replace the peer.
                    print("📡 FIX #1184b: [\(LogRedaction.redactHost(self.host))] Block listener timeout (300s no data) — peer is dead, exiting")
                    break
                } catch is CancellationError {
                    // FIX #120: Listener was stopped - exit cleanly without error message
                    // FIX #1184b: Kill connection to prevent orphaned NWConnection.receive from
                    // desynchronizing the stream. When receive(count:24) is cancelled mid-wait,
                    // the NWConnection.receive callback stays registered. If the connection is
                    // reused (e.g., by header sync), the orphan fires first and consumes 24 bytes
                    // → "Invalid magic bytes". Killing the connection cancels all pending callbacks.
                    self.connectionLock.lock()
                    let conn = self.connection
                    self.connection = nil
                    self.connectionLock.unlock()
                    if let conn = conn {
                        self.safeCancelConnection(conn, force: true)
                        print("🔌 FIX #1184b: [\(LogRedaction.redactHost(self.host))] Killed connection after cancellation (orphan prevention)")
                    }
                    break
                } catch NetworkError.invalidMagicBytes {
                    // FIX #1175: Invalid magic bytes = stream is corrupted, stop immediately
                    // Retrying on a desynced stream just reads more garbage
                    // The peer will be replaced by health check recovery
                    print("🔌 FIX #1175: [\(LogRedaction.redactHost(self.host))] Invalid magic bytes in block listener - stopping (stream corrupted)")
                    break
                } catch {
                    // Connection closed or error - stop listening
                    if case .running = self.getCurrentState() {
                        print("📡 [\(LogRedaction.redactHost(self.host))] Block listener stopped: \(error.localizedDescription)")
                    }
                    break
                }
            }

            // FIX #1094: Deactivate dispatcher BEFORE transitioning state
            // This tells other operations to use direct reads since block listener is stopping
            await self.messageDispatcher.setActive(false)
            print("📡 FIX #1094: [\(LogRedaction.redactHost(self.host))] Dispatcher deactivated - block listener exiting")

            // FIX #1069: Transition to stopped state when task ends
            _ = self.transitionTo(.stopped, from: [.running(taskID: taskID), .stopping])
            print("📡 [\(LogRedaction.redactHost(self.host))] Block listener ended")
        }
    }

    /// FIX #822: Signal listener to stop without waiting (non-blocking)
    /// Used by PeerManager to quickly signal all listeners before waiting on them
    /// This allows listeners to start shutting down in parallel while we wait
    /// FIX #1069: Now uses state machine
    /// FIX #1248: Deactivate dispatcher synchronously for immediate effect
    func signalStopListener() {
        // FIX #1248: Deactivate dispatcher synchronously (non-async)
        // This can't be async since signalStopListener is synchronous, but we need to
        // deactivate the dispatcher ASAP. Use Task to do it without blocking the caller.
        // The actual stopBlockListener() will also deactivate (idempotent).
        Task {
            await messageDispatcher.setActive(false)
            print("🔓 FIX #1248: [\(host)] Dispatcher deactivated in signalStopListener")
        }

        // FIX #1069: Transition to stopping state (non-blocking)
        // Only transition from running - if already stopped/stopping, no-op
        stateLock.lock()
        let currentState = listenerState
        if case .running = currentState {
            listenerState = .stopping
            print("🔄 FIX #1069: [\(host)] Block listener: running → stopping (signal)")
        }
        let task = blockListenerTask
        stateLock.unlock()

        task?.cancel()  // Cancel the task (non-blocking)
    }

    /// Stop listening for block announcements
    /// FIX #509 v3: Wait for task to finish and release messageLock before returning
    /// This prevents race condition where header sync tries to acquire messageLock while listener holds it
    /// FIX #814: Add 2s timeout to prevent indefinite hang if task is stuck
    /// FIX #1069: Now uses state machine + unified GCD timeout (withReliableTimeout)
    /// FIX #1248: Deactivate dispatcher IMMEDIATELY to prevent lock timeout during header sync
    func stopBlockListener() async {
        // FIX #1248: Deactivate dispatcher synchronously BEFORE waiting for task
        // Previous bug: dispatcher stayed active while block listener task was stopping,
        // causing withExclusiveAccessTimeout(5s) in header sync to timeout waiting for messageLock.
        // The dispatcher was only deactivated INSIDE the task at line 2228, but if the task
        // was stuck on receiveMessage (120s timeout), the dispatcher remained active for up to
        // 120 seconds. This caused:
        // - Header sync tries withExclusiveAccessTimeout(seconds: 5.0) at line 720/936
        // - Block listener holds messageLock waiting for receive() to complete
        // - 5 second timeout expires → "Lock acquisition timed out" → peer disconnected
        // Deactivating immediately tells all operations to skip this peer for dispatcher-based
        // operations, preventing lock contention during the stop sequence.
        await messageDispatcher.setActive(false)
        print("🔓 FIX #1248: [\(host)] Dispatcher deactivated IMMEDIATELY on stop (preventing lock timeout)")

        // FIX #1069: Transition to stopping state - handle ALL states properly
        stateLock.lock()
        let currentState = listenerState
        if case .running = currentState {
            listenerState = .stopping
            print("🔄 FIX #1069: [\(host)] Block listener: running → stopping")
        } else if case .starting = currentState {
            // FIX #1069: Handle race condition - stop called while still starting
            // Task may not exist yet or just starting - set state to stopping
            listenerState = .stopping
            print("🔄 FIX #1069: [\(host)] Block listener: starting → stopping (race condition handled)")
        } else if case .stopped = currentState {
            stateLock.unlock()
            print("📡 [\(host)] Block listener already stopped")
            return
        } else if case .stopping = currentState {
            // Already stopping - just wait for it
            let task = blockListenerTask
            stateLock.unlock()
            print("📡 [\(host)] Block listener already stopping, waiting...")
            // Wait briefly for state to become stopped
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                if case .stopped = getCurrentState() {
                    return
                }
            }
            // FIX #1088: Timed out waiting for listener to stop - do full cleanup
            // Previous bug: just forced state to stopped without actually stopping the task
            // This left the task running and holding the lock for 12+ more seconds!
            print("⚠️ FIX #1088: [\(host)] Timed out waiting for listener stop - forcing cleanup")

            // Cancel the task
            task?.cancel()

            // FIX #1093: CRITICAL - Cancel connection BEFORE releasing lock!
            // Previous bug: forceRelease() then safeCancelConnection() created race window
            // where another operation acquired lock and started reading BEFORE connection
            // was cancelled → two concurrent readers → "Invalid magic bytes"
            print("🔌 FIX #1093: [\(host)] Cancelling connection to kill stuck receive FIRST")
            connectionLock.lock()
            let conn = connection
            connection = nil
            connectionLock.unlock()
            safeCancelConnection(conn, force: true)

            // NOW it's safe to release the lock - no stuck reader on this connection
            print("🔓 FIX #1093: [\(host)] Force releasing messageLock AFTER connection cancelled")
            await messageLock.forceRelease()

            // Force to stopped
            _ = transitionTo(.stopped, from: nil)
            return
        }
        let task = blockListenerTask
        stateLock.unlock()

        // Cancel the task
        task?.cancel()

        // FIX #814 + FIX #1069: Wait for task with reliable GCD-based 2 second timeout
        // GCD timeout is guaranteed to fire even when Swift thread pool is busy
        if let task = task {
            let completed = await withReliableTimeout(seconds: P2PTimeout.blockListenerStop) {
                _ = await task.value
                return true
            } onTimeout: {
                return false
            }

            if !completed {
                print("⚠️ FIX #814: [\(host)] Block listener stop timed out after \(P2PTimeout.blockListenerStop)s - proceeding anyway")

                // FIX #1093: CRITICAL - Cancel connection BEFORE releasing lock!
                // Previous bug (FIX #906/FIX #1072): forceRelease() then safeCancelConnection()
                // created race window where another operation acquired lock and started reading
                // BEFORE connection was cancelled → two concurrent readers → "Invalid magic bytes"
                print("🔌 FIX #1093: [\(host)] Cancelling connection to kill stuck receive FIRST")
                connectionLock.lock()
                let conn = connection
                connection = nil
                connectionLock.unlock()
                safeCancelConnection(conn, force: true)

                // NOW it's safe to release the lock - no stuck reader on this connection
                print("🔓 FIX #1093: [\(host)] Force releasing messageLock AFTER connection cancelled")
                await messageLock.forceRelease()

                // FIX #1069: Force state to stopped on timeout
                _ = transitionTo(.stopped, from: nil)
            }
        }

        // FIX #906: Verify lock is actually released before returning
        // Even without timeout, ensure lock is available for header sync
        let lockAvailable = await messageLock.tryAcquire()
        if lockAvailable {
            await messageLock.release()
            print("📡 [\(host)] Block listener stopped - messageLock verified available")
        } else {
            // FIX #1093: Lock still held - cancel connection BEFORE forceRelease
            // Same race condition fix: ensure no stuck reader before another can acquire
            print("⚠️ FIX #1093: [\(host)] messageLock still held - cancelling connection first")
            connectionLock.lock()
            let conn = connection
            connection = nil
            connectionLock.unlock()
            safeCancelConnection(conn, force: true)

            print("🔓 FIX #1093: [\(host)] Force releasing messageLock AFTER connection cancelled")
            await messageLock.forceRelease()
        }

        // FIX #875: Drain socket buffer to prevent TCP stream desync
        // Block listener may have in-flight data that arrived after we stopped
        // If not drained, next P2P operation will read stale data → INVALID MAGIC BYTES
        await drainSocketBuffer()
    }

    /// FIX #875: Drain any pending data from socket buffer
    /// Called after stopping block listener to clear stale data
    /// FIX #875 v2: More aggressive draining - longer timeouts, multiple rounds
    public func drainSocketBuffer() async {
        guard let conn = connection, conn.state == .ready else {
            return  // No connection or not ready
        }

        var drainedBytes = 0
        var iterations = 0
        let maxIterations = 20  // More iterations
        var consecutiveEmpty = 0
        let requiredEmptyRounds = 3  // Need 3 empty rounds to be sure

        while iterations < maxIterations && consecutiveEmpty < requiredEmptyRounds {
            iterations += 1

            // Try to read up to 256KB with longer timeout (200ms)
            // FIX #875 v2: Longer timeout catches large in-flight responses
            let drained = await withCheckedContinuation { (continuation: CheckedContinuation<Int, Never>) in
                var didResume = false

                // Set up timeout - 200ms to catch large block responses
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                    if !didResume {
                        didResume = true
                        continuation.resume(returning: 0)  // No data pending
                    }
                }

                // Try to receive any pending data (up to 256KB per read)
                conn.receive(minimumIncompleteLength: 1, maximumLength: 262144) { data, _, _, _ in
                    if !didResume {
                        didResume = true
                        continuation.resume(returning: data?.count ?? 0)
                    }
                }
            }

            if drained == 0 {
                consecutiveEmpty += 1
            } else {
                consecutiveEmpty = 0  // Reset counter if we got data
                drainedBytes += drained
            }
        }

        if drainedBytes > 0 {
            print("🚿 FIX #875: [\(host)] Drained \(drainedBytes) stale bytes from socket buffer (\(iterations) iterations)")
        }
    }

    /// FIX #906: Public method to force release message lock
    /// Called by PeerManager when stopAllBlockListeners times out
    /// This ensures header sync can use peers even if listeners are stuck
    /// FIX #1093: Cancel connection BEFORE releasing lock to prevent race condition
    /// FIX #1248: Deactivate dispatcher to prevent further lock contention
    public func forceReleaseMessageLock() async {
        // FIX #1248: Deactivate dispatcher FIRST
        // If we're force-releasing the lock, the block listener is stuck/dead.
        // Deactivate dispatcher so no other operations try to use this peer for
        // dispatcher-based operations (which would try to acquire the lock again).
        await messageDispatcher.setActive(false)
        print("🔓 FIX #1248: [\(host)] Dispatcher deactivated during force release")

        // FIX #1093: Cancel connection FIRST to kill any stuck reader
        // Previous bug: releasing lock while reader still active → another op acquires lock
        // → two concurrent readers → "Invalid magic bytes"
        print("🔌 FIX #1093: [\(host)] Cancelling connection before force releasing lock")
        connectionLock.lock()
        let conn = connection
        connection = nil
        connectionLock.unlock()
        safeCancelConnection(conn, force: true)

        // NOW safe to release the lock
        print("🔓 FIX #1093: [\(host)] Force releasing messageLock AFTER connection cancelled")
        await messageLock.forceRelease()
    }

    /// Receive message without blocking indefinitely (uses short timeout)
    private func receiveMessageNonBlocking() async throws -> (String, Data) {
        guard let connection = connection else {
            throw NetworkError.notConnected
        }

        // Use a short timeout to periodically check if we should stop
        // FIX #920: Timeout must disconnect to prevent TCP stream desync
        return try await withThrowingTaskGroup(of: (String, Data).self) { group in
            group.addTask {
                return try await self.receiveMessage()
            }

            group.addTask { [weak self] in
                // 30 second timeout - allows periodic check of listener state
                try await Task.sleep(nanoseconds: 30_000_000_000)
                // FIX #920: CRITICAL - Must disconnect on timeout
                // FIX #1039: Use safe cancel to avoid NWConnection warnings
                if let self = self {
                    self.connectionLock.lock()
                    let conn = self.connection
                    self.connection = nil
                    self.connectionLock.unlock()
                    self.safeCancelConnection(conn, force: true)
                }
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
        // FIX #1069: Use state machine instead of _isListening flag
        guard case .running = getCurrentState() else {
            throw CancellationError()
        }

        guard connection != nil else {
            throw NetworkError.notConnected
        }

        // FIX #1184b: REMOVED the 500ms task group timeout — it was the root cause of
        // permanent TCP stream desync on ALL peers.
        //
        // The old code raced receiveMessageTolerant() against a 500ms Task.sleep in a
        // withThrowingTaskGroup. Every 500ms cycle:
        //   1. Registered a new NWConnection.receive(count: 24) callback
        //   2. When 500ms fired, group.cancelAll() cancelled the Swift task
        //   3. FIX #1196 prevented the GCD timeout from killing the connection (good!)
        //   4. BUT the NWConnection.receive callback stayed registered in NWConnection's queue
        //   5. When data arrived, the orphaned callback consumed 24 bytes from the TCP buffer
        //   6. Those bytes were discarded (completionFlag already marked complete)
        //   7. All subsequent reads were offset by 24 bytes → permanent stream desync
        //   8. "Invalid magic in tolerant receive" on ALL peers
        //
        // With FIX #1184 (dispatcher-only routing), the block listener is the SOLE reader.
        // No other operation needs messageLock, so we can let receive(count:) block until
        // data arrives. ONE NWConnection.receive callback at a time = zero orphaned callbacks.
        //
        // FIX #1439: Increased from 120s to 300s. During witness rebuild / tree operations,
        // block listeners may be paused for 2-3 minutes. 120s killed good peers prematurely
        // causing peer count to drop to 1. 300s gives ample room for long operations.
        // Blocks come every ~75s, pings every ~60s. If 300s passes with zero data, the peer is truly dead.
        // For stopping: FIX #1196's withTaskCancellationHandler resumes the continuation
        // immediately on blockListenerTask?.cancel().
        return try await receiveMessageTolerant(headerTimeout: 300.0)
    }

    /// Tolerant receive that throws invalidMagicBytes instead of handshakeFailed
    /// FIX #1139: Added checksum validation - missing validation caused TCP stream desync!
    /// Without checksum validation, a corrupted message with wrong length field would
    /// read the wrong number of bytes, misaligning all subsequent reads.
    /// FIX #1181: On invalid magic, attempt resync (same as receiveMessage)
    /// FIX #1184b: Added headerTimeout parameter. FIX #1439: Block listener uses 300s (was 120s).
    ///            120s was too aggressive during witness rebuild — killed good peers.
    ///            Payload reads still use the default 15s since data should flow continuously.
    private func receiveMessageTolerant(headerTimeout: TimeInterval = P2PTimeout.messageReceive, killConnectionOnTimeout: Bool = true) async throws -> (String, Data) {
        // Read header (24 bytes) — use headerTimeout for the initial wait
        // FIX #1418: killConnectionOnTimeout=false for block listener short poll mode
        var header = try await receive(count: 24, timeout: headerTimeout, killConnectionOnTimeout: killConnectionOnTimeout)

        // FIX #1181: Verify magic — resync if invalid (unsolicited messages from peers)
        if Array(header.prefix(4)) != networkMagic {
            let gotMagic = Array(header.prefix(4)).map { String(format: "%02x", $0) }.joined()
            print("🔄 FIX #1181: [\(host)] Invalid magic in tolerant receive: \(gotMagic), attempting resync...")

            let maxScanBytes = isOnion ? 4096 : 65536
            var window = Array(header)
            var bytesScanned = 0
            var resyncSucceeded = false

            while bytesScanned < maxScanBytes {
                if window.count >= 4 && Array(window.prefix(4)) == networkMagic {
                    let bytesNeeded = 24 - window.count
                    if bytesNeeded > 0 {
                        let remaining = try await receive(count: bytesNeeded)
                        window.append(contentsOf: remaining)
                    }
                    if window.count >= 24 {
                        header = Data(window.prefix(24))
                        resyncCount += 1
                        if resyncCount > 5 {
                            print("🔌 FIX #1181: [\(host)] Too many resyncs in tolerant receive - disconnecting")
                            connectionLock.lock()
                            let conn = connection
                            connection = nil
                            connectionLock.unlock()
                            safeCancelConnection(conn, force: true)
                            throw NetworkError.invalidMagicBytes
                        }
                        print("✅ FIX #1181: [\(host)] Tolerant resync after \(bytesScanned) bytes (resync #\(resyncCount))")
                        resyncSucceeded = true
                        break
                    }
                }
                let nextByte = try await receive(count: 1)
                window.removeFirst()
                window.append(contentsOf: nextByte)
                bytesScanned += 1
            }

            if !resyncSucceeded {
                print("🔌 FIX #1181: [\(host)] Tolerant resync failed after \(bytesScanned) bytes - disconnecting")
                connectionLock.lock()
                let conn = connection
                connection = nil
                connectionLock.unlock()
                safeCancelConnection(conn, force: true)
                throw NetworkError.invalidMagicBytes
            }
        }

        // Parse command
        let commandBytes = header[4..<16]
        let command = String(bytes: commandBytes.prefix(while: { $0 != 0 }), encoding: .utf8) ?? ""

        // Parse length (safe loading)
        let length = header.loadUInt32(at: 16)

        // FIX #1365 / VUL-NET-004: Per-message payload size limits
        // FIX #1446: Zclassic headers are ~544 bytes each (140-byte header + 403-byte Equihash(192,7)
        // solution + 1-byte txcount), NOT 81 bytes like Bitcoin. Max 2000 headers/response = ~1,088,000.
        let maxSizeBL: UInt32 = {
            switch command {
            case "version", "verack": return 300
            case "ping", "pong": return 8
            case "addr": return 1_000 * 30 + 4
            case "inv", "getdata", "notfound": return 50_000 * 36 + 4
            case "headers": return 1_200_000   // FIX #1446: ~2200 Zclassic headers (544 bytes each)
            case "getheaders": return 14_000    // FIX #1446: request with block locators (~10 hashes)
            case "tx": return 100_000
            case "block": return 4_000_000
            case "reject": return 1_000
            case "mempool", "getaddr", "sendheaders": return 0
            default: return 4_000_000
            }
        }()
        guard length <= maxSizeBL else {
            print("⚠️  VUL-NET-004: Rejecting oversized '\(command)' payload: \(length) bytes (max \(maxSizeBL)) from \(host)")
            throw NetworkError.invalidData
        }

        // FIX #1139: Extract expected checksum from header (bytes 20-24)
        let expectedChecksum = header.loadUInt32(at: 20)

        // Read payload
        var payload = Data()
        if length > 0 {
            payload = try await receive(count: Int(length))
        }

        // FIX #1139: Validate checksum - doubleSHA256(payload).prefix(4)
        // This is CRITICAL: if we read wrong length due to corrupted header,
        // the checksum will fail and we detect the desync immediately!
        let payloadHash = payload.doubleSHA256()
        let actualChecksum = payloadHash.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }

        if actualChecksum != expectedChecksum {
            print("🚨 FIX #1139: [\(host)] Block listener checksum mismatch for '\(command)'!")
            print("   Expected: \(String(format: "0x%08x", expectedChecksum))")
            print("   Actual:   \(String(format: "0x%08x", actualChecksum))")
            print("   Payload size: \(payload.count) bytes")
            // Throw invalidMagicBytes to trigger block listener's retry logic
            throw NetworkError.invalidMagicBytes
        }

        return (command, payload)
    }

    /// FIX #883: Handle messages received in background listener - CENTRALIZED DISPATCHER
    /// Block listener is the SINGLE reader of TCP stream. ALL messages go through dispatcher first.
    /// Operations register handlers; dispatcher delivers messages to waiting handlers.
    private func handleBackgroundMessage(command: String, payload: Data) async {
        // FIX #883: ALWAYS try to dispatch through message dispatcher FIRST
        // This is the centralized message dispatcher pattern - block listener handles ALL responses
        let dispatched = await messageDispatcher.dispatch(command: command, payload: payload)
        if dispatched {
            // FIX #1440: Suppress repetitive dispatch logs for headers (fires 30+ times during sync)
            if command != "headers" {
                print("📨 FIX #883: [\(host)] Dispatched '\(command)' to waiting handler")
            }
            return  // Message was delivered to waiting operation
        }

        // FIX #883: Message not claimed by any operation - handle locally
        switch command {
        case "inv":
            // Parse inv for block announcements AND mempool transactions
            await handleInvMessage(payload: payload)

        case "ping":
            // Respond to pings to keep connection alive
            try? await sendMessage(command: "pong", payload: payload)

        case "tx":
            // FIX #883 + FIX #1333: Transaction received — fire callbacks for instant detection
            if payload.count >= 4 {
                let txid = Data(payload.doubleSHA256().reversed())
                // FIX #1333: Event-driven mempool detection — pass full raw TX for trial decryption.
                // This fires when our getdata (sent from handleInvMessage) gets a response.
                // NetworkManager.processIncomingMempoolTx does trial decrypt → instant notification.
                onMempoolTxData?(txid, payload)
                // Legacy callbacks
                await messageDispatcher.onMempoolTxSeen?(txid)
                onMempoolTx?(txid)
            }

        case "block":
            // FIX #883: Full block received - extract txids for confirmation detection
            handleBlockMessage(payload: payload)

        case "reject":
            // FIX #883: Reject not claimed by broadcast handler - log it
            parseAndLogReject(payload: payload)

        case "headers":
            // FIX #883: Headers not claimed - could be unsolicited announcement
            // Log but don't error (Zclassic nodes send unsolicited headers)
            print("📨 FIX #883: [\(host)] Received unclaimed 'headers' message (\(payload.count) bytes)")

        case "addr":
            // FIX #1522: Handle unsolicited addr messages — peers proactively share addresses
            // when they learn about new nodes. Previously silently discarded.
            let addresses = parseAddrPayload(payload)
            if !addresses.isEmpty {
                print("📡 FIX #1522: [\(host)] Received unsolicited 'addr' → \(addresses.count) addresses")
                onAddressesReceived?(addresses)
            }

        case "addrv2":
            // FIX #1522: Handle unsolicited addrv2 (BIP 155) — includes Tor .onion addresses
            let addresses = parseAddrV2Payload(payload)
            if !addresses.isEmpty {
                let onionCount = addresses.filter { $0.host.hasSuffix(".onion") }.count
                print("📡 FIX #1522: [\(host)] Received unsolicited 'addrv2' → \(addresses.count) addresses (\(onionCount) .onion)")
                onAddressesReceived?(addresses)
            }

        case "alert", "getdata", "notfound", "mempool", "getblocks", "getheaders":
            // Known P2P messages - ignore silently
            break

        default:
            // Unknown message type - log for debugging
            print("📨 FIX #883: [\(host)] Unknown message '\(command)' (\(payload.count) bytes)")
        }
    }

    /// FIX #883: Parse and log reject message that wasn't claimed by a handler
    private func parseAndLogReject(payload: Data) {
        guard payload.count > 0 else { return }
        var offset = 0
        // Message type (varint string)
        let msgLen = Int(payload[0])
        let msgType = String(data: payload[1..<min(1+msgLen, payload.count)], encoding: .utf8) ?? "?"
        offset = 1 + msgLen
        // Reject code
        var codeName = "UNKNOWN"
        if offset < payload.count {
            let code = payload[offset]
            let codeMap: [UInt8: String] = [
                0x01: "MALFORMED", 0x10: "INVALID", 0x11: "OBSOLETE", 0x12: "DUPLICATE",
                0x40: "NONSTANDARD", 0x41: "DUST", 0x42: "INSUFFICIENTFEE", 0x43: "CHECKPOINT"
            ]
            codeName = codeMap[code] ?? "UNKNOWN(\(code))"
        }
        print("⚠️ FIX #883: [\(host)] Unclaimed REJECT for '\(msgType)': \(codeName)")
    }

    /// FIX #1333: Unsolicited TX inv hashes — captured from unsolicited `inv` MSG_TX
    /// When a TX enters a peer's mempool, peer sends `inv` MSG_TX to all connections.
    /// Block listener receives it but handleInvMessage only processed MSG_BLOCK.
    /// Per Bitcoin P2P protocol, peer marks TX as "announced" → won't re-send via `mempool`.
    /// FIX: Capture these hashes and merge into getMempoolTransactions() results.
    private var unsolicitedTxHashes: [Data] = []
    private let unsolicitedTxLock = NSLock()

    /// FIX #1333: Callback for incoming raw mempool TX (event-driven detection)
    /// Called with (txid in display format, full raw TX) when a `tx` response arrives
    /// from our unsolicited inv getdata request. NetworkManager trial-decrypts here.
    var onMempoolTxData: ((Data, Data) -> Void)?

    /// FIX #883: Callback for mempool transaction notification (legacy)
    var onMempoolTx: ((Data) -> Void)?

    /// FIX #1522: Callback for unsolicited addr/addrv2 messages from peers.
    /// Zclassic nodes proactively broadcast addr messages when they learn about new peers.
    /// Previously silently discarded at line 2847 — now parsed and forwarded to NetworkManager.
    var onAddressesReceived: (([PeerAddress]) -> Void)?

    /// FIX #883: Callback for transaction confirmation (legacy)
    var onTxConfirmed: ((Data, UInt32) -> Void)?

    /// FIX #881: Parse block message and extract transaction IDs for confirmation detection
    private func handleBlockMessage(payload: Data) {
        guard payload.count >= 80 else { return }

        // Block header is first 80 bytes
        // Extract block hash (for logging)
        let blockHeader = payload.prefix(80)
        let blockHash = blockHeader.doubleSHA256().reversed()

        // Parse transaction count (varint after 80-byte header)
        var offset = 80
        guard offset < payload.count else { return }
        let (txCount, varIntSize) = readVarInt(from: payload, at: offset)
        offset += varIntSize

        // Extract transaction IDs from block
        var txids: [Data] = []
        for _ in 0..<txCount {
            guard offset + 4 <= payload.count else { break }

            // Read transaction version
            offset += 4

            // Parse transaction to get its total length and txid
            // This is complex - for now just extract first few txids
            // The full block is already validated by PoW, we just want txids
            if let txid = extractTxIdFromBlockOffset(payload: payload, offset: &offset) {
                txids.append(txid)
            }
        }

        // Notify about transactions in block (for confirmation detection)
        if !txids.isEmpty {
            let blockHeight: UInt32 = 0  // Height determined by NetworkManager from block hash
            for txid in txids {
                onTxConfirmed?(txid, blockHeight)
            }
        }
    }

    /// FIX #881: Extract txid from a transaction at given offset in block payload
    /// Returns the txid and advances offset past the transaction
    private func extractTxIdFromBlockOffset(payload: Data, offset: inout Int) -> Data? {
        let txStart = offset

        // Simplified extraction - just compute txid from transaction bytes
        // Full transaction parsing is complex, but we only need the txid
        guard txStart + 4 <= payload.count else { return nil }

        // For now, we rely on the inv messages which have txids
        // Full block parsing for confirmation would require complete TX parser
        // Return nil and let NetworkManager use inv-based confirmation
        return nil
    }

    /// Parse inv message and extract block announcements + unsolicited TX hashes
    /// FIX #1333: Now async — sends getdata for unsolicited TX inv for instant mempool detection
    private func handleInvMessage(payload: Data) async {
        guard payload.count >= 1 else { return }

        var offset = 0

        // Read count (varint)
        let (count, countSize) = readVarInt(from: payload, at: offset)
        offset += countSize

        var blockHashes: [Data] = []
        var txHashes: [Data] = []

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

            // FIX #1333: Capture unsolicited TX announcements (type 1)
            if invType == 1 {
                txHashes.append(hash)
            }
        }

        // FIX #1333: Store unsolicited TX hashes for mempool scanner fallback
        if !txHashes.isEmpty {
            unsolicitedTxLock.lock()
            unsolicitedTxHashes.append(contentsOf: txHashes)
            unsolicitedTxLock.unlock()
            print("🔮 FIX #1333: [\(host)] Unsolicited inv with \(txHashes.count) TX hash(es) — requesting full TX via getdata")

            // FIX #1333: Event-driven mempool detection — request full TXs immediately.
            // The `tx` responses will arrive through the block listener loop and be
            // handled by `case "tx":` which fires onMempoolTxData for trial decryption.
            // This is INSTANT vs the old 18-second polling approach.
            var getdataPayload = Data()
            // varint count
            var txCount = UInt64(txHashes.count)
            if txCount < 253 {
                getdataPayload.append(UInt8(txCount))
            } else {
                getdataPayload.append(0xFD)
                getdataPayload.append(contentsOf: withUnsafeBytes(of: UInt16(txCount).littleEndian) { Array($0) })
            }
            for hash in txHashes {
                // MSG_TX = 1
                getdataPayload.append(contentsOf: withUnsafeBytes(of: UInt32(1).littleEndian) { Array($0) })
                getdataPayload.append(hash)
            }
            do {
                try await sendMessage(command: "getdata", payload: getdataPayload)
            } catch {
                print("⚠️ FIX #1333: [\(host)] Failed to send getdata for unsolicited TXs: \(error.localizedDescription)")
            }
        }

        // Notify about new blocks
        if !blockHashes.isEmpty {
            print("📦 [\(host)] Received \(blockHashes.count) new block announcement(s)!")

            // FIX #1265: Update peer height on block announcement.
            // peerStartHeight is only set during VERSION handshake and never updated.
            // When a peer announces a new block via inv, they MUST know about it,
            // so their height is at least peerStartHeight + 1.
            // Without this, getChainHeight() returns stale heights until peers reconnect,
            // delaying TX confirmation detection by 2-10+ minutes.
            let newHeight = peerStartHeight + Int32(blockHashes.count)
            if newHeight > peerStartHeight {
                print("📊 FIX #1265: [\(host)] Updating peer height \(peerStartHeight) → \(newHeight) (block announcement)")
                peerStartHeight = newHeight
            }

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
                        // FIX #1050: Suppress verbose log - successful version is routine
                        // print("📡 [\(host)] Peer version: \(peerVersion), user-agent: \(peerUserAgent)")
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
                    // Zcash uses higher versions (170018+, 170020+, 170100+ for NU5)
                    // Don't alarm about "Sybil" - these are legitimate nodes for different chain
                    // FIX #229: Throw specific error so NetworkManager can permanently ban
                    // FIX #379: ALSO ban directly here - callers may not handle the error!
                    // FIX #428: Added 170018 detection - Zcash nodes demanding 170018+ are wrong chain
                    // FIX #455: Added 170016+170017 - these versions don't exist in Zclassic (max is 170012)
                    //         They're below Zcash's 170018 but still invalid for Zclassic
                    if let reason = lastRejectReason,
                       reason.contains("170016") || reason.contains("170017") ||
                       reason.contains("170018") || reason.contains("170019") ||
                       reason.contains("170020") || reason.contains("170100") {
                        print("⚠️ [\(host)] Wrong chain: Peer requires version 170016+ (Zclassic max is 170012)")
                        // FIX #379: Ban directly - don't rely on caller to do it
                        print("🚫 FIX #379: Banning Zcash peer \(host) directly from handshake")
                        await MainActor.run {
                            NetworkManager.shared.banPeerForSybilAttack(host)
                        }
                        // Still throw so caller knows connection failed
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

        // FIX #1050: Suppress verbose log - successful handshake is routine
        // print("📡 [\(host)] Handshake complete - supportsAddrv2: \(supportsAddrv2)")

        // FIX #915: isHandshakeComplete is now computed from peerVersion > 0 && isValidZclassicPeer
        // Setting peerVersion in the handshake loop above makes isHandshakeComplete return true
        recordSuccess()
        lastActivity = Date() // Mark connection as active after successful handshake
    }

    // FIX #1181: drainBufferedMessages() REMOVED — it used receiveMessageWithTimeout(destroyConnectionOnTimeout: false)
    // which left orphaned NWConnection readers. When the drain's last iteration timed out, the orphaned Task's
    // receive(count: 24) remained registered. A subsequent fetch operation's receive(count: 24) was registered AFTER
    // the orphaned header read but BEFORE its payload read. NWConnection delivers in registration order, so:
    //   1. Orphaned reader gets addr header (24 bytes)
    //   2. Fetch operation gets addr PAYLOAD (0xFD...) instead of next message header → "Invalid magic bytes"
    // Fix: receiveMessage() now resyncs on invalid magic for all peers (FIX #1181)

    private func parseVersionPayload(_ data: Data) {
        guard data.count >= 80 else {
            print("⚠️ [\(host)] Version payload too short: \(data.count) bytes (need 80+)")
            return
        }

        // Protocol version (bytes 0-3) - use safe loading
        peerVersion = data.loadInt32(at: 0)
        // FIX #1050: Suppress verbose log - version parsing is routine
        // print("🔍 FIX #478: [\(host)] Parsed version payload: peerVersion=\(peerVersion), payloadSize=\(data.count) bytes")

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
    /// FIX #1147: Use dispatcher when block listener is active to prevent TCP stream desync
    /// FIX #1521: Register expected responses BEFORE sending getaddr to prevent race condition.
    /// Old code: sendMessage("getaddr") → waitForResponse("addr") — if peer responded before
    /// handler was registered, the addr message was dispatched to NO handler and lost.
    /// Also: Zclassic nodes only respond to getaddr ONCE per connection (fSentAddr flag in main.cpp:6365).
    func getAddresses() async throws -> [PeerAddress] {
        // Check if dispatcher is active (block listener running)
        let dispatcherActive = await messageDispatcher.isActive

        if dispatcherActive {
            // FIX #1521: Pre-register expected responses BEFORE sending getaddr.
            // This ensures dispatch() queues the response if it arrives before
            // waitForResponseWithTimeout registers its handler.
            let expectedCommands = ["addr", "addrv2"]
            await messageDispatcher.expectCommands(expectedCommands)

            // FIX #1147: Use dispatcher pattern - block listener will deliver response
            try await sendMessage(command: "getaddr", payload: Data())

            // Wait for addr or addrv2 response via dispatcher
            // FIX #1521: Handler checks earlyResponses first (queued by dispatch)
            if let response = await messageDispatcher.waitForResponseWithTimeout(command: "addr", timeoutSeconds: 15) {
                let result = parseAddrPayload(response.1)
                // FIX #1514: Log response type and count
                print("📡 FIX #1514: \(host) responded with 'addr' (\(response.1.count) bytes) → \(result.count) addresses")
                await messageDispatcher.clearExpectedCommands(expectedCommands)
                return result
            } else if let response = await messageDispatcher.waitForResponseWithTimeout(command: "addrv2", timeoutSeconds: 5) {
                let result = parseAddrV2Payload(response.1)
                print("📡 FIX #1514: \(host) responded with 'addrv2' (\(response.1.count) bytes) → \(result.count) addresses")
                await messageDispatcher.clearExpectedCommands(expectedCommands)
                return result
            }
            // FIX #1521: Clean up expected commands on timeout
            await messageDispatcher.clearExpectedCommands(expectedCommands)
            print("📡 FIX #1514: \(host) — no addr/addrv2 response (timeout)")
            return []
        }

        // FIX #131: Fallback to direct reads when block listener not running
        // FIX #1521: Loop to skip unsolicited messages (e.g., getheaders) before addr.
        // Zclassic nodes often send getheaders before the addr response, and the old code
        // read ONE message, got getheaders, and gave up — wasting the one-time getaddr response.
        return try await withExclusiveAccess {
            try await sendMessage(command: "getaddr", payload: Data())

            // Read up to 5 messages looking for addr/addrv2 (skip unsolicited getheaders, ping, etc.)
            for attempt in 1...5 {
                let (command, response) = try await receiveMessage()

                switch command {
                case "addr":
                    let result = parseAddrPayload(response)
                    print("📡 FIX #1514: \(host) (direct) responded with 'addr' → \(result.count) addresses (after \(attempt) message(s))")
                    return result
                case "addrv2":
                    let result = parseAddrV2Payload(response)
                    print("📡 FIX #1514: \(host) (direct) responded with 'addrv2' → \(result.count) addresses (after \(attempt) message(s))")
                    return result
                default:
                    print("📡 FIX #1521: \(host) (direct) — skipping unsolicited '\(command)', waiting for addr (\(attempt)/5)")
                    continue
                }
            }
            print("📡 FIX #1514: \(host) (direct) — no addr/addrv2 after 5 messages")
            return []
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

        // NET-005: Cap at 100 addresses per peer response
        let cappedCount = min(count, 100)

        for _ in 0..<cappedCount {
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
            // Security audit TASK 18: Log redaction
            print("🧅 Discovered Tor v2 onion peer (addrv2): \(LogRedaction.redactAddress("\(onionAddress).onion"))")
            return "\(onionAddress).onion"

        case 0x04: // Tor v3 (32 bytes + 1 byte checksum version)
            guard addrBytes.count == 32 else { return nil }
            // Tor v3 onion address is base32(pubkey + checksum + version)
            // The pubkey is the 32 bytes we have, we need to add checksum + version
            let onionAddress = encodeOnionV3(publicKey: addrBytes)
            print("🧅 Discovered Tor v3 onion peer (addrv2): \(LogRedaction.redactAddress("\(onionAddress).onion"))")
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

        // FIX #1365 / Security audit TASK 9: Use proper CompactSize varint decoding for address count
        guard data.count > 0 else { return [] }
        guard let countValue = readCompactSize(from: data, at: &offset) else { return [] }
        let count = Int(countValue)
        // NET-005: Cap at 100 addresses per peer response (Zclassic sends up to 1000)
        // FIX #1523: Was `guard count <= 100 else { return [] }` — rejected ENTIRE payload
        // when count > 100 (all Zclassic nodes send 1000). Now caps iteration like parseAddrV2Payload.
        let cappedCount = min(count, 100)

        // Each addr entry: timestamp (4) + services (8) + IPv6 (16) + port (2) = 30 bytes
        let entrySize = 30

        for _ in 0..<cappedCount {
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

    /// FIX #1365 / Security audit TASK 9: Decode CompactSize varint per Bitcoin protocol
    /// - 0x00-0xFC: 1-byte value (direct)
    /// - 0xFD: next 2 bytes (UInt16 little-endian)
    /// - 0xFE: next 4 bytes (UInt32 little-endian)
    /// - 0xFF: next 8 bytes (UInt64 little-endian)
    private func readCompactSize(from data: Data, at offset: inout Int) -> UInt64? {
        guard offset < data.count else { return nil }
        let first = data[offset]
        offset += 1

        switch first {
        case 0x00...0xFC:
            return UInt64(first)
        case 0xFD:
            guard offset + 2 <= data.count else { return nil }
            let val = data[offset..<offset+2].withUnsafeBytes { $0.loadUnaligned(as: UInt16.self).littleEndian }
            offset += 2
            return UInt64(val)
        case 0xFE:
            guard offset + 4 <= data.count else { return nil }
            let val = data[offset..<offset+4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
            offset += 4
            return UInt64(val)
        case 0xFF:
            guard offset + 8 <= data.count else { return nil }
            let val = data[offset..<offset+8].withUnsafeBytes { $0.loadUnaligned(as: UInt64.self).littleEndian }
            offset += 8
            return UInt64(val)
        default:
            return nil
        }
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
            print("🧅 Discovered Tor v2 onion peer: \(LogRedaction.redactAddress("\(onionAddress).onion"))")
            return "\(onionAddress).onion"
        }

        // Check for IPv4-mapped IPv6 (::ffff:x.x.x.x)
        let ipv4Prefix: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff]
        if Array(bytes.prefix(12)) == ipv4Prefix {
            let ip = "\(bytes[12]).\(bytes[13]).\(bytes[14]).\(bytes[15])"
            // Validate: reject 255.255.x.x (invalid/reserved) and 0.x.x.x
            if bytes[12] == 255 && bytes[13] == 255 { return nil }
            if bytes[12] == 0 { return nil }
            // FIX #1365 / Security audit TASK 24: Validate reserved IPs
            if NetworkManager.shared.isReservedIPAddress(ip) { return nil }
            return ip
        }

        // Check for all-zeros prefix (alternative IPv4-mapped format)
        // Some implementations use 0:0:0:0:0:0:ffff:xxxx where ffff is in the 7th position
        if bytes[0...9].allSatisfy({ $0 == 0 }) && bytes[10] == 0xff && bytes[11] == 0xff {
            let ip = "\(bytes[12]).\(bytes[13]).\(bytes[14]).\(bytes[15])"
            // Validate: reject 255.255.x.x (invalid/reserved) and 0.x.x.x
            if bytes[12] == 255 && bytes[13] == 255 { return nil }
            if bytes[12] == 0 { return nil }
            // FIX #1365 / Security audit TASK 24: Validate reserved IPs
            if NetworkManager.shared.isReservedIPAddress(ip) { return nil }
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

        // FIX #478: Relay flag (1 byte) - True means we want transaction relay from peer
        // This was MISSING - peers might reject connections without this flag!
        payload.append(0x01)

        return payload
    }

    // MARK: - Message Protocol

    func sendMessage(command: String, payload: Data) async throws {
        // FIX #1365 / Security audit TASK 22: Rate limit outbound P2P messages
        // Skip rate limiting for ping/pong (keepalive must always go through)
        if command != "ping" && command != "pong" {
            await rateLimiter.waitForToken()
        }

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

        // FIX #915: Track send time (matches Zcash nLastSend)
        lastSend = Date()
    }

    func receiveMessage() async throws -> (String, Data) {
        // Read header (24 bytes)
        let header = try await receive(count: 24)

        // FIX #921: Validate we got exactly 24 bytes (should never fail due to FIX #922)
        guard header.count == 24 else {
            print("🚨 FIX #921: [\(host)] Incomplete header: got \(header.count) bytes, expected 24")
            // FIX #1039: Use safe cancel to avoid NWConnection warnings
            connectionLock.lock()
            let conn = connection
            connection = nil
            connectionLock.unlock()
            safeCancelConnection(conn, force: true)
            throw NetworkError.invalidMagicBytes
        }

        // Verify magic
        var actualHeader = header
        if Array(header.prefix(4)) != networkMagic {
            // FIX #1181: Invalid magic bytes — stream is desynced by unsolicited messages
            // Root cause: peers send addr/inv/addrv2 after handshake. If the stream is mid-payload
            // (e.g., orphaned reader consumed header but not payload), the next read gets payload data.
            // The bytes typically start with 0xFD (CompactSize for addr count > 252).
            //
            // FIX #1175 disconnected clear-net peers immediately, but this caused ALL peers to drop
            // after every reconnection. Now we resync ALL peers (not just .onion).
            // Magic bytes [0x24, 0xE9, 0x27, 0x64] are specific enough (1 in 4B false positive rate)
            // that scanning for them is safe.
            let receivedMagic = Array(header.prefix(4))
            // FIX #1181: Scan limit: 64KB for clear-net (skip addr payloads), 4KB for .onion
            let maxScanBytes = isOnion ? 4096 : 65536
            print("🔄 FIX #1181: [\(host)] Invalid magic bytes - got \(receivedMagic), scanning up to \(maxScanBytes/1024)KB for resync...")

            var window = Array(header)
            var bytesScanned = 0
            var resyncSucceeded = false

            while bytesScanned < maxScanBytes {
                if window.count >= 4 && Array(window.prefix(4)) == networkMagic {
                    let bytesNeeded = 24 - window.count
                    if bytesNeeded > 0 {
                        let remaining = try await receive(count: bytesNeeded)
                        window.append(contentsOf: remaining)
                    }

                    if window.count >= 24 {
                        actualHeader = Data(window.prefix(24))
                        resyncCount += 1
                        // FIX #1181: Allow more resyncs (5) since unsolicited messages are common
                        if resyncCount > 5 {
                            print("🔌 FIX #1181: [\(host)] Too many resyncs (\(resyncCount)) - disconnecting")
                            connectionLock.lock()
                            let conn = connection
                            connection = nil
                            connectionLock.unlock()
                            safeCancelConnection(conn, force: true)
                            throw NetworkError.streamDesync
                        }
                        print("✅ FIX #1181: [\(host)] Resynchronized after \(bytesScanned) bytes (resync #\(resyncCount))")
                        resyncSucceeded = true
                        break
                    }
                }

                let nextByte = try await receive(count: 1)
                window.removeFirst()
                window.append(contentsOf: nextByte)
                bytesScanned += 1
            }

            if !resyncSucceeded {
                print("🔌 FIX #1181: [\(host)] Failed to resync after \(bytesScanned) bytes - disconnecting")
                connectionLock.lock()
                let conn = connection
                connection = nil
                connectionLock.unlock()
                safeCancelConnection(conn, force: true)
                throw NetworkError.invalidMagicBytes
            }
        }

        // Parse command
        let commandBytes = header[4..<16]
        let command = String(bytes: commandBytes.prefix(while: { $0 != 0 }), encoding: .utf8) ?? ""

        // Parse length (safe loading)
        let length = header.loadUInt32(at: 16)

        // FIX #1365 / VUL-NET-004: Per-message payload size limits
        // FIX #1446: Zclassic headers are ~544 bytes each (140-byte header + 403-byte Equihash(192,7)
        // solution + 1-byte txcount), NOT 81 bytes like Bitcoin. Max 2000 headers/response = ~1,088,000.
        let maxSizeRM: UInt32 = {
            switch command {
            case "version", "verack": return 300
            case "ping", "pong": return 8
            case "addr": return 1_000 * 30 + 4
            case "inv", "getdata", "notfound": return 50_000 * 36 + 4
            case "headers": return 1_200_000   // FIX #1446: ~2200 Zclassic headers (544 bytes each)
            case "getheaders": return 14_000    // FIX #1446: request with block locators (~10 hashes)
            case "tx": return 100_000
            case "block": return 4_000_000
            case "reject": return 1_000
            case "mempool", "getaddr", "sendheaders": return 0
            default: return 4_000_000
            }
        }()
        guard length <= maxSizeRM else {
            print("⚠️  VUL-NET-004: Rejecting oversized '\(command)' payload: \(length) bytes (max \(maxSizeRM)) from \(host)")
            throw NetworkError.invalidData
        }

        // FIX #880: Extract checksum from header (bytes 20-24) - matches Zclassic main.cpp:6688-6695
        let expectedChecksum = header.loadUInt32(at: 20)

        // Read payload
        var payload = Data()
        if length > 0 {
            payload = try await receive(count: Int(length))
        }

        // FIX #880: Validate checksum - doubleSHA256(payload).prefix(4)
        // Zclassic/Bitcoin protocol: checksum = first 4 bytes of Hash(payload)
        // This catches corrupted data from TCP stream desync or malicious peers
        let payloadHash = payload.doubleSHA256()
        let actualChecksum = payloadHash.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }

        if actualChecksum != expectedChecksum {
            print("🚨 FIX #880: [\(host)] CHECKSUM MISMATCH for '\(command)' message!")
            print("   Expected: \(String(format: "0x%08x", expectedChecksum))")
            print("   Actual:   \(String(format: "0x%08x", actualChecksum))")
            print("   Payload size: \(payload.count) bytes")
            // Checksum mismatch means TCP stream is desynchronized - must reset connection
            connectionLock.lock()
            let conn = connection
            connection = nil
            connectionLock.unlock()
            safeCancelConnection(conn, force: true)
            throw NetworkError.invalidMagicBytes  // Treat as stream corruption
        }

        // FIX #915: Track receive time (matches Zcash nLastRecv)
        lastRecv = Date()

        return (command, payload)
    }

    /// FIX #112 + FIX #170: Receive P2P message with timeout to prevent infinite hangs
    /// This is critical for block fetches where the peer may drop connection silently
    /// FIX #170: NWConnection.receive() doesn't respond to Swift Task cancellation,
    /// so we use a workaround: cancel the connection to force the receive to fail
    /// FIX #181: Use class wrapper instead of UnsafeMutablePointer to prevent double-free crash
    /// FIX #1006: Added `destroyConnectionOnTimeout` parameter - false for mempool (expected timeout)
    /// FIX #1069: Use GCD-based timeout (reliable) instead of Task.sleep
    func receiveMessageWithTimeout(seconds: TimeInterval = 15, destroyConnectionOnTimeout: Bool = true) async throws -> (String, Data) {
        // FIX #181: Use class instead of UnsafeMutablePointer - ARC keeps it alive
        // until all closures release their reference (prevents double-free crash)
        // FIX #1069: Also tracks if receive completed to avoid racing destruction
        final class TimeoutState: @unchecked Sendable {
            var didTimeout = false
            var didComplete = false
            let lock = NSLock()
        }
        let state = TimeoutState()

        return try await withCheckedThrowingContinuation { continuation in
            var continuationResumed = false
            let continuationLock = NSLock()

            // Start the receive operation
            Task {
                do {
                    let result = try await self.receiveMessage()

                    // Mark as completed
                    state.lock.lock()
                    state.didComplete = true
                    let alreadyTimedOut = state.didTimeout
                    state.lock.unlock()

                    // Only resume if we haven't already timed out
                    if !alreadyTimedOut {
                        continuationLock.lock()
                        if !continuationResumed {
                            continuationResumed = true
                            continuationLock.unlock()
                            continuation.resume(returning: result)
                        } else {
                            continuationLock.unlock()
                        }
                    }
                } catch {
                    state.lock.lock()
                    let alreadyTimedOut = state.didTimeout
                    state.lock.unlock()

                    if !alreadyTimedOut {
                        continuationLock.lock()
                        if !continuationResumed {
                            continuationResumed = true
                            continuationLock.unlock()
                            continuation.resume(throwing: error)
                        } else {
                            continuationLock.unlock()
                        }
                    }
                }
            }

            // FIX #1069: GCD-based timeout (runs on separate thread pool, guaranteed to fire)
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [weak self] in
                state.lock.lock()
                state.didTimeout = true
                let alreadyCompleted = state.didComplete
                state.lock.unlock()

                if !alreadyCompleted {
                    // FIX #170: NWConnection doesn't respond to Swift cancellation
                    // Force-cancel the connection to unblock the receive
                    // FIX #184: Use lock for thread-safe access
                    // FIX #1006: Only destroy connection if requested (not for mempool expected timeouts)
                    // FIX #1039: Use safe cancel to avoid NWConnection warnings
                    if destroyConnectionOnTimeout, let self = self {
                        self.connectionLock.lock()
                        let conn = self.connection
                        self.connection = nil
                        self.connectionLock.unlock()
                        self.safeCancelConnection(conn, force: true)
                    }

                    continuationLock.lock()
                    if !continuationResumed {
                        continuationResumed = true
                        continuationLock.unlock()
                        continuation.resume(throwing: NetworkError.timeout)
                    } else {
                        continuationLock.unlock()
                    }
                }
            }
        }
    }

    // MARK: - FIX #246: Keepalive Ping

    /// Send a ping message and wait for pong response
    /// Used for keepalive to detect dead connections early
    /// FIX #869: Returns PingResult to distinguish between failure modes
    ///   - .success: Peer responded with valid pong
    ///   - .busy: Lock acquisition failed (peer busy with other operation)
    ///   - .timeout/.protocolError: Protocol issues - should count towards ban threshold
    ///   - .transientNetworkError: TCP-level issues - should NOT count towards ban threshold
    /// FIX #1148: Use dispatcher pattern when block listener is active to prevent TCP stream desync
    func sendPing(timeoutSeconds: TimeInterval = 10) async -> PingResult {
        guard isConnectionReady else {
            return .protocolError  // Not connected is a protocol issue
        }

        // Generate random nonce (8 bytes)
        var nonce = Data(count: 8)
        _ = nonce.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 8, $0.baseAddress!) }

        // FIX #1148: Check if dispatcher is active (block listener running)
        let dispatcherActive = await messageDispatcher.isActive

        if dispatcherActive {
            // FIX #1148: Use dispatcher pattern - block listener will deliver pong response
            do {
                try await sendMessage(command: "ping", payload: nonce)

                // Wait for pong response via dispatcher with timeout
                if let response = await messageDispatcher.waitForResponseWithTimeout(command: "pong", timeoutSeconds: timeoutSeconds) {
                    if response.1 == nonce {
                        lastActivity = Date()
                        return .success
                    } else {
                        // Wrong nonce - stale pong
                        return .protocolError
                    }
                } else {
                    return .timeout
                }
            } catch {
                let errorDesc = error.localizedDescription
                if errorDesc.contains("error 54") || errorDesc.contains("error 96") ||
                   errorDesc.contains("error 57") || errorDesc.contains("Connection reset") ||
                   errorDesc.contains("broken pipe") || errorDesc.contains("Not connected") {
                    return .transientNetworkError
                }
                return .protocolError
            }
        }

        // Fallback: Direct reads when block listener not running
        do {
            // FIX #724: Wrap ping in withExclusiveAccessTimeout to prevent race condition
            return try await withExclusiveAccessTimeout(seconds: 5) {
                // Send ping with nonce
                try await sendMessage(command: "ping", payload: nonce)

                // Loop to receive messages until we get matching pong or timeout
                let startTime = Date()
                var attempts = 0
                let maxAttempts = 50  // Prevent infinite loop

                while attempts < maxAttempts {
                    attempts += 1

                    // Check timeout
                    if Date().timeIntervalSince(startTime) > timeoutSeconds {
                        print("⚠️ FIX #246: [\(host)] Ping timeout after \(attempts) unsolicited messages")
                        return .timeout  // FIX #869: Protocol timeout - count towards ban
                    }

                    let (command, responseData) = try await receiveMessageWithTimeout(seconds: 1)

                    if command == "pong" && responseData == nonce {
                        // Got matching pong response
                        lastActivity = Date()
                        return .success
                    } else if command == "pong" {
                        // Got pong with wrong nonce (old response) - keep waiting
                        continue
                    } else if command == "ping" {
                        // Respond to peer's ping (they might be checking us too)
                        try? await sendMessage(command: "pong", payload: responseData)
                        continue
                    } else if command == "addr" {
                        // FIX #1522: Parse unsolicited addr and forward to NetworkManager
                        let addrs = parseAddrPayload(responseData)
                        if !addrs.isEmpty { onAddressesReceived?(addrs) }
                        continue
                    } else if command == "addrv2" {
                        // FIX #1522: Parse unsolicited addrv2 and forward
                        let addrs = parseAddrV2Payload(responseData)
                        if !addrs.isEmpty { onAddressesReceived?(addrs) }
                        continue
                    } else if command == "inv" || command == "headers" || command == "block" {
                        // Drain unsolicited messages - peer is alive, just chatty
                        continue
                    } else {
                        // Other unsolicited message - keep waiting
                        continue
                    }
                }

                // Too many attempts without matching pong
                print("⚠️ FIX #246: [\(host)] Ping gave up after \(maxAttempts) unsolicited messages")
                return .protocolError  // FIX #869: Protocol issue - count towards ban
            }
        } catch NetworkError.timeout {
            // FIX #724: Lock acquisition timed out - another operation is using the peer
            // This is not a connection failure, just skip this ping cycle
            print("⚠️ FIX #724: [\(host)] Ping skipped - peer busy with another operation")
            return .busy  // FIX #869: Peer is fine, just busy - don't count
        } catch {
            // FIX #868/869/872/879: Distinguish transient network errors from protocol errors
            // Transient: Connection reset (error 54), broken pipe, ENOMSG (error 96), ENOTCONN (error 57) - TCP layer issues
            // Protocol: Invalid magic bytes, wrong chain, handshake failures
            let errorDesc = error.localizedDescription
            // FIX #872: Added error 96 (ENOMSG - "No message available on STREAM") and
            // "Not connected to network" as transient errors - these indicate TCP connection
            // dropped, not a misbehaving peer
            // FIX #879: Added error 57 (ENOTCONN - "Socket is not connected") - iOS reports this
            // when TCP connection drops, especially common with Tor circuits
            let isTransientNetworkError = errorDesc.contains("error 54") ||
                                          errorDesc.contains("error 57") ||  // FIX #879: ENOTCONN
                                          errorDesc.contains("error 96") ||  // FIX #872: ENOMSG
                                          errorDesc.contains("Connection reset") ||
                                          errorDesc.contains("broken pipe") ||
                                          errorDesc.contains("Socket is not connected") ||  // FIX #879
                                          errorDesc.contains("Not connected") ||  // FIX #872
                                          errorDesc.contains("ECONNRESET") ||
                                          errorDesc.contains("ENOMSG") ||  // FIX #872
                                          errorDesc.contains("ENOTCONN") ||  // FIX #872
                                          errorDesc.contains("EPIPE")
            if isTransientNetworkError {
                print("⚠️ FIX #879: [\(host)] Ping failed (transient network error - not counting towards ban)")
                return .transientNetworkError  // FIX #869: Don't count towards ban
            } else {
                print("❌ FIX #246: [\(host)] Ping failed: \(errorDesc)")
                return .protocolError  // FIX #869: Protocol issue - count towards ban
            }
        }
    }

    // MARK: - FIX #247: P2P Transaction Verification

    /// Request a transaction via P2P getdata message
    /// Returns true if peer has the TX (responds with tx message), false if not found
    /// FIX #1149: Use dispatcher pattern when block listener is active to prevent TCP stream desync
    func requestTransaction(txid: Data) async throws -> Bool {
        guard isConnectionReady else {
            throw NetworkError.notConnected
        }

        // Build getdata message for MSG_TX (type 1)
        var payload = Data()
        payload.append(0x01)  // Count = 1
        var txType: UInt32 = 1  // MSG_TX
        payload.append(Data(bytes: &txType, count: 4))
        payload.append(txid)  // 32-byte hash

        // FIX #1149: Check if dispatcher is active (block listener running)
        let dispatcherActive = await messageDispatcher.isActive

        if dispatcherActive {
            // FIX #1149: Use dispatcher pattern - block listener will deliver response
            try await sendMessage(command: "getdata", payload: payload)

            // FIX #1201: Wait for EITHER "tx" OR "notfound" simultaneously
            // Previous code waited for "tx" 5s THEN "notfound" 1s sequentially.
            // If peer responded "notfound" during the 5s "tx" wait, the response was
            // dispatched with no handler registered → dropped. We always waited the
            // full 5s before checking notfound. Combined with verifyTxViaP2P's 5s
            // outer timeout, this caused CancellationError on EVERY peer → false
            // Sybil attack warnings even though TX was genuinely in the mempool.
            if let response = await messageDispatcher.waitForAnyResponseWithTimeout(
                commands: ["tx", "notfound"],
                timeoutSeconds: 6
            ) {
                if response.0 == "tx" && !response.1.isEmpty {
                    lastActivity = Date()
                    return true
                }
                // "notfound" or empty "tx" = peer doesn't have it
                return false
            }
            // Timeout with no response
            return false
        }

        // Fallback: Direct reads when block listener not running
        // FIX #354: Wrap in withExclusiveAccess to prevent race with block listener
        return try await withExclusiveAccess {
            try await sendMessage(command: "getdata", payload: payload)

            // FIX #354: Loop to drain buffered messages until we get tx/notfound
            var attempts = 0
            let maxAttempts = 5

            while attempts < maxAttempts {
                attempts += 1

                let (command, responseData) = try await receiveMessageWithTimeout(seconds: 3)

                if command == "tx" && !responseData.isEmpty {
                    lastActivity = Date()
                    return true
                } else if command == "notfound" {
                    return false
                } else if command == "ping" {
                    try await sendMessage(command: "pong", payload: responseData)
                    continue
                } else if command == "addr" {
                    // FIX #1522: Forward unsolicited addr
                    let addrs = parseAddrPayload(responseData)
                    if !addrs.isEmpty { onAddressesReceived?(addrs) }
                    continue
                } else if command == "inv" || command == "headers" || command == "block" {
                    // Drain buffered messages
                    continue
                } else {
                    continue
                }
            }

            return false
        }
    }

    /// Get raw transaction data via P2P getdata message
    /// Returns the raw transaction bytes, or nil if not found
    /// FIX #1150: Use dispatcher when block listener is active to prevent TCP stream desync
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

        // FIX #1150: Use dispatcher when block listener is active
        let dispatcherActive = await messageDispatcher.isActive
        if dispatcherActive {
            // Send via dispatcher - block listener will route response back
            try await sendMessage(command: "getdata", payload: payload)

            // FIX #1201: Wait for EITHER "tx" OR "notfound" simultaneously
            // Same fix as requestTransaction — sequential waits caused "notfound" to be
            // dropped during the "tx" wait, always hitting the full 10s timeout.
            if let response = await messageDispatcher.waitForAnyResponseWithTimeout(
                commands: ["tx", "notfound"],
                timeoutSeconds: 10
            ) {
                if response.0 == "tx" && !response.1.isEmpty {
                    lastActivity = Date()
                    return response.1
                }
                // "notfound" = peer doesn't have it
                return nil
            }

            // Timeout with no response
            return nil
        }

        // Fallback to direct reads when block listener is NOT active
        // FIX #354: Wrap in withExclusiveAccess to prevent race with block listener
        // FIX #570: Optimize timeouts for faster P2P verification
        return try await withExclusiveAccess {
            try await sendMessage(command: "getdata", payload: payload)

            // FIX #354: Loop to drain buffered messages until we get tx/notfound
            // FIX #570: Reduced maxAttempts from 10 to 5 and timeout from 10s to 3s
            var attempts = 0
            let maxAttempts = 5  // FIX #570: was 10

            while attempts < maxAttempts {
                attempts += 1

                // FIX #570: Reduced timeout from 10s to 3s for faster failure detection
                let (command, responseData) = try await receiveMessageWithTimeout(seconds: 3)

                if command == "tx" && !responseData.isEmpty {
                    lastActivity = Date()
                    return responseData
                } else if command == "notfound" {
                    return nil
                } else if command == "ping" {
                    try await sendMessage(command: "pong", payload: responseData)
                    continue
                } else if command == "addr" {
                    // FIX #1522: Forward unsolicited addr
                    let addrs = parseAddrPayload(responseData)
                    if !addrs.isEmpty { onAddressesReceived?(addrs) }
                    continue
                } else if command == "inv" || command == "headers" || command == "block" {
                    continue
                } else {
                    continue
                }
            }

            return nil
        }
    }

    // MARK: - Network I/O

    private func send(_ data: Data) async throws {
        guard let connection = connection else {
            throw NetworkError.notConnected
        }

        // FIX #714: Check connection state before sending
        // If connection is cancelled/failed, completion handler may never be called
        // causing "continuation leaked" error
        // FIX #929: Wait briefly for connection to become ready (handles transient states)
        if connection.state != .ready {
            // Wait up to 2 seconds for connection to become ready
            for _ in 0..<20 {
                try await Task.sleep(nanoseconds: 100_000_000) // 100ms
                if connection.state == .ready {
                    break
                }
                // Check for terminal states (cancelled or failed)
                if case .cancelled = connection.state {
                    throw NetworkError.notConnected
                }
                if case .failed(_) = connection.state {
                    throw NetworkError.notConnected
                }
            }
            // Final check after waiting
            guard connection.state == .ready else {
                throw NetworkError.notConnected
            }
        }

        // FIX #714: Add timeout to prevent continuation leak
        // FIX #1069: Use GCD-based timeout with completion flag (GCD can't be cancelled)
        return try await withCheckedThrowingContinuation { (outerContinuation: CheckedContinuation<Void, Error>) in
            var operationCompleted = false
            let completionLock = NSLock()

            // Start the actual send operation
            connection.send(content: data, completion: .contentProcessed { error in
                completionLock.lock()
                guard !operationCompleted else {
                    completionLock.unlock()
                    return // Timeout already fired
                }
                operationCompleted = true
                completionLock.unlock()

                if let error = error {
                    outerContinuation.resume(throwing: error)
                } else {
                    outerContinuation.resume()
                }
            })

            // FIX #1069: GCD-based timeout (separate thread pool - guaranteed to fire)
            DispatchQueue.global().asyncAfter(deadline: .now() + P2PTimeout.lockAcquire) {
                completionLock.lock()
                guard !operationCompleted else {
                    completionLock.unlock()
                    return // Send completed successfully, don't timeout
                }
                operationCompleted = true
                completionLock.unlock()

                outerContinuation.resume(throwing: NetworkError.timeout)
            }
        }
    }

    /// FIX #1196: Thread-safe completion flag for receive(count:) that can be shared
    /// between the NWConnection callback, GCD timeout, and withTaskCancellationHandler.
    /// Reference type so all three closures share the same instance.
    /// Also stores the continuation so onCancel can resume it (preventing continuation leaks).
    private final class ReceiveCompletionFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var completed = false
        private var storedContinuation: CheckedContinuation<Data, Error>?

        func storeContinuation(_ continuation: CheckedContinuation<Data, Error>) {
            lock.lock()
            storedContinuation = continuation
            lock.unlock()
        }

        /// Atomically try to mark as complete. Returns true if this call completed it,
        /// false if it was already completed by another path.
        func tryComplete() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !completed else { return false }
            completed = true
            return true
        }

        /// Cancel: mark complete and resume continuation with CancellationError
        func cancel() {
            lock.lock()
            guard !completed else { lock.unlock(); return }
            completed = true
            let cont = storedContinuation
            storedContinuation = nil
            lock.unlock()
            cont?.resume(throwing: CancellationError())
        }
    }

    /// FIX #1184b: Added `timeout` parameter so block listener can use a longer header timeout.
    /// Default remains P2PTimeout.messageReceive (15s) for normal operations.
    private func receive(count: Int, timeout: TimeInterval = P2PTimeout.messageReceive, killConnectionOnTimeout: Bool = true) async throws -> Data {
        guard let connection = connection else {
            throw NetworkError.notConnected
        }

        // FIX #714: Check connection state before receiving
        // FIX #929: Wait briefly for connection to become ready (handles transient states)
        if connection.state != .ready {
            // Wait up to 2 seconds for connection to become ready
            for _ in 0..<20 {
                try await Task.sleep(nanoseconds: 100_000_000) // 100ms
                if connection.state == .ready {
                    break
                }
                // Check for terminal states (cancelled or failed)
                if case .cancelled = connection.state {
                    throw NetworkError.notConnected
                }
                if case .failed(_) = connection.state {
                    throw NetworkError.notConnected
                }
            }
            // Final check after waiting
            guard connection.state == .ready else {
                throw NetworkError.notConnected
            }
        }

        // FIX #714: Add timeout to prevent continuation leak
        // FIX #920: CRITICAL - Timeout must disconnect to prevent TCP stream desync
        // FIX #1069: Use GCD-based timeout with completion flag
        // GCD runs on separate thread pool from Swift concurrency, guaranteeing timeout fires
        // BUT: GCD block cannot be cancelled by group.cancelAll() - need completion flag!
        // FIX #1196: Use withTaskCancellationHandler to set completion flag when task is cancelled.
        // Without this, group.cancelAll() in receiveMessageNonBlockingTolerant leaves the GCD
        // timeout alive. 15s later, the stale GCD timeout fires, sees operationCompleted==false,
        // sets connection=nil → block listener's while condition fails → dispatcher deactivates.

        // FIX #1196: Use reference-type flag so withTaskCancellationHandler's onCancel
        // can access the same flag instance as the continuation and GCD timeout
        let completionFlag = ReceiveCompletionFlag()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { [weak self] (outerContinuation: CheckedContinuation<Data, Error>) in
                // FIX #1196: Store continuation so onCancel can resume it (prevents leak)
                completionFlag.storeContinuation(outerContinuation)

                // Start the actual receive operation
                connection.receive(minimumIncompleteLength: count, maximumLength: count) { [weak self] data, _, isComplete, error in
                    guard completionFlag.tryComplete() else { return } // Timeout or cancellation already fired

                    if let error = error {
                        outerContinuation.resume(throwing: error)
                    } else if let data = data {
                        // FIX #922: NWConnection can return partial data if connection closes
                        if data.count == count {
                            outerContinuation.resume(returning: data)
                        } else {
                            let hostForLog = self?.host ?? "unknown"
                            print("⚠️ FIX #922: [\(hostForLog)] Partial data: got \(data.count)/\(count) bytes, isComplete=\(isComplete)")
                            outerContinuation.resume(throwing: NetworkError.timeout)
                        }
                    } else {
                        outerContinuation.resume(throwing: NetworkError.timeout)
                    }
                }

                // FIX #1069: GCD-based timeout (separate thread pool - guaranteed to fire)
                // FIX #920: Increased from 3s to P2PTimeout.messageReceive (15s) for block data
                // FIX #1184b: Use configurable timeout (120s for block listener header, 15s for payload)
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                    guard completionFlag.tryComplete() else { return } // Already completed or cancelled

                    // FIX #920: CRITICAL - Must disconnect on GENUINE timeout!
                    // If we're here, the receive is stuck (no data for the full timeout) -
                    // disconnect to prevent TCP stream desync from orphaned NWConnection.receive
                    // FIX #1196: This only fires for genuine stuck receives, NOT for cancelled tasks
                    // FIX #1418: When killConnectionOnTimeout=false (block listener short poll),
                    // DON'T kill the connection — just throw timeout so caller can check stop flag.
                    // The orphaned NWConnection.receive callback is harmless here because we'll
                    // immediately re-enter the same receive loop (no other reader).
                    if killConnectionOnTimeout {
                        if let self = self {
                            self.connectionLock.lock()
                            let conn = self.connection
                            self.connection = nil
                            self.connectionLock.unlock()
                            self.safeCancelConnection(conn, force: true)
                        }
                    }
                    outerContinuation.resume(throwing: NetworkError.timeout)
                }
            }
        } onCancel: {
            // FIX #1196: Task was cancelled (e.g., by stopBlockListener).
            // Mark flag complete so the stale GCD timeout does NOT kill the connection.
            // Also resume the continuation with CancellationError to prevent leak.
            // Without this, the GCD timeout fires later → connection=nil → dispatcher dies.
            completionFlag.cancel()
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
        // FIX #1028: CRITICAL - Align with Bitcoin/Zclassic P2P protocol
        // From Zclassic main.cpp lines 6253-6267:
        //   - If TX invalid → peer sends "reject" message IMMEDIATELY (<100ms)
        //   - If TX valid → peer stays SILENT (no response = accepted into mempool)
        // This is standard Bitcoin protocol behavior!

        // Compute TX ID first for logging
        let txId = rawTx.doubleSHA256().reversed()
        let txIdString = txId.map { String(format: "%02x", $0) }.joined()

        // FIX #1184: Route through dispatcher when block listener is active
        // This eliminates orphaned NWConnection readers from receiveMessageWithTimeout
        let dispatcherActive = await messageDispatcher.isActive
        if dispatcherActive {
            return try await broadcastTransactionViaDispatcher(rawTx: rawTx, txIdString: txIdString)
        }

        // Fallback: Direct read when dispatcher is not active (startup, repair)
        return try await broadcastTransactionDirect(rawTx: rawTx, txIdString: txIdString)
    }

    /// FIX #1184: Broadcast through dispatcher — zero orphaned readers
    /// Block listener dispatches reject messages to our waiting handler
    private func broadcastTransactionViaDispatcher(rawTx: Data, txIdString: String) async throws -> String {
        print("📡 FIX #1184: Broadcasting via dispatcher, txid: \(txIdString.prefix(16))...")

        // Send TX — no lock needed, just a socket write
        do {
            try await sendMessage(command: "tx", payload: rawTx)
            print("📡 FIX #1184: TX sent to peer via dispatcher path")
        } catch {
            print("❌ FIX #1184: Send FAILED: \(error.localizedDescription)")
            throw error
        }

        // Wait for reject via dispatcher (1s timeout — Sapling proof validation ~100-500ms)
        // Silence (timeout) = TX accepted per Bitcoin protocol
        let result = await messageDispatcher.waitForBroadcastResultWithTimeout(
            txid: txIdString,
            timeoutSeconds: 1.0
        )

        if let (_, response) = result {
            // Got a reject — parse it
            return try parseBroadcastReject(response: response, txIdString: txIdString, prefix: "FIX #1184")
        }

        // nil = timeout = silence = TX ACCEPTED
        print("✅ FIX #1184: No reject via dispatcher = TX ACCEPTED (silence = success)")
        return txIdString
    }

    /// Fallback: Direct broadcast when dispatcher is not active (startup, repair)
    private func broadcastTransactionDirect(rawTx: Data, txIdString: String) async throws -> String {
        print("📡 FIX #1184: Broadcasting via direct path (dispatcher inactive), txid: \(txIdString.prefix(16))...")

        return try await withExclusiveAccessTimeout(seconds: 2) {
            // FIX #1028: Send the TX
            do {
                try await sendMessage(command: "tx", payload: rawTx)
                print("📡 FIX #1048: TX sent to peer (direct), txid: \(txIdString.prefix(16))...")
            } catch {
                print("❌ FIX #1048: Send FAILED: \(error.localizedDescription)")
                throw error
            }

            // FIX #1048: Wait for reject with timeout (single attempt)
            do {
                let (command, response) = try await receiveMessageWithTimeout(seconds: 0.5, destroyConnectionOnTimeout: false)

                if command == "reject" {
                    return try parseBroadcastReject(response: response, txIdString: txIdString, prefix: "FIX #1048")
                }

                // Got non-reject, wait once more
                print("⚠️ FIX #882: Got '\(command)' (not reject) - waiting for actual verdict...")
                do {
                    let (cmd2, response2) = try await receiveMessageWithTimeout(seconds: 0.5, destroyConnectionOnTimeout: false)
                    if cmd2 == "reject" {
                        return try parseBroadcastReject(response: response2, txIdString: txIdString, prefix: "FIX #882")
                    }
                    print("✅ FIX #882: No reject after second wait = TX ACCEPTED")
                    return txIdString
                } catch NetworkError.timeout {
                    print("✅ FIX #882: Timeout after non-reject = TX ACCEPTED (silence = success)")
                    return txIdString
                }
            } catch NetworkError.timeout {
                print("✅ FIX #1048: No reject in 500ms = TX ACCEPTED (silence = success)")
                return txIdString
            }
        }
    }

    /// Parse a reject message from broadcast and throw appropriate error
    /// Returns txIdString on DUPLICATE (which is actually success), throws otherwise
    private func parseBroadcastReject(response: Data, txIdString: String, prefix: String) throws -> String {
        var offset = 0
        if response.count > 0 {
            let msgLen = Int(response[0])
            offset = 1 + msgLen
        }
        if offset < response.count {
            let rejectCode = response[offset]
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

            print("❌ \(prefix): TX REJECTED by peer: \(codeName) - \(reason)")
            if rejectCode == 0x12 {
                // DUPLICATE = TX already in mempool = actually SUCCESS!
                print("✅ \(prefix): DUPLICATE means TX is in mempool = SUCCESS!")
                throw NetworkError.transactionDuplicateRejected
            }
            throw NetworkError.transactionRejected
        }
        // Couldn't parse reject code — treat as generic rejection
        throw NetworkError.transactionRejected
    }

    func getBlockHeaders(from height: UInt64, count: Int) async throws -> [BlockHeader] {
        // FIX #914: REMOVED retry-with-reconnect logic
        // During parallel operations, multiple peers trying to reconnect simultaneously
        // causes race conditions and "Peer handshake failed" errors.
        // If this peer fails, caller (NetworkManager) should try a different peer.
        return try await getBlockHeadersInternal(from: height, count: count)
    }

    private func getBlockHeadersInternal(from height: UInt64, count: Int) async throws -> [BlockHeader] {
        // FIX #565: Cap request count at MAX_HEADERS_RESULTS to match Zclassic protocol
        // This prevents overwhelming peers with excessive header requests
        let cappedCount = min(count, MAX_HEADERS_RESULTS)

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

        // FIX #671: If requesting beyond HeaderStore range, cap at latest available height
        // This prevents falling back to ancient checkpoints
        var actualLocatorHeight = locatorHeight
        let headerStoreMaxHeight = (try? HeaderStore.shared.getLatestHeight()) ?? 0
        if locatorHeight > headerStoreMaxHeight && headerStoreMaxHeight > 0 {
            actualLocatorHeight = headerStoreMaxHeight
            debugLog(.network, "📋 FIX #671: Requesting height \(locatorHeight) beyond HeaderStore (\(headerStoreMaxHeight)), using \(headerStoreMaxHeight)")
        }

        // Try 1: HeaderStore (cached headers)
        if let lastHeader = try? HeaderStore.shared.getHeader(at: actualLocatorHeight) {
            locatorHash = lastHeader.blockHash
            debugLog(.network, "📋 getBlockHeaders: Using HeaderStore hash for locator at height \(actualLocatorHeight)")
        }

        // Try 2: Checkpoints
        if locatorHash == nil, let checkpointHex = ZclassicCheckpoints.mainnet[locatorHeight] {
            if let hashData = Data(hexString: checkpointHex) {
                locatorHash = Data(hashData.reversed())  // Convert to wire format
                debugLog(.network, "📋 getBlockHeaders: Using checkpoint for locator at height \(locatorHeight)")
            }
        }

        // Try 3: BundledBlockHashes - FIX #669: DISABLED (data corruption bug)
        // FIX #874: Removed warning print - was causing excessive log entries during startup
        // BundledBlockHashes is completely disabled, no need to check or log

        // Try 4: Find nearest checkpoint BELOW the requested height
        // FIX #673: Skip checkpoint fallback if HeaderStore was recently cleared (wrong fork!)
        if locatorHash == nil {
            // Check if HeaderStore was recently cleared (maxHeight < currentHeight - 10000)
            let headerStoreMaxHeight = (try? HeaderStore.shared.getLatestHeight()) ?? 0
            let headerStoreRecentlyCleared = (headerStoreMaxHeight > 0) && (height > headerStoreMaxHeight + 10000)

            if !headerStoreRecentlyCleared {
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
            } else {
                // FIX #673: HeaderStore recently cleared - checkpoint might be on wrong fork
                // Use genesis block (zero hash) to force full resync from beginning
                debugLog(.network, "📋 FIX #673: HeaderStore recently cleared (\(headerStoreMaxHeight) < \(height)), using genesis hash to force full resync")
            }
        }

        // Append locator hash (or zero hash as last resort - will get genesis headers)
        if let hash = locatorHash {
            payload.append(hash)
        } else {
            debugLog(.network, "📋 getBlockHeaders: No locator found for height \(locatorHeight), using zero hash (will sync from genesis)")
            payload.append(Data(count: 32))
        }

        // Stop hash (zeros = get maximum headers)
        payload.append(Data(count: 32))

        // FIX #1231: CRITICAL - Do NOT use receiveMessageWithTimeout(..., destroyConnectionOnTimeout: false)
        // inside withExclusiveAccessTimeout. This violates FIX #1181's orphaned reader pattern:
        // When the outer timeout fires, the inner receiveMessageWithTimeout has already registered
        // an NWConnection.receive(count:) callback that persists in the GCD queue. This orphaned
        // reader consumes the `headers` response when it eventually arrives, desyncing the TCP stream.
        // Solution: Use destroyConnectionOnTimeout: true. The outer lock will be released by the defer,
        // and the connection will be killed cleanly if timeout occurs (no orphaned readers).
        let response = try await withExclusiveAccessTimeout(seconds: 30) {
            try await self.sendMessage(command: "getheaders", payload: payload)

            // FIX #1236: Use 0.5s timeout for draining unsolicited messages (was 30s)
            var attempts = 0
            while attempts < 10 {
                let (cmd, resp) = try await self.receiveMessageWithTimeout(seconds: 0.5, destroyConnectionOnTimeout: true)
                if cmd == "headers" {
                    return resp
                }
                print("⏭️ FIX #1236: [\(LogRedaction.redactHost(self.host))] Skipping '\(cmd)' while waiting for headers (attempt \(attempts+1)/10)")
                attempts += 1
            }
            throw NetworkError.timeout
        }

        // Parse headers response
        var headers: [BlockHeader] = []
        var offset = 0

            // FIX #565: Read header count as varint (compact size), not single byte!
            // Zclassic uses ReadCompactSize for the count (see main.cpp:6276)
            guard response.count >= 1 else { return [] }
            let (headerCountRaw, varintSize) = readCompactSize(response, at: offset)
            let headerCount = Int(min(headerCountRaw, UInt64(count)))  // Cap at requested count
            offset += varintSize

            print("📋 [\(host)] getBlockHeaders: Read varint count=\(headerCountRaw) (requested \(count)), parsing \(headerCount) headers")

            // FIX #207: Parse headers with variable-length solution
            // Structure: 140 bytes header + varint + solution (400 bytes) + 1 byte tx_count
            for _ in 0..<headerCount {
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

                // Zclassic post-Bubbles uses Equihash(192,7) with 400-byte solutions
                // Pre-Bubbles uses Equihash(200,9) with 1344-byte solutions
                // Debug: Log unexpected solution sizes to diagnose parsing bugs
                if solutionLen != 400 && solutionLen != 1344 {
                    let rawOffset = offset - varintSize
                    let nearbyBytes = response[max(0, rawOffset - 4)..<min(response.count, rawOffset + 10)]
                    let hexBytes = nearbyBytes.map { String(format: "%02x", $0) }.joined(separator: " ")
                    print("🔍 DEBUG Peer[\(host)]: Unexpected solutionLen=\(solutionLen) at header \(headers.count)")
                    print("   varintSize=\(varintSize), offset=\(offset), response.count=\(response.count)")
                    print("   Nearby bytes: \(hexBytes)")
                }

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

    func getCompactFilters(from height: UInt64, count: Int) async throws -> [CompactFilter] {
        var payload = Data()
        payload.append(UInt8(0)) // Filter type (basic)
        payload.append(contentsOf: withUnsafeBytes(of: height.littleEndian) { Array($0) })
        payload.append(contentsOf: withUnsafeBytes(of: UInt32(count).littleEndian) { Array($0) })

        // FIX #1231: CRITICAL - Do NOT use receiveMessageWithTimeout(..., destroyConnectionOnTimeout: false)
        // inside withExclusiveAccessTimeout. Same orphaned reader pattern as getBlockHeaders above.
        // Use destroyConnectionOnTimeout: true to prevent orphaned NWConnection readers.
        let response = try await withExclusiveAccessTimeout(seconds: 30) {
            try await self.sendMessage(command: "getcfilters", payload: payload)
            let (_, resp) = try await self.receiveMessageWithTimeout(seconds: 30, destroyConnectionOnTimeout: true)
            return resp
        }

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
    /// FIX #565: Implements pagination to handle peers that return fewer headers than requested
    func getFullBlocks(from height: UInt64, count: Int) async throws -> [CompactBlock] {
        var allBlocks: [CompactBlock] = []
        var currentHeight = height
        var remainingCount = count
        let maxBatchSize = 2000  // FIX #565 v4: Increased to 2000 (was 200) for faster bulk fetching

        while remainingCount > 0 {
            // Step 1: Get block headers to obtain hashes (paginated)
            let requestCount = min(remainingCount, maxBatchSize)
            let headers = try await getBlockHeaders(from: currentHeight, count: requestCount)

            guard !headers.isEmpty else {
                print("⚠️ No headers received at height \(currentHeight), stopping pagination")
                break
            }

            // If peer returned fewer headers than requested, we've hit their limit
            // Continue with what we got
            let receivedCount = headers.count
            print("📦 [\(host)] getFullBlocks: Requested \(requestCount), got \(receivedCount) headers at height \(currentHeight)")

            // Step 2: Get blocks for these headers
            let blockHashes = headers.map { $0.hash }

            // Build getdata payload
            var getdataPayload = Data()
            getdataPayload.append(UInt8(blockHashes.count))

            for hash in blockHashes {
                // Type 2 = MSG_BLOCK
                getdataPayload.append(contentsOf: withUnsafeBytes(of: UInt32(2).littleEndian) { Array($0) })
                getdataPayload.append(hash)
            }

            // FIX #111: Wrap send+receive in withExclusiveAccess to prevent race conditions
            // Without this, mempool scan could consume block messages meant for this operation
            // FIX #806: Use timeout to prevent indefinite hang when peer lock is held
            // FIX #1069: Use P2PTimeout constants for consistent behavior
            let blocks = try await withExclusiveAccessTimeout(seconds: P2PTimeout.lockAcquire) {
                try await self.sendMessage(command: "getdata", payload: getdataPayload)

                // Receive block messages
                // FIX: Use while loop to handle unexpected messages (like leftover 'headers') without advancing block index
                var blocks: [CompactBlock] = []
                var blockIndex = 0
                var unexpectedMessages = 0
                let maxUnexpectedMessages = 10  // Prevent infinite loop if peer keeps sending wrong messages

                while blockIndex < blockHashes.count && unexpectedMessages < maxUnexpectedMessages {
                    // FIX #1069: Use P2PTimeout.messageReceive (15s) for reliable block receipt
                    // GCD-based timeout guaranteed to fire even under heavy load
                    let (command, response) = try await self.receiveMessageWithTimeout(seconds: P2PTimeout.messageReceive)

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
                            blockHeight: currentHeight + UInt64(blockIndex),
                            blockHash: hash,
                            prevHash: block.prevHash,
                            finalSaplingRoot: block.finalSaplingRoot,
                            time: block.time,
                            transactions: block.transactions
                        )
                        blocks.append(block)
                        // FIX #565 v4: Removed debug print for performance (2000 blocks = 2000 prints!)
                    }
                    blockIndex += 1
                }

                if unexpectedMessages > 0 {
                    print("⚠️ Drained \(unexpectedMessages) unexpected messages during block fetch")
                }

                return blocks
            }

            allBlocks.append(contentsOf: blocks)

            // Check if we need to continue pagination
            if receivedCount < requestCount {
                // Peer returned fewer headers than requested - we've hit their limit
                print("⚠️ [\(host)] Peer returned only \(receivedCount)/\(requestCount) headers - pagination limit reached")
                break
            }

            // Move to next batch
            currentHeight += UInt64(receivedCount)
            remainingCount -= receivedCount

            // Safety check: prevent infinite loop if peer returns 0 blocks
            if blocks.isEmpty {
                print("⚠️ [\(host)] Got 0 blocks for \(receivedCount) headers, stopping pagination")
                break
            }
        }

        print("✅ [\(host)] getFullBlocks returning \(allBlocks.count) blocks (requested \(count))")
        return allBlocks
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
        // FIX #325: Disabled verbose log (too much output)
        // debugLog(.network, "📦 P2P BLOCK: Parsing block data, size=\(data.count) bytes")
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

        // FIX #325: Disabled verbose log
        // debugLog(.network, "📋 P2P TX: offset=\(offset) header=0x\(String(format: "%08X", header)) v\(version) overwinter=\(fOverwintered)")

        // Check for Sapling transaction (v4 with overwintered)
        guard fOverwintered && version >= 4 else {
            // Not a Sapling transaction - skip it entirely
            // FIX #325: Disabled verbose log
            // debugLog(.network, "⏭️ P2P TX: Not Sapling (v\(version), overwinter=\(fOverwintered)) - skipping")
            return (Data(repeating: 0, count: 32), [], [], skipLegacyTransaction(data, offset: offset))
        }

        // nVersionGroupId (4 bytes)
        guard pos + 4 <= data.count else { return (Data(repeating: 0, count: 32), [], [], pos) }
        let versionGroupId = data.loadUInt32(at: pos)
        pos += 4

        // Verify Sapling version group ID (0x892F2085)
        guard versionGroupId == 0x892F2085 else {
            // Not a Sapling transaction - could be Overwinter (0x03C48270) or other
            // FIX #325: Disabled verbose log
            // debugLog(.network, "⏭️ P2P TX: Not Sapling versionGroupId=0x\(String(format: "%08X", versionGroupId)) - skipping")
            return (Data(repeating: 0, count: 32), [], [], skipLegacyTransaction(data, offset: offset))
        }

        // vin (transparent inputs)
        let (vinCount, vinBytes) = readCompactSize(data, at: pos)
        pos += vinBytes
        // FIX #325: Disabled verbose log
        // debugLog(.network, "📋 P2P TX: vinCount=\(vinCount) pos=\(pos)")
        // Sanity limit - transactions rarely have >1000 inputs
        let safeVinCount = min(vinCount, 10000)
        for _ in 0..<safeVinCount {
            guard pos < data.count else { break }
            pos = skipTransparentInput(data, offset: pos)
        }

        // vout (transparent outputs)
        let (voutCount, voutBytes) = readCompactSize(data, at: pos)
        pos += voutBytes
        // FIX #325: Disabled verbose log
        // debugLog(.network, "📋 P2P TX: voutCount=\(voutCount) pos after vin=\(pos)")
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

        // FIX #325: Disabled verbose log
        // debugLog(.network, "📋 P2P TX: pos after locktime/expiry/valueBalance=\(pos)")

        // vShieldedSpend
        let (spendCount, spendBytes) = readCompactSize(data, at: pos)
        pos += spendBytes
        // FIX #325: Disabled verbose log
        // debugLog(.network, "📋 P2P TX: spendCount=\(spendCount)")
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
        // FIX #325: Disabled verbose log
        // debugLog(.network, "📋 P2P TX: outputCount=\(outputCount)")
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
            // FIX #325: Disabled verbose log
            // debugLog(.network, "📋 P2P TX: Output[\(i)] cmu=\(cmu.prefix(8).hexString)...")

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

        // FIX #325: Disabled verbose log
        // debugLog(.network, "✅ P2P TX: Parsed successfully - \(spends.count) spends, \(outputs.count) outputs, txHash=\(txHash.reversedBytes().hexString)")
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
        // FIX #1071: Pre-reconnection now happens at NetworkManager level
        // before parallel fetches start, so peers should already have fresh sockets
        // Just verify connection is ready
        if !isConnectionReady {
            print("⚠️ FIX #1071: [\(host)] Connection not ready for single block fetch, attempting reconnect...")
            try await ensureConnected()
        }

        guard hash.count == 32 else {
            throw PeerError.invalidData
        }

        // Block hash for error logging only
        let hashHex = hash.prefix(8).map { String(format: "%02x", $0) }.joined()

        // Build getdata message for single block (outside lock - pure computation)
        var payload = Data()
        payload.append(1) // count = 1
        payload.append(contentsOf: withUnsafeBytes(of: UInt32(2).littleEndian) { Array($0) }) // MSG_BLOCK = 2
        payload.append(hash)

        // CRITICAL FIX: Wrap send+receive in withExclusiveAccess to prevent race with block listener
        // FIX #806: Use timeout to prevent indefinite hang when peer lock is held
        // FIX #1069: Use P2PTimeout constant for lock acquisition
        return try await withExclusiveAccessTimeout(seconds: P2PTimeout.lockAcquire) {
            try await self.sendMessage(command: "getdata", payload: payload)

            // Wait for block response with timeout
            // Peers may send ping, inv, addr messages - we need to handle them
            var attempts = 0
            let maxAttempts = 30 // Increased from 10 - blocks can be large and slow
            while attempts < maxAttempts {
                attempts += 1

                // Add timeout for each receive attempt
                // FIX #919: Timeout must disconnect to prevent TCP stream desynchronization
                // FIX #1069: Use GCD-based reliable timeout instead of Task.sleep
                do {
                    let result = try await withReliableTimeoutThrowing(seconds: P2PTimeout.messageReceive) {
                        try await self.receiveMessage()
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
                    // Other messages (inv, addr, etc.) - continue waiting for block
                    // Continue waiting for block message
                } catch is CancellationError {
                    // Timeout on this attempt, continue to next
                    continue
                } catch is P2PTimeoutError {
                    // FIX #1069: Reliable timeout fired, continue to next attempt
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

        // Validate all hashes
        for hash in hashes {
            guard hash.count == 32 else { throw PeerError.invalidData }
        }

        // Build getdata message for multiple blocks
        var payload = Data()
        if hashes.count < 253 {
            payload.append(UInt8(hashes.count))
        } else {
            payload.append(253)
            payload.append(contentsOf: withUnsafeBytes(of: UInt16(hashes.count).littleEndian) { Array($0) })
        }

        for hash in hashes {
            payload.append(contentsOf: withUnsafeBytes(of: UInt32(2).littleEndian) { Array($0) }) // MSG_BLOCK = 2
            payload.append(hash)
        }

        // FIX #893: Use dispatcher when block listener is active
        // Block listener stays running, dispatcher collects responses - NO stream desync!
        let dispatcherActive = await messageDispatcher.isActive

        if dispatcherActive {
            print("📦 FIX #893: [\(host)] Fetching \(hashes.count) blocks via dispatcher (listener stays running)")

            // Send request - block listener will receive responses
            try await sendMessage(command: "getdata", payload: payload)

            // Wait for blocks via dispatcher with timeout
            // Dispatcher collects "block" messages from block listener
            // FIX #1217: Adaptive timeout based on block count.
            // Healthy peers deliver 128 blocks in <3s. Previous fixed 30s let dead peers
            // waste 30s before failing — peer 77.110.103.38 wasted 60s across two calls.
            // Scale: ≤10 blocks → 5s, ≤50 → 10s, >50 → 15s.
            let batchTimeout: Double = hashes.count <= 10 ? 5.0 : (hashes.count <= 50 ? 10.0 : 15.0)
            let blockData = await messageDispatcher.waitForBatch(
                command: "block",
                expectedCount: hashes.count,
                timeoutSeconds: batchTimeout
            )

            print("📦 FIX #893: [\(host)] Received \(blockData.count)/\(hashes.count) blocks via dispatcher (timeout=\(String(format: "%.0f", batchTimeout))s)")

            // Parse blocks
            return blockData.compactMap { parseCompactBlock($0) }

        } else {
            // FIX #1184: Do NOT use direct reads — they hold the message lock and
            // prevent block listeners from reading, creating a vicious cycle where
            // dispatchers stay inactive → more direct reads → lock contention → 76 blocks/s.
            // Dispatcher path is lock-free (~300 blocks/s). If dispatcher is not active,
            // this peer can't be used for batch block fetches. Caller (getBlocksDataP2P)
            // will use other dispatcher-active peers instead.
            print("📦 FIX #1184: [\(host)] Dispatcher not active — skipping peer for block fetch (\(hashes.count) blocks)")
            return []
        }
    }

    /// Get a transaction by its hash via P2P getdata
    /// Uses exclusive access to prevent message stream conflicts
    func getTransaction(hash: Data) async throws -> Data {
        guard hash.count == 32 else {
            throw PeerError.invalidData
        }

        // FIX #453 v2: Use timeout version to prevent deadlock with block listeners
        // Block listeners hold the message lock indefinitely while processing network messages
        // If getTransaction waits forever for the lock, VUL-002 verification hangs
        // 30 second timeout gives enough time for block listeners to release the lock
        return try await withExclusiveAccessTimeout(seconds: 30) {
            // Build getdata message for single transaction
            var payload = Data()
            payload.append(1) // count = 1
            payload.append(contentsOf: withUnsafeBytes(of: UInt32(1).littleEndian) { Array($0) }) // MSG_TX = 1
            payload.append(hash)

            try await sendMessage(command: "getdata", payload: payload)

            // FIX #453 v2: Use receiveMessageWithTimeout to prevent infinite wait for peer response
            // If peer doesn't respond with "tx", the receiveMessage() call would hang forever
            // Even though we have lock acquisition timeout, once lock is acquired we still need timeout here
            var attempts = 0
            while attempts < 10 {
                attempts += 1
                // FIX #453 v2: Use 10-second timeout for each receive attempt
                // This allows 10 attempts × 10 seconds = 100 seconds max total wait
                let (command, response) = try await receiveMessageWithTimeout(seconds: 10)

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
    /// FIX #1004: Use receiveMessageWithTimeout to prevent indefinite blocking
    /// FIX #1005: Empty mempool = no response (Zclassic source: vInv.size() > 0 check)
    /// FIX #1184: Route through dispatcher when active to eliminate orphaned readers
    /// FIX #1333: Merge unsolicited TX inv hashes with mempool command results
    func getMempoolTransactions() async throws -> [Data] {
        // FIX #1333: Drain unsolicited TX hashes (captured from unsolicited inv MSG_TX).
        // Per Bitcoin P2P protocol, once a peer sends inv for a TX, it won't re-send
        // via the mempool command response. These hashes would otherwise be lost.
        let unsolicited: [Data]
        unsolicitedTxLock.lock()
        unsolicited = unsolicitedTxHashes
        unsolicitedTxHashes.removeAll()
        unsolicitedTxLock.unlock()

        // FIX #1184: Route through dispatcher when block listener is active
        let dispatcherActive = await messageDispatcher.isActive
        if dispatcherActive {
            let fromMempool = try await getMempoolTransactionsViaDispatcher()

            // FIX #1333: Merge unsolicited hashes with mempool response (deduplicate)
            if unsolicited.isEmpty {
                return fromMempool
            }
            var merged = Set(fromMempool)
            for tx in unsolicited {
                merged.insert(tx)
            }
            print("🔮 FIX #1333: [\(host)] Merged \(unsolicited.count) unsolicited + \(fromMempool.count) mempool = \(merged.count) unique TX hashes")
            return Array(merged)
        }

        // FIX #1184b: Do NOT fall back to direct reads when dispatcher is inactive.
        // Direct reads use receiveMessageWithTimeout(destroyConnectionOnTimeout: false)
        // which leaves orphaned NWConnection readers. When block listeners restart later,
        // the orphaned reader consumes the next header → block listener reads payload data
        // → "invalid magic bytes [253, ...]" → stream desync → peer death.

        // FIX #1333: Even when dispatcher is inactive, return unsolicited hashes if we have them.
        // These were captured by the block listener before it stopped.
        if !unsolicited.isEmpty {
            print("🔮 FIX #1333: [\(host)] Returning \(unsolicited.count) unsolicited TX hash(es) (dispatcher inactive)")
            return unsolicited
        }

        print("🔮 FIX #1184b: Skipping mempool query (dispatcher inactive, avoiding orphaned readers)")
        return []
    }

    /// FIX #1184: Mempool query through dispatcher — zero orphaned readers
    /// Block listener dispatches inv messages to our waiting handler
    private func getMempoolTransactionsViaDispatcher() async throws -> [Data] {
        print("🔮 FIX #1184: Requesting mempool via dispatcher...")

        // Send mempool request — no lock needed, just a socket write
        try await sendMessage(command: "mempool", payload: Data())

        // Wait for inv response via dispatcher (3s timeout)
        // If mempool empty, Zclassic sends NOTHING → timeout → empty array
        let result = await messageDispatcher.waitForResponseWithTimeout(
            command: "inv",
            timeoutSeconds: 3.0
        )

        guard let (_, response) = result, response.count >= 1 else {
            print("🔮 FIX #1184: Mempool empty (no inv via dispatcher)")
            return []
        }

        // Parse inv payload: [count: varint][inv_vector...]
        return parseMempoolInv(response: response)
    }

    /// Fallback: Direct mempool query when dispatcher is not active
    /// FIX #1183: Reduced to SINGLE timeout to limit orphaned NWConnection readers
    private func getMempoolTransactionsDirect() async throws -> [Data] {
        return try await withExclusiveAccess {
            print("🔮 FIX #1184: Requesting mempool via direct path (dispatcher inactive)...")

            // Send mempool request (empty payload)
            try await sendMessage(command: "mempool", payload: Data())

            var attempts = 0

            while attempts < 3 {
                attempts += 1

                do {
                    let (command, response) = try await receiveMessageWithTimeout(seconds: 3, destroyConnectionOnTimeout: false)

                    // Handle ping automatically
                    if command == "ping" {
                        try await sendMessage(command: "pong", payload: response)
                        continue
                    }

                    if command == "inv" && response.count >= 1 {
                        return parseMempoolInv(response: response)
                    }

                    // Ignore other messages, keep waiting
                    continue
                } catch NetworkError.timeout {
                    // FIX #1183: Return IMMEDIATELY on first timeout
                    print("🔮 FIX #1183: Mempool empty (no inv response after timeout)")
                    return []
                }
            }

            print("🔮 FIX #1005: Mempool likely empty (no inv after \(attempts) attempts)")
            return []
        }
    }

    /// Parse inv payload for mempool transaction hashes (MSG_TX type 1 only)
    private func parseMempoolInv(response: Data) -> [Data] {
        var txHashes: [Data] = []
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
            print("🧅 Invalid onion address format")
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
        // FIX #131: Wrap in withExclusiveAccess to prevent P2P race conditions
        try await withExclusiveAccess {
            // Send addrv2 message
            try await sendMessage(command: "addrv2", payload: payload)
            print("🧅 Advertised our .onion address to peer \(LogRedaction.redactIP(host)): \(LogRedaction.redactAddress(onionAddress)):\(port)")
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

    // FIX #535: Performance tracking for header sync prioritization
    var headersProvided: Int = 0          // Number of valid headers provided
    var headerResponseTimeMs: Double = 0  // Average header response time in milliseconds
    var chainworkValidations: Int = 0     // Number of successful chainwork validations
    var lastChainworkValidation: Date?    // Last successful chainwork validation time

    // FIX #1100: Block fetch speed tracking for dynamic peer selection
    // Track actual measured speed to prefer faster peers regardless of location
    var blockFetchSamples: Int = 0              // Number of block fetch measurements
    var totalBlocksFetched: Int = 0             // Total blocks fetched
    var totalFetchTimeSeconds: Double = 0       // Total time spent fetching
    var averageBlocksPerSecond: Double = 0      // Running average blocks/sec

    // FIX #1101: Track consecutive slow responses for fast skip
    var consecutiveSlowFetches: Int = 0         // Consecutive fetches below threshold
    var lastFetchSpeed: Double = 0              // Last measured speed (blocks/sec)

    /// FIX #1100: Update block fetch speed statistics
    mutating func recordBlockFetch(blocks: Int, seconds: Double) {
        guard seconds > 0 else { return }  // Only require valid time

        // FIX #1101 v2: Handle failures (blocks=0) as very slow fetches
        if blocks == 0 {
            // Timeout/failure - count as consecutive slow fetch
            lastFetchSpeed = 0
            consecutiveSlowFetches += 1
            blockFetchSamples += 1
            // Don't update average speed for failures (would skew to 0)
            return
        }

        let speed = Double(blocks) / seconds
        lastFetchSpeed = speed

        blockFetchSamples += 1
        totalBlocksFetched += blocks
        totalFetchTimeSeconds += seconds

        // Exponential moving average (weight recent samples more)
        let alpha: Double = 0.3  // 30% weight to new sample
        if averageBlocksPerSecond == 0 {
            averageBlocksPerSecond = speed
        } else {
            averageBlocksPerSecond = alpha * speed + (1 - alpha) * averageBlocksPerSecond
        }

        // FIX #1101: Track consecutive slow fetches (threshold: 50 blocks/sec)
        let slowThreshold: Double = 50.0
        if speed < slowThreshold {
            consecutiveSlowFetches += 1
        } else {
            consecutiveSlowFetches = 0
        }
    }
}

// MARK: - Banned Peer

public struct BannedPeer {
    public let address: String
    public let banTime: Date
    public let banDuration: TimeInterval // Default 24 hours, -1 means PERMANENT (FIX #159)
    public let reason: BanReason

    public init(address: String, banDuration: TimeInterval, reason: BanReason) {
        self.address = address
        self.banTime = Date()
        self.banDuration = banDuration
        self.reason = reason
    }

    /// FIX #159: Indicates if this is a permanent ban (Sybil attackers)
    /// Permanent bans do NOT expire automatically and require manual unbanning
    public var isPermanent: Bool {
        banDuration < 0
    }

    public var isExpired: Bool {
        // FIX #159: Permanent bans (duration < 0) NEVER expire
        if isPermanent {
            return false
        }
        return Date() > banTime.addingTimeInterval(banDuration)
    }

    /// Time remaining for temporary bans, nil for permanent bans
    public var timeRemaining: TimeInterval? {
        if isPermanent {
            return nil
        }
        let remaining = banTime.addingTimeInterval(banDuration).timeIntervalSinceNow
        return max(0, remaining)
    }
}

public enum BanReason: String {
    case tooManyFailures = "Too many consecutive failures"
    case lowSuccessRate = "Very low success rate"
    case invalidMessages = "Sent invalid messages"
    case protocolViolation = "Protocol violation"
    case corruptedData = "Sent corrupted or invalid data"
    case fakeChainHeight = "Reported fake chain height (Sybil attack detected)"
    case wrongProtocol = "Wrong protocol version (Zcash node)"
}

// MARK: - FIX #284: Parked Peer (Connection Timeout - Exponential Backoff)

/// Parked peer - temporarily unavailable due to connection timeout
/// NOT a ban! Will retry with exponential backoff: 1s → 5min → 1h → 24h max
public struct ParkedPeer {
    public let address: String
    public let port: UInt16
    public var parkedTime: Date  // FIX #850: Changed to var so incrementRetry() can reset it
    public var retryCount: Int
    public let wasPreferred: Bool  // Track if this was a preferred seed before parking
    public let isHardcodedSeed: Bool  // FIX #352: Track if this is a hardcoded seed
    public var pingFailureCount: Int = 0  // FIX #863: Track ping failures across reconnects
    public var handshakeFailureCount: Int = 0  // FIX #908: Track handshake failures across reconnects
    public var handshakePhase: Int = 0  // FIX #908: 0 = first 5 failures (1h), 1 = second 5 failures (24h)
    public var handshakeParkTime: TimeInterval = 0  // FIX #908: Custom park duration for handshake failures

    /// Backoff schedule (in seconds):
    /// Phase 1: 1, 2, 4, 8, 16, 32, 64, 128, 256, 300 (5min cap)
    /// Phase 2: 3600 (1h), 14400 (4h), 28800 (8h), 57600 (16h), 86400 (24h max)
    private static let backoffPhase1: [TimeInterval] = [1, 2, 4, 8, 16, 32, 64, 128, 256, 300]
    private static let backoffPhase2: [TimeInterval] = [3600, 14400, 28800, 57600, 86400]

    /// FIX #352: Hardcoded seeds known to be reliable Zclassic nodes
    /// FIX #1428: Keep in sync with NetworkManager.HARDCODED_SEEDS and PeerManager.HARDCODED_SEEDS
    private static let hardcodedSeeds: Set<String> = [
        "140.174.189.3",
        "140.174.189.17",
        "205.209.104.118",
        "95.179.131.117",
        "45.77.216.198",
        "212.23.222.231",
        "157.90.223.151"
    ]

    /// Get the next retry interval based on retry count
    /// FIX #352: Hardcoded seeds cap at 5 minutes (300s) instead of 24h
    /// FIX #908: Handshake failure park time takes priority when set
    public var nextRetryInterval: TimeInterval {
        // FIX #908: If handshake failure park time is set, use it
        if handshakeParkTime > 0 {
            return handshakeParkTime
        }

        if retryCount < ParkedPeer.backoffPhase1.count {
            return ParkedPeer.backoffPhase1[retryCount]
        }
        // FIX #352: Hardcoded seeds should NOT wait hours - cap at 5 minutes
        if isHardcodedSeed {
            return 300  // 5 minute max for hardcoded seeds
        }
        let phase2Index = retryCount - ParkedPeer.backoffPhase1.count
        if phase2Index < ParkedPeer.backoffPhase2.count {
            return ParkedPeer.backoffPhase2[phase2Index]
        }
        // Max backoff: 24 hours
        return 86400
    }

    /// Time when we should next attempt to connect
    public var nextRetryTime: Date {
        return parkedTime.addingTimeInterval(nextRetryInterval)
    }

    /// Check if it's time to retry
    public var isReadyForRetry: Bool {
        return Date() >= nextRetryTime
    }

    /// Time remaining until retry
    public var timeUntilRetry: TimeInterval {
        return max(0, nextRetryTime.timeIntervalSinceNow)
    }

    /// Human-readable description of backoff status
    public var backoffDescription: String {
        let interval = nextRetryInterval
        if interval < 60 {
            return "\(Int(interval))s"
        } else if interval < 3600 {
            return "\(Int(interval / 60))m"
        } else {
            return "\(Int(interval / 3600))h"
        }
    }

    /// Create new parked peer
    /// FIX #352: Auto-detect if address is a hardcoded seed
    public init(address: String, port: UInt16, wasPreferred: Bool = false) {
        self.address = address
        self.port = port
        self.parkedTime = Date()
        self.retryCount = 0
        self.wasPreferred = wasPreferred
        self.isHardcodedSeed = ParkedPeer.hardcodedSeeds.contains(address)
    }

    /// FIX #850: Increment retry count AND reset parkedTime after failed retry
    /// Without resetting parkedTime, the nextRetryTime calculation uses ORIGINAL parkedTime
    /// which could be far in the past, making isReadyForRetry immediately return true
    /// This caused peers to be retried every 30 seconds despite exponential backoff
    public mutating func incrementRetry() {
        retryCount += 1
        parkedTime = Date()  // FIX #850: Reset timer for new backoff period
    }

    /// FIX #863: Increment ping failure count
    /// Called when peer connects successfully but fails ping (magic byte mismatch, etc.)
    /// This tracks failures across reconnects to detect persistently bad peers
    public mutating func incrementPingFailure() {
        pingFailureCount += 1
        parkedTime = Date()  // Reset timer for backoff
        retryCount += 1
    }

    /// FIX #863: Check if peer should be banned due to repeated ping failures
    /// A peer that connects OK but consistently fails ping is likely on wrong chain
    /// or has corrupted protocol state - ban after 5 consecutive ping failures
    public var shouldBanForPingFailures: Bool {
        return pingFailureCount >= 5
    }

    /// FIX #863: Reset ping failure count (called when ping succeeds)
    public mutating func resetPingFailures() {
        pingFailureCount = 0
    }

    /// FIX #908: Increment handshake failure count
    /// After 5 failures → park for 1 hour
    /// After 1 hour, if 5 more failures → park for 24 hours
    /// Returns the park duration to use (in seconds)
    public mutating func incrementHandshakeFailure() -> TimeInterval {
        handshakeFailureCount += 1
        parkedTime = Date()

        if handshakePhase == 0 {
            // Phase 0: First batch of failures - park for 1 hour after 5 failures
            if handshakeFailureCount >= 5 {
                handshakeParkTime = 3600  // 1 hour
                return 3600
            }
            // Less than 5 failures in phase 0, use short backoff
            return min(Double(handshakeFailureCount) * 30, 300)  // 30s, 60s, 90s, 120s max 5min
        } else {
            // Phase 1+: After first 1 hour park, park for 24 hours after 5 more failures
            if handshakeFailureCount >= 5 {
                handshakeParkTime = 86400  // 24 hours
                return 86400
            }
            // Less than 5 failures in phase 1+, use 1 hour backoff
            return 3600
        }
    }

    /// FIX #908: Move to next handshake failure phase (after 1h park expires)
    public mutating func advanceHandshakePhase() {
        handshakePhase += 1
        handshakeFailureCount = 0
        handshakeParkTime = 0
    }

    /// FIX #908: Check if peer should be parked for extended duration due to handshake failures
    /// Returns the custom park time if set, or nil to use default backoff
    public var handshakeFailureParkDuration: TimeInterval? {
        if handshakeParkTime > 0 {
            return handshakeParkTime
        }
        return nil
    }

    /// FIX #908: Get time remaining for handshake failure park
    public var handshakeParkTimeRemaining: TimeInterval {
        guard handshakeParkTime > 0 else { return 0 }
        let elapsed = Date().timeIntervalSince(parkedTime)
        return max(0, handshakeParkTime - elapsed)
    }

    /// FIX #908: Check if handshake failure park has expired
    public var isHandshakeParkExpired: Bool {
        guard handshakeParkTime > 0 else { return true }
        return handshakeParkTimeRemaining <= 0
    }

    /// FIX #908: Reset handshake failures (called when handshake succeeds)
    public mutating func resetHandshakeFailures() {
        handshakeFailureCount = 0
        handshakePhase = 0
        handshakeParkTime = 0
    }

    /// Reset for fresh retry (new parking)
    public mutating func resetParking() {
        retryCount = 0
        pingFailureCount = 0  // FIX #863: Also reset ping failures on fresh parking
        handshakeFailureCount = 0  // FIX #908: Also reset handshake failures on fresh parking
        handshakePhase = 0
        handshakeParkTime = 0
    }
}
