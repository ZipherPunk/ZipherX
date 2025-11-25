// Copyright (c) 2025 Zipherpunk.com dev team
// Block header model for header-sync approach

import Foundation

/// Zclassic block header (80 bytes base + extended data)
/// Contains the critical finalsaplingroot field from zcashd
struct BlockHeader {
    // Standard 80-byte header fields
    let version: UInt32
    let hashPrevBlock: Data       // 32 bytes
    let hashMerkleRoot: Data      // 32 bytes
    let hashFinalSaplingRoot: Data // 32 bytes - THE ANCHOR WE NEED!
    let time: UInt32
    let bits: UInt32
    let nonce: Data               // 32 bytes

    // Metadata
    let height: UInt64
    let blockHash: Data           // 32 bytes (computed from header)

    /// The Sapling anchor from zcashd's tree state
    /// This is guaranteed to match zcashd's internal computation
    var anchor: Data {
        return hashFinalSaplingRoot
    }

    /// Parse block header from network bytes
    /// Zcash/Zclassic header format:
    /// - nVersion (4 bytes)
    /// - hashPrevBlock (32 bytes)
    /// - hashMerkleRoot (32 bytes)
    /// - hashFinalSaplingRoot (32 bytes) ← This is the anchor!
    /// - nTime (4 bytes)
    /// - nBits (4 bytes)
    /// - nNonce (32 bytes)
    /// Total: 140 bytes
    static func parse(data: Data, height: UInt64) throws -> BlockHeader {
        guard data.count >= 140 else {
            throw ParseError.insufficientData(expected: 140, got: data.count)
        }

        var offset = 0

        // Read version (4 bytes, little-endian)
        let version = data.withUnsafeBytes { bytes in
            bytes.load(fromByteOffset: offset, as: UInt32.self)
        }
        offset += 4

        // Read previous block hash (32 bytes)
        let hashPrevBlock = data.subdata(in: offset..<offset+32)
        offset += 32

        // Read merkle root (32 bytes)
        let hashMerkleRoot = data.subdata(in: offset..<offset+32)
        offset += 32

        // Read final Sapling root (32 bytes) - THIS IS THE ANCHOR!
        let hashFinalSaplingRoot = data.subdata(in: offset..<offset+32)
        offset += 32

        // Read time (4 bytes, little-endian)
        let time = data.withUnsafeBytes { bytes in
            bytes.load(fromByteOffset: offset, as: UInt32.self)
        }
        offset += 4

        // Read bits (4 bytes, little-endian)
        let bits = data.withUnsafeBytes { bytes in
            bytes.load(fromByteOffset: offset, as: UInt32.self)
        }
        offset += 4

        // Read nonce (32 bytes)
        let nonce = data.subdata(in: offset..<offset+32)
        offset += 32

        // Compute block hash (double SHA256 of first 80 bytes for standard Bitcoin-like headers)
        // Note: Zcash uses Equihash, so this is a simplified version
        // The actual block hash should come from the network
        let headerBytes = data.subdata(in: 0..<80)
        let blockHash = headerBytes.doubleSHA256()

        return BlockHeader(
            version: version,
            hashPrevBlock: hashPrevBlock,
            hashMerkleRoot: hashMerkleRoot,
            hashFinalSaplingRoot: hashFinalSaplingRoot,
            time: time,
            bits: bits,
            nonce: nonce,
            height: height,
            blockHash: blockHash
        )
    }

    /// Serialize header to bytes for storage
    func serialize() -> Data {
        var data = Data()

        withUnsafeBytes(of: version.littleEndian) { data.append(contentsOf: $0) }
        data.append(hashPrevBlock)
        data.append(hashMerkleRoot)
        data.append(hashFinalSaplingRoot)
        withUnsafeBytes(of: time.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: bits.littleEndian) { data.append(contentsOf: $0) }
        data.append(nonce)

        return data
    }
}

enum ParseError: Error {
    case insufficientData(expected: Int, got: Int)

    var localizedDescription: String {
        switch self {
        case .insufficientData(let expected, let got):
            return "Insufficient data for block header: expected \(expected) bytes, got \(got) bytes"
        }
    }
}

// MARK: - Data Extensions

extension Data {
    /// Double SHA256 hash (used for block hashes)
    func doubleSHA256() -> Data {
        let hash1 = self.sha256()
        return hash1.sha256()
    }

    /// Single SHA256 hash
    func sha256() -> Data {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        self.withUnsafeBytes {
            _ = CC_SHA256($0.baseAddress, CC_LONG(self.count), &hash)
        }
        return Data(hash)
    }

    /// Convert to hex string
    func hexString() -> String {
        return map { String(format: "%02x", $0) }.joined()
    }
}

// Import CommonCrypto for SHA256
import CommonCrypto
