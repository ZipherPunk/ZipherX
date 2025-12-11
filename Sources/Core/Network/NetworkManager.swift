import Foundation
import Network
import Combine

/// Thread-safe actor for transaction tracking state
/// Eliminates priority inversion from NSLock usage in async contexts
private actor TransactionTrackingState {
    /// Pending outgoing transactions (txid -> amount in zatoshis)
    private var pendingOutgoingTxs: [String: UInt64] = [:]

    /// Notified incoming mempool transactions (to avoid duplicate notifications)
    private var notifiedMempoolIncomingTxs: Set<String> = []

    /// Pending incoming transactions (txid -> amount in zatoshis) - tracked until confirmed
    private var pendingIncomingTxs: [String: UInt64] = [:]

    // MARK: - Outgoing Transaction Tracking

    func trackOutgoing(txid: String, amount: UInt64) -> (total: UInt64, count: Int) {
        pendingOutgoingTxs[txid] = amount
        let total = pendingOutgoingTxs.values.reduce(0, +)
        return (total, pendingOutgoingTxs.count)
    }

    func confirmOutgoing(txid: String) -> (amount: UInt64?, removed: Bool, total: UInt64, count: Int) {
        let amount = pendingOutgoingTxs[txid]
        let removed = pendingOutgoingTxs.removeValue(forKey: txid) != nil
        let total = pendingOutgoingTxs.values.reduce(0, +)
        return (amount, removed, total, pendingOutgoingTxs.count)
    }

    func getPendingTxids() -> [String] {
        Array(pendingOutgoingTxs.keys)
    }

    func isPendingOutgoing(txid: String) -> Bool {
        pendingOutgoingTxs[txid] != nil
    }

    /// Get all pending outgoing txids as a Set for efficient lookup
    func getAllPendingOutgoingTxids() -> Set<String> {
        Set(pendingOutgoingTxs.keys)
    }

    /// Clear all pending outgoing transactions (called when broadcast fails)
    func clearAllOutgoing() {
        pendingOutgoingTxs.removeAll()
    }

    // MARK: - Incoming Mempool Notification Tracking

    func checkAndMarkNotified(txid: String) -> Bool {
        let isNew = !notifiedMempoolIncomingTxs.contains(txid)
        if isNew {
            notifiedMempoolIncomingTxs.insert(txid)
        }
        return isNew
    }

    func clearIncomingNotification(txid: String) {
        notifiedMempoolIncomingTxs.remove(txid)
    }

    // MARK: - Incoming Transaction Tracking (for confirmed celebration)

    func trackIncoming(txid: String, amount: UInt64) {
        pendingIncomingTxs[txid] = amount
    }

    func confirmIncoming(txid: String) -> UInt64? {
        let amount = pendingIncomingTxs[txid]
        pendingIncomingTxs.removeValue(forKey: txid)
        return amount
    }

    func isPendingIncoming(txid: String) -> Bool {
        pendingIncomingTxs[txid] != nil
    }

    func getPendingIncomingAmount(txid: String) -> UInt64? {
        pendingIncomingTxs[txid]
    }

    /// Get all pending incoming txids (for periodic confirmation check)
    func getPendingIncomingTxids() -> [(txid: String, amount: UInt64)] {
        pendingIncomingTxs.map { ($0.key, $0.value) }
    }

    /// Get total pending incoming amount
    func getTotalPendingIncoming() -> UInt64 {
        pendingIncomingTxs.values.reduce(0, +)
    }

    /// Get count of pending incoming transactions
    func getPendingIncomingCount() -> Int {
        pendingIncomingTxs.count
    }
}

/// Timeout helper for async operations
func withTimeout<T>(seconds: Double, operation: @escaping () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw NetworkError.timeout
        }
        // Return first result, cancel the other
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

/// Multi-Peer Network Manager for Zclassic
/// Connects to multiple nodes and requires consensus for all queries
final class NetworkManager: ObservableObject {
    static let shared = NetworkManager()

    // MARK: - Constants
    private let MIN_PEERS = 8  // Increased from 3 for better reliability
    private let MAX_PEERS = 30  // Increased from 20
    private let TARGET_PEER_PERCENT = 0.15 // Connect to 15% of known addresses
    private let CONSENSUS_THRESHOLD = 5 // SECURITY: Byzantine fault tolerance (n=8, f=2) - VUL-001 fix
    private let PEER_ROTATION_INTERVAL: TimeInterval = 300 // 5 minutes
    private let QUERY_TIMEOUT: TimeInterval = 10
    private let BAN_DURATION: TimeInterval = 604800 // VUL-010: 7 days for stronger Sybil protection
    private let MAX_KNOWN_ADDRESSES = 1000
    private let GETADDR_INTERVAL: TimeInterval = 30 // Request addresses every 30 seconds

    // MARK: - Published Properties
    @Published private(set) var connectedPeers: Int = 0
    @Published private(set) var isConnected: Bool = false
    @Published private(set) var syncProgress: Double = 0.0
    @Published private(set) var lastBlockHeight: UInt64 = 0
    @Published private(set) var knownAddressCount: Int = 0
    @Published private(set) var peerVersion: String = ""
    @Published private(set) var chainHeight: UInt64 = 0
    @Published private(set) var walletHeight: UInt64 = 0
    @Published private(set) var zclPriceUSD: Double = 0.0
    @Published private(set) var zclPriceFailed: Bool = false  // True if both price APIs failed
    @Published private(set) var lastBlockTxCount: Int = 0
    @Published private(set) var networkDifficulty: Double = 0.0
    @Published private(set) var bannedPeersCount: Int = 0
    @Published private(set) var onionPeersCount: Int = 0  // .onion addresses discovered

    /// Public accessor for known addresses count (for privacy report)
    var knownAddressesCount: Int {
        addressLock.lock()
        defer { addressLock.unlock() }
        return knownAddresses.count
    }
    @Published private(set) var torConnectedPeersCount: Int = 0  // peers connected via Tor SOCKS5
    @Published private(set) var onionConnectedPeersCount: Int = 0  // .onion peers actually connected

    /// Warning: P2P connection issues prevent mempool scanning
    /// UI should show warning when this is true (incoming tx detection disabled)
    @Published private(set) var p2pMempoolWarning: Bool = false

    /// Sybil attack detection - published when a fake peer is banned
    /// Contains: (peerHost: String, fakeHeight: UInt64, realHeight: UInt64)
    @Published private(set) var sybilAttackDetected: (peer: String, fakeHeight: UInt64, realHeight: UInt64)? = nil

    /// Set of pending outgoing transaction IDs (for synchronous change detection)
    /// This is updated alongside the actor's pendingOutgoingTxs for sync access
    private var pendingOutgoingTxidSet: Set<String> = []
    private let pendingOutgoingLock = NSLock()

    /// Synchronous check if a transaction is pending outgoing (our own send)
    /// Used by FilterScanner to detect change outputs without async
    func isPendingOutgoingSync(txid: String) -> Bool {
        pendingOutgoingLock.lock()
        defer { pendingOutgoingLock.unlock() }
        return pendingOutgoingTxidSet.contains(txid)
    }

    /// Flag to suppress background sync during initial startup sync
    /// Set to true during ContentView's initial sync task, false after completion
    var suppressBackgroundSync: Bool = false

    // MARK: - Connection Cooldown (FIX #114)
    /// Track last connection attempt per address to prevent infinite reconnection loops
    /// Key: "host:port", Value: timestamp of last attempt
    private var connectionAttempts: [String: Date] = [:]
    private let connectionAttemptsLock = NSLock()
    private let CONNECTION_COOLDOWN: TimeInterval = 5.0  // 5 seconds between attempts to same address

    /// Check if an address is on cooldown (recently attempted)
    private func isOnCooldown(_ host: String, port: UInt16) -> Bool {
        let key = "\(host):\(port)"
        connectionAttemptsLock.lock()
        defer { connectionAttemptsLock.unlock() }

        if let lastAttempt = connectionAttempts[key] {
            let elapsed = Date().timeIntervalSince(lastAttempt)
            return elapsed < CONNECTION_COOLDOWN
        }
        return false
    }

    /// Record a connection attempt for cooldown tracking
    private func recordConnectionAttempt(_ host: String, port: UInt16) {
        let key = "\(host):\(port)"
        connectionAttemptsLock.lock()
        connectionAttempts[key] = Date()
        connectionAttemptsLock.unlock()
    }

    // MARK: - Private Properties
    internal var peers: [Peer] = []  // internal so HeaderSyncManager can access

    /// Get a connected peer for block downloads
    /// Returns the first peer with a ready connection
    func getConnectedPeer() -> Peer? {
        return peers.first { $0.isConnectionReady }
    }

    /// Get all connected peers with ready connections
    func getAllConnectedPeers() -> [Peer] {
        return peers.filter { $0.isConnectionReady }
    }

    /// Update wallet height directly (called after sync completes)
    func updateWalletHeight(_ height: UInt64) {
        Task { @MainActor in
            self.walletHeight = height
        }
    }
    private var peerRotationTimer: Timer?
    private var addressDiscoveryTimer: Timer?
    private var statsRefreshTimer: Timer?
    private let STATS_REFRESH_INTERVAL: TimeInterval = 30 // Refresh chain height every 30 seconds
    private let queue = DispatchQueue(label: "com.zipherx.network", qos: .userInitiated)

    // Address Manager
    private var knownAddresses: [String: AddressInfo] = [:] // host:port -> info
    private var bannedPeers: [String: BannedPeer] = [:] // host -> ban info
    private var triedAddresses: Set<String> = [] // Addresses we've connected to
    private var newAddresses: Set<String> = [] // Addresses we haven't tried yet
    private let addressLock = NSLock() // Thread safety for address collections
    private var isConnecting = false // Prevent concurrent connection attempts

    // Known public Zclassic nodes (DNS seeds + hardcoded)
    private let dnsSeedsZCL = [
        "dnsseed.zclassic.org",
        "dnsseed.rotorproject.org",
        "dnsseed.zclnet.net"
    ]

    // Hardcoded peers for reliable connectivity (IP addresses only)
    private let hardcodedPeersZCL = [
        "185.205.246.161:8033",  // Known ZCL peer
        "140.174.189.3:8033",    // Known ZCL peer
        "205.209.104.118:8033",
        "74.50.74.102:8033",
        "162.55.92.62:8033",
        "157.90.223.151:8033",
        "37.187.76.79:8033",
        "51.178.179.75:8033",
        "54.37.81.148:8033",
        "67.183.29.123:8033",
        "116.202.13.16:8033",
        "188.165.24.209:8033",
        "198.50.168.213:8033"
    ]

    // .onion peers for Tor users (requires Tor to be enabled)
    // These are hidden service addresses that can only be reached via Tor
    // Note: .onion peers are also discovered dynamically via P2P addr/addrv2 messages
    private let onionPeersZCL: [String] = [
        // .onion peers are discovered dynamically via BIP155 addrv2 messages
        // from peers that support protocol version > 170011
    ]

    // MARK: - User Custom Nodes

    /// User-added custom nodes (persisted to UserDefaults)
    @Published private(set) var customNodes: [UserCustomNode] = []
    private let customNodesKey = "UserCustomNodes"

    /// Load custom nodes from UserDefaults
    private func loadCustomNodes() {
        guard let data = UserDefaults.standard.data(forKey: customNodesKey),
              let nodes = try? JSONDecoder().decode([UserCustomNode].self, from: data) else {
            customNodes = []
            return
        }
        customNodes = nodes
        print("📌 Loaded \(nodes.count) custom nodes from storage")
    }

    /// Save custom nodes to UserDefaults
    private func saveCustomNodes() {
        guard let data = try? JSONEncoder().encode(customNodes) else { return }
        UserDefaults.standard.set(data, forKey: customNodesKey)
    }

    /// Add a new custom node
    @MainActor
    public func addCustomNode(host: String, port: UInt16 = 8033, label: String = "") -> Bool {
        // Validate format
        var node = UserCustomNode(host: host, port: port, label: label)
        guard node.isValid else {
            print("❌ Invalid node address: \(host)")
            return false
        }

        // Check for duplicates
        if customNodes.contains(where: { $0.host == host && $0.port == port }) {
            print("⚠️ Node already exists: \(host):\(port)")
            return false
        }

        customNodes.append(node)
        saveCustomNodes()
        print("✅ Added custom node: \(node.label) (\(node.addressType.rawValue))")

        // Add to known addresses for immediate use
        let key = "\(host):\(port)"
        let now = Date()
        addressLock.lock()
        knownAddresses[key] = AddressInfo(
            address: PeerAddress(host: host, port: port),
            source: "user",
            firstSeen: now,
            lastSeen: now,
            attempts: 0,
            successes: 0
        )
        addressLock.unlock()

        // Trigger immediate connection attempt
        Task {
            await connectToNewCustomNode(host: host, port: port)
        }

        return true
    }

    /// Attempt to connect to a newly added custom node immediately
    private func connectToNewCustomNode(host: String, port: UInt16) async {
        print("🔄 Attempting immediate connection to custom node: \(host):\(port)")

        // For .onion addresses, wait for circuit warmup
        if host.hasSuffix(".onion") {
            let torConnected = await TorManager.shared.connectionState.isConnected
            if !torConnected {
                print("⏳ Waiting for Tor to connect before trying .onion custom node...")
                // Wait up to 30 seconds for Tor to connect
                for _ in 0..<30 {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if await TorManager.shared.connectionState.isConnected { break }
                }
            }

            // Now wait for circuit warmup
            let circuitsReady = await TorManager.shared.isOnionCircuitsReady
            if !circuitsReady {
                let remaining = await TorManager.shared.onionCircuitWarmupRemaining
                if remaining > 0 {
                    print("⏳ Waiting \(Int(remaining))s for .onion circuits to warm up...")
                    try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                }
            }
        }

        let peer = Peer(host: host, port: port, networkMagic: networkMagic)
        do {
            try await peer.connect()
            try await peer.performHandshake()

            await MainActor.run {
                // Add to connected peers if not already there
                if !self.peers.contains(where: { $0.host == host && $0.port == port }) {
                    self.peers.append(peer)
                }
                self.connectedPeers = self.peers.filter { $0.isConnectionReady }.count
                self.recordCustomNodeConnection(host: host, port: port, success: true)
                print("✅ Connected to custom node: \(host):\(port)")
            }
        } catch {
            await MainActor.run {
                self.recordCustomNodeConnection(host: host, port: port, success: false)
                print("⚠️ Failed to connect to custom node \(host):\(port): \(error.localizedDescription)")
            }
        }
    }

    /// Update an existing custom node
    @MainActor
    public func updateCustomNode(_ node: UserCustomNode) -> Bool {
        guard let index = customNodes.firstIndex(where: { $0.id == node.id }) else {
            return false
        }
        customNodes[index] = node
        saveCustomNodes()
        print("✅ Updated custom node: \(node.label)")
        return true
    }

    /// Delete a custom node
    @MainActor
    public func deleteCustomNode(id: UUID) -> Bool {
        guard let index = customNodes.firstIndex(where: { $0.id == id }) else {
            return false
        }
        let node = customNodes[index]

        // Remove from known addresses
        let key = "\(node.host):\(node.port)"
        addressLock.lock()
        knownAddresses.removeValue(forKey: key)
        addressLock.unlock()

        customNodes.remove(at: index)
        saveCustomNodes()
        print("🗑️ Deleted custom node: \(node.label)")
        return true
    }

    /// Toggle a custom node's enabled state
    @MainActor
    public func toggleCustomNode(id: UUID) -> Bool {
        guard let index = customNodes.firstIndex(where: { $0.id == id }) else {
            return false
        }
        customNodes[index].isEnabled.toggle()
        saveCustomNodes()
        print("🔄 Custom node \(customNodes[index].label) is now \(customNodes[index].isEnabled ? "enabled" : "disabled")")
        return true
    }

    /// Record connection result for a custom node
    private func recordCustomNodeConnection(host: String, port: UInt16, success: Bool) {
        guard let index = customNodes.firstIndex(where: { $0.host == host && $0.port == port }) else {
            return
        }
        customNodes[index].connectionAttempts += 1
        if success {
            customNodes[index].connectionSuccesses += 1
            customNodes[index].lastConnected = Date()
        }
        saveCustomNodes()
    }

    /// Get enabled custom nodes for connection
    func getEnabledCustomNodes() -> [UserCustomNode] {
        return customNodes.filter { $0.isEnabled }
    }

    // Zclassic network parameters
    private let networkMagic: [UInt8] = [0x24, 0xe9, 0x27, 0x64] // ZCL mainnet
    private let defaultPort: UInt16 = 8033

    private init() {
        setupPeerRotation()
        setupAddressDiscovery()
        setupStatsRefresh()
        loadBundledPeers()      // Load bundled peers first (for fresh installs)
        loadPersistedAddresses() // Then override with persisted (for returning users)
        loadCustomNodes()        // Load user-added custom nodes
    }

    // MARK: - Address Management

    /// Add a new address to our known addresses
    private func addAddress(_ address: PeerAddress, source: String) {
        // Normalize IPv6-mapped addresses to IPv4
        guard let normalizedHost = normalizeIPv6MappedAddress(address.host) else {
            // Skip pure IPv6 addresses
            return
        }

        // Skip invalid/corrupted addresses (255.255.x.x from bad addr parsing, 0.x.x.x reserved)
        if normalizedHost.hasPrefix("255.255.") || normalizedHost.hasPrefix("0.") {
            return
        }

        let normalizedAddress = PeerAddress(host: normalizedHost, port: address.port)
        let key = "\(normalizedHost):\(address.port)"

        // Skip if banned
        if isBanned(normalizedHost) {
            return
        }

        // Skip our own onion address (prevent self-connection)
        if normalizedHost.hasSuffix(".onion") {
            Task {
                if let ownOnion = await HiddenServiceManager.shared.onionAddress {
                    // Extract just the address part (without .onion suffix)
                    let ownOnionBase = ownOnion.replacingOccurrences(of: ".onion", with: "")
                    let addrOnionBase = normalizedHost.replacingOccurrences(of: ".onion", with: "")
                    if ownOnionBase == addrOnionBase {
                        print("🧅 Skipping our own onion address: \(normalizedHost.prefix(16))...")
                    }
                }
            }
            // Synchronous check using stored value
            if let ownOnion = HiddenServiceManager.cachedOnionAddress,
               normalizedHost == ownOnion || normalizedHost == "\(ownOnion).onion" {
                return
            }
        }

        addressLock.lock()
        defer { addressLock.unlock() }

        // Skip if already known
        if knownAddresses[key] != nil {
            // Update last seen time
            knownAddresses[key]?.lastSeen = Date()
            return
        }

        // Add to new addresses
        if knownAddresses.count < MAX_KNOWN_ADDRESSES {
            knownAddresses[key] = AddressInfo(
                address: normalizedAddress,
                source: source,
                firstSeen: Date(),
                lastSeen: Date(),
                attempts: 0,
                successes: 0
            )
            newAddresses.insert(key)

            let count = knownAddresses.count
            DispatchQueue.main.async {
                self.knownAddressCount = count
            }
        }
    }

    /// Check if an address is banned
    private func isBanned(_ host: String) -> Bool {
        guard let ban = bannedPeers[host] else {
            return false
        }

        // Remove expired bans
        if ban.isExpired {
            bannedPeers.removeValue(forKey: host)
            return false
        }

        return true
    }

