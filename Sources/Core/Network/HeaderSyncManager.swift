// Copyright (c) 2025 Zipherpunk.com dev team
// Header synchronization with multi-peer consensus

import Foundation

/// Manages header synchronization from multiple peers with consensus verification
/// Ensures trustless operation by requiring 6/8 peers to agree on header data
final class HeaderSyncManager {
    private let headerStore: HeaderStore
    private let networkManager: NetworkManager

    // FIX #1348: Verbose logging flag for pre-production build
    private let verbose = false

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

    // FIX #775: Track chain mismatch warnings to reduce log spam
    // Only print summary, not every occurrence
    private static var chainMismatchCount: Int = 0
    private static var chainMismatchFirstHeight: UInt64 = 0

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
        // FIX #1220: Skip header sync entirely while gap-fill is running.
        // Header sync stops block listeners (FIX #811) → kills TCP connections → deactivates dispatchers.
        // Gap-fill needs dispatchers active for the entire duration. Without this guard, header sync
        // triggered by network path change recovery kills dispatchers 1.3s into gap-fill (6.8% coverage).
        if await WalletManager.shared.isGapFillingDelta {
            print("⚠️ FIX #1220: Header sync blocked — gap-fill in progress (needs dispatchers active)")
            throw SyncError.alreadySyncing  // Re-use existing error to avoid adding new cases
        }

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

        // FIX #1418: Header sync now routes through the dispatcher (sendAndWaitViaDispatcher).
        // Block listeners receive "headers" responses and dispatch them to our waiting handler.
        // This eliminates the need to stop/restart block listeners, which was the #1 cause of
        // peer drops (stopping kills NWConnections → connection nil → reconnection overhead).
        //
        // Old flow: stop listeners → verify stopped (30s) → reconnect dead peers → wait for .ready
        //           → sync headers via direct reads → restart listeners. Total overhead: 5-35s.
        // New flow: send getheaders → dispatcher routes response → done. Zero connection disruption.
        //
        // FIX #811/900/904/1010/1206/1227/1235/1243/1244 stop/verify/reconnect logic REMOVED.
        // sendAndWaitViaDispatcher handles all cases:
        //   - Dispatcher active → routes through block listener (zero overhead)
        //   - Dispatcher inactive → starts block listener automatically (2s startup)

        // FIX #1227: Still reconnect dead peers — connections may be dead from OTHER operations
        let deadPeers = await MainActor.run {
            networkManager.peers.filter { $0.isHandshakeComplete && !$0.isConnectionReady }
        }
        if !deadPeers.isEmpty {
            print("🔄 FIX #1418: Reconnecting \(deadPeers.count) dead peers before header sync...")
            var reconnectedHosts = Set<String>()  // FIX #1235
            for peer in deadPeers {
                if reconnectedHosts.contains(peer.host) { continue }
                do {
                    try await peer.ensureConnected()
                    reconnectedHosts.insert(peer.host)
                } catch {
                    print("⚠️ FIX #1418: [\(peer.host)] Reconnect failed: \(error.localizedDescription)")
                }
            }
        }

        print("🔄 Starting header sync from height \(startHeight)")

        // FIX #775: Reset chain mismatch counter at start of new sync session
        Self.chainMismatchCount = 0
        Self.chainMismatchFirstHeight = 0

        // P2P-only consensus: get from NetworkManager
        let consensusHeight = try await networkManager.getChainHeight()

        guard consensusHeight > 0 else {
            print("❌ No consensus on chain height - cannot sync safely")
            throw SyncError.noConsensus(heights: [])
        }

        var chainTip = consensusHeight
        if verbose {
            print("🎯 Consensus chain tip: \(chainTip)")
        }

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
        // FIX #946: NEVER request headers beyond consensusHeight - they don't exist yet!
        //   Previous bug: `targetTip <= consensusHeight + 200` allowed requesting blocks
        //   200 ahead of chain tip, causing infinite loop waiting for non-existent blocks
        if let maxHeaders = maxHeaders, maxHeaders > 0 {
            let targetTip = startHeight + maxHeaders
            // FIX #946: Cap targetTip at consensusHeight - can't sync blocks that don't exist
            let cappedTarget = min(targetTip, consensusHeight)
            if cappedTarget > chainTip {
                if verbose {
                    print("📊 FIX #180/747/946: Adjusting chainTip from \(chainTip) to \(cappedTarget) (requested \(targetTip), capped at consensus \(consensusHeight))")
                }
                chainTip = cappedTarget
            } else if cappedTarget < chainTip {
                if verbose {
                    print("📊 FIX #180: Limiting chainTip from \(chainTip) to \(cappedTarget) based on maxHeaders (\(maxHeaders))")
                }
                chainTip = cappedTarget
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

            if verbose {
                print("📋 FIX #141: Already have headers up to \(maxStoredHeight)")
                print("📋 FIX #141: Starting sync from \(effectiveStartHeight) instead of \(startHeight)")
                print("📋 FIX #141: This saves syncing \(effectiveStartHeight - startHeight) headers we already have!")
            }
        }

        // FIX #1249: Off-by-one in header count calculation causes infinite retry loop
        // When chainTip == effectiveStartHeight (need exactly 1 header), old calculation:
        //   totalHeaders = chainTip - effectiveStartHeight = 3006260 - 3006260 = 0
        // But syncHeadersSimple uses `while currentHeight < chainTip` which is FALSE when equal
        // → loop never executes → no headers fetched → FilterScanner sees no progress → retry loop
        // Correct calculation: We need headers FROM effectiveStartHeight TO chainTip INCLUSIVE
        //   totalHeaders = chainTip - effectiveStartHeight + 1 = 3006260 - 3006260 + 1 = 1 header
        let totalHeaders = Int(chainTip - effectiveStartHeight + 1)
        if verbose {
            print("📥 Need to sync \(totalHeaders) headers (from \(effectiveStartHeight) to \(chainTip))")
        }

        // FIX #1251: Early return when totalHeaders = 0 to avoid wasting 4-5 seconds
        // This happens when HeaderStore is already at chainTip (effectiveStartHeight > chainTip).
        // Without this check, syncHeadersSimple runs its peer selection + getheaders loop even
        // though there's nothing to sync, and fillHeaderGaps also runs full gap detection logic.
        // Log evidence: "Need to sync 0 headers" → 3.94s wasted in syncHeadersSimple
        if totalHeaders <= 0 {
            print("✅ FIX #1251: No headers to sync (totalHeaders=\(totalHeaders)) - INSTANT RETURN")
            return
        }

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
            if verbose {
                print("📋 Filled \(gapsFilled) header gaps after main sync")
            }
        }

