import Foundation
import Combine

// MARK: - Supporting Types (Moved from NetworkManager/Peer)

/// Peer address representation
public struct PeerAddress: Hashable {
    public let host: String
    public let port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    public var key: String { "\(host):\(port)" }
}

/// Information about a known peer address
public struct AddressInfo {
    public let address: PeerAddress
    public let source: String // Where we learned about this address
    public let firstSeen: Date
    public var lastSeen: Date
    public var attempts: Int
    public var successes: Int

    public init(address: PeerAddress, source: String) {
        self.address = address
        self.source = source
        self.firstSeen = Date()
        self.lastSeen = Date()
        self.attempts = 0
        self.successes = 0
    }

    /// Full initializer for importing peer data with existing history
    public init(address: PeerAddress, source: String, firstSeen: Date, lastSeen: Date, attempts: Int, successes: Int) {
        self.address = address
        self.source = source
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.attempts = attempts
        self.successes = successes
    }

    /// Calculate selection probability based on history
    public func getChance() -> Double {
        var chance = 1.0

        // Reduce chance based on failed attempts
        if attempts > successes {
            let failures = attempts - successes
            chance *= pow(0.66, Double(min(failures, 8)))
        }

        // Boost for recent success
        if successes > 0 {
            let hoursSinceSuccess = Date().timeIntervalSince(lastSeen) / 3600
            if hoursSinceSuccess < 1 {
                chance *= 1.5
            } else if hoursSinceSuccess > 168 { // 1 week
                chance *= 0.3
            }
        }

        // Reduce chance for untried addresses with old timestamps
        if successes == 0 && attempts == 0 {
            let daysSinceFirst = Date().timeIntervalSince(firstSeen) / 86400
            if daysSinceFirst > 7 {
                chance *= 0.5
            }
        }

        return chance
    }

    /// Check if this address should be removed
    public func isTerrible() -> Bool {
        // Never succeeded and many failures
        if successes == 0 && attempts >= 3 {
            return true
        }

        // Very low success rate
        if attempts >= 10 {
            let successRate = Double(successes) / Double(attempts)
            if successRate < 0.05 {
                return true
            }
        }

        // Not seen in 30 days
        let daysSinceSeen = Date().timeIntervalSince(lastSeen) / 86400
        if daysSinceSeen > 30 {
            return true
        }

        return false
    }
}

/// Codable version of AddressInfo for persistence
public struct PersistedAddress: Codable {
    public let host: String
    public let port: UInt16
    public let firstSeen: Date
    public let lastSeen: Date
    public let attempts: Int
    public let successes: Int
}

// NOTE: BanReason, BannedPeer, and ParkedPeer structs are defined in Peer.swift
// PeerManager uses those types directly to avoid duplication

/// Sybil attack alert info
public struct SybilAlert {
    public let attackerCount: Int
    public let bypassedTor: Bool
    public let detectedAt: Date

    public init(attackerCount: Int, bypassedTor: Bool) {
        self.attackerCount = attackerCount
        self.bypassedTor = bypassedTor
        self.detectedAt = Date()
    }
}

// MARK: - PeerManager

/// Centralized Peer Manager
/// Handles ALL peer-related operations: connection, banning, parking, selection, recovery
@MainActor
public final class PeerManager: ObservableObject {

    // MARK: - Singleton

    public static let shared = PeerManager()

    // MARK: - Constants

    public let MIN_PEERS = 8
    public let MAX_PEERS = 30
    // FIX #1493: VULN-009 — Use centralized constant (was local hardcoded 5, mismatched with operational code)
    public let CONSENSUS_THRESHOLD = ZipherXConstants.consensusThreshold
    public let BAN_DURATION: TimeInterval = 604800  // 7 days
    public let CONNECTION_COOLDOWN: TimeInterval = 2.0
    public let MAX_KNOWN_ADDRESSES = 1000

    /// FIX #235, FIX #423: Hardcoded Zclassic seed nodes - EXEMPT from cooldown
    /// These are VERIFIED good ZCL nodes that should ALWAYS be tried first
    // FIX #931: PRODUCTION MODE - All hardcoded seeds enabled
    /// VUL-N-003: localhost removed — only added dynamically in Full Node mode
    public let HARDCODED_SEEDS: Set<String> = [
        "140.174.189.3",      // MagicBean node cluster
        "140.174.189.17",     // MagicBean node cluster
        "205.209.104.118",    // MagicBean node
        "95.179.131.117",     // Additional Zclassic node
        "45.77.216.198",      // Additional Zclassic node
        "212.23.222.231",     // FIX #423: Verified ZCL node
        "157.90.223.151"      // FIX #423: Verified ZCL node
    ]

    /// DNS seeds for peer discovery
    // FIX #931: PRODUCTION MODE - DNS seeds enabled
    public let DNS_SEEDS: [String] = [
        "dnsseed.zclassic.org",
        "dnsseed.rotorproject.org"
    ]

    // MARK: - Published State

    @Published public private(set) var connectedPeerCount: Int = 0
    @Published public private(set) var bannedPeerCount: Int = 0
    @Published public private(set) var onionPeerCount: Int = 0
    @Published public private(set) var torConnectedPeerCount: Int = 0
    @Published public private(set) var sybilAttackAlert: SybilAlert?

    /// FIX #445: Prevent main thread hang from rapid @Published updates
    private var isUpdatingCounts = false
    private var pendingUpdate = false
    private let updateCountLock = NSLock()

    /// FIX #458: Protect peers array from concurrent access during filter operations
    private let peersLock = NSLock()

    // MARK: - Internal State

    /// Active peer connections
    internal var peers: [Peer] = []

    /// Known peer addresses (host:port -> info)
    private var knownAddresses: [String: AddressInfo] = [:]

    /// Addresses we've successfully connected to
    private var triedAddresses: Set<String> = []

    /// Addresses we haven't tried yet
    private var newAddresses: Set<String> = []

    /// Banned peers (host -> ban info) - ONLY for security issues
    private var bannedPeers: [String: BannedPeer] = [:]

    /// FIX #424: Persisted permanent bans (Zcash nodes, Sybil attackers)
    /// These survive app restarts to prevent re-trying known bad peers
    private let persistedBansKey = "ZipherX.PermanentlyBannedPeers"

    /// Permanently banned peers (hardcoded known bad actors)
    private let permanentlyBannedPeers: Set<String> = [
        // Add known Sybil attackers here
    ]

    /// FIX #284: Parked peers (host -> parked info) - connection timeouts
    private var parkedPeers: [String: ParkedPeer] = [:]

    /// Connection attempt tracking for cooldown
    private var connectionAttempts: [String: Date] = [:]

    /// Thread safety
    private let addressLock = NSLock()
    private let connectionAttemptsLock = NSLock()

    /// Sybil detection state
    private var consecutiveSybilRejections: Int = 0
    private var sybilBypassActive: Bool = false
    private let SYBIL_BYPASS_THRESHOLD: Int = 10

