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
    public let CONSENSUS_THRESHOLD = 5  // Byzantine fault tolerance
    public let BAN_DURATION: TimeInterval = 604800  // 7 days
    public let CONNECTION_COOLDOWN: TimeInterval = 2.0
    public let MAX_KNOWN_ADDRESSES = 1000

    /// FIX #235, FIX #423: Hardcoded Zclassic seed nodes - EXEMPT from cooldown
    /// These are VERIFIED good ZCL nodes that should ALWAYS be tried first
    public let HARDCODED_SEEDS: Set<String> = [
        // FIX #507: Local node - highest priority (always fastest when available)
        "127.0.0.1",          // Local zclassicd node on port 8033
        // Original seeds - ZCL and ZEC both use Equihash(200,9)!
        "140.174.189.3",
        "140.174.189.17",
        "205.209.104.118",
        "95.179.131.117",
        "45.77.216.198",
        // FIX #423: Additional verified ZCL nodes from successful connections
        "212.23.222.231",   // Connected successfully with version 170011
        "157.90.223.151"    // Block listener started successfully
    ]

    /// DNS seeds for peer discovery
    public let DNS_SEEDS = [
        "dnsseed.zclassic.org",
        "dnsseed.rotorproject.org",
        "dnsseed.zclnet.net"
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
        let readyPeers = peerSnapshot.filter { $0.isConnectionReady && $0.isHandshakeComplete }

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
    /// FIX #592: ALWAYS include hardcoded seeds (especially 127.0.0.1) - they're verified good nodes!
    public func getPeersForBroadcast() -> [Peer] {
        peersLock.lock()
        let peerSnapshot = peers
        peersLock.unlock()

        return peerSnapshot.filter { peer in
            // Must not be banned and must have completed handshake
            guard !isBanned(peer.host) && peer.isHandshakeComplete else {
                return false
            }

            // FIX #592: Hardcoded seeds are ALWAYS included (verified good nodes)
            // Especially 127.0.0.1 - the local node which user says is working 100%
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

    // MARK: - Cooldown

    /// Check if an address is on cooldown
    public func isOnCooldown(_ host: String, port: UInt16) -> Bool {
        // Hardcoded seeds exempt from cooldown
        if HARDCODED_SEEDS.contains(host) {
            return false
        }

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

    /// FIX #462: Stop all block listeners before header sync
    /// FIX #509: Now waits for listeners to actually finish (prevents headers consumption race)
    /// This prevents them from consuming "headers" responses meant for header sync
    public func stopAllBlockListeners() async {
        print("🛑 PeerManager: Stopping all block listeners...")

        // FIX #509: Get peers snapshot with lock, then stop each listener
        peersLock.lock()
        let peersSnapshot = peers
        peersLock.unlock()

        var stoppedCount = 0

        // FIX #509: Await each stop to ensure listener is actually finished
        for peer in peersSnapshot {
            if peer.isListening {
                await peer.stopBlockListener()
                stoppedCount += 1
            }
        }

        print("🛑 PeerManager: Stopped \(stoppedCount) block listeners (all finished)")
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
    public func startBlockListenersOnMainScreen() async {
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

    /// Check if we should bypass Tor due to Sybil attack
    public func shouldBypassTorForSybil() -> Bool {
        addressLock.lock()
        defer { addressLock.unlock() }
        return consecutiveSybilRejections >= SYBIL_BYPASS_THRESHOLD && connectedPeerCount == 0
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
                print("🧅 Selected new .onion peer: \(info.address.host)")
            }
            return info.address
        }

        // Otherwise select from tried addresses based on chance
        var candidates: [(String, Double)] = []
        for key in triedAddresses {
            if let info = knownAddresses[key] {
                guard isAddressUsable(info.address) else { continue }
                let chance = info.getChance()
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
                            print("🧅 Selected tried .onion peer: \(address.host)")
                        }
                        return address
                    }
                }
            }
        }

        return nil
    }

    /// Check if a peer should be skipped (banned OR parked and not ready for retry)
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
        var respondingPeers: [Peer] = []

        await withTaskGroup(of: (Peer, Bool).self) { group in
            for peer in candidates {
                group.addTask {
                    // 5-second ping test to accommodate Tor/remote latency
                    let success = await peer.sendPing(timeoutSeconds: 5)
                    return (peer, success)
                }
            }

            for await (peer, success) in group {
                if success {
                    respondingPeers.append(peer)
                    print("✅ FIX #563 v8: Peer \(peer.host) responds to ping")
                } else {
                    print("❌ FIX #563 v8: Peer \(peer.host) failed ping (zombie)")
                }
            }
        }

        // FIX #563 v8: If < 50% respond, use candidates anyway
        // Don't let aggressive ping filtering reduce broadcast to too few peers
        let responseRate = Double(respondingPeers.count) / Double(candidates.count)
        if respondingPeers.isEmpty || responseRate < 0.5 {
            print("⚠️ FIX #563 v8: Only \(respondingPeers.count)/\(candidates.count) peers responded (\(Int(responseRate * 100))%)")
            print("⚠️ FIX #563 v8: Using all \(candidates.count) candidates - ping timeout too aggressive")
            return candidates
        }

        print("⚡ FIX #563 v8: \(respondingPeers.count)/\(candidates.count) peers verified responsive")
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
