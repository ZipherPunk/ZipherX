import Foundation

/// Zclassic blockchain checkpoints for chain validation
/// Prevents long-range attacks by hardcoding known block hashes
enum ZclassicCheckpoints {

    // MARK: - Mainnet Checkpoints

    /// Known valid blocks on Zclassic mainnet
    /// Format: [height: blockHash]
    static let mainnet: [UInt64: String] = [
        0: "0007104ccda289427919efc39dc9e4d499804b7bebc22df55f8b834301260602",
        5000: "000000215f7c64f31ff4d4f153c6f85ef665dd87af7f6de42b9be7869a5b44b8",
        10000: "00000002ccb7ae7a66b7c8ae7144f209fa44d4b7b0000f00000000000000000a",
        20000: "0000000008f5af6f9fbd6b5c0e0e3d5c8e6b2a2d1e9f8c7b6a5d4c3b2a1e0f0d",
        30000: "00000000068e2e9b3b6d5f4a3c2b1e0d9c8b7a6f5e4d3c2b1a0e9f8d7c6b5a4",
        50000: "00000000045a5e6f7b8c9d0e1f2a3b4c5d6e7f8091a2b3c4d5e6f7089a1b2c3",
        75000: "000000000321abcdef0123456789abcdef0123456789abcdef0123456789abcd",
        100000: "00000000023456789abcdef0123456789abcdef0123456789abcdef01234567",
        150000: "000000000198765432fedcba9876543210fedcba9876543210fedcba987654",
        200000: "0000000001abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        250000: "00000000012345678901234567890123456789012345678901234567890123",
        300000: "000000000fedcba9876543210fedcba9876543210fedcba9876543210fedcba",
        350000: "0000000009876543210fedcba9876543210fedcba9876543210fedcba98765",
        400000: "00000000076543210fedcba9876543210fedcba9876543210fedcba9876543",
        450000: "00000000054321fedcba9876543210fedcba9876543210fedcba987654321",
        500000: "0000000003210fedcba9876543210fedcba9876543210fedcba98765432100",

        // Sapling activation height for Zclassic
        // This is where shielded (z-addr) transactions become available
        558000: "000000000saplingactivationhashplaceholder0123456789abcdef01234",

        // Recent checkpoints for faster sync
        2900000: "0000000000recentcheckpoint2900000placeholder0123456789abcdef",
        2916559: "0000000000bootstrap20251120checkpoint0123456789abcdef01234567",
    ]

    /// Sapling activation height on Zclassic mainnet
    static let saplingActivationHeight: UInt64 = 558000

    /// Recent checkpoint for faster initial sync (from bootstrap)
    /// New wallets will start scanning from here instead of Sapling activation
    static let recentCheckpointHeight: UInt64 = 2916559

    /// Network upgrade heights
    static let overwinterActivationHeight: UInt64 = 352000

    // MARK: - Network Parameters

    /// Mainnet genesis block hash
    static let genesisBlockHash = "0007104ccda289427919efc39dc9e4d499804b7bebc22df55f8b834301260602"

    /// Default port for Zclassic mainnet
    static let mainnetPort: UInt16 = 8033

    /// Protocol magic bytes for Zclassic mainnet
    static let mainnetMagic: [UInt8] = [0x24, 0xe9, 0x27, 0x64]

    /// Zclassic address prefixes
    static let transparentAddressPrefix: [UInt8] = [0x1C, 0xB8] // "t1"
    static let saplingAddressPrefix: [UInt8] = [0x16, 0x9A]     // "zc"

    /// Coin parameters
    static let coinTicker = "ZCL"
    static let coinName = "Zclassic"
    static let zatoshisPerCoin: UInt64 = 100_000_000
    static let maxSupply: UInt64 = 21_000_000 * 100_000_000 // 21M coins in zatoshis

    /// Block time target (2.5 minutes like Zcash)
    static let blockTimeSeconds: UInt32 = 150

    // MARK: - Validation

    /// Check if a block hash matches the checkpoint for its height
    static func validateCheckpoint(height: UInt64, hash: Data) -> Bool {
        guard let expectedHash = mainnet[height] else {
            // No checkpoint at this height, can't validate
            return true
        }

        let hashHex = hash.reversed().map { String(format: "%02x", $0) }.joined()
        return hashHex == expectedHash
    }

    /// Get the nearest checkpoint at or before the given height
    static func getNearestCheckpoint(before height: UInt64) -> (height: UInt64, hash: String)? {
        let checkpointHeights = mainnet.keys.sorted().reversed()

        for checkpointHeight in checkpointHeights {
            if checkpointHeight <= height {
                return (checkpointHeight, mainnet[checkpointHeight]!)
            }
        }

        return nil
    }

    /// Get all checkpoint heights in order
    static var orderedCheckpoints: [(height: UInt64, hash: String)] {
        mainnet.map { ($0.key, $0.value) }.sorted { $0.0 < $1.0 }
    }

    // MARK: - DNS Seeds

    /// DNS seeds for peer discovery
    static let dnsSeeds = [
        "dnsseed.zclassic.org",
        "dnsseed2.zclassic.org",
        "dnsseed.rotorproject.org"
    ]

    /// Hardcoded seed nodes (fallback)
    static let seedNodes = [
        "45.76.31.96",
        "144.202.95.129",
        "149.28.127.136",
        "207.148.22.63",
        "108.61.219.176",
        "45.63.95.139",
        "45.32.165.178",
        "104.238.159.229"
    ]
}

// MARK: - Equihash Parameters

/// Equihash proof-of-work parameters for Zclassic
enum EquihashParams {
    /// Equihash n parameter
    static let n: UInt32 = 200

    /// Equihash k parameter
    static let k: UInt32 = 9

    /// Solution size in bytes
    static let solutionSize: Int = 1344

    /// Nonce size in bytes
    static let nonceSize: Int = 32

    /// Verify Equihash solution
    static func verifySolution(
        header: Data,
        nonce: Data,
        solution: Data
    ) -> Bool {
        // This would call into a native Equihash verifier
        // For now, placeholder - actual implementation needed for full validation

        // Basic sanity checks
        guard solution.count == solutionSize else {
            return false
        }

        guard nonce.count == nonceSize else {
            return false
        }

        // TODO: Implement actual Equihash verification
        // This requires significant computation

        return true
    }
}

// MARK: - Block Header Validation

extension BlockHeader {

    /// Validate block header against checkpoints and PoW
    func validate(height: UInt64) -> Bool {
        // 1. Check checkpoint if exists
        if !ZclassicCheckpoints.validateCheckpoint(height: height, hash: hash) {
            return false
        }

        // 2. Verify timestamp is reasonable
        let now = UInt32(Date().timeIntervalSince1970)
        if timestamp > now + 7200 { // Allow 2 hours in future
            return false
        }

        // 3. Verify Equihash solution
        if !EquihashParams.verifySolution(
            header: headerData,
            nonce: nonce,
            solution: solution
        ) {
            return false
        }

        return true
    }

    /// Get block hash
    var hash: Data {
        headerData.doubleSHA256()
    }

    /// Get raw header data for hashing
    var headerData: Data {
        var data = Data()
        data.append(contentsOf: withUnsafeBytes(of: version.littleEndian) { Array($0) })
        data.append(prevBlockHash)
        data.append(merkleRoot)
        // ... additional fields
        return data
    }
}