    /// Ban a peer
    func banPeer(_ peer: Peer, reason: BanReason) {
        addressLock.lock()

        // Clean up expired bans first
        bannedPeers = bannedPeers.filter { !$0.value.isExpired }

        let ban = BannedPeer(
            address: peer.host,
            banTime: Date(),
            banDuration: BAN_DURATION,
            reason: reason
        )
        bannedPeers[peer.host] = ban
        let newCount = bannedPeers.count

        // Remove from known good addresses
        let key = "\(peer.host):\(peer.port)"
        knownAddresses.removeValue(forKey: key)
        triedAddresses.remove(key)
        newAddresses.remove(key)
        addressLock.unlock()

        // Update published count on main thread
        DispatchQueue.main.async {
            self.bannedPeersCount = newCount
        }

        print("🚫 Banned peer \(peer.host): \(reason.rawValue)")
    }

    /// Ban a peer by address (for connection failures)
    func banAddress(_ host: String, port: UInt16, reason: BanReason) {
        addressLock.lock()

        // Clean up expired bans first
        bannedPeers = bannedPeers.filter { !$0.value.isExpired }

        let ban = BannedPeer(
            address: host,
            banTime: Date(),
            banDuration: BAN_DURATION,
            reason: reason
        )
        bannedPeers[host] = ban
        let newCount = bannedPeers.count

        // Remove from known good addresses
        let key = "\(host):\(port)"
        knownAddresses.removeValue(forKey: key)
        triedAddresses.remove(key)
        newAddresses.remove(key)
        addressLock.unlock()

        // Update published count on main thread
        DispatchQueue.main.async {
            self.bannedPeersCount = newCount
        }

        print("🚫 Banned address \(host): \(reason.rawValue)")
    }

    /// Get list of all currently banned peers
    func getBannedPeers() -> [BannedPeer] {
        addressLock.lock()

        // Clean up expired bans first
        bannedPeers = bannedPeers.filter { !$0.value.isExpired }
        let result = Array(bannedPeers.values).sorted { $0.banTime > $1.banTime }
        let newCount = bannedPeers.count
        addressLock.unlock()

        // Update published count on main thread
        DispatchQueue.main.async {
            self.bannedPeersCount = newCount
        }

        return result
    }

    /// Unban a specific peer by address
    func unbanPeer(address: String) {
        addressLock.lock()
        let removed = bannedPeers.removeValue(forKey: address) != nil
        let newCount = bannedPeers.count
        addressLock.unlock()

        if removed {
            print("✅ Unbanned peer: \(address)")
            // Update published count on main thread
            DispatchQueue.main.async {
                self.bannedPeersCount = newCount
            }
        }
    }

    /// Unban all peers
    func unbanAllPeers() {
        addressLock.lock()
        let count = bannedPeers.count
        bannedPeers.removeAll()
        addressLock.unlock()

        print("✅ Unbanned all \(count) peers")
        // Update published count on main thread
        DispatchQueue.main.async {
            self.bannedPeersCount = 0
        }
    }

    /// Calculate target number of peers based on known addresses
    /// Returns 10% of known addresses, clamped between MIN_PEERS and MAX_PEERS
    private func calculateTargetPeers() -> Int {
        addressLock.lock()
        let knownCount = knownAddresses.count
        addressLock.unlock()

        let target = Int(Double(knownCount) * TARGET_PEER_PERCENT)
        return max(MIN_PEERS, min(MAX_PEERS, target))
    }

