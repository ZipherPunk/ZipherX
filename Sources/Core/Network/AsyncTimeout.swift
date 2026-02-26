import Foundation

// MARK: - P2P Timeout Constants
// FIX #1069: Centralized timeout configuration for consistent P2P behavior

/// Centralized timeout constants for P2P operations
/// These values are tuned for Zclassic P2P protocol reliability
public enum P2PTimeout {
    /// Per-peer block listener stop timeout
    public static let blockListenerStop: Double = 2.0

    /// Overall timeout for stopping all block listeners
    public static let blockListenerStopAll: Double = 5.0

    /// Ping/pong timeout for keepalive
    public static let ping: Double = 5.0

    /// Message receive timeout for typical operations
    public static let messageReceive: Double = 15.0

    /// Lock acquisition timeout before giving up on busy peer
    /// FIX #1099: Reduced from 10s to 3s - 104 timeouts × 10s = 17+ minutes wasted!
    public static let lockAcquire: Double = 3.0

    /// Broadcast timeout per peer (Tor connections need more time)
    public static let broadcastPerPeer: Double = 5.0
    public static let broadcastPerPeerTor: Double = 30.0

    /// Overall broadcast timeout
    public static let broadcastOverall: Double = 15.0
    public static let broadcastOverallTor: Double = 60.0

    /// Socket drain timeout per iteration
    public static let socketDrain: Double = 0.2

    /// Header sync timeout
    public static let headerSync: Double = 45.0

    /// Block fetch timeout per batch
    public static let blockFetch: Double = 60.0
}

// MARK: - Unified Timeout Helper

/// FIX #1069: Unified timeout pattern using GCD (always fires reliably)
/// Swift's cooperative threading can prevent Task.sleep from firing on time when
/// the thread pool is busy. GCD's DispatchQueue runs on a separate thread pool,
/// guaranteeing the timeout will fire even under heavy concurrency load.
///
/// This was the root cause of FIX #822, #829, #894 where timeouts didn't fire
/// and caused app hangs.
///
/// Usage:
/// ```
/// let result = await withReliableTimeout(seconds: 5.0) {
///     // Your async operation
///     return await someLongOperation()
/// } onTimeout: {
///     // Return default/fallback value
///     return .defaultValue
/// }
/// ```
public func withReliableTimeout<T>(
    seconds: Double,
    operation: @escaping () async -> T,
    onTimeout: @escaping () -> T
) async -> T {
    return await withCheckedContinuation { continuation in
        var continuationResumed = false
        let lock = NSLock()

        // Start the actual operation
        Task {
            let result = await operation()

            // Completed - resume continuation if not already timed out
            lock.lock()
            if !continuationResumed {
                continuationResumed = true
                lock.unlock()
                continuation.resume(returning: result)
            } else {
                lock.unlock()
            }
        }

        // Set up timeout on GCD queue (separate thread pool from Swift concurrency)
        // This is CRITICAL - GCD is independent of Swift's cooperative threading
        // so the timeout is guaranteed to fire even when Swift tasks are serialized
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
            lock.lock()
            if !continuationResumed {
                continuationResumed = true
                lock.unlock()
                continuation.resume(returning: onTimeout())
            } else {
                lock.unlock()
            }
        }
    }
}

/// FIX #1069: Throwing version of withReliableTimeout
/// Throws TimeoutError if operation doesn't complete within timeout
public func withReliableTimeoutThrowing<T>(
    seconds: Double,
    operation: @escaping () async throws -> T
) async throws -> T {
    // Use Result to capture success/failure, nil means timeout
    let result: Result<T, Error>? = await withCheckedContinuation { continuation in
        var continuationResumed = false
        let lock = NSLock()

        // Start the actual operation
        Task {
            do {
                let value = try await operation()

                lock.lock()
                if !continuationResumed {
                    continuationResumed = true
                    lock.unlock()
                    continuation.resume(returning: .success(value))
                } else {
                    lock.unlock()
                }
            } catch {
                lock.lock()
                if !continuationResumed {
                    continuationResumed = true
                    lock.unlock()
                    continuation.resume(returning: .failure(error))
                } else {
                    lock.unlock()
                }
            }
        }

        // GCD timeout (reliable even when Swift threads are busy)
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
            lock.lock()
            if !continuationResumed {
                continuationResumed = true
                lock.unlock()
                continuation.resume(returning: nil)  // nil = timeout
            } else {
                lock.unlock()
            }
        }
    }

    switch result {
    case .success(let value):
        return value
    case .failure(let error):
        throw error
    case .none:
        throw P2PTimeoutError.timeout(seconds: seconds)
    }
}