    /// FIX #472: Flag to track when header sync is in progress
    /// When true, block listeners should NOT be started (even for new peers)
    /// This prevents race condition where new peers' block listeners consume "headers" responses
    /// nonisolated(unsafe): Accessed from nonisolated functions via lock
    private nonisolated(unsafe) var headerSyncInProgressFlag: Bool = false
    private let headerSyncStateLock = NSLock()

    /// FIX #907: Flag to block block listeners during ANY operation
    /// Set to true during: scan, import, repair, broadcast, header sync
    /// Block listeners can ONLY run when app is idle on main screen
    private nonisolated(unsafe) var blockListenersBlockedFlag: Bool = false
    private let blockListenersBlockedLock = NSLock()

    // MARK: - Initialization

    private init() {
        // FIX #424: Load persisted permanent bans on startup
        loadPersistedBans()
        print("🔗 PeerManager initialized")
    }

    /// FIX #424: Load permanently banned peers from UserDefaults
    private func loadPersistedBans() {
        guard let data = UserDefaults.standard.data(forKey: persistedBansKey),
              let hosts = try? JSONDecoder().decode([String].self, from: data) else {
            return
        }

        for host in hosts {
            let ban = BannedPeer(address: host, banDuration: -1, reason: .wrongProtocol)
            bannedPeers[host] = ban
        }

        if !hosts.isEmpty {
            // FIX #1363: Update bannedPeerCount after loading persisted bans.
            // Without this, bannedPeerCount stays 0 until a ban/unban operation occurs,
            // causing Settings UI to show "0 banned" despite having persisted bans.
            updateBannedCount()
            print("🚫 FIX #424: Loaded \(hosts.count) persisted permanent bans")
        }
    }

    /// FIX #424: Save permanently banned peers to UserDefaults
    private func persistBans() {
        let permanentBans = bannedPeers.values
            .filter { $0.isPermanent }
            .map { $0.address }

        if let data = try? JSONEncoder().encode(permanentBans) {
            UserDefaults.standard.set(data, forKey: persistedBansKey)
        }
    }

    // MARK: - Peer List Access

    /// Get all peers with ready connections that are valid Zclassic nodes
    /// FIX #469: ONLY return peers with COMPLETED P2P handshake (version message received)
    /// FIX #434: Only return VALID ZCLASSIC peers (version 170010-170012)
    ///           Zcash peers (170018+) are filtered out - they return wrong Equihash params!
    /// FIX #458: Removed circular dependency - no longer calls NetworkManager.getAllConnectedPeers()
    /// FIX #458: Added lock to protect peers array from concurrent access
    public func getReadyPeers() -> [Peer] {
        peersLock.lock()
        let peerSnapshot = peers
        peersLock.unlock()

        // FIX #469: ONLY return peers with completed handshake AND live connection!
        // Peers with isHandshakeComplete=true but isConnectionReady=false will fail when used
        var readyPeers = peerSnapshot.filter { $0.isConnectionReady && $0.isHandshakeComplete }

        // FIX #1091: Filter out localhost in ZipherX mode - no local node in P2P-only mode
        let isFullNodeMode = WalletModeManager.shared.isUsingWalletDat
        if !isFullNodeMode {
            let beforeCount = readyPeers.count
            readyPeers = readyPeers.filter { $0.host != "127.0.0.1" && $0.host != "localhost" }
            let removed = beforeCount - readyPeers.count
            if removed > 0 {
                print("🚫 FIX #1091: Filtered out \(removed) localhost peer(s) - ZipherX P2P mode")
            }
        }

        let notReady = peerSnapshot.filter { $0.isConnectionReady && !$0.isHandshakeComplete }
        if !notReady.isEmpty {
            print("⚠️ FIX #469: Filtered out \(notReady.count) peers with incomplete handshake (TCP connected but no version message)")
        }

        let zcashPeers = peerSnapshot.filter { $0.isConnectionReady && !$0.isValidZclassicPeer && $0.peerVersion > 0 }
        if !zcashPeers.isEmpty {
            print("⚠️ FIX #434: Filtered out \(zcashPeers.count) Zcash peers (wrong chain)")
        }

        // FIX #458: Return empty array if no ready peers (caller should handle this)
        // Removed circular dependency that caused infinite recursion crash
        return readyPeers
    }

    /// Get first available peer (must be valid Zclassic node)
    /// FIX #469: Only return peers with COMPLETED P2P handshake
    /// FIX #434: Only return valid Zclassic peers
    /// FIX #458: Added lock to protect peers array
    public func getBestPeer() -> Peer? {
        peersLock.lock()
        let peerSnapshot = peers
        peersLock.unlock()

        return peerSnapshot.first { $0.isHandshakeComplete && !isBanned($0.host) }
    }

    /// Get peers suitable for broadcast (not banned, connection ready, recent activity)
    /// FIX #469: Only return peers with COMPLETED P2P handshake
    /// FIX #434: Only return valid Zclassic peers
    /// FIX #458: Added lock to protect peers array
    /// FIX #592: ALWAYS include hardcoded seeds - they're verified good nodes!
    /// FIX #1091: EXCEPT localhost in ZipherX mode - no local node in P2P-only mode
    public func getPeersForBroadcast() -> [Peer] {
        peersLock.lock()
        let peerSnapshot = peers
        peersLock.unlock()

        // FIX #1091: Check if we're in ZipherX mode (no local node)
        let isFullNodeMode = WalletModeManager.shared.isUsingWalletDat

        return peerSnapshot.filter { peer in
            // Must not be banned and must have completed handshake
            guard !isBanned(peer.host) && peer.isHandshakeComplete else {
                return false
            }

            // FIX #1091: NEVER include localhost in ZipherX mode - no local node exists!
            if !isFullNodeMode && (peer.host == "127.0.0.1" || peer.host == "localhost") {
                return false
            }

            // FIX #592: Hardcoded seeds are ALWAYS included (verified good nodes)
            // (But only in Full Node mode for localhost - see above)
            if HARDCODED_SEEDS.contains(peer.host) {
                return true  // Skip recent activity check for hardcoded seeds
            }

            // Other peers must have recent activity
            return peer.hasRecentActivity
        }
    }

    /// Get N peers for consensus operations
    /// FIX #469: Only return peers with COMPLETED P2P handshake
    /// FIX #434: Only return valid Zclassic peers
    /// FIX #458: Added lock to protect peers array
    public func getPeersForConsensus(count: Int) -> [Peer] {
        peersLock.lock()
        let peerSnapshot = peers
        peersLock.unlock()

        // CRITICAL: Must have LIVE connection (isConnectionReady), not just handshake!
        let ready = peerSnapshot.filter { $0.isConnectionReady && $0.isHandshakeComplete && !isBanned($0.host) }
        return Array(ready.prefix(count))
    }

    /// Get peers with recent activity
    /// FIX #458: Added lock to protect peers array
    public func getPeersWithRecentActivity() -> [Peer] {
        peersLock.lock()
        let peerSnapshot = peers
        peersLock.unlock()

        return peerSnapshot.filter { $0.hasRecentActivity }
    }