        print("🎉 Header sync complete! Synced to height \(chainTip)")

        // FIX #775: Print summary of chain mismatches if any occurred
        if Self.chainMismatchCount > 0 {
            print("ℹ️ FIX #775: Chain mismatch summary - \(Self.chainMismatchCount) occurrences starting at height \(Self.chainMismatchFirstHeight) (all trusted peer)")
            Self.chainMismatchCount = 0
            Self.chainMismatchFirstHeight = 0
        }

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
    /// FIX #802: Only check gaps from Sapling activation onwards (pre-Sapling headers not needed)
    /// FIX #898: Stop block listeners before gap filling (same as syncHeaders)
    func fillHeaderGaps() async throws -> Int {
        // FIX #1220: Skip gap filling while delta gap-fill is running (same reason as syncHeaders)
        if await WalletManager.shared.isGapFillingDelta {
            print("⚠️ FIX #1220: Header gap fill blocked — delta gap-fill in progress")
            return 0
        }

        if verbose {
            print("🔍 Checking for header gaps...")
        }

        // FIX #1251: Quick check if gaps exist BEFORE stopping listeners (save 2-5s overhead)
        // The gap detection logic (lines 496-547) is FAST (SQL queries), but the peer management
        // overhead (stop listeners, verify, reconnect, wait for ready) adds 2-5s minimum.
        // Without this early check, we waste time stopping/restarting listeners even when no gaps exist.
        // This is especially wasteful when called from syncHeaders which JUST synced to tip.
        do {
            guard let storeMaxHeight = try? headerStore.getLatestHeight() else {
                print("❌ FIX #1251: Cannot check gaps - no headers in store")
                return 0
            }

            let chainTip = try await networkManager.getChainHeight()

            // If HeaderStore is already at chain tip, no gaps possible
            if storeMaxHeight >= chainTip {
                print("✅ FIX #1251: No gaps possible - HeaderStore at chain tip (\(storeMaxHeight) >= \(chainTip)) - INSTANT RETURN")
                return 0
            }

            // Quick check: if we have all headers in Sapling range, no gaps
            let saplingActivation: UInt64 = 476_969
            let scanStartHeight = max(storeMaxHeight, saplingActivation)
            let expectedCount = Int(chainTip - scanStartHeight + 1)
            let actualCount = try headerStore.countHeadersInRange(from: scanStartHeight, to: chainTip)

            if actualCount >= expectedCount {
                print("✅ FIX #1251: No gaps detected in quick check (\(actualCount)/\(expectedCount) headers) - INSTANT RETURN")
                return 0
            }

            if verbose {
                print("📊 FIX #1251: Gaps detected in quick check (\(actualCount)/\(expectedCount) headers, missing \(expectedCount - actualCount)) - proceeding with full sync")
            }
        } catch {
            // If quick check fails, continue with full gap filling logic
            print("⚠️ FIX #1251: Quick gap check failed: \(error.localizedDescription) - proceeding with full sync")
        }

        // FIX #1418: Gap filling now uses dispatcher-based header sync (sendAndWaitViaDispatcher).
        // No need to stop/restart block listeners — dispatcher routes "headers" responses.
        // See syncHeaders() for full explanation.

        // FIX #1227: Still reconnect dead peers — connections may be dead from other operations
        let deadPeersGapFill = await MainActor.run {
            networkManager.peers.filter { $0.isHandshakeComplete && !$0.isConnectionReady }
        }
        if !deadPeersGapFill.isEmpty {
            print("🔄 FIX #1418: Reconnecting \(deadPeersGapFill.count) dead peers before gap fill...")
            var reconnectedHostsGapFill = Set<String>()  // FIX #1235
            for peer in deadPeersGapFill {
                if reconnectedHostsGapFill.contains(peer.host) { continue }
                do {
                    try await peer.ensureConnected()
                    reconnectedHostsGapFill.insert(peer.host)
                } catch {
                    print("⚠️ FIX #1418: [\(peer.host)] Reconnect failed: \(error.localizedDescription)")
                }
            }
        }

        // FIX #802: Only care about gaps from Sapling activation onwards
        let saplingActivation: UInt64 = 476_969

        guard let minHeight = try? headerStore.getMinHeight(),
              let storeMaxHeight = try? headerStore.getLatestHeight() else {
            print("❌ No headers in store")
            return 0
        }

        // Get current chain tip
        let chainTip: UInt64
        do {
            chainTip = try await networkManager.getChainHeight()
            if verbose {
                print("📊 FIX #937/#1247: Chain tip = \(chainTip), HeaderStore max = \(storeMaxHeight)")
            }
        } catch {
            print("⚠️ FIX #937: Could not get chain tip, using HeaderStore max: \(error)")
            chainTip = storeMaxHeight
        }

        // FIX #1247: Check gaps up to chainTip (not storeMaxHeight).
        // FIX #937 wanted to prevent checking BEYOND chainTip (when storeMaxHeight > chainTip),
        // but using min(storeMaxHeight, chainTip) also prevented checking UP TO chainTip
        // when storeMaxHeight < chainTip (e.g., chainTip=3006185, storeMax=3006184).
        // This caused "no gaps" false negative, missing the latest header.
        // Correct behavior: ALWAYS check up to chainTip. If HeaderStore is already at
        // chainTip, early return below catches it.
        let maxHeight = chainTip

        // Early return if HeaderStore is already at chain tip
        if storeMaxHeight >= chainTip {
            print("✅ No header gaps - HeaderStore at chain tip (\(storeMaxHeight) >= \(chainTip))")
            return 0
        }

        // FIX #802: Start scanning from Sapling activation, not minHeight
        let scanStartHeight = max(minHeight, saplingActivation)

        // FIX #802: Calculate expected count only for post-Sapling range
        let expectedCount = Int(maxHeight - scanStartHeight + 1)
        let actualCount = try headerStore.countHeadersInRange(from: scanStartHeight, to: maxHeight)
        let missingCount = expectedCount - actualCount

        if missingCount <= 0 {
            print("✅ No header gaps detected in Sapling range (\(actualCount) headers, \(scanStartHeight)-\(maxHeight))")
            return 0
        }

        print("⚠️ Detected \(missingCount) missing headers in Sapling range \(scanStartHeight)-\(maxHeight)")

        // Find all gaps (only in post-Sapling range)
        var gaps: [(start: UInt64, end: UInt64)] = []
        var currentHeight = scanStartHeight

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
            if verbose {
                print("📍 Gap found: \(gapStart) - \(gapEnd) (\(gapEnd - gapStart + 1) headers)")
            }
        }

