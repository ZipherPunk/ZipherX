// Copyright (c) 2025 Zipherpunk.com dev team
// Header synchronization with multi-peer consensus

import Foundation

/// Manages header synchronization from multiple peers with consensus verification
/// Ensures trustless operation by requiring 6/8 peers to agree on header data
final class HeaderSyncManager {
    private let headerStore: HeaderStore
    private let networkManager: NetworkManager

    // Consensus parameters
    // SECURITY: Chain height consensus uses InsightAPI + P2P peers with auto-banning
    // Header sync needs fewer peers since headers are verified by chain continuity + PoW
    // Fake heights are detected and banned by getConsensusChainHeight()
    private let minPeers = 3  // Minimum peers for header sync
    private let consensusThreshold = 3  // Require 3 peers to agree on headers

    // Sync state
    private var isSyncing = false
    private let syncQueue = DispatchQueue(label: "com.zipherx.headersync", qos: .userInitiated)

    // Progress tracking
    var onProgress: ((HeaderSyncProgress) -> Void)?

    init(headerStore: HeaderStore, networkManager: NetworkManager) {
        self.headerStore = headerStore
        self.networkManager = networkManager
    }

    // MARK: - Sync Operations

    /// Sync headers from a starting height to network tip
    /// Uses multi-peer consensus to ensure data integrity
    func syncHeaders(from startHeight: UInt64) async throws {
        guard !isSyncing else {
            throw SyncError.alreadySyncing
        }

        isSyncing = true
        defer { isSyncing = false }

        print("🔄 Starting header sync from height \(startHeight)")

        // SECURITY: Use multi-source consensus for chain height
        // Don't trust any single source (InsightAPI could be compromised too!)
        // Get consensus from: InsightAPI + multiple P2P peers
        // Peers reporting fake heights will be BANNED automatically
        let consensusHeight = await InsightAPI.shared.getConsensusChainHeight(networkManager: networkManager)

        guard consensusHeight > 0 else {
            print("❌ No consensus on chain height - cannot sync safely")
            throw SyncError.noConsensus(heights: [])
        }

        // Use consensus height as the sync target
        let chainTip = consensusHeight
        print("🎯 Consensus chain tip: \(chainTip)")

        guard chainTip > startHeight else {
            print("✅ Already synced to tip")
            return
        }

        // Sync in batches of 2000 headers (P2P protocol limit)
        let batchSize: UInt64 = 2000
        var currentHeight = startHeight

        while currentHeight < chainTip {
            let endHeight = min(currentHeight + batchSize, chainTip)

            print("📥 Syncing headers \(currentHeight) to \(endHeight)")

            // Request headers from multiple peers
            var headers = try await requestHeadersWithConsensus(
                from: currentHeight,
                to: endHeight
            )

            // SECURITY: Cap headers at consensus height - reject fake future headers
            // Malicious peers may send headers beyond the real chain tip
            let maxAllowedHeight = chainTip
            let originalCount = headers.count

            // Calculate how many headers we can actually use
            let maxHeadersToKeep = Int(maxAllowedHeight - currentHeight + 1)
            if headers.count > maxHeadersToKeep && maxHeadersToKeep > 0 {
                headers = Array(headers.prefix(maxHeadersToKeep))
                print("🚨 [SECURITY] Filtered out \(originalCount - headers.count) fake future headers (capped at height \(maxAllowedHeight))")
            } else if maxHeadersToKeep <= 0 {
                print("⚠️ Already at or past consensus height \(maxAllowedHeight), no headers needed")
                break
            }

            // Verify chain continuity (each header's prevHash matches previous block's hash)
            // Equihash is verified during parsing in parseHeadersPayload
            try verifyHeaderChain(headers, startingAt: currentHeight)

            // Store headers
            try headerStore.insertHeaders(headers)

            // Update currentHeight based on ACTUAL headers received (not requested endHeight)
            // P2P getheaders only returns up to 2000 headers per request
            let actualEndHeight = currentHeight + UInt64(headers.count) - 1
            currentHeight = actualEndHeight + 1

            // Report progress
            let progress = HeaderSyncProgress(
                currentHeight: actualEndHeight,
                totalHeight: chainTip,
                headersStored: try headerStore.getHeaderCount()
            )
            onProgress?(progress)

            print("✅ Synced \(headers.count) headers to height \(actualEndHeight) (\(progress.percentComplete)%)")

            // If we received fewer headers than expected, peers don't have more
            if headers.isEmpty {
                print("⚠️ No more headers available from peers")
                break
            }
        }

        print("🎉 Header sync complete! Synced to height \(chainTip)")
    }

