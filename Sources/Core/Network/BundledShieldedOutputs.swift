//
//  BundledShieldedOutputs.swift
//  ZipherX
//
//  Created by Claude on 2025-12-05.
//  Pre-bundled shielded outputs for fast parallel note discovery
//  Extracted from unified boost file (zipherx_boost_v1.bin)
//

import Foundation
import CryptoKit

/// Represents a single shielded output from the boost file
struct ShieldedOutputData {
    let height: UInt32
    let cmu: Data        // 32 bytes
    let epk: Data        // 32 bytes
    let encCiphertext: Data  // 580 bytes
}

/// Loader for shielded outputs from unified boost file
/// Boost file outputs section format (652 bytes per record):
///   - height: UInt32 (4 bytes)
///   - epk: [UInt8; 32]
///   - cmu: [UInt8; 32]
///   - ciphertext: [UInt8; 580]
///   - nullifier_prefix: UInt32 (4 bytes) - unused, for future filtering
final class BundledShieldedOutputs {

    static let shared = BundledShieldedOutputs()

    // Boost file output record format (652 bytes each)
    private static let OUTPUT_SIZE = 652

    // Cached outputs data (extracted from boost file)
    private var outputsData: Data?
    private var outputCount: UInt64 = 0
    private var startHeight: UInt64 = 0
    private var endHeight: UInt64 = 0

    // Height index for binary search (built on first use)
    private var heightIndex: [(height: UInt32, offset: Int)]?

    // Loading state
    private var isLoading = false

    private init() {}

    /// Check if bundled outputs are available (in memory)
    var isAvailable: Bool {
        return outputsData != nil && outputCount > 0
    }

    /// Check if bundled outputs are available (from boost file) - async version
    func checkBoostFileAvailable() async -> Bool {
        if outputsData != nil && outputCount > 0 {
            return true
        }
        // Check if boost file is cached
        return await CommitmentTreeUpdater.shared.hasCachedBoostFile()
    }

    /// Get the height range covered by bundled outputs
    var heightRange: ClosedRange<UInt64>? {
        guard outputsData != nil else { return nil }
        return startHeight...endHeight
    }

    /// Get total number of bundled outputs
    var count: UInt64 {
        return outputCount
    }

    /// Get the end height covered by bundled outputs
    var bundledEndHeight: UInt64 {
        return endHeight
    }

    // MARK: - Loading from Boost File

    /// Load shielded outputs from boost file
    /// Returns: (success, outputCount, endHeight)
    func loadFromBoostFile(onProgress: @escaping (Double, String) -> Void) async -> (Bool, UInt64, UInt64) {
        guard !isLoading else {
            print("⚠️ BundledShieldedOutputs: Load already in progress")
            return (false, 0, 0)
        }

        isLoading = true
        defer { isLoading = false }

        onProgress(0.0, "Loading shielded outputs...")

        // 1) Try to extract from boost file
        if await CommitmentTreeUpdater.shared.hasCachedBoostFile(),
           let sectionInfo = await CommitmentTreeUpdater.shared.getSectionInfo(type: .outputs) {
            do {
                onProgress(0.2, "Extracting outputs from boost file...")
                let data = try await CommitmentTreeUpdater.shared.extractShieldedOutputs()
                try loadFromBoostSection(data, startHeight: sectionInfo.start_height, count: sectionInfo.count)
                onProgress(1.0, "Ready: \(outputCount) outputs to height \(endHeight)")
                print("✅ BundledShieldedOutputs: Loaded \(outputCount) outputs from boost file")
                return (true, outputCount, endHeight)
            } catch {
                print("⚠️ BundledShieldedOutputs: Failed to extract from boost: \(error)")
            }
        }

        // 2) Download boost file if not available
        print("📥 BundledShieldedOutputs: No boost file available, downloading...")
        onProgress(0.1, "Downloading boost file...")

        do {
            _ = try await CommitmentTreeUpdater.shared.getBestAvailableBoostFile { progress, status in
                onProgress(0.1 + progress * 0.7, status)
            }

            if let sectionInfo = await CommitmentTreeUpdater.shared.getSectionInfo(type: .outputs) {
                let data = try await CommitmentTreeUpdater.shared.extractShieldedOutputs()
                try loadFromBoostSection(data, startHeight: sectionInfo.start_height, count: sectionInfo.count)
                onProgress(1.0, "Ready: \(outputCount) outputs to height \(endHeight)")
                print("✅ BundledShieldedOutputs: Downloaded and loaded \(outputCount) outputs")
                return (true, outputCount, endHeight)
            }
        } catch {
            print("❌ BundledShieldedOutputs: Failed to download boost file: \(error)")
        }

        return (false, 0, 0)
    }