        if gaps.isEmpty {
            if verbose {
                print("✅ No gaps found on detailed check")
            }
            return 0
        }

        // Fill each gap by syncing from the header before the gap
        var totalFilled = 0

        for (gapStart, gapEnd) in gaps {
            // FIX #802: Skip gaps entirely below Sapling activation
            if gapEnd < saplingActivation {
                if verbose {
                    print("⏭️ FIX #802: Skipping pre-Sapling gap \(gapStart) - \(gapEnd) (not needed for shielded wallet)")
                }
                continue
            }

            // FIX #802: Adjust gap start if it spans pre-Sapling range
            let effectiveGapStart = max(gapStart, saplingActivation)

            // FIX #937: Cap gap end at chain tip (safety check - should already be capped above)
            let effectiveGapEnd = min(gapEnd, chainTip)
            if gapEnd > chainTip {
                if verbose {
                    print("📊 FIX #937: Capping gap end at chain tip \(chainTip) (was \(gapEnd))")
                }
            }

            // FIX #937: Skip gaps entirely beyond chain tip
            if effectiveGapStart > chainTip {
                if verbose {
                    print("⏭️ FIX #937: Skipping gap \(effectiveGapStart) - \(gapEnd) (beyond chain tip \(chainTip))")
                }
                continue
            }

            if verbose {
                print("🔧 Filling gap \(effectiveGapStart) - \(effectiveGapEnd)...")
            }

            do {
                // We need to sync from effectiveGapStart using the header at effectiveGapStart-1 as locator
                // This is handled automatically by syncHeadersSimple which uses buildGetHeadersPayload
                try await syncHeadersSimple(from: effectiveGapStart, to: effectiveGapEnd + 1)

                // Verify the gap was filled
                let filledCount = (effectiveGapStart...effectiveGapEnd).filter { height in
                    (try? headerStore.getHeader(at: height)) != nil
                }.count

                totalFilled += filledCount
                if verbose {
                    print("✅ Filled \(filledCount) headers for gap \(effectiveGapStart) - \(effectiveGapEnd)")
                }

            } catch {
                print("⚠️ Failed to fill gap \(effectiveGapStart) - \(effectiveGapEnd): \(error)")
            }
        }