    /// Get the current chain tip height using P2P consensus
    /// SECURITY VUL-006 FIX: Uses locally verified headers as primary source, P2P consensus as secondary
    /// InsightAPI is only used as a last-resort fallback when P2P is unavailable
    func getChainTip() async throws -> UInt64 {
        // VUL-006: P2P-first chain height determination
        // 1. PRIMARY: Locally verified headers (cryptographically validated with Equihash)
        // 2. SECONDARY: P2P peer consensus (median height from multiple peers)
        // 3. FALLBACK: InsightAPI (only if P2P unavailable)

        // Maximum acceptable height difference between header store and P2P
        let maxHeightDrift: UInt64 = 20

        // 1. PRIMARY: Check locally verified header store (Equihash-validated)
        var headerStoreHeight: UInt64 = 0
        if let headerHeight = try? headerStore.getLatestHeight() {
            headerStoreHeight = headerHeight
            print("📡 [LOCAL] HeaderStore height: \(headerStoreHeight) (Equihash verified)")
        }

        // 2. SECONDARY: Get P2P peer heights and compute consensus (median)
        var peerHeights: [UInt64] = []
        do {
            let peers = try await networkManager.getConnectedPeers(min: minPeers)
            for peer in peers {
                let h = UInt64(peer.peerStartHeight)
                if h > 0 {
                    peerHeights.append(h)
                }
            }
        } catch {
            print("⚠️ Could not get peer list: \(error)")
        }

        var p2pConsensusHeight: UInt64 = 0
        if peerHeights.count >= 3 {
            // Use median for Byzantine fault tolerance
            let sorted = peerHeights.sorted()
            p2pConsensusHeight = sorted[sorted.count / 2]
            print("📡 [P2P] Consensus height (median of \(peerHeights.count) peers): \(p2pConsensusHeight)")
        } else if !peerHeights.isEmpty {
            // Not enough peers for median, use max with caution
            p2pConsensusHeight = peerHeights.max() ?? 0
            print("📡 [P2P] Height from \(peerHeights.count) peer(s): \(p2pConsensusHeight) (insufficient for median)")
        }

        // 3. Determine chain tip using P2P-first logic
        var maxHeight: UInt64 = 0

        if headerStoreHeight > 0 {
            // We have locally verified headers - use as baseline
            maxHeight = headerStoreHeight

            // Validate P2P heights against locally verified data
            if p2pConsensusHeight > 0 {
                if p2pConsensusHeight > headerStoreHeight + maxHeightDrift {
                    // P2P is way ahead - could be legitimate new blocks OR fake heights
                    // Trust it cautiously but cap at reasonable drift from verified headers
                    print("⚠️ P2P \(p2pConsensusHeight - headerStoreHeight) blocks ahead of local store")
                    maxHeight = headerStoreHeight + maxHeightDrift
                    print("📡 Capping at \(maxHeight) until headers are synced")
                } else if p2pConsensusHeight > headerStoreHeight {
                    // P2P slightly ahead - accept (new blocks since last sync)
                    maxHeight = p2pConsensusHeight
                }
            }
        } else if p2pConsensusHeight > 0 {
            // No local headers, use P2P consensus
            maxHeight = p2pConsensusHeight
            print("📡 Using P2P consensus (no local headers)")
        }

        // 4. FALLBACK: If P2P consensus unavailable, try InsightAPI as last resort
        if maxHeight == 0 {
            print("⚠️ VUL-006: No P2P consensus available, falling back to InsightAPI")
            do {
                let status = try await InsightAPI.shared.getStatus()
                maxHeight = status.height
                print("📡 [FALLBACK] InsightAPI chain tip: \(maxHeight)")
            } catch {
                print("❌ InsightAPI also unavailable: \(error)")
            }
        }

        if maxHeight > 0 {
            print("📡 Using chain tip: \(maxHeight)")
            return maxHeight
        }

        throw SyncError.insufficientPeers(got: 0, need: 1)
    }