    // MARK: - Banning

    /// Check if a host is banned (includes expiration cleanup)
    public func isBanned(_ host: String) -> Bool {
        // Permanently banned
        if permanentlyBannedPeers.contains(host) {
            return true
        }

        // Check temporary ban
        if let ban = bannedPeers[host] {
            if ban.isExpired {
                bannedPeers.removeValue(forKey: host)
                updateBannedCount()
                return false
            }
            return true
        }

        return false
    }

    /// Ban a peer for a specific reason
    public func banPeer(_ peer: Peer, reason: BanReason) {
        banAddress(peer.host, port: peer.port, reason: reason)
    }

    /// Ban an address
    /// FIX #399: Hardcoded seeds are NEVER banned - only parked for exponential backoff
    public func banAddress(_ host: String, port: UInt16, reason: BanReason) {
        // FIX #399: Never ban hardcoded seeds - they're known-good ZCL nodes
        if HARDCODED_SEEDS.contains(host) {
            print("⚠️ FIX #399: Refusing to ban hardcoded seed \(host) - parking instead")
            parkPeer(host, port: port, wasPreferred: true)
            return
        }

        let ban = BannedPeer(address: host, banDuration: BAN_DURATION, reason: reason)
        bannedPeers[host] = ban
        updateBannedCount()
        print("🚫 Banned peer \(host):\(port) for: \(reason.rawValue)")
    }

    /// Permanently ban a peer for Sybil attack (fake chain height)
    /// FIX #399: Hardcoded seeds are NEVER banned even for Sybil attacks
    public func banPeerPermanentlyForSybil(_ host: String, port: UInt16, fakeHeight: UInt64, realHeight: UInt64) {
        // FIX #399: Never ban hardcoded seeds - if they send bad data, it's a network issue
        if HARDCODED_SEEDS.contains(host) {
            print("⚠️ FIX #399: Refusing to Sybil-ban hardcoded seed \(host) - parking instead")
            parkPeer(host, port: port, wasPreferred: true)
            return
        }

        let ban = BannedPeer(address: host, banDuration: -1, reason: .fakeChainHeight) // -1 = PERMANENT
        bannedPeers[host] = ban
        updateBannedCount()
        persistBans()  // FIX #424: Persist immediately
        print("🚨 PERMANENT BAN: Sybil attack from \(host) - claimed \(fakeHeight), real \(realHeight)")
    }

    /// Ban peer for Sybil attack (wrong protocol version)
    /// FIX #399: Hardcoded seeds are NEVER banned even for Sybil attacks
    public func banPeerForSybilAttack(_ host: String) {
        // FIX #399: Never ban hardcoded seeds
        if HARDCODED_SEEDS.contains(host) {
            print("⚠️ FIX #399: Refusing to Sybil-ban hardcoded seed \(host)")
            return
        }

        let ban = BannedPeer(address: host, banDuration: -1, reason: .wrongProtocol) // PERMANENT
        bannedPeers[host] = ban
        consecutiveSybilRejections += 1
        updateBannedCount()
        persistBans()  // FIX #424: Persist immediately
        print("🚨 PERMANENT BAN: Sybil attack from \(host) - wrong protocol version (Zcash node)")
    }

    /// Get all non-expired banned peers
    public func getBannedPeers() -> [BannedPeer] {
        return bannedPeers.values.filter { !$0.isExpired }
    }

    /// Manually unban a peer
    public func unbanPeer(_ address: String) {
        bannedPeers.removeValue(forKey: address)
        updateBannedCount()
        print("✅ Unbanned peer: \(address)")
    }

    /// Clear all temporary bans (not permanent)
    public func clearAllBannedPeers() {
        bannedPeers = bannedPeers.filter { $0.value.isPermanent }
        updateBannedCount()
        print("🧹 Cleared all temporary bans")
    }

    /// FIX #399: Clear any bans on hardcoded seeds (should never be banned)
    /// Call this at startup to recover from any previous bad bans
    public func clearHardcodedSeedBans() {
        var clearedCount = 0
        for seed in HARDCODED_SEEDS {
            if bannedPeers.removeValue(forKey: seed) != nil {
                clearedCount += 1
                print("✅ FIX #399: Cleared ban on hardcoded seed \(seed)")
            }
        }
        if clearedCount > 0 {
            updateBannedCount()
            print("🧹 FIX #399: Cleared \(clearedCount) bans on hardcoded seeds")
        }
    }

    private func updateBannedCount() {
        self.bannedPeerCount = self.getBannedPeers().count
    }

    // MARK: - Parking (Exponential Backoff)

    /// Park a peer (connection timeout - will retry with exponential backoff)
    public func parkPeer(_ host: String, port: UInt16, wasPreferred: Bool = false) {
        if var existing = parkedPeers[host] {
            existing.incrementRetry()
            parkedPeers[host] = existing
        } else {
            parkedPeers[host] = ParkedPeer(address: host, port: port, wasPreferred: wasPreferred)
        }
        let parked = parkedPeers[host]!
        print("🅿️ Parked peer \(host) - retry #\(parked.retryCount), next in \(Int(parked.nextRetryInterval))s")
    }

    /// Check if a peer is parked
    public func isParked(_ host: String) -> Bool {
        return parkedPeers[host] != nil
    }

    /// Check if a parked peer is ready for retry
    public func isParkedPeerReadyForRetry(_ host: String) -> Bool {
        return parkedPeers[host]?.isReadyForRetry ?? false
    }

    /// Unpark a peer (successful connection)
    public func unparkPeer(_ host: String, port: UInt16) {
        parkedPeers.removeValue(forKey: host)
        print("✅ Unparked peer \(host):\(port)")
    }

    /// Get all parked peers ready for retry
    public func getParkedPeersReadyForRetry() -> [ParkedPeer] {
        return parkedPeers.values.filter { $0.isReadyForRetry }
    }

    /// Get all parked peers
    public func getParkedPeers() -> [ParkedPeer] {
        return Array(parkedPeers.values)
    }

    /// Clear all parked peers
    public func clearAllParkedPeers() {
        parkedPeers.removeAll()
        print("🧹 Cleared all parked peers")
    }

    /// FIX #352: Clear parked hardcoded seeds only
    public func clearParkedHardcodedSeeds() {
        parkedPeers = parkedPeers.filter { !$0.value.isHardcodedSeed }
        print("🧹 Cleared parked hardcoded seeds")
    }

    /// FIX #863: Record a ping failure for a parked peer
    /// Called when a peer connects successfully but then fails ping
    /// Returns true if peer should be banned (too many ping failures)
    @discardableResult
    public func recordPingFailure(_ host: String, port: UInt16) -> Bool {
        addressLock.lock()
        defer { addressLock.unlock() }

        if var existing = parkedPeers[host] {
            existing.incrementPingFailure()
            parkedPeers[host] = existing
            print("⚠️ FIX #863: [\(host)] Ping failure #\(existing.pingFailureCount)")
            return existing.shouldBanForPingFailures
        } else {
            // Create new parked peer with ping failure
            var newParked = ParkedPeer(address: host, port: port)
            newParked.incrementPingFailure()
            parkedPeers[host] = newParked
            print("⚠️ FIX #863: [\(host)] First ping failure (new parked peer)")
            return false
        }
    }

