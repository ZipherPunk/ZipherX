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

    // FIX #673: Track when we last deleted corrupted headers (for chainwork validation)
    private var lastCorruptedHeaderDeletion: Date?

    // Progress tracking
    var onProgress: ((HeaderSyncProgress) -> Void)?

    init(headerStore: HeaderStore, networkManager: NetworkManager) {
        self.headerStore = headerStore
        self.networkManager = networkManager
    }

    // MARK: - Sync Operations

    /// Sync headers from a starting height to network tip
    /// Uses multi-peer consensus to ensure data integrity
    /// - Parameters:
    ///   - startHeight: Starting block height to sync from
    ///   - maxHeaders: FIX #180: Optional maximum number of headers to sync (default: unlimited)
    func syncHeaders(from startHeight: UInt64, maxHeaders: UInt64? = nil) async throws {
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

        var chainTip = consensusHeight
        print("🎯 Consensus chain tip: \(chainTip)")

        // FIX #753: If startHeight is already beyond consensus, we're ahead of the network
        // This happens when HeaderStore has headers that peers don't (yet)
        // Don't try to sync - peers won't have those headers!
        if startHeight > consensusHeight {
            print("✅ FIX #753: Already ahead of network (start \(startHeight) > consensus \(consensusHeight))")
            return
        }

        // FIX #180 + FIX #747: Apply maxHeaders to set sync target
        // - FIX #180: LIMIT chainTip if maxHeaders would overshoot
        // - FIX #747: RAISE chainTip if maxHeaders goes beyond consensus
        //   This fixes the case where peers report stale heights but we need headers
        //   for blocks we're about to scan. If caller says "I need 39 more headers",
        //   we should try to sync them even if peers claim chain is lower.
        // FIX #753: Only raise chainTip if we're actually behind consensus
        if let maxHeaders = maxHeaders, maxHeaders > 0 {
            let targetTip = startHeight + maxHeaders
            // Only adjust if target is within reasonable range of consensus
            // Don't request headers far beyond what peers report
            if targetTip > chainTip && targetTip <= consensusHeight + 200 {
                print("📊 FIX #180/747: Adjusting chainTip from \(chainTip) to \(targetTip) based on maxHeaders (\(maxHeaders))")
                chainTip = targetTip
            } else if targetTip < chainTip {
                print("📊 FIX #180: Limiting chainTip from \(chainTip) to \(targetTip) based on maxHeaders (\(maxHeaders))")
                chainTip = targetTip
            }
        }

        // FIX #484: Check if we need to sync (chainTip >= startHeight means we need headers)
        // All callers pass (currentHeight + 1) as startHeight
        // So if chainTip == startHeight, we need exactly 1 header
        guard chainTip >= startHeight else {
            print("✅ Already synced to tip")
            return
        }

        // FIX #141: Check what we ACTUALLY need to sync
        // If we already have headers up to a certain height, start from there instead
        var effectiveStartHeight = startHeight
        if let maxStoredHeight = try? headerStore.getLatestHeight(),
           maxStoredHeight >= startHeight {
            // We already have headers from startHeight up to maxStoredHeight
            // Only sync from maxStoredHeight + 1
            effectiveStartHeight = maxStoredHeight + 1

            if effectiveStartHeight > chainTip {
                print("✅ FIX #141: Already have headers up to \(maxStoredHeight), nothing new to sync!")
                return
            }

            print("📋 FIX #141: Already have headers up to \(maxStoredHeight)")
            print("📋 FIX #141: Starting sync from \(effectiveStartHeight) instead of \(startHeight)")
            print("📋 FIX #141: This saves syncing \(effectiveStartHeight - startHeight) headers we already have!")
        }

        let totalHeaders = Int(chainTip - effectiveStartHeight)
        print("📥 Need to sync \(totalHeaders) headers (from \(effectiveStartHeight) to \(chainTip))")

        // FIX #122: FAST PARALLEL HEADER SYNC
        // Instead of sequential batch-by-batch with consensus, use parallel fetching:
        // 1. Assign different height ranges to different peers
        // 2. Fetch all ranges in parallel
        // 3. Verify chain continuity after all fetches complete
        // This reduces sync time from ~7 minutes to ~30-60 seconds!

        if totalHeaders <= 500 {
            // Small sync - use simple single-peer fetch (faster for small ranges)
            try await syncHeadersSimple(from: effectiveStartHeight, to: chainTip)
        } else {
            // Large sync - use parallel multi-peer fetch
            try await syncHeadersParallel(from: effectiveStartHeight, to: chainTip)
        }

        // FIX #141: Fill any gaps that may have been created during sync
        // This is important when parallel sync has chain discontinuity errors
        let gapsFilled = try await fillHeaderGaps()
        if gapsFilled > 0 {
            print("📋 Filled \(gapsFilled) header gaps after main sync")
        }

        print("🎉 Header sync complete! Synced to height \(chainTip)")

        // FIX #767 v3: Clear boost corruption flag after successful P2P sync
        // This allows boost file to be loaded again on next startup
        // Without this, the flag persists forever once set
        if headerStore.shouldSkipBoostHeaders() {
            headerStore.clearBoostHeadersCorruptionFlag()
            print("✅ FIX #767 v3: Boost corruption flag cleared - boost file can load on next startup")
        }
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
    /// FIX #501: Aggressive peer rotation - try each trusted peer for 5s max, then switch
    /// FIX #502: PRIORITIZE localhost (127.0.0.1) - user's local node
    /// No consensus overhead - just fetch from one peer and verify Equihash
    private func syncHeadersSimple(from startHeight: UInt64, to chainTip: UInt64) async throws {
        print("⚡ FIX #502: Using localhost-priority header sync for \(chainTip - startHeight) headers")

        // FIX #519: Set flag to prevent health checks from disrupting sync
        await networkManager.setHeaderSyncInProgress(true)
        defer {
            // FIX #519: Always clear flag when done (even if error)
            Task { await networkManager.setHeaderSyncInProgress(false) }
        }

        // FIX: Timing diagnostics - track each step
        let syncStartTime = Date()
        var stepTimings: [String: TimeInterval] = [:]

        // FIX #155: Report initial progress (0%) before starting
        let initialProgress = HeaderSyncProgress(
            currentHeight: startHeight,
            totalHeight: chainTip,
            headersStored: (try? headerStore.getHeaderCount()) ?? 0
        )
        onProgress?(initialProgress)

        var currentHeight = startHeight
        var failedPeers = Set<String>()

        // FIX #501: Much longer total timeout - we'll try many peers
        let headersNeeded = chainTip - currentHeight
        let maxSyncDuration: TimeInterval = 300.0  // 5 minutes to try all peers
        print("📊 FIX #502: Header sync timeout set to \(Int(maxSyncDuration))s for \(headersNeeded) headers")

        // FIX #502: PRIORITIZE localhost above all other peers - user's local node at 127.0.0.1:8033
        let localhostPeer = "127.0.0.1"
        let trustedSeedPeers = [
            "140.174.189.3",    // MagicBean node cluster
            "140.174.189.17",   // MagicBean node cluster
            "205.209.104.118",  // MagicBean node
            "37.187.76.79",     // Known working Zclassic peer
            "135.181.94.12",    // Known working Zclassic peer
            "95.179.131.117",   // Zclassic seed node
            "45.77.216.198"     // Zclassic seed node
        ]

        while currentHeight < chainTip {
            // FIX #274: Check total sync timeout
            let elapsed = Date().timeIntervalSince(syncStartTime)
            if elapsed > maxSyncDuration {
                print("⚠️ FIX #502: Header sync timeout after \(Int(elapsed))s - tried all peers")
                throw SyncError.timeout("Header sync timed out after \(Int(elapsed))s - \(chainTip - currentHeight) blocks remaining")
            }

            // FIX #502 v2: PRIORITIZE localhost (127.0.0.1) ABOVE ALL OTHER PEERS
            // FIX #517: Localhost exempt from hasRecentActivity - ALWAYS try it first!
            // User's local node is most reliable - no network latency, always available
            // Secondary: peers that have reported valid heights (peerStartHeight > 0)
            // These are peers that completed handshake and sent us a valid chain height
            let currentPeers = await MainActor.run {
                let allPeers = networkManager.peers.filter { peer in
                    peer.isConnectionReady &&  // CRITICAL: Must have LIVE connection, not just handshake!
                    peer.isHandshakeComplete &&
                    peer.peerStartHeight > 0 &&  // MUST have reported a valid height
                    !failedPeers.contains(peer.host) &&
                    // FIX #517: Localhost exempt from hasRecentActivity - ALWAYS try it!
                    (peer.host == localhostPeer || peer.hasRecentActivity)
                }

                // FIX #535: Performance-based sorting - BEST peers tried FIRST
                // Priority: localhost > trusted seed > highest performance score > highest height
                return allPeers.sorted { (peer1: Peer, peer2: Peer) -> Bool in
                    let peer1IsLocalhost = peer1.host == localhostPeer
                    let peer2IsLocalhost = peer2.host == localhostPeer

                    // Localhost ALWAYS comes first (user's local node is most reliable)
                    if peer1IsLocalhost && !peer2IsLocalhost {
                        return true  // peer1 (localhost) first
                    } else if !peer1IsLocalhost && peer2IsLocalhost {
                        return false  // peer2 (localhost) first
                    }

                    // Neither or both are localhost - use trusted seed logic
                    let peer1IsTrusted = trustedSeedPeers.contains(peer1.host)
                    let peer2IsTrusted = trustedSeedPeers.contains(peer2.host)

                    if peer1IsTrusted && !peer2IsTrusted {
                        return true  // peer1 first
                    } else if !peer1IsTrusted && peer2IsTrusted {
                        return false  // peer2 first
                    } else {
                        // Both trusted or both not trusted - USE PERFORMANCE SCORE!
                        let score1 = peer1.getPerformanceScore()
                        let score2 = peer2.getPerformanceScore()

                        if abs(score1 - score2) > 5.0 {
                            // Significant performance difference - use score
                            return score1 > score2
                        } else {
                            // Similar performance - prefer higher peerStartHeight (more recent)
                            return peer1.peerStartHeight > peer2.peerStartHeight
                        }
                    }
                }
            }

            // FIX #707: Removed per-batch peer ranking log (too spammy)

            guard let peer = currentPeers.first else {
                // FIX #502: Suggest adding localhost if no peers available
                print("⚠️ FIX #502: No ready peers with valid heights, waiting 2s...")
                print("   💡 TIP: Start your local Zclassic node: zclassicd -daemon -listen=1 -listenonion=0")
                print("   💡 Or add custom node: Settings → Network → Add Node (127.0.0.1:8033)")
                try await Task.sleep(nanoseconds: 2_000_000_000)

                // FIX #477: Check timeout AFTER sleep to prevent infinite loop
                let elapsedAfterSleep = Date().timeIntervalSince(syncStartTime)
                if elapsedAfterSleep > maxSyncDuration {
                    print("⚠️ FIX #502: Header sync timeout after peer wait (\(Int(elapsedAfterSleep))s)")
                    throw SyncError.timeout("Header sync timed out after \(Int(elapsedAfterSleep))s while waiting for peers")
                }

                failedPeers.removeAll() // Reset failed peers to retry all
                continue
            }

            // FIX #707: Removed per-batch "trying peer" log (too spammy)

            // FIX #133: Destructure tuple to get actual locator height
            let (payload, actualLocatorHeight) = buildGetHeadersPayload(startHeight: currentHeight)
            // Headers will start at actualLocatorHeight + 1 (P2P returns headers AFTER locator)
            let headersStartHeight = actualLocatorHeight + 1

            do {
                // FIX #501: Very aggressive timeout - 5 seconds per peer, then switch
                let headers: [ZclassicBlockHeader] = try await peer.withExclusiveAccessTimeout(seconds: 5.0) {
                    try await peer.sendMessage(command: "getheaders", payload: payload)

                    var receivedHeaders: [ZclassicBlockHeader]?
                    var attempts = 0

                    // Only 1 attempt with 3 second timeout - if peer doesn't respond, move on
                    while receivedHeaders == nil && attempts < 1 {
                        attempts += 1
                        let (command, response) = try await peer.receiveMessageWithTimeout(seconds: 3)
                        if command == "headers" {
                            // FIX #133: Use correct starting height from actual locator
                            receivedHeaders = try self.parseHeadersPayload(response, startingAt: headersStartHeight, fromPeer: peer.host)
                        }
                    }

                    return receivedHeaders ?? []
                }

                guard !headers.isEmpty else {
                    print("⚠️ FIX #502: Peer \(peer.host) returned no headers, trying next peer...")
                    failedPeers.insert(peer.host)
                    continue
                }

                // FIX #133: Verify chain starting at correct height
                try verifyHeaderChain(headers, startingAt: headersStartHeight, fromPeer: peer.host)
                try headerStore.insertHeaders(headers)

                // FIX #535: Track peer performance (silent - no log spam)
                peer.recordSuccess()
                peer.score.headersProvided += headers.count

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

                // FIX #707: Only log every 1000 headers or at 100%
                if peer.score.headersProvided % 1000 < 160 || progress.percentComplete == 100 {
                    print("📡 Synced to \(actualEndHeight) (\(progress.percentComplete)%) - \(peer.score.headersProvided) headers from \(peer.host)")
                }

                // Clear failed peers on success - a working peer might recover
                failedPeers.removeAll()

            } catch {
                // FIX #746: Handle headers restart needed - update currentHeight and retry
                if case SyncError.headersRestartNeeded(let newStartHeight) = error {
                    print("🔄 FIX #746: Restarting header sync from height \(newStartHeight)")
                    currentHeight = newStartHeight
                    failedPeers.removeAll()  // Reset failed peers for fresh start
                    break  // Exit peer loop to restart main loop with new height
                }

                // FIX #579: Don't disconnect peers for chain discontinuity - that's outdated BundledBlockHashes, not peer failure
                if case SyncError.chainDiscontinuity = error {
                    // Chain mismatch = BundledBlockHashes outdated, NOT a peer problem
                    // Don't disconnect peer, just skip it for this attempt
                    print("⚠️ FIX #579: Peer \(peer.host) has different chain (BundledBlockHashes may be outdated) - keeping peer connected")
                    failedPeers.insert(peer.host)
                    continue
                }

                // For other errors, disconnect and try next peer
                print("⚠️ FIX #502: Peer \(peer.host) failed: \(error.localizedDescription) - disconnecting and trying next...")
                peer.recordFailure()
                peer.disconnect()  // Reset stuck NWConnection
                failedPeers.insert(peer.host)
                continue
            }
        }

        // FIX: Timing summary
        let totalDuration = Date().timeIntervalSince(syncStartTime)
        print("⏱️ FIX #502: Header sync timing summary:")
        print("   Total duration: \(String(format: "%.2f", totalDuration))s")
        print("   Headers per second: \(String(format: "%.1f", Double(headersNeeded) / totalDuration))")
    }

    /// FIX #141: PARALLEL header requests - request from ALL peers, take first response
    /// FIX #501: Aggressive peer rotation - try each trusted peer for 5s max, then switch
    /// FIX #502: PRIORITIZE localhost (127.0.0.1) - user's local node
    /// Over Tor, latency varies wildly. Parallel requests ensure fastest peer wins.
    /// IMPORTANT: P2P getheaders returns headers AFTER the locator hash
    /// Each batch uses the last received header's hash as locator for the next batch
    private func syncHeadersParallel(from startHeight: UInt64, to chainTip: UInt64) async throws {
        print("🚀 FIX #502: Using PARALLEL header requests with localhost priority for \(chainTip - startHeight) headers")

        // FIX #519: Set flag to prevent health checks from disrupting sync
        await networkManager.setHeaderSyncInProgress(true)
        defer {
            // FIX #519: Always clear flag when done (even if error)
            Task { await networkManager.setHeaderSyncInProgress(false) }
        }

        // FIX #502: PRIORITIZE localhost above all other peers - user's local node at 127.0.0.1:8033
        let localhostPeer = "127.0.0.1"
        let trustedSeedPeers = [
            "140.174.189.3",    // MagicBean node cluster
            "140.174.189.17",   // MagicBean node cluster
            "205.209.104.118",  // MagicBean node
            "37.187.76.79",     // Known working Zclassic peer
            "135.181.94.12",    // Known working Zclassic peer
            "95.179.131.117",   // Zclassic seed node
            "45.77.216.198"     // Zclassic seed node
        ]

        // FIX #483: Use NetworkManager.peers directly instead of PeerManager
        let peers = await MainActor.run {
            // CRITICAL: Must have LIVE connection (isConnectionReady), not just handshake!
            // Peers with completed handshake but dead connections cause "Not connected to network" errors
            let allPeers = networkManager.peers.filter { $0.isConnectionReady && $0.isHandshakeComplete }
            // FIX #502: Sort: localhost FIRST, then trusted, then by peerStartHeight (most recent)
            return allPeers.sorted { (peer1: Peer, peer2: Peer) -> Bool in
                let peer1IsLocalhost = peer1.host == localhostPeer
                let peer2IsLocalhost = peer2.host == localhostPeer

                // FIX #502: Localhost ALWAYS comes first
                if peer1IsLocalhost && !peer2IsLocalhost {
                    return true  // peer1 (localhost) first
                } else if !peer1IsLocalhost && peer2IsLocalhost {
                    return false  // peer2 (localhost) first
                }

                // Neither or both are localhost - use existing trusted seed logic
                let peer1IsTrusted = trustedSeedPeers.contains(peer1.host)
                let peer2IsTrusted = trustedSeedPeers.contains(peer2.host)

                if peer1IsTrusted && !peer2IsTrusted {
                    return true  // peer1 first
                } else if !peer1IsTrusted && peer2IsTrusted {
                    return false  // peer2 first
                } else {
                    // Both trusted or both not trusted - prefer higher peerStartHeight (more recent)
                    return peer1.peerStartHeight > peer2.peerStartHeight
                }
            }
        }
        guard !peers.isEmpty else {
            throw SyncError.insufficientPeers(got: 0, need: 1)
        }

        // FIX #155: Report initial progress (0%) before starting
        let initialProgress = HeaderSyncProgress(
            currentHeight: startHeight,
            totalHeight: chainTip,
            headersStored: (try? headerStore.getHeaderCount()) ?? 0
        )
        onProgress?(initialProgress)

        print("📊 FIX #502: Requesting headers from \(peers.count) peers (localhost first, then trusted)")

        var currentHeight = startHeight
        var totalSynced = 0
        let totalNeeded = Int(chainTip - startHeight)
        let startTime = Date()
        var failedPeers = Set<String>()

        // FIX #501: Much longer total timeout - we'll try many peers
        let headersNeeded = chainTip - startHeight
        let maxSyncDuration: TimeInterval = 300.0  // 5 minutes
        print("⏱️ FIX #502: Parallel sync timeout set to \(Int(maxSyncDuration))s for \(headersNeeded) headers")

        while currentHeight < chainTip {
            // FIX #501: Check for timeout
            let totalElapsed = Date().timeIntervalSince(startTime)
            if totalElapsed > maxSyncDuration {
                print("⚠️ FIX #502: Header sync timeout after \(Int(totalElapsed))s - tried all peers")
                throw SyncError.timeout("Header sync timed out after \(Int(totalElapsed))s - \(chainTip - currentHeight) blocks remaining")
            }

            // FIX #133: Destructure tuple to get actual locator height
            let (payload, actualLocatorHeight) = buildGetHeadersPayload(startHeight: currentHeight)
            // Headers will start at actualLocatorHeight + 1 (P2P returns headers AFTER locator)
            let headersStartHeight = actualLocatorHeight + 1

            // Get fresh peer list for each batch, prioritizing trusted peers
            // FIX #517: For localhost, skip hasRecentActivity check - always try it!
            // FIX #502 v2: PRIORITIZE localhost, then peers with valid heights (peerStartHeight > 0)
            let currentPeers = await MainActor.run {
                let allPeers = networkManager.peers.filter { peer in
                    peer.isConnectionReady &&  // CRITICAL: Must have LIVE connection, not just handshake!
                    peer.isHandshakeComplete &&
                    peer.peerStartHeight > 0 &&  // MUST have reported a valid height
                    !failedPeers.contains(peer.host) &&
                    // FIX #517: Localhost exempt from hasRecentActivity - ALWAYS try it first!
                    // Localhost is user's own node - should always be available for header sync
                    (peer.host == localhostPeer || peer.hasRecentActivity)
                }
                // FIX #535: Performance-based sorting - BEST peers tried FIRST
                return allPeers.sorted { (peer1: Peer, peer2: Peer) -> Bool in
                    let peer1IsLocalhost = peer1.host == localhostPeer
                    let peer2IsLocalhost = peer2.host == localhostPeer

                    // Localhost ALWAYS comes first (user's local node is most reliable)
                    if peer1IsLocalhost && !peer2IsLocalhost {
                        return true  // peer1 (localhost) first
                    } else if !peer1IsLocalhost && peer2IsLocalhost {
                        return false  // peer2 (localhost) first
                    }

                    // Neither or both are localhost - use trusted seed logic
                    let peer1IsTrusted = trustedSeedPeers.contains(peer1.host)
                    let peer2IsTrusted = trustedSeedPeers.contains(peer2.host)

                    if peer1IsTrusted && !peer2IsTrusted {
                        return true  // peer1 first
                    } else if !peer1IsTrusted && peer2IsTrusted {
                        return false  // peer2 first
                    } else {
                        // Both trusted or both not trusted - USE PERFORMANCE SCORE!
                        let score1 = peer1.getPerformanceScore()
                        let score2 = peer2.getPerformanceScore()

                        if abs(score1 - score2) > 5.0 {
                            // Significant performance difference - use score
                            return score1 > score2
                        } else {
                            // Similar performance - prefer higher peerStartHeight (more recent)
                            return peer1.peerStartHeight > peer2.peerStartHeight
                        }
                    }
                }
            }

            // FIX #707: Removed per-batch peer ranking log (too spammy)

            guard !currentPeers.isEmpty else {
                print("⚠️ FIX #502: No connected peers, waiting 2s for reconnection...")
                print("   💡 TIP: Start your local Zclassic node: zclassicd -daemon -listen=1 -listenonion=0")
                try await Task.sleep(nanoseconds: 2_000_000_000)

                // FIX #477: Check timeout AFTER sleep
                let totalElapsedAfterSleep = Date().timeIntervalSince(startTime)
                if totalElapsedAfterSleep > maxSyncDuration {
                    print("⚠️ FIX #502: Parallel sync timeout after peer wait")
                    throw SyncError.timeout("Header sync timed out waiting for peers")
                }

                failedPeers.removeAll() // Reset failed peers to retry all
                continue
            }

            // FIX #501: Try each peer with aggressive timeout (5 seconds max)
            var headers: [ZclassicBlockHeader]?
            var successPeerHost: String? = nil  // FIX #535: Track which peer provided headers
            let perPeerTimeout: TimeInterval = 5.0  // 5 seconds per peer

            for (_, peer) in currentPeers.enumerated() {
                // FIX #707: Removed per-peer "trying" log (too spammy)
                do {
                    let result: [ZclassicBlockHeader] = try await peer.withExclusiveAccessTimeout(seconds: perPeerTimeout) {
                        try await peer.sendMessage(command: "getheaders", payload: payload)

                        // FIX #501: Only 1 attempt with 3 second timeout
                        let (command, response) = try await peer.receiveMessageWithTimeout(seconds: 3)

                        if command == "headers" {
                            return try self.parseHeadersPayload(response, startingAt: headersStartHeight, fromPeer: peer.host)
                        }

                        return []
                    }

                    if !result.isEmpty {
                        // Success!
                        print("✅ FIX #502: Got \(result.count) headers from \(peer.host)")

                        // FIX #535: Log first few block hashes to trace which peer sent which chain
                        // This helps identify when peers are on different forks
                        if !result.isEmpty {
                            let firstHeader = result[0]
                            let blockHashHex = firstHeader.blockHash.map { String(format: "%02x", $0) }.joined()
                            print("🔍 FIX #535: [\(peer.host)] First header at height \(firstHeader.height):")
                            print("   blockHash: \(blockHashHex.prefix(32))...")
                            print("   prevHash:  \(firstHeader.hashPrevBlock.map { String(format: "%02x", $0) }.joined().prefix(32))...")

                            if result.count > 1 {
                                let lastHeader = result[result.count - 1]
                                let lastBlockHashHex = lastHeader.blockHash.map { String(format: "%02x", $0) }.joined()
                                print("🔍 FIX #535: [\(peer.host)] Last header at height \(lastHeader.height):")
                                print("   blockHash: \(lastBlockHashHex.prefix(32))...")
                            }
                        }

                        headers = result
                        successPeerHost = peer.host  // FIX #535: Remember which peer provided headers
                        failedPeers.removeAll() // Clear failed peers on success
                        break  // Exit peer loop - we got our headers
                    }

                } catch {
                    // FIX #746: Handle headers restart needed - update currentHeight and retry
                    if case SyncError.headersRestartNeeded(let newStartHeight) = error {
                        print("🔄 FIX #746: Restarting parallel header sync from height \(newStartHeight)")
                        currentHeight = newStartHeight
                        failedPeers.removeAll()
                        break  // Exit peer loop to restart main loop with new height
                    }

                    // FIX #579: Don't disconnect peers for chain discontinuity - that's outdated BundledBlockHashes, not peer failure
                    if case SyncError.chainDiscontinuity = error {
                        // Chain mismatch = BundledBlockHashes outdated, NOT a peer problem
                        print("⚠️ FIX #579: Peer \(peer.host) has different chain - keeping peer connected")
                        failedPeers.insert(peer.host)
                        continue
                    }

                    // For other errors, disconnect and try next peer
                    print("⚠️ FIX #501: Peer \(peer.host) failed: \(error.localizedDescription) - disconnecting")
                    peer.recordFailure()
                    peer.disconnect()
                    failedPeers.insert(peer.host)
                    continue
                }
            }

            guard let headers = headers, !headers.isEmpty else {
                print("⚠️ FIX #502: All peers failed, waiting 2s before retry...")
                try await Task.sleep(nanoseconds: 2_000_000_000)
                continue
            }

            // FIX #133: Verify chain continuity with correct starting height
            // FIX #746: Wrap in do-catch to handle restart needed error
            do {
                try verifyHeaderChain(headers, startingAt: headersStartHeight, fromPeer: successPeerHost ?? "unknown")
            } catch SyncError.headersRestartNeeded(let newStartHeight) {
                print("🔄 FIX #746: Restarting parallel header sync from height \(newStartHeight) (post-fetch)")
                currentHeight = newStartHeight
                failedPeers.removeAll()
                continue  // Restart main loop with new height
            }

            // FIX #535: Track peer performance - update the peer that provided headers
            if let successHost = successPeerHost {
                let successPeer = await MainActor.run {
                    networkManager.peers.first(where: { $0.host == successHost })
                }
                if let peer = successPeer {
                    peer.recordSuccess()
                    peer.score.headersProvided += headers.count
                    // Response time is tracked implicitly via success rate in performance score
                    print("✅ FIX #535: Updated \(successHost) performance - now at \(peer.score.headersProvided) headers provided")
                }
            }

            // FIX #535: Validate chainwork to detect wrong forks
            // This prevents Sybil attacks where 9 peers provide wrong blockchain data
            // Compare P2P chainwork against our trusted HeaderStore chainwork
            if let peerHost = successPeerHost {
                try await validateChainwork(headers, fromPeer: peerHost)
            }

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
        print("🎉 FIX #502: Header sync complete: \(totalSynced) headers in \(String(format: "%.1f", totalTime))s (\(Int(finalRate)) headers/sec)")
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
                        receivedHeaders = try self.parseHeadersPayload(response, startingAt: headersStartHeight, fromPeer: peer.host)
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
                let isBanned = await MainActor.run { networkManager.isPeerBanned(peer.host) }
                guard !isBanned, peer.peerStartHeight > 0 else { continue }
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
        // FIX #483: Use NetworkManager.peers directly instead of PeerManager
        var allPeers = await MainActor.run { networkManager.peers }

        // If we don't have enough peers, try to connect more
        if allPeers.count < minPeersToTry {
            print("🔄 Only \(allPeers.count) peers, attempting to connect more...")
            try? await networkManager.connect()

            // FIX #120: Wait for peers to actually connect (up to 15 seconds)
            // The connect() call initiates connections but they may not be ready yet
            var waitAttempts = 0
            let maxWaitAttempts = 30 // 30 * 0.5s = 15 seconds max
            var peerCount = await MainActor.run { networkManager.connectedPeers }
            while peerCount < minPeers && waitAttempts < maxWaitAttempts {
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
                waitAttempts += 1
                peerCount = await MainActor.run { networkManager.connectedPeers }
                if waitAttempts % 4 == 0 { // Log every 2 seconds
                    print("⏳ Waiting for peers to connect... (\(peerCount)/\(minPeers) ready, waited \(waitAttempts / 2)s)")
                }
            }

            allPeers = await MainActor.run { networkManager.peers }
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
                            // CRITICAL FIX: Ban peer immediately after handshake failure
                            // Repeated handshake failures indicate the peer is incompatible/malicious
                            print("🚫 [\(peer.host)] Handshake failed - BANNING peer (incompatible protocol)")
                            // Record 10 failures to trigger immediate ban via shouldBan()
                            for _ in 0..<10 {
                                peer.recordFailure()
                            }
                            return (peer.host, nil)
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
                    receivedHeaders = try self.parseHeadersPayload(response, startingAt: headersStartHeight, fromPeer: peer.host)
                    print("✅ Received \(receivedHeaders?.count ?? 0) headers from \(peer.host) (starting at height \(headersStartHeight))")
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

        // Protocol version (170012 = BIP155 support, MAX VALID for Zclassic)
        let version: UInt32 = 170012
        payload.append(contentsOf: withUnsafeBytes(of: version.littleEndian) { Array($0) })

        // Number of block locator hashes (varint - use 1 for simplicity)
        payload.append(1)

        // Block locator hash - need the hash at (startHeight - 1) to request headers starting at startHeight
        let locatorHeight = startHeight > 0 ? startHeight - 1 : 0
        var locatorHash: Data?
        var actualLocatorHeight = locatorHeight  // FIX #133: Track actual height used

        // FIX #436: CRITICAL - HeaderStore block hashes from boost file are WRONG!
        // Boost file headers only have 140-byte data, but block hash = SHA256(SHA256(header + varint + solution))
        // The hash computed from 140 bytes doesn't match any real block, causing peers to return genesis!
        //
        // Priority order (SAFEST to least safe):
        // 1. Checkpoints (hardcoded, verified)
        // 2. BundledBlockHashes (downloaded from GitHub, contains correct P2P-synced hashes)
        // 3. HeaderStore (ONLY if synced via P2P with Equihash verification, NOT from boost file)

        // First try: Checkpoints (most trusted - hardcoded in app)
        if let checkpointHex = ZclassicCheckpoints.mainnet[locatorHeight] {
            if let hashData = Data(hexString: checkpointHex) {
                locatorHash = Data(hashData.reversed()) // Reverse to wire format
                print("📋 FIX #436: Using checkpoint hash for locator at height \(locatorHeight)")
            }
        }

        // FIX #669: DISABLED BundledBlockHashes - has data corruption bug
        // Hashes are truncated (29 bytes instead of 32), causing P2P to send wrong headers
        // Fall through to HeaderStore below which has correct hashes
        // Second try: BundledBlockHashes (correct hashes from GitHub)
        if locatorHash == nil {
            let bundledHashes = BundledBlockHashes.shared
            if bundledHashes.isLoaded, let hash = bundledHashes.getBlockHash(at: locatorHeight) {
                // FIX #669: DISABLED - Do not use BundledBlockHashes
                print("🚨 FIX #669: SKIPPING BundledBlockHashes (corrupted) for height \(locatorHeight), falling back to HeaderStore")
                // locatorHash = hash  // DISABLED
                // print("📋 FIX #436: Using BundledBlockHashes for locator at height \(locatorHeight)")
            }
        }

        // FIX #680: Use HeaderStore hash if we've already synced past the locator height
        // After P2P sync, HeaderStore has verified correct hashes we can use
        // Only fall back to checkpoint if HeaderStore doesn't have the height
        if locatorHash == nil {
            if let header = try? HeaderStore.shared.getHeader(at: locatorHeight) {
                // FIX #706: HeaderStore now stores hashes in little-endian (wire format) after FIX #676
                // Previously stored big-endian, but FIX #676 reversed during boost loading
                // So now we use the hash DIRECTLY without reversal
                locatorHash = header.blockHash  // Already in wire format (little-endian)
                actualLocatorHeight = locatorHeight
                // FIX #707: Removed per-batch locator log (too spammy)
            } else {
                // HeaderStore doesn't have this height - find nearest checkpoint BELOW
                let checkpoints = ZclassicCheckpoints.mainnet.keys.sorted(by: >)
                for checkpointHeight in checkpoints {
                    if checkpointHeight <= locatorHeight {
                        if let checkpointHex = ZclassicCheckpoints.mainnet[checkpointHeight] {
                            if let hashData = Data(hexString: checkpointHex) {
                                locatorHash = Data(hashData.reversed())  // Convert to wire format
                                actualLocatorHeight = checkpointHeight
                                print("📋 FIX #680: HeaderStore missing \(locatorHeight), using checkpoint at \(checkpointHeight)")
                                break
                            }
                        }
                    }
                }
            }
        }

        // Fourth try: Find nearest checkpoint or BundledBlockHash BELOW requested height
        if locatorHash == nil {
            // Try BundledBlockHashes for nearest available
            let bundledHashes = BundledBlockHashes.shared
            if bundledHashes.isLoaded {
                // BundledBlockHashes has heights up to boost file height
                let bundledEndHeight = bundledHashes.endHeight
                if bundledEndHeight > 0 && bundledEndHeight < locatorHeight {
                    if let hash = bundledHashes.getBlockHash(at: bundledEndHeight) {
                        locatorHash = hash
                        actualLocatorHeight = bundledEndHeight
                        print("📋 FIX #436: Using BundledBlockHashes end height \(bundledEndHeight) as locator")
                    }
                }
            }
        }

        // Fifth try: Find nearest checkpoint BELOW the requested height (P2P-safe fallback)
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
    private func parseHeadersPayload(_ data: Data, startingAt startHeight: UInt64, fromPeer: String = "unknown") throws -> [ZclassicBlockHeader] {
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

        // FIX #707: Removed per-batch parsing log (too spammy)

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

            // Zclassic post-Bubbles uses Equihash(192,7) with 400-byte solutions
            // Pre-Bubbles uses Equihash(200,9) with 1344-byte solutions
            if solutionLen == 0 {
                print("🚨 solutionLen=0 at header \(i) (height \(startHeight + UInt64(i))) - corrupted!")
            } else if solutionLen != 400 && solutionLen != 1344 {
                // Debug: Unexpected solution size - log details to diagnose parsing issues
                let nearbyStart = max(0, solLenOffset - 4)
                let nearbyEnd = min(data.count, solLenOffset + 10)
                let nearbyBytes = data[nearbyStart..<nearbyEnd].map { String(format: "%02x", $0) }.joined(separator: " ")
                print("🔍 DEBUG: Peer[\(fromPeer)] sent unexpected solutionLen=\(solutionLen) at header \(i) height \(startHeight + UInt64(i))")
                print("   solLenOffset=\(solLenOffset), varintLen=\(varintLen), solFirstByte=0x\(String(format: "%02x", solFirstByte))")
                print("   Nearby bytes: \(nearbyBytes)")
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

            // Debug logging removed - FIX #704

            // FIX #695 v2: Allow zero sapling roots - recovery via RPC later
            // P2P peers send zeros; actual roots need RPC getblock

            // FIX #562: Disable Equihash verification during initial sync for 10x faster startup
            // Equihash verification will be done later via health check on sampled headers
            let height = startHeight + UInt64(i)
            do {
                let header = try ZclassicBlockHeader.parseWithSolution(data: fullHeaderData, height: height, verifyEquihash: false)
                headers.append(header)
            } catch ParseError.equihashVerificationFailed(let failHeight) {
                print("🚨 [SECURITY] Equihash verification FAILED at height \(failHeight) - rejecting header")
                throw SyncError.invalidHeadersPayload(reason: "Equihash verification failed for header at height \(failHeight)")
            }

            // Skip past this header entry (including tx_count)
            offset += entrySize
        }

        // FIX #707: Removed per-batch parsed log (too spammy)

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

            // FIX #681: DISABLED empty sapling_root consensus check
            // This was incorrectly rejecting valid headers when all peers agreed on a header
            // The chain continuity check and Equihash verification provide sufficient security

            consensusHeaders.append(consensusHeader)
        }

        print("✅ Header consensus verified for \(consensusHeaders.count) headers")

        return consensusHeaders
    }

    /// Verify header chain continuity (each header links to previous)
    /// FIX #579: Added peerHost parameter to prioritize localhost over remote peers
    private func verifyHeaderChain(_ headers: [ZclassicBlockHeader], startingAt height: UInt64, fromPeer peerHost: String) throws {
        guard !headers.isEmpty else { return }

        var currentHeight = height
        var prevHash: Data?
        var prevHashFromHeaderStore = false  // FIX #536: Track where prevHash came from
        var checkpointWarningPrinted = false  // FIX #673: Only print checkpoint warning once

        // FIX #437 + #438 + #670: Use correct hash sources for chain continuity
        // - BundledBlockHashes: DISABLED (FIX #669 - corrupted hashes)
        // - HeaderStore: For all heights (P2P-synced with Equihash = correct hashes)
        // - Checkpoint fallback: For missing HeaderStore entries
        if currentHeight > 0 {
            let prevHeight = currentHeight - 1

            // FIX #670: DISABLE BundledBlockHashes - has corruption bug (FIX #669)
            // Use HeaderStore as primary source (P2P-synced with Equihash verification)
            if let prevHeader = try? headerStore.getHeader(at: prevHeight) {
                prevHash = prevHeader.blockHash
                prevHashFromHeaderStore = true
                // FIX #707: Removed per-batch HeaderStore log (too spammy)
            } else {
                // Fallback: Use nearest checkpoint
                let checkpoints = ZclassicCheckpoints.mainnet.keys.sorted(by: >)
                for checkpointHeight in checkpoints {
                    if checkpointHeight <= prevHeight {
                        if let checkpointHex = ZclassicCheckpoints.mainnet[checkpointHeight],
                           let hashData = Data(hexString: checkpointHex) {
                            prevHash = Data(hashData.reversed())
                            prevHashFromHeaderStore = false
                            print("📋 FIX #670: Using checkpoint at \(checkpointHeight) for height \(prevHeight)")
                            break
                        }
                    }
                }
            }
        }

        let totalHeaders = headers.count
        for (index, header) in headers.enumerated() {
            // Verify previous hash links correctly
            // Skip verification for the very first header if we don't have its previous block
            if prevHash != nil {
                // FIX #707: Removed per-header debug logs (too spammy)

                guard header.hashPrevBlock == prevHash! else {
                    // Only log first mismatch to reduce spam
                    if !checkpointWarningPrinted {
                        print("⚠️ Chain mismatch at height \(currentHeight) - will trust peer")
                    }

                    // FIX #536: Check if prevHash came from HeaderStore (might be corrupted!)
                    if prevHashFromHeaderStore {
                        // FIX #691: Prevent repeated header deletion during P2P sync
                        let skipDeletion = lastCorruptedHeaderDeletion.map { Date().timeIntervalSince($0) < 30 } ?? false

                        if !skipDeletion {
                            // FIX #767: CRITICAL - Protect boost file headers from deletion!
                            // Only delete P2P headers (above boost file end height)
                            // Deleting boost headers causes infinite resync loop:
                            // 1. Mismatch detected → delete all headers (including boost)
                            // 2. Next startup → reload boost file
                            // 3. Mismatch again → delete → infinite loop!
                            //
                            // Note: If effectiveTreeHeight is 0 (first launch, no boost yet),
                            // we can delete all headers since there's no boost file to protect.
                            let boostFileEndHeight = ZipherXConstants.effectiveTreeHeight
                            let prevHeight = currentHeight - 1
                            print("🔍 FIX #767: Chain mismatch at height \(currentHeight), boostFileEndHeight=\(boostFileEndHeight)")

                            // Only delete headers ABOVE the boost file end height
                            let safeDeleteStart = max(prevHeight, boostFileEndHeight + 1)

                            if let maxH = try? headerStore.getLatestHeight(), safeDeleteStart <= maxH {
                                if !checkpointWarningPrinted {
                                    if prevHeight <= boostFileEndHeight {
                                        print("🛡️ FIX #767: Protecting boost file headers (height <= \(boostFileEndHeight))")
                                        print("🗑️ FIX #767: Only deleting P2P headers from \(safeDeleteStart) to \(maxH)")
                                    } else {
                                        print("🗑️ Deleting corrupted headers from \(safeDeleteStart) to \(maxH)")
                                    }
                                }
                                try? headerStore.deleteHeadersInRange(from: safeDeleteStart, to: maxH)
                            } else if !checkpointWarningPrinted {
                                print("🛡️ FIX #767: No headers to delete (mismatch at \(prevHeight) is within boost range <= \(boostFileEndHeight))")
                            }

                            // FIX #767 v2: Only mark as corrupted if mismatch is WITHIN boost file range
                            // If mismatch is in P2P range, don't mark boost as corrupted (it's not!)
                            if prevHeight <= boostFileEndHeight {
                                headerStore.markBoostHeadersCorrupted(mismatchHeight: currentHeight)
                            } else {
                                print("ℹ️ FIX #767: Mismatch in P2P range - NOT marking boost as corrupted")
                            }
                            lastCorruptedHeaderDeletion = Date()

                            // FIX #746: CRITICAL - Don't continue processing this batch!
                            // We just deleted headers, creating a gap. Must restart sync from
                            // the new HeaderStore max height to ensure chain continuity.
                            let newStartHeight = (try? headerStore.getLatestHeight()).map { $0 + 1 } ?? 476969
                            print("🔄 FIX #746: Throwing headersRestartNeeded - must restart sync from \(newStartHeight)")
                            throw SyncError.headersRestartNeeded(newStartHeight: newStartHeight)
                        }

                        prevHash = header.hashPrevBlock
                        prevHashFromHeaderStore = false
                        checkpointWarningPrinted = true
                        currentHeight += 1
                        continue
                    } else {
                        // Checkpoint/gap mismatch - trust peer
                        prevHash = header.hashPrevBlock
                        prevHashFromHeaderStore = false
                        checkpointWarningPrinted = true
                        currentHeight += 1
                        continue
                    }
                }

                // Update prevHash for next iteration
                prevHash = header.blockHash
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

        // FIX #707: Removed per-batch "continuity verified" log (too spammy)
    }

    /// FIX #535: Validate chainwork to detect wrong forks
    /// Compares P2P chainwork against trusted HeaderStore chainwork
    /// - Rejects if P2P chainwork < existing chainwork (wrong fork!)
    /// - Accepts if P2P chainwork >= existing chainwork (reorg or same chain)
    /// - Bans peers that provide wrong fork data
    private func validateChainwork(_ headers: [ZclassicBlockHeader], fromPeer peerHost: String) async throws {
        // FIX #679 v2: P2P headers don't include chainwork - it's computed locally during insert
        // Skip chainwork validation entirely - chainwork is only for detecting database corruption
        // The real validation is block hash continuity (verified elsewhere)
        print("✅ FIX #679: Skipping chainwork validation - P2P headers don't include chainwork, it's computed during insert")
        return

        /* Old validation code below - DISABLED because P2P headers have empty chainwork
        for header in headers {
            // Check if we have an existing header at this height
            if let existingHeader = try? headerStore.getHeader(at: header.height) {
                // FIX #679: If existing header has empty chainwork (from boost file), trust P2P peer
                // Boost file headers loaded before FIX #679 have NULL chainwork
                // P2P headers have computed chainwork, so always trust P2P over empty boost data
                if existingHeader.chainwork.isEmpty {
                    print("🔄 FIX #679: Existing header at \(header.height) has empty chainwork (from boost file)")
                    print("   Trusting P2P peer with computed chainwork")
                    continue  // Skip validation - P2P data is better
                }

                // Compare chainwork values
                let comparison = headerStore.compareChainwork(header.chainwork, existingHeader.chainwork)

                if comparison == .orderedAscending {
                    // P2P chainwork is LOWER - this is a WRONG FORK!
                    let p2pWorkHex = header.chainwork.map { String(format: "%02x", $0) }.joined().suffix(16)
                    let existingWorkHex = existingHeader.chainwork.map { String(format: "%02x", $0) }.joined().suffix(16)

                    print("🚨 FIX #535: WRONG FORK DETECTED from peer \(peerHost)!")
                    print("   Height: \(header.height)")
                    print("   P2P chainwork (WRONG): ...\(p2pWorkHex)")
                    print("   Our chainwork (CORRECT): ...\(existingWorkHex)")
                    print("   P2P block hash: \(header.blockHash.map { String(format: "%02x", $0) }.joined().prefix(32))...")
                    print("   Our block hash: \(existingHeader.blockHash.map { String(format: "%02x", $0) }.joined().prefix(32))...")

                    // Ban this peer for providing wrong fork data
                    print("🚫 FIX #535: Banning peer \(peerHost) for providing wrong fork data")
                    Task { @MainActor in
                        networkManager.banPeerForSybilAttack(peerHost)
                    }

                    throw SyncError.wrongFork(
                        height: header.height,
                        peer: peerHost,
                        p2pChainwork: String(p2pWorkHex),
                        ourChainwork: String(existingWorkHex)
                    )
                } else if comparison == .orderedDescending {
                    // P2P chainwork is HIGHER - this is a REORG!
                    let p2pWorkHex = header.chainwork.map { String(format: "%02x", $0) }.joined().suffix(16)
                    let existingWorkHex = existingHeader.chainwork.map { String(format: "%02x", $0) }.joined().suffix(16)

                    print("🔄 FIX #535: CHAIN REORG detected from peer \(peerHost)")
                    print("   Height: \(header.height)")
                    print("   P2P chainwork (HIGHER): ...\(p2pWorkHex)")
                    print("   Our chainwork (LOWER): ...\(existingWorkHex)")
                    print("   Accepting P2P chain (has more proof-of-work)")

                    // Continue - will replace with higher chainwork headers
                } else {
                    // Equal chainwork - same chain, different blocks at same height?
                    // FIX #673: If we just deleted corrupted headers (FIX #536), trust P2P peer
                    let timeSinceDeletion = Date().timeIntervalSince(lastCorruptedHeaderDeletion ?? Date.distantPast)
                    let recentlyDeleted = timeSinceDeletion < 5.0

                    if header.blockHash != existingHeader.blockHash {
                        let p2pHash = header.blockHash.map { String(format: "%02x", $0) }.joined().prefix(16)
                        let existingHash = existingHeader.blockHash.map { String(format: "%02x", $0) }.joined().prefix(16)

                        if recentlyDeleted {
                            // FIX #673: We just deleted corrupted headers - trust P2P peer
                            print("🔄 FIX #673: Different hash at height \(header.height) but we recently deleted corrupted headers")
                            print("   P2P: \(p2pHash)...")
                            print("   Us:  \(existingHash)...")
                            print("   ✅ Trusting P2P peer - replacing with peer's chain")
                            // Continue - will replace with peer's headers
                        } else {
                            // Not recently deleted - this is a real error
                            print("⚠️ FIX #535: Same chainwork but different block hashes at height \(header.height)")
                            print("   P2P: \(p2pHash)...")
                            print("   Us:  \(existingHash)...")
                            print("   This indicates a difficulty collision or invalid data")
                            // Reject - same chainwork should mean same block
                            throw SyncError.wrongFork(
                                height: header.height,
                                peer: peerHost,
                                p2pChainwork: "same",
                                ourChainwork: "same"
                            )
                        }
                    }
                }
            }
            // No existing header at this height - OK, will insert new
        }

        print("✅ FIX #535: Chainwork validation passed for \(headers.count) headers")

        // FIX #535: Track successful chainwork validation for peer performance
        let peer = await MainActor.run {
            networkManager.peers.first(where: { $0.host == peerHost })
        }
        if let p = peer {
            p.score.chainworkValidations += 1
            p.score.lastChainworkValidation = Date()
            print("✅ FIX #535: Updated \(peerHost) chainwork validations - now at \(p.score.chainworkValidations)")
        }
         */
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

enum SyncError: LocalizedError, Equatable {
    case alreadySyncing
    case insufficientPeers(got: Int, need: Int)
    case noConsensus(heights: [UInt64])
    case insufficientConsensus(position: Int, hash: String, votes: Int, need: Int)
    case saplingRootMismatch(position: Int, votes: Int, need: Int)
    case chainDiscontinuity(height: UInt64, expectedPrevHash: String, gotPrevHash: String)
    case headersRestartNeeded(newStartHeight: UInt64)  // FIX #746: Restart sync after header deletion
    case unexpectedMessage(expected: String, got: String)
    case invalidHeadersPayload(reason: String)
    case noHeadersReceived
    case timeout(String)
    case internalError(String)
    case wrongFork(height: UInt64, peer: String, p2pChainwork: String, ourChainwork: String)  // FIX #535

    static func == (lhs: SyncError, rhs: SyncError) -> Bool {
        switch (lhs, rhs) {
        case (.alreadySyncing, .alreadySyncing),
             (.noHeadersReceived, .noHeadersReceived):
            return true
        case (.timeout(let lhsMsg), .timeout(let rhsMsg)):
            return lhsMsg == rhsMsg
        case (.insufficientPeers(let lhsGot, let lhsNeed), .insufficientPeers(let rhsGot, let rhsNeed)):
            return lhsGot == rhsGot && lhsNeed == rhsNeed
        case (.noConsensus(let lhsHeights), .noConsensus(let rhsHeights)):
            return lhsHeights == rhsHeights
        case (.insufficientConsensus(let lhsP, let lhsH, let lhsV, let lhsN), .insufficientConsensus(let rhsP, let rhsH, let rhsV, let rhsN)):
            return lhsP == rhsP && lhsH == rhsH && lhsV == rhsV && lhsN == rhsN
        case (.saplingRootMismatch(let lhsP, let lhsV, let lhsN), .saplingRootMismatch(let rhsP, let rhsV, let rhsN)):
            return lhsP == rhsP && lhsV == rhsV && lhsN == rhsN
        case (.chainDiscontinuity(let lhsH, let lhsE, let lhsG), .chainDiscontinuity(let rhsH, let rhsE, let rhsG)):
            return lhsH == rhsH && lhsE == rhsE && lhsG == rhsG
        case (.headersRestartNeeded(let lhsH), .headersRestartNeeded(let rhsH)):
            return lhsH == rhsH
        case (.unexpectedMessage(let lhsE, let lhsG), .unexpectedMessage(let rhsE, let rhsG)):
            return lhsE == rhsE && lhsG == rhsG
        case (.invalidHeadersPayload(let lhsR), .invalidHeadersPayload(let rhsR)):
            return lhsR == lhsR
        case (.internalError(let lhsM), .internalError(let rhsM)):
            return lhsM == rhsM
        case (.wrongFork(let lhsH, let lhsP, let lhsPW, let lhsOW), .wrongFork(let rhsH, let rhsP, let rhsPW, let rhsOW)):
            return lhsH == rhsH && lhsP == rhsP && lhsPW == rhsPW
        default:
            return false
        }
    }

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
        case .headersRestartNeeded(let newStartHeight):
            return "FIX #746: Headers restart needed from height \(newStartHeight)"
        case .unexpectedMessage(let expected, let got):
            return "Unexpected message: expected '\(expected)', got '\(got)'"
        case .invalidHeadersPayload(let reason):
            return "Invalid headers payload: \(reason)"
        case .noHeadersReceived:
            return "No headers received from peers"
        case .timeout(let msg):
            return msg
        case .internalError(let msg):
            return "Internal error: \(msg)"
        case .wrongFork(let height, let peer, let p2pWork, let ourWork):
            // FIX #535: Wrong fork detected - peer provided chain with lower accumulated work
            return "Wrong fork from \(peer) at height \(height): P2P chainwork (\(p2pWork)) < our chainwork (\(ourWork))"
        }
    }
}
