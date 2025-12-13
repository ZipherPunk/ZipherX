//
//  DeltaCMUManager.swift
//  ZipherX
//
//  Created by Claude on 2025-12-10.
//  Local delta shielded outputs bundle for instant witness generation
//
//  FORMAT: Identical to GitHub boost file outputs section (652 bytes per record)
//    - height: UInt32 (4 bytes, little-endian)
//    - index: UInt32 (4 bytes, little-endian)
//    - cmu: [UInt8; 32] (wire format, little-endian)
//    - epk: [UInt8; 32] (wire format, little-endian)
//    - ciphertext: [UInt8; 580]
//

import Foundation

/// Manages a local delta shielded outputs bundle that accumulates outputs after the GitHub bundle height.
/// This enables instant witness generation and parallel note decryption without P2P network fetches.
///
/// **File format (same as GitHub boost file outputs section):**
/// - Each record: 652 bytes
///   - height: UInt32 LE (4 bytes)
///   - index: UInt32 LE (4 bytes) - index of output within block
///   - cmu: 32 bytes (wire format / little-endian)
///   - epk: 32 bytes (wire format / little-endian)
///   - ciphertext: 580 bytes
///
/// **Manifest format (JSON):**
/// - start_height: First block height in delta
/// - end_height: Last block height in delta
/// - output_count: Total outputs in delta bundle
/// - cmu_count: Total CMUs (same as output_count)
/// - tree_root: Merkle tree root after all CMUs (anchor)
/// - updated_at: ISO8601 timestamp
///
class DeltaCMUManager {

    static let shared = DeltaCMUManager()

    // MARK: - Constants

    private let deltaFileName = "shielded_outputs_delta.bin"
    private let manifestFileName = "delta_manifest.json"

    /// Output record size - MUST match GitHub boost file format exactly
    /// height(4) + index(4) + cmu(32) + epk(32) + ciphertext(580) = 652 bytes
    static let OUTPUT_SIZE = 652

    // MARK: - Properties

    private var deltaFileURL: URL {
        // Use centralized app data directory (Application Support on macOS, Documents on iOS)
        return AppDirectories.appData.appendingPathComponent(deltaFileName)
    }

    private var manifestFileURL: URL {
        // Use centralized app data directory (Application Support on macOS, Documents on iOS)
        return AppDirectories.appData.appendingPathComponent(manifestFileName)
    }

    // Thread safety
    private let queue = DispatchQueue(label: "com.zipherx.deltacmu", qos: .userInitiated)

    // In-memory cache
    private var cachedOutputCount: UInt64 = 0
    private var cachedEndHeight: UInt64 = 0

    // MARK: - Manifest Structure

    struct DeltaManifest: Codable {
        var startHeight: UInt64
        var endHeight: UInt64
        var outputCount: UInt64
        var cmuCount: UInt64  // Same as outputCount, for compatibility
        var treeRoot: String  // Hex encoded (wire format)
        var updatedAt: String // ISO8601

        enum CodingKeys: String, CodingKey {
            case startHeight = "start_height"
            case endHeight = "end_height"
            case outputCount = "output_count"
            case cmuCount = "cmu_count"
            case treeRoot = "tree_root"
            case updatedAt = "updated_at"
        }
    }

    /// Represents a single shielded output for the delta bundle
    struct DeltaOutput {
        let height: UInt32
        let index: UInt32
        let cmu: Data        // 32 bytes, wire format
        let epk: Data        // 32 bytes, wire format
        let ciphertext: Data // 580 bytes

        /// Serialize to 652-byte record (same format as boost file)
        func serialize() -> Data {
            var data = Data(capacity: DeltaCMUManager.OUTPUT_SIZE)

            // height: UInt32 LE
            var h = height.littleEndian
            data.append(Data(bytes: &h, count: 4))

            // index: UInt32 LE
            var i = index.littleEndian
            data.append(Data(bytes: &i, count: 4))

            // cmu: 32 bytes
            data.append(cmu.prefix(32))
            if cmu.count < 32 {
                data.append(Data(count: 32 - cmu.count))
            }

            // epk: 32 bytes
            data.append(epk.prefix(32))
            if epk.count < 32 {
                data.append(Data(count: 32 - epk.count))
            }

            // ciphertext: 580 bytes
            data.append(ciphertext.prefix(580))
            if ciphertext.count < 580 {
                data.append(Data(count: 580 - ciphertext.count))
            }

            return data
        }