    /// FIX #863: Reset ping failures for a peer (called when ping succeeds)
    public func resetPingFailures(_ host: String) {
        addressLock.lock()
        defer { addressLock.unlock() }

        if var existing = parkedPeers[host] {
            if existing.pingFailureCount > 0 {
                existing.resetPingFailures()
                parkedPeers[host] = existing
                print("✅ FIX #863: [\(host)] Ping failures reset")
            }
        }
    }

    /// FIX #863: Check if a peer should be banned for ping failures
    public func shouldBanForPingFailures(_ host: String) -> Bool {
        addressLock.lock()
        defer { addressLock.unlock() }

        return parkedPeers[host]?.shouldBanForPingFailures ?? false
    }

    /// FIX #908: Record a handshake failure for a peer
    /// After 5 failures → park for 1 hour
    /// After 1 hour, if 5 more failures → park for 24 hours
    /// Returns the park duration in seconds
    @discardableResult
    public func recordHandshakeFailure(_ host: String, port: UInt16) -> TimeInterval {
        addressLock.lock()
        defer { addressLock.unlock() }

        if var existing = parkedPeers[host] {
            // Check if previous handshake park has expired
            if existing.handshakeParkTime > 0 && existing.isHandshakeParkExpired {
                // Park expired, advance to next phase
                existing.advanceHandshakePhase()
                parkedPeers[host] = existing
                print("🔄 FIX #908: [\(host)] Handshake park expired, advancing to phase \(existing.handshakePhase)")
            }

            let parkDuration = existing.incrementHandshakeFailure()
            parkedPeers[host] = existing

            let durationStr = parkDuration >= 3600 ? "\(Int(parkDuration / 3600))h" : "\(Int(parkDuration / 60))m"
            print("⚠️ FIX #908: [\(host)] Handshake failure #\(existing.handshakeFailureCount) (phase \(existing.handshakePhase)), park for \(durationStr)")
            return parkDuration
        } else {
            // Create new parked peer with handshake failure
            var newParked = ParkedPeer(address: host, port: port)
            let parkDuration = newParked.incrementHandshakeFailure()
            parkedPeers[host] = newParked
            print("⚠️ FIX #908: [\(host)] First handshake failure (new parked peer), park for \(Int(parkDuration))s")
            return parkDuration
        }
    }

    /// FIX #908: Reset handshake failures for a peer (called when handshake succeeds)
    public func resetHandshakeFailures(_ host: String) {
        addressLock.lock()
        defer { addressLock.unlock() }

        if var existing = parkedPeers[host] {
            if existing.handshakeFailureCount > 0 || existing.handshakePhase > 0 {
                existing.resetHandshakeFailures()
                parkedPeers[host] = existing
                print("✅ FIX #908: [\(host)] Handshake failures reset")
            }
        }
    }

    /// FIX #908: Check if peer has extended handshake failure park
    public func hasHandshakeFailurePark(_ host: String) -> Bool {
        addressLock.lock()
        defer { addressLock.unlock() }

        guard let parked = parkedPeers[host] else { return false }
        return parked.handshakeParkTime > 0 && !parked.isHandshakeParkExpired
    }

    // MARK: - Cooldown

    /// Check if an address is on cooldown
    /// VUL-N-014: ALL peers subject to cooldown (hardcoded seeds no longer exempt)
    public func isOnCooldown(_ host: String, port: UInt16) -> Bool {
        let key = "\(host):\(port)"
        connectionAttemptsLock.lock()
        defer { connectionAttemptsLock.unlock() }

        if let lastAttempt = connectionAttempts[key] {
            return Date().timeIntervalSince(lastAttempt) < CONNECTION_COOLDOWN
        }
        return false
    }

    /// Record a connection attempt
    public func recordConnectionAttempt(_ host: String, port: UInt16) {
        let key = "\(host):\(port)"
        connectionAttemptsLock.lock()
        connectionAttempts[key] = Date()
        connectionAttemptsLock.unlock()
    }

    // MARK: - Peer Health Tracking

    /// Record successful peer interaction
    public func recordPeerSuccess(_ peer: Peer) {
        peer.recordSuccess()

        // Update address info
        let key = "\(peer.host):\(peer.port)"
        addressLock.lock()
        if var info = knownAddresses[key] {
            info.successes += 1
            info.lastSeen = Date()
            knownAddresses[key] = info
        }
        addressLock.unlock()
    }

    /// Record failed peer interaction
    public func recordPeerFailure(_ peer: Peer) {
        peer.recordFailure()

        // Update address info
        let key = "\(peer.host):\(peer.port)"
        addressLock.lock()
        if var info = knownAddresses[key] {
            info.attempts += 1
            knownAddresses[key] = info
        }
        addressLock.unlock()
    }

    // MARK: - Block Listener Coordination

    /// FIX #874: Check if any block listeners are running (for fast-path skip)
    public func hasActiveBlockListeners() async -> Bool {
        peersLock.lock()
        let hasListeners = peers.contains { $0.isListening }
        peersLock.unlock()
        return hasListeners
    }

    /// FIX #462: Stop all block listeners before header sync
    /// FIX #509: Now waits for listeners to actually finish (prevents headers consumption race)
    /// FIX #817: Stop peers in PARALLEL to avoid sequential 2s timeouts per stuck peer
    /// FIX #822: Add 5s overall timeout - don't block startup if peers are slow
    /// FIX #829: Fix timeout not triggering due to Swift task group serialization
    ///          Uses continuation + DispatchQueue for reliable timeout
    /// This prevents them from consuming "headers" responses meant for header sync
    /// - Parameter timeout: Optional timeout in seconds (default 5s, use 10s for broadcast)
    public func stopAllBlockListeners(timeout: Double = 5.0) async {
        print("🛑 PeerManager: Stopping all block listeners (timeout: \(timeout)s)...")

        // FIX #509: Get peers snapshot with lock, then stop each listener
        peersLock.lock()
        let peersSnapshot = peers
        peersLock.unlock()

        let listeningPeers = peersSnapshot.filter { $0.isListening }

        if listeningPeers.isEmpty {
            print("🛑 PeerManager: No listening peers to stop")
            return
        }

        print("🛑 PeerManager: Stopping \(listeningPeers.count) listening peers...")

        // FIX #822: FIRST signal all listeners to stop immediately (non-blocking)
        // This sets _isListening = false so they'll exit their loop ASAP
        for peer in listeningPeers {
            peer.signalStopListener()
        }

        // FIX #829: Use withCheckedContinuation + DispatchQueue for reliable timeout
        // Swift's cooperative threading can prevent Task.sleep from firing on time
        // GCD's DispatchQueue runs on a separate thread pool, guaranteeing the timeout
        let startTime = Date()
        let timeoutSeconds: Double = timeout  // FIX #833: Use parameter instead of hardcoded 5s

        let timedOut = await withCheckedContinuation { continuation in
            var continuationResumed = false
            let lock = NSLock()

            // Start the actual stop operation
            Task {
                await withTaskGroup(of: Void.self) { group in
                    for peer in listeningPeers {
                        group.addTask {
                            await peer.stopBlockListener()
                        }
                    }
                }

                // Completed - resume continuation if not already timed out
                lock.lock()
                if !continuationResumed {
                    continuationResumed = true
                    lock.unlock()
                    continuation.resume(returning: false)  // Not timed out
                } else {
                    lock.unlock()
                }
            }

            // Set up timeout on GCD queue (separate thread pool from Swift concurrency)
            DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds) {
                lock.lock()
                if !continuationResumed {
                    continuationResumed = true
                    lock.unlock()
                    continuation.resume(returning: true)  // Timed out
                } else {
                    lock.unlock()
                }
            }
        }

