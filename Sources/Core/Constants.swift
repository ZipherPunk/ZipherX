import Foundation

/// VUL-018: Shared constants for ZipherX
/// Centralizes hardcoded values to prevent inconsistencies across the codebase
enum ZipherXConstants {

    // MARK: - Commitment Tree (Dynamic from GitHub)

    /// UserDefaults keys for tree info downloaded from GitHub
    private static let treeHeightKey = "effectiveTreeHeight"
    private static let treeCMUCountKey = "effectiveTreeCMUCount"
    private static let treeRootKey = "effectiveTreeRoot"

    /// Fallback values ONLY used if GitHub manifest hasn't been downloaded yet
    /// These should match the MINIMUM supported tree (Sapling activation)
    private static let fallbackTreeHeight: UInt64 = 476_969  // Sapling activation
    private static let fallbackTreeCMUCount: UInt64 = 0
    private static let fallbackTreeRoot = ""

    /// Get the tree height (from GitHub manifest stored in UserDefaults)
    /// Returns Sapling activation height if not yet downloaded
    static var bundledTreeHeight: UInt64 {
        let downloaded = UserDefaults.standard.integer(forKey: treeHeightKey)
        return downloaded > 0 ? UInt64(downloaded) : fallbackTreeHeight
    }

    /// Get the CMU count (from GitHub manifest stored in UserDefaults)
    static var bundledTreeCMUCount: UInt64 {
        let downloaded = UserDefaults.standard.integer(forKey: treeCMUCountKey)
        return downloaded > 0 ? UInt64(downloaded) : fallbackTreeCMUCount
    }

    /// Get the tree root (from GitHub manifest stored in UserDefaults)
    static var bundledTreeRoot: String {
        return UserDefaults.standard.string(forKey: treeRootKey) ?? fallbackTreeRoot
    }

    /// Update tree info from downloaded GitHub manifest
    /// Called by CommitmentTreeUpdater after successful download
    static func updateTreeInfo(height: UInt64, cmuCount: UInt64, root: String) {
        UserDefaults.standard.set(Int(height), forKey: treeHeightKey)
        UserDefaults.standard.set(Int(cmuCount), forKey: treeCMUCountKey)
        UserDefaults.standard.set(root, forKey: treeRootKey)
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
        print("📊 Cleared tree info from UserDefaults")
    }

    /// Alias for backwards compatibility
    static var effectiveTreeHeight: UInt64 { bundledTreeHeight }
    static var effectiveTreeCMUCount: UInt64 { bundledTreeCMUCount }

    // MARK: - Network

    /// Zclassic Sapling activation height
    static let saplingActivationHeight: UInt64 = 476_969

    /// Zclassic Buttercup activation height
    static let buttercupActivationHeight: UInt64 = 707_000

    /// Buttercup consensus branch ID
    static let buttercupBranchId: UInt32 = 0x930b540d

    // MARK: - Transaction

    /// Default transaction fee in zatoshis (0.0001 ZCL)
    static let defaultFee: UInt64 = 10_000

    /// Minimum output value (dust threshold)
    /// Outputs below this are unspendable due to fees
    static let dustThreshold: UInt64 = 10_000

    /// Maximum memo length in bytes
    static let maxMemoLength = 512

    // MARK: - Security

    /// Minimum peers required for consensus operations
    static let minConsensusPeers = 3

    /// Threshold for Byzantine fault tolerance (n=8, f=2)
    static let consensusThreshold = 5

    /// Peer ban duration in seconds (7 days)
    static let peerBanDuration: TimeInterval = 604_800
}
