import Foundation

/// VUL-018: Shared constants for ZipherX
/// Centralizes hardcoded values to prevent inconsistencies across the codebase
enum ZipherXConstants {

    // MARK: - Commitment Tree (GitHub Boost File)

    /// UserDefaults keys for tree info downloaded from GitHub boost file
    private static let treeHeightKey = "effectiveTreeHeight"
    private static let treeCMUCountKey = "effectiveTreeCMUCount"
    private static let treeRootKey = "effectiveTreeRoot"
    private static let treeBlockHashKey = "effectiveTreeBlockHash"  // FIX #1446c

    /// Get the effective tree height (from downloaded boost file)
    /// Returns 0 if no boost file has been downloaded yet (forces download)
    static var effectiveTreeHeight: UInt64 {
        let downloaded = UserDefaults.standard.integer(forKey: treeHeightKey)
        return downloaded > 0 ? UInt64(downloaded) : 0
    }

    /// Get the effective CMU count (from downloaded boost file)
    /// Returns 0 if no boost file has been downloaded yet
    static var effectiveTreeCMUCount: UInt64 {
        let downloaded = UserDefaults.standard.integer(forKey: treeCMUCountKey)
        return downloaded > 0 ? UInt64(downloaded) : 0
    }

    /// Check if tree data has been downloaded from GitHub boost file
    static var hasDownloadedTree: Bool {
        return effectiveTreeHeight > 0
    }

    /// Get the tree root (from downloaded boost file)
    static var effectiveTreeRoot: String {
        return UserDefaults.standard.string(forKey: treeRootKey) ?? ""
    }

    /// FIX #1446c: Get the block hash at boost file end height (for header sync locator)
    /// Returns hex string in display format (big-endian), or empty if not set
    static var effectiveBlockHash: String {
        return UserDefaults.standard.string(forKey: treeBlockHashKey) ?? ""
    }

    /// Update tree info from downloaded GitHub boost file
    /// Called by CommitmentTreeUpdater after successful download
    /// FIX #1446c: Also stores block_hash for dynamic header sync locator
    static func updateTreeInfo(height: UInt64, cmuCount: UInt64, root: String, blockHash: String = "") {
        UserDefaults.standard.set(Int(height), forKey: treeHeightKey)
        UserDefaults.standard.set(Int(cmuCount), forKey: treeCMUCountKey)
        UserDefaults.standard.set(root, forKey: treeRootKey)
        if !blockHash.isEmpty {
            UserDefaults.standard.set(blockHash, forKey: treeBlockHashKey)
        }
        print("📊 Updated tree info: height=\(height), CMUs=\(cmuCount), root=\(root.prefix(16))...")
    }

    /// Check if tree info has been downloaded from GitHub
    static var hasDownloadedTreeInfo: Bool {
        return UserDefaults.standard.integer(forKey: treeHeightKey) > 0
    }

    /// Clear tree info (for testing or to force re-download)
    /// NOTE: This clears the CACHED tree info, not wallet data
    /// Tree data is blockchain-level and shared across wallets
    static func clearTreeInfo() {
        UserDefaults.standard.removeObject(forKey: treeHeightKey)
        UserDefaults.standard.removeObject(forKey: treeCMUCountKey)
        UserDefaults.standard.removeObject(forKey: treeRootKey)
        UserDefaults.standard.removeObject(forKey: treeBlockHashKey)
        print("📊 Cleared tree info from UserDefaults")
    }

    /// Aliases for backwards compatibility with code using "bundled" naming
    static var bundledTreeHeight: UInt64 { effectiveTreeHeight }
    static var bundledTreeCMUCount: UInt64 { effectiveTreeCMUCount }
    static var bundledTreeRoot: String { effectiveTreeRoot }

    // MARK: - Network

    /// Zclassic Sapling activation height
    static let saplingActivationHeight: UInt64 = 476_969

    /// Zclassic Bubbles activation height (Equihash changes from (200,9) to (192,7))
    static let bubblesActivationHeight: UInt64 = 585_318

    /// Zclassic Buttercup activation height
    static let buttercupActivationHeight: UInt64 = 707_000

    /// Buttercup consensus branch ID
    static let buttercupBranchId: UInt32 = 0x930b540d

    // MARK: - Protocol Limits

    /// Consensus MAX_MONEY in zatoshis — from zclassic/src/amount.h line 30
    /// MAX_MONEY = 21000000 * COIN — used by MoneyRange() for transaction validation
    /// NOTE: Actual achievable supply is ~11.46M ZCL due to Buttercup triple halving (height 707000)
    /// but MAX_MONEY remains 21M as the protocol-level sanity check upper bound
    static let maxMoneyZatoshis: UInt64 = 2_100_000_000_000_000

    // MARK: - Transaction

    /// Default transaction fee in zatoshis (0.0001 ZCL)
    static let defaultFee: UInt64 = 10_000

    /// Minimum output value (dust threshold)
    /// Outputs below this are unspendable due to fees
    static let dustThreshold: UInt64 = 10_000

    /// Maximum memo length in bytes
    static let maxMemoLength = 512

    // MARK: - Security

    // FIX #1493: VULN-009 — Single source of truth for all consensus thresholds.
    // FIX #934 established that Zclassic's small network cannot reliably provide 5+
    // agreeing peers. 3 is the proven operational threshold across all components.
    // FIX #1551: Now configurable via Settings (UserDefaults). Range: 2-8, default: 3.
    // Changes take effect on next app restart (local copies capture at init time).

    /// Consensus threshold for Byzantine fault tolerance on the Zclassic network.
    /// All P2P consensus checks (chain height, headers, blocks, Equihash) MUST use this value.
    /// FIX #1551: User-configurable via Settings → Network → Consensus Threshold
    static var consensusThreshold: Int {
        let stored = UserDefaults.standard.integer(forKey: "ZipherX_ConsensusThreshold")
        // FIX M-015: Minimum 3 for Byzantine fault tolerance (was 2, too low for consensus)
        // Default 3 when not set (UserDefaults returns 0 for unset integer keys)
        return (stored >= 3 && stored <= 8) ? stored : 3
    }

    /// Reduced consensus threshold for degraded network conditions.
    /// Used ONLY as a fallback when full consensusThreshold cannot be met (e.g., header sync).
    /// Security is weakened — operations using this threshold log a warning.
    /// FIX #1551: Dynamically derived as consensusThreshold - 1 (minimum 1)
    static var reducedConsensusThreshold: Int {
        return max(1, consensusThreshold - 1)
    }

    /// Peer ban duration in seconds (7 days)
    static let peerBanDuration: TimeInterval = 604_800

    // MARK: - Disk Space (FIX #1536)

    /// FIX #1536: Minimum disk space in bytes required for operation.
    /// Breakdown: Boost file (~520MB) + Header store (~410MB) + Block caches (~107MB)
    ///          + Sapling params (~50MB) + Tree cache (~33MB) + Wallet DB (~20MB) = ~1.1GB
    /// Adding margin for delta sync, temp files, and growth → 1.5 GB recommended
    static let minimumDiskSpaceBytes: Int64 = 1_500_000_000  // 1.5 GB

    /// Warning threshold — show orange banner when below this
    static let warningDiskSpaceBytes: Int64 = 1_000_000_000  // 1.0 GB

    /// Critical threshold — block sync operations when below this
    static let criticalDiskSpaceBytes: Int64 = 200_000_000   // 200 MB
}
