#!/usr/bin/env swift
//
// build_tree_from_cmus.swift
// Builds the actual Sapling commitment tree from raw CMUs
// Uses the ZipherX Rust FFI functions
//
// Usage: Run from Xcode or compile with the ZipherX library
//

import Foundation

// MARK: - FFI Declarations (same as bridging header)

@_silgen_name("zipherx_tree_init")
func zipherx_tree_init() -> Bool

@_silgen_name("zipherx_tree_append")
func zipherx_tree_append(_ cmu: UnsafePointer<UInt8>) -> UInt64

@_silgen_name("zipherx_tree_size")
func zipherx_tree_size() -> UInt64

@_silgen_name("zipherx_tree_root")
func zipherx_tree_root(_ root_out: UnsafeMutablePointer<UInt8>) -> Bool

@_silgen_name("zipherx_tree_serialize")
func zipherx_tree_serialize(_ tree_out: UnsafeMutablePointer<UInt8>, _ tree_out_len: UnsafeMutablePointer<Int>) -> Bool

// MARK: - Main

func main() {
    print("🌳 Building Sapling Commitment Tree from CMUs")
    print("=============================================\n")

    // Paths
    let toolsDir = FileManager.default.currentDirectoryPath
    let inputPath = toolsDir + "/commitment_tree.bin"
    let outputPath = toolsDir + "/sapling_tree.bin"
    let metaOutputPath = toolsDir + "/sapling_tree_meta.json"

    // Read CMUs file
    guard let inputData = FileManager.default.contents(atPath: inputPath) else {
        print("❌ Could not read \(inputPath)")
        print("   Run build_commitment_tree.swift first!")
        exit(1)
    }

    print("📂 Loaded \(inputPath)")
    print("📦 File size: \(inputData.count / 1024 / 1024) MB")

    // Parse header: first 8 bytes = commitment count
    guard inputData.count >= 8 else {
        print("❌ Invalid file format")
        exit(1)
    }

    let count = inputData.withUnsafeBytes { ptr -> UInt64 in
        ptr.load(as: UInt64.self)
    }

    print("📊 Commitments to process: \(count)")

    // Verify file size
    let expectedSize = 8 + (Int(count) * 32)
    guard inputData.count >= expectedSize else {
        print("❌ File too small. Expected \(expectedSize) bytes, got \(inputData.count)")
        exit(1)
    }

    // Initialize tree
    guard zipherx_tree_init() else {
        print("❌ Failed to initialize commitment tree")
        exit(1)
    }
    print("✅ Tree initialized")

    // Process CMUs
    let startTime = Date()
    var processed: UInt64 = 0

    inputData.withUnsafeBytes { ptr in
        let basePtr = ptr.baseAddress!.advanced(by: 8) // Skip count header

        for i in 0..<Int(count) {
            let cmuPtr = basePtr.advanced(by: i * 32).assumingMemoryBound(to: UInt8.self)
            let position = zipherx_tree_append(cmuPtr)

            if position == UInt64.max {
                print("\n❌ Failed to append commitment at index \(i)")
                exit(1)
            }

            processed += 1

            // Progress every 10000
            if processed % 10000 == 0 || processed == count {
                let elapsed = Date().timeIntervalSince(startTime)
                let rate = Double(processed) / elapsed
                let remaining = Double(count - processed) / rate
                let eta = remaining > 0 ? formatTime(remaining) : "done"
                let progress = Double(processed) / Double(count) * 100

                print("\r⏳ Progress: \(String(format: "%.1f", progress))% | " +
                      "\(processed)/\(count) | " +
                      "Speed: \(String(format: "%.0f", rate))/s | " +
                      "ETA: \(eta)     ", terminator: "")
                fflush(stdout)
            }
        }
    }

    print("\n")

    // Verify tree size
    let treeSize = zipherx_tree_size()
    print("🌳 Tree size: \(treeSize) commitments")

    // Get tree root
    var root = [UInt8](repeating: 0, count: 32)
    if zipherx_tree_root(&root) {
        let rootHex = root.map { String(format: "%02x", $0) }.joined()
        print("🔑 Tree root: \(rootHex)")
    }

    // Serialize tree
    print("\n📦 Serializing tree...")

    // Allocate buffer for serialized tree (estimate: ~50MB max)
    let maxSize = 50 * 1024 * 1024
    var treeBuffer = [UInt8](repeating: 0, count: maxSize)
    var actualSize = maxSize

    guard zipherx_tree_serialize(&treeBuffer, &actualSize) else {
        print("❌ Failed to serialize tree")
        exit(1)
    }

    // Save serialized tree
    let treeData = Data(treeBuffer.prefix(actualSize))
    do {
        try treeData.write(to: URL(fileURLWithPath: outputPath))
        print("💾 Saved to: \(outputPath)")
        print("📦 Serialized size: \(actualSize / 1024 / 1024) MB")
    } catch {
        print("❌ Failed to save: \(error)")
        exit(1)
    }

    // Save metadata
    let rootHex = root.map { String(format: "%02x", $0) }.joined()
    let metadata: [String: Any] = [
        "version": 1,
        "chain": "zclassic",
        "commitment_count": treeSize,
        "tree_root": rootHex,
        "serialized_size": actualSize,
        "created_at": ISO8601DateFormatter().string(from: Date())
    ]

    do {
        let metadataJSON = try JSONSerialization.data(withJSONObject: metadata, options: .prettyPrinted)
        try metadataJSON.write(to: URL(fileURLWithPath: metaOutputPath))
        print("📋 Metadata saved to: \(metaOutputPath)")
    } catch {
        print("⚠️ Could not save metadata: \(error)")
    }

    let totalTime = Date().timeIntervalSince(startTime)
    print("\n✅ Done in \(formatTime(totalTime))")

    // Verify by deserializing and checking root
    print("\n🔍 Verifying serialized tree...")

    // Re-init and deserialize
    guard zipherx_tree_init() else {
        print("❌ Failed to re-init tree for verification")
        exit(1)
    }

    let verifyResult = treeData.withUnsafeBytes { ptr -> Bool in
        return zipherx_tree_deserialize(
            ptr.baseAddress!.assumingMemoryBound(to: UInt8.self),
            treeData.count
        )
    }

    if verifyResult {
        var verifyRoot = [UInt8](repeating: 0, count: 32)
        if zipherx_tree_root(&verifyRoot) {
            let verifyRootHex = verifyRoot.map { String(format: "%02x", $0) }.joined()
            if verifyRootHex == rootHex {
                print("✅ Verification passed! Root matches: \(verifyRootHex)")
            } else {
                print("⚠️ Root mismatch!")
                print("   Original: \(rootHex)")
                print("   Verified: \(verifyRootHex)")
            }
        }
        let verifySize = zipherx_tree_size()
        print("📊 Deserialized tree size: \(verifySize)")
    } else {
        print("❌ Failed to deserialize tree for verification")
    }

    print("\n📱 To bundle with iOS app:")
    print("   1. Add \(outputPath) to Xcode project")
    print("   2. Load on app startup with zipherx_tree_deserialize()")
}

@_silgen_name("zipherx_tree_deserialize")
func zipherx_tree_deserialize(_ tree_data: UnsafePointer<UInt8>, _ tree_len: Int) -> Bool

func formatTime(_ seconds: Double) -> String {
    if seconds < 60 {
        return "\(Int(seconds))s"
    } else if seconds < 3600 {
        return "\(Int(seconds / 60))m \(Int(seconds.truncatingRemainder(dividingBy: 60)))s"
    } else {
        let hours = Int(seconds / 3600)
        let mins = Int((seconds.truncatingRemainder(dividingBy: 3600)) / 60)
        return "\(hours)h \(mins)m"
    }
}

// Run
main()
