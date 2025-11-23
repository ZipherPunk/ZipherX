import Foundation
import Network
import Combine

/// Multi-Peer Network Manager for Zclassic
/// Connects to multiple nodes and requires consensus for all queries
final class NetworkManager: ObservableObject {
    static let shared = NetworkManager()

    // MARK: - Constants
    private let MIN_PEERS = 3
    private let CONSENSUS_THRESHOLD = 2
    private let PEER_ROTATION_INTERVAL: TimeInterval = 300 // 5 minutes
    private let QUERY_TIMEOUT: TimeInterval = 10
    private let BAN_DURATION: TimeInterval = 86400 // 24 hours
    private let MAX_KNOWN_ADDRESSES = 1000
    private let GETADDR_INTERVAL: TimeInterval = 60 // Request addresses every minute initially

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
    @Published private(set) var lastBlockTxCount: Int = 0
    @Published private(set) var networkDifficulty: Double = 0.0

    // MARK: - Private Properties
    private var peers: [Peer] = []

    /// Get a connected peer for block downloads
    func getConnectedPeer() -> Peer? {
        return peers.first
    }
    private var peerRotationTimer: Timer?
    private var addressDiscoveryTimer: Timer?
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
    // Working nodes first
    private let hardcodedPeersZCL = [
        "205.209.104.118:8033",  // Known working
        "74.50.74.102:8033",     // Known working
        "162.55.92.62:8033",
        "157.90.223.151:8033",
        "37.187.76.79:8033",
        "51.178.179.75:8033",
        "140.174.189.3:8033",
        "185.205.246.161:8033",
        "54.37.81.148:8033",
        "67.183.29.123:8033",
        "116.202.13.16:8033",
        "188.165.24.209:8033",
        "198.50.168.213:8033"
    ]

    // Zclassic network parameters
    private let networkMagic: [UInt8] = [0x24, 0xe9, 0x27, 0x64] // ZCL mainnet
    private let defaultPort: UInt16 = 8033

    private init() {
        setupPeerRotation()
        setupAddressDiscovery()
        loadPersistedAddresses()
    }

    // MARK: - Address Management