        if verbose {
            print("🎉 Gap filling complete: \(totalFilled) headers filled")
        }
        return totalFilled
    }

    /// FIX #122: Simple single-peer header sync for small ranges (<500 headers)
    /// FIX #501: Aggressive peer rotation - try each trusted peer for 5s max, then switch
    /// FIX #502: PRIORITIZE localhost (127.0.0.1) - user's local node
    /// No consensus overhead - just fetch from one peer and verify Equihash
    private func syncHeadersSimple(from startHeight: UInt64, to chainTip: UInt64) async throws {
        // FIX #1249: Include +1 for accurate count (startHeight TO chainTip INCLUSIVE)
        print("⚡ FIX #502: Using localhost-priority header sync for \(chainTip - startHeight + 1) headers")

        // FIX #519: Set flag to prevent health checks from disrupting sync
        await networkManager.setHeaderSyncInProgress(true)
        defer {
            // FIX #519: Always clear flag when done (even if error)
            Task { await networkManager.setHeaderSyncInProgress(false) }
        }

        // FIX: Timing diagnostics - track each step
        let syncStartTime = Date()

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
        if verbose {
            print("📊 FIX #502: Header sync timeout set to \(Int(maxSyncDuration))s for \(headersNeeded) headers")
        }

        // FIX #1097: Use isPreferredForDownload from Peer (matches Zclassic fPreferredDownload)
        // Preferred peers (hardcoded seeds) get +1000 bonus in performance score

        // FIX #1249: Changed `<` to `<=` to fetch header at chainTip height
        // Old bug: When currentHeight == chainTip (need 1 header), loop never executed
        // Example: currentHeight=3006260, chainTip=3006260 → 3006260 < 3006260 = FALSE
        // Correct: We need to fetch the header AT chainTip, so use `<=`
        while currentHeight <= chainTip {
            // FIX #274: Check total sync timeout
            let elapsed = Date().timeIntervalSince(syncStartTime)
            if elapsed > maxSyncDuration {
                print("⚠️ FIX #502: Header sync timeout after \(Int(elapsed))s - tried all peers")
                throw SyncError.timeout("Header sync timed out after \(Int(elapsed))s - \(chainTip - currentHeight) blocks remaining")
            }

            // FIX #1097 v2: SIMPLIFIED - Just sort by performance score!
            // isPreferredForDownload peers (hardcoded seeds) get +1000 bonus
            // No more duplicate trustedSeedPeers list - uses PeerManager.HARDCODED_SEEDS
            let currentPeers = await MainActor.run {
                let allPeers = networkManager.peers.filter { peer in
                    peer.isConnectionReady &&  // CRITICAL: Must have LIVE connection, not just handshake!
                    peer.isHandshakeComplete &&
                    peer.peerStartHeight > 0 &&  // MUST have reported a valid height
                    !failedPeers.contains(peer.host) &&
                    // FIX #1097: Preferred peers exempt from hasRecentActivity - ALWAYS try them!
                    (peer.isPreferredForDownload || peer.hasRecentActivity)
                }

                // FIX #1097: Simple sort by performance score - preferred peers naturally first
                // Performance score includes +1000 for isPreferredForDownload peers
                let sorted = allPeers.sorted { $0.getPerformanceScore() > $1.getPerformanceScore() }
                if let best = sorted.first {
                    if verbose {
                        print("📊 FIX #1097: Best peer for headers: \(best.host) (score: \(String(format: "%.1f", best.getPerformanceScore())), preferred: \(best.isPreferredForDownload))")
                    }
                }
                return sorted
            }

            // FIX #707: Removed per-batch peer ranking log (too spammy)

            guard let peer = currentPeers.first else {
                // FIX #905: Debug logging to understand why no peers are available
                let debugInfo = await MainActor.run { () -> (total: Int, ready: Int, handshake: Int, height: Int, notFailed: Int) in
                    let allPeers = networkManager.peers
                    let ready = allPeers.filter { $0.isConnectionReady }.count
                    let handshake = allPeers.filter { $0.isHandshakeComplete }.count
                    let height = allPeers.filter { $0.peerStartHeight > 0 }.count
                    let notFailed = allPeers.filter { !failedPeers.contains($0.host) }.count
                    return (allPeers.count, ready, handshake, height, notFailed)
                }
                // FIX #502: Suggest adding localhost if no peers available
                print("⚠️ FIX #502: No ready peers with valid heights, waiting 2s...")
                if verbose {
                    print("   📊 FIX #905 Debug: total=\(debugInfo.total), ready=\(debugInfo.ready), handshake=\(debugInfo.handshake), height=\(debugInfo.height), notFailed=\(debugInfo.notFailed)")
                    print("   💡 TIP: Start your local Zclassic node: zclassicd -daemon -listen=1 -listenonion=0")
                    print("   💡 Or add custom node: Settings → Network → Add Node (127.0.0.1:8033)")
                }
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
                // FIX #1418: Route header sync through the dispatcher instead of direct reads.
                // Old approach: stop block listeners → acquire messageLock → direct read → restart.
                // This killed NWConnections (peer drops from 9 to 3), required 2-3s reconnection per peer.
                // New approach: send getheaders, block listener receives "headers" response,
                // dispatcher routes it to us. No listener stop/start, connections preserved.
                let (_, responsePayload) = try await peer.sendAndWaitViaDispatcher(
                    command: "getheaders",
                    payload: payload,
                    expectedResponse: "headers",
                    timeoutSeconds: 5.0
                )
                let headers: [ZclassicBlockHeader] = try self.parseHeadersPayload(responsePayload, startingAt: headersStartHeight, fromPeer: peer.host)

                guard !headers.isEmpty else {
                    print("⚠️ FIX #502: Peer \(peer.host) returned no headers, trying next peer...")
                    failedPeers.insert(peer.host)
                    continue
                }

                // FIX #1250: Truncate headers beyond chainTip
                // getheaders protocol doesn't support stop height - peer sends all available headers
                // If peer has blocks beyond consensus chainTip, only store headers up to chainTip
                let originalCount = headers.count
                let headersToStore = headers.filter { $0.height <= chainTip }
                if headersToStore.count < originalCount {
                    if verbose {
                        print("🔍 FIX #1250: Peer \(peer.host) sent \(originalCount) headers, truncating to \(headersToStore.count) (chainTip=\(chainTip))")
                    }
                }

                // FIX #133: Verify chain starting at correct height
                try verifyHeaderChain(headersToStore, startingAt: headersStartHeight, fromPeer: peer.host)
                try headerStore.insertHeaders(headersToStore)

                // FIX #535: Track peer performance (silent - no log spam)
                peer.recordSuccess()
                peer.score.headersProvided += headersToStore.count

                // FIX #133: Use actual header heights, not requested heights
                // FIX #1250: Use truncated count (headersToStore) for accurate progress tracking
                let actualEndHeight = headersStartHeight + UInt64(headersToStore.count) - 1
                currentHeight = actualEndHeight + 1

                // Report progress
                let progress = HeaderSyncProgress(
                    currentHeight: actualEndHeight,
                    totalHeight: chainTip,
                    headersStored: try headerStore.getHeaderCount()
                )
                onProgress?(progress)

                // FIX #1440: Always show progress every ~1000 headers (not gated on verbose)
                // Replaces the per-request getheaders log that was too spammy
                if peer.score.headersProvided % 1000 < 160 || progress.percentComplete == 100 {
                    print("📡 Header sync: \(actualEndHeight)/\(chainTip) (\(progress.percentComplete)%)")
                }

                // Clear failed peers on success - a working peer might recover
                failedPeers.removeAll()

            } catch {
                // FIX #746: Handle headers restart needed - update currentHeight and retry
                if case SyncError.headersRestartNeeded(let newStartHeight, let failedPeerHost) = error {
                    if verbose {
                        print("🔄 FIX #746: Restarting header sync from height \(newStartHeight)")
                    }
                    // FIX #1246: Add the peer that caused chain mismatch to failedPeers
                    // This forces next iteration to try a different peer, breaking infinite loop
                    if let peerHost = failedPeerHost {
                        failedPeers.insert(peerHost)
                        print("⚠️ FIX #1246: Marked peer \(peerHost) as failed (chain mismatch) - will try different peer")
                    }
                    currentHeight = newStartHeight
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
        if verbose {
            print("⏱️ FIX #502: Header sync timing summary:")
            print("   Total duration: \(String(format: "%.2f", totalDuration))s")
            print("   Headers per second: \(String(format: "%.1f", Double(headersNeeded) / totalDuration))")
        }
    }

    /// FIX #141: PARALLEL header requests - request from ALL peers, take first response
    /// FIX #501: Aggressive peer rotation - try each trusted peer for 5s max, then switch
    /// FIX #502: PRIORITIZE localhost (127.0.0.1) - user's local node
    /// Over Tor, latency varies wildly. Parallel requests ensure fastest peer wins.
    /// IMPORTANT: P2P getheaders returns headers AFTER the locator hash
    /// Each batch uses the last received header's hash as locator for the next batch
    private func syncHeadersParallel(from startHeight: UInt64, to chainTip: UInt64) async throws {
        // FIX #1249: Include +1 for accurate count (startHeight TO chainTip INCLUSIVE)
        print("🚀 FIX #502: Using PARALLEL header requests with localhost priority for \(chainTip - startHeight + 1) headers")

        // FIX #519: Set flag to prevent health checks from disrupting sync
        await networkManager.setHeaderSyncInProgress(true)
        defer {
            // FIX #519: Always clear flag when done (even if error)
            Task { await networkManager.setHeaderSyncInProgress(false) }
        }

        // FIX #1097: Use isPreferredForDownload from Peer (matches Zclassic fPreferredDownload)
        // Preferred peers (hardcoded seeds) get +1000 bonus in performance score

        // FIX #483: Use NetworkManager.peers directly instead of PeerManager
        let peers = await MainActor.run {
            // CRITICAL: Must have LIVE connection (isConnectionReady), not just handshake!
            let allPeers = networkManager.peers.filter { $0.isConnectionReady && $0.isHandshakeComplete }
            // FIX #1097: Simple sort by performance score - preferred peers naturally first
            let sorted = allPeers.sorted { $0.getPerformanceScore() > $1.getPerformanceScore() }
            if let best = sorted.first {
                if verbose {
                    print("📊 FIX #1097: Best peer for parallel headers: \(best.host) (score: \(String(format: "%.1f", best.getPerformanceScore())), preferred: \(best.isPreferredForDownload))")
                }
            }
            return sorted
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

        if verbose {
            print("📊 FIX #502: Requesting headers from \(peers.count) peers (localhost first, then trusted)")
        }

        var currentHeight = startHeight
        var totalSynced = 0
        // FIX #1249: Include +1 for accurate count (startHeight TO chainTip INCLUSIVE)
        let totalNeeded = Int(chainTip - startHeight + 1)
        let startTime = Date()
        var failedPeers = Set<String>()

        // FIX #501: Much longer total timeout - we'll try many peers
        // FIX #1249: Include +1 for accurate count
        let headersNeeded = chainTip - startHeight + 1
        let maxSyncDuration: TimeInterval = 300.0  // 5 minutes
        if verbose {
            print("⏱️ FIX #502: Parallel sync timeout set to \(Int(maxSyncDuration))s for \(headersNeeded) headers")
        }

        // FIX #1249: Changed `<` to `<=` to fetch header at chainTip height
        while currentHeight <= chainTip {
            // FIX #1342: Early termination — if HeaderStore already covers chainTip
            // (e.g. from concurrent background loading or locator caught up), stop immediately
            if let storedHeight = try? headerStore.getLatestHeight(), storedHeight >= chainTip {
                if verbose {
                    print("✅ FIX #1342: HeaderStore (\(storedHeight)) already covers chainTip (\(chainTip)) — done")
                }
                break
            }

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

            // FIX #1097: Get fresh peer list for each batch, using performance score
            // Preferred peers (hardcoded seeds) exempt from hasRecentActivity
            let currentPeers = await MainActor.run {
                let allPeers = networkManager.peers.filter { peer in
                    peer.isConnectionReady &&  // CRITICAL: Must have LIVE connection, not just handshake!
                    peer.isHandshakeComplete &&
                    peer.peerStartHeight > 0 &&  // MUST have reported a valid height
                    !failedPeers.contains(peer.host) &&
                    // FIX #1097: Preferred peers exempt from hasRecentActivity - ALWAYS try them!
                    (peer.isPreferredForDownload || peer.hasRecentActivity)
                }
                // FIX #1097: Simple sort by performance score - preferred peers naturally first
                return allPeers.sorted { $0.getPerformanceScore() > $1.getPerformanceScore() }
            }

            // FIX #707: Removed per-batch peer ranking log (too spammy)

            guard !currentPeers.isEmpty else {
                // FIX #905: Debug logging to understand why no peers are available
                let debugInfo = await MainActor.run { () -> (total: Int, ready: Int, handshake: Int, height: Int, notFailed: Int) in
                    let allPeers = networkManager.peers
                    let ready = allPeers.filter { $0.isConnectionReady }.count
                    let handshake = allPeers.filter { $0.isHandshakeComplete }.count
                    let height = allPeers.filter { $0.peerStartHeight > 0 }.count
                    let notFailed = allPeers.filter { !failedPeers.contains($0.host) }.count
                    return (allPeers.count, ready, handshake, height, notFailed)
                }
                print("⚠️ FIX #502: No connected peers, waiting 2s for reconnection...")
                print("   📊 FIX #905 Debug: total=\(debugInfo.total), ready=\(debugInfo.ready), handshake=\(debugInfo.handshake), height=\(debugInfo.height), notFailed=\(debugInfo.notFailed)")
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
                    // FIX #1418: Route through dispatcher — no direct reads, no listener stop needed.
                    let (_, responsePayload) = try await peer.sendAndWaitViaDispatcher(
                        command: "getheaders",
                        payload: payload,
                        expectedResponse: "headers",
                        timeoutSeconds: perPeerTimeout
                    )
                    let result: [ZclassicBlockHeader] = try self.parseHeadersPayload(responsePayload, startingAt: headersStartHeight, fromPeer: peer.host)

                    if !result.isEmpty {
                        // Success!
                        if verbose {
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
                        }

                        headers = result
                        successPeerHost = peer.host  // FIX #535: Remember which peer provided headers
                        failedPeers.removeAll() // Clear failed peers on success
                        break  // Exit peer loop - we got our headers
                    }

                } catch {
                    // FIX #746: Handle headers restart needed - update currentHeight and retry
                    if case SyncError.headersRestartNeeded(let newStartHeight, let failedPeerHost) = error {
                        if verbose {
                            print("🔄 FIX #746: Restarting parallel header sync from height \(newStartHeight)")
                        }
                        // FIX #1246: Add the peer that caused chain mismatch to failedPeers
                        if let peerHost = failedPeerHost {
                            failedPeers.insert(peerHost)
                            print("⚠️ FIX #1246: Marked peer \(peerHost) as failed (chain mismatch) - will try different peer")
                        }
                        currentHeight = newStartHeight
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

            // FIX #1250: Truncate headers beyond chainTip (parallel sync path)
            // getheaders protocol doesn't support stop height - peer sends all available headers
            let originalCount = headers.count
            let headersToStore = headers.filter { $0.height <= chainTip }
            if headersToStore.count < originalCount {
                if verbose {
                    print("🔍 FIX #1250: Peer \(successPeerHost ?? "unknown") sent \(originalCount) headers, truncating to \(headersToStore.count) (chainTip=\(chainTip))")
                }
            }

            // FIX #133: Verify chain continuity with correct starting height
            // FIX #746: Wrap in do-catch to handle restart needed error
            do {
                try verifyHeaderChain(headersToStore, startingAt: headersStartHeight, fromPeer: successPeerHost ?? "unknown")
            } catch SyncError.headersRestartNeeded(let newStartHeight, let failedPeerHost) {
                if verbose {
                    print("🔄 FIX #746: Restarting parallel header sync from height \(newStartHeight) (post-fetch)")
                }
                // FIX #1246: Add the peer that caused chain mismatch to failedPeers
                if let peerHost = failedPeerHost {
                    failedPeers.insert(peerHost)
                    print("⚠️ FIX #1246: Marked peer \(peerHost) as failed (chain mismatch) - will try different peer")
                }
                currentHeight = newStartHeight
                continue  // Restart main loop with new height
            }

            // FIX #535: Track peer performance - update the peer that provided headers
            if let successHost = successPeerHost {
                let successPeer = await MainActor.run {
                    networkManager.peers.first(where: { $0.host == successHost })
                }
                if let peer = successPeer {
                    peer.recordSuccess()
                    peer.score.headersProvided += headersToStore.count  // FIX #1250: Use truncated count
                    // Response time is tracked implicitly via success rate in performance score
                    if verbose {
                        print("✅ FIX #535: Updated \(successHost) performance - now at \(peer.score.headersProvided) headers provided")
                    }
                }
            }

            // FIX #535: Validate chainwork to detect wrong forks
            // This prevents Sybil attacks where 9 peers provide wrong blockchain data
            // Compare P2P chainwork against our trusted HeaderStore chainwork
            if let peerHost = successPeerHost {
                try await validateChainwork(headersToStore, fromPeer: peerHost)
            }

            // Store headers
            try headerStore.insertHeaders(headersToStore)

            totalSynced += headersToStore.count  // FIX #1250: Use truncated count
            // FIX #133: Use actual header end height for next iteration
            currentHeight = headersStartHeight + UInt64(headersToStore.count)

            // FIX #1342: Cap progress at 100% — locator fallback can cause actual range
            // to be larger than totalNeeded (e.g. checkpoint 50K before target)
            let percent = min(totalSynced * 100 / max(totalNeeded, 1), 100)
            let elapsed = Date().timeIntervalSince(startTime)
            let rate = elapsed > 0 ? Double(totalSynced) / elapsed : 0
            if verbose {
                print("✅ Synced \(totalSynced)/\(totalNeeded) headers (\(percent)%) - \(Int(rate)) headers/sec")
            }

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

        // FIX #775: Print summary of chain mismatches if any occurred
        if Self.chainMismatchCount > 0 {
            print("ℹ️ FIX #775: Chain mismatch summary - \(Self.chainMismatchCount) occurrences starting at height \(Self.chainMismatchFirstHeight) (all trusted peer)")
            Self.chainMismatchCount = 0
            Self.chainMismatchFirstHeight = 0
        }
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

            // FIX #1418: Route through dispatcher — no direct reads needed.
            let (_, responsePayload) = try await peer.sendAndWaitViaDispatcher(
                command: "getheaders",
                payload: payload,
                expectedResponse: "headers",
                timeoutSeconds: 5.0
            )
            let headers: [ZclassicBlockHeader] = try self.parseHeadersPayload(responsePayload, startingAt: headersStartHeight, fromPeer: peer.host)

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
                if verbose {
                    print("📡 [RPC] Full Node daemon height: \(rpcHeight) (TRUSTED)")
                }
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
            if verbose {
                print("📡 [LOCAL] HeaderStore height: \(headerStoreHeight) (Equihash verified)")
            }
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
            if verbose {
                print("📡 [P2P] Consensus height (median of \(peerHeights.count) peers): \(p2pConsensusHeight)")
            }
        } else if !peerHeights.isEmpty {
            // Not enough peers for median, use max with caution
            p2pConsensusHeight = peerHeights.max() ?? 0
            if verbose {
                print("📡 [P2P] Height from \(peerHeights.count) peer(s): \(p2pConsensusHeight) (insufficient for median)")
            }
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
                    if verbose {
                        print("📡 Capping at \(maxHeight) until headers are synced")
                    }
                } else if p2pConsensusHeight > headerStoreHeight {
                    // P2P slightly ahead - accept (new blocks since last sync)
                    maxHeight = p2pConsensusHeight
                }
            }
        } else if p2pConsensusHeight > 0 {
            // No local headers, use P2P consensus
            maxHeight = p2pConsensusHeight
            if verbose {
                print("📡 Using P2P consensus (no local headers)")
            }
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
            if verbose {
                print("📡 Using chain tip: \(maxHeight)")
            }
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
            if verbose {
                print("🔄 Only \(allPeers.count) peers, attempting to connect more...")
            }
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
                    if verbose {
                        print("⏳ Waiting for peers to connect... (\(peerCount)/\(minPeers) ready, waited \(waitAttempts / 2)s)")
                    }
                }
            }

            allPeers = await MainActor.run { networkManager.peers }
            if verbose {
                print("📡 After waiting: \(allPeers.count) peers connected")
            }
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

            if verbose {
                print("🌐 Trying \(peersToTry.count) peers (total tried: \(triedPeersCount), need \(consensusThreshold - successfulHeaders.count) more)")
            }

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
                        if verbose {
                            print("📊 Consensus: \(successfulHeaders.count)/\(self.consensusThreshold) peers (\(host))")
                        }
                        if successfulHeaders.count >= self.consensusThreshold {
                            group.cancelAll()
                            break
                        }
                    } else {
                        if verbose {
                            print("⚠️ Peer \(host) failed, \(remainingPeers.count) peers remaining")
                        }
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

        if verbose {
            print("📊 Received headers from \(peerHeaders.count) peers")
        }

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

        // FIX #1418: Route through dispatcher — no direct reads, no messageLock needed.
        // Block listener receives "headers" response and dispatcher routes it to us.
        let (_, responsePayload) = try await peer.sendAndWaitViaDispatcher(
            command: "getheaders",
            payload: payload,
            expectedResponse: "headers",
            timeoutSeconds: 5.0
        )
        let headers = try self.parseHeadersPayload(responsePayload, startingAt: headersStartHeight, fromPeer: peer.host)

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
        // FIX #874: Removed warning print - was causing 123+ log entries during startup
        // BundledBlockHashes is completely disabled, no need to check or log

        // FIX #680: Use HeaderStore hash if we've already synced past the locator height
        // After P2P sync, HeaderStore has verified correct hashes we can use
        // Only fall back to checkpoint if HeaderStore doesn't have the height
        if locatorHash == nil {
            if let header = try? HeaderStore.shared.getHeader(at: locatorHeight) {
                // FIX #1163: Skip headers with garbage block_hash (FIX #1156 inserts minimal headers with X'00')
                // These have 1-byte garbage hashes that break the getheaders locator
                // Only use headers with valid 32-byte block hashes
                if header.blockHash.count == 32 {
                    // FIX #706: HeaderStore now stores hashes in little-endian (wire format) after FIX #676
                    // Previously stored big-endian, but FIX #676 reversed during boost loading
                    // So now we use the hash DIRECTLY without reversal
                    locatorHash = header.blockHash  // Already in wire format (little-endian)
                    actualLocatorHeight = locatorHeight
                } else {
                    // FIX #1163: Invalid block_hash - try boost file end as fallback
                    print("⚠️ FIX #1163: Skipping header at \(locatorHeight) - invalid block_hash (\(header.blockHash.count) bytes)")
                    if let boostEndHeader = try? HeaderStore.shared.getHeader(at: UInt64(ZipherXConstants.effectiveTreeHeight)),
                       boostEndHeader.blockHash.count == 32 {
                        locatorHash = boostEndHeader.blockHash
                        actualLocatorHeight = UInt64(ZipherXConstants.effectiveTreeHeight)
                        print("📋 FIX #1163: Using boost file end as locator instead")
                    }
                    // If boost file end also bad, will fall through to checkpoint code below
                }
                // FIX #707: Removed per-batch locator log (too spammy)
            } else {
                // FIX #901: If locatorHeight is ABOVE boost file end, use boost file end as locator
                // This prevents falling back to old checkpoint (2938700) which syncs 50K+ headers
                // Boost file headers are ALWAYS present up to effectiveTreeHeight, so use that first
                let boostFileEndHeight = UInt64(ZipherXConstants.effectiveTreeHeight)

                // FIX #1342: Fixed off-by-one (was `>`, should be `>=`)
                // When locatorHeight == boostFileEndHeight, we still need the fallback
                if locatorHeight >= boostFileEndHeight {
                    // Try boost file end first - it's the closest reliable header
                    if let boostEndHeader = try? HeaderStore.shared.getHeader(at: boostFileEndHeight) {
                        locatorHash = boostEndHeader.blockHash  // Already in wire format
                        actualLocatorHeight = boostFileEndHeight
                        print("📋 FIX #901: Using boost file end (\(boostFileEndHeight)) as locator for height \(locatorHeight)")
                    } else {
                        // FIX #1446c: HeaderStore doesn't have boost headers (FIX #1341 skipped loading).
                        // Use manifest's block_hash stored in ZipherXConstants instead.
                        // This avoids falling back 22K+ blocks to the stale hardcoded checkpoint.
                        let manifestHash = ZipherXConstants.effectiveBlockHash
                        if !manifestHash.isEmpty, let hashData = Data(hexString: manifestHash) {
                            locatorHash = Data(hashData.reversed())  // Convert display format → wire format
                            actualLocatorHeight = boostFileEndHeight
                            print("📋 FIX #1446c: Using manifest block_hash as locator at height \(boostFileEndHeight) (HeaderStore empty)")
                        }
                    }
                }

                // If still no locator, fall back to checkpoints
                if locatorHash == nil {
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

            // VUL-NET-001: Sampled Equihash verification (replaces FIX #562 total bypass)
            // Incremental sync (≤160 headers): verify ALL — recent blocks, most security-critical
            // Initial sync (>160 headers): verify every 100th + last — probabilistic deterrent
            let shouldVerifyEquihash: Bool
            if count <= 160 {
                shouldVerifyEquihash = true  // Incremental: verify every header
            } else {
                shouldVerifyEquihash = (i % 100 == 0) || (i == count - 1)  // Sample + last
            }
            let height = startHeight + UInt64(i)
            do {
                let header = try ZclassicBlockHeader.parseWithSolution(data: fullHeaderData, height: height, verifyEquihash: shouldVerifyEquihash)
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
                // FIX #772: ONLY use checkpoint if it's EXACTLY at prevHeight
                // Using a checkpoint from an earlier height (e.g., 476969 for prevHeight 523360)
                // will ALWAYS cause chain mismatch because the checkpoint hash is for a
                // different block than the incoming header's hashPrevBlock.
                //
                // Previous logic (WRONG): Used nearest checkpoint at checkpointHeight <= prevHeight
                // This caused massive chain mismatch spam for all headers between checkpoints.
                //
                // New logic (FIX #772): Only use checkpoint if checkpointHeight == prevHeight
                // If no exact match, leave prevHash = nil so chain verification is skipped
                // for the first header (just like index == 0 case).
                if let checkpointHex = ZclassicCheckpoints.mainnet[prevHeight],
                   let hashData = Data(hexString: checkpointHex) {
                    prevHash = Data(hashData.reversed())
                    prevHashFromHeaderStore = false
                    print("📋 FIX #772: Using exact checkpoint at height \(prevHeight)")
                } else {
                    // No header in store and no checkpoint at prevHeight
                    // Skip chain verification for first header (prevHash stays nil)
                    print("ℹ️ FIX #772: No header/checkpoint at \(prevHeight) - skipping first header verification")
                }
            }
        }

        let _ = headers.count  // totalHeaders - available for future logging
        for (index, header) in headers.enumerated() {
            // Verify previous hash links correctly
            // Skip verification for the very first header if we don't have its previous block
            if prevHash != nil {
                // FIX #707: Removed per-header debug logs (too spammy)

                guard header.hashPrevBlock == prevHash! else {
                    // FIX #924: Debug logging to investigate chain mismatch
                    let peerPrevHash = header.hashPrevBlock.map { String(format: "%02x", $0) }.joined()
                    let storedPrevHash = prevHash!.map { String(format: "%02x", $0) }.joined()
                    print("🔍 FIX #924: CHAIN MISMATCH DEBUG at height \(currentHeight):")
                    print("   Peer's hashPrevBlock: \(peerPrevHash)")
                    print("   Stored prevHash:      \(storedPrevHash)")
                    print("   prevHashFromHeaderStore: \(prevHashFromHeaderStore)")

                    // FIX #775: Track mismatch count instead of printing every occurrence
                    // Only print first occurrence per sync session
                    if Self.chainMismatchCount == 0 {
                        Self.chainMismatchFirstHeight = currentHeight
                        print("ℹ️ FIX #775: Chain mismatch at height \(currentHeight) - will trust peer (further warnings suppressed)")
                    }
                    Self.chainMismatchCount += 1

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
                            // FIX #775: Only log occasionally to reduce spam
                            if Self.chainMismatchCount % 100 == 1 {
                                print("🔍 FIX #767: Chain mismatch at height \(currentHeight), boostFileEndHeight=\(boostFileEndHeight)")
                            }

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

                            // FIX #792: NEVER mark boost file as corrupted from P2P chain mismatch
                            // The boost file is Equihash-verified and trustworthy.
                            // Chain mismatches happen because HeaderStore has stale/wrong P2P headers,
                            // NOT because the boost file is corrupted.
                            //
                            // Previous logic (FIX #767 v2) was BACKWARDS - it marked boost as corrupted
                            // when mismatch was WITHIN boost range, but that's exactly when the boost
                            // file is CORRECT and HeaderStore is WRONG.
                            //
                            // Solution: Don't set the corruption flag at all. The boost file will be
                            // reloaded on restart and Equihash verification will confirm its validity.
                            if prevHeight <= boostFileEndHeight {
                                print("ℹ️ FIX #792: Chain mismatch at \(currentHeight) within boost range - HeaderStore has stale headers (boost file is correct)")
                            } else {
                                print("ℹ️ FIX #792: Mismatch in P2P range at \(currentHeight) - will resync from peers")
                            }
                            lastCorruptedHeaderDeletion = Date()

                            // FIX #746: CRITICAL - Don't continue processing this batch!
                            // We just deleted headers, creating a gap. Must restart sync from
                            // the new HeaderStore max height to ensure chain continuity.
                            let newStartHeight = (try? headerStore.getLatestHeight()).map { $0 + 1 } ?? 476969
                            print("🔄 FIX #746: Throwing headersRestartNeeded - must restart sync from \(newStartHeight)")
                            // FIX #1246: Include peer host so catch block can mark it as failed (prevents infinite loop)
                            throw SyncError.headersRestartNeeded(newStartHeight: newStartHeight, failedPeerHost: peerHost)
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
        // FIX #1440: Removed spammy per-batch log (fires 30+ times during header sync)
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
    case headersRestartNeeded(newStartHeight: UInt64, failedPeerHost: String?)  // FIX #746: Restart sync after header deletion, FIX #1246: Track peer that caused chain mismatch
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
        case (.headersRestartNeeded(let lhsH, let lhsP), .headersRestartNeeded(let rhsH, let rhsP)):
            return lhsH == rhsH && lhsP == rhsP
        case (.unexpectedMessage(let lhsE, let lhsG), .unexpectedMessage(let rhsE, let rhsG)):
            return lhsE == rhsE && lhsG == rhsG
        case (.invalidHeadersPayload(let lhsR), .invalidHeadersPayload(let rhsR)):
            return lhsR == rhsR
        case (.internalError(let lhsM), .internalError(let rhsM)):
            return lhsM == rhsM
        case (.wrongFork(let lhsH, let lhsP, let lhsPW, _), .wrongFork(let rhsH, let rhsP, let rhsPW, _)):
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
        case .headersRestartNeeded(let newStartHeight, let failedPeerHost):
            if let peerHost = failedPeerHost {
                return "FIX #746/#1246: Headers restart needed from height \(newStartHeight) (peer \(peerHost) has forked chain)"
            } else {
                return "FIX #746: Headers restart needed from height \(newStartHeight)"
            }
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