        /// Parse from 652-byte record
        static func parse(from data: Data, at offset: Int) -> DeltaOutput? {
            guard data.count >= offset + DeltaCMUManager.OUTPUT_SIZE else { return nil }

            let height = data.subdata(in: offset..<(offset + 4)).withUnsafeBytes {
                $0.load(as: UInt32.self).littleEndian
            }
            let index = data.subdata(in: (offset + 4)..<(offset + 8)).withUnsafeBytes {
                $0.load(as: UInt32.self).littleEndian
            }
            let cmu = data.subdata(in: (offset + 8)..<(offset + 40))
            let epk = data.subdata(in: (offset + 40)..<(offset + 72))
            let ciphertext = data.subdata(in: (offset + 72)..<(offset + 652))

            return DeltaOutput(height: height, index: index, cmu: cmu, epk: epk, ciphertext: ciphertext)
        }
    }

    // MARK: - Public Methods

    /// Check if delta bundle exists and has data
    func hasDeltaBundle() -> Bool {
        return FileManager.default.fileExists(atPath: deltaFileURL.path) &&
               FileManager.default.fileExists(atPath: manifestFileURL.path)
    }

    /// Get the current delta manifest
    func getManifest() -> DeltaManifest? {
        guard FileManager.default.fileExists(atPath: manifestFileURL.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: manifestFileURL)
            let manifest = try JSONDecoder().decode(DeltaManifest.self, from: data)
            return manifest
        } catch {
            print("⚠️ DeltaCMU: Failed to read manifest: \(error)")
            return nil
        }
    }

    /// Get the end height of the delta bundle (or nil if no bundle)
    func getDeltaEndHeight() -> UInt64? {
        return getManifest()?.endHeight
    }

    /// Get the tree root (anchor) from the delta bundle
    func getDeltaTreeRoot() -> Data? {
        guard let manifest = getManifest(),
              let rootData = Data(hexString: manifest.treeRoot) else {
            return nil
        }
        return rootData
    }

    /// Get the output count
    func getOutputCount() -> UInt64 {
        return getManifest()?.outputCount ?? 0
    }

    /// Load delta bundle as raw Data (for Rust FFI parallel scan)
    /// Returns raw 652-byte records concatenated (no header)
    func loadDeltaOutputsRaw() -> Data? {
        guard FileManager.default.fileExists(atPath: deltaFileURL.path) else {
            return nil
        }

        do {
            let fileData = try Data(contentsOf: deltaFileURL)
            print("📦 DeltaCMU: Loaded \(fileData.count / Self.OUTPUT_SIZE) outputs from local delta bundle")
            return fileData
        } catch {
            print("⚠️ DeltaCMU: Failed to load delta bundle: \(error)")
            return nil
        }
    }

    /// Load all CMUs from the delta bundle (32 bytes each, wire format)
    /// For tree building - extracts just the CMU field from each 652-byte record
    func loadDeltaCMUs() -> [Data]? {
        guard let rawData = loadDeltaOutputsRaw() else { return nil }

        let outputCount = rawData.count / Self.OUTPUT_SIZE
        var cmus: [Data] = []
        cmus.reserveCapacity(outputCount)

        for i in 0..<outputCount {
            let offset = i * Self.OUTPUT_SIZE
            // CMU is at bytes 8-40 (after height and index)
            let cmu = rawData.subdata(in: (offset + 8)..<(offset + 40))
            cmus.append(cmu)
        }

        return cmus
    }

    /// Load CMUs from the delta bundle filtered by block height range
    /// Returns CMUs in blockchain order for outputs in [startHeight...endHeight]
    /// - Parameters:
    ///   - startHeight: First block height to include
    ///   - endHeight: Last block height to include
    /// - Returns: Array of 32-byte CMUs in wire format, or nil if delta bundle not available
    func loadDeltaCMUsForHeightRange(startHeight: UInt64, endHeight: UInt64) -> [Data]? {
        guard let rawData = loadDeltaOutputsRaw() else { return nil }

        let outputCount = rawData.count / Self.OUTPUT_SIZE
        var cmus: [Data] = []
        cmus.reserveCapacity(outputCount / 10)  // Estimate ~10% of outputs in range

        for i in 0..<outputCount {
            let offset = i * Self.OUTPUT_SIZE
            // Parse height from first 4 bytes
            let height = rawData.subdata(in: offset..<(offset + 4)).withUnsafeBytes {
                UInt64($0.load(as: UInt32.self).littleEndian)
            }

            // Only include outputs in our height range
            if height >= startHeight && height <= endHeight {
                // CMU is at bytes 8-40 (after height and index)
                let cmu = rawData.subdata(in: (offset + 8)..<(offset + 40))
                cmus.append(cmu)
            }
        }

        return cmus
    }

    /// Get outputs for parallel decryption (same format as BundledShieldedOutputs)
    /// Returns: [(height, globalPosition, outputData: 644 bytes for FFI)]
    func getOutputsForParallelDecryption(startGlobalPosition: UInt64) -> [(height: UInt32, globalPosition: UInt64, epk: Data, cmu: Data, ciphertext: Data)]? {
        guard let rawData = loadDeltaOutputsRaw() else { return nil }

        let outputCount = rawData.count / Self.OUTPUT_SIZE
        var results: [(height: UInt32, globalPosition: UInt64, epk: Data, cmu: Data, ciphertext: Data)] = []
        results.reserveCapacity(outputCount)

        for i in 0..<outputCount {
            let offset = i * Self.OUTPUT_SIZE
            guard let output = DeltaOutput.parse(from: rawData, at: offset) else { continue }

            // globalPosition is the position in the full tree (GitHub bundle count + delta index)
            let globalPosition = startGlobalPosition + UInt64(i)

            results.append((
                height: output.height,
                globalPosition: globalPosition,
                epk: output.epk,
                cmu: output.cmu,
                ciphertext: output.ciphertext
            ))
        }

        return results
    }

    /// Append new outputs to the delta bundle (or just update height if no outputs)
    /// - Parameters:
    ///   - outputs: Array of DeltaOutput (must have all 652 bytes of data), can be empty
    ///   - fromHeight: Starting block height of the scanned range (important for gap tracking!)
    ///   - toHeight: Ending block height
    ///   - treeRoot: Current tree root after appending (anchor, wire format)
    func appendOutputs(_ outputs: [DeltaOutput], fromHeight: UInt64? = nil, toHeight: UInt64, treeRoot: Data) {
        queue.sync {
            do {
                var fileData: Data
                var currentOutputCount: UInt64 = 0
                var startHeight: UInt64

                // Load existing data if file exists
                if FileManager.default.fileExists(atPath: deltaFileURL.path),
                   let existingData = try? Data(contentsOf: deltaFileURL),
                   let manifest = getManifest() {
                    fileData = existingData
                    currentOutputCount = manifest.outputCount
                    startHeight = manifest.startHeight
                } else {
                    fileData = Data()
                    // CRITICAL: Use fromHeight if provided (ensures gap is tracked!)
                    // This allows the caller to specify "I scanned from X to Y, even if no outputs found"
                    startHeight = fromHeight ?? outputs.first.map { UInt64($0.height) } ?? toHeight
                }

                // Append new outputs
                for output in outputs {
                    fileData.append(output.serialize())
                }

                // Write updated file
                try fileData.write(to: deltaFileURL)

                // Update manifest
                let newOutputCount = currentOutputCount + UInt64(outputs.count)
                let newManifest = DeltaManifest(
                    startHeight: startHeight,
                    endHeight: toHeight,
                    outputCount: newOutputCount,
                    cmuCount: newOutputCount,
                    treeRoot: treeRoot.hexString,
                    updatedAt: ISO8601DateFormatter().string(from: Date())
                )

                let manifestData = try JSONEncoder().encode(newManifest)
                try manifestData.write(to: manifestFileURL)

                // Update cache
                cachedOutputCount = newOutputCount
                cachedEndHeight = toHeight

                print("📦 DeltaCMU: Appended \(outputs.count) outputs (total: \(newOutputCount), height \(startHeight)-\(toHeight))")

            } catch {
                print("⚠️ DeltaCMU: Failed to append outputs: \(error)")
            }
        }
    }

    /// Replace the entire delta bundle with new data
    func replaceDeltaBundle(outputs: [DeltaOutput], startHeight: UInt64, endHeight: UInt64, treeRoot: Data) {
        queue.sync {
            do {
                // Write delta file
                var fileData = Data(capacity: outputs.count * Self.OUTPUT_SIZE)
                for output in outputs {
                    fileData.append(output.serialize())
                }
                try fileData.write(to: deltaFileURL)

                // Write manifest
                let manifest = DeltaManifest(
                    startHeight: startHeight,
                    endHeight: endHeight,
                    outputCount: UInt64(outputs.count),
                    cmuCount: UInt64(outputs.count),
                    treeRoot: treeRoot.hexString,
                    updatedAt: ISO8601DateFormatter().string(from: Date())
                )

                let manifestData = try JSONEncoder().encode(manifest)
                try manifestData.write(to: manifestFileURL)

                // Update cache
                cachedOutputCount = UInt64(outputs.count)
                cachedEndHeight = endHeight

                print("📦 DeltaCMU: Created delta bundle with \(outputs.count) outputs (height \(startHeight)-\(endHeight))")

            } catch {
                print("⚠️ DeltaCMU: Failed to create delta bundle: \(error)")
            }
        }
    }

    /// Clear the delta bundle (e.g., when wallet is deleted or GitHub bundle is updated)
    func clearDeltaBundle() {
        queue.sync {
            try? FileManager.default.removeItem(at: deltaFileURL)
            try? FileManager.default.removeItem(at: manifestFileURL)
            cachedOutputCount = 0
            cachedEndHeight = 0
            print("📦 DeltaCMU: Cleared delta bundle")
        }
    }

    /// Check if we need to fetch outputs from network
    /// Returns the height we need to start fetching from, or nil if no fetch needed
    func getHeightNeedingFetch(chainHeight: UInt64, bundledEndHeight: UInt64) -> UInt64? {
        if let manifest = getManifest() {
            // Have delta - check if it's up to date
            if manifest.endHeight >= chainHeight {
                return nil  // Delta is current, no fetch needed
            }
            return manifest.endHeight + 1  // Fetch from after delta
        }

        // No delta - need to fetch from after GitHub bundle
        if bundledEndHeight >= chainHeight {
            return nil  // Bundle is current (rare)
        }
        return bundledEndHeight + 1
    }

    /// Get combined data info for transaction building
    /// Returns (bundleEndHeight, deltaEndHeight, totalCMUCount, anchor)
    func getCombinedInfo(bundledEndHeight: UInt64, bundledCMUCount: UInt64) -> (endHeight: UInt64, cmuCount: UInt64, anchor: Data?)? {
        if let manifest = getManifest() {
            // Have delta
            let totalCMUs = bundledCMUCount + manifest.cmuCount
            let anchor = Data(hexString: manifest.treeRoot)
            return (endHeight: manifest.endHeight, cmuCount: totalCMUs, anchor: anchor)
        } else {
            // No delta - use bundle info
            let anchor = Data(hexString: ZipherXConstants.bundledTreeRoot)
            return (endHeight: bundledEndHeight, cmuCount: bundledCMUCount, anchor: anchor)
        }
    }

    // MARK: - Validation

    /// Validation result
    struct ValidationResult {
        let isValid: Bool
        let error: String?
        let manifest: DeltaManifest?
        let outputCount: UInt64
        let fileSize: Int
    }

    /// Validate delta bundle integrity on app startup
    /// Checks:
    /// 1. File exists and is readable
    /// 2. Manifest is valid JSON
    /// 3. Delta starts at bundledEndHeight + 1
    /// 4. File size matches manifest output count
    /// 5. Tree root (anchor) is 32 bytes
    ///
    /// Returns ValidationResult with details
    func validateDeltaBundle(bundledEndHeight: UInt64) -> ValidationResult {
        // Check if delta bundle exists
        guard hasDeltaBundle() else {
            return ValidationResult(isValid: true, error: nil, manifest: nil, outputCount: 0, fileSize: 0)
        }

        // Load manifest
        guard let manifest = getManifest() else {
            print("⚠️ DeltaCMU: Invalid manifest - clearing delta bundle")
            clearDeltaBundle()
            return ValidationResult(isValid: false, error: "Invalid manifest JSON", manifest: nil, outputCount: 0, fileSize: 0)
        }

        // Validate start height continuity
        let expectedStartHeight = bundledEndHeight + 1
        if manifest.startHeight != expectedStartHeight {
            print("⚠️ DeltaCMU: Start height mismatch - expected \(expectedStartHeight), got \(manifest.startHeight)")
            print("⚠️ DeltaCMU: Clearing invalid delta bundle")
            clearDeltaBundle()
            return ValidationResult(isValid: false, error: "Start height mismatch (expected \(expectedStartHeight), got \(manifest.startHeight))", manifest: manifest, outputCount: 0, fileSize: 0)
        }

        // Check file exists and get size
        guard FileManager.default.fileExists(atPath: deltaFileURL.path) else {
            print("⚠️ DeltaCMU: Data file missing - clearing delta bundle")
            clearDeltaBundle()
            return ValidationResult(isValid: false, error: "Data file missing", manifest: manifest, outputCount: 0, fileSize: 0)
        }

        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: deltaFileURL.path)
            let fileSize = attributes[.size] as? Int ?? 0

            // Validate file size matches output count
            let expectedSize = Int(manifest.outputCount) * Self.OUTPUT_SIZE
            if fileSize != expectedSize {
                print("⚠️ DeltaCMU: File size mismatch - expected \(expectedSize) bytes, got \(fileSize)")
                print("⚠️ DeltaCMU: Clearing corrupted delta bundle")
                clearDeltaBundle()
                return ValidationResult(isValid: false, error: "File size mismatch (expected \(expectedSize), got \(fileSize))", manifest: manifest, outputCount: 0, fileSize: fileSize)
            }

            // Validate tree root is valid hex (64 chars = 32 bytes)
            if manifest.treeRoot.count != 64 {
                print("⚠️ DeltaCMU: Invalid tree root length - expected 64 hex chars, got \(manifest.treeRoot.count)")
                clearDeltaBundle()
                return ValidationResult(isValid: false, error: "Invalid tree root length", manifest: manifest, outputCount: 0, fileSize: fileSize)
            }

            // Validate output count matches cmu count
            if manifest.outputCount != manifest.cmuCount {
                print("⚠️ DeltaCMU: Output/CMU count mismatch")
                clearDeltaBundle()
                return ValidationResult(isValid: false, error: "Output/CMU count mismatch", manifest: manifest, outputCount: 0, fileSize: fileSize)
            }

            print("✅ DeltaCMU: Validation passed - \(manifest.outputCount) outputs, height \(manifest.startHeight)-\(manifest.endHeight)")
            return ValidationResult(isValid: true, error: nil, manifest: manifest, outputCount: manifest.outputCount, fileSize: fileSize)

        } catch {
            print("⚠️ DeltaCMU: Failed to get file attributes: \(error)")
            clearDeltaBundle()
            return ValidationResult(isValid: false, error: "File access error: \(error.localizedDescription)", manifest: manifest, outputCount: 0, fileSize: 0)
        }
    }

    /// Validate delta bundle tree root against HeaderStore
    /// This ensures the delta's anchor matches the blockchain's finalSaplingRoot at deltaEndHeight
    func validateTreeRootAgainstHeaders() async -> Bool {
        guard let manifest = getManifest() else {
            return true  // No delta = nothing to validate
        }

        // Get header at delta end height
        do {
            let headerStore = HeaderStore.shared
            try headerStore.open()

            if let header = try headerStore.getHeader(at: manifest.endHeight) {
                let headerRoot = header.hashFinalSaplingRoot.hexString
                if headerRoot == manifest.treeRoot {
                    print("✅ DeltaCMU: Tree root matches header at height \(manifest.endHeight)")
                    return true
                } else {
                    print("⚠️ DeltaCMU: Tree root MISMATCH at height \(manifest.endHeight)")
                    print("   Delta root:  \(manifest.treeRoot.prefix(32))...")
                    print("   Header root: \(headerRoot.prefix(32))...")
                    // Don't auto-clear - let caller decide
                    return false
                }
            } else {
                // FIX: Without header validation, delta bundle could be corrupted
                // DO NOT trust unvalidated delta bundles - they can cause wrong anchor
                print("⚠️ DeltaCMU: No header at height \(manifest.endHeight) for validation - REJECTING BUNDLE")
                return false  // Can't validate = NOT safe to use
            }
        } catch {
            // FIX: Validation errors mean we can't verify the delta
            print("⚠️ DeltaCMU: Header validation error: \(error) - REJECTING BUNDLE")
            return false  // Can't validate = NOT safe to use
        }
    }
}