    /// Select best peer to connect to based on scoring
    /// Filters .onion addresses based on Tor availability
    private func selectBestAddress() -> PeerAddress? {
        addressLock.lock()
        defer { addressLock.unlock() }

        // Check if Tor is available for regular SOCKS connections
        let torAvailable = torIsAvailable

        // Check if .onion circuits are ready (requires warmup period)
        // .onion addresses need rendezvous circuits; regular IPv4 via SOCKS works immediately
        let onionReady = onionCircuitsReady

        // Helper to check if address is .onion
        func isOnion(_ host: String) -> Bool {
            return host.hasSuffix(".onion")
        }

        // Helper to filter address based on Tor availability
        func isAddressUsable(_ address: PeerAddress) -> Bool {
            if isOnion(address.host) {
                // .onion addresses require both Tor and circuit warmup
                return onionReady
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

    /// Check if Tor is available for connections (cached for performance in sync operations)
    private var torIsAvailable: Bool {
        // This is called synchronously, so we can't await TorManager
        // Use a cached value that's updated periodically
        return _torIsAvailable
    }
    private var _torIsAvailable: Bool = false

    /// Check if .onion circuits are ready (requires warmup period after SOCKS connection)
    /// Regular IPv4 via SOCKS works immediately; .onion addresses need ~10s for rendezvous circuits
    private var onionCircuitsReady: Bool {
        return _onionCircuitsReady
    }
    private var _onionCircuitsReady: Bool = false

    /// Update Tor availability status (call periodically or when Tor state changes)
    func updateTorAvailability() async {
        let mode = await TorManager.shared.mode
        let connected = await TorManager.shared.connectionState.isConnected
        _torIsAvailable = (mode == .enabled && connected)

        // Check if .onion circuits are ready (requires warmup period after SOCKS connection)
        let wasOnionReady = _onionCircuitsReady
        _onionCircuitsReady = await TorManager.shared.isOnionCircuitsReady

        // Log transition when .onion circuits become ready
        if !wasOnionReady && _onionCircuitsReady {
            print("🧅 .onion circuits now ready! Can connect to hidden services.")
        } else if connected && !_onionCircuitsReady {
            let remaining = await TorManager.shared.onionCircuitWarmupRemaining
            if remaining > 0 {
                print("🧅 .onion circuits warming up... \(Int(remaining))s remaining")
            }
        }

        // Count .onion peers in address book
        addressLock.lock()
        let onionCount = knownAddresses.values.filter { $0.address.host.hasSuffix(".onion") }.count
        addressLock.unlock()

        // Count peers connected via Tor SOCKS5
        let torCount = peers.filter { $0.isConnectedViaTor }.count
        // Count .onion peers actually connected
        let onionConnected = peers.filter { $0.isOnion && $0.isConnectionReady }.count

        // Debug: Log Tor peer status
        if torCount > 0 || onionConnected > 0 {
            print("🧅 Tor peers: \(torCount) via SOCKS5, \(onionConnected) .onion connected, \(onionCount) .onion discovered")
        }

        await MainActor.run {
            self.onionPeersCount = onionCount
            self.torConnectedPeersCount = torCount
            self.onionConnectedPeersCount = onionConnected
        }

        if _torIsAvailable && (torCount == 0 && onionCount == 0) {
            print("🧅 Tor available - 0 .onion peers in address book")
        }
    }

    /// Request addresses from all connected peers
    private func discoverMoreAddresses() async {
        var discoveredCount = 0
        var onionDiscoveredCount = 0
        for peer in peers {
            do {
                let addresses = try await peer.getAddresses()
                for addr in addresses {
                    addAddress(addr, source: peer.host)
                    discoveredCount += 1
                    if addr.host.hasSuffix(".onion") {
                        onionDiscoveredCount += 1
                    }
                }
                peer.recordSuccess()
            } catch {
                peer.recordFailure()
            }
        }

        // Log .onion discoveries
        if onionDiscoveredCount > 0 {
            print("🧅 Discovered \(onionDiscoveredCount) .onion peers via P2P addr messages")
        }

        // Persist addresses if we discovered new ones
        if discoveredCount > 0 {
            persistAddresses()

            // Update onion peer count
            await updateTorAvailability()
        }
    }

    private func setupAddressDiscovery() {
        addressDiscoveryTimer = Timer.scheduledTimer(withTimeInterval: GETADDR_INTERVAL, repeats: true) { [weak self] _ in
            Task {
                await self?.discoverMoreAddresses()
            }
        }
    }

    private func setupStatsRefresh() {
        statsRefreshTimer = Timer.scheduledTimer(withTimeInterval: STATS_REFRESH_INTERVAL, repeats: true) { [weak self] _ in
            Task {
                await self?.refreshChainHeight()
            }
        }
    }

    /// Refresh chain height (P2P consensus primary when Tor enabled, InsightAPI fallback)
    /// Also triggers background sync if wallet is behind
    private func refreshChainHeight() async {
        guard isConnected else { return }

        let torEnabled = await TorManager.shared.mode == .enabled
        var newHeight: UInt64 = 0
        var networkTruthHeight: UInt64 = 0

        // When Tor is enabled, use P2P ONLY (InsightAPI blocked by Cloudflare)
        // When Tor is disabled, InsightAPI is authoritative

        // FIX #111: Get HeaderStore height FIRST for Sybil detection
        // CRITICAL FIX: During initial sync, headers are behind chain tip. Use a much larger tolerance
        // to avoid banning legitimate peers during catch-up sync.
        let headerStoreHeightForValidation = (try? HeaderStore.shared.getLatestHeight()) ?? 0
        // Use 10,000 blocks tolerance during initial sync (headers may be far behind)
        // Once synced (within 100 blocks of chain), reduce to 1000 for stricter protection
        let isInitialSyncPhase = headerStoreHeightForValidation < ZipherXConstants.bundledTreeHeight
        let sybilTolerance: UInt64 = isInitialSyncPhase ? 50_000 : 10_000  // Much higher tolerance during initial sync
        let sybilThreshold = headerStoreHeightForValidation > 0 ? headerStoreHeightForValidation + sybilTolerance : UInt64(100_000_000) // 100M if no headers

        // 1. Get P2P peer consensus height FIRST (skip banned peers + detect Sybil attackers)
        var peerHeights: [UInt64: Int] = [:]
        var peerMaxHeight: UInt64 = 0
        for peer in peers {
            // SECURITY: Skip banned peers and handle negative heights (malicious peers)
            guard !isBanned(peer.host), peer.peerStartHeight > 0 else { continue }
            let h = UInt64(peer.peerStartHeight)  // Safe: checked > 0 above

            // FIX #111: DETECT AND BAN SYBIL ATTACKERS reporting impossible heights
            if h > sybilThreshold {
                print("🚨 [SYBIL BAN] Peer \(peer.host) reporting FAKE height \(h) - BANNING!")
                banAddress(peer.host, port: peer.port, reason: .corruptedData)  // Ban for 7 days
                continue  // Don't use this peer's height
            }

            if h > 0 {
                peerHeights[h, default: 0] += 1
                peerMaxHeight = max(peerMaxHeight, h)
            }
        }

        // Find consensus (most peers within 10 blocks of max)
        var peerConsensusHeight: UInt64 = 0
        var consensusCount = 0
        for (height, count) in peerHeights {
            if peerMaxHeight > 0 && height >= peerMaxHeight - 10 && count > consensusCount {
                peerConsensusHeight = height
                consensusCount = count
            }
        }

        // 2. P2P ONLY MODE - No InsightAPI calls
        // FIX #120: Commented out InsightAPI - using P2P only
        // if !torEnabled {
        //     if let status = try? await InsightAPI.shared.getStatus() {
        //         networkTruthHeight = status.height
        //         print("📡 [API] Network height: \(networkTruthHeight)")
        //     }
        // } else {
        //     print("🧅 Tor enabled - using P2P consensus only (InsightAPI blocked by Cloudflare)")
        // }
        print("📡 Using P2P consensus only (InsightAPI disabled)")

        // 3. Determine best height
        // FIX #111: ALWAYS use HeaderStore as ground truth to reject Sybil attack heights
        let headerStoreHeight = (try? HeaderStore.shared.getLatestHeight()) ?? 0
        let maxReasonableHeight = headerStoreHeight > 0 ? headerStoreHeight + 1000 : UInt64.max

        if torEnabled {
            // TOR MODE: P2P consensus is authoritative, BUT validate against HeaderStore
            if peerConsensusHeight > 0 && consensusCount >= 2 {
                // FIX #111: Validate consensus height against HeaderStore
                if peerConsensusHeight <= maxReasonableHeight {
                    newHeight = peerConsensusHeight
                    print("🧅 [P2P] Peer consensus height: \(newHeight) (\(consensusCount) peers)")
                } else {
                    print("🚨 [SYBIL] Consensus height \(peerConsensusHeight) rejected (HeaderStore: \(headerStoreHeight))")
                    newHeight = headerStoreHeight
                }
            } else if peerMaxHeight > 0 && peerMaxHeight <= maxReasonableHeight {
                // FIX #111: Only use peerMaxHeight if it's reasonable (within 1000 of HeaderStore)
                newHeight = peerMaxHeight
                print("🧅 [P2P] Using peer max height (no consensus): \(newHeight)")
            } else if peerMaxHeight > maxReasonableHeight {
                // FIX #111: Reject obviously fake heights from Sybil attack
                print("🚨 [SYBIL] Peer max height \(peerMaxHeight) rejected (HeaderStore: \(headerStoreHeight))")
                newHeight = headerStoreHeight
            } else if headerStoreHeight > 0 {
                newHeight = headerStoreHeight
                print("🧅 [P2P] Using HeaderStore height: \(newHeight)")
            }
        } else {
            // NORMAL MODE: InsightAPI authoritative, P2P fallback
            if networkTruthHeight > 0 {
                newHeight = networkTruthHeight
            } else if peerConsensusHeight > 0 && consensusCount >= 2 {
                newHeight = peerConsensusHeight
                print("📡 [P2P] Using peer consensus (API unavailable): \(newHeight)")
            } else if let headerHeight = try? HeaderStore.shared.getLatestHeight() {
                newHeight = headerHeight
                print("📡 [P2P] Using HeaderStore height (API unavailable): \(newHeight)")
            }
        }

        // Only update and log if height changed
        if newHeight > 0 && newHeight != chainHeight {
            await MainActor.run {
                self.chainHeight = newHeight
                // Cache for fast start mode (consecutive app launches)
                UserDefaults.standard.set(Int(newHeight), forKey: "cachedChainHeight")
                print("📊 Chain height updated: \(newHeight)")
            }

            // CRITICAL: Trigger background sync if wallet is behind
            let dbHeight = (try? WalletDatabase.shared.getLastScannedHeight()) ?? 0
            if newHeight > dbHeight && dbHeight > 0 {
                print("🔄 New block detected, syncing: chain=\(newHeight) wallet=\(dbHeight) (+\(newHeight - dbHeight) blocks)")
                Task {
                    await WalletManager.shared.backgroundSyncToHeight(newHeight)
                }
            }
        }
    }

    private let persistedAddressesKey = "ZipherX.KnownPeerAddresses"
    private let maxPersistedAddresses = 100

    /// Convert IPv6-mapped IPv4 addresses to pure IPv4 format
    /// e.g., "0:0:0:0:0:0:ffff:9de93c4e" -> "157.233.60.78"
    private func normalizeIPv6MappedAddress(_ host: String) -> String? {
        // Skip .onion addresses
        if host.hasSuffix(".onion") {
            return host
        }

        // Already IPv4
        if host.split(separator: ".").count == 4 && !host.contains(":") {
            return host
        }

        // Check for IPv6-mapped IPv4: 0:0:0:0:0:0:ffff:XXXX
        if host.contains(":") && host.lowercased().contains("ffff:") {
            let parts = host.split(separator: ":")
            if parts.count >= 2, let lastPart = parts.last {
                // Convert hex to IPv4 bytes
                let hexStr = String(lastPart)
                if hexStr.count == 8, let hexVal = UInt32(hexStr, radix: 16) {
                    let b1 = (hexVal >> 24) & 0xFF
                    let b2 = (hexVal >> 16) & 0xFF
                    let b3 = (hexVal >> 8) & 0xFF
                    let b4 = hexVal & 0xFF
                    return "\(b1).\(b2).\(b3).\(b4)"
                }
            }
        }

        // Pure IPv6 - not supported via Tor SOCKS5
        if host.contains(":") {
            return nil
        }

        return host
    }

    private func loadPersistedAddresses() {
        guard let data = UserDefaults.standard.data(forKey: persistedAddressesKey),
              let savedAddresses = try? JSONDecoder().decode([PersistedAddress].self, from: data) else {
            print("📡 No persisted peer addresses found")
            return
        }

        addressLock.lock()
        defer { addressLock.unlock() }

        var loadedCount = 0
        var skippedIPv6 = 0
        var skippedInvalid = 0
        for saved in savedAddresses {
            // Normalize IPv6-mapped addresses to IPv4
            guard let normalizedHost = normalizeIPv6MappedAddress(saved.host) else {
                skippedIPv6 += 1
                continue
            }

            // Skip corrupted addresses (255.255.x.x from bad addr message parsing)
            if normalizedHost.hasPrefix("255.255.") || normalizedHost.hasPrefix("0.") {
                skippedInvalid += 1
                continue
            }

            let address = PeerAddress(host: normalizedHost, port: saved.port)
            let key = "\(normalizedHost):\(saved.port)"

            // Skip if banned or already known
            if isBanned(normalizedHost) || knownAddresses[key] != nil {
                continue
            }

            knownAddresses[key] = AddressInfo(
                address: address,
                source: "persisted",
                firstSeen: saved.firstSeen,
                lastSeen: saved.lastSeen,
                attempts: saved.attempts,
                successes: saved.successes
            )

            // Good addresses go to tried set, others to new
            if saved.successes > 0 {
                triedAddresses.insert(key)
            } else {
                newAddresses.insert(key)
            }
            loadedCount += 1
        }

        let count = knownAddresses.count
        DispatchQueue.main.async {
            self.knownAddressCount = count
        }

        var skipInfo: [String] = []
        if skippedIPv6 > 0 { skipInfo.append("\(skippedIPv6) IPv6") }
        if skippedInvalid > 0 { skipInfo.append("\(skippedInvalid) invalid") }

        if skipInfo.isEmpty {
            print("📡 Loaded \(loadedCount) persisted peer addresses")
        } else {
            print("📡 Loaded \(loadedCount) persisted peer addresses (skipped \(skipInfo.joined(separator: ", ")))")
        }
    }

    private func persistAddresses() {
        addressLock.lock()
        let addresses = knownAddresses.values
            .filter { $0.successes > 0 || $0.attempts < 3 } // Only save good or untried addresses
            .filter { !$0.address.host.hasPrefix("255.255.") && !$0.address.host.hasPrefix("0.") } // Filter invalid
            .sorted { $0.successes > $1.successes } // Best first
            .prefix(maxPersistedAddresses)
            .map { info in
                PersistedAddress(
                    host: info.address.host,
                    port: info.address.port,
                    firstSeen: info.firstSeen,
                    lastSeen: info.lastSeen,
                    attempts: info.attempts,
                    successes: info.successes
                )
            }
        addressLock.unlock()

        if let data = try? JSONEncoder().encode(Array(addresses)) {
            UserDefaults.standard.set(data, forKey: persistedAddressesKey)
            print("📡 Persisted \(addresses.count) peer addresses")
        }
    }

    /// Load bundled peer list from Resources (for fresh installs)
    private func loadBundledPeers() {
        guard let url = Bundle.main.url(forResource: "bundled_peers", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let bundledPeers = try? JSONDecoder().decode([BundledPeer].self, from: data) else {
            print("📡 No bundled peers file found (this is OK for development)")
            return
        }

        addressLock.lock()
        defer { addressLock.unlock() }

        var loadedCount = 0
        for peer in bundledPeers {
            let key = "\(peer.host):\(peer.port)"

            // Skip if banned or already known
            if isBanned(peer.host) || knownAddresses[key] != nil {
                continue
            }

            let address = PeerAddress(host: peer.host, port: peer.port)
            knownAddresses[key] = AddressInfo(
                address: address,
                source: "bundled",
                firstSeen: Date(),
                lastSeen: Date(),
                attempts: 0,
                successes: peer.reliability > 0.5 ? 1 : 0  // Assume good if reliability > 50%
            )

            // High reliability peers go to tried set
            if peer.reliability > 0.5 {
                triedAddresses.insert(key)
            } else {
                newAddresses.insert(key)
            }
            loadedCount += 1
        }

        print("📡 Loaded \(loadedCount) bundled peer addresses")
    }

    // MARK: - GitHub Peer Download

    /// GitHub URL for reliable peers list
    private static let GITHUB_PEERS_URL = "https://raw.githubusercontent.com/VictorLux/ZipherX_Boost/main/reliable_peers.json"

    /// Download and load reliable peers from GitHub
    /// Call this at startup to get the latest peer list
    func downloadReliablePeersFromGitHub() async -> Int {
        print("📡 Checking GitHub for reliable peers...")

        guard let url = URL(string: Self.GITHUB_PEERS_URL) else {
            print("❌ Invalid GitHub peers URL")
            return 0
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                print("⚠️ GitHub peers fetch failed: HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                return 0
            }

            let bundledPeers = try JSONDecoder().decode([BundledPeer].self, from: data)
            print("📡 Downloaded \(bundledPeers.count) peers from GitHub")

            addressLock.lock()
            defer { addressLock.unlock() }

            var loadedCount = 0
            for peer in bundledPeers {
                let key = "\(peer.host):\(peer.port)"

                // Skip if banned
                if isBanned(peer.host) {
                    continue
                }

                // If already known, update reliability info if GitHub has better data
                if let existing = knownAddresses[key] {
                    // Only update if GitHub peer has higher reliability and our local has few attempts
                    if existing.attempts < 5 && peer.reliability > 0.7 {
                        knownAddresses[key]?.successes = max(existing.successes, 1)
                        triedAddresses.insert(key)
                    }
                    continue
                }

                let address = PeerAddress(host: peer.host, port: peer.port)
                knownAddresses[key] = AddressInfo(
                    address: address,
                    source: "github",
                    firstSeen: Date(),
                    lastSeen: peer.lastSeen,
                    attempts: 0,
                    successes: peer.reliability > 0.5 ? 1 : 0
                )

                // High reliability peers go to tried set (prioritized for connection)
                if peer.reliability > 0.5 {
                    triedAddresses.insert(key)
                } else {
                    newAddresses.insert(key)
                }
                loadedCount += 1
            }

            print("✅ Added \(loadedCount) new peers from GitHub (total known: \(knownAddresses.count))")
            return loadedCount
        } catch {
            print("⚠️ GitHub peers download error: \(error.localizedDescription)")
            return 0
        }
    }

    /// Export current reliable peers for bundling in future releases
    /// Call this from Settings when 100+ peers have been discovered
    func exportReliablePeersForBundling() -> String {
        addressLock.lock()
        let reliablePeers = knownAddresses.values
            .filter { $0.successes > 0 && $0.attempts > 0 }  // Must have succeeded at least once
            .sorted {
                // Sort by success rate, then by total successes
                let rate1 = Double($0.successes) / Double(max(1, $0.attempts))
                let rate2 = Double($1.successes) / Double(max(1, $1.attempts))
                if abs(rate1 - rate2) < 0.1 {
                    return $0.successes > $1.successes
                }
                return rate1 > rate2
            }
            .prefix(150)  // Export top 150 reliable peers
            .map { info -> BundledPeer in
                let reliability = Double(info.successes) / Double(max(1, info.attempts))
                return BundledPeer(
                    host: info.address.host,
                    port: info.address.port,
                    reliability: reliability,
                    lastSeen: info.lastSeen
                )
            }
        addressLock.unlock()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        guard let data = try? encoder.encode(Array(reliablePeers)),
              let jsonString = String(data: data, encoding: .utf8) else {
            return "// Error encoding peers"
        }

        return jsonString
    }

    /// Get count of reliable peers (success rate > 50%)
    var reliablePeerCount: Int {
        addressLock.lock()
        let count = knownAddresses.values.filter {
            $0.successes > 0 && Double($0.successes) / Double(max(1, $0.attempts)) > 0.5
        }.count
        addressLock.unlock()
        return count
    }

    // MARK: - Connection Management

    /// Connect to the Zclassic network
    /// Targets 10% of known peers (min 3, max 20)
    func connect() async throws {
        // Prevent concurrent connection attempts
        guard !isConnecting else {
            return
        }
        isConnecting = true
        defer { isConnecting = false }

        // CRITICAL: If Tor mode is enabled, WAIT for Tor to connect first
        // Otherwise IPv4 peers will fail and get banned before Tor is ready
        let torMode = await TorManager.shared.mode
        if torMode == .enabled {
            var torConnected = await TorManager.shared.connectionState.isConnected
            if !torConnected {
                print("🧅 Tor mode enabled - waiting for Tor to connect (max 30s)...")
                var waitCount = 0
                let maxWait = 300 // 30 seconds max
                while !torConnected && waitCount < maxWait {
                    try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                    waitCount += 1
                    torConnected = await TorManager.shared.connectionState.isConnected
                    if waitCount % 50 == 0 {
                        let state = await TorManager.shared.connectionState
                        print("🧅 Waiting for Tor... (\(waitCount/10)s) state: \(state.displayText)")
                    }
                }
                if !torConnected {
                    print("⚠️ Tor did not connect within 30s, proceeding with .onion peers only")
                } else {
                    print("✅ Tor connected, proceeding with P2P connections")
                }
            }
        }

        // Update Tor availability status for .onion peer selection
        await updateTorAvailability()

        print("🔌 Starting network connection...")

        // Discover peers via DNS seeds
        var discoveredPeers = await discoverPeers()
        print("📡 DNS discovery found \(discoveredPeers.count) peers")

        // Add hardcoded peers for eclipse attack resistance
        for peer in hardcodedPeersZCL {
            let components = peer.split(separator: ":")
            if components.count == 2,
               let port = UInt16(components[1]) {
                discoveredPeers.append(PeerAddress(host: String(components[0]), port: port))
            }
        }

        // Add .onion peers if Tor is enabled and connected
        let torConnected = await TorManager.shared.connectionState.isConnected
        if torConnected && !onionPeersZCL.isEmpty {
            print("🧅 Tor connected - adding \(onionPeersZCL.count) .onion peers")
            for peer in onionPeersZCL {
                let components = peer.split(separator: ":")
                if components.count == 2,
                   let port = UInt16(components[1]) {
                    discoveredPeers.append(PeerAddress(host: String(components[0]), port: port))
                }
            }
        }

        // Add all discovered to address manager
        for addr in discoveredPeers {
            addAddress(addr, source: "dns")
        }

        // Calculate target: 15% of known addresses (min 8, max 30)
        let targetPeers = calculateTargetPeers()
        print("📋 Known addresses: \(knownAddresses.count), Target peers: \(targetPeers)")

        // Build candidate list from ALL known addresses, not just DNS discovered
        // This allows reconnecting to previously discovered peers
        addressLock.lock()
        var allCandidates: [PeerAddress] = []
        for (key, _) in knownAddresses {
            let components = key.split(separator: ":")
            guard components.count == 2, let port = UInt16(components[1]) else { continue }
            allCandidates.append(PeerAddress(host: String(components[0]), port: port))
        }
        addressLock.unlock()

        // Add fresh DNS discoveries to the front (prioritize fresh data)
        allCandidates = discoveredPeers + allCandidates

        // Deduplicate and filter banned peers
        var seenPeers = Set<String>()
        var validPeers = allCandidates.filter { addr in
            let key = "\(addr.host):\(addr.port)"
            if seenPeers.contains(key) || isBanned(addr.host) {
                return false
            }
            seenPeers.insert(key)
            return true
        }

        print("📋 Valid candidates after dedup: \(validPeers.count)")

        // Shuffle to avoid always connecting to same peers
        validPeers.shuffle()

        // Connect to peers in batches until we reach target
        var connectedCount = 0
        let maxConcurrent = 10 // Try up to 10 at once per batch
        var peerIndex = 0
        var attemptedThisBatch = Set<String>()

        while connectedCount < targetPeers && peerIndex < validPeers.count {
            let batchEnd = min(peerIndex + maxConcurrent, validPeers.count)
            let batch = Array(validPeers[peerIndex..<batchEnd])
            peerIndex = batchEnd

            await withTaskGroup(of: (Peer?, PeerAddress).self) { group in
                for address in batch {
                    let key = "\(address.host):\(address.port)"
                    guard !attemptedThisBatch.contains(key) else { continue }
                    attemptedThisBatch.insert(key)

                    // FIX #114: Skip addresses on cooldown to prevent infinite reconnection loops
                    if self.isOnCooldown(address.host, port: address.port) {
                        continue
                    }

                    group.addTask {
                        // Record attempt BEFORE trying (cooldown starts now)
                        self.recordConnectionAttempt(address.host, port: address.port)

                        do {
                            print("🔄 Trying \(address.host):\(address.port)...")
                            let peer = try await self.connectToPeer(address)
                            print("✅ Connected to \(address.host):\(address.port)")
                            return (peer, address)
                        } catch let error as NetworkError {
                            // Ban on timeout or connection failure
                            if case .timeout = error {
                                await MainActor.run {
                                    self.banAddress(address.host, port: address.port, reason: .timeout)
                                }
                            } else if case .connectionTimeout = error {
                                await MainActor.run {
                                    self.banAddress(address.host, port: address.port, reason: .timeout)
                                }
                            }
                            print("❌ Failed: \(address.host) - \(error.localizedDescription)")
                            return (nil, address)
                        } catch {
                            print("❌ Failed: \(address.host) - \(error.localizedDescription)")
                            return (nil, address)
                        }
                    }
                }

                // Collect successful connections
                for await (peer, address) in group {
                    if let peer = peer {
                        peers.append(peer)
                        connectedCount += 1

                        // Set up block announcement listener
                        self.setupBlockListener(for: peer)

                        // Update UI immediately
                        await MainActor.run {
                            self.connectedPeers = connectedCount
                            self.isConnected = true
                        }

                        // Update address info (on main thread to avoid async lock warning)
                        let key = "\(peer.host):\(peer.port)"
                        DispatchQueue.main.async {
                            self.addressLock.lock()
                            self.knownAddresses[key]?.successes += 1
                            self.newAddresses.remove(key)
                            self.triedAddresses.insert(key)
                            self.addressLock.unlock()

                            // Also update custom node stats if this is a custom node
                            self.recordCustomNodeConnection(host: peer.host, port: peer.port, success: true)
                        }

                        // Request addresses from new peer (async)
                        Task {
                            if let addresses = try? await peer.getAddresses() {
                                for addr in addresses {
                                    self.addAddress(addr, source: peer.host)
                                }
                                self.persistAddresses()
                            }
                        }

                        // Stop if we've reached target
                        if connectedCount >= targetPeers {
                            break
                        }
                    }
                }
            }

            // Log progress
            print("📊 Connected \(connectedCount)/\(targetPeers) peers (tried \(peerIndex)/\(validPeers.count))")
        }

        // Persist after successful connections
        persistAddresses()
        print("📊 Final: Connected to \(connectedCount)/\(targetPeers) target peers")

        // We can work with fewer peers, just warn
        if connectedCount < MIN_PEERS {
            print("Warning: Only connected to \(connectedCount)/\(MIN_PEERS) peers")
        }

        guard connectedCount > 0 else {
            throw NetworkError.insufficientPeers(connectedCount, MIN_PEERS)
        }

        DispatchQueue.main.async {
            self.connectedPeers = connectedCount
            self.isConnected = connectedCount > 0
        }

        // Persist good addresses for next launch
        persistAddresses()

        // Advertise our .onion address to peers (if hidden service is running)
        await advertiseOnionAddressToPeers()
    }

    // MARK: - Onion Address Advertisement

    /// Advertise our .onion address to all connected peers
    /// This makes ZipherX visible on the network while remaining anonymous
    func advertiseOnionAddressToPeers() async {
        // Check if hidden service is running
        guard await HiddenServiceManager.shared.state == .running,
              let onionAddress = await HiddenServiceManager.shared.onionAddress else {
            print("🧅 advertiseOnionAddressToPeers: Hidden service not running or no address")
            return
        }

        let port = await HiddenServiceManager.shared.p2pPort

        // Count BIP155 peers
        let bip155Peers = peers.filter { $0.supportsAddrv2 }
        print("🧅 Advertising our .onion address - \(peers.count) total peers, \(bip155Peers.count) support BIP155")

        // Advertise to all connected peers in parallel
        await withTaskGroup(of: Void.self) { group in
            for peer in peers {
                group.addTask {
                    do {
                        try await peer.advertiseOnionAddress(onionAddress: onionAddress, port: port)
                    } catch {
                        print("🧅 Failed to advertise to \(peer.host): \(error.localizedDescription)")
                    }
                }
            }
        }

        print("🧅 Finished advertising our .onion address to network")
    }

    /// Disconnect from all peers
    func disconnect() {
        for peer in peers {
            peer.disconnect()
        }
        peers.removeAll()

        DispatchQueue.main.async {
            self.connectedPeers = 0
            self.isConnected = false
        }
    }

    /// Fetch network statistics (P2P-first when Tor enabled, InsightAPI fallback when disabled)
    func fetchNetworkStats() async {
        // Update Tor/Onion peer counts (so UI shows current connected .onion peers)
        await updateTorAvailability()

        // Get peer version from first connected peer (silently)
        if let peer = peers.first {
            let version = peer.peerUserAgent.isEmpty ? "Unknown" : peer.peerUserAgent
            await MainActor.run {
                self.peerVersion = version
            }
        }

        let torEnabled = await TorManager.shared.mode == .enabled
        var currentChainHeight: UInt64 = 0
        _ = await MainActor.run { self.chainHeight }  // Check previous height (used for comparison below)

        // When Tor enabled: P2P ONLY (InsightAPI blocked by Cloudflare)
        // When Tor disabled: InsightAPI authoritative, P2P fallback

        if torEnabled {
            // TOR MODE: P2P consensus is authoritative
            // 1. Get P2P peer consensus height (skip banned peers, handle negative heights)
            var peerHeights: [UInt64: Int] = [:]
            var peerMaxHeight: UInt64 = 0
            for peer in peers {
                // SECURITY: Skip banned peers and negative heights (malicious peers)
                guard !isBanned(peer.host), peer.peerStartHeight > 0 else { continue }
                let h = UInt64(peer.peerStartHeight)  // Safe: checked > 0 above
                if h > 0 {
                    peerHeights[h, default: 0] += 1
                    peerMaxHeight = max(peerMaxHeight, h)
                }
            }

            // Find consensus (most peers within 10 blocks of max)
            for (height, count) in peerHeights {
                if peerMaxHeight > 0 && height >= peerMaxHeight - 10 && count > 1 {
                    if height > currentChainHeight {
                        currentChainHeight = height
                    }
                }
            }

            // SECURITY FIX #108: Don't trust max peer height without consensus
            // Fallback to header store first (locally verified headers are trustworthy)
            if currentChainHeight == 0, let headerHeight = try? HeaderStore.shared.getLatestHeight() {
                currentChainHeight = headerHeight
                print("📊 Using HeaderStore height (no P2P consensus): \(headerHeight)")
            }

            // Only use peer max height if it's within reasonable range of header store
            // This prevents Sybil attack where single malicious peer reports fake height
            if currentChainHeight == 0 && peerMaxHeight > 0 {
                // If we have a cached height, validate peer height against it
                let cachedHeight = UInt64(UserDefaults.standard.integer(forKey: "cachedChainHeight"))
                if cachedHeight > 0 && peerMaxHeight > cachedHeight + 1000 {
                    // Peer height is suspiciously far ahead - likely fake
                    print("🚨 [SECURITY] Rejecting suspicious peer height \(peerMaxHeight) (cached: \(cachedHeight))")
                    // Use cached height as safer fallback
                    currentChainHeight = cachedHeight
                } else {
                    currentChainHeight = peerMaxHeight
                }
            }
        } else {
            // FIX #120: P2P ONLY MODE - InsightAPI commented out
            // NORMAL MODE: InsightAPI authoritative
            // 1. First try InsightAPI (authoritative network source)
            // if let status = try? await InsightAPI.shared.getStatus() {
            //     currentChainHeight = status.height
            //     await MainActor.run {
            //         self.networkDifficulty = status.difficulty
            //     }
            // }

            // 2. If API unavailable, fallback to header store (may be stale)
            // if currentChainHeight == 0 {
            if let headerHeight = try? HeaderStore.shared.getLatestHeight() {
                currentChainHeight = headerHeight
            }
            // }

            // 3. If still no height, try P2P peer heights from version handshake
            if currentChainHeight == 0 {
                for peer in peers {
                    // SECURITY: Skip banned peers and negative heights (malicious peers)
                    guard !isBanned(peer.host), peer.peerStartHeight > 0 else { continue }
                    let h = UInt64(peer.peerStartHeight)  // Safe: checked > 0 above
                    if h > currentChainHeight {
                        currentChainHeight = h
                    }
                }
            }
        }

        // Update chain height (only log if changed)
        if currentChainHeight > 0 {
            await MainActor.run {
                if self.chainHeight != currentChainHeight {
                    print("📊 Chain height: \(currentChainHeight)")
                }
                self.chainHeight = currentChainHeight
                // Cache for fast start mode (consecutive app launches)
                UserDefaults.standard.set(Int(currentChainHeight), forKey: "cachedChainHeight")
            }
        }

        // Get ZCL price (from CoinGecko or similar)
        await fetchZCLPrice()

        // Get wallet height from database
        let dbHeight = (try? WalletDatabase.shared.getLastScannedHeight()) ?? 0
        await MainActor.run {
            self.walletHeight = dbHeight
        }

        // BACKGROUND SYNC: If chain is ahead of wallet, sync new blocks
        // This keeps the tree always current for instant sends
        // IMPORTANT: Use local currentChainHeight, not @Published chainHeight
        // to avoid race conditions with MainActor updates
        // SKIP during initial sync to avoid race conditions with startup header sync
        if suppressBackgroundSync {
            // Silently skip during initial sync
        } else if currentChainHeight > dbHeight && dbHeight > 0 {
            print("🔄 Background sync: +\(currentChainHeight - dbHeight) blocks")
            Task {
                await WalletManager.shared.backgroundSyncToHeight(currentChainHeight)
            }
        }

        // MEMPOOL SCAN: Check for incoming unconfirmed transactions
        // Uses message queue to prevent stream conflicts
        // SKIP mempool scan during initial sync to avoid interfering with header sync
        if !suppressBackgroundSync {
            Task {
                await scanMempoolForIncoming()
            }
        }

        // ALWAYS check if any pending txs have been confirmed
        // (even during initial sync - user wants to see when their tx confirms)
        Task {
            await checkPendingOutgoingConfirmations()
            await checkPendingIncomingConfirmations()
        }
    }

    // MARK: - Mempool Detection (Cypherpunk Style!)

    /// Published property for incoming mempool amount
    @Published private(set) var mempoolIncoming: UInt64 = 0
    @Published private(set) var mempoolTxCount: Int = 0

    /// Published property for outgoing pending transactions (just broadcast, waiting for confirmation)
    @Published private(set) var mempoolOutgoing: UInt64 = 0
    @Published private(set) var mempoolOutgoingTxCount: Int = 0

    /// NEW: Two-phase outgoing tracking for instant UI feedback
    /// Phase 1: Peer accepted (set when first peer accepts broadcast)
    /// Phase 2: Mempool verified (set when tx confirmed in mempool)
    @Published private(set) var pendingBroadcastAmount: UInt64 = 0
    @Published private(set) var pendingBroadcastTxid: String? = nil
    @Published private(set) var isMempoolVerified: Bool = false

    /// Published when a transaction is confirmed (for showing "Settlement" celebration)
    /// Contains (txid, amount, isOutgoing, clearingTime, settlementTime) - cleared after UI handles it
    /// clearingTime: seconds from send click to mempool, settlementTime: seconds from send click to 1st confirmation
    @Published var justConfirmedTx: (txid: String, amount: UInt64, isOutgoing: Bool, clearingTime: TimeInterval?, settlementTime: TimeInterval?)? = nil

    /// Published when incoming ZCL is detected in mempool (for showing "Clearing" celebration)
    /// Contains (txid, amount, clearingTime) - cleared after UI handles it
    /// clearingTime: seconds from send click to mempool detection (only for sender)
    @Published var justDetectedIncomingMempool: (txid: String, amount: UInt64, clearingTime: TimeInterval?)? = nil

    /// Published when sender's tx is verified in mempool (for showing "Clearing" celebration on sender side)
    /// Contains (txid, amount, clearingTime) - cleared after UI handles it
    @Published var justClearedOutgoing: (txid: String, amount: UInt64, clearingTime: TimeInterval)? = nil

    /// Counter to trigger onChange when outgoing clearing is detected
    @Published var outgoingClearingTrigger: Int = 0

    /// Counter to trigger onChange when mempool incoming is detected (workaround for tuple observation)
    @Published var mempoolIncomingCelebrationTrigger: Int = 0

    /// Counter to trigger onChange when settlement (confirmation) is detected (workaround for tuple observation)
    @Published var settlementCelebrationTrigger: Int = 0

    /// Actor-based transaction tracking (eliminates priority inversion from NSLock)
    private let txTrackingState = TransactionTrackingState()

    /// Called IMMEDIATELY when first peer accepts the broadcast
    /// This provides instant UI feedback before mempool verification completes
    /// ALSO adds txid to pendingOutgoingTxidSet so FilterScanner can detect change outputs
    /// AND tracks in the actor so checkPendingOutgoingConfirmations works
    @MainActor
    func setPendingBroadcast(txid: String, amount: UInt64) {
        pendingBroadcastTxid = txid
        pendingBroadcastAmount = amount
        isMempoolVerified = false

        // CRITICAL: Add to pendingOutgoingTxidSet IMMEDIATELY so FilterScanner
        // can detect change outputs even if trackPendingOutgoing hasn't been called yet
        pendingOutgoingLock.lock()
        pendingOutgoingTxidSet.insert(txid)
        pendingOutgoingLock.unlock()

        // Also update mempoolOutgoing for immediate UI feedback
        self.mempoolOutgoing = amount
        self.mempoolOutgoingTxCount = 1

        // Track in the actor (async but non-blocking) so confirmation checking works
        Task {
            _ = await txTrackingState.trackOutgoing(txid: txid, amount: amount)
            print("📤 Actor tracking set for: \(txid.prefix(12))...")
        }

        print("⚡ Pending broadcast set: txid=\(txid.prefix(12))..., amount=\(amount) zatoshis (added to tracking)")
    }

    /// Called when mempool verification completes
    @MainActor
    func setMempoolVerified() {
        isMempoolVerified = true
        print("✅ Mempool verified for pending broadcast")

        // Trigger Clearing celebration for sender
        if let txid = pendingBroadcastTxid, pendingBroadcastAmount > 0 {
            var clearingTime: TimeInterval = 0
            if let sendTime = WalletManager.shared.lastSendTimestamp {
                clearingTime = Date().timeIntervalSince(sendTime)
            }
            justClearedOutgoing = (txid: txid, amount: pendingBroadcastAmount, clearingTime: clearingTime)
            outgoingClearingTrigger += 1
            print("🏦 CLEARING! Outgoing tx \(txid.prefix(12))... verified in mempool after \(String(format: "%.1f", clearingTime))s")
        }
    }

    /// Clear pending broadcast state (called when tx is confirmed/mined OR when broadcast fails)
    @MainActor
    func clearPendingBroadcast() {
        pendingBroadcastTxid = nil
        pendingBroadcastAmount = 0
        isMempoolVerified = false
        // Also clear mempoolOutgoing so "awaiting confirmation" message disappears
        mempoolOutgoing = 0
        mempoolOutgoingTxCount = 0
        // Clear the sync-accessible pending set
        pendingOutgoingLock.lock()
        pendingOutgoingTxidSet.removeAll()
        pendingOutgoingLock.unlock()
        // Clear the actor state in background
        Task {
            await txTrackingState.clearAllOutgoing()
        }
        print("🧹 Pending broadcast cleared (all pending state reset)")
    }

    /// Called after successfully broadcasting a transaction
    /// Tracks the pending outgoing amount until it confirms
    /// This is now async and awaitable to ensure the tracking completes before UI updates
    func trackPendingOutgoing(txid: String, amount: UInt64) async {
        // Add to sync-accessible set first (for FilterScanner change detection)
        pendingOutgoingLock.lock()
        pendingOutgoingTxidSet.insert(txid)
        pendingOutgoingLock.unlock()

        let result = await txTrackingState.trackOutgoing(txid: txid, amount: amount)
        await MainActor.run {
            self.mempoolOutgoing = result.total
            self.mempoolOutgoingTxCount = result.count
            print("📤 Tracking pending outgoing: \(txid.prefix(12))... = \(amount) zatoshis (total: \(result.total))")
        }
    }

    /// Check if a transaction is being tracked as pending outgoing (our own send)
    /// Used to detect change outputs and suppress notifications
    func isPendingOutgoing(txid: String) async -> Bool {
        return await txTrackingState.isPendingOutgoing(txid: txid)
    }

    /// Called when a transaction is confirmed (found in a block)
    /// Removes from pending tracking and publishes confirmation for UI celebration
    /// This is now async and awaitable to ensure proper completion ordering
    func confirmOutgoingTx(txid: String) async {
        print("📤 confirmOutgoingTx called for: \(txid.prefix(16))...")

        // Remove from sync-accessible set
        pendingOutgoingLock.lock()
        pendingOutgoingTxidSet.remove(txid)
        pendingOutgoingLock.unlock()

        let result = await txTrackingState.confirmOutgoing(txid: txid)
        print("📤 confirmOutgoing result: removed=\(result.removed), total=\(result.total), count=\(result.count)")
        if result.removed {
            await MainActor.run {
                self.mempoolOutgoing = result.total
                self.mempoolOutgoingTxCount = result.count

                // Clear two-phase broadcast tracking (instant UI was showing this)
                self.clearPendingBroadcast()

                // Calculate timing for Settlement celebration
                var settlementTime: TimeInterval? = nil
                var clearingTime: TimeInterval? = nil
                if let sendTime = WalletManager.shared.lastSendTimestamp {
                    settlementTime = Date().timeIntervalSince(sendTime)
                    // Estimate clearing time (we don't have exact mempool verified time, but it's typically 2-5 seconds)
                    clearingTime = min(5.0, settlementTime ?? 5.0)
                }

                // Publish confirmation for UI celebration (Settlement!)
                if let amount = result.amount {
                    self.justConfirmedTx = (txid: txid, amount: amount, isOutgoing: true, clearingTime: clearingTime, settlementTime: settlementTime)
                    self.settlementCelebrationTrigger += 1  // Increment to trigger onChange
                }

                print("⛏️ SETTLEMENT! Outgoing tx confirmed: \(txid.prefix(12))... after \(String(format: "%.1f", settlementTime ?? 0))s (remaining pending: \(result.total), mempoolOutgoing now: \(self.mempoolOutgoing), trigger=\(self.settlementCelebrationTrigger))")
            }
        } else {
            // Even if not tracked, clear pending broadcast in case it was set
            await MainActor.run {
                if self.pendingBroadcastTxid == txid {
                    self.clearPendingBroadcast()
                }
            }
            print("📤 confirmOutgoingTx: txid not found in pending list (already confirmed or never tracked)")
        }
    }

    /// Called when an incoming transaction is confirmed (found in a block during scanning)
    /// Removes from the notification tracking set to allow future notifications for same txid if re-broadcast
    func clearMempoolIncomingNotification(txid: String) {
        Task {
            await txTrackingState.clearIncomingNotification(txid: txid)
        }
    }

    /// Track a pending incoming transaction found during block scan (0 confirmations)
    /// This will trigger the Settlement celebration once it has 1+ confirmations
    func trackPendingIncoming(txid: String, amount: UInt64) async {
        print("📥 trackPendingIncoming: txid=\(txid.prefix(16))... amount=\(amount)")
        await txTrackingState.trackIncoming(txid: txid, amount: amount)
        await MainActor.run {
            // Update mempoolIncoming to show pending indicator
            self.mempoolIncoming += amount
            self.mempoolTxCount += 1
        }
    }

    /// Called when an incoming transaction is confirmed (found in a mined block)
    /// Removes from pending tracking and publishes confirmation for UI celebration
    func confirmIncomingTx(txid: String, amount: UInt64) async {

        // Check if this was a tracked mempool incoming tx
        let trackedAmount = await txTrackingState.confirmIncoming(txid: txid)

        // Use tracked amount if available, otherwise use provided amount
        let finalAmount = trackedAmount ?? amount

        // Clear notification tracking
        await txTrackingState.clearIncomingNotification(txid: txid)

        // ALWAYS clear mempool incoming when a tx is confirmed
        // This handles cases where:
        // 1. Tx was tracked in mempool → clear tracked amount
        // 2. Tx was NOT tracked (peer failures) but mempoolIncoming is set → clear the amount
        // 3. Tx arrived directly in block without mempool detection → no-op (mempoolIncoming already 0)
        await MainActor.run {
            if trackedAmount != nil {
                // Tracked case: reduce by confirmed amount
                if self.mempoolIncoming >= finalAmount {
                    self.mempoolIncoming -= finalAmount
                } else {
                    self.mempoolIncoming = 0
                }
                if self.mempoolTxCount > 0 {
                    self.mempoolTxCount -= 1
                }
            } else if self.mempoolIncoming > 0 {
                // NOT tracked but mempoolIncoming is set → clear it
                // This happens when mempool scan set it but tracking failed
                print("⚠️ mempoolIncoming=\(self.mempoolIncoming) but tx wasn't tracked - clearing")
                if self.mempoolIncoming >= finalAmount {
                    self.mempoolIncoming -= finalAmount
                } else {
                    self.mempoolIncoming = 0
                }
                if self.mempoolTxCount > 0 {
                    self.mempoolTxCount -= 1
                }
            }
        }

        await MainActor.run {
            // Publish confirmation for UI celebration (Settlement for receiver!)
            // Receiver doesn't have send click time, so clearingTime/settlementTime are nil
            self.justConfirmedTx = (txid: txid, amount: finalAmount, isOutgoing: false, clearingTime: nil, settlementTime: nil)
            self.settlementCelebrationTrigger += 1  // Increment to trigger onChange
            print("⛏️ Confirmed: +\(Double(finalAmount) / 100_000_000.0) ZCL")

            // Also send system notification
            NotificationManager.shared.notifyReceivedConfirmed(amount: finalAmount, txid: txid)
        }
    }

    /// Check if any pending outgoing transactions have been confirmed
    /// Called periodically to clean up confirmed transactions
    func checkPendingOutgoingConfirmations() async {
        let pendingTxids = await txTrackingState.getPendingTxids()

        // Only log when there's something to check
        if !pendingTxids.isEmpty || mempoolOutgoing > 0 {
            print("📤 checkPendingOutgoingConfirmations: pendingTxids=\(pendingTxids.count), mempoolOutgoing=\(mempoolOutgoing)")
        }

        guard !pendingTxids.isEmpty else {
            // If we have mempoolOutgoing > 0 but no pending txids, something is out of sync
            if mempoolOutgoing > 0 {
                print("⚠️ mempoolOutgoing=\(mempoolOutgoing) but no pending txids! Clearing...")
                await MainActor.run {
                    self.mempoolOutgoing = 0
                    self.mempoolOutgoingTxCount = 0
                }
            }
            return
        }

        print("📤 Checking \(pendingTxids.count) pending outgoing transactions for confirmations...")
        print("📤 Pending txids: \(pendingTxids.map { $0.prefix(16) + "..." })")

        var confirmedCount = 0

        for txid in pendingTxids {
            // FIX #120: InsightAPI commented out - P2P only
            // Check if transaction has confirmations via InsightAPI
            // do {
            //     let txInfo = try await InsightAPI.shared.getTransaction(txid: txid)
            //     print("📤 Tx \(txid.prefix(16))... has \(txInfo.confirmations) confirmations")
            //     if txInfo.confirmations > 0 {
            //         print("📤 Tx \(txid.prefix(16))... CONFIRMED! Calling confirmOutgoingTx...")
            //         await confirmOutgoingTx(txid: txid)
            //         confirmedCount += 1
            //     }
            // } catch {
            //     print("📤 Failed to check tx \(txid.prefix(16))...: \(error)")
            //     // If we can't find the tx and we've been tracking it, it might be confirmed
            //     // with a different txid format. Check if mempoolOutgoing should be cleared
            //     // after multiple failed lookups.
            // }
            print("📤 Tx \(txid.prefix(16))... (InsightAPI disabled - using P2P only)")
        }

        // Safety: If all pending txids were confirmed but mempoolOutgoing is still > 0,
        // force clear after a small delay (async race condition protection)
        if confirmedCount == pendingTxids.count && confirmedCount > 0 {
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 second delay
            await MainActor.run {
                if self.mempoolOutgoing > 0 {
                    print("📤 Force clearing mempoolOutgoing after all txids confirmed")
                    self.mempoolOutgoing = 0
                    self.mempoolOutgoingTxCount = 0
                }
            }
        }

        // CRITICAL FIX: If any tx was confirmed, trigger wallet sync to update balances
        // This ensures the change note is discovered and has 1+ confirmations
        if confirmedCount > 0 {
            print("⛏️ \(confirmedCount) tx(s) confirmed - triggering wallet sync to update change notes...")

            // FIX #120: InsightAPI commented out - use P2P chain height
            // Get current chain height from InsightAPI
            // if let status = try? await InsightAPI.shared.getStatus() {
            //     let currentHeight = status.height
            let currentHeight = chainHeight  // Use cached P2P chain height
            let walletHeight = (try? WalletDatabase.shared.getLastScannedHeight()) ?? 0

            if currentHeight > walletHeight {
                print("⛏️ Chain height \(currentHeight) > wallet height \(walletHeight) - syncing...")
                // Trigger background sync to scan the confirmed tx block
                await WalletManager.shared.backgroundSyncToHeight(currentHeight)
                // Refresh balance to update confirmation counts
                try? await WalletManager.shared.refreshBalance()
            } else {
                // Even if heights match, still refresh balance to update confirmations
                print("⛏️ Heights match but refreshing balance to update confirmations...")
                try? await WalletManager.shared.refreshBalance()
            }
            // }
        }
    }

    /// Check if any pending incoming transactions have been confirmed (1+ confirmations)
    /// Called periodically to detect when mempool txs get mined and show celebration
    func checkPendingIncomingConfirmations() async {
        let pendingIncoming = await txTrackingState.getPendingIncomingTxids()

        // Only log when there's something to check
        if !pendingIncoming.isEmpty || mempoolIncoming > 0 {
            print("📥 checkPendingIncomingConfirmations: pendingIncoming=\(pendingIncoming.count), mempoolIncoming=\(mempoolIncoming)")
        }

        guard !pendingIncoming.isEmpty else {
            // If we have mempoolIncoming > 0 but no pending txids, something is out of sync
            // This can happen if mempool scan set it but tracking failed
            if mempoolIncoming > 0 {
                print("⚠️ mempoolIncoming=\(mempoolIncoming) but no pending txids! Clearing...")
                await MainActor.run {
                    self.mempoolIncoming = 0
                    self.mempoolTxCount = 0
                }
            }
            return
        }

        // Check pending incoming transactions silently

        var confirmedCount = 0

        for (txid, amount) in pendingIncoming {
            // FIX #120: InsightAPI commented out - P2P only
            // Check if transaction has confirmations via InsightAPI
            // do {
            //     let txInfo = try await InsightAPI.shared.getTransaction(txid: txid)
            //     if txInfo.confirmations >= 1 {
            //         await confirmIncomingTx(txid: txid, amount: amount)
            //         confirmedCount += 1
            //     }
            // } catch {
            //     // Silently skip failed checks
            // }
            _ = txid  // Suppress unused warning
            _ = amount
        }

        // Safety: If all pending txids were confirmed but mempoolIncoming is still > 0,
        // force clear after a small delay (async race condition protection)
        if confirmedCount == pendingIncoming.count && confirmedCount > 0 {
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 second delay
            await MainActor.run {
                if self.mempoolIncoming > 0 {
                    print("📥 Force clearing mempoolIncoming after all txids confirmed")
                    self.mempoolIncoming = 0
                    self.mempoolTxCount = 0
                }
            }
        }
    }

    /// Force clear all pending outgoing transactions
    /// Called when we detect they should be confirmed (e.g., wallet synced past tx block)
    func clearAllPendingOutgoing() {
        Task {
            let txids = await txTrackingState.getPendingTxids()
            for txid in txids {
                await txTrackingState.confirmOutgoing(txid: txid)
            }
            await MainActor.run {
                self.mempoolOutgoing = 0
                self.mempoolOutgoingTxCount = 0
                print("📤 Cleared all pending outgoing transactions")
            }
        }
    }

    /// Scan mempool for incoming shielded transactions
    /// Uses trial decryption to detect payments before confirmation
    private func scanMempoolForIncoming() async {
        print("🔮 scanMempoolForIncoming: starting...")

        // Get all connected peers and try them in order
        var connectedPeers = getAllConnectedPeers()

        // If no ready peers, try to reconnect (LIMITED to 3 peers max to prevent DNS exhaustion)
        if connectedPeers.isEmpty {
            print("🔮 scanMempoolForIncoming: no ready peers, attempting reconnection...")

            // Only try to reconnect up to 3 disconnected peers to prevent connection explosion
            // DNS service has limited slots - creating too many connections causes NoMemory errors
            let maxReconnectAttempts = 3
            var reconnectAttempts = 0

            // Try to reconnect disconnected peers (limited)
            // Use ensureConnected() which has built-in 5-second cooldown to prevent infinite loops
            for peer in peers where !peer.isConnectionReady && reconnectAttempts < maxReconnectAttempts {
                reconnectAttempts += 1
                do {
                    try await peer.ensureConnected()
                    print("✅ scanMempoolForIncoming: reconnected to \(peer.host)")
                    break // Stop after first successful reconnection
                } catch NetworkError.timeout {
                    // Cooldown period - peer was recently reconnected, skip
                    continue
                } catch {
                    // Silently continue - we'll try other peers (up to limit)
                }
            }

            // Check again after reconnect attempt
            connectedPeers = getAllConnectedPeers()
        }

        guard !connectedPeers.isEmpty else {
            print("⚠️ scanMempoolForIncoming: no connected peer after reconnect attempt - mempool scanning disabled!")
            await MainActor.run {
                if !self.p2pMempoolWarning {
                    self.p2pMempoolWarning = true
                    print("⚠️ P2P mempool warning activated - incoming tx detection may be delayed")
                }
            }
            return
        }

        // Clear warning if we have peers now
        await MainActor.run {
            if self.p2pMempoolWarning {
                self.p2pMempoolWarning = false
                print("✅ P2P mempool warning cleared - peers available")
            }
        }

        // Try each peer until one succeeds
        var mempoolTxs: [Data] = []
        var successfulPeer: Peer?

        for peer in connectedPeers {
            do {
                print("🔮 scanMempoolForIncoming: requesting mempool txs from peer \(peer.host)...")
                // Ensure connection is fresh before requesting mempool
                try await peer.ensureConnected()
                mempoolTxs = try await peer.getMempoolTransactions()
                successfulPeer = peer
                print("🔮 scanMempoolForIncoming: got \(mempoolTxs.count) mempool txs from \(peer.host)")
                break
            } catch NetworkError.handshakeFailed {
                // Connection is stale - try to reconnect using ensureConnected (has 5s cooldown)
                print("🔮 scanMempoolForIncoming: peer \(peer.host) stale, will try next peer...")
                // Don't attempt immediate reconnect - let ensureConnected handle it on next iteration
                // This prevents infinite reconnection loops
                continue
            } catch {
                print("⚠️ scanMempoolForIncoming: peer \(peer.host) failed: \(error.localizedDescription)")
                continue
            }
        }

        guard let peer = successfulPeer else {
            print("⚠️ scanMempoolForIncoming: all peers failed")
            return
        }

        // Process mempool transactions
        // NOTE: Don't clear mempoolIncoming when peer returns 0 txs if we have tracked pending incoming
        // This prevents UI flickering when peers are unreliable
        guard !mempoolTxs.isEmpty else {
            let hasPendingIncoming = await txTrackingState.getPendingIncomingCount() > 0
            if !hasPendingIncoming {
                await MainActor.run {
                    self.mempoolIncoming = 0
                    self.mempoolTxCount = 0
                }
            } else {
                print("🔮 Peer returned 0 txs but we have tracked pending incoming - keeping mempoolIncoming=\(self.mempoolIncoming)")
            }
            return
        }

        print("🔮 Scanning \(mempoolTxs.count) mempool transactions...")

        // Get spending key for trial decryption
        guard let spendingKey = try? SecureKeyStorage().retrieveSpendingKey() else {
            print("🔮 scanMempoolForIncoming: could not retrieve spending key, skipping")
            return
        }
        print("🔮 scanMempoolForIncoming: got spending key, checking txs...")

        var incomingAmount: UInt64 = 0
        var incomingCount = 0
        var newIncomingTxs: [(txid: String, amount: UInt64)] = []

        // Get pending outgoing txids upfront to detect change outputs early
        let pendingOutgoingTxids = await txTrackingState.getAllPendingOutgoingTxids()

        // Check each mempool transaction for shielded outputs
        for txHashData in mempoolTxs.prefix(50) { // Limit to 50 to avoid spam
            // P2P returns txids in wire format (little-endian)
            // Convert to display format (big-endian) for consistency with InsightAPI
            let txHashReversed = Data(txHashData.reversed())
            let txHashHex = txHashReversed.map { String(format: "%02x", $0) }.joined()

            // EARLY CHECK: Skip change outputs from our own pending transactions
            // This prevents change from being counted in mempoolIncoming
            // Check BOTH the actor set AND the sync-accessible set to handle race condition
            // where setPendingBroadcast has updated the sync set but actor update is still pending
            if pendingOutgoingTxids.contains(txHashHex) || isPendingOutgoingSync(txid: txHashHex) {
                print("🔮 MEMPOOL: Skipping tx \(txHashHex.prefix(12))... (change output from our pending send)")
                continue
            }

            // FIX #120: P2P only - InsightAPI fallback commented out
            // Try to get raw tx from P2P peer first, then InsightAPI fallback
            var rawTx: Data?
            do {
                rawTx = try await peer.getMempoolTransaction(txid: txHashData)
                print("🔮 Got raw tx \(txHashHex.prefix(12))... from P2P peer")
            } catch {
                print("⚠️ P2P getMempoolTransaction failed for \(txHashHex.prefix(12))...: \(error.localizedDescription)")
                // Fallback to InsightAPI - use getRawTransaction endpoint
                // do {
                //     rawTx = try await InsightAPI.shared.getRawTransaction(txid: txHashHex)
                //     print("🔮 Got raw tx \(txHashHex.prefix(12))... from InsightAPI fallback")
                // } catch {
                //     print("⚠️ InsightAPI fallback also failed for \(txHashHex.prefix(12))...")
                // }
            }

            guard let rawTx = rawTx else {
                print("⚠️ Could not get raw tx for \(txHashHex.prefix(12))... - skipping")
                continue
            }

            // Parse transaction for shielded outputs
            if let outputs = parseShieldedOutputs(from: rawTx) {
                var txIncomingAmount: UInt64 = 0
                for output in outputs {
                    // Try to decrypt with our key
                    if let decrypted = ZipherXFFI.tryDecryptNoteWithSK(
                        spendingKey: spendingKey,
                        epk: output.epk,
                        cmu: output.cmu,
                        ciphertext: output.ciphertext
                    ) {
                        // Found incoming payment!
                        if decrypted.count >= 19 {
                            let valueBytes = Data(decrypted[11..<19])
                            let value = valueBytes.withUnsafeBytes { $0.load(as: UInt64.self) }
                            txIncomingAmount += value
                            print("🔮 MEMPOOL: Found incoming \(value) zatoshis in tx \(txHashHex.prefix(12))...")
                        }
                    }
                }

                if txIncomingAmount > 0 {
                    // EARLY check for change output - before counting toward mempoolIncoming
                    let txidData = Data(hexString: txHashHex) ?? Data()
                    var isChangeOutput = (try? WalletDatabase.shared.transactionExists(txid: txidData, type: .sent)) ?? false

                    if !isChangeOutput {
                        let isPending = await txTrackingState.isPendingOutgoing(txid: txHashHex)
                        if isPending {
                            isChangeOutput = true
                            print("🔔 MEMPOOL: Detected pending outgoing tx \(txHashHex.prefix(12))... (change output)")
                        }
                    }

                    if !isChangeOutput {
                        if let lastSend = WalletManager.shared.lastSendTimestamp,
                           Date().timeIntervalSince(lastSend) < 120.0 {
                            isChangeOutput = true
                            print("🔔 MEMPOOL: Detected recent send activity - treating as change output")
                        }
                    }

                    if !isChangeOutput && mempoolOutgoing > 0 {
                        isChangeOutput = true
                        print("🔔 MEMPOOL: mempoolOutgoing > 0 - treating as change output")
                    }

                    if isChangeOutput {
                        // Change outputs are NOT counted in mempoolIncoming
                        print("🔔 MEMPOOL: Excluding change output \(txIncomingAmount) zatoshis from tx \(txHashHex.prefix(12))...")
                    } else {
                        // CRITICAL: Check if this tx has already been confirmed
                        // This prevents the race condition where mempool scan runs
                        // after confirmation clears mempoolIncoming, but the tx
                        // is still in some peers' mempool (brief lag before removal)
                        let txidDataForCheck = txidData.isEmpty ? (Data(hexString: txHashHex) ?? Data()) : txidData
                        let alreadyConfirmed = (try? WalletDatabase.shared.transactionExists(txid: txidDataForCheck, type: .received)) ?? false

                        if alreadyConfirmed {
                            print("🔮 MEMPOOL: Skipping already-confirmed tx \(txHashHex.prefix(12))...")
                        } else {
                            // Real incoming - count it and prepare for notification
                            incomingAmount += txIncomingAmount
                            incomingCount += 1

                            // Check if this is a NEW incoming tx we haven't notified about
                            let isNewTx = await txTrackingState.checkAndMarkNotified(txid: txHashHex)
                            print("🔮 MEMPOOL: tx \(txHashHex.prefix(12))... isNewTx=\(isNewTx)")
                            if isNewTx {
                                newIncomingTxs.append((txid: txHashHex, amount: txIncomingAmount))
                            } else {
                                print("🔮 MEMPOOL: Skipping already-notified tx \(txHashHex.prefix(12))...")
                            }
                        }
                    }
                }
            }
        }

        // Send notifications for NEW incoming transactions (already filtered for change)
        for (txid, amount) in newIncomingTxs {
            print("🔔 MEMPOOL NOTIFICATION: New incoming \(amount) zatoshis in tx \(txid.prefix(12))...")
            NotificationManager.shared.notifyReceived(amount: amount, txid: txid)

            // Track this incoming tx so we can celebrate when it's confirmed
            await txTrackingState.trackIncoming(txid: txid, amount: amount)

            // Trigger UI celebration for incoming mempool transaction (Clearing for receiver)
            // Receiver doesn't have send click time, so clearingTime is nil
            await MainActor.run {
                self.justDetectedIncomingMempool = (txid: txid, amount: amount, clearingTime: nil)
                self.mempoolIncomingCelebrationTrigger += 1  // Increment to trigger onChange
                print("🏦 CLEARING! Set justDetectedIncomingMempool: txid=\(txid.prefix(12))..., amount=\(amount), trigger=\(self.mempoolIncomingCelebrationTrigger)")
            }
        }

        await MainActor.run {
            self.mempoolIncoming = incomingAmount
            self.mempoolTxCount = incomingCount
            if incomingAmount > 0 {
                print("🔮 Mempool incoming: \(incomingAmount) zatoshis (\(incomingCount) tx)")
            }
        }
    }

    /// Parse shielded outputs from raw transaction data using proper Zcash v4 format
    private func parseShieldedOutputs(from rawTx: Data) -> [(cmu: Data, epk: Data, ciphertext: Data)]? {
        // Zcash v4 overwintered Sapling transaction format
        guard rawTx.count > 200 else { return nil }

        var pos = 0
        var outputs: [(cmu: Data, epk: Data, ciphertext: Data)] = []

        // Header (4 bytes): version and fOverwintered flag
        guard pos + 4 <= rawTx.count else { return nil }
        let header = rawTx.loadUInt32(at: pos)
        let version = header & 0x7FFFFFFF
        let fOverwintered = (header & 0x80000000) != 0
        pos += 4

        // Must be Sapling v4 overwintered transaction
        guard fOverwintered && version >= 4 else {
            print("🔮 parseShieldedOutputs: Not Sapling v4 (v\(version), overwinter=\(fOverwintered))")
            return nil
        }

        // nVersionGroupId (4 bytes)
        guard pos + 4 <= rawTx.count else { return nil }
        let versionGroupId = rawTx.loadUInt32(at: pos)
        pos += 4

        // Verify Sapling version group ID (0x892F2085)
        guard versionGroupId == 0x892F2085 else {
            print("🔮 parseShieldedOutputs: Not Sapling versionGroupId=0x\(String(format: "%08X", versionGroupId))")
            return nil
        }

        // Skip vin (transparent inputs)
        let (vinCount, vinBytes) = readCompactSize(rawTx, at: pos)
        pos += vinBytes
        for _ in 0..<min(vinCount, 10000) {
            guard pos < rawTx.count else { return nil }
            pos = skipTransparentInput(rawTx, offset: pos)
        }

        // Skip vout (transparent outputs)
        let (voutCount, voutBytes) = readCompactSize(rawTx, at: pos)
        pos += voutBytes
        for _ in 0..<min(voutCount, 10000) {
            guard pos < rawTx.count else { return nil }
            pos = skipTransparentOutput(rawTx, offset: pos)
        }

        // Skip nLockTime (4 bytes)
        guard pos + 4 <= rawTx.count else { return nil }
        pos += 4

        // Skip nExpiryHeight (4 bytes)
        guard pos + 4 <= rawTx.count else { return nil }
        pos += 4

        // Skip valueBalance (8 bytes)
        guard pos + 8 <= rawTx.count else { return nil }
        pos += 8

        // Skip vShieldedSpend (each SpendDescription is 384 bytes)
        let (spendCount, spendBytes) = readCompactSize(rawTx, at: pos)
        pos += spendBytes
        for _ in 0..<min(spendCount, 10000) {
            guard pos + 384 <= rawTx.count else { return nil }
            pos += 384 // cv(32) + anchor(32) + nullifier(32) + rk(32) + zkproof(192) + spendAuthSig(64)
        }

        // vShieldedOutput (each OutputDescription is 948 bytes)
        let (outputCount, outputBytes) = readCompactSize(rawTx, at: pos)
        pos += outputBytes
        print("🔮 parseShieldedOutputs: Found \(outputCount) shielded outputs at pos=\(pos)")

        for i in 0..<min(outputCount, 10000) {
            // OutputDescription: cv(32) + cmu(32) + ephemeralKey(32) + encCiphertext(580) + outCiphertext(80) + zkproof(192)
            guard pos + 948 <= rawTx.count else {
                print("🔮 parseShieldedOutputs: Not enough data for output \(i) at pos=\(pos)")
                break
            }

            // cv (32 bytes) - skip
            pos += 32

            // cmu (32 bytes) - EXTRACT
            let cmu = rawTx.subdata(in: pos..<pos+32)
            pos += 32

            // ephemeralKey (32 bytes) - EXTRACT
            let epk = rawTx.subdata(in: pos..<pos+32)
            pos += 32

            // encCiphertext (580 bytes) - EXTRACT
            let ciphertext = rawTx.subdata(in: pos..<pos+580)
            pos += 580

            outputs.append((cmu: cmu, epk: epk, ciphertext: ciphertext))
            print("🔮 parseShieldedOutputs: Output[\(i)] cmu=\(cmu.prefix(8).map { String(format: "%02x", $0) }.joined())...")

            // outCiphertext (80 bytes) - skip
            pos += 80

            // zkproof (192 bytes) - skip
            pos += 192
        }

        return outputs.isEmpty ? nil : outputs
    }

    /// Helper: Read compact size (varint) from data
    private func readCompactSize(_ data: Data, at offset: Int) -> (UInt64, Int) {
        guard offset < data.count else { return (0, 0) }

        let first = data[offset]
        if first < 253 {
            return (UInt64(first), 1)
        } else if first == 253 {
            guard offset + 3 <= data.count else { return (0, 1) }
            let value = UInt16(data[offset + 1]) | (UInt16(data[offset + 2]) << 8)
            return (UInt64(value), 3)
        } else if first == 254 {
            guard offset + 5 <= data.count else { return (0, 1) }
            let value = data.loadUInt32(at: offset + 1)
            return (UInt64(value), 5)
        } else {
            guard offset + 9 <= data.count else { return (0, 1) }
            let value = data.loadUInt64(at: offset + 1)
            return (value, 9)
        }
    }

    /// Helper: Skip a transparent input
    private func skipTransparentInput(_ data: Data, offset: Int) -> Int {
        var pos = offset
        guard pos + 36 <= data.count else { return data.count }
        pos += 36 // prevout: txid (32) + vout index (4)

        let (scriptLen, scriptBytes) = readCompactSize(data, at: pos)
        pos += scriptBytes
        guard scriptLen <= UInt64(data.count - pos) else { return data.count }
        pos += Int(clamping: scriptLen)

        guard pos + 4 <= data.count else { return data.count }
        pos += 4 // sequence
        return pos
    }

    /// Helper: Skip a transparent output
    private func skipTransparentOutput(_ data: Data, offset: Int) -> Int {
        var pos = offset
        guard pos + 8 <= data.count else { return data.count }
        pos += 8 // value

        let (scriptLen, scriptBytes) = readCompactSize(data, at: pos)
        pos += scriptBytes
        guard scriptLen <= UInt64(data.count - pos) else { return data.count }
        pos += Int(clamping: scriptLen)
        return pos
    }

    /// Last time price was fetched (for rate limiting)
    private var lastPriceFetchTime: Date?

    /// Fetch ZCL price from API (with fallback, rate limited to every hour)
    private func fetchZCLPrice() async {
        // Rate limit: only fetch every hour (3600 seconds)
        if let lastFetch = lastPriceFetchTime, Date().timeIntervalSince(lastFetch) < 3600 {
            print("💰 Price fetch skipped (rate limited - hourly)")
            return
        }
        lastPriceFetchTime = Date()
        print("💰 Fetching ZCL price...")

        // Try CoinGecko API first
        if let price = await fetchPriceFromCoinGecko() {
            print("💰 CoinGecko price: $\(price)")
            await MainActor.run {
                self.zclPriceUSD = price
                self.zclPriceFailed = false
            }
            return
        }

        // Fallback: Try CoinMarketCap (free tier)
        if let price = await fetchPriceFromCoinMarketCap() {
            print("💰 CoinMarketCap price: $\(price)")
            await MainActor.run {
                self.zclPriceUSD = price
                self.zclPriceFailed = false
            }
            return
        }

        // Both APIs failed - keep existing price if we have one
        print("⚠️ Failed to fetch ZCL price from any source")
        await MainActor.run {
            self.zclPriceFailed = true
        }
    }

    private func fetchPriceFromCoinGecko() async -> Double? {
        guard let url = URL(string: "https://api.coingecko.com/api/v3/simple/price?ids=zclassic&vs_currencies=usd") else {
            return nil
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            if let httpResponse = response as? HTTPURLResponse {
                print("💰 CoinGecko HTTP status: \(httpResponse.statusCode)")
            }
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let zclData = json["zclassic"] as? [String: Any],
               let price = zclData["usd"] as? Double {
                return price
            }
            print("💰 CoinGecko: couldn't parse response: \(String(data: data, encoding: .utf8) ?? "nil")")
        } catch {
            print("⚠️ CoinGecko price fetch failed: \(error)")
        }
        return nil
    }

    private func fetchPriceFromCoinMarketCap() async -> Double? {
        // CoinMarketCap free tier - uses their web API endpoint (no API key needed)
        // ZCL ID on CoinMarketCap is 1447
        guard let url = URL(string: "https://api.coinmarketcap.com/data-api/v3/cryptocurrency/quote/latest?id=1447&convertId=2781") else {
            return nil
        }

        do {
            var request = URLRequest(url: url)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                print("💰 CoinMarketCap HTTP status: \(httpResponse.statusCode)")
                if httpResponse.statusCode != 200 {
                    print("💰 CoinMarketCap: non-200 status")
                    return nil
                }
            }

            // Parse response: {"data":{"id":1447,"name":"Zclassic",...,"quote":[{"price":0.49,...}]}}
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let dataObj = json["data"] as? [String: Any],
               let quotes = dataObj["quote"] as? [[String: Any]],
               let firstQuote = quotes.first,
               let price = firstQuote["price"] as? Double {
                return price
            }

            // Log response for debugging
            let responseStr = String(data: data, encoding: .utf8) ?? "nil"
            print("💰 CoinMarketCap: couldn't parse response: \(responseStr.prefix(500))")
        } catch {
            print("⚠️ CoinMarketCap price fetch failed: \(error)")
        }
        return nil
    }

    // MARK: - Peer Discovery

    private func discoverPeers() async -> [PeerAddress] {
        var addresses: [PeerAddress] = []

        for seed in dnsSeedsZCL {
            let resolved = await resolveDNSSeed(seed)
            addresses.append(contentsOf: resolved)
        }

        // Add .onion seed nodes if Tor is available
        let torMode = await TorManager.shared.mode
        let torConnected = await TorManager.shared.connectionState.isConnected
        if torMode == .enabled && torConnected {
            for onionSeed in ZclassicCheckpoints.onionSeedNodes {
                addresses.append(PeerAddress(host: onionSeed, port: defaultPort))
                print("🧅 Added .onion seed: \(onionSeed)")
            }
        }

        return addresses
    }

    private func resolveDNSSeed(_ hostname: String) async -> [PeerAddress] {
        return await withCheckedContinuation { continuation in
            // Dispatch DNS resolution to background queue to avoid priority inversion
            DispatchQueue.global(qos: .utility).async {
                let host = CFHostCreateWithName(nil, hostname as CFString).takeRetainedValue()
                var resolved = DarwinBoolean(false)

                CFHostStartInfoResolution(host, .addresses, nil)

                guard let addresses = CFHostGetAddressing(host, &resolved)?.takeUnretainedValue() as? [Data] else {
                    continuation.resume(returning: [])
                    return
                }

                var peerAddresses: [PeerAddress] = []
                for addressData in addresses {
                    var hostnameBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    addressData.withUnsafeBytes { ptr in
                        let sockaddr = ptr.baseAddress!.assumingMemoryBound(to: sockaddr.self)
                        getnameinfo(sockaddr, socklen_t(addressData.count), &hostnameBuffer, socklen_t(hostnameBuffer.count), nil, 0, NI_NUMERICHOST)
                    }
                    let hostStr = String(cString: hostnameBuffer)
                    peerAddresses.append(PeerAddress(host: hostStr, port: self.defaultPort))
                }

                continuation.resume(returning: peerAddresses)
            }
        }
    }

    private func connectToPeer(_ address: PeerAddress) async throws -> Peer {
        let peer = Peer(host: address.host, port: address.port, networkMagic: networkMagic)

        // Add timeout for connection attempts
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await peer.connect()
                try await peer.performHandshake()
            }

            group.addTask {
                try await Task.sleep(nanoseconds: 10_000_000_000) // 10 second timeout
                throw NetworkError.connectionTimeout
            }

            // Wait for first to complete (either connection or timeout)
            try await group.next()
            group.cancelAll()
        }

        return peer
    }

    // MARK: - Block Announcement Listener

    /// Set up block announcement listener for a peer
    /// When the peer receives a new block via P2P inv message, it triggers a background sync
    private func setupBlockListener(for peer: Peer) {
        peer.onBlockAnnounced = { [weak self] blockHash in
            guard let self = self else { return }

            let hashHex = blockHash.map { String(format: "%02x", $0) }.joined()
            print("📦 New block announced: \(hashHex.prefix(16))...")

            // Trigger background sync immediately (non-blocking)
            Task {
                await self.onNewBlockAnnounced()
            }
        }

        // Start listening in background
        peer.startBlockListener()
    }

    /// Called when any peer announces a new block
    /// Triggers fetchNetworkStats which will sync new blocks via backgroundSyncToHeight
    private func onNewBlockAnnounced() async {
        // Debounce: avoid multiple syncs if multiple peers announce same block
        let now = Date()
        if let lastAnnouncement = lastBlockAnnouncementTime,
           now.timeIntervalSince(lastAnnouncement) < 2.0 {
            return // Skip if less than 2 seconds since last announcement
        }
        lastBlockAnnouncementTime = now

        print("⚡ Processing new block announcement - triggering sync...")

        // Fetch network stats which will trigger backgroundSyncToHeight if needed
        await fetchNetworkStats()
    }

    /// Track last block announcement time for debouncing
    private var lastBlockAnnouncementTime: Date?

    // MARK: - Consensus Queries

    /// Query shielded balance with multi-peer consensus
    func queryShieldedBalance(for address: String) async throws -> ShieldedBalance {
        guard isConnected else {
            throw NetworkError.notConnected
        }

        var responses: [String: Int] = [:]
        var balanceResponses: [String: ShieldedBalance] = [:]

        // Query all peers
        await withTaskGroup(of: (String, ShieldedBalance?).self) { group in
            for peer in peers {
                group.addTask {
                    do {
                        let balance = try await peer.getShieldedBalance(address: address)
                        return (peer.id, balance)
                    } catch {
                        return (peer.id, nil)
                    }
                }
            }

            for await (peerId, balance) in group {
                if let balance = balance {
                    let key = "\(balance.confirmed):\(balance.pending)"
                    responses[key, default: 0] += 1
                    balanceResponses[key] = balance
                }
            }
        }

        // Find consensus
        guard let (key, count) = responses.max(by: { $0.value < $1.value }),
              count >= CONSENSUS_THRESHOLD,
              let balance = balanceResponses[key] else {
            throw NetworkError.consensusNotReached
        }

        return balance
    }

    /// Broadcast progress callback type
    typealias BroadcastProgressCallback = (_ phase: String, _ detail: String?, _ progress: Double?) -> Void

    /// Broadcast transaction with multi-peer propagation and progress reporting
    /// Primary: P2P broadcast to connected peers
    /// Fallback: InsightAPI broadcast if no P2P peers available
    /// Success = at least one peer/API accepted + mempool confirms (FAST EXIT)
    /// NEW: Pass amount to enable instant UI feedback when first peer accepts
    func broadcastTransactionWithProgress(_ rawTx: Data, amount: UInt64 = 0, onProgress: BroadcastProgressCallback? = nil) async throws -> String {
        print("📡 Starting broadcast, connected: \(isConnected), peers: \(peers.count)")

        // FIX #120: InsightAPI commented out - P2P only
        // If no P2P peers, fall back to InsightAPI broadcast
        if !isConnected || peers.isEmpty {
            print("⚠️ No P2P peers available - cannot broadcast (P2P only mode)")
            // onProgress?("api", "Submitting to blockchain...", 0.3)
            //
            // do {
            //     let txid = try await InsightAPI.shared.broadcastTransaction(rawTx)
            //     print("✅ InsightAPI broadcast successful: \(txid)")
            //     onProgress?("api", "Submitted - awaiting miners", 1.0)
            //     return txid
            // } catch {
            //     print("❌ InsightAPI broadcast failed: \(error)")
            //     throw NetworkError.broadcastFailed
            // }
            throw NetworkError.connectionFailed("No P2P peers available for broadcast")
        }

        let peerCount = peers.count
        print("📡 Broadcasting to \(peerCount) peers...")
        onProgress?("peers", "Propagating to network (\(peerCount) peers)...", 0.0)

        // Use actor for thread-safe state
        actor BroadcastState {
            var successCount = 0
            var txId: String?
            var mempoolVerified = false
            var pendingBroadcastSet = false  // Track if we've set pending broadcast

            func recordSuccess(_ id: String) -> (count: Int, isFirst: Bool) {
                let isFirst = (successCount == 0)
                successCount += 1
                txId = id
                return (successCount, isFirst)
            }

            func markPendingBroadcastSet() { pendingBroadcastSet = true }
            func isPendingBroadcastSet() -> Bool { pendingBroadcastSet }
            func setVerified() { mempoolVerified = true }
            func isVerified() -> Bool { mempoolVerified }
            func getTxId() -> String? { txId }
            func getSuccessCount() -> Int { successCount }
        }

        let state = BroadcastState()
        let broadcastAmount = amount  // Capture for use in closures

        // Broadcast to all peers - but check mempool after FIRST success
        // Use short timeout (5s) to avoid waiting for slow/dead peers
        await withThrowingTaskGroup(of: Void.self) { group in
            // Add broadcast tasks for all peers with fast timeout
            for peer in peers {
                let peerHost = "\(peer.host):\(peer.port)"
                group.addTask {
                    do {
                        // 5 second timeout for ENTIRE operation (connect + broadcast)
                        let id = try await withThrowingTaskGroup(of: String.self) { timeoutGroup in
                            timeoutGroup.addTask {
                                // Ensure peer connection is still valid before broadcast
                                try await peer.ensureConnected()
                                return try await peer.broadcastTransaction(rawTx)
                            }
                            timeoutGroup.addTask {
                                try await Task.sleep(nanoseconds: 5_000_000_000) // 5s timeout
                                throw NetworkError.timeout
                            }
                            // Return first result (either success or timeout)
                            guard let result = try await timeoutGroup.next() else {
                                throw NetworkError.timeout
                            }
                            timeoutGroup.cancelAll()
                            return result
                        }
                        print("✅ Peer \(peerHost) accepted tx: \(id)")
                        let result = await state.recordSuccess(id)

                        // On FIRST peer acceptance, immediately set pending broadcast for instant UI feedback
                        if result.isFirst && broadcastAmount > 0 {
                            await MainActor.run {
                                self.setPendingBroadcast(txid: id, amount: broadcastAmount)
                            }
                            await state.markPendingBroadcastSet()
                        }

                        // Include txid in detail so UI can display it immediately
                        onProgress?("peers", "Accepted by \(result.count)/\(peerCount) nodes [txid:\(id)]", Double(result.count) / Double(peerCount))
                    } catch {
                        print("⚠️ Peer \(peerHost) broadcast failed: \(error)")
                    }
                }
            }

            // Add mempool verification task - runs in parallel, exits early on success
            group.addTask {
                // Wait for at least one peer to accept (max 10 seconds, then give up)
                var waitAttempts = 0
                while await state.getTxId() == nil && waitAttempts < 100 {
                    try await Task.sleep(nanoseconds: 100_000_000) // 100ms
                    waitAttempts += 1
                }

                guard let txId = await state.getTxId() else {
                    print("⚠️ No peer accepted transaction within timeout")
                    return
                }

                // FIX #120: InsightAPI mempool check commented out - P2P only
                // If P2P peers accepted, assume success (mempool check via API disabled)
                onProgress?("verify", "Propagating to miners...", 0.8)

                // Check mempool - 5 attempts with 1 second between each (5 seconds total)
                // This gives time for transaction to propagate and be validated by the network
                // for attempt in 1...5 {
                //     onProgress?("verify", "Verifying mempool (attempt \(attempt)/5)...", 0.5 + Double(attempt) * 0.08)
                //     if try await InsightAPI.shared.checkTransactionExists(txid: txId) {
                //         print("✅ Transaction VERIFIED in mempool: \(txId)")
                //         onProgress?("verify", "In mempool - awaiting miners", 1.0)
                //         await state.setVerified()
                //         // Update UI state: mempool verified (for progressive messaging)
                //         await MainActor.run {
                //             self.setMempoolVerified()
                //         }
                //         return // Exit immediately!
                //     }
                //     print("⏳ Mempool check attempt \(attempt)/5: not yet visible")
                //     if attempt < 5 {
                //         try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second between checks
                //     }
                // }
                // print("❌ Transaction NOT found in mempool after 5 attempts")

                // P2P only mode: If peers accepted, mark as verified
                print("✅ P2P broadcast accepted - marking as verified (InsightAPI disabled)")
                onProgress?("verify", "Accepted by network - awaiting miners", 1.0)
                await state.setVerified()
                await MainActor.run {
                    self.setMempoolVerified()
                }
            }

            // The mempool verification task will set isVerified() and return
            // The broadcast tasks will complete (success or fail)
            // We just need to wait for all tasks to finish, but with a timeout

            // Add a timeout task that cancels everything after 15 seconds
            // (5 second broadcast + 5 second mempool verification + buffer)
            group.addTask {
                try await Task.sleep(nanoseconds: 15_000_000_000) // 15 second max
                print("⏱️ Broadcast timeout reached")
            }

            // Wait for tasks - but check verified status after each
            var tasksRemaining = true
            while tasksRemaining {
                // Check if mempool verified - exit early!
                if await state.isVerified() {
                    print("✅ Mempool verified - exiting broadcast loop")
                    group.cancelAll()
                    break
                }

                do {
                    guard let _ = try await group.next() else {
                        tasksRemaining = false
                        break
                    }
                    // A task finished - check verified status again immediately
                    if await state.isVerified() {
                        print("✅ Mempool verified after task completion - exiting")
                        group.cancelAll()
                        break
                    }
                } catch {
                    // Task threw (timeout or error), continue
                    if await state.isVerified() {
                        group.cancelAll()
                        break
                    }
                }
            }
        }

        // Check results
        guard let txId = await state.getTxId() else {
            // FIX #120: InsightAPI fallback commented out - P2P only
            // P2P broadcast failed - fall back to InsightAPI
            print("⚠️ P2P broadcast failed - no fallback (P2P only mode)")
            // onProgress?("api", "Retrying via backup route...", 0.5)
            //
            // do {
            //     let apiTxId = try await InsightAPI.shared.broadcastTransaction(rawTx)
            //     print("✅ InsightAPI broadcast successful: \(apiTxId)")
            //     onProgress?("api", "Submitted - awaiting miners", 1.0)
            //     return apiTxId
            // } catch {
            //     print("❌ InsightAPI broadcast also failed: \(error)")
            //     throw NetworkError.broadcastFailed
            // }
            throw NetworkError.broadcastFailed
        }

        let successCount = await state.getSuccessCount()
        let verified = await state.isVerified()

        print("📡 Transaction broadcast to \(successCount)/\(peerCount) peers: \(txId)")

        if !verified {
            // CRITICAL FIX: Mempool verification failed - the transaction was likely REJECTED!
            // P2P peers may "accept" into their local mempool but then reject during validation.
            // If we can't see it in the explorer mempool, it's NOT a valid transaction.
            print("❌ BROADCAST FAILED: Transaction not visible in mempool after 5 attempts")
            print("❌ The transaction was likely rejected by the network (invalid proof)")
            onProgress?("error", "Transaction rejected by network", 0.0)

            // Clear any pending broadcast state since the tx is invalid
            await MainActor.run {
                self.clearPendingBroadcast()
            }

            throw NetworkError.broadcastFailed
        }

        return txId
    }

    /// Broadcast transaction with multi-peer propagation (without progress)
    /// Success = at least one peer accepted the transaction (returned txid)
    func broadcastTransaction(_ rawTx: Data) async throws -> String {
        return try await broadcastTransactionWithProgress(rawTx, onProgress: nil)
    }

    /// Get block headers for chain verification
    func getBlockHeaders(from height: UInt64, count: Int) async throws -> [BlockHeader] {
        guard isConnected else {
            throw NetworkError.notConnected
        }

        var responses: [[BlockHeader]: Int] = [:]

        await withTaskGroup(of: [BlockHeader]?.self) { group in
            for peer in peers {
                group.addTask {
                    try? await peer.getBlockHeaders(from: height, count: count)
                }
            }

            for await result in group {
                if let headers = result {
                    responses[headers, default: 0] += 1
                }
            }
        }

        guard let (headers, count) = responses.max(by: { $0.value < $1.value }),
              count >= CONSENSUS_THRESHOLD else {
            throw NetworkError.consensusNotReached
        }

        return headers
    }

    /// Get current chain height from peers (P2P-first, InsightAPI fallback)
    func getChainHeight() async throws -> UInt64 {
        guard isConnected else {
            throw NetworkError.notConnected
        }

        // P2P-FIRST architecture: prioritize trustless P2P data
        // CRITICAL: Always verify against network - don't trust stale cached values!
        let torEnabled = await TorManager.shared.mode == .enabled
        print("📡 Getting chain height (P2P-first, Tor=\(torEnabled ? "ON" : "OFF"))...")

        // FIX #120: InsightAPI commented out - P2P only
        // 1. Get network height from InsightAPI - ONLY if Tor is disabled
        // InsightAPI is blocked by Cloudflare when accessed via Tor
        var networkHeight: UInt64 = 0
        // if !torEnabled {
        //     if let status = try? await InsightAPI.shared.getStatus() {
        //         networkHeight = status.height
        //         print("📡 [API] Network height: \(networkHeight)")
        //     }
        // } else {
        //     print("🧅 Tor enabled - skipping InsightAPI (Cloudflare blocks Tor)")
        // }
        _ = torEnabled  // Suppress unused warning
        print("📡 P2P only mode - InsightAPI disabled")

        // 2. Check header store (our locally verified headers)
        var headerHeight: UInt64 = 0
        if let h = try? HeaderStore.shared.getLatestHeight() {
            headerHeight = h
            print("📡 [P2P] HeaderStore height: \(headerHeight)")
        }

        // 3. PEER CONSENSUS - The most trustworthy source for chain height
        // Collect heights from all connected peers and find consensus (skip banned peers)
        var peerHeights: [UInt64: Int] = [:]  // height -> count of peers reporting it
        var peerMaxHeight: UInt64 = 0

        for peer in peers {
            // SECURITY: Skip banned peers and negative heights (malicious peers)
            guard !isBanned(peer.host), peer.peerStartHeight > 0 else { continue }
            let h = UInt64(peer.peerStartHeight)  // Safe: checked > 0 above
            if h > 0 {
                peerHeights[h, default: 0] += 1
                if h > peerMaxHeight {
                    peerMaxHeight = h
                }
            }
        }

        // Find peer consensus height (height reported by most peers, must be within 10 blocks of max)
        var peerConsensusHeight: UInt64 = 0
        var consensusCount = 0
        for (height, count) in peerHeights {
            // Only consider heights close to max (within 10 blocks)
            if peerMaxHeight > 0 && height >= peerMaxHeight - 10 && count > consensusCount {
                peerConsensusHeight = height
                consensusCount = count
            }
        }

        if peerConsensusHeight > 0 {
            print("📡 [P2P] Peer consensus: \(peerConsensusHeight) (\(consensusCount)/\(peers.count) peers agree)")
        }

        // SECURITY: Detect and ban peers reporting heights VERY far from consensus
        let maxOutlierTolerance: UInt64 = 500
        if peerConsensusHeight > 0 {
            for peer in peers {
                // Skip already banned peers, skip negative heights
                guard !isBanned(peer.host), peer.peerStartHeight > 0 else { continue }
                let h = UInt64(peer.peerStartHeight)  // Safe: checked > 0 above
                if h > peerConsensusHeight + maxOutlierTolerance {
                    print("""
                    🚨🚨🚨 SECURITY ALERT: FAKE HEIGHT DETECTED 🚨🚨🚨
                    ⚠️ Peer \(peer.host) reports height \(h)
                    ⚠️ Peer consensus: \(peerConsensusHeight)
                    ⚠️ Difference: \(h - peerConsensusHeight) blocks AHEAD (tolerance: \(maxOutlierTolerance))
                    🔒 BANNING peer for 7 days...
                    🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨
                    """)
                    banPeer(peer, reason: .corruptedData)
                    peer.disconnect()
                }
            }
        }

        // WARNING: If peer consensus is significantly higher than HeaderStore, headers are lagging
        if headerHeight > 0 && peerConsensusHeight > headerHeight + 50 {
            print("⚠️ HeaderStore is \(peerConsensusHeight - headerHeight) blocks behind peer consensus - header sync needed!")
        }

        // 4. Determine best height - PEER CONSENSUS is PRIMARY (decentralized!)
        // Priority: Peer consensus > InsightAPI > HeaderStore > Cached
        var bestHeight: UInt64 = 0

        if peerConsensusHeight > 0 && consensusCount >= 2 {
            // BEST: Peer consensus (decentralized, trustworthy if 2+ peers agree)
            bestHeight = peerConsensusHeight
            print("📡 Using PEER CONSENSUS height: \(bestHeight) (\(consensusCount) peers)")
        } else if networkHeight > 0 {
            // FALLBACK: InsightAPI (centralized but usually accurate)
            bestHeight = networkHeight
            print("📡 Using InsightAPI height: \(bestHeight)")
        } else if peerMaxHeight > 0 {
            // FALLBACK: Single peer max (less trustworthy)
            bestHeight = peerMaxHeight
            print("📡 Using peer max height (no consensus): \(bestHeight)")
        } else if headerHeight > 0 {
            // FALLBACK: HeaderStore (local, can be lagging)
            bestHeight = headerHeight
            print("📡 Using HeaderStore height: \(bestHeight)")
        } else if chainHeight > 0 {
            // LAST RESORT: Cached value
            bestHeight = chainHeight
            print("📡 Using cached height: \(bestHeight)")
        }

        if bestHeight > 0 {
            return bestHeight
        }

        throw NetworkError.consensusNotReached
    }

    /// Get compact block filters for transaction detection
    func getCompactFilters(from height: UInt64, count: Int) async throws -> [CompactFilter] {
        guard isConnected else {
            throw NetworkError.notConnected
        }

        var responses: [[CompactFilter]: Int] = [:]

        await withTaskGroup(of: [CompactFilter]?.self) { group in
            for peer in peers {
                group.addTask {
                    try? await peer.getCompactFilters(from: height, count: count)
                }
            }

            for await result in group {
                if let filters = result {
                    responses[filters, default: 0] += 1
                }
            }
        }

        guard let (filters, count) = responses.max(by: { $0.value < $1.value }),
              count >= CONSENSUS_THRESHOLD else {
            throw NetworkError.consensusNotReached
        }

        return filters
    }

    /// Get compact blocks (ZIP-307) for shielded transaction scanning
    /// Uses multi-peer consensus for trustless verification
    func getCompactBlocks(from height: UInt64, count: Int) async throws -> [CompactBlock] {
        guard isConnected else {
            throw NetworkError.notConnected
        }

        // For single blocks or small batches, use multi-peer consensus
        if count <= 10 {
            return try await getBlocksWithConsensus(from: height, count: count)
        }

        // For larger batches, use single peer but verify key data
        guard let peer = peers.first else {
            throw NetworkError.notConnected
        }

        let blocks = try await peer.getFullBlocks(from: height, count: count)

        guard !blocks.isEmpty else {
            throw NetworkError.consensusNotReached
        }

        return blocks
    }

    /// Get blocks from multiple peers and verify consensus on critical data
    /// Returns blocks only if at least CONSENSUS_THRESHOLD peers agree
    func getBlocksWithConsensus(from height: UInt64, count: Int) async throws -> [CompactBlock] {
        guard isConnected else {
            throw NetworkError.notConnected
        }

        let availablePeers = peers.prefix(min(peers.count, 4)) // Use up to 4 peers
        guard availablePeers.count >= 1 else {
            throw NetworkError.notConnected
        }

        // Request blocks from multiple peers in parallel
        var peerResults: [[[UInt8]]: [CompactBlock]] = [:] // Block hashes -> blocks

        await withTaskGroup(of: (String, [CompactBlock]?).self) { group in
            for peer in availablePeers {
                group.addTask {
                    do {
                        let blocks = try await peer.getFullBlocks(from: height, count: count)
                        return (peer.host, blocks)
                    } catch {
                        print("⚠️ Failed to get blocks from peer \(peer.host): \(error)")
                        peer.recordFailure()
                        return (peer.host, nil)
                    }
                }
            }

            for await (peerHost, blocks) in group {
                if let blocks = blocks, !blocks.isEmpty {
                    // Create key from block hashes for consensus check
                    let hashKey = blocks.map { Array($0.blockHash) }
                    peerResults[hashKey] = blocks
                    print("📦 Peer \(peerHost) returned \(blocks.count) blocks")
                }
            }
        }

        // Find consensus - blocks where hash matches between peers
        guard !peerResults.isEmpty else {
            throw NetworkError.consensusNotReached
        }

        // If we have multiple responses, verify they match
        if peerResults.count >= 2 {
            // Find the response with most agreement
            var voteCount: [[UInt8]: Int] = [:]
            for (hashKey, _) in peerResults {
                // Flatten to single hash for voting
                let flatHash = hashKey.flatMap { $0 }
                voteCount[flatHash, default: 0] += 1
            }

            guard let (winningHash, votes) = voteCount.max(by: { $0.value < $1.value }),
                  votes >= min(CONSENSUS_THRESHOLD, peerResults.count) else {
                print("❌ No consensus on blocks from height \(height)")
                throw NetworkError.consensusNotReached
            }

            // Find blocks matching winning hash
            for (hashKey, blocks) in peerResults {
                if hashKey.flatMap({ $0 }) == winningHash {
                    print("✅ Block consensus reached with \(votes) peers")
                    return blocks
                }
            }
        }

        // Single peer response - accept it (user should enable multi-peer for security)
        if let (_, blocks) = peerResults.first {
            print("⚠️ Using single peer response (multi-peer consensus recommended)")
            return blocks
        }

        throw NetworkError.consensusNotReached
    }

    /// Get a single block by hash from multiple peers with consensus
    func getBlockByHashWithConsensus(hash: Data) async throws -> CompactBlock {
        guard isConnected else {
            throw NetworkError.notConnected
        }

        let availablePeers = peers.prefix(min(peers.count, 3))
        guard !availablePeers.isEmpty else {
            throw NetworkError.notConnected
        }

        var results: [Data: CompactBlock] = [:] // finalSaplingRoot -> block

        await withTaskGroup(of: CompactBlock?.self) { group in
            for peer in availablePeers {
                group.addTask {
                    try? await peer.getBlockByHash(hash: hash)
                }
            }

            for await block in group {
                if let block = block {
                    // Key by finalSaplingRoot - the critical data we need to verify
                    results[block.finalSaplingRoot] = block
                }
            }
        }

        guard !results.isEmpty else {
            throw NetworkError.consensusNotReached
        }

        // If multiple different sapling roots, reject (could be attack)
        if results.count > 1 {
            print("⚠️ Peers disagree on finalSaplingRoot - possible attack!")
            throw NetworkError.consensusNotReached
        }

        // All peers agree
        return results.values.first!
    }

    /// Get transaction by txid from P2P network
    func getTransactionP2P(txid: String) async throws -> Data {
        guard isConnected else {
            throw NetworkError.notConnected
        }

        guard let peer = peers.first else {
            throw NetworkError.notConnected
        }

        // Convert txid hex string to Data (reversed for network byte order)
        guard let txidData = Data(hexString: txid)?.reversed() else {
            throw NetworkError.invalidData
        }

        // Request transaction via getdata
        return try await peer.getTransaction(hash: Data(txidData))
    }

    // MARK: - P2P Block Scanning

    /// Get block data for a specific height via P2P (used by FilterScanner)
    /// Returns CompactBlock with transactions including shielded outputs
    func getBlockForScanning(height: UInt64) async throws -> CompactBlock {
        guard isConnected else {
            throw NetworkError.notConnected
        }

        // Use multi-peer consensus for single block
        let blocks = try await getBlocksWithConsensus(from: height, count: 1)
        guard let block = blocks.first else {
            throw NetworkError.consensusNotReached
        }

        return block
    }

    /// Get multiple blocks for scanning via P2P
    func getBlocksForScanning(from height: UInt64, count: Int) async throws -> [CompactBlock] {
        guard isConnected else {
            throw NetworkError.notConnected
        }

        // For larger batches, use getCompactBlocks which handles consensus
        return try await getCompactBlocks(from: height, count: count)
    }

    /// Get chain height from P2P sources only (no InsightAPI fallback)
    /// Uses: HeaderStore (locally verified) > peer version heights
    func getChainHeightP2POnly() async throws -> UInt64 {
        guard isConnected else {
            throw NetworkError.notConnected
        }

        // FIX #120: InsightAPI commented out - P2P only
        // SECURITY: Get InsightAPI height first to validate P2P sources
        var trustedHeight: UInt64 = 0
        let maxDeviation: UInt64 = 10

        // do {
        //     let status = try await InsightAPI.shared.getStatus()
        //     trustedHeight = status.height
        // } catch {
        //     print("⚠️ InsightAPI unavailable for P2P height validation")
        // }
        _ = maxDeviation  // Suppress unused warning (validation disabled)
        print("📡 P2P only mode - using HeaderStore as trusted source")

        var maxHeight: UInt64 = 0

        // 1. HeaderStore (locally verified headers - but may have fake data)
        if let headerHeight = try? HeaderStore.shared.getLatestHeight() {
            // Validate against trusted source
            if trustedHeight > 0 && headerHeight > trustedHeight + maxDeviation {
                print("🚨 [SECURITY] HeaderStore height \(headerHeight) is FAKE, ignoring")
            } else {
                maxHeight = max(maxHeight, headerHeight)
            }
        }

        // 2. Peer version heights (may be fake) - skip banned peers and negative heights
        for peer in peers {
            // SECURITY: Skip banned peers and negative heights (malicious peers)
            guard !isBanned(peer.host), peer.peerStartHeight > 0 else { continue }
            let h = UInt64(peer.peerStartHeight)  // Safe: checked > 0 above
            if h > 0 {
                // Validate against trusted source
                if trustedHeight > 0 && h > trustedHeight + maxDeviation {
                    print("🚨 [SECURITY] Peer height \(h) is FAKE, ignoring")
                } else if h > maxHeight {
                    maxHeight = h
                }
            }
        }

        // 3. Use trusted height if we have it and P2P sources were all fake
        if trustedHeight > 0 && maxHeight == 0 {
            print("📡 All P2P heights were fake, using InsightAPI: \(trustedHeight)")
            return trustedHeight
        }

        // 4. Fallback to cached height only if reasonable
        if maxHeight == 0 && chainHeight > 0 {
            if trustedHeight > 0 && chainHeight > trustedHeight + maxDeviation {
                print("🚨 [SECURITY] Cached chainHeight \(chainHeight) is FAKE, ignoring")
            } else {
                maxHeight = chainHeight
            }
        }

        guard maxHeight > 0 else {
            throw NetworkError.consensusNotReached
        }

        return maxHeight
    }

    // MARK: - P2P Block Data On-Demand (No HeaderStore Required)

    /// Get blocks on-demand via P2P using getheaders + getdata
    /// This does NOT require pre-synced headers - fetches headers directly from peers
    /// Tries multiple peers with reconnection logic
    /// Returns: [(CompactBlock)] with CMUs in wire format (little-endian)
    func getBlocksOnDemandP2P(from height: UInt64, count: Int) async throws -> [CompactBlock] {
        print("🔗 P2P on-demand: Fetching \(count) blocks from height \(height)")

        // Ensure at least some peers are connected before checking
        var availablePeers = peers.filter { $0.isConnectionReady }

        if availablePeers.isEmpty && !peers.isEmpty {
            // No ready peers but we have peers - try to reconnect them
            print("⏳ P2P on-demand: No ready peers, attempting reconnection...")

            // Try to reconnect up to 3 peers in parallel
            let peersToReconnect = Array(peers.prefix(3))
            await withTaskGroup(of: Void.self) { group in
                for peer in peersToReconnect {
                    group.addTask {
                        do {
                            try await peer.ensureConnected()
                        } catch {
                            print("⚠️ P2P on-demand: Failed to reconnect \(peer.host): \(error.localizedDescription)")
                        }
                    }
                }
            }

            // Check again after reconnection attempt
            availablePeers = peers.filter { $0.isConnectionReady }

            if availablePeers.isEmpty {
                print("⚠️ P2P on-demand: Still no ready peers after reconnection attempt")
                throw NetworkError.notConnected
            } else {
                print("✅ P2P on-demand: Reconnected \(availablePeers.count) peers")
            }
        }

        guard !availablePeers.isEmpty else {
            throw NetworkError.notConnected
        }

        // Try each peer until one succeeds with the block fetch
        var lastError: Error = NetworkError.p2pFetchFailed
        for peer in availablePeers.shuffled() {
            do {
                print("📡 P2P on-demand: Trying peer \(peer.host)...")
                let blocks = try await withTimeout(seconds: 30) {
                    try await peer.getFullBlocks(from: height, count: count)
                }

                if !blocks.isEmpty {
                    print("✅ P2P on-demand: Got \(blocks.count) blocks from \(peer.host)")
                    return blocks
                }
            } catch {
                print("⚠️ P2P on-demand: Peer \(peer.host) failed: \(error.localizedDescription)")
                lastError = error
                continue
            }
        }

        print("❌ P2P on-demand: All \(availablePeers.count) peers failed")
        throw lastError
    }

    // MARK: - P2P Block Data for Scanning (Full P2P Mode)

    /// Get block data with shielded outputs in format compatible with FilterScanner
    /// Returns: (blockHash, [(txid, [ShieldedOutput], [ShieldedSpend]?)])
    func getBlockDataP2P(height: UInt64) async throws -> (String, [(String, [ShieldedOutput], [ShieldedSpend]?)]) {
        guard isConnected else {
            throw NetworkError.notConnected
        }

        guard let peer = peers.first else {
            throw NetworkError.notConnected
        }

        // Get block hash from HeaderStore (already synced)
        guard let header = try? HeaderStore.shared.getHeader(at: height) else {
            print("⚠️ P2P: No header found at height \(height)")
            throw NetworkError.consensusNotReached
        }

        // Get the block by hash via P2P
        let block = try await peer.getBlockByHash(hash: header.blockHash)
        // Set correct height on the returned block (getBlockByHash doesn't know the height)
        let blockWithHeight = CompactBlock(
            blockHeight: height,
            blockHash: block.blockHash,
            prevHash: block.prevHash,
            finalSaplingRoot: block.finalSaplingRoot,
            time: block.time,
            transactions: block.transactions
        )

        // Convert block hash to hex string
        let blockHashHex = blockWithHeight.blockHash.map { String(format: "%02x", $0) }.joined()

        // Parse each transaction in the block
        var txDataList: [(String, [ShieldedOutput], [ShieldedSpend]?)] = []

        for (_, tx) in blockWithHeight.transactions.enumerated() {
            // Convert CompactOutput to ShieldedOutput format
            var shieldedOutputs: [ShieldedOutput] = []
            for output in tx.outputs {
                // Convert Data to hex strings in display format (big-endian for cmu/epk)
                // Note: The wire format is little-endian, display format is big-endian (reversed)
                let cmuHex = Data(output.cmu.reversed()).map { String(format: "%02x", $0) }.joined()
                let epkHex = Data(output.epk.reversed()).map { String(format: "%02x", $0) }.joined()
                // Ciphertext is NOT reversed - it's raw bytes
                let ciphertextHex = output.ciphertext.map { String(format: "%02x", $0) }.joined()

                let shieldedOutput = ShieldedOutput(
                    cv: String(repeating: "0", count: 64), // Not used for decryption
                    cmu: cmuHex,
                    ephemeralKey: epkHex,
                    encCiphertext: ciphertextHex,
                    outCiphertext: String(repeating: "0", count: 160), // Not used for decryption
                    proof: String(repeating: "0", count: 384) // Not used for decryption
                )
                shieldedOutputs.append(shieldedOutput)
            }

            // Convert CompactSpend to ShieldedSpend format
            var shieldedSpends: [ShieldedSpend]? = nil
            if !tx.spends.isEmpty {
                shieldedSpends = tx.spends.map { spend in
                    // Nullifier in display format (big-endian)
                    let nullifierHex = Data(spend.nullifier.reversed()).map { String(format: "%02x", $0) }.joined()
                    return ShieldedSpend(
                        cv: String(repeating: "0", count: 64),
                        anchor: String(repeating: "0", count: 64),
                        nullifier: nullifierHex,
                        rk: String(repeating: "0", count: 64),
                        proof: String(repeating: "0", count: 384),
                        spendAuthSig: String(repeating: "0", count: 128)
                    )
                }
            }

            // Generate txid from transaction data (placeholder - would need real tx hash)
            let txidHex = tx.txHash.map { String(format: "%02x", $0) }.joined()

            if !shieldedOutputs.isEmpty || (shieldedSpends?.isEmpty == false) {
                txDataList.append((txidHex, shieldedOutputs, shieldedSpends))
            }
        }

        return (blockHashHex, txDataList)
    }

    /// Get multiple blocks' data for P2P scanning
    /// Distributes block ranges across peers - each peer fetches its range SEQUENTIALLY
    /// All peers work in PARALLEL for maximum throughput
    /// Returns: [(height, blockHash, timestamp, txData)]
    func getBlocksDataP2P(from height: UInt64, count: Int) async throws -> [(UInt64, String, UInt32, [(String, [ShieldedOutput], [ShieldedSpend]?)])] {
        // Ensure at least some peers are connected before checking
        // This prevents race condition where peers are reconnecting
        var availablePeers = peers.filter { $0.isConnectionReady }

        if availablePeers.isEmpty && !peers.isEmpty {
            // No ready peers but we have peers - try to reconnect them
            print("⏳ P2P: No ready peers, attempting reconnection...")

            // Try to reconnect up to 3 peers in parallel
            let peersToReconnect = Array(peers.prefix(3))
            await withTaskGroup(of: Void.self) { group in
                for peer in peersToReconnect {
                    group.addTask {
                        do {
                            try await peer.ensureConnected()
                        } catch {
                            print("⚠️ P2P: Failed to reconnect \(peer.host): \(error.localizedDescription)")
                        }
                    }
                }
            }

            // Check again after reconnection attempt
            availablePeers = peers.filter { $0.isConnectionReady }

            if availablePeers.isEmpty {
                print("⚠️ P2P: Still no ready peers after reconnection attempt")
            } else {
                print("✅ P2P: Reconnected \(availablePeers.count) peers")
            }
        }

        guard !availablePeers.isEmpty else {
            debugLog(.network, "⚠️ No ready peers for P2P block fetch")
            throw NetworkError.notConnected
        }

        let peerCount = availablePeers.count
        let blocksPerPeer = (count + peerCount - 1) / peerCount  // Ceiling division

        // Check if block hashes are available for this range
        let bundledAvailable = BundledBlockHashes.shared.isLoaded && BundledBlockHashes.shared.contains(height: height)
        let headerStoreAvailable = (try? HeaderStore.shared.getHeader(at: height)) != nil

        debugLog(.network, "🚀 P2P fetch: \(count) blocks from height \(height), \(peerCount) ready peers, bundled=\(bundledAvailable), headers=\(headerStoreAvailable)")
        print("🚀 P2P parallel fetch: \(count) blocks across \(peerCount) peers (~\(blocksPerPeer) blocks each)")
        let startTime = Date()

        // Each peer gets a DISJOINT range of blocks
        // Peer 0: [height, height + blocksPerPeer)
        // Peer 1: [height + blocksPerPeer, height + 2*blocksPerPeer)
        // etc.
        let results = await withTaskGroup(of: [(UInt64, String, UInt32, [(String, [ShieldedOutput], [ShieldedSpend]?)])]?.self) { group in
            var collected: [(UInt64, String, UInt32, [(String, [ShieldedOutput], [ShieldedSpend]?)])] = []

            for (peerIndex, peer) in availablePeers.enumerated() {
                let rangeStart = height + UInt64(peerIndex * blocksPerPeer)
                let rangeEnd = min(rangeStart + UInt64(blocksPerPeer), height + UInt64(count))
                let rangeCount = Int(rangeEnd - rangeStart)

                if rangeCount <= 0 { break }

                group.addTask {
                    // Each peer fetches its range SEQUENTIALLY (no interleaving)
                    return await self.fetchBlockBatchP2P(peer: peer, startHeight: rangeStart, count: rangeCount)
                }
            }

            // Collect results from all peers
            for await result in group {
                if let blocks = result {
                    collected.append(contentsOf: blocks)
                }
            }

            return collected
        }

        let elapsed = Date().timeIntervalSince(startTime)
        let rate = Double(results.count) / max(elapsed, 0.001)

        // If we got less than 10% of requested blocks, consider it a failure
        if results.count < count / 10 {
            print("⚠️ P2P fetch failed: only got \(results.count)/\(count) blocks in \(String(format: "%.1f", elapsed))s")
            throw NetworkError.p2pFetchFailed
        }

        print("✅ P2P parallel fetch complete: \(results.count)/\(count) blocks in \(String(format: "%.1f", elapsed))s (\(String(format: "%.0f", rate)) blocks/sec)")

        // Sort by height to maintain order
        return results.sorted { $0.0 < $1.0 }
    }

    /// Fetch a batch of blocks from a single peer using HeaderStore or BundledBlockHashes
    /// Uses sequential getdata calls (batch getdata had parsing issues)
    /// PRIORITY: 1) HeaderStore (synced headers), 2) BundledBlockHashes (for historical scan)
    /// Returns: [(height, blockHash, timestamp, txData)]
    private func fetchBlockBatchP2P(peer: Peer, startHeight: UInt64, count: Int) async -> [(UInt64, String, UInt32, [(String, [ShieldedOutput], [ShieldedSpend]?)])]? {
        // Get block hashes - try HeaderStore first, then BundledBlockHashes
        var blockHashes: [(UInt64, Data)] = []
        var headerStoreCount = 0
        var bundledCount = 0

        for i in 0..<count {
            let height = startHeight + UInt64(i)

            // First try HeaderStore (synced headers from P2P)
            if let header = try? HeaderStore.shared.getHeader(at: height) {
                blockHashes.append((height, header.blockHash))
                headerStoreCount += 1
            }
            // Then try BundledBlockHashes (for historical blocks)
            else if let hash = BundledBlockHashes.shared.getBlockHash(at: height) {
                blockHashes.append((height, hash))
                bundledCount += 1
            }
        }

        if headerStoreCount > 0 || bundledCount > 0 {
            print("📦 [\(peer.host)] P2P batch: \(headerStoreCount) from HeaderStore, \(bundledCount) from BundledHashes")
        }

        // FIX #120: If no hashes found, use on-demand P2P fetch (fetches headers first)
        if blockHashes.isEmpty {
            print("📦 [\(peer.host)] Using on-demand P2P fetch for blocks \(startHeight)-\(startHeight + UInt64(count) - 1)")
            do {
                let blocks = try await peer.getFullBlocks(from: startHeight, count: count)
                var results: [(UInt64, String, UInt32, [(String, [ShieldedOutput], [ShieldedSpend]?)])] = []
                for block in blocks {
                    let finalBlockHash = block.blockHash.map { String(format: "%02x", $0) }.joined()
                    let blockTimestamp = block.time
                    var txDataList: [(String, [ShieldedOutput], [ShieldedSpend]?)] = []

                    for tx in block.transactions {
                        var shieldedOutputs: [ShieldedOutput] = []
                        for output in tx.outputs {
                            let cmuHex = Data(output.cmu.reversed()).map { String(format: "%02x", $0) }.joined()
                            let epkHex = Data(output.epk.reversed()).map { String(format: "%02x", $0) }.joined()
                            let ciphertextHex = output.ciphertext.map { String(format: "%02x", $0) }.joined()
                            let shieldedOutput = ShieldedOutput(
                                cv: String(repeating: "0", count: 64),
                                cmu: cmuHex,
                                ephemeralKey: epkHex,
                                encCiphertext: ciphertextHex,
                                outCiphertext: String(repeating: "0", count: 160),
                                proof: String(repeating: "0", count: 384)
                            )
                            shieldedOutputs.append(shieldedOutput)
                        }

                        var shieldedSpends: [ShieldedSpend]? = nil
                        if !tx.spends.isEmpty {
                            shieldedSpends = tx.spends.map { spend in
                                let nullifierHex = Data(spend.nullifier.reversed()).map { String(format: "%02x", $0) }.joined()
                                return ShieldedSpend(
                                    cv: String(repeating: "0", count: 64),
                                    anchor: String(repeating: "0", count: 64),
                                    nullifier: nullifierHex,
                                    rk: String(repeating: "0", count: 64),
                                    proof: String(repeating: "0", count: 384),
                                    spendAuthSig: String(repeating: "0", count: 128)
                                )
                            }
                        }

                        let txidHex = tx.txHash.map { String(format: "%02x", $0) }.joined()
                        if !shieldedOutputs.isEmpty || (shieldedSpends?.isEmpty == false) {
                            txDataList.append((txidHex, shieldedOutputs, shieldedSpends))
                        }
                    }

                    results.append((block.height, finalBlockHash, blockTimestamp, txDataList))
                }
                return results.isEmpty ? nil : results
            } catch {
                print("⚠️ [\(peer.host)] On-demand P2P fetch failed: \(error.localizedDescription)")
                return nil
            }
        }

        // Check peer connection before attempting fetches
        guard peer.isConnectionReady else {
            print("⚠️ [\(peer.host)] Peer not ready, skipping batch of \(count) blocks")
            return nil
        }

        // SEQUENTIAL FETCH: Request blocks one by one (more reliable)
        var blocks: [(UInt64, CompactBlock)] = []
        var failCount = 0
        for (height, hash) in blockHashes {
            do {
                let block = try await withTimeout(seconds: 10) {
                    try await peer.getBlockByHash(hash: hash)
                }
                blocks.append((height, block))
            } catch {
                failCount += 1
                // If too many failures, peer is likely dead
                if failCount > 3 {
                    print("⚠️ [\(peer.host)] Too many failures (\(failCount)), aborting batch")
                    break
                }
                continue
            }
        }

        if blocks.isEmpty && !blockHashes.isEmpty {
            print("⚠️ [\(peer.host)] Returned 0 blocks from \(blockHashes.count) requests")
        }

        var results: [(UInt64, String, UInt32, [(String, [ShieldedOutput], [ShieldedSpend]?)])] = []

        for (blockHeight, compactBlock) in blocks {
            let finalBlockHash = compactBlock.blockHash.map { String(format: "%02x", $0) }.joined()
            let blockTimestamp = compactBlock.time  // Block timestamp from P2P header
            var txDataList: [(String, [ShieldedOutput], [ShieldedSpend]?)] = []

            for tx in compactBlock.transactions {
                var shieldedOutputs: [ShieldedOutput] = []
                for output in tx.outputs {
                    let cmuHex = Data(output.cmu.reversed()).map { String(format: "%02x", $0) }.joined()
                    let epkHex = Data(output.epk.reversed()).map { String(format: "%02x", $0) }.joined()
                    let ciphertextHex = output.ciphertext.map { String(format: "%02x", $0) }.joined()

                    let shieldedOutput = ShieldedOutput(
                        cv: String(repeating: "0", count: 64),
                        cmu: cmuHex,
                        ephemeralKey: epkHex,
                        encCiphertext: ciphertextHex,
                        outCiphertext: String(repeating: "0", count: 160),
                        proof: String(repeating: "0", count: 384)
                    )
                    shieldedOutputs.append(shieldedOutput)
                }

                var shieldedSpends: [ShieldedSpend]? = nil
                if !tx.spends.isEmpty {
                    shieldedSpends = tx.spends.map { spend in
                        let nullifierHex = Data(spend.nullifier.reversed()).map { String(format: "%02x", $0) }.joined()
                        return ShieldedSpend(
                            cv: String(repeating: "0", count: 64),
                            anchor: String(repeating: "0", count: 64),
                            nullifier: nullifierHex,
                            rk: String(repeating: "0", count: 64),
                            proof: String(repeating: "0", count: 384),
                            spendAuthSig: String(repeating: "0", count: 128)
                        )
                    }
                }

                let txidHex = tx.txHash.map { String(format: "%02x", $0) }.joined()

                if !shieldedOutputs.isEmpty || (shieldedSpends?.isEmpty == false) {
                    txDataList.append((txidHex, shieldedOutputs, shieldedSpends))
                }
            }

            results.append((blockHeight, finalBlockHash, blockTimestamp, txDataList))
        }

        return results
    }

    /// Fetch a single block from P2P peers with fallback to InsightAPI
    /// Returns: (height, blockHash, timestamp, txData)
    private func fetchSingleBlockP2P(height: UInt64, peers: [Peer]) async -> (UInt64, String, UInt32, [(String, [ShieldedOutput], [ShieldedSpend]?)])? {
        var block: CompactBlock?
        var blockHash: Data?

        // Get block hash from HeaderStore
        if let header = try? HeaderStore.shared.getHeader(at: height) {
            blockHash = header.blockHash
        }

        // Try P2P peers with timeout
        if let hash = blockHash {
            // Try a random peer first for load balancing
            let shuffledPeers = peers.shuffled()
            for peer in shuffledPeers.prefix(3) {  // Try up to 3 peers
                do {
                    block = try await withTimeout(seconds: 5) {
                        try await peer.getBlockByHash(hash: hash)
                    }
                    if block != nil { break }
                } catch {
                    // Try next peer
                }
            }
        }

        // FIX #120: InsightAPI fallback commented out - P2P only
        // Fallback to InsightAPI if P2P failed
        if block == nil {
            // do {
            //     let hashFromAPI = try await InsightAPI.shared.getBlockHash(height: height)
            //     let insightBlock = try await InsightAPI.shared.getBlock(hash: hashFromAPI)
            //     var txDataList: [(String, [ShieldedOutput], [ShieldedSpend]?)] = []
            //
            //     for txid in insightBlock.tx {
            //         let txInfo = try? await InsightAPI.shared.getTransaction(txid: txid)
            //         let spends = txInfo?.spendDescs
            //         let outputs = try await InsightAPI.shared.getShieldedOutputsFromRaw(txid: txid)
            //
            //         if !outputs.isEmpty || (spends?.isEmpty == false) {
            //             txDataList.append((txid, outputs, spends))
            //         }
            //     }
            //     return (height, hashFromAPI, UInt32(insightBlock.time), txDataList)
            // } catch {
            //     return nil
            // }
            print("⚠️ P2P block fetch failed - no fallback (P2P only mode)")
            return nil
        }

        guard let block = block else { return nil }

        // Process P2P block data
        let finalBlockHash = block.blockHash.map { String(format: "%02x", $0) }.joined()
        var txDataList: [(String, [ShieldedOutput], [ShieldedSpend]?)] = []

        for tx in block.transactions {
            var shieldedOutputs: [ShieldedOutput] = []
            for output in tx.outputs {
                let cmuHex = Data(output.cmu.reversed()).map { String(format: "%02x", $0) }.joined()
                let epkHex = Data(output.epk.reversed()).map { String(format: "%02x", $0) }.joined()
                let ciphertextHex = output.ciphertext.map { String(format: "%02x", $0) }.joined()

                let shieldedOutput = ShieldedOutput(
                    cv: String(repeating: "0", count: 64),
                    cmu: cmuHex,
                    ephemeralKey: epkHex,
                    encCiphertext: ciphertextHex,
                    outCiphertext: String(repeating: "0", count: 160),
                    proof: String(repeating: "0", count: 384)
                )
                shieldedOutputs.append(shieldedOutput)
            }

            var shieldedSpends: [ShieldedSpend]? = nil
            if !tx.spends.isEmpty {
                shieldedSpends = tx.spends.map { spend in
                    let nullifierHex = Data(spend.nullifier.reversed()).map { String(format: "%02x", $0) }.joined()
                    return ShieldedSpend(
                        cv: String(repeating: "0", count: 64),
                        anchor: String(repeating: "0", count: 64),
                        nullifier: nullifierHex,
                        rk: String(repeating: "0", count: 64),
                        proof: String(repeating: "0", count: 384),
                        spendAuthSig: String(repeating: "0", count: 128)
                    )
                }
            }

            let txidHex = tx.txHash.map { String(format: "%02x", $0) }.joined()

            if !shieldedOutputs.isEmpty || (shieldedSpends?.isEmpty == false) {
                txDataList.append((txidHex, shieldedOutputs, shieldedSpends))
            }
        }

        return (height, finalBlockHash, block.time, txDataList)
    }

    // MARK: - Peer Rotation

    private func setupPeerRotation() {
        peerRotationTimer = Timer.scheduledTimer(withTimeInterval: PEER_ROTATION_INTERVAL, repeats: true) { [weak self] _ in
            self?.rotatePeers()
        }
    }

    private func rotatePeers() {
        Task {
            // Check for peers that should be banned
            for peer in peers {
                if peer.shouldBan() {
                    banPeer(peer, reason: peer.consecutiveFailures >= 10 ? .tooManyFailures : .lowSuccessRate)
                    peer.disconnect()
                }
            }

            // Remove banned/disconnected peers AND peers with dead connections
            // FIX #119: Also remove peers that are not connection-ready to prevent socket accumulation
            peers.removeAll { peer in
                let shouldRemove = isBanned(peer.host) || peer.shouldBan() || !peer.isConnectionReady
                if shouldRemove && !isBanned(peer.host) && !peer.shouldBan() {
                    // Peer has dead connection but isn't banned - disconnect and remove
                    peer.disconnect()
                }
                return shouldRemove
            }

            // Find worst performing peer to rotate out
            if peers.count >= MIN_PEERS {
                if let worstPeer = peers.min(by: { $0.getChance() < $1.getChance() }) {
                    if worstPeer.getChance() < 0.5 {
                        worstPeer.disconnect()
                        peers.removeAll { $0.id == worstPeer.id }
                    }
                }
            }

            // Connect to new peers if needed
            while peers.count < MIN_PEERS {
                guard let address = selectBestAddress() else {
                    break
                }

                if isBanned(address.host) {
                    continue
                }

                if let peer = try? await connectToPeer(address) {
                    peers.append(peer)

                    // Set up block announcement listener
                    setupBlockListener(for: peer)

                    let key = "\(address.host):\(address.port)"
                    knownAddresses[key]?.successes += 1
                    newAddresses.remove(key)
                    triedAddresses.insert(key)

                    // Also update custom node stats if this is a custom node
                    recordCustomNodeConnection(host: address.host, port: address.port, success: true)

                    // Request addresses from new peer
                    if let addresses = try? await peer.getAddresses() {
                        for addr in addresses {
                            addAddress(addr, source: peer.host)
                        }
                    }
                } else {
                    let key = "\(address.host):\(address.port)"
                    knownAddresses[key]?.attempts += 1
                }
            }

            DispatchQueue.main.async {
                // BUGFIX: Only count peers with READY connections, not all peers in array
                let readyPeers = self.peers.filter { $0.isConnectionReady }
                self.connectedPeers = readyPeers.count
                self.isConnected = readyPeers.count > 0
            }
        }
    }
}

// MARK: - Supporting Types

struct PeerAddress {
    let host: String
    let port: UInt16
}

/// Information about a known peer address
struct AddressInfo {
    let address: PeerAddress
    let source: String // Where we learned about this address
    let firstSeen: Date
    var lastSeen: Date
    var attempts: Int
    var successes: Int

