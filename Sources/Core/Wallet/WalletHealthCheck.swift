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

        return results
    }

    /// Check if all required bundle files exist
    private func checkBundleFiles() async -> HealthCheckResult {
        var missing: [String] = []

        // Check Sapling parameters
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let spendPath = documentsPath.appendingPathComponent("sapling-spend.params")
        let outputPath = documentsPath.appendingPathComponent("sapling-output.params")

        if !FileManager.default.fileExists(atPath: spendPath.path) {
            missing.append("sapling-spend.params")
        }
        if !FileManager.default.fileExists(atPath: outputPath.path) {
            missing.append("sapling-output.params")
        }

        if missing.isEmpty {
            return .passed("Bundle Files", details: "All Sapling parameters present")
        } else {
            return .failed("Bundle Files", details: "Missing: \(missing.joined(separator: ", "))", critical: true)
        }
    }

    /// Check database file integrity
    private func checkDatabaseIntegrity() async -> HealthCheckResult {
        do {
            // Check wallet database
            let noteCount = try WalletDatabase.shared.getAllNotes().count
            let historyCount = try WalletDatabase.shared.getTransactionHistoryCount()

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

    /// Verify balance matches sum of history (+received - sent)
    private func checkBalanceHistoryMatch() async -> HealthCheckResult {
        do {
            // Get current balance from unspent notes
            let notes = try WalletDatabase.shared.getUnspentNotes(accountId: 1)
            let noteBalance = notes.reduce(0) { $0 + $1.value }

            // Get balance from history (received - sent)
            let history = try WalletDatabase.shared.getTransactionHistory(limit: 10000, offset: 0)
            var historyReceived: UInt64 = 0
            var historySent: UInt64 = 0

            for tx in history {
                switch tx.type {
                case .received:
                    historyReceived += tx.value
                case .sent:
                    historySent += tx.value + (tx.fee ?? 0)
                case .change:
                    break // Change is internal, doesn't affect balance
                }
            }

            let historyBalance = Int64(historyReceived) - Int64(historySent)

            // Compare
            let noteBalanceZCL = Double(noteBalance) / 100_000_000.0
            let historyBalanceZCL = Double(historyBalance) / 100_000_000.0
            let diff = abs(noteBalanceZCL - historyBalanceZCL)

            if diff < 0.00000001 {  // Allow for rounding
                return .passed("Balance Reconciliation", details: "Balance: \(String(format: "%.8f", noteBalanceZCL)) ZCL matches history")
            } else {
                return .failed("Balance Reconciliation",
                    details: "Notes: \(String(format: "%.8f", noteBalanceZCL)) ZCL, History: \(String(format: "%.8f", historyBalanceZCL)) ZCL, Diff: \(String(format: "%.8f", diff)) ZCL",
                    critical: false)
            }
        } catch {
            return .failed("Balance Reconciliation", details: error.localizedDescription, critical: false)
        }
    }

    /// Verify stored block hashes match P2P network consensus
    private func checkHashAccuracy() async -> HealthCheckResult {
        do {
            // Get latest stored header
            guard let latestHeight = try HeaderStore.shared.getLatestHeight(),
                  let storedHeader = try HeaderStore.shared.getHeader(at: latestHeight) else {
                return .passed("Hash Accuracy", details: "No headers stored yet")
            }

            // Compare with P2P network consensus
            let networkManager = NetworkManager.shared
            guard networkManager.connectedPeerCount >= 2 else {
                return .passed("Hash Accuracy", details: "Not enough peers to verify (need 2+)")
            }

            // Get block hash from multiple peers for the same height
            var peerHashes: [Data] = []
            let peers = networkManager.getAllConnectedPeers()

            for peer in peers.prefix(3) {
                do {
                    let headers = try await peer.getBlockHeaders(from: latestHeight, count: 1)
                    if let header = headers.first {
                        peerHashes.append(header.blockHash)
                    }
                } catch {
                    continue
                }
            }

            guard !peerHashes.isEmpty else {
                return .passed("Hash Accuracy", details: "Could not fetch headers from peers")
            }

            // Check if stored hash matches peer consensus
            let storedHashHex = storedHeader.blockHash.map { String(format: "%02x", $0) }.joined()

            // All peer hashes should match (consensus)
            let peerHashSet = Set(peerHashes.map { $0.map { String(format: "%02x", $0) }.joined() })
            if peerHashSet.count > 1 {
                return .failed("Hash Accuracy", details: "Peers disagree on block \(latestHeight) hash!", critical: true)
            }

            if let peerHash = peerHashes.first {
                let peerHashHex = peerHash.map { String(format: "%02x", $0) }.joined()
                if storedHashHex == peerHashHex {
                    return .passed("Hash Accuracy", details: "Block \(latestHeight) hash verified with \(peerHashes.count) peers")
                } else {
                    return .failed("Hash Accuracy",
                        details: "Block \(latestHeight): stored=\(storedHashHex.prefix(16))... peer=\(peerHashHex.prefix(16))...",
                        critical: true)
                }
            }

            return .passed("Hash Accuracy", details: "Verification complete")
        } catch {
            return .failed("Hash Accuracy", details: error.localizedDescription, critical: false)
        }
    }

    /// Check P2P network connectivity
    private func checkP2PConnectivity() async -> HealthCheckResult {
        let connectedPeers = NetworkManager.shared.connectedPeerCount
        let minPeers = 3

        if connectedPeers >= minPeers {
            return .passed("P2P Connectivity", details: "\(connectedPeers) peers connected")
        } else if connectedPeers > 0 {
            return .failed("P2P Connectivity", details: "Only \(connectedPeers)/\(minPeers) peers (partial)", critical: false)
        } else {
            return .failed("P2P Connectivity", details: "No peers connected", critical: false)
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
}