/// FIX #1069: Timeout error type
public enum P2PTimeoutError: Error, LocalizedError {
    case timeout(seconds: Double)

    public var errorDescription: String? {
        switch self {
        case .timeout(let seconds):
            return "Operation timed out after \(String(format: "%.1f", seconds)) seconds"
        }
    }
}

// MARK: - Per-Request Lock Pattern
// FIX #1069: Simplified locking pattern for P2P requests
// Based on user feedback: "each peer/P2P request creates a lock, sends the request,
// waits x sec for reply, or error or nothing, then removes the lock"

/// FIX #1069: Simple per-request lock for P2P operations
/// Each P2P request:
/// 1. Checks if peer is busy (lock held)
/// 2. If free, acquires lock
/// 3. Sends request
/// 4. Waits for reply (with timeout)
/// 5. Releases lock (in defer, so always released)
///
/// This eliminates complex state management - just "busy" or "free"
public actor PeerRequestLock {
    private var isLocked = false
    private var lockHolder: String? = nil  // For debugging

    /// Try to acquire lock for a specific operation
    /// Returns true if lock acquired, false if peer is busy
    public func tryAcquire(operation: String) -> Bool {
        if isLocked {
            // Peer is busy - caller should skip or retry later
            return false
        }
        isLocked = true
        lockHolder = operation
        return true
    }

    /// Force acquire with timeout (waits for lock to become available)
    /// Returns true if acquired within timeout, false otherwise
    public func acquireWithTimeout(operation: String, seconds: Double) async -> Bool {
        let startTime = Date()
        let pollInterval: TimeInterval = 0.05  // 50ms between checks

        while Date().timeIntervalSince(startTime) < seconds {
            if !isLocked {
                isLocked = true
                lockHolder = operation
                return true
            }
            // Wait before next check - but use a proper async delay
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }

        return false
    }

    /// Release the lock
    public func release() {
        isLocked = false
        lockHolder = nil
    }

    /// Force release (for cleanup after timeout)
    public func forceRelease() {
        if isLocked {
            print("⚠️ FIX #1069: Force releasing lock (was held by: \(lockHolder ?? "unknown"))")
        }
        isLocked = false
        lockHolder = nil
    }

    /// Check if lock is currently held
    public var isBusy: Bool {
        return isLocked
    }

    /// Get current lock holder (for debugging)
    public var currentOperation: String? {
        return lockHolder
    }
}

/// FIX #1069: Execute a P2P operation with automatic lock management
/// This is the recommended pattern for P2P requests:
/// - Acquires lock (or returns early if peer busy)
/// - Executes operation with timeout
/// - Always releases lock (even on error/timeout)
///
/// Usage:
/// ```
/// let result = await withP2PRequest(peer: peer, operation: "getHeaders", timeout: 5.0) {
///     try await peer.sendAndReceive(command: "getheaders", payload: data)
/// }
/// switch result {
/// case .success(let data): // handle data
/// case .busy: // peer was busy, skip or try another
/// case .timeout: // operation timed out
/// case .failed(let error): // operation failed
/// }
/// ```
public func withP2PRequest<T>(
    lock: PeerRequestLock,
    operation: String,
    timeout: Double,
    body: @escaping () async throws -> T
) async -> P2PRequestResult<T> {
    // Step 1: Try to acquire lock
    let acquired = await lock.tryAcquire(operation: operation)
    guard acquired else {
        return .busy(currentOperation: await lock.currentOperation)
    }

    // Step 2: Execute with timeout, always release lock
    defer {
        Task { await lock.release() }
    }

    do {
        let result = try await withReliableTimeoutThrowing(seconds: timeout) {
            try await body()
        }
        return .success(result)
    } catch is P2PTimeoutError {
        return .timeout
    } catch {
        return .failed(error)
    }
}

/// FIX #1069: Result type for P2P requests
public enum P2PRequestResult<T> {
    case success(T)
    case busy(currentOperation: String?)
    case timeout
    case failed(Error)

    /// Get the successful result or nil
    public var value: T? {
        if case .success(let v) = self { return v }
        return nil
    }

    /// Check if request was successful
    public var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