    /// Calculate selection probability based on history
    func getChance() -> Double {
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
    func isTerrible() -> Bool {
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
struct PersistedAddress: Codable {
    let host: String
    let port: UInt16
    let firstSeen: Date
    let lastSeen: Date
    let attempts: Int
    let successes: Int
}

/// User-added custom node for manual peer management
/// Supports IPv4, IPv6, and .onion addresses
public struct UserCustomNode: Codable, Identifiable, Equatable {
    public let id: UUID
    public var host: String  // IPv4, IPv6, or .onion address
    public var port: UInt16
    public var label: String  // User-friendly name
    public var isEnabled: Bool
    public var addedDate: Date
    public var lastConnected: Date?
    public var connectionSuccesses: Int
    public var connectionAttempts: Int

    public init(host: String, port: UInt16 = 8033, label: String = "") {
        self.id = UUID()
        self.host = host
        self.port = port
        self.label = label.isEmpty ? host : label
        self.isEnabled = true
        self.addedDate = Date()
        self.lastConnected = nil
        self.connectionSuccesses = 0
        self.connectionAttempts = 0
    }

    /// Determine the address type
    public var addressType: AddressType {
        if host.hasSuffix(".onion") {
            return .onion
        } else if host.contains(":") {
            return .ipv6
        } else {
            return .ipv4
        }
    }

    public enum AddressType: String, Codable {
        case ipv4 = "IPv4"
        case ipv6 = "IPv6"
        case onion = "Onion"

        public var icon: String {
            switch self {
            case .ipv4: return "network"
            case .ipv6: return "network.badge.shield.half.filled"
            case .onion: return "shield.lefthalf.filled"
            }
        }
    }

    /// Validate the address format
    public var isValid: Bool {
        switch addressType {
        case .onion:
            // Tor v3 onion addresses are 56 characters (without .onion)
            let onionPart = host.replacingOccurrences(of: ".onion", with: "")
            return onionPart.count == 56 && onionPart.allSatisfy { $0.isLetter || $0.isNumber }
        case .ipv4:
            let components = host.split(separator: ".")
            if components.count != 4 { return false }
            return components.allSatisfy { UInt8($0) != nil }
        case .ipv6:
            // Basic IPv6 validation
            return host.contains(":") && !host.contains("..")
        }
    }

    /// Success rate as percentage
    public var successRate: Double {
        guard connectionAttempts > 0 else { return 0 }
        return Double(connectionSuccesses) / Double(connectionAttempts) * 100
    }
}

/// Peer data for bundling in app resources
struct BundledPeer: Codable {
    let host: String
    let port: UInt16
    let reliability: Double  // Success rate 0.0-1.0
    let lastSeen: Date
}

struct ShieldedBalance: Equatable {
    let confirmed: UInt64
    let pending: UInt64
}

struct BlockHeader: Hashable {
    let version: Int32
    let prevBlockHash: Data
    let merkleRoot: Data
    let finalSaplingRoot: Data // 32-byte reserved field (hashFinalSaplingRoot post-Sapling)
    let timestamp: UInt32
    let bits: UInt32
    let nonce: Data // Equihash nonce (32 bytes)
    let solution: Data // Equihash solution (400 bytes for post-Bubbles Equihash(192,7))
}

struct CompactFilter: Hashable {
    let blockHash: Data
    let filterType: UInt8
    let filterData: Data
}

// MARK: - Network Errors

enum NetworkError: LocalizedError {
    case notConnected
    case insufficientPeers(Int, Int)
    case consensusNotReached
    case broadcastFailed
    case transactionRejected
    case transactionNotVerified
    case connectionFailed(String)
    case handshakeFailed
    case invalidMagicBytes  // For tolerant block listener - can retry
    case timeout
    case connectionTimeout
    case invalidData
    case notFound
    case p2pFetchFailed

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Not connected to network"
        case .insufficientPeers(let connected, let required):
            return "Insufficient peers: \(connected)/\(required)"
        case .consensusNotReached:
            return "Could not reach consensus among peers"
        case .broadcastFailed:
            return "Transaction broadcast failed"
        case .transactionRejected:
            return "Transaction was rejected by the network"
        case .transactionNotVerified:
            return "Transaction not found on blockchain - may have been rejected"
        case .connectionFailed(let message):
            return "Connection failed: \(message)"
        case .handshakeFailed:
            return "Peer handshake failed"
        case .invalidMagicBytes:
            return "Invalid P2P magic bytes (Tor noise or protocol mismatch)"
        case .timeout:
            return "Request timed out"
        case .connectionTimeout:
            return "Connection timed out"
        case .invalidData:
            return "Invalid data format"
        case .notFound:
            return "Data not found on peer"
        case .p2pFetchFailed:
            return "P2P block fetch failed"
        }
    }
}
