#!/usr/bin/env swift
//
// verify_tree.swift
// Load CMUs from bin file, build tree, and verify root matches chain
//

import Foundation

// Load the FFI
@_silgen_name("zipherx_tree_init")
func treeInit() -> Bool

@_silgen_name("zipherx_tree_append")
func treeAppend(_ cmu: UnsafePointer<UInt8>) -> UInt64

@_silgen_name("zipherx_tree_root")
func treeRoot(_ rootOut: UnsafeMutablePointer<UInt8>) -> Bool

@_silgen_name("zipherx_tree_size")
func treeSize() -> UInt64

func main() {
    print("🌳 Tree Verification Tool")
    print("========================\n")

    // Load CMUs from file
    let inputPath = FileManager.default.currentDirectoryPath + "/commitment_tree.bin"

    guard let data = FileManager.default.contents(atPath: inputPath) else {
        print("❌ Could not read \(inputPath)")
        return
    }

    // Parse: [count: UInt64][cmu1: 32 bytes][cmu2: 32 bytes]...
    var offset = 0
    let count = data.withUnsafeBytes { ptr -> UInt64 in
        ptr.load(fromByteOffset: 0, as: UInt64.self)
    }
    offset = 8

    print("📦 Loading \(count) CMUs from file...")

    // Initialize tree
    guard treeInit() else {
        print("❌ Failed to init tree")
        return
    }

    // Append all CMUs
    let startTime = Date()
    var position: UInt64 = 0

    for i in 0..<count {
        let cmuData = data.subdata(in: offset..<(offset + 32))
        offset += 32

        cmuData.withUnsafeBytes { ptr in
            position = treeAppend(ptr.baseAddress!.assumingMemoryBound(to: UInt8.self))
        }

        if i % 100000 == 0 {
            let progress = Double(i) / Double(count) * 100
            print("\r⏳ Progress: \(String(format: "%.1f", progress))% (\(i)/\(count))", terminator: "")
            fflush(stdout)
        }
    }

    let elapsed = Date().timeIntervalSince(startTime)
    print("\n✅ Loaded \(count) CMUs in \(String(format: "%.1f", elapsed))s")

    // Get tree root
    var root = [UInt8](repeating: 0, count: 32)
    guard treeRoot(&root) else {
        print("❌ Failed to get tree root")
        return
    }

    // Convert to hex (note: the root needs to be reversed for comparison with RPC)
    let rootHex = root.reversed().map { String(format: "%02x", $0) }.joined()

    print("\n📊 Tree Statistics:")
    print("   Size: \(treeSize()) commitments")
    print("   Root: \(rootHex)")

    print("\n💡 Compare with chain's finalsaplingroot using:")
    print("   zclassic-cli getblockheader $(zclassic-cli getblockhash HEIGHT) true | grep finalsaplingroot")
}

main()
