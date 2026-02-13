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
    private let saplingRootsFileName = "delta_sapling_roots.bin"  // FIX #1253
    private let nullifiersFileName = "delta_nullifiers.bin"  // FIX #1289 v3

    /// Output record size - MUST match GitHub boost file format exactly
    /// height(4) + index(4) + cmu(32) + epk(32) + ciphertext(580) = 652 bytes
    static let OUTPUT_SIZE = 652

    /// FIX #1289 v3: Nullifier record size for spend detection during Full Rescan
    /// height(4) + txid(32) + nullifier(32) = 68 bytes
    static let NULLIFIER_RECORD_SIZE = 68

    // MARK: - Properties

    private var deltaFileURL: URL {
        // Use centralized app data directory (Application Support on macOS, Documents on iOS)
        return AppDirectories.appData.appendingPathComponent(deltaFileName)
    }

    private var manifestFileURL: URL {
        // Use centralized app data directory (Application Support on macOS, Documents on iOS)
        return AppDirectories.appData.appendingPathComponent(manifestFileName)
    }

    // FIX #1253: Companion file for finalsaplingroots from P2P block fetches.
    // Format: array of 40-byte entries (UInt64 height LE + 32-byte sapling_root).
    // Append-only. Cleared only by clearDeltaBundle(). Immutable when DeltaBundleVerified.
    private var saplingRootsFileURL: URL {
        return AppDirectories.appData.appendingPathComponent(saplingRootsFileName)
    }

    /// FIX #1289 v3: Delta nullifiers file for local spend detection
    private var nullifiersFileURL: URL {
        return AppDirectories.appData.appendingPathComponent(nullifiersFileName)
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

    /// FIX #1289 v3: Represents a single nullifier (spend) from a delta-range block.
    /// Stored in delta_nullifiers.bin for local spend detection during Full Rescan.
    /// When Phase 1b runs, these nullifiers are matched against discovered notes
    /// to detect spends without P2P block fetching.
    struct DeltaNullifier {
        let height: UInt32
        let txid: Data       // 32 bytes, wire format (reversed byte order)
        let nullifier: Data  // 32 bytes, wire format

        /// Serialize to 68-byte record
        func serialize() -> Data {
            var data = Data(capacity: DeltaCMUManager.NULLIFIER_RECORD_SIZE)
            var h = height.littleEndian
            data.append(Data(bytes: &h, count: 4))
            data.append(txid.count >= 32 ? txid.prefix(32) : txid + Data(count: 32 - txid.count))
            data.append(nullifier.count >= 32 ? nullifier.prefix(32) : nullifier + Data(count: 32 - nullifier.count))
            return data
        }

        /// Parse from 68-byte record
        static func parse(from data: Data, at offset: Int) -> DeltaNullifier? {
            guard data.count >= offset + DeltaCMUManager.NULLIFIER_RECORD_SIZE else { return nil }
            let height = data.subdata(in: offset..<(offset + 4)).withUnsafeBytes {
                $0.load(as: UInt32.self).littleEndian
            }
            let txid = data.subdata(in: (offset + 4)..<(offset + 36))
            let nullifier = data.subdata(in: (offset + 36)..<(offset + 68))
            return DeltaNullifier(height: height, txid: txid, nullifier: nullifier)
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
        // FIX #563 v12: Direct file read without queue to prevent deadlock
        // Called from background context in WalletManager, so safe to do sync I/O
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

    /// FIX #781: Helper struct to store CMU with its ordering key
    private struct OrderedCMU {
        let height: UInt32
        let index: UInt32
        let cmu: Data
    }

    /// Load all CMUs from the delta bundle (32 bytes each, wire format)
    /// For tree building - extracts just the CMU field from each 652-byte record
    /// FIX #781: CMUs are sorted by (height, index) to ensure correct tree root computation
    /// FIX #785: De-duplicates CMUs by (height, index) key to fix tree root mismatch (137 vs 134 CMUs)
    func loadDeltaCMUs() -> [Data]? {
        guard let rawData = loadDeltaOutputsRaw() else { return nil }

        let outputCount = rawData.count / Self.OUTPUT_SIZE
        var orderedCMUs: [OrderedCMU] = []
        orderedCMUs.reserveCapacity(outputCount)

        // FIX #785: Track (height, index) keys to detect and skip duplicates
        var seenKeys = Set<String>()
        var duplicateCount = 0

        for i in 0..<outputCount {
            let offset = i * Self.OUTPUT_SIZE
            // Parse height (bytes 0-4) and index (bytes 4-8)
            let height = rawData.subdata(in: offset..<(offset + 4)).withUnsafeBytes {
                $0.load(as: UInt32.self).littleEndian
            }
            let index = rawData.subdata(in: (offset + 4)..<(offset + 8)).withUnsafeBytes {
                $0.load(as: UInt32.self).littleEndian
            }

            // FIX #785: Skip duplicates - same (height, index) means same CMU
            let key = "\(height)_\(index)"
            if seenKeys.contains(key) {
                duplicateCount += 1
                continue
            }
            seenKeys.insert(key)

            // CMU is at bytes 8-40 (after height and index)
            let cmu = rawData.subdata(in: (offset + 8)..<(offset + 40))
            orderedCMUs.append(OrderedCMU(height: height, index: index, cmu: cmu))
        }

        if duplicateCount > 0 {
            print("🔧 FIX #785: Filtered \(duplicateCount) duplicate CMUs on load (was \(outputCount), now \(orderedCMUs.count))")
        }

        // FIX #781: CRITICAL - Sort by (height, index) for correct tree root
        // Commitment tree is order-dependent - CMUs must be in exact blockchain order
        orderedCMUs.sort { ($0.height, $0.index) < ($1.height, $1.index) }

        return orderedCMUs.map { $0.cmu }
    }

    /// Load CMUs from the delta bundle filtered by block height range
    /// Returns CMUs in blockchain order for outputs in [startHeight...endHeight]
    /// FIX #781: CMUs are sorted by (height, index) to ensure correct tree root computation
    /// FIX #785: De-duplicates CMUs by (height, index) key to fix tree root mismatch (137 vs 134 CMUs)
    /// - Parameters:
    ///   - startHeight: First block height to include
    ///   - endHeight: Last block height to include
    /// - Returns: Array of 32-byte CMUs in wire format, sorted by (height, index), or nil if delta bundle not available
    func loadDeltaCMUsForHeightRange(startHeight: UInt64, endHeight: UInt64) -> [Data]? {
        guard let rawData = loadDeltaOutputsRaw() else { return nil }

        let outputCount = rawData.count / Self.OUTPUT_SIZE
        var orderedCMUs: [OrderedCMU] = []
        orderedCMUs.reserveCapacity(outputCount / 10)  // Estimate ~10% of outputs in range

        // FIX #785: Track (height, index) keys to detect and skip duplicates
        var seenKeys = Set<String>()
        var duplicateCount = 0

        for i in 0..<outputCount {
            let offset = i * Self.OUTPUT_SIZE
            // Parse height (bytes 0-4) and index (bytes 4-8)
            let height = rawData.subdata(in: offset..<(offset + 4)).withUnsafeBytes {
                $0.load(as: UInt32.self).littleEndian
            }

            // Only include outputs in our height range
            if UInt64(height) >= startHeight && UInt64(height) <= endHeight {
                let index = rawData.subdata(in: (offset + 4)..<(offset + 8)).withUnsafeBytes {
                    $0.load(as: UInt32.self).littleEndian
                }

                // FIX #785: Skip duplicates - same (height, index) means same CMU
                let key = "\(height)_\(index)"
                if seenKeys.contains(key) {
                    duplicateCount += 1
                    continue
                }
                seenKeys.insert(key)

                // CMU is at bytes 8-40 (after height and index)
                let cmu = rawData.subdata(in: (offset + 8)..<(offset + 40))
                orderedCMUs.append(OrderedCMU(height: height, index: index, cmu: cmu))
            }
        }

        if duplicateCount > 0 {
            print("🔧 FIX #785: Filtered \(duplicateCount) duplicate CMUs on load for range \(startHeight)-\(endHeight)")
        }

        // FIX #781: CRITICAL - Sort by (height, index) for correct tree root
        // Commitment tree is order-dependent - CMUs must be in exact blockchain order
        orderedCMUs.sort { ($0.height, $0.index) < ($1.height, $1.index) }

        print("📦 FIX #781: Delta bundle returning \(orderedCMUs.count) CMUs for range \(startHeight)-\(endHeight) (sorted by height,index)")
        return orderedCMUs.map { $0.cmu }
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
    /// FIX #784: De-duplicates outputs to prevent tree root mismatch caused by duplicate CMUs
    /// - Parameters:
    ///   - outputs: Array of DeltaOutput (must have all 652 bytes of data), can be empty
    ///   - fromHeight: Starting block height of the scanned range (important for gap tracking!)
    ///   - toHeight: Ending block height
    ///   - treeRoot: Current tree root after appending (anchor, wire format)
    func appendOutputs(_ outputs: [DeltaOutput], fromHeight: UInt64? = nil, toHeight: UInt64, treeRoot: Data) {
        queue.sync {
            do {
                var existingOutputs: [DeltaOutput] = []
                var startHeight: UInt64

                // FIX #784: Track existing (height, index) keys to detect duplicates
                var existingKeys = Set<String>()

                // Load existing data if file exists
                if FileManager.default.fileExists(atPath: deltaFileURL.path),
                   let existingData = try? Data(contentsOf: deltaFileURL),
                   let manifest = getManifest() {
                    startHeight = manifest.startHeight

                    // FIX #784: Parse existing outputs and build key set
                    let outputCount = existingData.count / Self.OUTPUT_SIZE
                    for i in 0..<outputCount {
                        let offset = i * Self.OUTPUT_SIZE
                        if let output = DeltaOutput.parse(from: existingData, at: offset) {
                            existingOutputs.append(output)
                            let key = "\(output.height)_\(output.index)"
                            existingKeys.insert(key)
                        }
                    }
                } else {
                    // CRITICAL: Use fromHeight if provided (ensures gap is tracked!)
                    // This allows the caller to specify "I scanned from X to Y, even if no outputs found"
                    startHeight = fromHeight ?? outputs.first.map { UInt64($0.height) } ?? toHeight
                }

                // FIX #784: Filter out duplicates from new outputs
                var duplicateCount = 0
                var newUniqueOutputs: [DeltaOutput] = []
                for output in outputs {
                    let key = "\(output.height)_\(output.index)"
                    if existingKeys.contains(key) {
                        duplicateCount += 1
                    } else {
                        newUniqueOutputs.append(output)
                        existingKeys.insert(key)  // Track so we don't add the same output twice from new batch
                    }
                }

                if duplicateCount > 0 {
                    print("🔧 FIX #784: Filtered \(duplicateCount) duplicate CMUs (prevented tree root mismatch)")
                }

                // Rebuild file data with existing + new unique outputs
                var fileData = Data(capacity: (existingOutputs.count + newUniqueOutputs.count) * Self.OUTPUT_SIZE)
                for output in existingOutputs {
                    fileData.append(output.serialize())
                }
                for output in newUniqueOutputs {
                    fileData.append(output.serialize())
                }

                // Write updated file
                try fileData.write(to: deltaFileURL)

                // Update manifest
                let newOutputCount = UInt64(existingOutputs.count + newUniqueOutputs.count)
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

                print("📦 DeltaCMU: Appended \(newUniqueOutputs.count) outputs (total: \(newOutputCount), height \(startHeight)-\(toHeight))")

            } catch {
                print("⚠️ DeltaCMU: Failed to append outputs: \(error)")
            }
        }
    }

    // MARK: - FIX #1289 v3: Delta Nullifier Storage

    /// Append nullifiers (spends) collected during delta sync.
    /// These enable Phase 1b to detect spends locally during Full Rescan.
    func appendNullifiers(_ nullifiers: [DeltaNullifier]) {
        guard !nullifiers.isEmpty else { return }
        queue.sync {
            do {
                var fileData: Data
                if FileManager.default.fileExists(atPath: nullifiersFileURL.path) {
                    fileData = try Data(contentsOf: nullifiersFileURL)
                } else {
                    fileData = Data()
                }
                for nf in nullifiers {
                    fileData.append(nf.serialize())
                }
                try fileData.write(to: nullifiersFileURL)
                let totalCount = fileData.count / Self.NULLIFIER_RECORD_SIZE
                print("📦 FIX #1289 v3: Saved \(nullifiers.count) nullifiers (total: \(totalCount))")
            } catch {
                print("⚠️ FIX #1289 v3: Failed to save nullifiers: \(error)")
            }
        }
    }

    /// Load all stored nullifiers for local spend detection.
    /// Returns nil if no nullifiers file exists.
    func loadNullifiers() -> [DeltaNullifier]? {
        guard FileManager.default.fileExists(atPath: nullifiersFileURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: nullifiersFileURL)
            guard data.count >= Self.NULLIFIER_RECORD_SIZE else { return nil }
            let count = data.count / Self.NULLIFIER_RECORD_SIZE
            var nullifiers: [DeltaNullifier] = []
            nullifiers.reserveCapacity(count)
            for i in 0..<count {
                if let nf = DeltaNullifier.parse(from: data, at: i * Self.NULLIFIER_RECORD_SIZE) {
                    nullifiers.append(nf)
                }
            }
            print("📦 FIX #1289 v3: Loaded \(nullifiers.count) nullifiers from delta bundle")
            return nullifiers.isEmpty ? nil : nullifiers
        } catch {
            print("⚠️ FIX #1289 v3: Failed to load nullifiers: \(error)")
            return nil
        }
    }

    /// Check if delta bundle has nullifiers stored (for Phase 1b v3 eligibility)
    func hasNullifiers() -> Bool {
        guard FileManager.default.fileExists(atPath: nullifiersFileURL.path),
              let attrs = try? FileManager.default.attributesOfItem(atPath: nullifiersFileURL.path),
              let size = attrs[.size] as? UInt64 else { return false }
        return size >= UInt64(Self.NULLIFIER_RECORD_SIZE)
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

    /// FIX #1190: Update only the tree root in the delta manifest
    /// Called AFTER callers compute the tree root from FFI, to finalize the delta
    /// This avoids the chicken-and-egg problem: delta outputs are saved during P2P fetch,
    /// but tree root is only known after all CMUs are appended to the tree
    func updateManifestTreeRoot(_ treeRoot: Data) {
        queue.sync {
            guard var manifest = getManifest() else {
                print("⚠️ FIX #1190: Cannot update tree root - no manifest exists")
                return
            }

            manifest = DeltaManifest(
                startHeight: manifest.startHeight,
                endHeight: manifest.endHeight,
                outputCount: manifest.outputCount,
                cmuCount: manifest.cmuCount,
                treeRoot: treeRoot.hexString,
                updatedAt: ISO8601DateFormatter().string(from: Date())
            )

            do {
                let manifestData = try JSONEncoder().encode(manifest)
                try manifestData.write(to: manifestFileURL)
                print("📦 FIX #1190: Updated delta manifest tree root to \(treeRoot.prefix(8).map { String(format: "%02x", $0) }.joined())...")
            } catch {
                print("⚠️ FIX #1190: Failed to update manifest tree root: \(error)")
            }
        }
    }

    /// Clear the delta bundle.
    /// FIX #1254: By default, REFUSES to clear if delta is verified (immutable).
    /// Only Full Rescan, wallet wipe, and boost file update should pass `force: true`.
    /// All other callers (validation failures, tree mismatches, etc.) use default `force: false`
    /// which protects verified delta from accidental destruction.
    func clearDeltaBundle(force: Bool = false) {
        queue.sync {
            // FIX #1254: Guard verified delta from non-forced clears.
            // 26+ callsites trigger clearDeltaBundle on validation failures,
            // but verified delta was already validated against blockchain roots.
            // Validation failure after verification = loading/sync issue, NOT delta corruption.
            if !force && UserDefaults.standard.bool(forKey: "DeltaBundleVerified") {
                print("🛡️ FIX #1254: clearDeltaBundle() BLOCKED — delta is VERIFIED (immutable)")
                print("   Use force:true only for Full Rescan, wallet wipe, or boost update")
                print("   Caller should handle the mismatch without destroying verified data")
                return
            }
            try? FileManager.default.removeItem(at: deltaFileURL)
            try? FileManager.default.removeItem(at: manifestFileURL)
            try? FileManager.default.removeItem(at: saplingRootsFileURL)  // FIX #1253
            try? FileManager.default.removeItem(at: nullifiersFileURL)  // FIX #1289 v3
            cachedOutputCount = 0
            cachedEndHeight = 0
            // FIX #1252: Any delta clear invalidates the verified flag.
            // Delta must be rebuilt and re-verified before becoming immutable again.
            UserDefaults.standard.set(false, forKey: "DeltaBundleVerified")
            // FIX #1253: Clear in-memory cache too
            HeaderStore.shared.deltaSaplingRoots = []
            if force {
                print("📦 DeltaCMU: FORCE cleared delta bundle + sapling roots (authorized operation)")
            } else {
                print("📦 DeltaCMU: Cleared delta bundle + sapling roots (delta was not verified)")
            }
        }
    }

    // MARK: - FIX #1253: Delta Sapling Roots

    /// Append a finalsaplingroot from a P2P block fetch to the delta roots file.
    /// Each entry is 40 bytes: UInt64 height (LE) + 32-byte sapling_root.
    /// Append-only file, cleared only by clearDeltaBundle().
    /// Also adds to HeaderStore in-memory cache for immediate containsSaplingRoot() lookups.
    func appendSaplingRoot(height: UInt64, root: Data) {
        guard root.count == 32 else { return }
        queue.sync {
            var entry = Data(capacity: 40)
            var h = height
            withUnsafeBytes(of: &h) { entry.append(contentsOf: $0) }  // 8 bytes LE
            entry.append(root)  // 32 bytes

            if FileManager.default.fileExists(atPath: saplingRootsFileURL.path) {
                if let handle = try? FileHandle(forWritingTo: saplingRootsFileURL) {
                    handle.seekToEndOfFile()
                    handle.write(entry)
                    handle.closeFile()
                }
            } else {
                try? entry.write(to: saplingRootsFileURL)
            }

            // Also add to in-memory cache (both byte orders for FIX #1230)
            HeaderStore.shared.deltaSaplingRoots.insert(root)
            HeaderStore.shared.deltaSaplingRoots.insert(Data(root.reversed()))
        }
    }

    /// FIX #1287: Batch append multiple sapling roots in a single file I/O operation.
    /// Replaces per-block appendSaplingRoot() calls that open/seek/write/close for EACH block
    /// (128 file I/O ops per peer batch → 1 file I/O op).
    func appendSaplingRootsBatch(_ entries: [(height: UInt64, root: Data)]) {
        let validEntries = entries.filter { $0.root.count == 32 }
        guard !validEntries.isEmpty else { return }
        queue.sync {
            // Build all entries into one Data buffer (40 bytes each)
            var allData = Data(capacity: validEntries.count * 40)
            for (height, root) in validEntries {
                var h = height
                withUnsafeBytes(of: &h) { allData.append(contentsOf: $0) }  // 8 bytes LE
                allData.append(root)  // 32 bytes
            }

            // Single file write instead of per-block open/seek/write/close
            if FileManager.default.fileExists(atPath: saplingRootsFileURL.path) {
                if let handle = try? FileHandle(forWritingTo: saplingRootsFileURL) {
                    handle.seekToEndOfFile()
                    handle.write(allData)
                    handle.closeFile()
                }
            } else {
                try? allData.write(to: saplingRootsFileURL)
            }

            // Update in-memory cache (both byte orders for FIX #1230)
            for (_, root) in validEntries {
                HeaderStore.shared.deltaSaplingRoots.insert(root)
                HeaderStore.shared.deltaSaplingRoots.insert(Data(root.reversed()))
            }
        }
    }

    /// Load all sapling roots from the delta roots file into a Set for O(1) lookups.
    /// Called at startup to populate HeaderStore.deltaSaplingRoots.
    /// Returns roots in BOTH byte orders (wire + canonical) for FIX #1230 compatibility.
    func loadSaplingRoots() -> Set<Data> {
        guard FileManager.default.fileExists(atPath: saplingRootsFileURL.path) else {
            return []
        }
        guard let data = try? Data(contentsOf: saplingRootsFileURL) else {
            return []
        }

        let entrySize = 40  // 8 (height) + 32 (root)
        let count = data.count / entrySize
        var roots = Set<Data>(minimumCapacity: count * 2)

        for i in 0..<count {
            let offset = i * entrySize + 8  // Skip height, read 32-byte root
            guard offset + 32 <= data.count else { break }
            let root = data[offset..<(offset + 32)]
            let rootData = Data(root)
            roots.insert(rootData)
            roots.insert(Data(rootData.reversed()))  // FIX #1230: both byte orders
        }

        print("📦 FIX #1253: Loaded \(count) delta sapling roots (\(roots.count) entries with both byte orders)")
        return roots
    }

    /// Check if the delta sapling roots file exists and has data
    func hasSaplingRoots() -> Bool {
        guard FileManager.default.fileExists(atPath: saplingRootsFileURL.path) else {
            return false
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: saplingRootsFileURL.path)[.size] as? Int) ?? 0
        return size >= 40  // At least one entry
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

            // FIX #601 v2: Removed over-aggressive output count validation
            // Original FIX #601 expected 0.2 outputs/block, but Zclassic only has ~0.06/block
            // This was causing delta bundle to be cleared every startup, breaking witness updates
            // Now we trust the output count as-is - the delta bundle was created by our own scan
            let blockRange = manifest.endHeight - manifest.startHeight + 1
            let actualRate = Double(manifest.outputCount) / Double(blockRange)
            print("📊 FIX #601 v2: Delta bundle has \(manifest.outputCount) outputs for \(blockRange) blocks (\(String(format: "%.3f", actualRate))/block)")

            print("✅ DeltaCMU: Validation passed - \(manifest.outputCount) outputs, height \(manifest.startHeight)-\(manifest.endHeight)")
            return ValidationResult(isValid: true, error: nil, manifest: manifest, outputCount: manifest.outputCount, fileSize: fileSize)

        } catch {
            print("⚠️ DeltaCMU: Failed to get file attributes: \(error)")
            clearDeltaBundle()
            return ValidationResult(isValid: false, error: "File access error: \(error.localizedDescription)", manifest: manifest, outputCount: 0, fileSize: 0)
        }
    }

    /// FIX #1191: Validate delta tree root against P2P block's finalsaplingroot
    /// Fetches a single block header from a P2P peer and compares the sapling root
    /// NO local node, NO RPC, NO zclassic-cli — pure P2P validation
    ///
    /// Returns true if:
    /// - No delta exists (nothing to validate)
    /// - No peers available (graceful skip)
    /// - Tree root matches blockchain (delta is correct)
    /// Returns false if:
    /// - Tree root does NOT match (delta is corrupt)
    func validateTreeRootAgainstHeaders() async -> Bool {
        guard let manifest = getManifest() else {
            return true  // No delta = nothing to validate
        }

        // FIX #1191: Get finalsaplingroot from P2P peer for the delta end height
        // The block's finalsaplingroot field is the authoritative tree root
        let endHeight = manifest.endHeight

        // Try to get the sapling root from HeaderStore first (fastest, no network)
        if let header = try? HeaderStore.shared.getHeader(at: endHeight) {
            let headerRoot = header.hashFinalSaplingRoot
            let isZeroRoot = headerRoot.allSatisfy { $0 == 0 }

            if !isZeroRoot {
                // We have a non-zero header root — compare with delta
                guard let deltaRootData = Data(hexString: manifest.treeRoot) else {
                    print("⚠️ FIX #1191: Invalid hex in delta tree root")
                    return true
                }

                // Header stores sapling root in wire format (same as delta)
                if deltaRootData == headerRoot {
                    print("✅ FIX #1191: Delta tree root MATCHES header at height \(endHeight)")
                    return true
                }

                // Also check reversed (header might be display format)
                let deltaReversed = Data(deltaRootData.reversed())
                if deltaReversed == headerRoot {
                    print("✅ FIX #1191: Delta tree root matches header (reversed) at height \(endHeight)")
                    return true
                }

                // FIX #1204: HeaderStore roots above boost file ARE authoritative now.
                // Delta sync fetched full blocks for endHeight → FIX #1204 stored the real
                // finalsaplingroot from block data (not from unreliable getheaders).
                // A mismatch here is a REAL mismatch — delta CMUs are corrupt.
                print("❌ FIX #1191: Delta tree root MISMATCH at height \(endHeight)!")
                print("   Delta root:  \(manifest.treeRoot.prefix(32))...")
                print("   Header root: \(headerRoot.map { String(format: "%02x", $0) }.joined().prefix(32))...")
                return false
            }
        }

        // No header available or zero root — skip validation
        // The delta will be validated indirectly through witness anchor checks
        print("📦 FIX #1191: No reliable header at height \(endHeight) — skipping delta root validation")
        return true
    }

    // MARK: - FIX #979: Delta Bundle Compaction

    /// FIX #979: PERFORMANCE - Compact delta bundle at startup to remove accumulated duplicates
    /// The delta bundle can accumulate duplicate CMUs over time due to:
    /// 1. Re-scans of the same height range
    /// 2. Background sync overlapping with catch-up sync
    /// 3. Repair operations re-scanning already processed blocks
    ///
    /// This function reads the delta bundle, removes duplicates, and rewrites it.
    /// Should be called once at app startup BEFORE loading CMUs into memory.
    ///
    /// Returns: (originalCount, compactedCount) - tuple showing before/after counts
    func compactDeltaBundleIfNeeded() -> (original: Int, compacted: Int, removed: Int) {
        return queue.sync {
            guard FileManager.default.fileExists(atPath: deltaFileURL.path),
                  let manifest = getManifest() else {
                return (0, 0, 0)
            }

            do {
                let existingData = try Data(contentsOf: deltaFileURL)
                let originalCount = existingData.count / Self.OUTPUT_SIZE

                // Quick check: if manifest.outputCount matches file, likely no duplicates
                // Skip compaction if difference is small (< 5% overhead)
                let duplicateThreshold = max(10, originalCount / 20) // 5% or at least 10
                if Int(manifest.outputCount) >= originalCount - duplicateThreshold {
                    print("📦 FIX #979: Delta bundle looks clean (file:\(originalCount), manifest:\(manifest.outputCount)) - skipping compaction")
                    return (originalCount, originalCount, 0)
                }

                print("📦 FIX #979: Compacting delta bundle (file has \(originalCount) records, manifest says \(manifest.outputCount))...")

                // Parse all outputs and deduplicate by (height, index) key
                var seenKeys = Set<String>()
                var uniqueOutputs: [DeltaOutput] = []
                uniqueOutputs.reserveCapacity(originalCount)
                var duplicateCount = 0

                for i in 0..<originalCount {
                    let offset = i * Self.OUTPUT_SIZE
                    if let output = DeltaOutput.parse(from: existingData, at: offset) {
                        let key = "\(output.height)_\(output.index)"
                        if seenKeys.contains(key) {
                            duplicateCount += 1
                        } else {
                            seenKeys.insert(key)
                            uniqueOutputs.append(output)
                        }
                    }
                }

                // Only rewrite if we found significant duplicates
                if duplicateCount < 10 {
                    print("📦 FIX #979: Only \(duplicateCount) duplicates found - not worth rewriting")
                    return (originalCount, originalCount, duplicateCount)
                }

                // Sort by (height, index) for correct tree order
                uniqueOutputs.sort { ($0.height, $0.index) < ($1.height, $1.index) }

                // Rewrite the file with unique, sorted outputs
                var compactedData = Data(capacity: uniqueOutputs.count * Self.OUTPUT_SIZE)
                for output in uniqueOutputs {
                    compactedData.append(output.serialize())
                }
                try compactedData.write(to: deltaFileURL)

                // Update manifest with correct count
                let newManifest = DeltaManifest(
                    startHeight: manifest.startHeight,
                    endHeight: manifest.endHeight,
                    outputCount: UInt64(uniqueOutputs.count),
                    cmuCount: UInt64(uniqueOutputs.count),
                    treeRoot: manifest.treeRoot,
                    updatedAt: ISO8601DateFormatter().string(from: Date())
                )
                let manifestData = try JSONEncoder().encode(newManifest)
                try manifestData.write(to: manifestFileURL)

                // Update cache
                cachedOutputCount = UInt64(uniqueOutputs.count)

                print("✅ FIX #979: Compacted delta bundle from \(originalCount) to \(uniqueOutputs.count) records (removed \(duplicateCount) duplicates)")
                return (originalCount, uniqueOutputs.count, duplicateCount)

            } catch {
                print("⚠️ FIX #979: Failed to compact delta bundle: \(error)")
                return (0, 0, 0)
            }
        }
    }

    /// FIX #979: Check if delta bundle needs compaction
    /// Returns true if there are likely duplicates (manifest count != file record count)
    func needsCompaction() -> Bool {
        guard FileManager.default.fileExists(atPath: deltaFileURL.path),
              let manifest = getManifest() else {
            return false
        }

        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: deltaFileURL.path)
            let fileSize = attributes[.size] as? Int ?? 0
            let fileRecordCount = fileSize / Self.OUTPUT_SIZE

            // If file has more records than manifest claims, we have duplicates
            let hasDuplicates = fileRecordCount > Int(manifest.outputCount) + 10
            if hasDuplicates {
                print("📦 FIX #979: Delta bundle needs compaction (file:\(fileRecordCount) > manifest:\(manifest.outputCount))")
            }
            return hasDuplicates
        } catch {
            return false
        }
    }
}
