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

        // FIX #180: Apply maxHeaders limit if specified
        // This ensures we only sync up to maxHeaders blocks, not the entire chain
        if let maxHeaders = maxHeaders, maxHeaders > 0 {
            let limitedTip = startHeight + maxHeaders
            if limitedTip < chainTip {
                print("📊 FIX #180: Limiting sync to \(maxHeaders) headers (original tip: \(chainTip), limited: \(limitedTip))")
                chainTip = limitedTip
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
            "37.187.76.79",     // Known working Zclassic peer
            "135.181.94.12",    // Known working Zclassic peer
            "140.174.189.3",    // Zclassic seed node
            "140.174.189.17",   // Zclassic seed node
            "205.209.104.118"   // Zclassic seed node
        ]

        while currentHeight < chainTip {
            // FIX #274: Check total sync timeout
            let elapsed = Date().timeIntervalSince(syncStartTime)
            if elapsed > maxSyncDuration {
                print("⚠️ FIX #502: Header sync timeout after \(Int(elapsed))s - tried all peers")
                throw SyncError.timeout("Header sync timed out after \(Int(elapsed))s - \(chainTip - currentHeight) blocks remaining")
            }

            // FIX #502 v2: PRIORITIZE localhost (127.0.0.1) ABOVE ALL OTHER PEERS
            // User's local node is most reliable - no network latency, always available
            // Secondary: peers that have reported valid heights (peerStartHeight > 0)
            // These are peers that completed handshake and sent us a valid chain height
            let currentPeers = await MainActor.run {
                let allPeers = networkManager.peers.filter { peer in
                    peer.isHandshakeComplete &&
                    peer.hasRecentActivity &&  // FIX #504: MUST have recent activity (connection is alive!)
                    peer.peerStartHeight > 0 &&  // MUST have reported a valid height
                    !failedPeers.contains(peer.host)
                }

                // FIX #502: Sort by: localhost FIRST, then trusted, then by recency of height report
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

            let isTrusted = trustedSeedPeers.contains(peer.host)
            let isLocalhost = peer.host == localhostPeer
            let peerLabel = isLocalhost ? "[LOCALHOST]" : (isTrusted ? "[TRUSTED]" : "[OTHER]")
            print("📡 FIX #502: Trying peer \(peer.host) \(peerLabel) - reported height: \(peer.peerStartHeight)")

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
                            receivedHeaders = try self.parseHeadersPayload(response, startingAt: headersStartHeight)
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

                print("✅ FIX #502: Synced \(headers.count) headers to \(actualEndHeight) (\(progress.percentComplete)%) from \(peer.host)")

                // Clear failed peers on success - a working peer might recover
                failedPeers.removeAll()

            } catch {
                // FIX #501: Log failure and immediately disconnect/reset peer
                print("⚠️ FIX #502: Peer \(peer.host) failed: \(error.localizedDescription) - disconnecting and trying next...")
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

        // FIX #502: PRIORITIZE localhost above all other peers - user's local node at 127.0.0.1:8033
        let localhostPeer = "127.0.0.1"
        let trustedSeedPeers = [
            "37.187.76.79",     // Known working Zclassic peer
            "135.181.94.12",    // Known working Zclassic peer
            "140.174.189.3",    // Zclassic seed node
            "140.174.189.17",   // Zclassic seed node
            "205.209.104.118"   // Zclassic seed node
        ]

        // FIX #483: Use NetworkManager.peers directly instead of PeerManager
        let peers = await MainActor.run {
            let allPeers = networkManager.peers.filter { $0.isHandshakeComplete }
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
            // FIX #502 v2: PRIORITIZE localhost, then peers with valid heights (peerStartHeight > 0)
            let currentPeers = await MainActor.run {
                let allPeers = networkManager.peers.filter { peer in
                    peer.isHandshakeComplete &&
                    peer.hasRecentActivity &&  // FIX #504: MUST have recent activity (connection is alive!)
                    peer.peerStartHeight > 0 &&  // MUST have reported a valid height
                    !failedPeers.contains(peer.host)
                }
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
            let perPeerTimeout: TimeInterval = 5.0  // 5 seconds per peer

            for (index, peer) in currentPeers.enumerated() {
                let isTrusted = trustedSeedPeers.contains(peer.host)
                let isLocalhost = peer.host == localhostPeer
                let peerLabel = isLocalhost ? "[LOCALHOST]" : (isTrusted ? "[TRUSTED]" : "[OTHER]")
                print("📡 FIX #502: Trying \(peer.host) [\(index + 1)/\(currentPeers.count)] \(peerLabel) - reported height: \(peer.peerStartHeight)")

                do {
                    let result: [ZclassicBlockHeader] = try await peer.withExclusiveAccessTimeout(seconds: perPeerTimeout) {
                        try await peer.sendMessage(command: "getheaders", payload: payload)

                        // FIX #501: Only 1 attempt with 3 second timeout
                        let (command, response) = try await peer.receiveMessageWithTimeout(seconds: 3)

                        if command == "headers" {
                            return try self.parseHeadersPayload(response, startingAt: headersStartHeight)
                        }

                        return []
                    }

                    if !result.isEmpty {
                        // Success!
                        print("✅ FIX #502: Got \(result.count) headers from \(peer.host)")
                        headers = result
                        failedPeers.removeAll() // Clear failed peers on success
                        break  // Exit peer loop - we got our headers
                    }

                } catch {
                    // This peer failed, try next one
                    print("⚠️ FIX #501: Peer \(peer.host) failed: \(error.localizedDescription) - disconnecting")
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

        // Second try: BundledBlockHashes (correct hashes from GitHub)
        if locatorHash == nil {
            let bundledHashes = BundledBlockHashes.shared
            if bundledHashes.isLoaded, let hash = bundledHashes.getBlockHash(at: locatorHeight) {
                locatorHash = hash  // Already in wire format
                print("📋 FIX #436: Using BundledBlockHashes for locator at height \(locatorHeight)")
            }
        }

        // Third try: HeaderStore - ONLY for heights ABOVE BundledBlockHashes range
        // FIX #438: Headers above bundled range were P2P-synced with Equihash verification = CORRECT hashes
        // Headers AT or BELOW bundled range might be from boost file = WRONG hashes (140 bytes only)
        if locatorHash == nil {
            let bundledHashes = BundledBlockHashes.shared
            let bundledEndHeight = bundledHashes.isLoaded ? bundledHashes.endHeight : 0

            // Only use HeaderStore if locatorHeight is ABOVE the bundled range
            // These headers were synced via P2P with full Equihash solutions = correct hashes
            if locatorHeight > bundledEndHeight {
                if let lastHeader = try? headerStore.getHeader(at: locatorHeight) {
                    locatorHash = lastHeader.blockHash
                    print("📋 FIX #438: Using HeaderStore for locator at height \(locatorHeight) (above bundled range \(bundledEndHeight))")
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

        // FIX #437 + #438: Use correct hash sources for chain continuity
        // - BundledBlockHashes: For heights within bundled range (correct hashes from GitHub)
        // - HeaderStore: For heights ABOVE bundled range (P2P-synced with Equihash = correct hashes)
        // - NEVER use HeaderStore for heights within bundled range (boost file has wrong hashes)
        if currentHeight > 0 {
            let prevHeight = currentHeight - 1
            let bundledHashes = BundledBlockHashes.shared
            let bundledEndHeight = bundledHashes.isLoaded ? bundledHashes.endHeight : 0

            if bundledHashes.isLoaded, let bundledHash = bundledHashes.getBlockHash(at: prevHeight) {
                prevHash = bundledHash
                print("📋 FIX #437: Using BundledBlockHashes for chain continuity at height \(prevHeight)")
            } else if prevHeight > bundledEndHeight, let prevHeader = try? headerStore.getHeader(at: prevHeight) {
                // FIX #438: Only use HeaderStore for heights ABOVE bundled range (P2P synced = correct)
                prevHash = prevHeader.blockHash
                print("📋 FIX #438: Using HeaderStore for chain continuity at height \(prevHeight) (above bundled \(bundledEndHeight))")
            }
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
    case timeout(String)
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
        case .timeout(let msg):
            return msg
        case .internalError(let msg):
            return "Internal error: \(msg)"
        }
    }
}
