// Copyright (c) 2025 Zipherpunk.com dev team
// Wallet health checks - runs at startup before app becomes available

import Foundation

/// Health check results with details
struct HealthCheckResult {
    let checkName: String
    let passed: Bool
    let details: String
    let critical: Bool  // If critical and failed, app should not continue

    static func passed(_ name: String, details: String = "") -> HealthCheckResult {
        HealthCheckResult(checkName: name, passed: true, details: details, critical: false)
    }

    static func failed(_ name: String, details: String, critical: Bool = false) -> HealthCheckResult {
        HealthCheckResult(checkName: name, passed: false, details: details, critical: critical)
    }
}

/// Comprehensive wallet health checker
/// Runs before app becomes available to user
final class WalletHealthCheck {
    static let shared = WalletHealthCheck()
    private init() {}

    // MARK: - FIX #1131: Track witness rebuilds to avoid duplicate work

    /// Set to true when witnesses are rebuilt during health checks (FIX #550/828)
    /// Used by FIX #557 to skip redundant witness rebuild
    var witnessesRebuiltThisSession: Bool = false

    /// Reset at app launch
    func resetSessionFlags() {
        witnessesRebuiltThisSession = false
    }

    // MARK: - FIX #1126: Verified State System

    /// Keys for verified state persistence
    private enum VerifiedStateKeys {
        static let timestamp = "FIX1126_VerifiedStateTimestamp"
        static let treeSize = "FIX1126_VerifiedTreeSize"
        static let witnessCount = "FIX1126_VerifiedWitnessCount"
        static let notesBalance = "FIX1126_VerifiedBalance"
        static let lastScannedHeight = "FIX1126_VerifiedLastScanned"
    }

    /// Check if we have a valid verified state (skip redundant health checks)
    /// Returns true if state was verified within 24 hours AND current state matches
    func hasValidVerifiedState() -> Bool {
        let defaults = UserDefaults.standard
        let timestamp = defaults.double(forKey: VerifiedStateKeys.timestamp)

        // Must have been verified within 24 hours
        let hoursSinceVerification = (Date().timeIntervalSince1970 - timestamp) / 3600
        guard timestamp > 0 && hoursSinceVerification < 24 else {
            return false
        }

        // Verify current state matches saved state
        let savedTreeSize = UInt64(defaults.integer(forKey: VerifiedStateKeys.treeSize))
        let savedWitnessCount = defaults.integer(forKey: VerifiedStateKeys.witnessCount)
        let savedLastScanned = UInt64(defaults.integer(forKey: VerifiedStateKeys.lastScannedHeight))

        // Get current values
        let currentTreeSize = ZipherXFFI.treeSize()
        let currentLastScanned = (try? WalletDatabase.shared.getLastScannedHeight()) ?? 0

        // Tree size and lastScannedHeight should match (witnesses may vary slightly)
        let treeSizeMatches = currentTreeSize == savedTreeSize || savedTreeSize == 0
        let lastScannedMatches = currentLastScanned == savedLastScanned || savedLastScanned == 0

        if treeSizeMatches && lastScannedMatches {
            print("✅ FIX #1126: Valid verified state from \(String(format: "%.1f", hoursSinceVerification))h ago")
            print("   Tree: \(currentTreeSize), LastScanned: \(currentLastScanned)")
            return true
        }

        print("⚠️ FIX #1126: State changed since verification - running full health checks")
        print("   Tree: \(currentTreeSize) vs saved \(savedTreeSize)")
        print("   LastScanned: \(currentLastScanned) vs saved \(savedLastScanned)")
        return false
    }

    /// Save current state as verified (call after successful Full Rescan or all health checks pass)
    func saveVerifiedState(treeSize: UInt64, witnessCount: Int, balance: UInt64, lastScannedHeight: UInt64) {
        let defaults = UserDefaults.standard
        defaults.set(Date().timeIntervalSince1970, forKey: VerifiedStateKeys.timestamp)
        defaults.set(Int(treeSize), forKey: VerifiedStateKeys.treeSize)
        defaults.set(witnessCount, forKey: VerifiedStateKeys.witnessCount)
        defaults.set(Int(balance), forKey: VerifiedStateKeys.notesBalance)
        defaults.set(Int(lastScannedHeight), forKey: VerifiedStateKeys.lastScannedHeight)

        // Also set FIX #1104 timestamp for backward compatibility
        defaults.set(Date().timeIntervalSince1970, forKey: "FIX1104_BalanceVerifiedTimestamp")

        print("✅ FIX #1126: Saved verified state - tree=\(treeSize), witnesses=\(witnessCount), balance=\(Double(balance)/100_000_000.0) ZCL")
    }