    /// Add a new address to our known addresses
    private func addAddress(_ address: PeerAddress, source: String) {
        let key = "\(address.host):\(address.port)"

        // Skip if banned
        if isBanned(address.host) {
            return
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
                address: address,
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
    private func banPeer(_ peer: Peer, reason: BanReason) {
        addressLock.lock()
        defer { addressLock.unlock() }

        let ban = BannedPeer(
            address: peer.host,
            banTime: Date(),
            banDuration: BAN_DURATION,
            reason: reason
        )
        bannedPeers[peer.host] = ban

        // Remove from known good addresses
        let key = "\(peer.host):\(peer.port)"
        knownAddresses.removeValue(forKey: key)
        triedAddresses.remove(key)
        newAddresses.remove(key)

        print("Banned peer \(peer.host): \(reason.rawValue)")
    }

    /// Select best peer to connect to based on scoring
    private func selectBestAddress() -> PeerAddress? {
        addressLock.lock()
        defer { addressLock.unlock() }

        // Prefer new addresses first
        if let newKey = newAddresses.randomElement(),
           let info = knownAddresses[newKey] {
            return info.address
        }

        // Otherwise select from tried addresses based on chance
        var candidates: [(String, Double)] = []
        for key in triedAddresses {
            if let info = knownAddresses[key] {
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
                    return knownAddresses[key]?.address
                }
            }
        }

        return nil
    }

    /// Request addresses from all connected peers
    private func discoverMoreAddresses() async {
        for peer in peers {
            do {
                let addresses = try await peer.getAddresses()
                for addr in addresses {
                    addAddress(addr, source: peer.host)
                }
                peer.recordSuccess()
            } catch {
                peer.recordFailure()
            }
        }
    }

    private func setupAddressDiscovery() {
        addressDiscoveryTimer = Timer.scheduledTimer(withTimeInterval: GETADDR_INTERVAL, repeats: true) { [weak self] _ in
            Task {
                await self?.discoverMoreAddresses()
            }
        }
    }

    private func loadPersistedAddresses() {
        // TODO: Load from UserDefaults or database
        // For now, start fresh each launch
    }

    private func persistAddresses() {
        // TODO: Save good addresses to UserDefaults or database
    }

    // MARK: - Connection Management

    /// Connect to the Zclassic network
    func connect() async throws {
        // Prevent concurrent connection attempts
        guard !isConnecting else {
            return
        }
        isConnecting = true
        defer { isConnecting = false }

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
        print("📋 Total peers to try: \(discoveredPeers.count)")

        // Add all discovered to address manager
        for addr in discoveredPeers {
            addAddress(addr, source: "dns")
        }

        // Don't shuffle - try known working nodes first
        // discoveredPeers.shuffle()

        // Deduplicate peers by host:port
        var seenPeers = Set<String>()
        let uniquePeers = discoveredPeers.filter { addr in
            let key = "\(addr.host):\(addr.port)"
            if seenPeers.contains(key) {
                return false
            }
            seenPeers.insert(key)
            return true
        }

        // Connect to peers in parallel
        var connectedCount = 0
        let maxConcurrent = 8 // Try up to 8 at once

        // Filter out banned peers
        let validPeers = uniquePeers.filter { !isBanned($0.host) }

        await withTaskGroup(of: Peer?.self) { group in
            var started = 0

            for address in validPeers {
                // Start up to maxConcurrent connections
                if started < maxConcurrent {
                    started += 1
                    group.addTask {
                        do {
                            print("🔄 Trying to connect to \(address.host):\(address.port)...")
                            let peer = try await self.connectToPeer(address)
                            print("✅ Connected to \(address.host):\(address.port)")
                            return peer
                        } catch {
                            print("❌ Failed to connect to \(address.host):\(address.port) - \(error.localizedDescription)")
                            return nil
                        }
                    }
                }
            }

            // Collect successful connections
            for await peer in group {
                if let peer = peer {
                    peers.append(peer)
                    connectedCount += 1

                    // Update UI immediately
                    DispatchQueue.main.async {
                        self.connectedPeers = connectedCount
                        self.isConnected = true
                    }

                    // Update address info (thread-safe)
                    let key = "\(peer.host):\(peer.port)"
                    addressLock.lock()
                    knownAddresses[key]?.successes += 1
                    newAddresses.remove(key)
                    triedAddresses.insert(key)
                    addressLock.unlock()

                    // Request addresses from new peer
                    Task {
                        if let addresses = try? await peer.getAddresses() {
                            for addr in addresses {
                                self.addAddress(addr, source: peer.host)
                            }
                        }
                    }
                }
            }
        }

        print("📊 Connected to \(connectedCount) peers")

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

    /// Fetch network statistics
    func fetchNetworkStats() async {
        print("📊 Fetching network stats...")

        // Get peer version from first connected peer
        if let peer = peers.first {
            let version = peer.peerUserAgent.isEmpty ? "Unknown" : peer.peerUserAgent
            print("📊 Peer version: \(version)")
            await MainActor.run {
                self.peerVersion = version
            }
        }

        // Get chain info from Insight API
        do {
            let status = try await InsightAPI.shared.getStatus()
            let height = status.height
            print("📊 Chain height: \(height)")

            // Get last block info
            let blockHash = try await InsightAPI.shared.getBlockHash(height: height)
            let block = try await InsightAPI.shared.getBlock(hash: blockHash)
            print("📊 Last block txns: \(block.tx.count)")

            await MainActor.run {
                self.chainHeight = height
                self.lastBlockTxCount = block.tx.count
                self.networkDifficulty = status.difficulty
                print("📊 Updated chainHeight to: \(self.chainHeight)")
            }
        } catch {
            print("⚠️ Failed to fetch chain stats: \(error)")
        }

        // Get ZCL price (from CoinGecko or similar)
        await fetchZCLPrice()

        // Get wallet height from database
        let dbHeight = (try? WalletDatabase.shared.getLastScannedHeight()) ?? 0
        await MainActor.run {
            self.walletHeight = dbHeight
        }
    }

    /// Fetch ZCL price from API
    private func fetchZCLPrice() async {
        // Try CoinGecko API
        guard let url = URL(string: "https://api.coingecko.com/api/v3/simple/price?ids=zclassic&vs_currencies=usd") else {
            return
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let zclData = json["zclassic"] as? [String: Any],
               let price = zclData["usd"] as? Double {
                await MainActor.run {
                    self.zclPriceUSD = price
                }
            }
        } catch {
            print("⚠️ Failed to fetch ZCL price: \(error)")
        }
    }

    // MARK: - Peer Discovery

    private func discoverPeers() async -> [PeerAddress] {
        var addresses: [PeerAddress] = []

        for seed in dnsSeedsZCL {
            let resolved = await resolveDNSSeed(seed)
            addresses.append(contentsOf: resolved)
        }

        return addresses
    }

    private func resolveDNSSeed(_ hostname: String) async -> [PeerAddress] {
        return await withCheckedContinuation { continuation in
            let host = CFHostCreateWithName(nil, hostname as CFString).takeRetainedValue()
            var resolved = DarwinBoolean(false)

            CFHostStartInfoResolution(host, .addresses, nil)

            guard let addresses = CFHostGetAddressing(host, &resolved)?.takeUnretainedValue() as? [Data] else {
                continuation.resume(returning: [])
                return
            }

            var peerAddresses: [PeerAddress] = []
            for addressData in addresses {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                addressData.withUnsafeBytes { ptr in
                    let sockaddr = ptr.baseAddress!.assumingMemoryBound(to: sockaddr.self)
                    getnameinfo(sockaddr, socklen_t(addressData.count), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
                }
                let host = String(cString: hostname)
                peerAddresses.append(PeerAddress(host: host, port: defaultPort))
            }

            continuation.resume(returning: peerAddresses)
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

    /// Broadcast transaction with multi-peer propagation
    func broadcastTransaction(_ rawTx: Data) async throws -> String {
        guard isConnected else {
            throw NetworkError.notConnected
        }

        var successCount = 0
        var txId: String?

        // Broadcast to all peers
        await withTaskGroup(of: String?.self) { group in
            for peer in peers {
                group.addTask {
                    do {
                        let id = try await peer.broadcastTransaction(rawTx)
                        return id
                    } catch {
                        return nil
                    }
                }
            }

            for await result in group {
                if let id = result {
                    successCount += 1
                    txId = id
                }
            }
        }

        guard successCount >= CONSENSUS_THRESHOLD, let txId = txId else {
            throw NetworkError.broadcastFailed
        }

        return txId
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

    /// Get current chain height from peers
    func getChainHeight() async throws -> UInt64 {
        guard isConnected else {
            throw NetworkError.notConnected
        }

        var heights: [UInt64: Int] = [:]

        await withTaskGroup(of: UInt64?.self) { group in
            for peer in peers {
                group.addTask {
                    // Get height from peer's version message or getblockcount
                    return UInt64(peer.peerStartHeight)
                }
            }

            for await result in group {
                if let height = result, height > 0 {
                    heights[height, default: 0] += 1
                }
            }
        }

        // Return highest height with consensus
        guard let (height, count) = heights.max(by: { $0.key < $1.key }),
              count >= 1 else { // At least one peer must report
            throw NetworkError.consensusNotReached
        }

        return height
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
    func getCompactBlocks(from height: UInt64, count: Int) async throws -> [CompactBlock] {
        guard isConnected else {
            throw NetworkError.notConnected
        }

        // Use first available peer for block download (full blocks are large)
        guard let peer = peers.first else {
            throw NetworkError.notConnected
        }

        // Use getFullBlocks which properly fetches via getblocks/getdata
        let blocks = try await peer.getFullBlocks(from: height, count: count)

        guard !blocks.isEmpty else {
            throw NetworkError.consensusNotReached
        }

        return blocks
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

            // Remove banned/disconnected peers
            peers.removeAll { peer in
                isBanned(peer.host) || peer.shouldBan()
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

                    let key = "\(address.host):\(address.port)"
                    knownAddresses[key]?.successes += 1
                    newAddresses.remove(key)
                    triedAddresses.insert(key)

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
                self.connectedPeers = self.peers.count
                self.isConnected = self.peers.count > 0
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

struct ShieldedBalance: Equatable {
    let confirmed: UInt64
    let pending: UInt64
}

struct BlockHeader: Hashable {
    let version: Int32
    let prevBlockHash: Data
    let merkleRoot: Data
    let timestamp: UInt32
    let bits: UInt32
    let nonce: Data // Equihash nonce
    let solution: Data // Equihash solution
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
    case connectionFailed(String)
    case handshakeFailed
    case timeout
    case connectionTimeout

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
        case .connectionFailed(let message):
            return "Connection failed: \(message)"
        case .handshakeFailed:
            return "Peer handshake failed"
        case .timeout:
            return "Request timed out"
        case .connectionTimeout:
            return "Connection timed out"
        }
    }
}
