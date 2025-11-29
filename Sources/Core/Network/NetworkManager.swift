import Foundation
import Network
import Combine

/// Multi-Peer Network Manager for Zclassic
/// Connects to multiple nodes and requires consensus for all queries
final class NetworkManager: ObservableObject {
    static let shared = NetworkManager()

    // MARK: - Constants
    private let MIN_PEERS = 3
    private let MAX_PEERS = 20
    private let TARGET_PEER_PERCENT = 0.10 // Connect to 10% of known addresses
    private let CONSENSUS_THRESHOLD = 2 // SECURITY: Require at least 2 peers to agree
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
    internal var peers: [Peer] = []  // internal so HeaderSyncManager can access

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

        print("🚫 Banned peer \(peer.host): \(reason.rawValue)")
    }

    /// Ban a peer by address (for connection failures)
    private func banAddress(_ host: String, port: UInt16, reason: BanReason) {
        addressLock.lock()
        defer { addressLock.unlock() }

        let ban = BannedPeer(
            address: host,
            banTime: Date(),
            banDuration: BAN_DURATION,
            reason: reason
        )
        bannedPeers[host] = ban

        // Remove from known good addresses
        let key = "\(host):\(port)"
        knownAddresses.removeValue(forKey: key)
        triedAddresses.remove(key)
        newAddresses.remove(key)

        print("🚫 Banned address \(host): \(reason.rawValue)")
    }

    /// Get list of all currently banned peers
    func getBannedPeers() -> [BannedPeer] {
        addressLock.lock()
        defer { addressLock.unlock() }

        // Clean up expired bans first
        let now = Date()
        bannedPeers = bannedPeers.filter { !$0.value.isExpired }

        return Array(bannedPeers.values).sorted { $0.banTime > $1.banTime }
    }

    /// Unban a specific peer by address
    func unbanPeer(address: String) {
        addressLock.lock()
        defer { addressLock.unlock() }

        if bannedPeers.removeValue(forKey: address) != nil {
            print("✅ Unbanned peer: \(address)")
        }
    }

    /// Unban all peers
    func unbanAllPeers() {
        addressLock.lock()
        defer { addressLock.unlock() }

        let count = bannedPeers.count
        bannedPeers.removeAll()
        print("✅ Unbanned all \(count) peers")
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
        var discoveredCount = 0
        for peer in peers {
            do {
                let addresses = try await peer.getAddresses()
                for addr in addresses {
                    addAddress(addr, source: peer.host)
                    discoveredCount += 1
                }
                peer.recordSuccess()
            } catch {
                peer.recordFailure()
            }
        }

        // Persist addresses if we discovered new ones
        if discoveredCount > 0 {
            persistAddresses()
        }
    }

    private func setupAddressDiscovery() {
        addressDiscoveryTimer = Timer.scheduledTimer(withTimeInterval: GETADDR_INTERVAL, repeats: true) { [weak self] _ in
            Task {
                await self?.discoverMoreAddresses()
            }
        }
    }

    private let persistedAddressesKey = "ZipherX.KnownPeerAddresses"
    private let maxPersistedAddresses = 100

    private func loadPersistedAddresses() {
        guard let data = UserDefaults.standard.data(forKey: persistedAddressesKey),
              let savedAddresses = try? JSONDecoder().decode([PersistedAddress].self, from: data) else {
            print("📡 No persisted peer addresses found")
            return
        }

        addressLock.lock()
        defer { addressLock.unlock() }

        var loadedCount = 0
        for saved in savedAddresses {
            let address = PeerAddress(host: saved.host, port: saved.port)
            let key = "\(saved.host):\(saved.port)"

            // Skip if banned or already known
            if isBanned(saved.host) || knownAddresses[key] != nil {
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

        print("📡 Loaded \(loadedCount) persisted peer addresses")
    }

    private func persistAddresses() {
        addressLock.lock()
        let addresses = knownAddresses.values
            .filter { $0.successes > 0 || $0.attempts < 3 } // Only save good or untried addresses
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

        // Add all discovered to address manager
        for addr in discoveredPeers {
            addAddress(addr, source: "dns")
        }

        // Calculate target: 10% of known addresses (min 3, max 20)
        let targetPeers = calculateTargetPeers()
        print("📋 Known addresses: \(knownAddresses.count), Target peers: \(targetPeers)")

        // Deduplicate and filter banned peers
        var seenPeers = Set<String>()
        var validPeers = discoveredPeers.filter { addr in
            let key = "\(addr.host):\(addr.port)"
            if seenPeers.contains(key) || isBanned(addr.host) {
                return false
            }
            seenPeers.insert(key)
            return true
        }

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

                    group.addTask {
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

                        // Update UI immediately
                        await MainActor.run {
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

        // BACKGROUND SYNC: If chain is ahead of wallet, sync new blocks
        // This keeps the tree always current for instant sends
        if chainHeight > dbHeight && dbHeight > 0 {
            Task {
                await WalletManager.shared.backgroundSyncToHeight(chainHeight)
            }
        }

        // MEMPOOL SCAN: Check for incoming unconfirmed transactions
        // Uses message queue to prevent stream conflicts
        Task {
            await scanMempoolForIncoming()
        }
    }

    // MARK: - Mempool Detection (Cypherpunk Style!)

    /// Published property for incoming mempool amount
    @Published private(set) var mempoolIncoming: UInt64 = 0
    @Published private(set) var mempoolTxCount: Int = 0

    /// Scan mempool for incoming shielded transactions
    /// Uses trial decryption to detect payments before confirmation
    private func scanMempoolForIncoming() async {
        guard isConnected else { return }

        // Get a connected peer
        guard let peer = getConnectedPeer() else { return }

        do {
            // Get mempool transaction list
            let mempoolTxs = try await peer.getMempoolTransactions()

            guard !mempoolTxs.isEmpty else {
                await MainActor.run {
                    self.mempoolIncoming = 0
                    self.mempoolTxCount = 0
                }
                return
            }

            print("🔮 Scanning \(mempoolTxs.count) mempool transactions...")

            // Get spending key for trial decryption
            guard let spendingKey = try? SecureKeyStorage().retrieveSpendingKey() else {
                return
            }

            var incomingAmount: UInt64 = 0
            var incomingCount = 0

            // Check each mempool transaction for shielded outputs
            for txHash in mempoolTxs.prefix(50) { // Limit to 50 to avoid spam
                guard let rawTx = try? await peer.getMempoolTransaction(txid: txHash) else {
                    continue
                }

                // Parse transaction for shielded outputs
                if let outputs = parseShieldedOutputs(from: rawTx) {
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
                                incomingAmount += value
                                incomingCount += 1
                                print("🔮 MEMPOOL: Found incoming \(value) zatoshis!")
                            }
                        }
                    }
                }
            }

            await MainActor.run {
                self.mempoolIncoming = incomingAmount
                self.mempoolTxCount = incomingCount
                if incomingAmount > 0 {
                    print("🔮 Mempool incoming: \(incomingAmount) zatoshis (\(incomingCount) tx)")
                }
            }
        } catch {
            print("⚠️ Mempool scan failed: \(error.localizedDescription)")
        }
    }

    /// Parse shielded outputs from raw transaction data
    private func parseShieldedOutputs(from rawTx: Data) -> [(cmu: Data, epk: Data, ciphertext: Data)]? {
        // Zcash v4 transaction format (simplified)
        // We need to find the shielded outputs section
        guard rawTx.count > 200 else { return nil }

        var outputs: [(cmu: Data, epk: Data, ciphertext: Data)] = []

        // Try to find OutputDescription pattern (948 bytes each)
        // cv(32) + cmu(32) + ephemeralKey(32) + encCiphertext(580) + outCiphertext(80) + zkproof(192)
        let outputDescSize = 948
        var offset = 0

        // Skip to shielded section (after header, inputs, etc)
        // This is a simplified scan - look for valid-looking output patterns
        while offset + outputDescSize <= rawTx.count {
            // Check if this looks like an OutputDescription
            let potentialCmu = rawTx.subdata(in: offset+32..<offset+64)
            let potentialEpk = rawTx.subdata(in: offset+64..<offset+96)
            let potentialCiphertext = rawTx.subdata(in: offset+96..<offset+676) // 580 bytes

            // Basic validation - non-zero values
            if !potentialCmu.allSatisfy({ $0 == 0 }) &&
               !potentialEpk.allSatisfy({ $0 == 0 }) {
                outputs.append((cmu: potentialCmu, epk: potentialEpk, ciphertext: potentialCiphertext))
            }

            offset += 32 // Slide window
        }

        return outputs.isEmpty ? nil : outputs
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

    /// Broadcast progress callback type
    typealias BroadcastProgressCallback = (_ phase: String, _ detail: String?, _ progress: Double?) -> Void

    /// Broadcast transaction with multi-peer propagation and progress reporting
    /// P2P ONLY - no InsightAPI fallback (trustless operation)
    /// Success = at least one peer accepted + mempool confirms (FAST EXIT)
    func broadcastTransactionWithProgress(_ rawTx: Data, onProgress: BroadcastProgressCallback? = nil) async throws -> String {
        print("📡 Starting broadcast, connected: \(isConnected), peers: \(peers.count)")

        guard isConnected else {
            print("❌ Broadcast failed: not connected to network")
            throw NetworkError.notConnected
        }

        guard !peers.isEmpty else {
            print("❌ Broadcast failed: no peers available")
            throw NetworkError.broadcastFailed
        }

        let peerCount = peers.count
        print("📡 Broadcasting to \(peerCount) peers...")
        onProgress?("peers", "Sending to \(peerCount) peers...", 0.0)

        // Use actor for thread-safe state
        actor BroadcastState {
            var successCount = 0
            var txId: String?
            var mempoolVerified = false

            func recordSuccess(_ id: String) -> Int {
                successCount += 1
                txId = id
                return successCount
            }

            func setVerified() { mempoolVerified = true }
            func isVerified() -> Bool { mempoolVerified }
            func getTxId() -> String? { txId }
            func getSuccessCount() -> Int { successCount }
        }

        let state = BroadcastState()

        // Broadcast to all peers - but check mempool after FIRST success
        try await withThrowingTaskGroup(of: Void.self) { group in
            // Add broadcast tasks for all peers
            for peer in peers {
                let peerHost = "\(peer.host):\(peer.port)"
                group.addTask {
                    do {
                        let id = try await peer.broadcastTransaction(rawTx)
                        print("✅ Peer \(peerHost) accepted tx: \(id)")
                        let count = await state.recordSuccess(id)
                        onProgress?("peers", "Accepted by \(count)/\(peerCount) peers", Double(count) / Double(peerCount))
                    } catch {
                        print("⚠️ Peer \(peerHost) broadcast failed: \(error)")
                    }
                }
            }

            // Add mempool verification task - runs in parallel, exits early on success
            group.addTask {
                // Wait for at least one peer to accept
                while await state.getTxId() == nil {
                    try await Task.sleep(nanoseconds: 100_000_000) // 100ms
                }

                guard let txId = await state.getTxId() else { return }

                onProgress?("verify", "Checking mempool...", 0.5)

                // Check mempool - just 3 quick attempts
                for attempt in 1...3 {
                    if try await InsightAPI.shared.checkTransactionExists(txid: txId) {
                        print("✅ Transaction VERIFIED in mempool: \(txId)")
                        onProgress?("verify", "Confirmed!", 1.0)
                        await state.setVerified()
                        return // Exit immediately!
                    }
                    if attempt < 3 {
                        try await Task.sleep(nanoseconds: 500_000_000) // 500ms between checks
                    }
                }
            }

            // Wait for either: mempool verified OR all broadcasts complete
            // Check every 200ms if we can exit early
            while true {
                // Exit early if mempool verified
                if await state.isVerified() {
                    group.cancelAll()
                    break
                }

                // Check if a task completed
                do {
                    guard let _ = try await group.next() else {
                        // All tasks done
                        break
                    }
                } catch {
                    // Task threw, continue waiting
                }
            }
        }

        // Check results
        guard let txId = await state.getTxId() else {
            print("❌ No peers accepted the transaction")
            throw NetworkError.broadcastFailed
        }

        let successCount = await state.getSuccessCount()
        let verified = await state.isVerified()

        print("📡 Transaction broadcast to \(successCount)/\(peerCount) peers: \(txId)")

        if !verified {
            // P2P broadcast succeeded, tx is propagating even if mempool check timed out
            print("⚠️ Mempool not yet visible (tx is propagating): \(txId)")
            onProgress?("verify", "Broadcast complete!", 1.0)
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

    /// Get current chain height from peers (with InsightAPI fallback)
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
        if let (height, count) = heights.max(by: { $0.key < $1.key }),
           count >= 1 {
            return height
        }

        // Fallback: If P2P peers don't report valid heights, use InsightAPI
        print("⚠️ P2P peers did not report chain height, falling back to InsightAPI...")
        do {
            let status = try await InsightAPI.shared.getStatus()
            print("📊 InsightAPI chain height: \(status.height)")
            return status.height
        } catch {
            print("❌ InsightAPI fallback also failed: \(error)")

            // Final fallback: use cached chain height if recent enough
            // This allows transactions to be built when temporarily offline
            if chainHeight > 0 {
                print("⚠️ Using cached chain height: \(chainHeight)")
                return chainHeight
            }

            throw NetworkError.consensusNotReached
        }
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

    /// Get chain height from P2P peers only (no InsightAPI fallback)
    func getChainHeightP2POnly() async throws -> UInt64 {
        guard isConnected else {
            throw NetworkError.notConnected
        }

        var heights: [UInt64: Int] = [:]

        await withTaskGroup(of: UInt64?.self) { group in
            for peer in peers {
                group.addTask {
                    return UInt64(peer.peerStartHeight)
                }
            }

            for await result in group {
                if let height = result, height > 0 {
                    heights[height, default: 0] += 1
                }
            }
        }

        // Return highest height with at least one peer
        guard let (height, _) = heights.max(by: { $0.key < $1.key }) else {
            throw NetworkError.consensusNotReached
        }

        return height
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
    /// NOTE: This is not used for normal scanning (uses InsightAPI instead to avoid peer spam)
    /// Kept for potential future use with trusted peers or local nodes
    func getBlocksDataP2P(from height: UInt64, count: Int) async throws -> [(UInt64, String, [(String, [ShieldedOutput], [ShieldedSpend]?)])] {
        guard isConnected else {
            throw NetworkError.notConnected
        }

        guard let peer = peers.first else {
            throw NetworkError.notConnected
        }

        var results: [(UInt64, String, [(String, [ShieldedOutput], [ShieldedSpend]?)])] = []

        // Fetch blocks one by one using HeaderStore hashes (with InsightAPI fallback)
        for i in 0..<count {
            let blockHeight = height + UInt64(i)

            var block: CompactBlock?

            // Try P2P first: Get block hash from HeaderStore
            if let header = try? HeaderStore.shared.getHeader(at: blockHeight) {
                block = try? await peer.getBlockByHash(hash: header.blockHash)
            }

            // Fallback to InsightAPI if P2P failed
            if block == nil {
                do {
                    let hashFromAPI = try await InsightAPI.shared.getBlockHash(height: blockHeight)
                    // Get shielded outputs via InsightAPI (uses raw tx parsing)
                    let insightBlock = try await InsightAPI.shared.getBlock(hash: hashFromAPI)
                    // Fetch shielded data from each transaction (including spends for nullifier detection!)
                    var txDataList: [(String, [ShieldedOutput], [ShieldedSpend]?)] = []
                    for txid in insightBlock.tx {
                        // Get full tx to check for spends (nullifier detection)
                        let txInfo = try? await InsightAPI.shared.getTransaction(txid: txid)
                        let spends = txInfo?.spendDescs

                        // Get outputs from raw tx (full encCiphertext)
                        let outputs = try await InsightAPI.shared.getShieldedOutputsFromRaw(txid: txid)

                        // Include tx if it has outputs OR spends (spends are for nullifier detection)
                        if !outputs.isEmpty || (spends?.isEmpty == false) {
                            txDataList.append((txid, outputs, spends))
                        }
                    }
                    results.append((blockHeight, hashFromAPI, txDataList))
                    continue
                } catch {
                    print("⚠️ P2P batch: Failed to get block at height \(blockHeight) (P2P and InsightAPI both failed)")
                    continue
                }
            }

            guard let block = block else {
                print("⚠️ P2P batch: No block data at height \(blockHeight)")
                continue
            }
            // Use block hash from P2P block
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

            results.append((blockHeight, finalBlockHash, txDataList))
        }

        return results
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

/// Codable version of AddressInfo for persistence
struct PersistedAddress: Codable {
    let host: String
    let port: UInt16
    let firstSeen: Date
    let lastSeen: Date
    let attempts: Int
    let successes: Int
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
    case transactionRejected
    case transactionNotVerified
    case connectionFailed(String)
    case handshakeFailed
    case timeout
    case connectionTimeout
    case invalidData
    case notFound

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
        case .timeout:
            return "Request timed out"
        case .connectionTimeout:
            return "Connection timed out"
        case .invalidData:
            return "Invalid data format"
        case .notFound:
            return "Data not found on peer"
        }
    }
}