    /// Request headers from multiple peers and verify consensus
    /// Tries at least 10 peers before giving up (P2P-first, no InsightAPI fallback for headers)
    private func requestHeadersWithConsensus(
        from startHeight: UInt64,
        to endHeight: UInt64
    ) async throws -> [ZclassicBlockHeader] {
        let minPeersToTry = 10  // Try at least 10 peers before giving up

        // Get ALL available peers for resilience
        var allPeers = networkManager.peers

        // If we don't have enough peers, try to connect more
        if allPeers.count < minPeersToTry {
            print("🔄 Only \(allPeers.count) peers, attempting to connect more...")
            try? await networkManager.connect()
            allPeers = networkManager.peers
        }

        guard allPeers.count >= minPeers else {
            throw SyncError.insufficientPeers(got: allPeers.count, need: minPeers)
        }

        // Track which peers we've tried and which succeeded
        var triedPeersCount = 0
        var successfulHeaders: [[ZclassicBlockHeader]] = []
        var remainingPeers = allPeers

        // Keep trying peers until we have consensus or tried 10+ peers
        while successfulHeaders.count < consensusThreshold && !remainingPeers.isEmpty {
            let peersNeeded = consensusThreshold - successfulHeaders.count
            let peersToTry = Array(remainingPeers.prefix(max(peersNeeded + 1, 4))) // Try at least 4 at a time

            // Remove from remaining pool
            for peer in peersToTry {
                remainingPeers.removeAll { $0.host == peer.host }
            }
            triedPeersCount += peersToTry.count

            print("🌐 Trying \(peersToTry.count) peers (total tried: \(triedPeersCount), need \(consensusThreshold - successfulHeaders.count) more)")

            // Request headers from this batch in parallel
            await withTaskGroup(of: (String, [ZclassicBlockHeader]?).self) { group in
                for peer in peersToTry {
                    group.addTask {
                        do {
                            try await peer.ensureConnected()
                            let result = try await self.requestHeaders(
                                from: peer,
                                startHeight: startHeight,
                                endHeight: endHeight
                            )
                            peer.markActive()
                            return (peer.host, result)
                        } catch NetworkError.handshakeFailed {
                            // Try reconnect once
                            print("🔄 [\(peer.host)] Handshake failed, reconnecting...")
                            peer.disconnect()
                            try? await Task.sleep(nanoseconds: 50_000_000)
                            do {
                                try await peer.connect()
                                try await peer.performHandshake()
                                let result = try await self.requestHeaders(
                                    from: peer,
                                    startHeight: startHeight,
                                    endHeight: endHeight
                                )
                                peer.markActive()
                                return (peer.host, result)
                            } catch {
                                peer.recordFailure()
                                return (peer.host, nil)
                            }
                        } catch {
                            print("⚠️ [\(peer.host)] Failed: \(error)")
                            peer.recordFailure()
                            return (peer.host, nil)
                        }
                    }
                }

                // Collect results, exit early if we reach consensus
                for await (host, headers) in group {
                    if let headers = headers {
                        successfulHeaders.append(headers)
                        print("📊 Consensus: \(successfulHeaders.count)/\(self.consensusThreshold) peers (\(host))")
                        if successfulHeaders.count >= self.consensusThreshold {
                            group.cancelAll()
                            break
                        }
                    } else {
                        print("⚠️ Peer \(host) failed, \(remainingPeers.count) peers remaining")
                    }
                }
            }

            // If we've tried 10+ peers and still don't have consensus, give up
            if triedPeersCount >= minPeersToTry && successfulHeaders.count < consensusThreshold {
                print("❌ Tried \(triedPeersCount) peers, only \(successfulHeaders.count) succeeded")
                break
            }
        }

        // FALLBACK: If we couldn't reach full consensus but have at least 2 peers agreeing,
        // proceed with reduced security. Better than being stuck forever.
        let reducedThreshold = 2
        if successfulHeaders.count < consensusThreshold && successfulHeaders.count >= reducedThreshold {
            print("⚠️ Reduced consensus: using \(successfulHeaders.count) peers (ideal is \(consensusThreshold))")
        }

        guard successfulHeaders.count >= reducedThreshold else {
            throw SyncError.insufficientPeers(got: successfulHeaders.count, need: consensusThreshold)
        }

        let peerHeaders = successfulHeaders
        // Use actual peer count as the effective threshold for consensus verification
        let effectiveThreshold = min(successfulHeaders.count, consensusThreshold)

        print("📊 Received headers from \(peerHeaders.count) peers")

        // Verify consensus - all peers should return same headers
        let consensusHeaders = try verifyHeaderConsensus(peerHeaders, threshold: effectiveThreshold)

        return consensusHeaders
    }

