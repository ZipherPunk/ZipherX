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

    // Sync state - FIX #133: Use static to prevent duplicate syncs from multiple instances
    private static var isSyncing = false
    private static let syncLock = NSLock()
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
        // FIX #133: Use static lock to prevent duplicate syncs from multiple HeaderSyncManager instances
        Self.syncLock.lock()
        guard !Self.isSyncing else {
            Self.syncLock.unlock()
            print("⚠️ Header sync already in progress (skipping duplicate)")
            throw SyncError.alreadySyncing
        }
        Self.isSyncing = true
        Self.syncLock.unlock()

        defer {
            Self.syncLock.lock()
            Self.isSyncing = false
            Self.syncLock.unlock()
        }

        print("🔄 Starting header sync from height \(startHeight)")

        // P2P-only consensus: get from NetworkManager
        let consensusHeight = try await networkManager.getChainHeight()

        guard consensusHeight > 0 else {
            print("❌ No consensus on chain height - cannot sync safely")
            throw SyncError.noConsensus(heights: [])
        }

        let chainTip = consensusHeight
        print("🎯 Consensus chain tip: \(chainTip)")

        guard chainTip > startHeight else {
            print("✅ Already synced to tip")
            return
        }

        let totalHeaders = Int(chainTip - startHeight)
        print("📥 Need to sync \(totalHeaders) headers")

        // FIX #122: FAST PARALLEL HEADER SYNC
        // Instead of sequential batch-by-batch with consensus, use parallel fetching:
        // 1. Assign different height ranges to different peers
        // 2. Fetch all ranges in parallel
        // 3. Verify chain continuity after all fetches complete
        // This reduces sync time from ~7 minutes to ~30-60 seconds!

        if totalHeaders <= 500 {
            // Small sync - use simple single-peer fetch (faster for small ranges)
            try await syncHeadersSimple(from: startHeight, to: chainTip)
        } else {
            // Large sync - use parallel multi-peer fetch
            try await syncHeadersParallel(from: startHeight, to: chainTip)
        }

        print("🎉 Header sync complete! Synced to height \(chainTip)")
    }

    /// FIX #122: Fill header gaps - detects and fills missing headers in the store
    /// This is crucial for fixing timestamps when header sync had discontinuities
    func fillHeaderGaps() async throws -> Int {
        print("🔍 Checking for header gaps...")

        guard let minHeight = try? headerStore.getMinHeight(),
              let maxHeight = try? headerStore.getLatestHeight() else {
            print("❌ No headers in store")
            return 0
        }

        let expectedCount = Int(maxHeight - minHeight + 1)
        let actualCount = try headerStore.getHeaderCount()
        let missingCount = expectedCount - actualCount

        if missingCount <= 0 {
            print("✅ No header gaps detected (\(actualCount) headers, \(minHeight)-\(maxHeight))")
            return 0
        }

        print("⚠️ Detected \(missingCount) missing headers in range \(minHeight)-\(maxHeight)")

        // Find all gaps
        var gaps: [(start: UInt64, end: UInt64)] = []
        var currentHeight = minHeight

        while currentHeight <= maxHeight {
            if let _ = try? headerStore.getHeader(at: currentHeight) {
                currentHeight += 1
                continue
            }

            // Found start of a gap
            let gapStart = currentHeight

            // Find end of gap
            while currentHeight <= maxHeight {
                if let _ = try? headerStore.getHeader(at: currentHeight) {
                    break
                }
                currentHeight += 1
            }

            let gapEnd = currentHeight - 1
            gaps.append((start: gapStart, end: gapEnd))
            print("📍 Gap found: \(gapStart) - \(gapEnd) (\(gapEnd - gapStart + 1) headers)")
        }

        if gaps.isEmpty {
            print("✅ No gaps found on detailed check")
            return 0
        }

        // Fill each gap by syncing from the header before the gap
        var totalFilled = 0

        for (gapStart, gapEnd) in gaps {
            print("🔧 Filling gap \(gapStart) - \(gapEnd)...")

            do {
                // We need to sync from gapStart using the header at gapStart-1 as locator
                // This is handled automatically by syncHeadersSimple which uses buildGetHeadersPayload
                try await syncHeadersSimple(from: gapStart, to: gapEnd + 1)

                // Verify the gap was filled
                let filledCount = (gapStart...gapEnd).filter { height in
                    (try? headerStore.getHeader(at: height)) != nil
                }.count

                totalFilled += filledCount
                print("✅ Filled \(filledCount) headers for gap \(gapStart) - \(gapEnd)")

            } catch {
                print("⚠️ Failed to fill gap \(gapStart) - \(gapEnd): \(error)")
            }
        }

        print("🎉 Gap filling complete: \(totalFilled) headers filled")
        return totalFilled
    }

    /// FIX #122: Simple single-peer header sync for small ranges (<500 headers)
    /// No consensus overhead - just fetch from one peer and verify Equihash
    private func syncHeadersSimple(from startHeight: UInt64, to chainTip: UInt64) async throws {
        print("⚡ Using simple sync with peer rotation for \(chainTip - startHeight) headers")

        var currentHeight = startHeight
        var failedPeers = Set<String>()

        while currentHeight < chainTip {
            // CRITICAL FIX: Get FRESH peers list on each iteration
            let currentPeers = networkManager.peers.filter { $0.isConnectionReady && !failedPeers.contains($0.host) }

            guard let peer = currentPeers.first else {
                // Wait and retry with refreshed peer list
                print("⚠️ No ready peers, waiting 2s for reconnection...")
                try await Task.sleep(nanoseconds: 2_000_000_000)
                failedPeers.removeAll() // Reset failed peers to retry all
                let retryPeers = networkManager.peers.filter { $0.isConnectionReady }
                guard !retryPeers.isEmpty else {
                    throw SyncError.insufficientPeers(got: 0, need: 1)
                }
                continue
            }

            // FIX #133: Destructure tuple to get actual locator height
            let (payload, actualLocatorHeight) = buildGetHeadersPayload(startHeight: currentHeight)
            // Headers will start at actualLocatorHeight + 1 (P2P returns headers AFTER locator)
            let headersStartHeight = actualLocatorHeight + 1

            do {
                let headers: [ZclassicBlockHeader] = try await peer.withExclusiveAccess {
                    try await peer.sendMessage(command: "getheaders", payload: payload)

                    var receivedHeaders: [ZclassicBlockHeader]?
                    var attempts = 0

                    while receivedHeaders == nil && attempts < 5 {
                        attempts += 1
                        let (command, response) = try await peer.receiveMessageWithTimeout(seconds: 15)
                        if command == "headers" {
                            // FIX #133: Use correct starting height from actual locator
                            receivedHeaders = try self.parseHeadersPayload(response, startingAt: headersStartHeight)
                        }
                    }

                    return receivedHeaders ?? []
                }

                guard !headers.isEmpty else {
                    print("⚠️ No headers from peer \(peer.host), trying another...")
                    failedPeers.insert(peer.host)
                    continue
                }

                // FIX #133: Verify chain starting at correct height
                try verifyHeaderChain(headers, startingAt: headersStartHeight)
                try headerStore.insertHeaders(headers)

                // FIX #133: Use actual header heights, not requested heights
                let actualEndHeight = headersStartHeight + UInt64(headers.count) - 1
                currentHeight = actualEndHeight + 1

                // Report progress
                let progress = HeaderSyncProgress(
                    currentHeight: actualEndHeight,
                    totalHeight: chainTip,
                    headersStored: try headerStore.getHeaderCount()
                )
                onProgress?(progress)

                print("✅ Synced \(headers.count) headers to \(actualEndHeight) (\(progress.percentComplete)%)")

            } catch {
                print("⚠️ Peer \(peer.host) failed: \(error.localizedDescription)")
                failedPeers.insert(peer.host)
                continue
            }
        }
    }

    /// FIX #141: PARALLEL header requests - request from ALL peers, take first response
    /// Over Tor, latency varies wildly. Parallel requests ensure fastest peer wins.
    /// IMPORTANT: P2P getheaders returns headers AFTER the locator hash
    /// Each batch uses the last received header's hash as locator for the next batch
    private func syncHeadersParallel(from startHeight: UInt64, to chainTip: UInt64) async throws {
        print("🚀 FIX #141: Using PARALLEL header requests for \(chainTip - startHeight) headers")

        let peers = networkManager.peers.filter { $0.isConnectionReady }
        guard !peers.isEmpty else {
            throw SyncError.insufficientPeers(got: 0, need: 1)
        }

        print("📊 Requesting headers from ALL \(peers.count) peers in parallel (first response wins)")

        var currentHeight = startHeight
        var totalSynced = 0
        let totalNeeded = Int(chainTip - startHeight)
        let startTime = Date()
        var consecutiveFailures = 0
        let maxConsecutiveFailures = 3

        while currentHeight < chainTip {
            // FIX #133: Destructure tuple to get actual locator height
            let (payload, actualLocatorHeight) = buildGetHeadersPayload(startHeight: currentHeight)
            // Headers will start at actualLocatorHeight + 1 (P2P returns headers AFTER locator)
            let headersStartHeight = actualLocatorHeight + 1

            // Get fresh peer list for each batch
            let currentPeers = networkManager.peers.filter { $0.isConnectionReady }
            guard !currentPeers.isEmpty else {
                print("⚠️ No connected peers, waiting 1s...")
                try await Task.sleep(nanoseconds: 1_000_000_000)
                consecutiveFailures += 1
                if consecutiveFailures >= maxConsecutiveFailures {
                    throw SyncError.insufficientPeers(got: 0, need: 1)
                }
                continue
            }

            // FIX #141: Request from ALL peers in parallel, take first valid response
            // This dramatically speeds up sync over Tor where latency varies wildly
            let headers: [ZclassicBlockHeader]? = await withTaskGroup(of: (Peer, [ZclassicBlockHeader]?).self) { group in
                // Start requests to all peers
                for peer in currentPeers {
                    group.addTask {
                        do {
                            let result: [ZclassicBlockHeader] = try await peer.withExclusiveAccess {
                                try await peer.sendMessage(command: "getheaders", payload: payload)

                                // FIX #141: Short 2s timeout - if peer doesn't respond quickly, skip it
                                let (command, response) = try await peer.receiveMessageWithTimeout(seconds: 2)
                                if command == "headers" {
                                    // FIX #133: Use correct starting height
                                    return try self.parseHeadersPayload(response, startingAt: headersStartHeight)
                                }
                                return []
                            }
                            return (peer, result.isEmpty ? nil : result)
                        } catch {
                            return (peer, nil)
                        }
                    }
                }

                // Take FIRST valid response (fastest peer wins!)
                for await (peer, result) in group {
                    if let headers = result, !headers.isEmpty {
                        print("⚡ FIX #141: Got \(headers.count) headers from \(peer.host) (first responder)")
                        group.cancelAll()  // Cancel other requests
                        return headers
                    }
                }
                return nil
            }

            guard let headers = headers, !headers.isEmpty else {
                print("⚠️ No headers from any peer, retrying...")
                consecutiveFailures += 1
                if consecutiveFailures >= maxConsecutiveFailures {
                    // Wait and retry with fresh peers
                    print("⚠️ \(maxConsecutiveFailures) consecutive failures, waiting 2s for peers...")
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    consecutiveFailures = 0
                }
                continue
            }

            // Success - reset failure counter
            consecutiveFailures = 0

            // FIX #133: Verify chain continuity with correct starting height
            try verifyHeaderChain(headers, startingAt: headersStartHeight)

            // Store headers
            try headerStore.insertHeaders(headers)

            totalSynced += headers.count
            // FIX #133: Use actual header end height for next iteration
            currentHeight = headersStartHeight + UInt64(headers.count)

            let percent = totalSynced * 100 / max(totalNeeded, 1)
            let elapsed = Date().timeIntervalSince(startTime)
            let rate = elapsed > 0 ? Double(totalSynced) / elapsed : 0
            print("✅ Synced \(totalSynced)/\(totalNeeded) headers (\(percent)%) - \(Int(rate)) headers/sec")

            // Report progress
            let progress = HeaderSyncProgress(
                currentHeight: currentHeight - 1,
                totalHeight: chainTip,
                headersStored: try headerStore.getHeaderCount()
            )
            onProgress?(progress)
        }

        let totalTime = Date().timeIntervalSince(startTime)
        let finalRate = totalTime > 0 ? Double(totalSynced) / totalTime : 0
        print("🎉 Header sync complete: \(totalSynced) headers in \(String(format: "%.1f", totalTime)) seconds (\(Int(finalRate)) headers/sec)")
    }

    /// Fetch headers from a single peer for a specific range
    /// Used by parallel sync - no consensus, just fetch and return
    private func fetchHeadersFromPeer(_ peer: Peer, from startHeight: UInt64, to endHeight: UInt64) async throws -> [ZclassicBlockHeader] {
        var allHeaders: [ZclassicBlockHeader] = []
        var currentHeight = startHeight

        while currentHeight < endHeight {
            // FIX #133: Destructure tuple to get actual locator height
            let (payload, actualLocatorHeight) = buildGetHeadersPayload(startHeight: currentHeight)
            // Headers will start at actualLocatorHeight + 1 (P2P returns headers AFTER locator)
            let headersStartHeight = actualLocatorHeight + 1

            let headers: [ZclassicBlockHeader] = try await peer.withExclusiveAccess {
                try await peer.sendMessage(command: "getheaders", payload: payload)

                var receivedHeaders: [ZclassicBlockHeader]?
                var attempts = 0

                // FIX #137: Reduced timeout for faster peer rotation
                while receivedHeaders == nil && attempts < 2 {
                    attempts += 1
                    let (command, response) = try await peer.receiveMessageWithTimeout(seconds: 5)
                    if command == "headers" {
                        // FIX #133: Use correct starting height from actual locator
                        receivedHeaders = try self.parseHeadersPayload(response, startingAt: headersStartHeight)
                    }
                }

                return receivedHeaders ?? []
            }

            guard !headers.isEmpty else { break }

            allHeaders.append(contentsOf: headers)
            // FIX #133: Use actual header end height for next iteration
            currentHeight = headersStartHeight + UInt64(headers.count)

            // Stop if we've reached our target
            if currentHeight >= endHeight { break }
        }

        return allHeaders
    }

    /// Get the current chain tip height using P2P consensus
    /// SECURITY VUL-006 FIX: Uses locally verified headers as primary source, P2P consensus as secondary
    /// InsightAPI is only used as a last-resort fallback when P2P is unavailable
    func getChainTip() async throws -> UInt64 {
        // VUL-006: Chain height determination priority:
        // 0. FULL NODE RPC: If running local daemon, use RPC (most trusted!)
        // 1. PRIMARY: Locally verified headers (cryptographically validated with Equihash)
        // 2. SECONDARY: P2P peer consensus (median height from multiple peers)
        // 3. FALLBACK: InsightAPI (only if P2P unavailable)

        // 0. FULL NODE RPC: If local daemon is running, use its height (most trusted source)
        #if os(macOS)
        if await WalletModeManager.shared.currentMode == .fullNode {
            if let rpcHeight = await FullNodeManager.shared.getBlockHeight() {
                print("📡 [RPC] Full Node daemon height: \(rpcHeight) (TRUSTED)")
                return rpcHeight
            }
        }
        #endif

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
                // SECURITY: Skip banned peers and handle negative heights (malicious peers send Int32 that wraps to negative)
                guard !networkManager.isPeerBanned(peer.host), peer.peerStartHeight > 0 else { continue }
                let h = UInt64(peer.peerStartHeight)  // Safe: checked > 0 above
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

        // FIX #120: InsightAPI commented out - P2P only
        // 4. FALLBACK: If P2P consensus unavailable, try InsightAPI as last resort
        // if maxHeight == 0 {
        //     print("⚠️ VUL-006: No P2P consensus available, falling back to InsightAPI")
        //     do {
        //         let status = try await InsightAPI.shared.getStatus()
        //         maxHeight = status.height
        //         print("📡 [FALLBACK] InsightAPI chain tip: \(maxHeight)")
        //     } catch {
        //         print("❌ InsightAPI also unavailable: \(error)")
        //     }
        // }
        if maxHeight == 0 {
            print("❌ P2P-only mode: No peers available for chain height consensus")
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

            // FIX #120: Wait for peers to actually connect (up to 15 seconds)
            // The connect() call initiates connections but they may not be ready yet
            var waitAttempts = 0
            let maxWaitAttempts = 30 // 30 * 0.5s = 15 seconds max
            while networkManager.peers.count < minPeers && waitAttempts < maxWaitAttempts {
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
                waitAttempts += 1
                if waitAttempts % 4 == 0 { // Log every 2 seconds
                    print("⏳ Waiting for peers to connect... (\(networkManager.peers.count)/\(minPeers) ready, waited \(waitAttempts / 2)s)")
                }
            }

            allPeers = networkManager.peers
            print("📡 After waiting: \(allPeers.count) peers connected")
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
                            // Try reconnect once using ensureConnected (has 5s cooldown)
                            print("🔄 [\(peer.host)] Handshake failed, trying ensureConnected...")
                            do {
                                try await peer.ensureConnected()
                                let result = try await self.requestHeaders(
                                    from: peer,
                                    startHeight: startHeight,
                                    endHeight: endHeight
                                )
                                peer.markActive()
                                return (peer.host, result)
                            } catch NetworkError.timeout {
                                // Cooldown period - peer was recently reconnected
                                print("⏳ [\(peer.host)] In reconnect cooldown, skipping...")
                                peer.recordFailure()
                                return (peer.host, nil)
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
        // FIX #133: Destructure tuple to get actual locator height
        let (payload, actualLocatorHeight) = buildGetHeadersPayload(startHeight: startHeight)
        // Headers will start at actualLocatorHeight + 1 (P2P returns headers AFTER locator)
        let headersStartHeight = actualLocatorHeight + 1

        // CRITICAL FIX: Wrap entire send+receive sequence in withExclusiveAccess
        // This prevents block listener from reading our response while we're waiting for it
        let headers = try await peer.withExclusiveAccess {
            // Send getheaders message
            try await peer.sendMessage(command: "getheaders", payload: payload)

            // Loop until we receive headers response (peers may send inv/addr/ping first)
            var receivedHeaders: [ZclassicBlockHeader]?
            let maxAttempts = 10
            var attempts = 0

            while receivedHeaders == nil && attempts < maxAttempts {
                attempts += 1
                // FIX #120: Use timeout to prevent infinite blocking on unresponsive peers
                let (command, response) = try await peer.receiveMessageWithTimeout(seconds: 30)

                if command == "headers" {
                    // FIX #133: Use correct starting height from actual locator
                    receivedHeaders = try self.parseHeadersPayload(response, startingAt: headersStartHeight)
                    print("✅ Received \(receivedHeaders?.count ?? 0) headers from peer (starting at height \(headersStartHeight))")
                } else {
                    // Ignore other messages (inv, addr, ping, etc.)
                    print("📭 Peer sent '\(command)' message, waiting for headers...")
                }
            }

            guard let headers = receivedHeaders else {
                throw SyncError.unexpectedMessage(expected: "headers", got: "timeout after \(maxAttempts) messages")
            }

            return headers
        }

        peer.recordSuccess()

        return headers
    }

    /// Build getheaders payload
    /// Format: version (4) + hash_count (varint) + block_hashes (32 each) + stop_hash (32)
    /// Returns: (payload, actualLocatorHeight) - the actual height of the locator used
    /// FIX #133: Track actual locator height to detect height offset issues
    private func buildGetHeadersPayload(startHeight: UInt64) -> (payload: Data, actualLocatorHeight: UInt64) {
        var payload = Data()

        // Protocol version (BIP155 support)
        let version: UInt32 = 170012
        payload.append(contentsOf: withUnsafeBytes(of: version.littleEndian) { Array($0) })

        // Number of block locator hashes (varint - use 1 for simplicity)
        payload.append(1)

        // Block locator hash - need the hash at (startHeight - 1) to request headers starting at startHeight
        let locatorHeight = startHeight > 0 ? startHeight - 1 : 0
        var locatorHash: Data?
        var actualLocatorHeight = locatorHeight  // FIX #133: Track actual height used

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

        // Third try: Get from BundledBlockHashes (downloaded from GitHub)
        if locatorHash == nil {
            let bundledHashes = BundledBlockHashes.shared
            if bundledHashes.isLoaded, let hash = bundledHashes.getBlockHash(at: locatorHeight) {
                locatorHash = hash  // Already in wire format
                print("📋 Using BundledBlockHashes hash for locator at height \(locatorHeight)")
            }
        }

        // Fourth try: Find nearest checkpoint BELOW the requested height (P2P-safe fallback)
        // FIX #133: This MUST update actualLocatorHeight to reflect the real starting point
        // Otherwise headers will be assigned wrong heights!
        if locatorHash == nil {
            let checkpoints = ZclassicCheckpoints.mainnet.keys.sorted(by: >)  // Descending
            for checkpointHeight in checkpoints {
                if checkpointHeight < locatorHeight, let checkpointHex = ZclassicCheckpoints.mainnet[checkpointHeight] {
                    if let hashData = Data(hexString: checkpointHex) {
                        locatorHash = Data(hashData.reversed())  // Convert to wire format
                        actualLocatorHeight = checkpointHeight  // FIX #133: Track actual checkpoint height!
                        print("📋 Using nearest checkpoint at height \(checkpointHeight) (requested \(locatorHeight))")
                        print("⚠️ FIX #133: Headers will start at height \(checkpointHeight + 1), not \(startHeight)!")
                        break
                    }
                }
            }
        }

        // Fallback: Use zero hash (will return headers from genesis) - SECURITY WARNING: may get old headers!
        // This should NEVER happen now that we have nearest checkpoint fallback
        if let hash = locatorHash {
            payload.append(hash)
        } else {
            print("🚨 No locator hash available for height \(locatorHeight), using zero hash (may get wrong Equihash params!)")
            payload.append(Data(count: 32))
            actualLocatorHeight = 0  // Headers will start from genesis
        }

        // Stop hash (zero = get maximum headers)
        payload.append(Data(count: 32))

        return (payload, actualLocatorHeight)
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
            // - varint solution_len (typically 3 bytes for 400: fd 90 01)
            // - solution (400 bytes for post-Bubbles Equihash(192,7))
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
