// Copyright (c) 2025 Zipherpunk.com dev team
// Block header model for header-sync approach

import Foundation

/// Zclassic block header (140 bytes + Equihash solution)
/// Contains the critical finalsaplingroot field from zcashd
struct ZclassicBlockHeader {
    // Standard 140-byte header fields (Zcash format)
    let version: UInt32
    let hashPrevBlock: Data       // 32 bytes
    let hashMerkleRoot: Data      // 32 bytes
    let hashFinalSaplingRoot: Data // 32 bytes - THE ANCHOR WE NEED!
    let time: UInt32
    let bits: UInt32
    let nonce: Data               // 32 bytes

    // Equihash solution (typically 1344 bytes for Equihash(200,9))
    let solution: Data

    // Metadata
    let height: UInt64
    let blockHash: Data           // 32 bytes (computed from header + solution)

    // FIX #535: Chainwork for fork detection (accumulated proof-of-work)
    // This allows us to detect when P2P peers are on a wrong fork (lower chainwork)
    let chainwork: Data           // 32 bytes - accumulated work from genesis to this block

    /// The Sapling anchor from zcashd's tree state
    /// This is guaranteed to match zcashd's internal computation
    var anchor: Data {
        return hashFinalSaplingRoot
    }

    /// The raw 140-byte header without solution
    var headerBytes: Data {
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

    /// Parse block header from network bytes (140-byte header only, no solution)
    /// Use parseWithSolution for full header with Equihash verification
    /// Zcash/Zclassic header format:
    /// - nVersion (4 bytes)
    /// - hashPrevBlock (32 bytes)
    /// - hashMerkleRoot (32 bytes)
    /// - hashFinalSaplingRoot (32 bytes) ← This is the anchor!
    /// - nTime (4 bytes)
    /// - nBits (4 bytes)
    /// - nNonce (32 bytes)
    /// Total: 140 bytes
    static func parse(data: Data, height: UInt64) throws -> ZclassicBlockHeader {
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
        // DEBUG: Check if saplingRoot is all zeros
        if hashFinalSaplingRoot.allSatisfy({ $0 == 0 }) {
            print("🚨 DEBUG: saplingRoot is all zeros at height \(height) in parseWithSolution!")
            print("   data.count=\(data.count), offset=\(offset)")
            print("   First 100 bytes: \(data.prefix(min(100, data.count)).map { String(format: "%02x", $0) }.joined())")
        }
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

        // Without solution, we can't compute the real block hash
        // Use a placeholder or zero hash
        let blockHash = Data(count: 32)
        // FIX #535: Chainwork will be computed later by HeaderStore
        let chainwork = Data(count: 32)

        return ZclassicBlockHeader(
            version: version,
            hashPrevBlock: hashPrevBlock,
            hashMerkleRoot: hashMerkleRoot,
            hashFinalSaplingRoot: hashFinalSaplingRoot,
            time: time,
            bits: bits,
            nonce: nonce,
            solution: Data(),
            height: height,
            blockHash: blockHash,
            chainwork: chainwork
        )
    }

    /// Parse block header WITH Equihash solution and verify PoW
    /// Format: header (140 bytes) + solution_len (varint) + solution
    /// Returns nil if Equihash verification fails
    static func parseWithSolution(data: Data, height: UInt64, verifyEquihash: Bool = true) throws -> ZclassicBlockHeader {
        guard data.count >= 141 else {
            throw ParseError.insufficientData(expected: 141, got: data.count)
        }

        var offset = 0

        // Parse header fields (140 bytes)
        let version = data.withUnsafeBytes { bytes in
            bytes.load(fromByteOffset: offset, as: UInt32.self)
        }
        offset += 4

        let hashPrevBlock = data.subdata(in: offset..<offset+32)
        offset += 32

        let hashMerkleRoot = data.subdata(in: offset..<offset+32)
        offset += 32

        let hashFinalSaplingRoot = data.subdata(in: offset..<offset+32)
        offset += 32

        let time = data.withUnsafeBytes { bytes in
            bytes.load(fromByteOffset: offset, as: UInt32.self)
        }
        offset += 4

        let bits = data.withUnsafeBytes { bytes in
            bytes.load(fromByteOffset: offset, as: UInt32.self)
        }
        offset += 4

        let nonce = data.subdata(in: offset..<offset+32)
        offset += 32

        // Parse solution length (varint)
        guard offset < data.count else {
            throw ParseError.insufficientData(expected: offset + 1, got: data.count)
        }

        let firstByte = data[offset]
        let solutionLen: Int
        let varintSize: Int

        if firstByte < 253 {
            solutionLen = Int(firstByte)
            varintSize = 1
        } else if firstByte == 253 {
            guard offset + 3 <= data.count else {
                throw ParseError.insufficientData(expected: offset + 3, got: data.count)
            }
            solutionLen = Int(data[offset + 1]) | (Int(data[offset + 2]) << 8)
            varintSize = 3
        } else {
            throw ParseError.invalidSolutionLength
        }
        offset += varintSize

        // Parse solution
        guard offset + solutionLen <= data.count else {
            throw ParseError.insufficientData(expected: offset + solutionLen, got: data.count)
        }
        let solution = data.subdata(in: offset..<offset+solutionLen)

        // Extract 140-byte header for Equihash verification
        let headerOnly = data.subdata(in: 0..<140)

        // Verify Equihash if requested
        if verifyEquihash {
            guard ZipherXFFI.verifyEquihash(header: headerOnly, solution: solution) else {
                throw ParseError.equihashVerificationFailed(height: height)
            }
        }

        // Compute block hash using FFI
        guard let blockHash = ZipherXFFI.computeBlockHash(header: headerOnly, solution: solution) else {
            throw ParseError.hashComputationFailed
        }

        // FIX #535: Chainwork will be computed later by HeaderStore
        let chainwork = Data(count: 32)

        return ZclassicBlockHeader(
            version: version,
            hashPrevBlock: hashPrevBlock,
            hashMerkleRoot: hashMerkleRoot,
            hashFinalSaplingRoot: hashFinalSaplingRoot,
            time: time,
            bits: bits,
            nonce: nonce,
            solution: solution,
            height: height,
            blockHash: blockHash,
            chainwork: chainwork
        )
    }

    /// Serialize header to bytes for storage (without solution)
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

    /// Serialize header with solution for full verification
    func serializeWithSolution() -> Data {
        var data = serialize()

        // Add solution length as varint
        if solution.count < 253 {
            data.append(UInt8(solution.count))
        } else {
            data.append(253)
            data.append(UInt8(solution.count & 0xff))
            data.append(UInt8((solution.count >> 8) & 0xff))
        }

        data.append(solution)

        return data
    }
}

enum ParseError: Error, LocalizedError {
    case insufficientData(expected: Int, got: Int)
    case invalidSolutionLength
    case equihashVerificationFailed(height: UInt64)
    case hashComputationFailed

    var errorDescription: String? {
        switch self {
        case .insufficientData(let expected, let got):
            return "Insufficient data for block header: expected \(expected) bytes, got \(got) bytes"
        case .invalidSolutionLength:
            return "Invalid Equihash solution length encoding"
        case .equihashVerificationFailed(let height):
            return "Equihash proof-of-work verification failed at height \(height)"
        case .hashComputationFailed:
            return "Failed to compute block hash"
        }
    }
}

// Note: Data extensions (doubleSHA256, sha256, hexString) are defined in Peer.swift