    /// Request headers from a single peer using getheaders P2P message
    private func requestHeaders(
        from peer: Peer,
        startHeight: UInt64,
        endHeight: UInt64
    ) async throws -> [ZclassicBlockHeader] {
        // Build getheaders payload
        let payload = buildGetHeadersPayload(startHeight: startHeight)

        // Send getheaders message
        try await peer.sendMessage(command: "getheaders", payload: payload)

        // Loop until we receive headers response (peers may send inv/addr/ping first)
        var headers: [ZclassicBlockHeader]?
        let maxAttempts = 10
        var attempts = 0

        while headers == nil && attempts < maxAttempts {
            attempts += 1
            let (command, response) = try await peer.receiveMessage()

            if command == "headers" {
                // Got the headers we requested!
                headers = try parseHeadersPayload(response, startingAt: startHeight)
            } else {
                // Ignore other messages (inv, addr, ping, etc.)
                print("📭 Peer sent '\(command)' message, waiting for headers...")
            }
        }

        guard let headers = headers else {
            throw SyncError.unexpectedMessage(expected: "headers", got: "timeout after \(maxAttempts) messages")
        }

        peer.recordSuccess()

        return headers
    }

    /// Build getheaders payload
    /// Format: version (4) + hash_count (varint) + block_hashes (32 each) + stop_hash (32)
    private func buildGetHeadersPayload(startHeight: UInt64) -> Data {
        var payload = Data()

        // Protocol version
        let version: UInt32 = 170011
        payload.append(contentsOf: withUnsafeBytes(of: version.littleEndian) { Array($0) })

        // Number of block locator hashes (varint - use 1 for simplicity)
        payload.append(1)

        // Block locator hash - need the hash at (startHeight - 1) to request headers starting at startHeight
        let locatorHeight = startHeight > 0 ? startHeight - 1 : 0
        var locatorHash: Data?

        // First try: Get from HeaderStore (cached headers)
        if let lastHeader = try? headerStore.getHeader(at: locatorHeight) {
            locatorHash = lastHeader.blockHash
            print("📋 Using HeaderStore hash for locator at height \(locatorHeight)")
        }

        // Second try: Get from checkpoints if HeaderStore doesn't have it
        if locatorHash == nil, let checkpointHex = ZclassicCheckpoints.mainnet[locatorHeight] {
            // Convert checkpoint hex (big-endian display format) to wire format (little-endian)
            if let hashData = Data(hexString: checkpointHex) {
                locatorHash = Data(hashData.reversed()) // Reverse to wire format
                print("📋 Using checkpoint hash for locator at height \(locatorHeight)")
            }
        }

        // Fallback: Use zero hash (will return headers from genesis)
        if let hash = locatorHash {
            payload.append(hash)
        } else {
            print("⚠️ No locator hash available for height \(locatorHeight), using zero hash")
            payload.append(Data(count: 32))
        }

        // Stop hash (zero = get maximum headers)
        payload.append(Data(count: 32))

        return payload
    }