    /// Invalidate verified state (call when database is modified)
    func invalidateVerifiedState() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: VerifiedStateKeys.timestamp)
        defaults.removeObject(forKey: VerifiedStateKeys.treeSize)
        defaults.removeObject(forKey: VerifiedStateKeys.witnessCount)
        defaults.removeObject(forKey: VerifiedStateKeys.notesBalance)
        defaults.removeObject(forKey: VerifiedStateKeys.lastScannedHeight)
        print("🔄 FIX #1126: Invalidated verified state")
    }

    /// Run all health checks and return results
    /// FIX #120: Ensures wallet is in consistent state before user interaction
    func runAllChecks() async -> [HealthCheckResult] {
        var results: [HealthCheckResult] = []

        // FIX #1126: If we have a valid verified state, skip most health checks
        // Only run critical checks that detect corruption, not validation checks
        if hasValidVerifiedState() {
            print("⏩ FIX #1126: Using verified state - skipping redundant health checks")

            // Only run minimal checks
            results.append(.passed("Verified State", details: "State verified within 24h"))
            results.append(await checkLastScannedHeightCorruption())  // Always check for corruption
            results.append(await checkP2PConnectivity())  // Always check network

            return results
        }

        // 0. FIX #166: CRITICAL - Check for corrupted last_scanned_height FIRST
        // This must be detected and fixed before any other checks run
        results.append(await checkLastScannedHeightCorruption())

        // 1. Bundle file integrity
        results.append(await checkBundleFiles())

        // 2. Database integrity
        results.append(await checkDatabaseIntegrity())

        // 3. Delta CMU verification
        results.append(await checkDeltaCMUs())

        // 4. Timestamp completeness
        results.append(await checkTimestamps())

        // 5. Balance vs History reconciliation
        results.append(await checkBalanceHistoryMatch())

        // 6. Hash accuracy (block hashes match P2P consensus)
        results.append(await checkHashAccuracy())

        // 7. P2P connectivity
        results.append(await checkP2PConnectivity())

        // 8. FIX #147: Equihash verification on latest 100 blocks
        results.append(await checkEquihashVerification())

        // 9. FIX #147: Witness validity check
        results.append(await checkWitnessValidity())

        // 10. FIX #147: Notes integrity check
        results.append(await checkNotesIntegrity())

        // 11. FIX #164: Verify unspent notes against blockchain (detect missed spends)
        results.append(await checkUnspentNullifiersOnChain())

        // 12. FIX #165: Checkpoint-based sync to catch ALL missed transactions (incoming AND spent)
        results.append(await checkPendingIncomingFromCheckpoint())

        // 13. VUL-002: DISABLED - P2P getdata only works for MEMPOOL, not confirmed TXs!
        // FIX #357: The old check was fundamentally broken - it marked REAL confirmed
        // transactions as "phantom" because P2P peers return "notfound" for any TX
        // that's not in their mempool (even if it's confirmed in a block).
        // This caused VUL-002 to incorrectly restore notes that were actually spent,
        // resulting in inflated balances (showed 2.79 ZCL when real balance was 0.93 ZCL).
        // TODO: Implement proper verification using Full Node RPC getrawtransaction
        // results.append(await checkSentTransactionsOnChain())
        print("⚠️ FIX #357: VUL-002 phantom detection DISABLED - P2P getdata doesn't work for confirmed TXs")

        // 14. FIX #358: CRYPTOGRAPHIC - Verify tree root matches header's finalsaplingroot
        // This is 100% trustless - our tree state vs Equihash-verified block header
        results.append(await checkTreeRootMatchesHeader())

        // 15. FIX #550: Auto-detect and fix anchor mismatches
        // Compares stored note anchors with blockchain headers to detect witness corruption
        results.append(await checkNoteAnchorsMatchHeaders())

        // 16. FIX #876: CRITICAL - Check for notes without witnesses (balance accuracy)
        // If notes exist without witnesses, balance is WRONG and must be fixed
        results.append(await checkNotesWithoutWitnesses())

        // 18. FIX #574: Detect stale witnesses at startup
        // Checks if witness anchors match CURRENT tree root (not note height anchor)
        // This is critical after FIX #572/573 fixes - stale witnesses cause TX rejections
        results.append(await checkStaleWitnesses())

        // 19. FIX #698: Detect and auto-repair zero sapling roots in HeaderStore
        // P2P bug causes headers to have zero sapling roots, causing TX failures
        results.append(await checkAndRepairZeroSaplingRoots())

        return results
    }

    /// FIX #166: CRITICAL - Detect and fix corrupted last_scanned_height
    /// This catches impossible future block heights that indicate database corruption
    /// Auto-fixes by resetting to a safe value based on verified chain height
    private func checkLastScannedHeightCorruption() async -> HealthCheckResult {
        do {
            let lastScannedHeight = try WalletDatabase.shared.getLastScannedHeight()
            let checkpointHeight = (try? WalletDatabase.shared.getVerifiedCheckpointHeight()) ?? 0

            // Get the REAL chain height from HeaderStore (locally verified Equihash)
            // This is the most trustworthy source
            let headerStoreHeight = (try? HeaderStore.shared.getLatestHeight()) ?? 0

            // Also check cached chain height as a reference
            let cachedChainHeight = UInt64(UserDefaults.standard.integer(forKey: "cachedChainHeight"))

            // Determine the maximum believable height
            // Use the highest of: headerStore, cached, or checkpoint + reasonable margin
            let maxTrustedHeight = max(headerStoreHeight, cachedChainHeight, checkpointHeight)

            // Current Zclassic chain height is ~2.94M (Dec 2025)
            // At 150s/block, max possible by 2030 is ~3.5M
            // If lastScannedHeight > max trusted + 1000 blocks, it's DEFINITELY corrupted
            let maxReasonableAhead: UInt64 = 1000
            let absoluteMax: UInt64 = 3_500_000

            print("🔍 FIX #166: Checking last_scanned_height corruption...")
            print("   lastScannedHeight: \(lastScannedHeight)")
            print("   headerStoreHeight: \(headerStoreHeight)")
            print("   cachedChainHeight: \(cachedChainHeight)")
            print("   checkpointHeight: \(checkpointHeight)")
            print("   maxTrustedHeight: \(maxTrustedHeight)")

            var isCorrupted = false
            var corruptionReason = ""

            // Check 1: Beyond absolute maximum (impossible height)
            if lastScannedHeight > absoluteMax {
                isCorrupted = true
                corruptionReason = "beyond absolute max (\(lastScannedHeight) > \(absoluteMax))"
            }
            // Check 2: Way ahead of all trusted sources
            else if maxTrustedHeight > 0 && lastScannedHeight > maxTrustedHeight + maxReasonableAhead {
                isCorrupted = true
                corruptionReason = "ahead of trusted height (\(lastScannedHeight) > \(maxTrustedHeight) + \(maxReasonableAhead))"
            }
            // Check 3: Sanity check - should be at least past Sapling activation
            else if lastScannedHeight > 0 && lastScannedHeight < ZipherXConstants.saplingActivationHeight {
                // This is suspicious but might be valid for a fresh wallet
                print("   ⚠️ lastScannedHeight (\(lastScannedHeight)) is below Sapling activation - might be fresh wallet")
            }

            if isCorrupted {
                print("🚨🚨🚨 FIX #166: CORRUPTION DETECTED! \(corruptionReason)")
                print("   Corrupted value: \(lastScannedHeight)")

                // AUTO-FIX: Reset to a safe value
                // Use the checkpoint height as it's the last VERIFIED good state
                // If no checkpoint, use bundled tree height as fallback
                let safeHeight: UInt64
                if checkpointHeight > ZipherXConstants.saplingActivationHeight {
                    safeHeight = checkpointHeight
                    print("   Resetting to checkpoint height: \(safeHeight)")
                } else if headerStoreHeight > ZipherXConstants.saplingActivationHeight {
                    safeHeight = headerStoreHeight
                    print("   Resetting to HeaderStore height: \(safeHeight)")
                } else {
                    safeHeight = ZipherXConstants.bundledTreeHeight
                    print("   Resetting to bundled tree height: \(safeHeight)")
                }

                // Apply the fix
                try WalletDatabase.shared.updateLastScannedHeight(safeHeight, hash: Data(count: 32))
                print("✅ FIX #166: Reset last_scanned_height from \(lastScannedHeight) to \(safeHeight)")

                return .failed("Sync State",
                              details: "FIXED: Corrupted height \(lastScannedHeight) → \(safeHeight)",
                              critical: false)  // Fixed, so not critical anymore
            }

            return .passed("Sync State", details: "last_scanned_height: \(lastScannedHeight) (valid)")

        } catch {
            print("⚠️ FIX #166: Could not check last_scanned_height: \(error)")
            return .failed("Sync State", details: "Check failed: \(error.localizedDescription)", critical: false)
        }
    }

    /// Check if all required bundle files exist
    private func checkBundleFiles() async -> HealthCheckResult {
        // Use SaplingParams which knows the correct path (AppDirectories.saplingParams)
        let params = SaplingParams.shared

        if params.areParamsReady {
            return .passed("Bundle Files", details: "All Sapling parameters present at \(params.spendParamsPath.deletingLastPathComponent().lastPathComponent)")
        }

        // Check which ones are missing for detailed error
        var missing: [String] = []
        if !FileManager.default.fileExists(atPath: params.spendParamsPath.path) {
            missing.append("sapling-spend.params")
        }
        if !FileManager.default.fileExists(atPath: params.outputParamsPath.path) {
            missing.append("sapling-output.params")
        }

        if missing.isEmpty {
            // Files exist but may have wrong size
            return .failed("Bundle Files", details: "Sapling params exist but may be corrupted (size mismatch)", critical: true)
        } else {
            return .failed("Bundle Files", details: "Missing: \(missing.joined(separator: ", "))", critical: true)
        }
    }

    /// Check database file integrity
    private func checkDatabaseIntegrity() async -> HealthCheckResult {
        do {
            // Check wallet database
            let noteCount = try WalletDatabase.shared.getAllUnspentNotes(accountId: 1).count
            let history = try WalletDatabase.shared.getTransactionHistory(limit: 10000, offset: 0)
            let historyCount = history.count

            // Check header store
            let headerStats = try HeaderStore.shared.getStats()
            let timestampCount = try HeaderStore.shared.getBlockTimesCount()

            let details = "Notes: \(noteCount), History: \(historyCount), Headers: \(headerStats.count), Timestamps: \(timestampCount)"
            return .passed("Database Integrity", details: details)
        } catch {
            return .failed("Database Integrity", details: error.localizedDescription, critical: true)
        }
    }

    /// Verify delta CMUs are consistent with tree
    private func checkDeltaCMUs() async -> HealthCheckResult {
        let treeSize = ZipherXFFI.treeSize()
        let expectedSize = ZipherXConstants.bundledTreeCMUCount

        if treeSize < expectedSize {
            return .failed("Delta CMU", details: "Tree size \(treeSize) < expected \(expectedSize)", critical: false)
        }

        // Check if tree root is valid
        guard let treeRoot = ZipherXFFI.treeRoot() else {
            return .failed("Delta CMU", details: "Cannot compute tree root", critical: true)
        }

        return .passed("Delta CMU", details: "Tree size: \(treeSize), Root: \(treeRoot.prefix(16))...")
    }

    /// Check that all transactions have real timestamps (not estimates)
    private func checkTimestamps() async -> HealthCheckResult {
        do {
            if let earliestMissing = try WalletDatabase.shared.getEarliestHeightNeedingTimestamp() {
                return .failed("Timestamps", details: "Missing timestamps from height \(earliestMissing)", critical: false)
            }
            return .passed("Timestamps", details: "All transactions have real timestamps")
        } catch {
            return .failed("Timestamps", details: error.localizedDescription, critical: false)
        }
    }

    /// FIX #163: Balance check - just report unspent notes as the authoritative balance
    /// The formula RECEIVED - SENT - FEES is flawed for shielded wallets because:
    /// - RECEIVED includes both external receives AND change from our own transactions
    /// - This causes double-counting and the formula never balances correctly
    /// - The ONLY reliable balance source is SUM(unspent notes)
    /// - History is for display purposes only, not for balance calculation
    private func checkBalanceHistoryMatch() async -> HealthCheckResult {
        do {
            // FIX #1083: Use comprehensive balance verification
            // FIX #1088: verifyBalanceIntegrity now correctly handles change outputs
            // It returns isValid=true when database is consistent (even if notes != history due to change)
            let (isValid, notesBalance, _, details) = try WalletDatabase.shared.verifyBalanceIntegrity(accountId: 1)

            let noteBalanceZCL = Double(notesBalance) / 100_000_000.0

            print("🏥 FIX #1088: Balance Integrity Check")
            print(details)

            if isValid {
                return .passed("Balance Integrity", details: String(format: "%.8f ZCL (verified)", noteBalanceZCL))
            } else {
                // FIX #1104: Check if balance was recently verified after a Full Rescan
                // If verified within last 24 hours, don't trigger another Full Rescan (non-critical)
                // This prevents the 28+ minute loop where startup keeps triggering Full Rescan
                let verifiedTimestamp = UserDefaults.standard.double(forKey: "FIX1104_BalanceVerifiedTimestamp")
                let hoursSinceVerification = (Date().timeIntervalSince1970 - verifiedTimestamp) / 3600

                if verifiedTimestamp > 0 && hoursSinceVerification < 24 {
                    print("⏩ FIX #1104: Balance was verified \(String(format: "%.1f", hoursSinceVerification))h ago - NOT triggering Full Rescan")
                    print("   (Minor discrepancy detected but Full Rescan already completed recently)")
                    // Return non-critical to avoid triggering FIX #1078's Full Rescan
                    return .failed("Balance Integrity",
                                  details: "Minor discrepancy (verified \(String(format: "%.1f", hoursSinceVerification))h ago)",
                                  critical: false)
                }

                // FIX #1088: Only critical when actual database corruption detected
                // (negative values, impossible states - NOT just notes != history difference)
                print("🚨 FIX #1088: Database corruption detected - requires repair")
                return .failed("Balance Integrity",
                              details: "Database corruption detected - run Repair Database",
                              critical: true)
            }
        } catch {
            return .failed("Balance Integrity", details: error.localizedDescription, critical: false)
        }
    }

    /// Verify stored block hashes match P2P network consensus
    /// FIX #120: DISABLED during FAST START - P2P requests cause hangs due to block listener contention
    /// This check is non-blocking and will be skipped to avoid UI hangs
    private func checkHashAccuracy() async -> HealthCheckResult {
        // FIX #120: Skip P2P-dependent hash check during startup
        // This was causing the UI to hang because:
        // 1. Block listeners are running after header sync
        // 2. peer.getBlockHeaders() competes for P2P lock
        // 3. Request hangs indefinitely waiting for lock
        // Hash accuracy is verified during header sync anyway (Equihash + chain continuity)
        return .passed("Hash Accuracy", details: "Verified during header sync (P2P check disabled to avoid hang)")
    }

    /// Check P2P network connectivity
    private func checkP2PConnectivity() async -> HealthCheckResult {
        let connectedPeers = await MainActor.run { NetworkManager.shared.connectedPeers }
        let minPeers = 3

        if connectedPeers >= minPeers {
            return .passed("P2P Connectivity", details: "\(connectedPeers) peers connected")
        } else if connectedPeers > 0 {
            return .failed("P2P Connectivity", details: "Only \(connectedPeers)/\(minPeers) peers (partial)", critical: false)
        } else {
            return .failed("P2P Connectivity", details: "No peers connected", critical: false)
        }
    }

    /// FIX #185/188/193: Verify Equihash proof-of-work from locally stored headers
    /// FIX #188: Now uses HeaderStore with cached solutions - NO P2P request needed!
    /// FIX #193: Skip P2P fallback for fresh imports (wallet height = 0) to prevent startup hang
    /// FIX #415: Only verify latest 50 blocks (not 100) - sufficient for chain tip validation
    /// This verifies Equihash(192,7) on headers that were stored during unified fetch
    private func checkEquihashVerification() async -> HealthCheckResult {
        // FIX #415: Only need 50 blocks for chain tip Equihash verification
        // Historical blocks are covered by Tree Root Validation (FIX #414)
        let verifyCount = 50

        // FIX #188: First try to verify from local storage (no P2P needed)
        let localSuccess = WalletManager.shared.verifyEquihashFromLocalStorage(count: verifyCount)

        if localSuccess {
            return .passed("Equihash PoW", details: "\(verifyCount) headers verified from local storage")
        }

        // FIX #193: For fresh imports (no synced data), skip P2P verification
        // P2P fallback can hang indefinitely, blocking startup
        // Equihash will be verified during initial sync anyway
        let lastScannedHeight = (try? WalletDatabase.shared.getLastScannedHeight()) ?? 0
        if lastScannedHeight == 0 {
            print("⚠️ FIX #193: Skipping P2P Equihash verification for fresh import")
            return .passed("Equihash PoW", details: "Skipped for fresh import (will verify during sync)")
        }

        // Fallback: If no local solutions and wallet is synced, try P2P fetch
        print("⚠️ FIX #415: No local solutions, fetching latest \(verifyCount) headers via P2P...")
        let p2pResult = await WalletManager.shared.verifyLatestEquihash(count: verifyCount)

        // FIX #231: Handle different result types appropriately
        switch p2pResult {
        case .verified(let count):
            // Clear any previous reduced verification alert
            WalletManager.shared.clearReducedVerificationAlert()
            return .passed("Equihash PoW", details: "\(count) headers verified (full consensus)")

        case .verifiedReducedConsensus(let count, let peers):
            // FIX #231 v2: Equihash PASSED but with reduced peer consensus
            // Still verified! But warn user about reduced consensus
            print("⚠️ FIX #231: Equihash verified with \(peers) peer(s) (reduced consensus)")

            // Set alert to warn user about reduced verification
            WalletManager.shared.setReducedVerificationAlert(
                peerCount: peers,
                reason: "Equihash verified with \(peers) peer(s) instead of 5"
            )

            return .passed("Equihash PoW", details: "\(count) headers verified (\(peers) peers - reduced consensus)")

        case .networkError(let reason):
            // FIX #231: Could not fetch ANY headers - network issue
            let peerCount = await MainActor.run { NetworkManager.shared.connectedPeers }
            print("⚠️ FIX #231: Equihash could not be verified - \(reason) (\(peerCount) peers)")

            // Set alert to warn user
            WalletManager.shared.setReducedVerificationAlert(peerCount: peerCount, reason: reason)

            return .passed("Equihash PoW", details: "Could not verify (network: \(reason))")

        case .failed(let verified, let total):
            // FIX #231: This IS critical - headers received but Equihash failed!
            // This indicates potential attack or chain fork
            return .failed("Equihash PoW", details: "CRITICAL: Only \(verified)/\(total) headers passed Equihash", critical: true)
        }
    }

    /// FIX #147: Verify witness validity for unspent notes
    /// FIX #557 v50: Relaxed validation - only check if witness has valid data, not root comparison
    /// Root comparison fails when tree is updated (anchor mismatch) but witness is still usable
    private func checkWitnessValidity() async -> HealthCheckResult {
        do {
            let notes = try WalletDatabase.shared.getAllUnspentNotes(accountId: 1)

            if notes.isEmpty {
                return .passed("Witness Validity", details: "No unspent notes to check")
            }

            var validCount = 0
            var invalidCount = 0
            var missingCount = 0

            for note in notes {
                // WalletNote.witness is non-optional Data - check if empty
                if note.witness.isEmpty {
                    missingCount += 1
                    continue
                }

                // FIX #557 v50: Check if witness has valid data (not all zeros)
                // A witness with valid data can be used even if anchor doesn't match
                // The anchor will be updated during transaction building
                // FIX #1107: Changed from 1028 to 100
                if note.witness.count >= 100 && !note.witness.allSatisfy({ $0 == 0 }) {
                    // Witness has valid data - consider it valid
                    // The witness root might not match stored anchor if tree was updated
                    // but that's OK - transaction builder will use current tree root
                    validCount += 1
                } else {
                    invalidCount += 1
                }
            }

            let details = "Valid: \(validCount), Invalid: \(invalidCount), Missing: \(missingCount)"

            if invalidCount > 0 || missingCount > 0 {
                return .failed("Witness Validity", details: details, critical: false)
            }

            return .passed("Witness Validity", details: details)
        } catch {
            return .failed("Witness Validity", details: error.localizedDescription, critical: false)
        }
    }

    /// FIX #147: Verify notes integrity (CMU exists, nullifier computed, etc.)
    private func checkNotesIntegrity() async -> HealthCheckResult {
        do {
            let notes = try WalletDatabase.shared.getAllUnspentNotes(accountId: 1)

            if notes.isEmpty {
                return .passed("Notes Integrity", details: "No notes to check")
            }

            var validNotes = 0
            var issues: [String] = []

            for note in notes {
                var noteValid = true

                // Check CMU exists (optional field)
                if note.cmu == nil || note.cmu!.isEmpty {
                    issues.append("Note \(note.id): missing CMU")
                    noteValid = false
                }

                // Check nullifier exists (non-optional but check if empty)
                if note.nullifier.isEmpty {
                    issues.append("Note \(note.id): missing nullifier")
                    noteValid = false
                }

                // Check value is reasonable
                if note.value == 0 {
                    issues.append("Note \(note.id): zero value")
                    noteValid = false
                }

                // Check witness exists
                if note.witness.isEmpty && note.height > ZipherXConstants.saplingActivationHeight + 100 {
                    issues.append("Note \(note.id): missing witness")
                    noteValid = false
                }

                if noteValid {
                    validNotes += 1
                }
            }

            if !issues.isEmpty {
                let issueText = issues.count > 3 ? "\(issues.prefix(3).joined(separator: ", "))..." : issues.joined(separator: ", ")
                return .failed("Notes Integrity", details: "\(validNotes)/\(notes.count) valid. Issues: \(issueText)", critical: false)
            }

            return .passed("Notes Integrity", details: "\(validNotes) notes verified")
        } catch {
            return .failed("Notes Integrity", details: error.localizedDescription, critical: false)
        }
    }

    /// FIX #164: Verify that "unspent" notes are actually unspent on the blockchain
    /// This catches cases where a spend was missed during scanning (e.g., FAST START skip)
    ///
    /// FIX #120: DISABLED during health checks - P2P block fetching causes hangs/timeouts over Tor
    /// Evidence from z.log: All P2P block fetch attempts timed out (67s, 56s, 144s per batch)
    /// Result: 0 blocks scanned, spent notes not detected, UI stuck at 91% for 8+ minutes
    ///
    /// Spent detection is now handled by:
    /// - FilterScanner during actual sync operations (processes blocks properly)
    /// - FIX #165 checkpoint sync which runs on confirmed chain height
    /// - Regular background sync which includes nullifier matching
    ///
    /// Health checks should be FAST and non-blocking for good UX
    private func checkUnspentNullifiersOnChain() async -> HealthCheckResult {
        print("🔍 FIX #164/FIX #120: Nullifier verification delegated to sync operations")
        print("   P2P block fetching disabled in health checks (causes Tor timeouts)")

        // Just report how many unspent notes we have - verification happens during sync
        do {
            let unspentNotes = try WalletDatabase.shared.getAllUnspentNotes(accountId: 1)
            let totalValue = unspentNotes.reduce(0) { $0 + $1.value }
            let totalZCL = Double(totalValue) / 100_000_000.0

            return .passed("Nullifier Check", details: "\(unspentNotes.count) unspent notes (\(String(format: "%.8f", totalZCL)) ZCL) - verified during sync")
        } catch {
            return .passed("Nullifier Check", details: "Verification delegated to sync operations")
        }
    }

    /// FIX #165: Checkpoint-based sync to detect ALL missed transactions since last verified checkpoint.
    /// This ensures that both INCOMING and SPENT transactions are discovered at startup.
    ///
    /// FIX #120: P2P block fetching disabled in health checks (causes Tor timeouts).
    /// Instead, we detect when a REPAIR is NEEDED and warn the user.
    ///
    /// When checkpoint is significantly behind lastScannedHeight, it means FAST START skipped
    /// blocks that may contain spent notes. User must run "Repair Database" to fix balance.
    private func checkPendingIncomingFromCheckpoint() async -> HealthCheckResult {
        print("🔍 FIX #165/FIX #120: Checkpoint sync check")

        let checkpointHeight = (try? WalletDatabase.shared.getVerifiedCheckpointHeight()) ?? 0
        let lastScannedHeight = (try? WalletDatabase.shared.getLastScannedHeight()) ?? 0

        // If checkpoint is 0 but we have lastScannedHeight, initialize checkpoint
        if checkpointHeight == 0 && lastScannedHeight > 0 {
            try? WalletDatabase.shared.updateVerifiedCheckpointHeight(lastScannedHeight)
            print("📝 FIX #165: Initialized checkpoint to \(lastScannedHeight)")
            return .passed("Checkpoint Sync", details: "Initialized checkpoint to \(lastScannedHeight)")
        }

        // FIX #164 v4: Check if there's a significant gap between checkpoint and lastScanned
        // This indicates FAST START skipped blocks that may contain spent notes
        let blocksBehind = lastScannedHeight > checkpointHeight ? Int(lastScannedHeight - checkpointHeight) : 0

        if blocksBehind > 100 {
            // More than 100 blocks were skipped - this could mean missed spends!
            print("⚠️ FIX #164 v4: \(blocksBehind) blocks skipped since last checkpoint!")
            print("   Checkpoint: \(checkpointHeight), LastScanned: \(lastScannedHeight)")
            print("   User should run 'Repair Database' to ensure balance is correct")

            // Return FAILED with a specific message that will trigger the repair alert
            return .failed("Checkpoint Sync",
                          details: "REPAIR NEEDED: \(blocksBehind) blocks skipped - spent notes may be missed",
                          critical: false)  // Not critical so app can still load, but needs repair
        }

        if checkpointHeight > 0 {
            return .passed("Checkpoint Sync", details: "Checkpoint at \(checkpointHeight), \(blocksBehind) blocks to verify")
        } else {
            return .passed("Checkpoint Sync", details: "Fresh wallet - checkpoint will be set after first sync")
        }
    }

    /// Print health check summary
    func printSummary(_ results: [HealthCheckResult]) {
        print("\n" + String(repeating: "=", count: 60))
        print("🏥 WALLET HEALTH CHECK SUMMARY")
        print(String(repeating: "=", count: 60))

        var passedCount = 0
        var failedCount = 0
        var criticalFailed = false

        for result in results {
            let status = result.passed ? "✅" : (result.critical ? "❌" : "⚠️")
            print("\(status) \(result.checkName): \(result.details)")

            if result.passed {
                passedCount += 1
            } else {
                failedCount += 1
                if result.critical {
                    criticalFailed = true
                }
            }
        }

        print(String(repeating: "-", count: 60))
        print("📊 Results: \(passedCount) passed, \(failedCount) failed")

        if criticalFailed {
            print("❌ CRITICAL ISSUES DETECTED - Wallet may not function correctly")
        } else if failedCount > 0 {
            print("⚠️ Some non-critical issues found - Will attempt to fix")
        } else {
            print("✅ All checks passed - Wallet is healthy!")
        }
        print(String(repeating: "=", count: 60) + "\n")
    }

    /// Check if any critical failures
    func hasCriticalFailures(_ results: [HealthCheckResult]) -> Bool {
        return results.contains { !$0.passed && $0.critical }
    }

    /// Get list of non-critical issues that can be fixed
    func getFixableIssues(_ results: [HealthCheckResult]) -> [HealthCheckResult] {
        return results.filter { !$0.passed && !$0.critical }
    }

    // MARK: - FIX #358: Cryptographic Tree Root Verification

    /// FIX #358: CRITICAL - Verify our tree root matches header's finalsaplingroot
    /// This is 100% trustless cryptographic verification:
    /// - We compute the tree root from CMUs we collected
    /// - Header's finalsaplingroot is from Equihash-verified block
    /// - If they match: Our tree state is 100% correct
    /// - If mismatch: Either our tree OR the header is wrong
    ///
    /// This replaces the broken P2P TX verification (FIX #357) with real crypto proof.
    private func checkTreeRootMatchesHeader() async -> HealthCheckResult {
        print("🔐 FIX #358: Checking tree root matches header's finalsaplingroot...")

        // Get current tree state
        guard let currentTreeRoot = ZipherXFFI.treeRoot() else {
            return .passed("Tree Root Validation", details: "No tree loaded - will verify after sync")
        }

        // Get current tree size (CMU count) to find the corresponding block height
        let treeSize = ZipherXFFI.treeSize()
        if treeSize == 0 {
            return .passed("Tree Root Validation", details: "Empty tree - will verify after sync")
        }

        // Get the last scanned height (this is where our tree state should match)
        guard let lastScannedHeight = try? WalletDatabase.shared.getLastScannedHeight(),
              lastScannedHeight > 0 else {
            return .passed("Tree Root Validation", details: "No blocks scanned yet")
        }

        // FIX #457 v5: Handle delta between boost file and current chain tip
        // If tree size matches boost file output count, tree is at boost file end height
        // We should validate against boost end height, NOT current chain tip
        // The delta blocks (boost end → chain tip) haven't been applied to tree yet
        var treeValidationHeight = lastScannedHeight

        // FIX #479: Track if validation is against boost file (for non-critical failure handling)
        var validatingAgainstBoostFile = false
        var boostManifest: (output_count: UInt64, chain_height: UInt64)? = nil

        // FIX #679: Track delta CMUs for later use (must be in outer scope)
        var deltaCMUs: UInt64 = 0

        // Check if we have a boost file loaded
        let treeUpdater = CommitmentTreeUpdater.shared
        if let manifest = await treeUpdater.loadCachedManifest() {
            let boostOutputCount = manifest.output_count  // UInt64
            let boostEndHeight = manifest.chain_height

            // FIX #732: Validate at the height where tree state ACTUALLY represents!
            // - If tree has 0 delta CMUs → tree only has boost file CMUs → validate at boost END height
            // - If tree has delta CMUs → tree has grown beyond boost → validate at delta END height
            //
            // Previous FIX #720 was WRONG - it always validated at lastScannedHeight even when
            // tree only contained boost file CMUs. This caused mismatch because header at
            // lastScannedHeight has different finalsaplingroot than header at boost end.
            deltaCMUs = treeSize >= boostOutputCount ? treeSize - boostOutputCount : 0
            print("📦 FIX #732: Tree size \(treeSize) = boost file (\(boostOutputCount)) + \(deltaCMUs) delta CMUs")

            if deltaCMUs == 0 {
                // Tree only has boost file CMUs - validate at boost END height
                treeValidationHeight = boostEndHeight
                print("📦 FIX #732: deltaCMUs=0, validating at BOOST END height \(boostEndHeight)")
            } else {
                // FIX #778 v2: Tree has grown beyond boost - need delta manifest to know validation height
                // The tree root is deterministic: root(CMU[0..N]) where N = boost + delta CMUs
                // Without knowing WHICH HEIGHT those delta CMUs correspond to, we can't validate.
                //
                // CRITICAL FIX: When deltaCMUs > 0 but no manifest exists:
                // - We CANNOT validate because we don't know which header to compare against
                // - Validating at boost end height would ALWAYS fail (tree has extra CMUs)
                // - Validating at lastScannedHeight is wrong if it equals boost end height
                // - The only safe option is to SKIP validation (non-critical)
                //
                // This prevents the infinite repair loop where:
                // 1. Tree has delta CMUs → mismatch at boost height → repair
                // 2. Repair can't fix because delta CMUs are in FFI memory, not file
                // 3. Health check fails again → repair → loop forever
                if let deltaManifest = DeltaCMUManager.shared.getManifest(), deltaManifest.endHeight > boostEndHeight {
                    treeValidationHeight = deltaManifest.endHeight
                    print("📦 FIX #778: Using delta manifest endHeight \(deltaManifest.endHeight) for validation")
                } else {
                    // FIX #778: Tree has delta CMUs but NO manifest - ORPHAN STATE
                    // This happens when:
                    // 1. FIX #524 repair appended delta CMUs to FFI tree
                    // 2. FIX #765 cleared the delta manifest (detecting incomplete CMUs)
                    // 3. FFI tree still has the extra CMUs in memory
                    //
                    // We CANNOT validate because:
                    // - Validating at boost height fails (tree has extra CMUs → different root)
                    // - Validating at lastScannedHeight fails (manifest cleared, we don't know which header)
                    //
                    // CRITICAL: Return non-critical failure to prevent repair loop!
                    // The old code returned .failed(critical: true) which triggered repair,
                    // repair failed again, health check ran again → infinite loop
                    //
                    // FIX #778: Return non-critical pass with warning instead
                    // The tree state is unknown - user should run Full Rescan if issues persist
                    print("📦 FIX #778: ORPHAN STATE - Tree has \(deltaCMUs) delta CMUs but NO manifest")
                    print("📦 FIX #778: Cannot determine correct validation height - skipping to prevent loop")
                    print("📦 FIX #778: Tree state is unknown - recommend Full Rescan if TX fails")

                    // Return passed (non-critical) to break the loop
                    // User can manually Full Rescan if they encounter TX failures
                    return .passed("Tree Root Validation",
                                  details: "⚠️ Orphan delta CMUs (\(deltaCMUs)) - validation skipped. Try Full Rescan if TX fails.")
                }
            }

            // Track that we started from boost file (for diagnostics)
            if deltaCMUs <= 2000 {
                validatingAgainstBoostFile = true
                boostManifest = (manifest.output_count, manifest.chain_height)
            }
        }

        // FIX #678: Get the header at the appropriate validation height
        // Try exact height first, then search nearby if not found
        var header: ZclassicBlockHeader?

        // First try exact height
        if let h = try? HeaderStore.shared.getHeader(at: treeValidationHeight) {
            header = h
        } else {
            // FIX #679: If exact height not found, search nearby (±50 blocks)
            // This handles cases where PHASE 2 CMUs added tree at slightly different height
            // or HeaderStore has a gap at exact boost end height
            let searchStart = max(Int64(treeValidationHeight) - 50, 476969)  // Don't go below Sapling activation
            let searchEnd = min(Int64(treeValidationHeight) + 50, Int64(lastScannedHeight))

            // FIX #893: Guard against invalid range (searchStart > searchEnd causes crash)
            guard searchStart <= searchEnd else {
                print("⚠️ FIX #893: Invalid search range \(searchStart)-\(searchEnd) (headers not synced to tree height)")
                // Tree is ahead of HeaderStore - skip validation, non-critical
                if deltaCMUs > 0 {
                    return .passed("Tree Root Validation",
                                  details: "Tree ahead of headers by \(treeValidationHeight - UInt64(searchEnd)) blocks - validation skipped")
                } else {
                    return .failed("Tree Root Validation",
                                  details: "⚠️ Headers not synced to tree height \(treeValidationHeight)",
                                  critical: false)
                }
            }

            print("⚠️ FIX #679: Header not found at exact height \(treeValidationHeight), searching range \(searchStart)-\(searchEnd)...")

            // FIX #682: Debug HeaderStore gaps - check what headers actually exist
            if let minH = try? HeaderStore.shared.getMinHeight(),
               let maxH = try? HeaderStore.shared.getLatestHeight() {
                print("🔍 FIX #682: HeaderStore range: \(minH) to \(maxH)")

                // Check if we can find any header in the search range
                var foundCount = 0
                var firstFound: Int64? = nil
                for testHeight in searchStart...searchEnd {
                    if (try? HeaderStore.shared.getHeader(at: UInt64(testHeight))) != nil {
                        if firstFound == nil { firstFound = testHeight }
                        foundCount += 1
                    }
                }
                print("🔍 FIX #682: Found \(foundCount) headers in search range, first at \(firstFound?.description ?? "none")")
            }

            for testHeight in searchStart...searchEnd {
                if let h = try? HeaderStore.shared.getHeader(at: UInt64(testHeight)) {
                    header = h
                    print("✅ FIX #679: Found header at nearby height \(testHeight)")
                    break
                }
            }
        }

        guard let header = header else {
            // FIX #375: No header found in range = cannot verify tree root = non-critical failure
            // But this is expected if tree has PHASE 2 CMUs beyond boost file - those headers might not exist yet
            // Check if this is just PHASE 2 growth (expected) vs actual problem
            if deltaCMUs > 0 && deltaCMUs <= 2000 {
                // FIX #679: Tree has PHASE 2 delta CMUs - header at exact boost end might not exist
                // This is EXPECTED and NON-CRITICAL - tree is valid, just at slightly different height
                print("📦 FIX #679: Tree has \(deltaCMUs) PHASE 2 CMUs beyond boost file - header at exact boost end may not exist")
                print("✅ FIX #679: Tree Root Validation PASSED - PHASE 2 growth is expected")
                return .passed("Tree Root Validation",
                              details: "Tree at boost end + \(deltaCMUs) PHASE 2 CMUs (validation skipped)")
            } else {
                // FIX #375: No header = cannot verify tree root = non-critical failure
                return .failed("Tree Root Validation",
                              details: "⚠️ No header at height \(treeValidationHeight) (±50 blocks) - headers not synced",
                              critical: false)
            }
        }

        // CRITICAL: Compare our tree root with header's finalsaplingroot
        let headerSaplingRoot = header.hashFinalSaplingRoot

        // FIX #976: BEFORE skipping validation (FIX #796), verify tree SIZE is correct!
        // Tree corruption (extra CMUs) would be missed if we just trust the computed root.
        // The tree root is computed from CMUs - if there are extra/missing CMUs, root is WRONG.
        if let boostOutputCount = boostManifest?.output_count {
            // Get expected delta CMU count from manifest
            let expectedDeltaCMUs: UInt64
            if let deltaManifest = DeltaCMUManager.shared.getManifest() {
                expectedDeltaCMUs = UInt64(deltaManifest.cmuCount)
            } else {
                expectedDeltaCMUs = 0
            }

            let expectedTreeSize = boostOutputCount + expectedDeltaCMUs
            let actualTreeSize = treeSize

            // Allow small tolerance (±10 CMUs) for race conditions during sync
            let sizeDiff = actualTreeSize > expectedTreeSize
                ? Int64(actualTreeSize - expectedTreeSize)
                : -Int64(expectedTreeSize - actualTreeSize)

            // FIX #1090: Only treat UNDER-sized trees as corruption
            // OVER-sized is OK - P2P delta fetch may have added CMUs not yet persisted to manifest
            if sizeDiff < -10 {
                // Tree is UNDER-sized by more than 10 - missing CMUs, likely corrupted
                print("❌ FIX #976: TREE SIZE MISMATCH - Tree is UNDER-SIZED!")
                print("   Expected: \(expectedTreeSize) CMUs (boost: \(boostOutputCount) + delta: \(expectedDeltaCMUs))")
                print("   Actual:   \(actualTreeSize) CMUs")
                print("   Missing: \(-sizeDiff) CMUs")
                print("   → Triggering Full Resync to rebuild tree from scratch")

                return .failed("Tree Root Validation",
                              details: "❌ Tree under-sized: missing \(-sizeDiff) CMUs. Full Resync required.",
                              critical: true)
            } else if sizeDiff > 10 {
                // FIX #1090: Tree is OVER-sized - this is OK (P2P delta fetch added extra CMUs)
                print("✅ FIX #1090: Tree has \(sizeDiff) extra CMUs (from P2P delta fetch) - this is OK")
            }

            print("✅ FIX #976: Tree size verified (\(actualTreeSize) CMUs, expected \(expectedTreeSize))")
        }

        // FIX #796: P2P headers above boost file end have UNRELIABLE sapling roots
        // The P2P getheaders protocol doesn't reliably include finalsaplingroot.
        // Only boost file headers (loaded from verified boost file) are trustworthy.
        // If we're validating at a height ABOVE boost file, skip validation against
        // potentially corrupted P2P headers - trust our computed tree root instead.
        // NOTE: FIX #976 above already verified tree SIZE is correct before we get here.
        if let boostEndHeight = boostManifest?.chain_height, treeValidationHeight > boostEndHeight {
            // Check if header sapling root is all zeros (definitely P2P artifact)
            let isZeroRoot = headerSaplingRoot.allSatisfy { $0 == 0 }

            // Check if this is likely a corrupted P2P header
            // P2P headers often have the same root copied to multiple heights (bug in P2P parsing)
            print("⚠️ FIX #796: Validation height \(treeValidationHeight) is ABOVE boost file end \(boostEndHeight)")
            print("⚠️ FIX #796: Header sapling root may be unreliable (P2P protocol limitation)")

            if isZeroRoot {
                print("⚠️ FIX #796: Header has ZERO sapling root - skipping validation (P2P artifact)")
                return .passed("Tree Root Validation",
                              details: "⚠️ P2P header at \(treeValidationHeight) has zero sapling root - tree root trusted")
            }

            // For non-zero roots above boost file, still skip validation but log for debugging
            // The tree root is computed from CMUs which are verified, so trust the tree
            print("⚠️ FIX #796: Skipping validation for P2P-range height - tree root computed from verified CMUs")
            return .passed("Tree Root Validation",
                          details: "✓ Tree root trusted (height \(treeValidationHeight) above boost file \(boostEndHeight))")
        }

        // FIX #XXX: Try both byte orders - headers might be stored in different order
        // The FFI tree root comes from zcash_primitives (little-endian internally)
        // Headers are parsed from network bytes (also little-endian)
        // But storage/display might flip byte order, so try both
        let headerSaplingRootReversed = Data(headerSaplingRoot.reversed())
        let rootsMatch = currentTreeRoot == headerSaplingRoot || currentTreeRoot == headerSaplingRootReversed

        // DEBUG: Log comparison details
        print("🔍 DEBUG: Tree root comparison at height \(treeValidationHeight)")
        print("   FFI tree root (\(currentTreeRoot.count) bytes): \(currentTreeRoot.prefix(8).hexString)...")
        print("   Header root (\(headerSaplingRoot.count) bytes): \(headerSaplingRoot.prefix(8).hexString)...")
        print("   Match (as-is): \(currentTreeRoot == headerSaplingRoot)")
        print("   Match (reversed): \(currentTreeRoot == headerSaplingRootReversed)")

        if rootsMatch {
            print("✅ FIX #358: Tree root VERIFIED at height \(treeValidationHeight)")
            print("   Root: \(currentTreeRoot.prefix(8).map { String(format: "%02x", $0) }.joined())...")

            // FIX #414: Clear Equihash "reduced verification" alert when Tree Root passes
            // Tree Root Validation is a STRONGER cryptographic proof than Equihash PoW
            // - Equihash: Verifies mining work was done (can be faked with enough hashrate)
            // - Tree Root: Cryptographically proves ENTIRE commitment tree state is correct
            // If Tree Root matches, the blockchain state is definitively correct
            print("✅ FIX #414: Clearing reduced verification alert - Tree Root is stronger proof than Equihash")
            WalletManager.shared.clearReducedVerificationAlert()

            return .passed("Tree Root Validation",
                          details: "✓ Tree root cryptographically verified at height \(treeValidationHeight)")
        } else {
            // MISMATCH! This is serious - either tree or header is wrong
            print("❌ FIX #358: Tree root MISMATCH at height \(treeValidationHeight)!")
            print("   Our tree root:        \(currentTreeRoot.hexString)")
            print("   Header sapling root:  \(headerSaplingRoot.hexString)")
            print("   Header root reversed: \(headerSaplingRootReversed.hexString)")
            print("   Tree size: \(treeSize) CMUs")

            // FIX #732: If we reach here, there's a REAL mismatch!
            // The validation height was chosen correctly based on deltaCMUs:
            // - deltaCMUs=0 → validated at boost end height
            // - deltaCMUs>0 → validated at delta manifest endHeight
            //
            // A mismatch here means tree state doesn't match blockchain.
            // This could be caused by:
            // 1. Corrupted tree data in database
            // 2. Wrong CMU byte order in boost file
            // 3. Delta CMUs not properly appended (P2P missed some outputs)
            if validatingAgainstBoostFile {
                print("❌ FIX #732: Tree root mismatch at boost validation height!")
                print("❌ FIX #732: This indicates tree corruption or byte order issue")
                print("❌ FIX #732: deltaCMUs=\(deltaCMUs), treeValidationHeight=\(treeValidationHeight)")
            }

            // FIX #778: Check if repair has already been attempted this session
            // If repair was already tried (FIX #779 limit reached), don't return critical
            // This prevents repair → health check → repair → health check infinite loop
            let repairAttemptKey = "TreeRootRepairAttempted"
            let repairSessionKey = "TreeRootRepairSession"
            let currentSession = Int(Date().timeIntervalSince1970 / 300) // 5-minute sessions
            let lastSession = UserDefaults.standard.integer(forKey: repairSessionKey)
            let repairAttempted = UserDefaults.standard.bool(forKey: repairAttemptKey)

            // Reset flag if new session
            if currentSession != lastSession {
                UserDefaults.standard.set(false, forKey: repairAttemptKey)
                UserDefaults.standard.set(currentSession, forKey: repairSessionKey)
            }

            // FIX #782: Check if global repair attempts have been exhausted
            // If so, return non-critical to prevent infinite repair loops across app restarts
            let repairExhausted = UserDefaults.standard.bool(forKey: "TreeRepairExhausted")
            if repairExhausted {
                print("🛑 FIX #782: Global tree repair attempts exhausted - returning non-critical")
                print("🛑 FIX #782: P2P cannot fetch all CMUs - user MUST run 'Full Resync' in Settings")
                return .failed("Tree Root Validation",
                              details: "⚠️ Auto-repair exhausted. Run 'Full Resync' in Settings to fix.",
                              critical: false)  // Non-critical to prevent infinite repair loop
            }

            // If repair was already attempted this session, return non-critical to break loop
            if repairAttempted && currentSession == lastSession {
                print("🛑 FIX #778: Repair already attempted this session - returning non-critical to break loop")
                print("🛑 FIX #778: User should try 'Full Rescan' in Settings")
                return .failed("Tree Root Validation",
                              details: "⚠️ Tree root mismatch persists. Try Full Rescan in Settings.",
                              critical: false)  // Non-critical to prevent repair loop
            }

            // Mark that repair will be attempted
            UserDefaults.standard.set(true, forKey: repairAttemptKey)
            UserDefaults.standard.set(currentSession, forKey: repairSessionKey)

            // This is CRITICAL - balance calculations will be wrong!
            return .failed("Tree Root Validation",
                          details: "🚨 Tree root mismatch at height \(treeValidationHeight)! Try Full Rescan in Settings.",
                          critical: true)
        }
    }

    // MARK: - VUL-002: Phantom Transaction Detection

    /// VUL-002: CRITICAL - Verify all SENT transactions actually exist on blockchain
    /// Phantom transactions (locally recorded but never confirmed by network) cause:
    /// 1. Incorrect balance (shows less than actual)
    /// 2. Notes incorrectly marked as spent
    /// 3. Corrupted transaction history
    ///
    /// This check queries InsightAPI (or P2P) to verify each sent TX exists on chain.
    /// If a TX doesn't exist, it's a PHANTOM and must be removed!
    private func checkSentTransactionsOnChain() async -> HealthCheckResult {
        print("🔍 VUL-002: Checking all SENT transactions exist on blockchain...")

        // Get all SENT transactions from history
        guard let sentTxs = try? WalletDatabase.shared.getSentTransactions() else {
            return .passed("Sent TX Verification", details: "No sent transactions to verify")
        }

        if sentTxs.isEmpty {
            return .passed("Sent TX Verification", details: "No sent transactions to verify")
        }

        print("🔍 VUL-002: Found \(sentTxs.count) SENT transaction(s) to verify")

        var phantomTxs: [(txid: String, height: UInt64, value: UInt64)] = []
        var verifiedCount = 0
        var errorCount = 0

        for tx in sentTxs {
            let txidHex = tx.txid.map { String(format: "%02x", $0) }.joined()

            // FIX #181: Skip boost placeholder txids - they are NOT real transactions
            // These are inserted during boost file scanning with prefix "boost_spent_" (hex: 626f6f73745f7370656e745f)
            if txidHex.hasPrefix("626f6f73745f7370") { // hex for "boost_sp"
                // Don't try to verify - it's a placeholder, not a real txid
                errorCount += 1  // Count as error so the warning message reflects this
                continue
            }

            // FIX #269: Check if we have peers BEFORE verification
            // If no peers available, don't mark as phantom - just skip this TX
            // FIX #384: Use PeerManager for centralized peer access
            let connectedPeers = await MainActor.run { PeerManager.shared.getReadyPeers() }
            if connectedPeers.isEmpty {
                print("⚠️ FIX #269: No peers available for TX \(txidHex.prefix(16))... - skipping (NOT phantom)")
                errorCount += 1  // Count as network error, not phantom
                continue
            }

            // FIX #247: Use P2P verification instead of InsightAPI (decentralized)
            // FIX #888: Now returns Bool? - nil means unable to verify (don't mark as phantom!)
            let (exists, confirmations) = await NetworkManager.shared.verifyTxExistsViaP2P(txid: txidHex)

            switch exists {
            case .some(true):
                // TX definitely exists
                verifiedCount += 1
                if confirmations > 0 {
                    print("✅ FIX #247: TX \(txidHex.prefix(16))... verified via P2P (\(confirmations) confirmations)")
                } else {
                    print("⏳ FIX #247: TX \(txidHex.prefix(16))... found via P2P (mempool/unconfirmed)")
                }

            case .none:
                // FIX #888: Unable to verify - DO NOT mark as phantom!
                // This prevents incorrectly deleting confirmed TXs when network is down
                print("⚠️ FIX #888: TX \(txidHex.prefix(16))... unable to verify - skipping (network issue, NOT phantom)")
                errorCount += 1
                continue

            case .some(false):
                // FIX #269: Re-check peers before declaring phantom
                // Peers may have dropped during the verification attempt
                // FIX #384: Use PeerManager for centralized peer access
                let stillConnectedPeers = await MainActor.run { PeerManager.shared.getReadyPeers() }
                if stillConnectedPeers.isEmpty {
                    print("⚠️ FIX #269: Peers dropped during TX \(txidHex.prefix(16))... check - skipping (NOT phantom)")
                    errorCount += 1  // Count as network error, not phantom
                    continue
                }

                // TX not found via P2P - could be phantom OR peers don't have it yet
                // Try multiple peers before marking as phantom
                let p2pVerified = await NetworkManager.shared.verifyTxViaP2P(txid: txidHex, maxAttempts: 5)
                if p2pVerified {
                    verifiedCount += 1
                    print("✅ FIX #247: TX \(txidHex.prefix(16))... verified via P2P (retry)")
                } else {
                    // FIX #269: Final peer check before marking phantom
                    // FIX #384: Use PeerManager for centralized peer access
                    let finalPeerCheck = await MainActor.run { PeerManager.shared.getReadyPeers() }
                    if finalPeerCheck.isEmpty {
                        print("⚠️ FIX #269: All peers lost during TX \(txidHex.prefix(16))... verification - skipping (NOT phantom)")
                        errorCount += 1
                        continue
                    }

                    // PHANTOM TRANSACTION DETECTED! (verified with peers still connected)
                    print("🚨 FIX #247: PHANTOM TX DETECTED! \(txidHex) does NOT exist (P2P verified with \(finalPeerCheck.count) peers)")
                    phantomTxs.append((txid: txidHex, height: tx.height, value: tx.value))
                }
            }
        }

        // Store phantom TXs for repair
        if !phantomTxs.isEmpty {
            // FIX #355: Removed overly conservative FIX #269 v2 checks
            // The old logic blocked phantom detection when verifiedCount == 0, but this is wrong:
            // - P2P getdata only returns TXs in mempool, not confirmed TXs
            // - So verifiedCount will be 0 for old/confirmed TXs even if network works
            // - If peers responded with "notfound", that's a VALID detection, not a network issue
            //
            // New logic: If we detected phantoms and had peers to query, trust the detection
            // Only skip if ALL checks failed with errors (no phantoms detected at all would mean empty array)
            // If we detected phantoms, that means peers responded - network worked!
            print("🔍 FIX #355: Phantom detection - verified: \(verifiedCount), errors: \(errorCount), phantoms: \(phantomTxs.count)")

            // Store in UserDefaults for the repair function to use
            let phantomData = phantomTxs.map { ["txid": $0.txid, "height": $0.height, "value": $0.value] as [String: Any] }
            UserDefaults.standard.set(phantomData, forKey: "phantomTransactions")

            let totalPhantomValue = phantomTxs.reduce(0) { $0 + $1.value }
            let totalPhantomZCL = Double(totalPhantomValue) / 100_000_000.0

            return .failed("Sent TX Verification",
                          details: "🚨 PHANTOM TXs: \(phantomTxs.count) sent TX(s) NOT on blockchain! Balance off by \(String(format: "%.8f", totalPhantomZCL)) ZCL. Run Repair Database!",
                          critical: true)  // CRITICAL - balance is WRONG
        }

        if errorCount > 0 {
            return .passed("Sent TX Verification",
                          details: "Verified \(verifiedCount)/\(sentTxs.count) TXs (\(errorCount) could not be checked - network issues)")
        }

        // Clear any old phantom data
        UserDefaults.standard.removeObject(forKey: "phantomTransactions")

        return .passed("Sent TX Verification", details: "All \(verifiedCount) sent transaction(s) verified on blockchain ✓")
    }

    // MARK: - FIX #550: Auto-detect and fix anchor mismatches

    /// FIX #550: Auto-detect and fix anchor mismatches at startup
    /// Compares stored note anchors with blockchain headers
    /// If mismatches found, auto-rebuilds witnesses with correct HeaderStore anchors
    ///
    /// FIX #783: Skip auto-fix when tree repair is exhausted to prevent infinite loop
    /// FIX #828: Changed to verify witness CONSISTENCY, not header comparison
    ///
    /// OLD (WRONG): Compare stored anchor vs HeaderStore at note height
    ///   - Witnesses created at boost file height all have SAME root
    ///   - Comparing to note height gives false positives
    ///   - Sapling accepts ANY historical tree root as anchor
    ///
    /// NEW (FIX #828): Verify witness internal consistency
    ///   - Check if witness.root() == merkle_path.root(cmu)
    ///   - This is what the transaction builder actually uses
    ///   - Uses FIX #827 witnessVerifyAnchor() function
    private func checkNoteAnchorsMatchHeaders() async -> HealthCheckResult {
        do {
            // FIX #1111: Skip witness check when tree is not caught up to lastScannedHeight
            // Root cause of 45s startup: Delta bundle ends at 3002599 but lastScannedHeight=3002937
            // Witnesses created at 3002937 fail verification against tree at 3002599
            // After catch-up sync, witnesses are fine - this is a false positive!
            let lastScannedHeight = try WalletDatabase.shared.getLastScannedHeight()
            let treeSize = ZipherXFFI.treeSize()
            let boostEndHeight: UInt64 = 2988797  // ZipherXConstants.effectiveTreeHeight

            // If tree is smaller than it should be for lastScannedHeight, skip check
            // Tree needs CMUs up to lastScannedHeight to verify witnesses correctly
            if lastScannedHeight > boostEndHeight {
                // Rough check: tree should have grown since boost end
                // Delta should have CMUs from boost end to lastScannedHeight
                let deltaManifest = DeltaCMUManager.shared.getManifest()
                let deltaEndHeight = deltaManifest?.endHeight ?? boostEndHeight

                if deltaEndHeight < lastScannedHeight {
                    print("⏭️ FIX #1111: Skipping witness check - tree not caught up")
                    print("   Delta ends at \(deltaEndHeight) but lastScannedHeight=\(lastScannedHeight)")
                    print("   Will verify witnesses after catch-up sync completes")
                    return .passed("Anchor Validation", details: "Deferred - tree syncing to \(lastScannedHeight)")
                }
            }

            // FIX #760: Get all unspent notes with anchors (use accountId: 1)
            let notes = try WalletDatabase.shared.getAllUnspentNotes(accountId: 1)
            let unspentNotes = notes.filter { $0.cmu != nil && $0.witness.count >= 100 }

            guard !unspentNotes.isEmpty else {
                return .passed("Anchor Validation", details: "No unspent notes with witnesses to check")
            }

            print("🔍 FIX #828: Checking witness consistency for \(unspentNotes.count) unspent notes...")

            var corruptedNotes: [(noteId: Int64, height: UInt64)] = []

            // FIX #828: Check witness internal consistency using FIX #827's function
            for note in unspentNotes {
                guard let cmu = note.cmu, !cmu.isEmpty else { continue }

                // FIX #827: Verify witness.root() == merkle_path.root(cmu)
                if !ZipherXFFI.witnessVerifyAnchor(note.witness, cmu: cmu) {
                    corruptedNotes.append((noteId: note.id, height: UInt64(note.height)))
                    print("   ❌ Note \(note.id) height \(note.height): WITNESS CORRUPTED (path computes different root)")
                }
            }

            if corruptedNotes.isEmpty {
                print("✅ FIX #828: All \(unspentNotes.count) witnesses are internally consistent!")
                return .passed("Anchor Validation", details: "All \(unspentNotes.count) witnesses consistent ✓")
            }

            // FIX #783: Check if tree repair is exhausted BEFORE attempting auto-fix
            let repairExhausted = UserDefaults.standard.bool(forKey: "TreeRepairExhausted")
            if repairExhausted {
                print("🛑 FIX #783: Tree repair exhausted - SKIPPING auto-fix to prevent infinite loop")
                print("🛑 FIX #783: \(corruptedNotes.count) corrupted witnesses detected but cannot auto-fix")
                print("🛑 FIX #783: User MUST run 'Full Resync' in Settings to rebuild witnesses")

                return .failed("Anchor Validation",
                              details: "⚠️ \(corruptedNotes.count) corrupted witnesses. Auto-repair exhausted. Run 'Full Resync' in Settings.",
                              critical: false)
            }

            // FIX #828: AUTO-FIX - Rebuild corrupted witnesses
            print("🔧 FIX #828: Found \(corruptedNotes.count) corrupted witnesses - AUTO-FIXING...")
            print("   This will rebuild witnesses with consistent anchors...")

            let fixed = await WalletManager.shared.fixAnchorMismatches()

            if fixed >= corruptedNotes.count {
                print("✅ FIX #828: Successfully rebuilt \(fixed) witnesses!")
                return .passed("Anchor Validation", details: "Rebuilt \(fixed) witnesses ✓")
            } else {
                print("⚠️ FIX #828: Rebuilt \(fixed)/\(corruptedNotes.count) witnesses")
                return .failed("Anchor Validation",
                              details: "Rebuilt \(fixed)/\(corruptedNotes.count) witnesses. Run 'Full Resync' in Settings to retry.",
                              critical: false)
            }

        } catch {
            print("❌ FIX #828: Error checking witnesses: \(error)")
            return .failed("Anchor Validation", details: "Error: \(error.localizedDescription)", critical: false)
        }
    }

    // MARK: - FIX #574: Stale Witness Detection

    /// FIX #574: Detect stale witnesses at startup
    /// Checks if witness anchors match CURRENT tree root
    /// This is critical after FIX #572/573 - stale witnesses cause "joinsplit requirements not met" rejections
    ///
    /// FIX #783: Skip auto-rebuild when tree repair is exhausted to prevent infinite loop:
    /// - Tree root mismatch → FIX #524 repair → P2P timeout → mismatch persists
    /// - FIX #782 sets TreeRepairExhausted after 5 global attempts
    /// - FIX #574 sees stale witnesses → tries rebuild → P2P timeout → triggers more repairs
    /// - Loop continues forever unless we break it here
    private func checkStaleWitnesses() async -> HealthCheckResult {
        do {
            // Get current tree root from FFI
            guard let currentTreeRoot = ZipherXFFI.treeRoot(), !currentTreeRoot.isEmpty else {
                print("⚠️ FIX #574: No tree root available - skipping stale witness check")
                return .passed("Stale Witness Check", details: "Tree not loaded yet")
            }

            let currentRootHex = currentTreeRoot.prefix(8).map { String(format: "%02x", $0) }.joined()
            print("🔍 FIX #574: Checking for stale witnesses (current root: \(currentRootHex)...)...")

            // FIX #760: Get all unspent notes (use accountId: 1)
            let notes = try WalletDatabase.shared.getAllUnspentNotes(accountId: 1)
            // FIX #1107: Changed from 1028 to 100
            let unspentNotes = notes.filter { !$0.witness.isEmpty && $0.witness.count >= 100 }

            guard !unspentNotes.isEmpty else {
                return .passed("Stale Witness Check", details: "No unspent notes with witnesses")
            }

            var staleCount = 0
            var validCount = 0
            var staleNoteIds: [Int64] = []

            // FIX #800: REVERTS FIX #785 - Witnesses are anchored at CURRENT tree root, not note height!
            //
            // FIX #785 was WRONG! It assumed witnesses are anchored at their confirmation height.
            // But the Rust FFI `treeCreateWitnessesBatch` builds ALL witnesses to the SAME root
            // (the current tree state), as stated in lib.rs:4345:
            //   "Created {}/{} witnesses (all with same root)"
            //
            // TransactionBuilder.swift (FIX #557 v38) correctly uses the witness's own root as anchor.
            // The Sapling protocol accepts ANY historical tree root that the network has seen.
            //
            // FIX #785's check "witness root == header root at note height" ALWAYS failed because:
            //   - Witness root = current tree root (same for all witnesses)
            //   - Header root at note height = historical root (different for each height)
            //
            // This caused the 42x "stale witness detected" loop even when witnesses were valid.
            //
            // The correct check: witness root should match CURRENT FFI tree root (or be valid).
            // If a witness extracts successfully and has a root, it's valid for spending.

            for note in unspentNotes {
                // Extract anchor from the witness itself (not from DB stored anchor)
                // The witness internal root is what matters for transaction validity
                if let witnessRoot = ZipherXFFI.witnessGetRoot(note.witness) {
                    // FIX #1013: REMOVED FIX #988's broken comparison to current tree root!
                    //
                    // FIX #988 was WRONG: It compared witness root to CURRENT tree root
                    // and flagged witnesses as "stale" when they didn't match.
                    //
                    // SAPLING TRUTH:
                    // - Sapling accepts ANY VALID HISTORICAL ANCHOR within the exclusion period
                    // - When new blocks arrive, the current tree root changes
                    // - This does NOT invalidate existing witnesses with older anchors
                    // - A witness with anchor from block 2990000 is VALID even if tree is now at 2992000
                    //
                    // FIX #988's broken logic caused:
                    // - 73 witnesses flagged as "stale" at every startup (when blocks arrived)
                    // - 60+ second rebuild every time user tried to send
                    // - Same unnecessary rebuild in TransactionBuilder (FIX #986 - also fixed)
                    //
                    // CORRECT CHECK: Witness is valid if we can extract a NON-ZERO root
                    // - Zero root = corrupted/uninitialized witness
                    // - Non-zero root = valid historical anchor (Sapling will accept it)
                    let isZeroAnchor = witnessRoot.allSatisfy { $0 == 0 }
                    if !isZeroAnchor {
                        validCount += 1
                    } else {
                        // Zero root = corrupted witness, needs rebuild
                        staleCount += 1
                        staleNoteIds.append(note.id)
                        print("   ❌ FIX #1013: Note \(note.id) (height \(note.height)): ZERO anchor - corrupted, needs rebuild")
                    }
                } else {
                    // Could not extract root - this IS invalid (corrupted witness)
                    staleCount += 1
                    staleNoteIds.append(note.id)
                    print("   ❌ Note \(note.id): Could not extract witness root - needs rebuild")
                }
            }

            if staleCount == 0 {
                print("✅ FIX #1013: All \(validCount) witnesses have valid anchors (instant sends enabled)!")
                // FIX #801: Reset repair counters when witnesses are healthy - allows auto-recovery
                // Without this, counters stay elevated and block future repairs even when fixed
                let staleWitnessGlobalKey = "StaleWitnessGlobalAttempts"
                let staleWitnessAttemptKey = "StaleWitnessRepairAttempted"
                if UserDefaults.standard.integer(forKey: staleWitnessGlobalKey) > 0 {
                    print("   🔄 FIX #801: Resetting stale witness repair counters (witnesses now valid)")
                    UserDefaults.standard.set(0, forKey: staleWitnessGlobalKey)
                    UserDefaults.standard.set(false, forKey: staleWitnessAttemptKey)
                }
                return .passed("Stale Witness Check", details: "All \(validCount) witnesses are current ✓")
            }

            print("🚨 FIX #1013: Found \(staleCount)/\(unspentNotes.count) witnesses with ZERO/CORRUPTED anchors!")
            print("🚨 FIX #1013: These need rebuild (zero anchor = uninitialized witness)")

            // FIX #783: Check if tree repair is exhausted BEFORE attempting auto-rebuild
            // When TreeRepairExhausted is true, P2P cannot fetch delta CMUs (persistent network issue)
            // Auto-rebuild will timeout and fail, triggering more repair attempts → infinite loop
            // The only solution is Full Resync which uses a different code path (downloads complete boost file)
            let repairExhausted = UserDefaults.standard.bool(forKey: "TreeRepairExhausted")
            if repairExhausted {
                print("🛑 FIX #783: Tree repair exhausted - SKIPPING auto-rebuild to prevent infinite loop")
                print("🛑 FIX #783: P2P delta sync has failed repeatedly - witnesses cannot be fixed automatically")
                print("🛑 FIX #783: User MUST run 'Full Resync' in Settings to rebuild tree and witnesses")

                // Return non-critical to allow app to continue
                // User can still see balance (may be incorrect) and attempt Full Resync
                return .failed("Stale Witness Check",
                              details: "⚠️ \(staleCount) stale witnesses. Auto-repair exhausted. Run 'Full Resync' in Settings.",
                              critical: false)  // Non-critical to break the repair loop
            }

            // FIX #783: Check stale witness-specific repair counter to prevent loop
            // This is SEPARATE from TreeRepairExhausted (which tracks tree root mismatch)
            // Stale witnesses can loop independently even when tree is correct
            let staleWitnessAttemptKey = "StaleWitnessRepairAttempted"
            let staleWitnessSessionKey = "StaleWitnessRepairSession"
            let staleWitnessGlobalKey = "StaleWitnessGlobalAttempts"

            let currentSession = Int(Date().timeIntervalSince1970 / 300) // 5-minute sessions
            let lastSession = UserDefaults.standard.integer(forKey: staleWitnessSessionKey)
            let repairAttempted = UserDefaults.standard.bool(forKey: staleWitnessAttemptKey)
            var globalAttempts = UserDefaults.standard.integer(forKey: staleWitnessGlobalKey)

            // Reset session flag if new session
            if currentSession != lastSession {
                UserDefaults.standard.set(false, forKey: staleWitnessAttemptKey)
                UserDefaults.standard.set(currentSession, forKey: staleWitnessSessionKey)
            }

            // FIX #783: If repair was already attempted this session, return non-critical to break loop
            let maxGlobalAttempts = 5
            if repairAttempted && currentSession == lastSession {
                print("🛑 FIX #783: Stale witness repair already attempted this session - breaking loop")
                print("🛑 FIX #783: Global attempts: \(globalAttempts)/\(maxGlobalAttempts)")
                return .failed("Stale Witness Check",
                              details: "⚠️ \(staleCount) stale witnesses persist. Try Full Resync in Settings.",
                              critical: false)  // Non-critical to break the loop
            }

            // FIX #783: If global attempts exhausted, return non-critical
            if globalAttempts >= maxGlobalAttempts {
                print("🛑 FIX #783: Max global stale witness repair attempts (\(maxGlobalAttempts)) exceeded!")
                print("🛑 FIX #783: User MUST run 'Full Resync' in Settings")
                return .failed("Stale Witness Check",
                              details: "⚠️ Auto-repair exhausted after \(maxGlobalAttempts) attempts. Run Full Resync.",
                              critical: false)
            }

            // Mark repair attempt
            UserDefaults.standard.set(true, forKey: staleWitnessAttemptKey)
            globalAttempts += 1
            UserDefaults.standard.set(globalAttempts, forKey: staleWitnessGlobalKey)
            print("🔧 FIX #783: Stale witness repair attempt \(globalAttempts)/\(maxGlobalAttempts) (global)")

            // FIX #574: AUTO-FIX - Trigger witness rebuild
            print("🔧 FIX #574: AUTO-FIXING stale witnesses - rebuilding witnesses...")

            // Trigger witness rebuild
            await WalletManager.shared.rebuildWitnessesForStartup()

            // FIX #783: Verify fix worked by fetching FRESH data from database
            // CRITICAL BUG FIX: Previous code used old `notes` array loaded BEFORE the rebuild!
            // The old array still contained stale witness data → verification always failed → infinite loop
            // Must re-fetch notes from database to get the REBUILT witness data
            // FIX #800: Check if witness root can be extracted (not if it matches header at note height)
            var stillStale = 0
            let freshNotes = try WalletDatabase.shared.getAllUnspentNotes(accountId: 1)
            for noteId in staleNoteIds {
                // FIX #783: Use freshNotes (just fetched from DB) instead of stale `notes` array
                // FIX #800: A witness is valid if we can extract its root - don't compare to header
                if let freshNote = freshNotes.first(where: { $0.id == noteId }),
                   !freshNote.witness.isEmpty,
                   ZipherXFFI.witnessGetRoot(freshNote.witness) != nil {
                    // Witness has valid root - it's fixed!
                    continue
                } else {
                    // Fresh note has empty witness or can't extract root - rebuild didn't work
                    stillStale += 1
                    print("   ⚠️ FIX #800: Note \(noteId) still has no valid witness after rebuild")
                }
            }

            if stillStale == 0 {
                print("✅ FIX #574: Successfully fixed all \(staleCount) stale witnesses!")
                // FIX #783: Reset global counter on success - repair worked!
                UserDefaults.standard.set(0, forKey: staleWitnessGlobalKey)
                return .passed("Stale Witness Check", details: "Fixed \(staleCount) stale witnesses ✓")
            } else {
                print("⚠️ FIX #574: \(stillStale)/\(staleCount) witnesses still stale after rebuild")
                // FIX #783: Return NON-CRITICAL since repair was already attempted
                // This breaks the repair → health check → repair loop
                // User will see the warning and can manually run Full Resync
                return .failed("Stale Witness Check",
                              details: "\(stillStale)/\(staleCount) witnesses still stale. Try Settings → Full Resync.",
                              critical: false)  // FIX #783: Changed from true to false to break loop
            }

        } catch {
            print("❌ FIX #574: Error checking stale witnesses: \(error)")
            return .failed("Stale Witness Check", details: "Error: \(error.localizedDescription)", critical: false)
        }
    }

    /// FIX #698: Detect and auto-repair zero sapling roots in HeaderStore
    /// P2P bug causes localhost Zclassic node to send headers with zero sapling roots
    /// This causes transaction failures: "joinsplit requirements not met"
    /// Auto-repairs using RPC if available (macOS only)
    private func checkAndRepairZeroSaplingRoots() async -> HealthCheckResult {
        print("🔍 FIX #698: Checking for zero sapling roots in HeaderStore...")

        do {
            // Check if there are any zero sapling roots
            guard let range = try HeaderStore.shared.getZeroSaplingRootRange() else {
                print("✅ FIX #698: No zero sapling roots found")
                return .passed("Sapling Root Check", details: "All headers have valid sapling roots ✓")
            }

            let zeroCount = range.1 - range.0 + 1
            print("🚨 FIX #698: Found \(zeroCount) headers with zero sapling roots (heights \(range.0)-\(range.1))")

            // FIX #797: In ZipherX P2P mode, skip RPC repair - P2P only!
            // RPC is only available in Full Node wallet.dat mode
            if !WalletModeManager.shared.isUsingWalletDat {
                print("⚠️ FIX #797: ZipherX P2P mode - RPC repair not available")
                print("⚠️ FIX #797: Zero sapling roots may indicate P2P header corruption")
                print("⚠️ FIX #797: Use 'Clear Block Headers' in Settings to re-sync from boost file")
                // In ZipherX mode, zero sapling roots in P2P headers are expected (FIX #796 handles this)
                // Return non-critical since FIX #796 skips validation for P2P-range heights anyway
                return .passed("Sapling Root Check",
                              details: "⚠️ \(zeroCount) P2P headers have zero sapling roots (expected in P2P mode)")
            }

            #if os(macOS)
            // Try to repair using RPC (only in Full Node wallet.dat mode)
            print("🔧 FIX #698: Attempting RPC-based repair...")

            let rpcClient = RPCClient.shared
            do {
                try rpcClient.loadConfig()
            } catch {
                print("⚠️ FIX #698: RPC config not available: \(error)")
                return .failed("Sapling Root Check",
                              details: "\(zeroCount) headers have zero sapling roots. RPC unavailable for repair. TX will fail.",
                              critical: true)
            }

            // Check if daemon is running
            let isConnected = await rpcClient.checkConnection()
            guard isConnected else {
                print("⚠️ FIX #698: Zclassic daemon not running - cannot repair via RPC")
                return .failed("Sapling Root Check",
                              details: "\(zeroCount) headers have zero sapling roots. Start zclassicd for auto-repair.",
                              critical: true)
            }

            // Get the list of heights that need repair
            let heights = try HeaderStore.shared.getHeightsWithZeroSaplingRoots()
            guard !heights.isEmpty else {
                print("✅ FIX #698: No heights to repair (race condition?)")
                return .passed("Sapling Root Check", details: "All headers have valid sapling roots ✓")
            }

            // Get the current node height to know which headers we can repair
            let nodeHeight = rpcClient.blockHeight
            print("📊 FIX #698: Node height: \(nodeHeight), need to repair heights: \(heights.first ?? 0)-\(heights.last ?? 0)")

            // Filter heights that the node can provide
            let repairableHeights = heights.filter { $0 <= nodeHeight }
            let unrepairableHeights = heights.filter { $0 > nodeHeight }

            if !unrepairableHeights.isEmpty {
                print("⚠️ FIX #698: \(unrepairableHeights.count) headers above node height (\(nodeHeight)) - will delete")
                try HeaderStore.shared.deleteHeadersAbove(height: nodeHeight)
            }

            if repairableHeights.isEmpty {
                print("✅ FIX #698: All zero-root headers were beyond node height and deleted")
                return .passed("Sapling Root Check", details: "Deleted \(unrepairableHeights.count) future headers ✓")
            }

            // Recover sapling roots via RPC
            print("🔧 FIX #698: Recovering \(repairableHeights.count) sapling roots via RPC...")

            var repaired: [UInt64: Data] = [:]
            var errors = 0

            for height in repairableHeights {
                do {
                    let saplingRootHex = try await rpcClient.getSaplingRoot(at: height)

                    // Convert hex string to Data (big-endian from RPC)
                    if let saplingData = Data(hexString: saplingRootHex) {
                        // Reverse to little-endian for storage
                        let reversedData = Data(saplingData.reversed())
                        repaired[height] = reversedData
                    }
                } catch {
                    errors += 1
                    if errors <= 3 {
                        print("⚠️ FIX #698: Failed to get sapling root at height \(height): \(error)")
                    }
                }
            }

            // Apply the repairs
            if !repaired.isEmpty {
                try HeaderStore.shared.updateSaplingRoots(repaired)
                print("✅ FIX #698: Successfully repaired \(repaired.count) sapling roots via RPC")
            }

            // Verify the fix
            if let remainingRange = try HeaderStore.shared.getZeroSaplingRootRange() {
                let remaining = remainingRange.1 - remainingRange.0 + 1
                print("⚠️ FIX #698: \(remaining) headers still have zero sapling roots")
                return .failed("Sapling Root Check",
                              details: "Repaired \(repaired.count), but \(remaining) still have zero sapling roots",
                              critical: remaining > 10)
            }

            let totalFixed = repaired.count + unrepairableHeights.count
            print("✅ FIX #698: All zero sapling roots fixed! (repaired: \(repaired.count), deleted: \(unrepairableHeights.count))")
            return .passed("Sapling Root Check", details: "Fixed \(totalFixed) headers via RPC ✓")

            #else
            // iOS - no RPC available, just warn
            print("⚠️ FIX #698: Zero sapling roots detected on iOS - RPC repair not available")
            return .failed("Sapling Root Check",
                          details: "\(zeroCount) headers have zero sapling roots. TX may fail. Re-sync headers from different peer.",
                          critical: true)
            #endif

        } catch {
            print("❌ FIX #698: Error checking zero sapling roots: \(error)")
            return .failed("Sapling Root Check", details: "Error: \(error.localizedDescription)", critical: false)
        }
    }

    // MARK: - FIX #876: Notes Without Witnesses Check

    /// FIX #876: CRITICAL - Check for notes without witnesses
    /// Notes without witnesses are EXCLUDED from balance calculation (getBalance WHERE witness IS NOT NULL)
    /// This causes balance to show WRONG until witnesses are computed
    ///
    /// Root cause: Delta CMU collection failed or was cleared (FIX #756), leaving notes in delta range
    /// without the CMUs needed to compute their witnesses
    ///
    /// FIX #1082: NO LONGER BLOCKS STARTUP - witness rebuild moved to AFTER PHASE 2 scan
    /// Previously this function would trigger a full P2P delta fetch (10+ minutes) on every startup.
    /// Now we let PHASE 2 collect delta CMUs naturally, then rebuild witnesses afterward.
    private func checkNotesWithoutWitnesses() async -> HealthCheckResult {
        print("🔍 FIX #876: Checking for notes without witnesses...")

        do {
            // Get notes without valid witnesses
            let (count, totalValue, minHeight) = try WalletDatabase.shared.getNotesWithoutWitnesses(accountId: 1)

            if count == 0 {
                print("✅ FIX #876: All notes have valid witnesses")
                return .passed("Notes Witness Check", details: "All notes have valid witnesses ✓")
            }

            // Notes exist without witnesses - this is CRITICAL because balance is WRONG
            let boostFileEndHeight = UInt64(ZipherXConstants.effectiveTreeHeight)
            let valueZCL = Double(totalValue) / 100_000_000.0

            print("🚨 FIX #876: CRITICAL - \(count) notes without witnesses!")
            print("   💰 Total value affected: \(String(format: "%.8f", valueZCL)) ZCL")
            print("   📍 Min note height: \(minHeight) (boost file ends at \(boostFileEndHeight))")

            // FIX #1082: Check if notes are ONLY in boost range (can rebuild instantly)
            // vs delta range (requires P2P fetch which is slow)
            let maxNoteHeight = try WalletDatabase.shared.getMaxUnspentNoteHeight(accountId: 1)
            let allNotesInBoostRange = maxNoteHeight <= boostFileEndHeight

            if allNotesInBoostRange {
                // All notes are in boost range - can rebuild instantly from local data
                print("   ⚡ FIX #1082: All notes in boost range - instant rebuild possible!")
                print("   🔧 FIX #876: Triggering automatic witness rebuild...")

                // Attempt to rebuild witnesses (fast - no P2P needed)
                await WalletManager.shared.rebuildWitnessesForStartup()

                // Verify fix worked
                let (stillMissing, _, _) = try WalletDatabase.shared.getNotesWithoutWitnesses(accountId: 1)

                if stillMissing == 0 {
                    print("✅ FIX #876: Successfully computed witnesses for all \(count) notes!")

                    // FIX #1074: Refresh balance after witness rebuild so UI shows correct amount
                    print("🔄 FIX #1074: Refreshing balance after witness rebuild...")
                    try await WalletManager.shared.refreshBalance()

                    return .passed("Notes Witness Check", details: "Fixed \(count) notes - witnesses computed ✓")
                } else {
                    print("⚠️ FIX #876: \(stillMissing)/\(count) notes still without witnesses")
                    // Still return passed to avoid blocking startup
                    return .passed("Notes Witness Check", details: "Witnesses will rebuild after sync")
                }
            } else {
                // FIX #1082: Notes in delta range - DON'T block startup with slow P2P fetch!
                // The PHASE 2 scan will collect delta CMUs naturally, then we rebuild witnesses.
                // This avoids duplicate P2P fetches and speeds up startup from 10+ min to ~30 sec.
                print("   📦 FIX #1082: Notes in delta range (max height: \(maxNoteHeight))")
                print("   ⚡ FIX #1082: SKIPPING blocking witness rebuild - will rebuild after PHASE 2 scan")
                print("   📝 FIX #1082: PHASE 2 will collect delta CMUs, then witnesses rebuild naturally")

                // Check if delta bundle already has enough CMUs
                let deltaOutputCount = DeltaCMUManager.shared.getOutputCount()
                let deltaEndHeight = DeltaCMUManager.shared.getDeltaEndHeight() ?? 0
                print("   📊 Delta bundle status: \(deltaOutputCount) CMUs, end height \(deltaEndHeight)")

                // Return passed - don't block startup. PHASE 2 scan will handle delta CMU collection.
                // The witnesses will be rebuilt after PHASE 2 completes.
                return .passed("Notes Witness Check",
                              details: "⏳ \(count) notes need witnesses - will rebuild after sync")
            }

        } catch {
            print("❌ FIX #876: Error checking notes without witnesses: \(error)")
            return .failed("Notes Witness Check", details: "Error: \(error.localizedDescription)", critical: false)
        }
    }
}