    /// Load outputs from boost file section (652 bytes per record)
    private func loadFromBoostSection(_ data: Data, startHeight: UInt64, count: UInt64) throws {
        // Validate data size (652 bytes per output)
        let expectedSize = Int(count) * Self.OUTPUT_SIZE
        guard data.count >= expectedSize else {
            throw NSError(domain: "BundledShieldedOutputs", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid boost section size"])
        }

        // Clear previous index
        heightIndex = nil

        // Store data and metadata
        self.outputsData = data
        self.outputCount = count
        self.startHeight = startHeight

        // Determine end height from last record
        if count > 0 {
            let lastOffset = Int(count - 1) * Self.OUTPUT_SIZE
            self.endHeight = UInt64(readUInt32(from: data, at: lastOffset))
        } else {
            self.endHeight = startHeight
        }

        print("⏰ BundledShieldedOutputs: Loaded \(count) outputs (heights \(startHeight) to \(endHeight))")
    }

    /// Clear loaded data
    func clear() {
        outputsData = nil
        heightIndex = nil
        outputCount = 0
        startHeight = 0
        endHeight = 0
    }

    // MARK: - Safe Byte Reading (avoids alignment crashes with memory-mapped files)

    private func readUInt32(from data: Data, at offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        return data.withUnsafeBytes { ptr in
            let bytes = ptr.baseAddress!.advanced(by: offset).assumingMemoryBound(to: UInt8.self)
            return UInt32(bytes[0]) |
                   (UInt32(bytes[1]) << 8) |
                   (UInt32(bytes[2]) << 16) |
                   (UInt32(bytes[3]) << 24)
        }
    }

    // MARK: - Output Access

    /// Build height index for binary search (lazy initialization)
    private func buildHeightIndex() {
        guard heightIndex == nil, let data = outputsData else { return }

        var index: [(height: UInt32, offset: Int)] = []
        var lastHeight: UInt32 = 0

        for i in 0..<Int(outputCount) {
            let offset = i * Self.OUTPUT_SIZE
            let height = readUInt32(from: data, at: offset)

            // Record first occurrence of each height
            if height != lastHeight {
                index.append((height: height, offset: offset))
                lastHeight = height
            }
        }

        heightIndex = index
        print("📊 BundledShieldedOutputs: Built height index with \(index.count) unique heights")
    }

    /// Get all shielded outputs in a height range
    /// Uses binary search for efficient range lookup
    func getOutputsInRange(from: UInt64, to: UInt64) -> [ShieldedOutputData] {
        guard let data = outputsData else {
            print("⚠️ getOutputsInRange: outputsData is nil")
            return []
        }

        // Build index if needed
        if heightIndex == nil {
            buildHeightIndex()
        }

        guard let index = heightIndex, !index.isEmpty else {
            print("⚠️ getOutputsInRange: heightIndex is nil or empty")
            return []
        }

        // Binary search for start position
        var lo = 0
        var hi = index.count

        while lo < hi {
            let mid = (lo + hi) / 2
            if index[mid].height < UInt32(from) {
                lo = mid + 1
            } else {
                hi = mid
            }
        }

        // Handle edge case: start height not found (request is for heights beyond bundled range)
        if lo >= index.count {
            // This is NORMAL when scanning heights beyond bundled data
            return []
        }

        // Check if first matching index is actually in our range
        // (binary search finds first >= from, but that might be > to)
        if index[lo].height > UInt32(to) {
            // Range has no outputs (sparse area of chain)
            return []
        }

        // Collect outputs in range
        var outputs: [ShieldedOutputData] = []
        var offset = index[lo].offset

        let dataCount = data.count
        while offset + Self.OUTPUT_SIZE <= dataCount {
            let output = parseOutput(at: offset, in: data)

            if output.height > UInt32(to) {
                break
            }

            if output.height >= UInt32(from) {
                outputs.append(output)
            }

            offset += Self.OUTPUT_SIZE
        }

        return outputs
    }

    /// Parse a single output at the given offset
    /// Boost file format (652 bytes):
    ///   - height: UInt32 (4 bytes)
    ///   - epk: [UInt8; 32]
    ///   - cmu: [UInt8; 32]
    ///   - ciphertext: [UInt8; 580]
    ///   - nullifier_prefix: UInt32 (4 bytes) - unused
    private func parseOutput(at offset: Int, in data: Data) -> ShieldedOutputData {
        let height = readUInt32(from: data, at: offset)

        // Boost format: height(4) + epk(32) + cmu(32) + ciphertext(580) + nullifier_prefix(4)
        let epk = data.subdata(in: (offset + 4)..<(offset + 36))
        let cmu = data.subdata(in: (offset + 36)..<(offset + 68))
        let encCiphertext = data.subdata(in: (offset + 68)..<(offset + 648))

        return ShieldedOutputData(
            height: height,
            cmu: cmu,
            epk: epk,
            encCiphertext: encCiphertext
        )
    }

    /// Get outputs for parallel decryption (returns FFI-compatible format)
    /// Also returns metadata for each output to correlate decryption results
    func getOutputsForParallelDecryption(from: UInt64, to: UInt64) -> [(output: ZipherXFFI.FFIShieldedOutput, height: UInt32, cmu: Data)] {
        let outputs = getOutputsInRange(from: from, to: to)

        return outputs.map { output in
            let ffiOutput = ZipherXFFI.FFIShieldedOutput(
                epk: output.epk,
                cmu: output.cmu,
                ciphertext: output.encCiphertext
            )
            return (output: ffiOutput, height: output.height, cmu: output.cmu)
        }
    }

    /// Get CMU data for tree building (in blockchain order)
    func getCMUsInRange(from: UInt64, to: UInt64) -> [Data] {
        let outputs = getOutputsInRange(from: from, to: to)
        return outputs.map { $0.cmu }
    }

    // MARK: - Utility Functions

    /// Get available disk space in bytes
    static func getAvailableDiskSpace() -> Int64 {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        do {
            let values = try documentsURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            if let capacity = values.volumeAvailableCapacityForImportantUsage {
                return capacity
            }
        } catch {
            print("⚠️ Could not get disk space: \(error)")
        }
        return 0
    }
}