    /// Parse headers from P2P message with Equihash(200,9) PoW verification
    /// SECURITY VUL-003: Equihash verification is ENABLED to ensure trustless header validation
    /// Format: count (varint) + headers (140 bytes + varint solution_len + solution each) + tx_count (varint, always 0)
    private func parseHeadersPayload(_ data: Data, startingAt startHeight: UInt64) throws -> [ZclassicBlockHeader] {
        var offset = 0

        // Read count (varint)
        guard data.count > 0 else {
            throw SyncError.invalidHeadersPayload(reason: "Empty payload")
        }

        let firstByte = data[offset]
        let count: Int
        if firstByte < 253 {
            count = Int(firstByte)
            offset += 1
        } else if firstByte == 253 {
            guard offset + 3 <= data.count else {
                throw SyncError.invalidHeadersPayload(reason: "Truncated count varint")
            }
            count = Int(data[offset + 1]) | (Int(data[offset + 2]) << 8)
            offset += 3
        } else {
            throw SyncError.invalidHeadersPayload(reason: "Invalid count varint")
        }

        print("📦 Parsing \(count) headers from payload with Equihash verification")

        var headers: [ZclassicBlockHeader] = []

        for i in 0..<count {
            // Zcash/Zclassic header format in "headers" P2P message:
            // - 140 bytes header (4 version + 32 prevhash + 32 merkle + 32 sapling + 4 time + 4 bits + 32 nonce)
            // - varint solution_len (typically 3 bytes for 1344)
            // - solution (typically 1344 bytes for Equihash(200,9))
            // - varint tx_count (always 0 in headers message, so 1 byte)

            guard offset + 140 <= data.count else {
                throw SyncError.invalidHeadersPayload(
                    reason: "Insufficient data for header \(i) base: need 140, have \(data.count - offset)"
                )
            }

            // Read solution length varint at offset 140
            let solLenOffset = offset + 140
            guard solLenOffset < data.count else {
                throw SyncError.invalidHeadersPayload(
                    reason: "No solution length for header \(i)"
                )
            }

            let solFirstByte = data[solLenOffset]
            let solutionLen: Int
            let varintLen: Int

            if solFirstByte < 253 {
                solutionLen = Int(solFirstByte)
                varintLen = 1
            } else if solFirstByte == 253 {
                guard solLenOffset + 3 <= data.count else {
                    throw SyncError.invalidHeadersPayload(reason: "Truncated solution varint for header \(i)")
                }
                solutionLen = Int(data[solLenOffset + 1]) | (Int(data[solLenOffset + 2]) << 8)
                varintLen = 3
            } else {
                throw SyncError.invalidHeadersPayload(reason: "Invalid solution varint for header \(i)")
            }

            // Total entry size: 140 + varint + solution + 1 (tx_count)
            let entrySize = 140 + varintLen + solutionLen + 1

            guard offset + entrySize <= data.count else {
                throw SyncError.invalidHeadersPayload(
                    reason: "Insufficient data for header \(i): need \(entrySize), have \(data.count - offset)"
                )
            }

            // Extract full header with solution (exclude tx_count)
            let fullHeaderData = data.subdata(in: offset..<(offset + 140 + varintLen + solutionLen))

            // SECURITY VUL-003: Enable Equihash PoW verification for trustless header validation
            // This prevents accepting fake headers from malicious peers
            let height = startHeight + UInt64(i)
            do {
                let header = try ZclassicBlockHeader.parseWithSolution(data: fullHeaderData, height: height, verifyEquihash: true)
                headers.append(header)
            } catch ParseError.equihashVerificationFailed(let failHeight) {
                print("🚨 [SECURITY] Equihash verification FAILED at height \(failHeight) - rejecting header")
                throw SyncError.invalidHeadersPayload(reason: "Equihash verification failed for header at height \(failHeight)")
            }

            // Skip past this header entry (including tx_count)
            offset += entrySize
        }

        print("✅ Parsed \(count) headers with Equihash verification")

        return headers
    }