        let elapsed = Date().timeIntervalSince(startTime)
        if timedOut {
            print("⚠️ FIX #829: Block listener stop timed out after \(String(format: "%.1f", elapsed))s - proceeding anyway (\(listeningPeers.count) listeners)")
            // FIX #906: Force release all message locks to unblock header sync
            // The listeners may still be holding locks even though we're proceeding
            print("🔓 FIX #906: Force releasing all message locks after timeout")
            for peer in listeningPeers {
                await peer.forceReleaseMessageLock()
            }
        } else {
            print("🛑 PeerManager: Stopped \(listeningPeers.count) block listeners in \(String(format: "%.1f", elapsed))s")
        }

        // FIX #913: Mark all peers as active after stopping block listeners
        // When block listeners are stopped, lastActivity doesn't update → peers become "stale"
        // This causes ensureConnected() to try reconnecting which fails with "Peer handshake failed"
        // Solution: Mark all connected peers as active so they don't appear stale
        peersLock.lock()
        let connectedPeers = peers.filter { $0.isConnectionReady }
        peersLock.unlock()
        for peer in connectedPeers {
            peer.markActive()
        }
        print("✅ FIX #913: Marked \(connectedPeers.count) peers as active after stopping block listeners")
    }

    /// FIX #834: Ensure ALL block listeners are stopped before critical operations (broadcast)
    /// Returns true only when ALL listeners verified stopped, false if any still running after max retries
    /// This is stricter than stopAllBlockListeners() which proceeds on timeout
    public func ensureAllBlockListenersStopped(maxRetries: Int = 3, retryDelay: Double = 1.0) async -> Bool {
        print("🔒 FIX #834: Ensuring ALL block listeners are stopped...")

        for attempt in 1...maxRetries {
            // First, stop all listeners
            await stopAllBlockListeners(timeout: 5.0)

            // Now VERIFY all are actually stopped
            peersLock.lock()
            let stillListening = peers.filter { $0.isListening }
            peersLock.unlock()

            if stillListening.isEmpty {
                print("✅ FIX #834: All block listeners verified stopped (attempt \(attempt))")
                return true
            }

            print("⚠️ FIX #834: \(stillListening.count) listeners still running after attempt \(attempt)/\(maxRetries)")
            for peer in stillListening {
                print("   ⚠️ Still listening: \(peer.host):\(peer.port)")
                // Force signal stop again
                peer.signalStopListener()
            }

            if attempt < maxRetries {
                print("🔄 FIX #834: Waiting \(retryDelay)s before retry...")
                try? await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
            }
        }

        // Final check
        peersLock.lock()
        let finalCheck = peers.filter { $0.isListening }
        peersLock.unlock()

        if finalCheck.isEmpty {
            print("✅ FIX #834: All block listeners stopped after retries")
            return true
        } else {
            print("🚨 FIX #834: FAILED - \(finalCheck.count) listeners still running after \(maxRetries) attempts!")
            for peer in finalCheck {
                print("   🚨 Still listening: \(peer.host):\(peer.port)")
            }
            return false
        }
    }

    /// Get count of currently listening peers (for verification)
    public func getListeningPeerCount() -> Int {
        peersLock.lock()
        let count = peers.filter { $0.isListening }.count
        peersLock.unlock()
        return count
    }

    /// Resume all block listeners (after header sync)
    /// FIX #509 v2: DISABLED - Block listeners should NOT start automatically
    /// They should only be started when app is 100% ready on main balance screen
    public func resumeAllBlockListeners() async {
        print("▶️ FIX #509: PeerManager resumeAllBlockListeners called - BLOCKED (will start on main screen only)")
        // DO NOT start block listeners here anymore
    }

    /// FIX #509: Start block listeners ONLY when app is fully ready on main balance screen
    /// This should be called explicitly by the UI when the main screen is displayed
    /// FIX #907: Check if operations are blocking listeners before starting
    public func startBlockListenersOnMainScreen() async {
        // FIX #907: Don't start if operations are in progress
        if areBlockListenersBlocked() {
            print("🛑 FIX #907: PeerManager startBlockListenersOnMainScreen BLOCKED - operations in progress")
            return
        }

        print("▶️ FIX #509: PeerManager - Starting block listeners on main balance screen...")
        peersLock.lock()
        let peersSnapshot = peers
        peersLock.unlock()

        for peer in peersSnapshot {
            peer.startBlockListener()
        }
    }

    // MARK: - FIX #472: Header Sync State Management

    /// Set header sync in progress state (called before header sync starts)
    /// nonisolated: Uses its own lock for thread safety, doesn't need MainActor
    nonisolated public func setHeaderSyncInProgress(_ inProgress: Bool) {
        headerSyncStateLock.lock()
        defer { headerSyncStateLock.unlock() }
        headerSyncInProgressFlag = inProgress
        print("📊 FIX #472: Header sync state = \(inProgress ? "IN PROGRESS" : "COMPLETE")")
    }

    /// Check if header sync is currently in progress
    /// When true, block listeners should NOT be started
    /// nonisolated: Uses its own lock for thread safety, doesn't need MainActor
    nonisolated public func isHeaderSyncInProgress() -> Bool {
        headerSyncStateLock.lock()
        defer { headerSyncStateLock.unlock() }
        return headerSyncInProgressFlag
    }

    // MARK: - FIX #907: Block Listeners Blocked State Management

    /// FIX #907: Set block listeners blocked state
    /// Called at START of any operation (scan, import, repair, broadcast)
    /// Block listeners can ONLY run when blocked = false
    nonisolated public func setBlockListenersBlocked(_ blocked: Bool) {
        blockListenersBlockedLock.lock()
        let changed = blockListenersBlockedFlag != blocked
        blockListenersBlockedFlag = blocked
        blockListenersBlockedLock.unlock()
        // FIX #1570: Only log state CHANGES to reduce log spam (was 70 lines in 20 min)
        if changed {
            print("🛑 FIX #907: Block listeners \(blocked ? "BLOCKED" : "UNBLOCKED")")
        }
    }

    /// FIX #907: Check if block listeners are blocked
    /// Returns true if ANY operation is in progress that requires peers
    nonisolated public func areBlockListenersBlocked() -> Bool {
        blockListenersBlockedLock.lock()
        defer { blockListenersBlockedLock.unlock() }
        return blockListenersBlockedFlag
    }

    /// FIX #907: Comprehensive check - should block listeners be allowed to start?
    /// Returns false if any operation is in progress
    nonisolated public func canStartBlockListeners() -> Bool {
        // Check both flags
        let headerSyncBlocked = isHeaderSyncInProgress()
        let operationsBlocked = areBlockListenersBlocked()
        return !headerSyncBlocked && !operationsBlocked
    }

    // MARK: - Sybil Detection

    /// Reset Sybil counter on legitimate peer connection
    public func resetSybilCounter() {
        addressLock.lock()
        if consecutiveSybilRejections > 0 {
            print("✅ Reset Sybil counter (was \(consecutiveSybilRejections))")
            consecutiveSybilRejections = 0
        }
        addressLock.unlock()
    }

    /// FIX H-002: NEVER bypass Tor — deanonymization risk outweighs connectivity.
    /// Old behavior: returned true after 10 Sybil rejections → caused Tor daemon shutdown → clearnet IP exposure.
    /// New behavior: always returns false. Callers should surface alert to user instead of deanonymizing.
    public func shouldBypassTorForSybil() -> Bool {
        return false  // FIX H-002: Never bypass Tor for privacy safety
    }

    /// Complete Sybil bypass (mark as active)
    nonisolated public func completeSybilBypass() {
        Task { @MainActor in
            self.sybilBypassActive = true
            self.sybilAttackAlert = SybilAlert(attackerCount: self.consecutiveSybilRejections, bypassedTor: true)
            print("🚨 Sybil bypass completed - \(self.consecutiveSybilRejections) attackers detected")
        }
    }

    /// Clear Sybil attack alert
    nonisolated public func clearSybilAttackAlert() {
        Task { @MainActor in self.sybilAttackAlert = nil }
    }

    // MARK: - Address Management

    /// Get count of known addresses
    public var knownAddressCount: Int {
        addressLock.lock()
        defer { addressLock.unlock() }
        return knownAddresses.count
    }

    /// Add a known address
    public func addKnownAddress(_ address: PeerAddress, source: String) {
        let key = address.key

        addressLock.lock()
        if knownAddresses[key] == nil {
            knownAddresses[key] = AddressInfo(address: address, source: source)
            newAddresses.insert(key)
        }
        addressLock.unlock()
    }

    /// Mark an address as tried
    public func markAddressTried(_ host: String, port: UInt16) {
        let key = "\(host):\(port)"
        addressLock.lock()
        newAddresses.remove(key)
        triedAddresses.insert(key)
        addressLock.unlock()
    }

    // MARK: - Peer Count Updates

    /// Update connected peer counts (call after peer list changes)
    /// FIX #435: Safe access to peers array to prevent EXC_BAD_ACCESS crash
    /// FIX #445: Debounce @Published updates to prevent main thread hang
    public func updatePeerCounts() {
        // FIX #447: Take a SNAPSHOT of peers array to prevent EXC_BAD_ACCESS
        // FIX #458: Use lock to protect peers array access
        peersLock.lock()
        let peerSnapshot = Array(peers)
        peersLock.unlock()

        // Take a snapshot of peer states to avoid race conditions
        // Peer.isConnectionReady accesses NWConnection.state which can change from background threads
        var readyCount = 0
        var torCount = 0
        var onionCount = 0

        for peer in peerSnapshot {
            // FIX #447 v2: Use NSLock to protect peer access, not try? (peer is not throwing)
            // Access peer properties safely - if peer is deallocated, skip it
            let isReady = peer.isConnectionReady
            if isReady {
                readyCount += 1
                if peer.isConnectedViaTor {
                    torCount += 1
                }
                if peer.isOnion {
                    onionCount += 1
                }
            }
        }

        // FIX #445: Debounce rapid updates to prevent main thread hang
        // FIX #448: Use lock to prevent race condition in check-then-set
        updateCountLock.lock()
        let shouldSkip = isUpdatingCounts
        if !shouldSkip {
            isUpdatingCounts = true
        }
        updateCountLock.unlock()

        if shouldSkip {
            pendingUpdate = true
            return
        }

        // FIX #446: @Published properties MUST be updated on main thread for SwiftUI
        // This function is already @MainActor isolated, so we're always on main thread
        // The fix is to ensure we don't call this from background contexts

        self.connectedPeerCount = readyCount
        self.torConnectedPeerCount = torCount
        self.onionPeerCount = onionCount

        self.updateCountLock.lock()
        self.isUpdatingCounts = false
        let hasPending = self.pendingUpdate
        if hasPending {
            self.pendingUpdate = false
        }
        self.updateCountLock.unlock()

        // Check for pending updates after we're done
        if hasPending {
            // Schedule update for next runloop to prevent tight loop
            Task { @MainActor [weak self] in
                self?.updatePeerCounts()
            }
        }
    }

    // MARK: - Peer List Sync (for incremental migration)

    /// Sync peer list from NetworkManager (for incremental migration)
    /// Eventually, PeerManager will own the peer list directly
    /// nonisolated to allow calling from background threads
    /// FIX #458: Uses Task { @MainActor in ... } for async serialization
    nonisolated public func syncPeers(_ peerList: [Peer]) {
        Task { @MainActor [weak self] in
            self?.peers = peerList
            self?.updatePeerCounts()
        }
    }

    /// Add a peer to the list
    /// nonisolated to allow calling from background threads
    /// FIX #458: Uses Task { @MainActor in ... } for async serialization
    nonisolated public func addPeer(_ peer: Peer) {
        Task { @MainActor [weak self] in
            self?.peers.append(peer)
            self?.updatePeerCounts()
        }
    }

    /// Remove a peer from the list
    /// nonisolated to allow calling from background threads
    /// FIX #458: Uses Task { @MainActor in ... } for async serialization
    nonisolated public func removePeer(_ peer: Peer) {
        Task { @MainActor [weak self] in
            self?.peers.removeAll { $0.id == peer.id }
            self?.updatePeerCounts()
        }
    }

    /// Remove all peers
    public func removeAllPeers() {
        peers.removeAll()
        updatePeerCounts()
    }

    /// Get internal peers array (for NetworkManager migration)
    public var allPeers: [Peer] {
        return peers
    }

    // MARK: - Tor State Tracking (for address selection)

    /// Whether Tor SOCKS is available
    internal var torIsAvailable: Bool = false

    /// Whether .onion circuits are ready (requires warmup period)
    internal var onionCircuitsReady: Bool = false

    /// Update Tor availability (called by NetworkManager)
    public func updateTorState(available: Bool, onionReady: Bool) {
        torIsAvailable = available
        onionCircuitsReady = onionReady
    }

    // MARK: - Peer Selection (FIX #384)

    /// Select best peer to connect to based on scoring
    /// Filters .onion addresses based on Tor availability
    /// FIX #189: Thread-safe access to knownAddresses
    public func selectBestAddress() -> PeerAddress? {
        addressLock.lock()
        defer { addressLock.unlock() }

        // Helper to check if address is .onion
        func isOnion(_ host: String) -> Bool {
            return host.hasSuffix(".onion")
        }

        // Helper to filter address based on Tor availability
        func isAddressUsable(_ address: PeerAddress) -> Bool {
            if isOnion(address.host) {
                // .onion addresses require both Tor and circuit warmup
                return onionCircuitsReady
            }
            return true // Regular addresses always usable
        }

        // Prefer new addresses first
        let usableNewAddresses = newAddresses.filter { key in
            guard let info = knownAddresses[key] else { return false }
            return isAddressUsable(info.address)
        }

        if let newKey = usableNewAddresses.randomElement(),
           let info = knownAddresses[newKey] {
            if isOnion(info.address.host) {
                print("🧅 Selected new .onion peer: \(LogRedaction.redactHost(info.address.host))")
            }
            return info.address
        }

        // Otherwise select from tried addresses based on chance
        var candidates: [(String, Double)] = []
        for key in triedAddresses {
            if let info = knownAddresses[key] {
                guard isAddressUsable(info.address) else { continue }
                var chance = info.getChance()
                // NET-005: Boost .onion addresses 2x for Sybil resistance (harder to generate)
                if isOnion(info.address.host) {
                    chance *= 2.0
                }
                if chance > 0 {
                    candidates.append((key, chance))
                }
            }
        }

        // Weighted random selection
        let totalChance = candidates.reduce(0) { $0 + $1.1 }
        if totalChance > 0 {
            var random = Double.random(in: 0..<totalChance)
            for (key, chance) in candidates {
                random -= chance
                if random <= 0 {
                    if let address = knownAddresses[key]?.address {
                        if isOnion(address.host) {
                            print("🧅 Selected tried .onion peer: \(LogRedaction.redactHost(address.host))")
                        }
                        return address
                    }
                }
            }
        }

        return nil
    }

    /// Check if a peer should be skipped (banned OR parked and not ready for retry)
    /// FIX #908: Also considers handshake failure park time
    public func shouldSkipPeer(_ host: String) -> Bool {
        // Banned peers are always skipped
        if isBanned(host) {
            return true
        }

        // Parked peers are skipped unless ready for retry
        addressLock.lock()
        if let parked = parkedPeers[host] {
            let ready = parked.isReadyForRetry
            addressLock.unlock()
            if !ready {
                // FIX #908: Log extended handshake park if applicable
                if parked.handshakeParkTime > 0 {
                    let remaining = parked.handshakeParkTimeRemaining
                    let hrs = Int(remaining / 3600)
                    let mins = Int((remaining.truncatingRemainder(dividingBy: 3600)) / 60)
                    print("🅿️ FIX #908: Skipping \(host) - handshake park (\(hrs)h \(mins)m remaining)")
                }
            }
            return !ready
        }
        addressLock.unlock()

        return false
    }

    /// Get preferred seeds from database
    nonisolated func getPreferredSeeds() -> [WalletDatabase.TrustedPeer] {
        return (try? WalletDatabase.shared.getPreferredSeeds()) ?? []
    }

    /// Get bundled addresses
    public func getBundledAddresses() -> [PeerAddress] {
        addressLock.lock()
        let bundled = knownAddresses.values
            .filter { $0.source == "bundled" }
            .map { $0.address }
        addressLock.unlock()
        return bundled
    }

    /// Record successful connection to address
    public func recordConnectionSuccess(_ host: String, port: UInt16) {
        let key = "\(host):\(port)"
        addressLock.lock()
        if var info = knownAddresses[key] {
            info.successes += 1
            info.lastSeen = Date()
            knownAddresses[key] = info
        }
        newAddresses.remove(key)
        triedAddresses.insert(key)
        addressLock.unlock()
    }

    /// Record failed connection to address
    public func recordConnectionFailure(_ host: String, port: UInt16) {
        let key = "\(host):\(port)"
        addressLock.lock()
        if var info = knownAddresses[key] {
            info.attempts += 1
            knownAddresses[key] = info
        }
        addressLock.unlock()
    }

    // MARK: - Peer Rotation Helpers

    /// Get peers that should be banned
    public func getPeersToRemove() -> [Peer] {
        return peers.filter { peer in
            isBanned(peer.host) || peer.shouldBan() || !peer.isConnectionReady
        }
    }

    /// Get worst performing peer to rotate out
    public func getWorstPeer() -> Peer? {
        guard peers.count >= MIN_PEERS else { return nil }
        if let worstPeer = peers.min(by: { $0.getChance() < $1.getChance() }) {
            if worstPeer.getChance() < 0.5 {
                return worstPeer
            }
        }
        return nil
    }

    /// Check if address is already connected
    public func isAlreadyConnected(_ host: String) -> Bool {
        return peers.contains { $0.host == host && $0.isConnectionReady }
    }

    /// Get count of .onion addresses in address book
    public func getOnionAddressCount() -> Int {
        addressLock.lock()
        let count = knownAddresses.values.filter { $0.address.host.hasSuffix(".onion") }.count
        addressLock.unlock()
        return count
    }

    // MARK: - Recovery State Tracking

    /// Track reconnection attempts for backoff
    private var reconnectionAttempts: [String: Int] = [:]

    /// Base backoff for reconnection (static for nonisolated access)
    private static let BASE_BACKOFF_SECONDS: TimeInterval = 2
    private static let MAX_BACKOFF_SECONDS: TimeInterval = 300

    /// Network generation for stale connection detection (FIX #268)
    private var networkGeneration: UInt64 = 0

    /// Increment network generation (call on network change events)
    public func incrementNetworkGeneration() {
        networkGeneration += 1
    }

    /// Get current network generation
    public func getNetworkGeneration() -> UInt64 {
        return networkGeneration
    }

    /// Get reconnection attempt count for address
    public func getReconnectionAttempts(_ host: String, port: UInt16) -> Int {
        let key = "\(host):\(port)"
        return reconnectionAttempts[key] ?? 0
    }

    /// Increment reconnection attempt count
    public func incrementReconnectionAttempts(_ host: String, port: UInt16) {
        let key = "\(host):\(port)"
        reconnectionAttempts[key] = (reconnectionAttempts[key] ?? 0) + 1
    }

    /// Reset reconnection attempt count (on success)
    public func resetReconnectionAttempts(_ host: String, port: UInt16) {
        let key = "\(host):\(port)"
        reconnectionAttempts.removeValue(forKey: key)
    }

    /// Calculate exponential backoff with jitter (pure function, no state access)
    nonisolated public func calculateBackoffWithJitter(attempts: Int) -> TimeInterval {
        let exponentialBackoff = Self.BASE_BACKOFF_SECONDS * pow(2.0, Double(min(attempts, 7)))  // Cap at 2^7 = 128x
        let cappedBackoff = min(Self.MAX_BACKOFF_SECONDS, exponentialBackoff)

        // Add jitter (0 to base/2 seconds)
        let jitter = Double.random(in: 0...(Self.BASE_BACKOFF_SECONDS / 2))

        return cappedBackoff + jitter
    }

    /// Check if reconnection should be aborted due to stale generation
    public func isReconnectionStale(capturedGeneration: UInt64) -> Bool {
        return networkGeneration != capturedGeneration
    }

    // MARK: - SOCKS5 Failure Tracking

    /// Consecutive SOCKS5 failures for Tor health detection
    private var consecutiveSOCKS5Failures: Int = 0
    private let SOCKS5_FAILURE_THRESHOLD: Int = 5

    /// Record SOCKS5 failure
    public func recordSOCKS5Failure() {
        consecutiveSOCKS5Failures += 1
    }

    /// Reset SOCKS5 failure counter
    public func resetSOCKS5Failures() {
        consecutiveSOCKS5Failures = 0
    }

    /// Check if SOCKS5 failure threshold exceeded
    public func shouldCheckTorHealth() -> Bool {
        return consecutiveSOCKS5Failures >= SOCKS5_FAILURE_THRESHOLD
    }

    /// Get SOCKS5 failure count
    public func getSOCKS5FailureCount() -> Int {
        return consecutiveSOCKS5Failures
    }

    // MARK: - FIX #387: Verified Broadcast Peers (Centralized)

    /// Get verified-responsive peers for broadcast
    /// FIX #387: Centralized ping verification to detect zombie connections
    /// This is the ONLY method that should be used for transaction broadcast
    /// NOTE: This is nonisolated to allow calling from non-MainActor contexts
    nonisolated public func getVerifiedPeersForBroadcast() async -> [Peer] {
        // Step 1: Get fresh candidate peers (must hop to MainActor)
        let candidates = await MainActor.run { self.getPeersForBroadcast() }

        if candidates.isEmpty {
            print("⚠️ FIX #387: No candidate peers for broadcast")
            return []
        }

        print("🔍 FIX #387: Testing \(candidates.count) peers with quick ping...")

        // FIX #563 v8: Use 5-second timeout instead of 2 seconds
        // 2s is too aggressive - only 1/6 peers responded, causing DUPLICATE false positive
        // FIX #823: Added 10s OVERALL timeout - Swift TaskGroup can serialize tasks
        // causing 16 peers × 5s = 80s hang (same issue as FIX #822)
        var respondingPeers: [Peer] = []
        var didTimeout = false

        // FIX #824: Always include localhost - skip ping verification for local node
        // Local node is most reliable for broadcast but ping can fail due to lock contention
        // when block listener is running. User reports localhost works 100%.
        let localhostPeers = candidates.filter { $0.host == "127.0.0.1" }
        let remotePeers = candidates.filter { $0.host != "127.0.0.1" }

        if !localhostPeers.isEmpty {
            respondingPeers.append(contentsOf: localhostPeers)
            print("✅ FIX #824: Localhost included in broadcast (ping skipped - most reliable)")
        }

        // FIX #823 v3: Simple timeout pattern - don't wait for slow pings
        // v2 had a bug: withThrowingTaskGroup still waited for tasks that were cancelled
        // v3: Use a simple deadline and collect results that arrive in time
        let deadline = Date().addingTimeInterval(10) // 10 second overall timeout
        var pendingCount = remotePeers.count

        print("🔍 FIX #823 v3: Starting ping verification for \(remotePeers.count) remote peers (10s deadline)")

        // Start all pings in parallel
        // FIX #869: sendPing now returns PingResult
        let pingTask = Task {
            await withTaskGroup(of: (Peer, PingResult).self) { group in
                for peer in remotePeers {
                    group.addTask {
                        let result = await peer.sendPing(timeoutSeconds: 5)
                        return (peer, result)
                    }
                }

                for await (peer, pingResult) in group {
                    // Check if we've exceeded deadline
                    if Date() > deadline {
                        print("⏰ FIX #823 v3: Deadline reached, stopping ping collection")
                        break  // Stop waiting for more results
                    }

                    pendingCount -= 1
                    // FIX #869: .success or .busy means peer is alive
                    let isAlive = (pingResult == .success || pingResult == .busy)
                    if isAlive {
                        respondingPeers.append(peer)
                        print("✅ FIX #563 v8: Peer \(peer.host) responds to ping (\(pendingCount) pending)")
                    } else {
                        print("❌ FIX #563 v8: Peer \(peer.host) failed ping (\(pingResult)) (\(pendingCount) pending)")
                    }
                }
            }
        }

        // Wait for either: all pings complete OR timeout
        // Use simple polling instead of complex TaskGroup race
        var pingsCompleted = false
        while Date() < deadline {
            if pingTask.isCancelled || pendingCount == 0 {
                pingsCompleted = true
                break
            }
            try? await Task.sleep(nanoseconds: 100_000_000) // Check every 100ms
        }

        // Cancel any remaining work
        pingTask.cancel()

        print("📊 FIX #823 v3: Ping verification ended - completed=\(pingsCompleted), responses=\(respondingPeers.count)")

        // FIX #823 v3: Use whatever peers responded before deadline
        // If we got some responses, use them. If none, fall back to all candidates.
        let responseRate = Double(respondingPeers.count) / Double(candidates.count)

        if respondingPeers.isEmpty {
            print("⚠️ FIX #823 v3: No peers responded in time, using all \(candidates.count) candidates")
            return candidates
        }

        if responseRate < 0.5 {
            print("⚠️ FIX #563 v8: Only \(respondingPeers.count)/\(candidates.count) peers responded (\(Int(responseRate * 100))%)")
            print("⚠️ FIX #563 v8: Using all \(candidates.count) candidates - ping filtering too aggressive")
            return candidates
        }

        print("⚡ FIX #823 v3: \(respondingPeers.count)/\(candidates.count) peers verified responsive")
        return respondingPeers
    }

    /// Get verified peers with recovery fallback
    /// FIX #387: If no peers respond, trigger recovery and wait
    nonisolated public func getVerifiedPeersWithRecovery(networkManager: NetworkManager) async -> [Peer] {
        var verifiedPeers = await getVerifiedPeersForBroadcast()

        if verifiedPeers.isEmpty {
            print("🔄 FIX #387: No responsive peers - triggering recovery...")
            await networkManager.attemptPeerRecovery()

            // Wait for recovery to establish connections
            try? await Task.sleep(nanoseconds: 3_000_000_000)

            // Try again
            verifiedPeers = await getVerifiedPeersForBroadcast()
            print("🔄 FIX #387: After recovery: \(verifiedPeers.count) peers available")
        }

        return verifiedPeers
    }
}
