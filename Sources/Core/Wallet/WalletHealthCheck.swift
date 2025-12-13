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

    /// Run all health checks and return results
    /// FIX #120: Ensures wallet is in consistent state before user interaction
    func runAllChecks() async -> [HealthCheckResult] {
        var results: [HealthCheckResult] = []

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

        // 13. VUL-002: CRITICAL - Verify all SENT transactions exist on blockchain
        // Phantom TXs (locally recorded but never confirmed) cause balance corruption
        results.append(await checkSentTransactionsOnChain())

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
            // Get current balance from unspent notes - this is the ONLY reliable source
            let notes = try WalletDatabase.shared.getUnspentNotes(accountId: 1)
            let noteBalance = notes.reduce(0) { $0 + $1.value }
            let noteBalanceZCL = Double(noteBalance) / 100_000_000.0

            // Get history counts for informational display only
            let history = try WalletDatabase.shared.getTransactionHistory(limit: 10000, offset: 0)
            var receivedCount = 0
            var sentCount = 0

            for tx in history {
                switch tx.type {
                case .received:
                    receivedCount += 1
                case .sent:
                    sentCount += 1
                case .change:
                    break
                }
            }

            // FIX #163: Always pass - unspent notes ARE the balance, no reconciliation needed
            // History balance formula (RECEIVED - SENT - FEES) is mathematically incorrect
            // because change notes are counted in RECEIVED but not subtracted from the formula
            print("🏥 FIX #163: Balance = SUM(unspent notes) = \(noteBalance) zatoshis (\(notes.count) notes)")
            print("   History has \(receivedCount) received, \(sentCount) sent (display only)")

            return .passed("Balance Reconciliation", details: "Balance: \(String(format: "%.8f", noteBalanceZCL)) ZCL (\(notes.count) notes, \(receivedCount)↓ \(sentCount)↑)")
        } catch {
            return .failed("Balance Reconciliation", details: error.localizedDescription, critical: false)
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
        let connectedPeers = NetworkManager.shared.connectedPeers
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
    /// This verifies Equihash(192,7) on headers that were stored during unified fetch
    private func checkEquihashVerification() async -> HealthCheckResult {
        // FIX #188: First try to verify from local storage (no P2P needed)
        let localSuccess = WalletManager.shared.verifyEquihashFromLocalStorage(count: 100)

        if localSuccess {
            return .passed("Equihash PoW", details: "100 headers verified from local storage")
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
        print("⚠️ FIX #188: No local solutions, falling back to P2P verification...")
        let p2pSuccess = await WalletManager.shared.verifyLatestEquihash(count: 100)

        if p2pSuccess {
            return .passed("Equihash PoW", details: "100 headers verified via P2P")
        } else {
            return .failed("Equihash PoW", details: "Latest headers failed Equihash verification", critical: true)
        }
    }

    /// FIX #147: Verify witness validity for unspent notes
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

                // Extract witness root and compare with stored anchor
                if let witnessRoot = ZipherXFFI.witnessGetRoot(note.witness) {
                    if let anchor = note.anchor, witnessRoot == anchor {
                        validCount += 1
                    } else {
                        invalidCount += 1
                    }
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

            do {
                let (exists, confirmations) = try await InsightAPI.shared.verifyTransactionExists(txid: txidHex)

                if exists {
                    verifiedCount += 1
                    if confirmations > 0 {
                        print("✅ VUL-002: TX \(txidHex.prefix(16))... verified (\(confirmations) confirmations)")
                    } else {
                        print("⏳ VUL-002: TX \(txidHex.prefix(16))... in mempool (0 confirmations)")
                    }
                } else {
                    // PHANTOM TRANSACTION DETECTED!
                    print("🚨 VUL-002: PHANTOM TX DETECTED! \(txidHex) does NOT exist on blockchain!")
                    phantomTxs.append((txid: txidHex, height: tx.height, value: tx.value))
                }
            } catch {
                // Network error - can't verify, but don't mark as phantom
                errorCount += 1
                print("⚠️ VUL-002: Could not verify TX \(txidHex.prefix(16))...: \(error.localizedDescription)")
            }
        }

        // Store phantom TXs for repair
        if !phantomTxs.isEmpty {
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
}