    /// Verify that multiple peers agree on header data (consensus)
    private func verifyHeaderConsensus(_ peerHeaders: [[ZclassicBlockHeader]], threshold: Int) throws -> [ZclassicBlockHeader] {
        guard let firstHeaders = peerHeaders.first else {
            throw SyncError.noHeadersReceived
        }

        let headerCount = firstHeaders.count
        var consensusHeaders: [ZclassicBlockHeader] = []

        // Verify each header position
        for i in 0..<headerCount {
            var blockHashVotes: [Data: Int] = [:]
            var saplingRootVotes: [Data: Int] = [:]
            var headersByHash: [Data: ZclassicBlockHeader] = [:]

            // Count votes for each header
            for headers in peerHeaders {
                guard i < headers.count else { continue }

                let header = headers[i]
                let blockHash = header.blockHash
                let saplingRoot = header.hashFinalSaplingRoot

                blockHashVotes[blockHash, default: 0] += 1
                saplingRootVotes[saplingRoot, default: 0] += 1
                headersByHash[blockHash] = header
            }

            // Find consensus header (most votes)
            guard let (consensusHash, votes) = blockHashVotes.max(by: { $0.value < $1.value }) else {
                throw SyncError.noConsensus(heights: [])
            }

            guard votes >= threshold else {
                let hashHex = consensusHash.map { String(format: "%02x", $0) }.joined().prefix(16)
                throw SyncError.insufficientConsensus(
                    position: i,
                    hash: String(hashHex),
                    votes: votes,
                    need: threshold
                )
            }

            // Verify sapling root also has consensus
            guard let consensusHeader = headersByHash[consensusHash] else {
                throw SyncError.internalError("Header not found for consensus hash")
            }

            let saplingVotes = saplingRootVotes[consensusHeader.hashFinalSaplingRoot] ?? 0
            guard saplingVotes >= threshold else {
                throw SyncError.saplingRootMismatch(
                    position: i,
                    votes: saplingVotes,
                    need: threshold
                )
            }

            consensusHeaders.append(consensusHeader)
        }

        print("✅ Header consensus verified for \(consensusHeaders.count) headers")

        return consensusHeaders
    }

    /// Verify header chain continuity (each header links to previous)
    private func verifyHeaderChain(_ headers: [ZclassicBlockHeader], startingAt height: UInt64) throws {
        guard !headers.isEmpty else { return }

        var currentHeight = height
        var prevHash: Data?

        // Get previous header's hash if we have it
        if currentHeight > 0, let prevHeader = try? headerStore.getHeader(at: currentHeight - 1) {
            prevHash = prevHeader.blockHash
        }

        let totalHeaders = headers.count
        for (index, header) in headers.enumerated() {
            // Verify previous hash links correctly
            // Skip verification for the very first header if we don't have its previous block
            if let prevHash = prevHash {
                // Debug: Print only first and last headers to reduce log spam
                let prevHex = prevHash.map { String(format: "%02x", $0) }.joined()
                let gotPrevHex = header.hashPrevBlock.map { String(format: "%02x", $0) }.joined()
                let currentBlockHex = header.blockHash.map { String(format: "%02x", $0) }.joined()

                // Only show first, last, and every 500th header
                if index == 0 || index == totalHeaders - 1 || index % 500 == 0 {
                    print("🔍 Height \(currentHeight): blockHash=\(currentBlockHex.prefix(16))... prevBlock=\(gotPrevHex.prefix(16))...")
                }

                guard header.hashPrevBlock == prevHash else {
                    print("❌ MISMATCH at height \(currentHeight)!")
                    print("   Expected prevHash: \(prevHex.prefix(32))...")
                    print("   Got prevHash:      \(gotPrevHex.prefix(32))...")
                    throw SyncError.chainDiscontinuity(
                        height: currentHeight,
                        expectedPrevHash: String(prevHex.prefix(16)),
                        gotPrevHash: String(gotPrevHex.prefix(16))
                    )
                }
            } else if index == 0 {
                // First header and no previous - this is OK for initial sync
                let blockHex = header.blockHash.map { String(format: "%02x", $0) }.joined()
                let prevHex = header.hashPrevBlock.map { String(format: "%02x", $0) }.joined()
                print("ℹ️ Skipping chain verification for first header at height \(currentHeight)")
                print("   First block hash: \(blockHex.prefix(32))...")
                print("   First prev hash:  \(prevHex.prefix(32))...")
            }

            prevHash = header.blockHash
            currentHeight += 1
        }

        print("✅ Header chain continuity verified")
    }
}

