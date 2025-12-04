import Foundation

/// VUL-018: Shared constants for ZipherX
/// Centralizes hardcoded values to prevent inconsistencies across the codebase
enum ZipherXConstants {

    // MARK: - Bundled Commitment Tree

    /// Height at which the bundled commitment tree ends
    /// Update this when regenerating the bundled tree file
    static let bundledTreeHeight: UInt64 = 2926122

    /// Number of CMUs in the bundled tree file
    static let bundledTreeCMUCount: UInt64 = 1_041_891

    /// Expected tree root at bundledTreeHeight (for verification)
    static let bundledTreeRoot = "5cc45e5ed5008b68e0098fdc7ea52cc25caa4400b3bc62c6701bbfc581990945"

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
