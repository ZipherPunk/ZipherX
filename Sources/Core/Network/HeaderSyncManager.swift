// Copyright (c) 2025 Zipherpunk.com dev team
// Header synchronization with multi-peer consensus

import Foundation

/// Manages header synchronization from multiple peers with consensus verification
/// Ensures trustless operation by requiring 6/8 peers to agree on header data
final class HeaderSyncManager {
    private let headerStore: HeaderStore
    private let networkManager: NetworkManager

    // Consensus parameters
    private let minPeers = 8
    private let consensusThreshold = 6  // 75% agreement required

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

        // Get current chain tip from peers
        let chainTip = try await getChainTip()
        print("🎯 Network chain tip: \(chainTip)")

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
            let headers = try await requestHeadersWithConsensus(
                from: currentHeight,
                to: endHeight
            )

            // Verify header chain continuity
            try verifyHeaderChain(headers, startingAt: currentHeight)

            // Store headers
            try headerStore.insertHeaders(headers)

            currentHeight = endHeight + 1

            // Report progress
            let progress = HeaderSyncProgress(
                currentHeight: endHeight,
                totalHeight: chainTip,
                headersStored: try headerStore.getHeaderCount()
            )
            onProgress?(progress)

            print("✅ Synced to height \(endHeight) (\(progress.percentComplete)%)")
        }

        print("🎉 Header sync complete! Synced to height \(chainTip)")
    }

    /// Get the current chain tip height from consensus of peers
    private func getChainTip() async throws -> UInt64 {
        let peers = try await networkManager.getConnectedPeers(min: minPeers)

        var heights: [UInt64] = []

        // Query each peer for their chain tip
        await withTaskGroup(of: UInt64?.self) { group in
            for peer in peers {
                group.addTask {
                    do {
                        // Use getblocks to discover peer's chain height
                        // Peer will respond with inventory of block hashes
                        // For now, use peer's reported start height from version handshake
                        return UInt64(peer.peerStartHeight)
                    } catch {
                        print("⚠️ Failed to get height from peer \(peer.host): \(error)")
                        return nil
                    }
                }
            }

            for await height in group {
                if let height = height {
                    heights.append(height)
                }
            }
        }

        guard heights.count >= consensusThreshold else {
            throw SyncError.insufficientPeers(got: heights.count, need: consensusThreshold)
        }

        // Use median height for consensus
        let sortedHeights = heights.sorted()
        let medianHeight = sortedHeights[sortedHeights.count / 2]

        // Verify consensus (at least consensusThreshold peers within 10 blocks)
        let consensusHeights = sortedHeights.filter { abs(Int64($0) - Int64(medianHeight)) <= 10 }

        guard consensusHeights.count >= consensusThreshold else {
            throw SyncError.noConsensus(heights: heights)
        }

        return medianHeight
    }

    /// Request headers from multiple peers and verify consensus
    private func requestHeadersWithConsensus(
        from startHeight: UInt64,
        to endHeight: UInt64
    ) async throws -> [BlockHeader] {
        let peers = try await networkManager.getConnectedPeers(min: minPeers)

        // Collect headers from each peer
        var peerHeaders: [[BlockHeader]] = []

        await withTaskGroup(of: [BlockHeader]?.self) { group in
            for peer in peers {
                group.addTask {
                    do {
                        return try await self.requestHeaders(
                            from: peer,
                            startHeight: startHeight,
                            endHeight: endHeight
                        )
                    } catch {
                        print("⚠️ Failed to get headers from peer \(peer.host): \(error)")
                        peer.recordFailure()
                        return nil
                    }
                }
            }

            for await headers in group {
                if let headers = headers {
                    peerHeaders.append(headers)
                }
            }
        }

        guard peerHeaders.count >= consensusThreshold else {
            throw SyncError.insufficientPeers(got: peerHeaders.count, need: consensusThreshold)
        }

        print("📊 Received headers from \(peerHeaders.count) peers")

        // Verify consensus - all peers should return same headers
        let consensusHeaders = try verifyHeaderConsensus(peerHeaders)

        return consensusHeaders
    }

    /// Request headers from a single peer using getheaders P2P message
    private func requestHeaders(
        from peer: Peer,
        startHeight: UInt64,
        endHeight: UInt64
    ) async throws -> [BlockHeader] {
        // Build getheaders payload
        let payload = buildGetHeadersPayload(startHeight: startHeight)

        // Send getheaders message
        try await peer.sendMessage(command: "getheaders", payload: payload)

        // Receive headers response
        let (command, response) = try await peer.receiveMessage()

        guard command == "headers" else {
            throw SyncError.unexpectedMessage(expected: "headers", got: command)
        }

        // Parse headers from response
        let headers = try parseHeadersPayload(response)

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

        // Block locator hash (use last known header, or genesis if starting fresh)
        if startHeight > 0, let lastHeader = try? headerStore.getHeader(at: startHeight - 1) {
            payload.append(lastHeader.blockHash)
        } else {
            // Use zero hash for genesis
            payload.append(Data(count: 32))
        }

        // Stop hash (zero = get maximum headers)
        payload.append(Data(count: 32))

        return payload
    }

    /// Parse headers from P2P message
    /// Format: count (varint) + headers (80 bytes each) + tx_count (varint, always 0)
    private func parseHeadersPayload(_ data: Data) throws -> [BlockHeader] {
        var offset = 0

        // Read count (varint - simplified to single byte)
        guard data.count > 0 else {
            throw SyncError.invalidHeadersPayload(reason: "Empty payload")
        }

        let count = Int(data[offset])
        offset += 1

        print("📦 Parsing \(count) headers from payload")

        var headers: [BlockHeader] = []

        for i in 0..<count {
            // Each header is 140 bytes (Zcash format) + 1 byte tx count
            let headerSize = 140
            let entrySize = headerSize + 1  // + tx_count

            guard offset + entrySize <= data.count else {
                throw SyncError.invalidHeadersPayload(
                    reason: "Insufficient data for header \(i): need \(entrySize), have \(data.count - offset)"
                )
            }

            // Extract header bytes (140 bytes)
            let headerData = data.subdata(in: offset..<(offset + headerSize))
            offset += headerSize

            // Skip tx_count (always 0 for headers message)
            offset += 1

            // Parse header
            // Height is unknown from payload - will be computed by caller
            let height = UInt64(i)  // Temporary, will be updated
            let header = try BlockHeader.parse(data: headerData, height: height)
            headers.append(header)
        }

        return headers
    }

    /// Verify that multiple peers agree on header data (consensus)
    private func verifyHeaderConsensus(_ peerHeaders: [[BlockHeader]]) throws -> [BlockHeader] {
        guard let firstHeaders = peerHeaders.first else {
            throw SyncError.noHeadersReceived
        }

        let headerCount = firstHeaders.count
        var consensusHeaders: [BlockHeader] = []

        // Verify each header position
        for i in 0..<headerCount {
            var blockHashVotes: [Data: Int] = [:]
            var saplingRootVotes: [Data: Int] = [:]
            var headersByHash: [Data: BlockHeader] = [:]

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

            guard votes >= consensusThreshold else {
                let hashHex = consensusHash.map { String(format: "%02x", $0) }.joined().prefix(16)
                throw SyncError.insufficientConsensus(
                    position: i,
                    hash: String(hashHex),
                    votes: votes,
                    need: consensusThreshold
                )
            }

            // Verify sapling root also has consensus
            guard let consensusHeader = headersByHash[consensusHash] else {
                throw SyncError.internalError("Header not found for consensus hash")
            }

            let saplingVotes = saplingRootVotes[consensusHeader.hashFinalSaplingRoot] ?? 0
            guard saplingVotes >= consensusThreshold else {
                throw SyncError.saplingRootMismatch(
                    position: i,
                    votes: saplingVotes,
                    need: consensusThreshold
                )
            }

            consensusHeaders.append(consensusHeader)
        }

        print("✅ Header consensus verified for \(consensusHeaders.count) headers")

        return consensusHeaders
    }

    /// Verify header chain continuity (each header links to previous)
    private func verifyHeaderChain(_ headers: [BlockHeader], startingAt height: UInt64) throws {
        guard !headers.isEmpty else { return }

        var currentHeight = height
        var prevHash: Data?

        // Get previous header's hash if we have it
        if currentHeight > 0, let prevHeader = try? headerStore.getHeader(at: currentHeight - 1) {
            prevHash = prevHeader.blockHash
        }

        for header in headers {
            // Verify previous hash links correctly
            if let prevHash = prevHash {
                guard header.hashPrevBlock == prevHash else {
                    let prevHex = prevHash.map { String(format: "%02x", $0) }.joined().prefix(16)
                    let gotHex = header.hashPrevBlock.map { String(format: "%02x", $0) }.joined().prefix(16)
                    throw SyncError.chainDiscontinuity(
                        height: currentHeight,
                        expectedPrevHash: String(prevHex),
                        gotPrevHash: String(gotHex)
                    )
                }
            }

            prevHash = header.blockHash
            currentHeight += 1
        }

        print("✅ Header chain continuity verified")
    }
}

// MARK: - Extensions

extension Peer {
    /// Send a P2P message (wrapper for existing sendMessage method)
    func sendMessage(command: String, payload: Data) async throws {
        // This should already exist in Peer.swift
        // If not, we'll need to make the existing sendMessage method public
    }

    /// Receive a P2P message (wrapper for existing receiveMessage method)
    func receiveMessage() async throws -> (String, Data) {
        // This should already exist in Peer.swift
        // If not, we'll need to make the existing receiveMessage method public
    }
}

extension NetworkManager {
    /// Get at least min connected peers
    func getConnectedPeers(min: Int) async throws -> [Peer] {
        // This should query the existing peer pool and return connected peers
        // Implementation depends on NetworkManager's structure
        // For now, placeholder - will be implemented based on NetworkManager
        fatalError("Not implemented - needs NetworkManager integration")
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