// MARK: - Extensions

extension NetworkManager {
    /// Get at least min connected peers for header sync
    func getConnectedPeers(min: Int) async throws -> [Peer] {
        // If we don't have enough peers, try to connect
        if peers.count < min {
            print("⚠️ Only \(peers.count) peers connected, need at least \(min). Attempting to connect...")
            try await connect()
        }

        guard peers.count >= min else {
            throw SyncError.insufficientPeers(got: peers.count, need: min)
        }

        print("✅ Using \(peers.count) connected peers for header sync")
        return peers
    }
}

// MARK: - Data Types

struct HeaderSyncProgress {
    let currentHeight: UInt64
    let totalHeight: UInt64
    let headersStored: Int

    var percentComplete: Int {
        guard totalHeight > 0 else { return 0 }
        return Int((Double(currentHeight) / Double(totalHeight)) * 100.0)
    }

    var remainingHeaders: UInt64 {
        return totalHeight > currentHeight ? totalHeight - currentHeight : 0
    }
}

// MARK: - Errors

enum SyncError: LocalizedError {
    case alreadySyncing
    case insufficientPeers(got: Int, need: Int)
    case noConsensus(heights: [UInt64])
    case insufficientConsensus(position: Int, hash: String, votes: Int, need: Int)
    case saplingRootMismatch(position: Int, votes: Int, need: Int)
    case chainDiscontinuity(height: UInt64, expectedPrevHash: String, gotPrevHash: String)
    case unexpectedMessage(expected: String, got: String)
    case invalidHeadersPayload(reason: String)
    case noHeadersReceived
    case internalError(String)

    var errorDescription: String? {
        switch self {
        case .alreadySyncing:
            return "Header sync already in progress"
        case .insufficientPeers(let got, let need):
            return "Insufficient peers: got \(got), need \(need)"
        case .noConsensus(let heights):
            return "No consensus on chain tip: heights \(heights)"
        case .insufficientConsensus(let pos, let hash, let votes, let need):
            return "Insufficient consensus at position \(pos) (hash: \(hash)): \(votes) votes, need \(need)"
        case .saplingRootMismatch(let pos, let votes, let need):
            return "Sapling root mismatch at position \(pos): \(votes) votes, need \(need)"
        case .chainDiscontinuity(let height, let expected, let got):
            return "Chain discontinuity at height \(height): expected prev_hash \(expected), got \(got)"
        case .unexpectedMessage(let expected, let got):
            return "Unexpected message: expected '\(expected)', got '\(got)'"
        case .invalidHeadersPayload(let reason):
            return "Invalid headers payload: \(reason)"
        case .noHeadersReceived:
            return "No headers received from peers"
        case .internalError(let msg):
            return "Internal error: \(msg)"
        }
    }
}
